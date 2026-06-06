import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:provider/provider.dart';
import 'package:purecuts/core/models/cart_model.dart';
import 'package:purecuts/core/services/firestore_service.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/core/widgets/sticky_cart_bar.dart';
import 'package:purecuts/features/categories/sub_sub_category_screen.dart';
import 'package:purecuts/features/home/home_provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

class CategoriesScreen extends StatefulWidget {
  final String? initialCategory;

  const CategoriesScreen({super.key, this.initialCategory});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _preferredCategory = 'All';
  Set<String> _purchasedProductIds = <String>{};
  final Set<String> _expandedCategories = <String>{};
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechReady = false;
  bool _isListening = false;
  bool _speechDialogVisible = false;
  String? _speechLocaleId;
  ValueNotifier<String>? _activeTranscript;
  bool _pendingVoiceSubmit = false;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.hideCurrentSnackBar();
      messenger?.clearSnackBars();
    });
    if (widget.initialCategory != null && widget.initialCategory!.isNotEmpty) {
      _preferredCategory = widget.initialCategory!;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final home = context.read<HomeProvider>();
      unawaited(
        Future<void>(() async {
          await home.loadData();
          await home.ensureVisibilityCatalogLoaded();
        }),
      );
    });
    _resolvePurchasedProducts();
    _initSpeech();
  }

  @override
  void dispose() {
    _speech.stop();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initSpeech() async {
    final available = await _speech.initialize(
      onStatus: (status) {
        if (!mounted) return;
        final normalized = status.toLowerCase();
        final listening = normalized.contains('listening');
        if (_isListening != listening) {
          setState(() => _isListening = listening);
        }
        if (!listening && _pendingVoiceSubmit) {
          final spoken = (_activeTranscript?.value ?? '').trim();
          if (spoken.isNotEmpty &&
              spoken != 'Listening...' &&
              !spoken.startsWith('Didn\'t catch')) {
            _applyVoiceText(spoken);
            _closeSpeechDialog();
            _pendingVoiceSubmit = false;
            return;
          }
        }
        if (!listening &&
            _activeTranscript != null &&
            _activeTranscript!.value == 'Listening...') {
          _activeTranscript!.value =
              'Didn\'t catch that. Try speaking again clearly.';
        }
      },
      onError: (error) {
        if (!mounted) return;
        setState(() => _isListening = false);
        if (_activeTranscript != null) {
          final current = _activeTranscript!.value.trim();
          if (current.isEmpty || current == 'Listening...') {
            _activeTranscript!.value = _speechErrorMessage(error);
          }
        }
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
        // Keep locale null to let plugin choose device default.
      }
    }

    setState(() {
      _speechReady = available;
      if (!available) {
        _isListening = false;
      }
    });
  }

  Future<void> _toggleVoiceSearch() async {
    if (!_speechReady) {
      await _initSpeech();
    }

    if (!_speechReady) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Voice search is unavailable on this device.'),
        ),
      );
      return;
    }

    if (_isListening) {
      _pendingVoiceSubmit = false;
      await _speech.stop();
      _closeSpeechDialog();
      if (!mounted) return;
      setState(() => _isListening = false);
      return;
    }

    final transcript = ValueNotifier<String>('Listening...');
    _activeTranscript = transcript;
    _showSpeechDialog(
      transcript: transcript,
      onSubmit: () {
        final spoken = transcript.value.trim();
        if (spoken.isEmpty || spoken == 'Listening...') return;
        _applyVoiceText(spoken);
        _pendingVoiceSubmit = false;
        _closeSpeechDialog();
      },
    );

    _pendingVoiceSubmit = true;
    await _speech.cancel();
    final started = await _speech.listen(
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.search,
        partialResults: true,
        cancelOnError: false,
      ),
      listenFor: const Duration(seconds: 20),
      pauseFor: const Duration(seconds: 5),
      localeId: _speechLocaleId,
      onResult: (result) {
        if (!mounted) return;
        final spoken = result.recognizedWords.trim();
        transcript.value = spoken.isEmpty ? 'Listening...' : spoken;
        _searchController
          ..text = spoken
          ..selection = TextSelection.fromPosition(
            TextPosition(offset: spoken.length),
          );
        setState(() => _searchQuery = spoken);
        if (result.finalResult && spoken.isNotEmpty) {
          _pendingVoiceSubmit = false;
          _closeSpeechDialog();
        }
      },
    );

    if (!started) {
      _pendingVoiceSubmit = false;
      _closeSpeechDialog();
      _activeTranscript = null;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not start voice input. Please try again.'),
        ),
      );
    }

    if (!mounted) return;
    setState(() => _isListening = started);
  }

  void _applyVoiceText(String spoken) {
    _searchController
      ..text = spoken
      ..selection = TextSelection.fromPosition(
        TextPosition(offset: spoken.length),
      );
    setState(() => _searchQuery = spoken);
  }

  void _closeSpeechDialog() {
    if (!_speechDialogVisible || !mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    _speechDialogVisible = false;
    _activeTranscript = null;
  }

  void _showSpeechDialog({
    required ValueNotifier<String> transcript,
    required VoidCallback onSubmit,
  }) {
    if (!mounted || _speechDialogVisible) return;
    _speechDialogVisible = true;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Voice search'),
          content: ValueListenableBuilder<String>(
            valueListenable: transcript,
            builder: (_, text, __) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _isListening ? Icons.mic : Icons.mic_none_rounded,
                        color: _isListening
                            ? AppColors.primary
                            : AppColors.textHint,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(_isListening ? 'Listening...' : 'Tap mic to speak'),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      text,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await _speech.stop();
                _closeSpeechDialog();
                if (!mounted) return;
                setState(() => _isListening = false);
              },
              child: const Text('Cancel'),
            ),
            FilledButton(onPressed: onSubmit, child: const Text('Use text')),
          ],
        );
      },
    ).whenComplete(() {
      _speechDialogVisible = false;
      _activeTranscript = null;
      transcript.dispose();
    });
  }

  String _baseProductId(String value) {
    final id = value.trim();
    if (id.isEmpty) return '';
    final sep = id.indexOf('::');
    if (sep <= 0) return id;
    return id.substring(0, sep);
  }

  Future<void> _resolvePurchasedProducts() async {
    final uid = fb_auth.FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty) {
      if (!mounted) return;
      setState(() => _purchasedProductIds = <String>{});
      return;
    }

    try {
      final purchased = await _firestoreService.getUserPurchasedProducts(
        uid: uid,
      );
      if (!mounted) return;
      setState(() {
        _purchasedProductIds = purchased
            .map((p) => _baseProductId((p['id'] ?? '').toString()))
            .where((id) => id.isNotEmpty)
            .toSet();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _purchasedProductIds = <String>{});
    }
  }

  String _normalized(String value) => value.trim().toLowerCase();

  bool _matchesQuery(String value, String query) {
    if (query.trim().isEmpty) return true;
    return _normalized(value).contains(_normalized(query));
  }

  List<_CategorySectionData> _buildSections(HomeProvider home) {
    final query = _searchQuery.trim();
    final sections = <_CategorySectionData>[];

    for (final category in home.categories) {
      final categoryName = (category['name'] ?? '').toString();
      if (categoryName.trim().isEmpty) continue;

      final allSubs = home.subCategoriesFor(categoryName);
      final categoryMatches = _matchesQuery(categoryName, query);

      if (allSubs.isEmpty) {
        continue;
      }

      final filteredSubs = categoryMatches
          ? allSubs
          : allSubs
                .where((sub) {
                  final subName = (sub['name'] ?? '').toString();
                  return _matchesQuery(subName, query);
                })
                .toList(growable: false);

      if (filteredSubs.isEmpty) continue;

      sections.add(
        _CategorySectionData(
          categoryName: categoryName,
          subCategories: filteredSubs,
          totalSubCategories: allSubs.length,
        ),
      );
    }

    sections.sort((a, b) {
      final aPreferred =
          _normalized(a.categoryName) == _normalized(_preferredCategory);
      final bPreferred =
          _normalized(b.categoryName) == _normalized(_preferredCategory);
      if (aPreferred == bPreferred) return 0;
      return aPreferred ? -1 : 1;
    });

    return sections;
  }

  void _openSubSubCategoryPage(String categoryName, String subCategoryName) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SubSubCategoryScreen(
          categoryName: categoryName,
          initialSubCategory: subCategoryName,
          purchasedProductIds: _purchasedProductIds,
        ),
      ),
    );
  }

  Future<void> _refreshCategories() async {
    final home = context.read<HomeProvider>();
    await home.loadData(forceRefresh: true);
    await home.ensureVisibilityCatalogLoaded();
  }

  @override
  Widget build(BuildContext context) {
    final home = context.watch<HomeProvider>();
    final sections = _buildSections(home);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFFB69DF8),
                Color(0xFFC4B5FD),
                Color(0xFFDDD6FE),
                Color(0xFFEDE9FE),
                Colors.white,
              ],
              stops: [0.0, 0.18, 0.42, 0.70, 1.0],
            ),
          ),
        ),
        title: const Text(
          'Categories',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
        ),
      ),
      body: SafeArea(
        child: home.loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                    child: Container(
                      height: 42,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE7EAF0)),
                      ),
                      child: TextField(
                        controller: _searchController,
                        onChanged: (v) => setState(() => _searchQuery = v),
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textPrimary,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Search category or sub-category',
                          hintStyle: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textHint,
                          ),
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 18,
                            color: AppColors.textHint,
                          ),
                          suffixIcon: IconButton(
                            onPressed: _toggleVoiceSearch,
                            icon: Icon(
                              _isListening ? Icons.mic : Icons.mic_none_rounded,
                              size: 18,
                              color: _isListening
                                  ? AppColors.primary
                                  : AppColors.textHint,
                            ),
                          ),
                          border: InputBorder.none,
                          isCollapsed: true,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _refreshCategories,
                      child: sections.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                40,
                                12,
                                110,
                              ),
                              children: const [
                                Center(
                                  child: Text(
                                    'No categories found',
                                    style: TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                4,
                                12,
                                110,
                              ),
                              itemCount: sections.length,
                              itemBuilder: (_, i) {
                                final section = sections[i];
                                return _CategorySection(
                                  section: section,
                                  expanded: _expandedCategories.contains(
                                    section.categoryName,
                                  ),
                                  onToggleExpanded: () {
                                    setState(() {
                                      if (_expandedCategories.contains(
                                        section.categoryName,
                                      )) {
                                        _expandedCategories.remove(
                                          section.categoryName,
                                        );
                                      } else {
                                        _expandedCategories.add(
                                          section.categoryName,
                                        );
                                      }
                                    });
                                  },
                                  onTapSubCategory: (subName) =>
                                      _openSubSubCategoryPage(
                                        section.categoryName,
                                        subName,
                                      ),
                                );
                              },
                            ),
                    ),
                  ),
                ],
              ),
      ),
      bottomNavigationBar: Consumer<CartModel>(
        builder: (context, cart, _) {
          if (cart.itemCount == 0) return const SizedBox.shrink();
          return const StickyCartBar();
        },
      ),
    );
  }
}

