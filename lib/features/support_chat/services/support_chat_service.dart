import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

class SupportChatService {
  SupportChatService({FirebaseFirestore? firestore, FirebaseStorage? storage})
    : _db = firestore ?? FirebaseFirestore.instance,
      _storage = storage ?? FirebaseStorage.instance;

  final FirebaseFirestore _db;
  final FirebaseStorage _storage;

  static const String _chatsCollection = 'chats';
  static const String _messagesSubcollection = 'messages';
  static const String _adminId = 'admin';

  String chatIdForUser(String uid) => 'support_$uid';

  CollectionReference<Map<String, dynamic>> get _chats =>
      _db.collection(_chatsCollection);

  CollectionReference<Map<String, dynamic>> _messagesRef(String chatId) =>
      _chats.doc(chatId).collection(_messagesSubcollection);

  Future<Uint8List> _compressImageForUpload(Uint8List bytes) async {
    if (bytes.isEmpty) return bytes;
    try {
      final compressed = await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: 1600,
        minHeight: 1600,
        quality: 78,
        format: CompressFormat.jpeg,
      );
      if (compressed.isNotEmpty && compressed.length < bytes.length) {
        return compressed;
      }
      return bytes;
    } catch (_) {
      return bytes;
    }
  }

  Future<bool> chatExists(String chatId) async {
    final snap = await _chats.doc(chatId).get();
    return snap.exists;
  }

  Future<String> ensureSupportChat({
    required String uid,
    String? userName,
    String? userEmail,
    String? userPhone,
  }) async {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty) {
      throw ArgumentError('uid cannot be empty');
    }

    final chatId = chatIdForUser(cleanUid);
    final chatRef = _chats.doc(chatId);

    await chatRef.set({
      'chatId': chatId,
      'type': 'support',
      'participants': [cleanUid, _adminId],
      'userId': cleanUid,
      'adminId': _adminId,
      'userName': (userName ?? '').trim(),
      'userEmail': (userEmail ?? '').trim(),
      'userPhone': (userPhone ?? '').trim(),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    return chatId;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> messagesStream(String chatId) {
    return _messagesRef(
      chatId,
    ).orderBy('timestamp', descending: false).snapshots();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> chatStream(String chatId) {
    final cleanChatId = chatId.trim();
    if (cleanChatId.isEmpty) {
      throw ArgumentError('chatId cannot be empty');
    }
    return _chats.doc(cleanChatId).snapshots();
  }

  Stream<int> unreadCountStreamForUser(String uid) {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty) return const Stream<int>.empty();

    final chatId = chatIdForUser(cleanUid);
    return _messagesRef(chatId)
        .where('senderRole', isEqualTo: 'admin')
        .where('seen', isEqualTo: false)
        .snapshots()
        .map((snap) => snap.size);
  }

  Future<Map<String, String>> uploadSupportMedia({
    required String uid,
    required String chatId,
    required XFile file,
  }) async {
    final cleanUid = uid.trim();
    final cleanChatId = chatId.trim();
    if (cleanUid.isEmpty || cleanChatId.isEmpty) {
      throw ArgumentError('uid and chatId are required');
    }

    final mime = file.mimeType?.trim().toLowerCase() ?? '';
    final lowerName = file.name.toLowerCase();
    final isImage =
        mime.startsWith('image/') ||
        lowerName.endsWith('.png') ||
        lowerName.endsWith('.jpg') ||
        lowerName.endsWith('.jpeg') ||
        lowerName.endsWith('.webp') ||
        lowerName.endsWith('.gif');
    final isVideo =
        mime.startsWith('video/') ||
        lowerName.endsWith('.mp4') ||
        lowerName.endsWith('.mov') ||
        lowerName.endsWith('.m4v') ||
        lowerName.endsWith('.webm') ||
        lowerName.endsWith('.avi');

    if (!isImage && !isVideo) {
      throw StateError('Only image and video files are supported.');
    }

    final mediaType = isImage ? 'image' : 'video';
    final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final storagePath =
        'chats/$cleanChatId/media/$cleanUid/${DateTime.now().millisecondsSinceEpoch}_$safeName';

    final rawBytes = await file.readAsBytes();
    final bytes = isImage ? await _compressImageForUpload(rawBytes) : rawBytes;
    final task = _storage
        .ref(storagePath)
        .putData(
          bytes,
          SettableMetadata(
            contentType: mime.isEmpty ? null : mime,
            cacheControl: 'public,max-age=31536000,immutable',
          ),
        );
    final snap = await task;
    final url = await snap.ref.getDownloadURL();

    return {
      'mediaUrl': url,
      'mediaType': mediaType,
      'mimeType': mime,
      'fileName': file.name,
      'storagePath': storagePath,
    };
  }

  Future<void> sendSupportMessage({
    required String uid,
    required String text,
    String? userName,
    String? userEmail,
    String? userPhone,
    String? chatId,
    String? clientMessageId,
    String? mediaUrl,
    String? mediaType,
    String? mimeType,
    String? fileName,
  }) async {
    final cleanUid = uid.trim();
    final message = text.trim();
    final cleanMediaUrl = (mediaUrl ?? '').trim();
    if (cleanUid.isEmpty || (message.isEmpty && cleanMediaUrl.isEmpty)) return;

    final resolvedChatId = (chatId ?? '').trim().isNotEmpty
        ? chatId!.trim()
        : await ensureSupportChat(
            uid: cleanUid,
            userName: userName,
            userEmail: userEmail,
            userPhone: userPhone,
          );

    final messageRef = _messagesRef(resolvedChatId).doc();
    final localNow = Timestamp.now();

    await messageRef.set({
      'messageId': messageRef.id,
      'chatId': resolvedChatId,
      'senderId': cleanUid,
      'sender': 'user',
      'senderRole': 'user',
      'text': message,
      'message': message,
      'mediaUrl': cleanMediaUrl,
      'mediaType': (mediaType ?? '').trim(),
      'mimeType': (mimeType ?? '').trim(),
      'fileName': (fileName ?? '').trim(),
      'clientMessageId': (clientMessageId ?? '').trim(),
      'seen': false,
      'timestamp': localNow,
      'serverTimestamp': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    });

    final fallbackLastMessage = cleanMediaUrl.isNotEmpty
        ? ((mediaType ?? '').toLowerCase() == 'video' ? '🎬 Video' : '📷 Photo')
        : 'New message';
    final summary = message.isNotEmpty ? message : fallbackLastMessage;

    await _chats.doc(resolvedChatId).set({
      'lastMessage': summary,
      'lastMessageBy': cleanUid,
      'lastTimestamp': localNow,
      'lastServerTimestamp': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> markAdminMessagesSeen({required String uid}) async {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty) return;

    final chatId = chatIdForUser(cleanUid);
    final query = await _messagesRef(chatId)
        .where('senderRole', isEqualTo: 'admin')
        .where('seen', isEqualTo: false)
        .get();

    if (query.docs.isEmpty) return;

    final batch = _db.batch();
    for (final doc in query.docs) {
      batch.update(doc.reference, {
        'seen': true,
        'seenAt': FieldValue.serverTimestamp(),
      });
    }

    batch.set(_chats.doc(chatId), {
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await batch.commit();
  }

  Future<void> resetSupportFlow({required String chatId}) async {
    final cleanChatId = chatId.trim();
    if (cleanChatId.isEmpty) return;

    await _chats.doc(cleanChatId).set({
      'supportFlow': {
        'step': 'START',
        'selectedCategory': '',
        'selectedQuantity': '',
        'selectedRequirement': '',
        'isCompleted': false,
      },
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
