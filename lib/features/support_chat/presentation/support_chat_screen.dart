import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';
import 'package:purecuts/features/support_chat/services/support_chat_service.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:video_player/video_player.dart';

class SupportChatScreen extends StatefulWidget {
  const SupportChatScreen({super.key, this.service});

  final SupportChatService? service;

  @override
  State<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends State<SupportChatScreen> {
  late final SupportChatService _service;
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _composerFocusNode = FocusNode();
  final ImagePicker _imagePicker = ImagePicker();
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _sending = false;
  bool _hasDraftText = false;
  bool _speechReady = false;
  bool _isListening = false;
  String? _speechLocaleId;
  String _voiceDraftPrefix = '';
  String? _chatId;
  String? _bootstrapError;
  XFile? _selectedMedia;
  int _lastRenderedMessageCount = 0;
  bool _markingSeen = false;
  final List<_PendingMessage> _pendingMessages = <_PendingMessage>[];

  Future<void> _sendOptionSelection(String option) async {
    final value = option.trim();
    if (value.isEmpty || _sending) return;

    final auth = context.read<AuthProvider>();
    final user = auth.user;
    if (user == null) return;

    final pendingId = DateTime.now().microsecondsSinceEpoch.toString();
    final pending = _PendingMessage(
      clientMessageId: pendingId,
      text: value,
      mediaType: '',
      timeLabel: _formatTime(Timestamp.now()),
    );

    setState(() {
      _selectedMedia = null;
      _pendingMessages.add(pending);
      _sending = true;
      _controller.clear();
      _hasDraftText = false;
    });
    _scrollToBottom(animated: true);

    try {
      var resolvedChatId = (_chatId ?? '').trim();
      if (resolvedChatId.isEmpty) {
        resolvedChatId = await _service.ensureSupportChat(
          uid: user.uid,
          userName: user.name,
          userEmail: user.email,
          userPhone: user.phone,
        );
        if (mounted) {
          setState(() => _chatId = resolvedChatId);
        }
      }

      await _service.sendSupportMessage(
        uid: user.uid,
        text: value,
        userName: user.name,
        userEmail: user.email,
        userPhone: user.phone,
        chatId: resolvedChatId,
        clientMessageId: pendingId,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pendingMessages.removeWhere(
          (item) => item.clientMessageId == pendingId,
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send selected option. $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  String _speechErrorMessage(dynamic error) {
    final rawMsg = (error?.errorMsg ?? error?.toString() ?? '').toString();
    final msg = rawMsg.toLowerCase();
    if (msg.contains('no_match') ||
        msg.contains('no match') ||
        msg.contains('speech_timeout') ||
        msg.contains('speech timeout') ||
        msg.contains('aborted')) {
      return 'Didn\'t catch that. Try speaking a little slower.';
    }
    if (msg.contains('permission') || msg.contains('not allowed')) {
      return 'Microphone permission is required. Please enable it in settings.';
    }
    final permanent = (error?.permanent == true);
    return permanent
        ? 'Microphone is unavailable right now. Please try again.'
        : 'Listening stopped. Tap mic and try again.';
  }

  Future<void> _initSpeech() async {
    final available = await _speech.initialize(
      onStatus: (status) {
        if (!mounted) return;
        final listening = status.toLowerCase().contains('listening');
        if (_isListening != listening) {
          setState(() => _isListening = listening);
        }
      },
      onError: (error) {
        if (!mounted) return;
        setState(() => _isListening = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_speechErrorMessage(error))));
      },
    );

    if (!mounted) return;
    if (available) {
      try {
        final systemLocale = await _speech.systemLocale();
        final locales = await _speech.locales();
        if (systemLocale != null && systemLocale.localeId.trim().isNotEmpty) {
          _speechLocaleId = systemLocale.localeId;
        } else {
          final preferred = locales.where((l) {
            final id = l.localeId.toLowerCase();
            return id == 'en_in' || id.startsWith('en_');
          });
          _speechLocaleId =
              (preferred.isNotEmpty
                      ? preferred.first
                      : locales.isNotEmpty
                      ? locales.first
                      : null)
                  ?.localeId;
        }
      } catch (_) {
        // Keep locale null to let plugin pick device default.
      }
    }

    setState(() {
      _speechReady = available;
      if (!available) _isListening = false;
    });
  }

  Future<void> _toggleComposerVoiceInput() async {
    if (!_speechReady) {
      await _initSpeech();
    }

    if (!_speechReady) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Voice input is unavailable on this device.'),
        ),
      );
      return;
    }

    if (_isListening) {
      await _speech.stop();
      if (!mounted) return;
      setState(() => _isListening = false);
      return;
    }

    _voiceDraftPrefix = _controller.text.trim();

    final started = await _speech.listen(
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.dictation,
        partialResults: true,
        cancelOnError: false,
      ),
      listenFor: const Duration(seconds: 20),
      pauseFor: const Duration(seconds: 5),
      localeId: _speechLocaleId,
      onResult: (result) {
        if (!mounted) return;
        final spoken = result.recognizedWords.trim();
        final nextText = spoken.isEmpty
            ? _voiceDraftPrefix
            : (_voiceDraftPrefix.isEmpty
                  ? spoken
                  : '$_voiceDraftPrefix $spoken');

        _controller
          ..text = nextText
          ..selection = TextSelection.fromPosition(
            TextPosition(offset: nextText.length),
          );
      },
    );