class _CategorySectionData {
  final String categoryName;
  final List<Map<String, dynamic>> subCategories;
  final int totalSubCategories;

  const _CategorySectionData({
    required this.categoryName,
    required this.subCategories,
    required this.totalSubCategories,
  });
}

class _CategorySection extends StatelessWidget {
  final _CategorySectionData section;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final ValueChanged<String> onTapSubCategory;

  const _CategorySection({
    required this.section,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onTapSubCategory,
  });

  @override
  Widget build(BuildContext context) {
    final maxCollapsedItems = 8;
    final shown = expanded
        ? section.subCategories
        : section.subCategories.take(maxCollapsedItems).toList(growable: false);
    final hasMore = section.totalSubCategories > maxCollapsedItems;
    final remainingCount = section.totalSubCategories - maxCollapsedItems;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF8F9EE),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              section.categoryName,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            if (shown.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(
                  'No sub-categories added yet.',
                  style: TextStyle(
                    color: AppColors.textHint,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              )
            else
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: shown.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.57,
                ),
                itemBuilder: (_, i) {
                  final sub = shown[i];
                  final name = (sub['name'] ?? '').toString();
                  return _SubCategoryMiniCard(
                    label: name,
                    iconPath: (sub['icon'] ?? sub['image'])?.toString(),
                    onTap: () => onTapSubCategory(name),
                  );
                },
              ),
            if (hasMore)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: GestureDetector(
                  onTap: onToggleExpanded,
                  child: Text(
                    expanded ? 'Show less' : '+$remainingCount more',
                    style: TextStyle(
                      color: expanded ? AppColors.primary : AppColors.textHint,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SubCategoryMiniCard extends StatelessWidget {
  final String label;
  final String? iconPath;
  final VoidCallback onTap;

  const _SubCategoryMiniCard({
    required this.label,
    required this.iconPath,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isLongLabel = label.trim().length > 20;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFFF2F4F6),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE1E5EA)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Container(
                  color: Colors.white,
                  child: Center(child: _CategoryIcon(iconPath: iconPath ?? '')),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 34,
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: isLongLabel ? 10.0 : 10.8,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryIcon extends StatelessWidget {
  final String iconPath;

  const _CategoryIcon({required this.iconPath});

  @override
  Widget build(BuildContext context) {
    const fallback = Icon(
      Icons.category_outlined,
      color: AppColors.textSecondary,
      size: 34,
    );

    final trimmed = iconPath.trim();
    if (trimmed.isEmpty) return fallback;

    if (trimmed.startsWith('assets/')) {
      return Image.asset(
        trimmed,
        width: 52,
        height: 52,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => fallback,
      );
    }

    return CachedNetworkImage(
      imageUrl: trimmed,
      width: 52,
      height: 52,
      fit: BoxFit.contain,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      memCacheWidth: 104,
      maxWidthDiskCache: 104,
      errorWidget: (_, __, ___) => fallback,
    );
  }
}