    if (!mounted) return;
    setState(() => _isListening = started);
  }

  void _onDraftChanged() {
    final next = _controller.text.trim().isNotEmpty;
    if (_hasDraftText == next) return;
    if (!mounted) return;
    setState(() => _hasDraftText = next);
  }

  Future<void> _handleStartOver() async {
    final auth = context.read<AuthProvider>();
    final user = auth.user;
    final chatId = (_chatId ?? '').trim();
    if (user == null || chatId.isEmpty || _sending) return;

    try {
      await _service.resetSupportFlow(chatId: chatId);
      _controller.text = 'Start Over';
      await _handleSend();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not restart chat flow. $e')),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? SupportChatService();
    _controller.addListener(_onDraftChanged);
    _initSpeech();
    _bootstrapChat();
  }

  Future<void> _bootstrapChat() async {
    final auth = context.read<AuthProvider>();
    final user = auth.user;
    if (user == null) return;

    if (mounted) {
      setState(() {
        _bootstrapError = null;
      });
    }

    try {
      final chatId = await _service.ensureSupportChat(
        uid: user.uid,
        userName: user.name,
        userEmail: user.email,
        userPhone: user.phone,
      );

      if (!mounted) return;
      setState(() => _chatId = chatId);

      await _service.markAdminMessagesSeen(uid: user.uid);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _bootstrapError =
            'Unable to open support chat right now. Please try again.';
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Support chat error: $e')));
    }
  }

  @override
  void dispose() {
    _speech.stop();
    _controller.removeListener(_onDraftChanged);
    _controller.dispose();
    _scrollController.dispose();
    _composerFocusNode.dispose();
    super.dispose();
  }

  Future<void> _handleSend() async {
    final auth = context.read<AuthProvider>();
    final user = auth.user;
    if (user == null) return;

    final text = _controller.text.trim();
    final selectedMedia = _selectedMedia;
    if ((text.isEmpty && selectedMedia == null) || _sending) return;

    final pendingId = DateTime.now().microsecondsSinceEpoch.toString();
    final pending = _PendingMessage(
      clientMessageId: pendingId,
      text: text,
      mediaType: selectedMedia == null
          ? ''
          : (_isImageFile(selectedMedia) ? 'image' : 'video'),
      timeLabel: _formatTime(Timestamp.now()),
    );

    setState(() {
      _pendingMessages.add(pending);
      _sending = true;
      _selectedMedia = null;
    });
    _scrollToBottom(animated: true);

    _controller.clear();
    _hasDraftText = false;

    try {
      String? mediaUrl;
      String? mediaType;
      String? mimeType;
      String? fileName;

      var resolvedChatId = (_chatId ?? '').trim();
      if (resolvedChatId.isEmpty) {
        resolvedChatId = await _service.ensureSupportChat(
          uid: user.uid,
          userName: user.name,
          userEmail: user.email,
          userPhone: user.phone,
        );
        if (mounted) {
          setState(() => _chatId = resolvedChatId);
        }
      }

      if (selectedMedia != null) {
        final mediaMeta = await _service.uploadSupportMedia(
          uid: user.uid,
          chatId: resolvedChatId,
          file: selectedMedia,
        );
        mediaUrl = mediaMeta['mediaUrl'];
        mediaType = mediaMeta['mediaType'];
        mimeType = mediaMeta['mimeType'];
        fileName = mediaMeta['fileName'];
      }

      await _service.sendSupportMessage(
        uid: user.uid,
        text: text,
        userName: user.name,
        userEmail: user.email,
        userPhone: user.phone,
        chatId: resolvedChatId,
        clientMessageId: pendingId,
        mediaUrl: mediaUrl,
        mediaType: mediaType,
        mimeType: mimeType,
        fileName: fileName,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pendingMessages.removeWhere(
          (item) => item.clientMessageId == pendingId,
        );
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to send message. $e')));
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  bool _isImageFile(XFile file) {
    final mime = (file.mimeType ?? '').toLowerCase();
    final name = file.name.toLowerCase();
    return mime.startsWith('image/') ||
        name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.webp') ||
        name.endsWith('.gif');
  }

  Future<void> _pickMedia() async {
    if (_sending) return;

    final source = await showModalBottomSheet<_MediaPickChoice>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose Photo'),
              onTap: () => Navigator.of(ctx).pop(_MediaPickChoice.galleryImage),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take Photo'),
              onTap: () => Navigator.of(ctx).pop(_MediaPickChoice.cameraImage),
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Choose Video'),
              onTap: () => Navigator.of(ctx).pop(_MediaPickChoice.galleryVideo),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Record Video'),
              onTap: () => Navigator.of(ctx).pop(_MediaPickChoice.cameraVideo),
            ),
          ],
        ),
      ),
    );

    if (source == null || !mounted) return;

    try {
      XFile? picked;
      switch (source) {
        case _MediaPickChoice.galleryImage:
          // On Android 13+, this uses system photo picker without broad media permissions
          // On older versions, requires READ_EXTERNAL_STORAGE (already removed from manifest)
          picked = await _imagePicker.pickImage(
            source: ImageSource.gallery,
            imageQuality: 88,
          );
          break;
        case _MediaPickChoice.cameraImage:
          // Camera doesn't require storage/media permissions
          picked = await _imagePicker.pickImage(
            source: ImageSource.camera,
            imageQuality: 88,
          );
          break;
        case _MediaPickChoice.galleryVideo:
          // On Android 13+, this uses system video picker without broad media permissions
          // On older versions, requires READ_EXTERNAL_STORAGE (already removed from manifest)
          picked = await _imagePicker.pickVideo(source: ImageSource.gallery);
          break;
        case _MediaPickChoice.cameraVideo:
          // Camera doesn't require storage/media permissions
          picked = await _imagePicker.pickVideo(source: ImageSource.camera);
          break;
      }

      if (picked == null || !mounted) return;

      final fileSize = await picked.length();
      const maxBytes = 25 * 1024 * 1024;
      if (fileSize > maxBytes) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select media up to 25MB.')),
        );
        return;
      }

      setState(() => _selectedMedia = picked);
      _focusComposer();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Unable to pick media. $e')));
    }
  }

  void _scrollToBottom({required bool animated}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (!animated) {
        _scrollController.jumpTo(target);
        return;
      }
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  String _formatTime(Timestamp? ts) {
    if (ts == null) return '';
    final dt = ts.toDate();
    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final minute = dt.minute.toString().padLeft(2, '0');
    final suffix = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  int _toMillis(dynamic value) {
    if (value is Timestamp) return value.toDate().millisecondsSinceEpoch;
    if (value is DateTime) return value.millisecondsSinceEpoch;
    if (value is int) return value;
    return 0;
  }

  bool _isLegacyQuantityPrompt(Map<String, dynamic> data) {
    final senderRole = (data['senderRole'] as String? ?? '')
        .trim()
        .toLowerCase();
    final sender = (data['sender'] as String? ?? '').trim().toLowerCase();
    final isBotLike = senderRole == 'bot' || sender == 'bot';
    if (!isBotLike) return false;

    final text = (data['text'] as String? ?? data['message'] as String? ?? '')
        .trim()
        .toLowerCase();
    final options =
        ((data['options'] as List?)
            ?.map((item) => item.toString().trim().toLowerCase())
            .where((item) => item.isNotEmpty)
            .toList(growable: false)) ??
        const <String>[];

    final isRangeOption = (String v) {
      final normalized = v.trim();
      return RegExp(r'^(\d+\s*-\s*\d+|\d+\+)$').hasMatch(normalized);
    };

    final hasLegacyText =
        text.contains('select quantity range') ||
        (text.contains('you are eligible for') &&
            text.contains('quantity range'));
    final hasLegacyOptions =
        options.isNotEmpty && options.every((opt) => isRangeOption(opt));

    return hasLegacyText || hasLegacyOptions;
  }

  Timestamp? _resolvedMessageTimestamp(Map<String, dynamic> data) {
    final serverTs = data['serverTimestamp'];
    if (serverTs is Timestamp) return serverTs;
    final localTs = data['timestamp'];
    if (localTs is Timestamp) return localTs;
    final createdAt = data['createdAt'];
    if (createdAt is Timestamp) return createdAt;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final user = auth.user;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Support Chat'),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimary,
        actions: [
          TextButton.icon(
            onPressed: (_chatId == null || _sending) ? null : _handleStartOver,
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('Start Over'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: user == null
          ? const Center(child: Text('Please login to chat with support.'))
          : _bootstrapError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 22,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.10),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.chat_bubble_outline_rounded,
                          color: AppColors.primary,
                          size: 28,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _bootstrapError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 14),
                      ElevatedButton.icon(
                        onPressed: _bootstrapChat,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: _chatId == null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(height: 10),
                              Text(
                                'Preparing support chat...',
                                style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        )
                      : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: _service.messagesStream(_chatId!),
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              return const Center(
                                child: Text('Could not load chat right now.'),
                              );
                            }

                            final docs = snapshot.data?.docs ?? [];
                            final hasPending = _pendingMessages.isNotEmpty;
                            final initialLoading =
                                snapshot.connectionState ==
                                    ConnectionState.waiting &&
                                docs.isEmpty &&
                                !hasPending;
                            if (initialLoading) {
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }

                            final orderedDocs =
                                List<
                                    QueryDocumentSnapshot<Map<String, dynamic>>
                                  >.from(docs)
                                  ..sort((a, b) {
                                    final ams = _toMillis(
                                      _resolvedMessageTimestamp(a.data()),
                                    );
                                    final bms = _toMillis(
                                      _resolvedMessageTimestamp(b.data()),
                                    );
                                    if (ams == bms) {
                                      return a.id.compareTo(b.id);
                                    }
                                    return ams.compareTo(bms);
                                  });

                            final visibleDocs = orderedDocs
                                .where(
                                  (doc) => !_isLegacyQuantityPrompt(doc.data()),
                                )
                                .toList(growable: false);

                            final acknowledgedClientIds = visibleDocs
                                .map(
                                  (doc) =>
                                      (doc.data()['clientMessageId']
                                                  as String? ??
                                              '')
                                          .trim(),
                                )
                                .where((id) => id.isNotEmpty)
                                .toSet();
                            if (visibleDocs.isEmpty) {
                              final pendingOnly = _pendingMessages;
                              if (pendingOnly.isEmpty) {
                                return _EmptyChat(onStart: _focusComposer);
                              }
                              return ListView(
                                controller: _scrollController,
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  12,
                                  12,
                                  8,
                                ),
                                children: pendingOnly
                                    .map(
                                      (item) => _ChatBubble(
                                        text: item.text,
                                        time: '${item.timeLabel} • Sending...',
                                        isMine: true,
                                      ),
                                    )
                                    .toList(),
                              );
                            }

                            final hasUnreadAdminMessage = visibleDocs.any((
                              doc,
                            ) {
                              final data = doc.data();
                              final senderId =
                                  (data['senderId'] as String? ?? '').trim();
                              final senderRole =
                                  (data['senderRole'] as String? ?? '')
                                      .trim()
                                      .toLowerCase();
                              final seen = data['seen'] == true;
                              final isAdminMessage =
                                  senderRole == 'admin' || senderId == 'admin';
                              return isAdminMessage && !seen;
                            });
                            if (hasUnreadAdminMessage && !_markingSeen) {
                              _markingSeen = true;
                              _service
                                  .markAdminMessagesSeen(uid: user.uid)
                                  .whenComplete(() => _markingSeen = false);
                            }

                            final hasNewMessage =
                                visibleDocs.length != _lastRenderedMessageCount;
                            if (hasNewMessage) {
                              final animate = _lastRenderedMessageCount > 0;
                              _lastRenderedMessageCount = visibleDocs.length;
                              _scrollToBottom(animated: animate);
                            }

                            final visiblePending = _pendingMessages
                                .where(
                                  (pending) => !acknowledgedClientIds.contains(
                                    pending.clientMessageId,
                                  ),
                                )
                                .toList();

                            return ListView.builder(
                              controller: _scrollController,
                              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                              itemCount:
                                  visibleDocs.length + visiblePending.length,
                              itemBuilder: (context, index) {
                                if (index >= visibleDocs.length) {
                                  final pending =
                                      visiblePending[index -
                                          visibleDocs.length];
                                  return _ChatBubble(
                                    text: pending.text,
                                    mediaType: pending.mediaType,
                                    time: '${pending.timeLabel} • Sending...',
                                    isMine: true,
                                  );
                                }

                                final data = visibleDocs[index].data();
                                final senderId =
                                    (data['senderId'] as String? ?? '').trim();
                                final isMine = senderId == user.uid;
                                final text =
                                    (data['text'] as String? ??
                                            data['message'] as String? ??
                                            '')
                                        .trim();
                                final mediaUrl =
                                    (data['mediaUrl'] as String? ?? '').trim();
                                final mediaType =
                                    (data['mediaType'] as String? ?? '')
                                        .trim()
                                        .toLowerCase();
                                final options =
                                    ((data['options'] as List?)
                                        ?.map((item) => item.toString().trim())
                                        .where((item) => item.isNotEmpty)
                                        .toList(growable: false)) ??
                                    const <String>[];
                                final ts = _resolvedMessageTimestamp(data);

                                return _ChatBubble(
                                  text: text,
                                  mediaUrl: mediaUrl,
                                  mediaType: mediaType,
                                  options: options,
                                  onOptionTap: isMine
                                      ? null
                                      : (value) => _sendOptionSelection(value),
                                  time: _formatTime(ts),
                                  isMine: isMine,
                                );
                              },
                            );
                          },
                        ),
                ),
                if (_selectedMedia != null)
                  _SelectedMediaDraft(
                    file: _selectedMedia!,
                    isImage: _isImageFile(_selectedMedia!),
                    onRemove: _sending
                        ? null
                        : () => setState(() => _selectedMedia = null),
                  ),
                _Composer(
                  controller: _controller,
                  focusNode: _composerFocusNode,
                  onSend: _handleSend,
                  onAttach: _pickMedia,
                  onVoiceInput: _toggleComposerVoiceInput,
                  isSending: _sending,
                  isListening: _isListening,
                  canSend: _hasDraftText || _selectedMedia != null,
                ),
              ],
            ),
    );
  }

  void _focusComposer() {
    FocusScope.of(context).requestFocus(_composerFocusNode);
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onAttach,
    required this.onVoiceInput,
    required this.isSending,
    required this.isListening,
    required this.canSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onVoiceInput;
  final bool isSending;
  final bool isListening;
  final bool canSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            InkWell(
              onTap: isSending ? null : onAttach,
              borderRadius: BorderRadius.circular(22),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.border),
                ),
                child: const Icon(
                  Icons.attach_file_rounded,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: 'Type your message...',
                  filled: true,
                  fillColor: AppColors.surface,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: isSending ? null : onVoiceInput,
              borderRadius: BorderRadius.circular(22),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isListening
                      ? AppColors.primary.withValues(alpha: 0.14)
                      : AppColors.surface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isListening ? AppColors.primary : AppColors.border,
                  ),
                ),
                child: Icon(
                  isListening ? Icons.mic : Icons.mic_none_rounded,
                  color: isListening
                      ? AppColors.primary
                      : AppColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: (isSending || !canSend) ? null : onSend,
              borderRadius: BorderRadius.circular(22),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: (isSending || !canSend)
                      ? AppColors.textHint
                      : AppColors.primary,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.send_rounded, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.text,
    required this.time,
    required this.isMine,
    this.mediaUrl = '',
    this.mediaType = '',
    this.options = const <String>[],
    this.onOptionTap,
  });

  final String text;
  final String time;
  final bool isMine;
  final String mediaUrl;
  final String mediaType;
  final List<String> options;
  final ValueChanged<String>? onOptionTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isMine ? AppColors.primary : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isMine ? 14 : 4),
            bottomRight: Radius.circular(isMine ? 4 : 14),
          ),
          border: Border.all(
            color: isMine ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: isMine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (mediaUrl.isNotEmpty && mediaType == 'image') ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: CachedNetworkImage(
                  imageUrl: mediaUrl,
                  width: 220,
                  height: 220,
                  fit: BoxFit.cover,
                  fadeInDuration: Duration.zero,
                  fadeOutDuration: Duration.zero,
                  memCacheWidth: 440,
                  maxWidthDiskCache: 440,
                  errorWidget: (_, _, __) => Container(
                    width: 220,
                    height: 140,
                    color: Colors.black12,
                    alignment: Alignment.center,
                    child: const Icon(Icons.broken_image_outlined),
                  ),
                ),
              ),
              if (text.isNotEmpty) const SizedBox(height: 8),
            ],
            if (mediaUrl.isNotEmpty && mediaType == 'video') ...[
              SizedBox(
                width: 220,
                height: 220,
                child: _NetworkVideoMessage(url: mediaUrl),
              ),
              if (text.isNotEmpty) const SizedBox(height: 8),
            ],
            if (text.isNotEmpty)
              Text(
                text,
                style: TextStyle(
                  color: isMine ? Colors.white : AppColors.textPrimary,
                  fontSize: 14,
                  height: 1.35,
                ),
              )
            else if (mediaType == 'image' && mediaUrl.isEmpty)
              Text(
                '📷 Sending photo...',
                style: TextStyle(
                  color: isMine ? Colors.white : AppColors.textPrimary,
                  fontSize: 14,
                  height: 1.35,
                ),
              )
            else if (mediaType == 'video' && mediaUrl.isEmpty)
              Text(
                '🎬 Sending video...',
                style: TextStyle(
                  color: isMine ? Colors.white : AppColors.textPrimary,
                  fontSize: 14,
                  height: 1.35,
                ),
              ),
            if (time.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                time,
                style: TextStyle(
                  color: isMine
                      ? Colors.white.withValues(alpha: 0.85)
                      : AppColors.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
            if (options.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: options
                    .map(
                      (option) => OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Colors.white,
                          side: const BorderSide(color: AppColors.border),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: onOptionTap == null
                            ? null
                            : () => onOptionTap!(option),
                        child: Text(
                          option,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SelectedMediaDraft extends StatelessWidget {
  const _SelectedMediaDraft({
    required this.file,
    required this.isImage,
    required this.onRemove,
  });

  final XFile file;
  final bool isImage;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: isImage
                ? FutureBuilder<Uint8List>(
                    future: file.readAsBytes(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      }
                      return Image.memory(snapshot.data!, fit: BoxFit.cover);
                    },
                  )
                : const Icon(Icons.videocam_rounded, color: AppColors.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isImage ? 'Photo ready to send' : 'Video ready to send',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close_rounded),
            color: AppColors.textSecondary,
          ),
        ],
      ),
    );
  }
}

class _NetworkVideoMessage extends StatefulWidget {
  const _NetworkVideoMessage({required this.url});

  final String url;

  @override
  State<_NetworkVideoMessage> createState() => _NetworkVideoMessageState();
}

class _NetworkVideoMessageState extends State<_NetworkVideoMessage> {
  VideoPlayerController? _controller;
  Future<void>? _initFuture;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  @override
  void didUpdateWidget(covariant _NetworkVideoMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _disposeController();
      _setup();
    }
  }

  void _setup() {
    final url = widget.url.trim();
    if (url.isEmpty) return;

    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _controller = controller;
    _initFuture = controller.initialize().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _disposeController() async {
    final c = _controller;
    _controller = null;
    _initFuture = null;
    await c?.dispose();
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || _initFuture == null) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.videocam_off_outlined),
      );
    }

    return FutureBuilder<void>(
      future: _initFuture,
      builder: (_, snapshot) {
        if (snapshot.connectionState != ConnectionState.done ||
            !_controller!.value.isInitialized) {
          return Container(
            decoration: BoxDecoration(
              color: Colors.black12,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _controller!.value.size.width,
                  height: _controller!.value.size.height,
                  child: VideoPlayer(_controller!),
                ),
              ),
              Align(
                alignment: Alignment.center,
                child: IconButton.filled(
                  onPressed: () {
                    final isPlaying = _controller!.value.isPlaying;
                    if (isPlaying) {
                      _controller!.pause();
                    } else {
                      _controller!.play();
                    }
                    if (mounted) setState(() {});
                  },
                  icon: Icon(
                    _controller!.value.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.support_agent_rounded,
                color: AppColors.primary,
                size: 34,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Need help?',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Start a conversation with PureCuts support. We are here to help.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: onStart,
              icon: const Icon(Icons.edit_rounded),
              label: const Text('Write a message'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingMessage {
  _PendingMessage({
    required this.clientMessageId,
    required this.text,
    required this.mediaType,
    required this.timeLabel,
  });

  final String clientMessageId;
  final String text;
  final String mediaType;
  final String timeLabel;
}

enum _MediaPickChoice { galleryImage, cameraImage, galleryVideo, cameraVideo }
