import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/core/models/cart_model.dart';
import 'package:purecuts/core/utils/tier_pricing.dart';
import 'package:purecuts/core/utils/variant_selection_guard.dart';
import 'package:purecuts/core/widgets/sticky_cart_bar.dart';

import 'package:purecuts/features/auth/providers/auth_provider.dart';
import 'package:purecuts/features/main_nav/main_nav_screen.dart';
import 'package:purecuts/features/orders/order_provider.dart';
import 'package:purecuts/features/products/product_detail_screen.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

class PreviouslyBoughtScreen extends StatefulWidget {
  const PreviouslyBoughtScreen({super.key});

  @override
  State<PreviouslyBoughtScreen> createState() => _PreviouslyBoughtScreenState();
}

class _PreviouslyBoughtScreenState extends State<PreviouslyBoughtScreen> {
  final TextEditingController _searchController = TextEditingController();
  final stt.SpeechToText _speech = stt.SpeechToText();
  String _search = '';
  String? _lastHydratedUid;
  bool _speechReady = false;
  bool _isListening = false;
  String? _speechLocaleId;
  bool _speechDialogVisible = false;
  ValueNotifier<String>? _activeTranscript;
  bool _pendingVoiceSearch = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      final value = _searchController.text;
      if (_search == value) return;
      setState(() => _search = value);
    });
    _initSpeech();
  }

  @override
  void dispose() {
    _speech.stop();
    _activeTranscript?.dispose();
    _searchController.dispose();
    super.dispose();
  }

  String _normalizeSearchText(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s,_-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  List<String> _productTags(Map<String, dynamic> product) {
    final tags = <String>{};

    final singleTag = (product['tag'] ?? '').toString().trim();
    if (singleTag.isNotEmpty) {
      tags.add(singleTag);
    }

    final rawTags = product['tags'];
    if (rawTags is List) {
      for (final item in rawTags) {
        final value = item.toString().trim();
        if (value.isNotEmpty) tags.add(value);
      }
    } else if (rawTags is String) {
      for (final item in rawTags.split(RegExp(r'[,|/&_-]+'))) {
        final value = item.trim();
        if (value.isNotEmpty) tags.add(value);
      }
    }

    return tags.toList(growable: false);
  }

  bool _matchesProductSearch(Map<String, dynamic> product, String query) {
    final normalizedQuery = _normalizeSearchText(query);
    if (normalizedQuery.isEmpty) return true;

    final searchable = _normalizeSearchText(
      [
        product['name'],
        product['brand'],
        product['category'],
        product['subCategory'] ?? product['subcategory'],
        product['subSubCategory'] ?? product['subsubCategory'],
        product['description'],
        ..._productTags(product),
      ].join(' '),
    );

    if (searchable.isEmpty) return false;
    if (searchable.contains(normalizedQuery)) return true;

    final tokens = normalizedQuery
        .split(' ')
        .where((token) => token.trim().isNotEmpty)
        .toList(growable: false);

    return tokens.every(searchable.contains);
  }

  String _speechErrorMessage(dynamic error) {
    final rawMsg = (error?.errorMsg ?? error?.toString() ?? '').toString();
    final msg = rawMsg.toLowerCase();
    if (msg.contains('no_match') ||
        msg.contains('no match') ||
        msg.contains('speech_timeout') ||
        msg.contains('speech timeout') ||
        msg.contains('aborted')) {
      return 'Didn\'t catch that. Try speaking clearly.';
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
        final normalized = status.toLowerCase();
        final listening = normalized.contains('listening');
        if (_isListening != listening) {
          setState(() => _isListening = listening);
        }
        if (!listening && _pendingVoiceSearch) {
          final spoken = (_activeTranscript?.value ?? '').trim();
          if (spoken.isNotEmpty &&
              spoken != 'Listening...' &&
              !spoken.startsWith('Didn\'t catch')) {
            _submitVoiceQuery(spoken);
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
        // Keep locale null to allow plugin default.
      }
    }

    if (!mounted) return;

    setState(() {
      _speechReady = available;
      if (!available) _isListening = false;
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
      _pendingVoiceSearch = false;
      await _speech.stop();
      _closeSpeechDialog();
      if (!mounted) return;
      setState(() => _isListening = false);
      return;
    }

    final transcript = ValueNotifier<String>('Listening...');
    _activeTranscript = transcript;
    _showSpeechDialog(
      title: 'Voice search',
      transcript: transcript,
      onSubmit: () {
        final spoken = transcript.value.trim();
        if (spoken.isEmpty || spoken == 'Listening...') return;
        _submitVoiceQuery(spoken);
      },
    );

    var launched = false;
    _pendingVoiceSearch = true;
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
        if (!mounted || launched) return;
        final spoken = result.recognizedWords.trim();
        transcript.value = spoken.isEmpty ? 'Listening...' : spoken;
        _searchController
          ..text = spoken
          ..selection = TextSelection.fromPosition(
            TextPosition(offset: spoken.length),
          );
        if (!result.finalResult || spoken.isEmpty) return;
        launched = true;
        _submitVoiceQuery(spoken);
      },
    );

    if (!started) {
      _pendingVoiceSearch = false;
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

  void _submitVoiceQuery(String spoken) {
    if (!_pendingVoiceSearch || !mounted) return;
    _pendingVoiceSearch = false;
    _closeSpeechDialog();
    _searchController
      ..text = spoken
      ..selection = TextSelection.fromPosition(
        TextPosition(offset: spoken.length),
      );
    setState(() => _isListening = false);
  }

  void _closeSpeechDialog() {
    if (!_speechDialogVisible || !mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    _speechDialogVisible = false;
    _activeTranscript = null;
  }

  void _showSpeechDialog({
    required String title,
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
          title: Text(title),
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
                _pendingVoiceSearch = false;
                _closeSpeechDialog();
                if (!mounted) return;
                setState(() => _isListening = false);
              },
              child: const Text('Cancel'),
            ),
            FilledButton(onPressed: onSubmit, child: const Text('Search')),
          ],
        );
      },
    ).whenComplete(() {
      _speechDialogVisible = false;
      _activeTranscript = null;
      transcript.dispose();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uid = Provider.of<AuthProvider>(context).user?.uid ?? '';
    if (uid == _lastHydratedUid) return;
    _lastHydratedUid = uid;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final orders = context.read<OrderProvider>();
      if (uid.trim().isEmpty) {
        orders.clear();
      } else {
        orders.loadPurchasedProducts(uid: uid, forceRefresh: true);
      }
    });
  }

  void _goToShop() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }

    navigator.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const MainNavScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final orderProvider = context.watch<OrderProvider>();
    final allBought = orderProvider.boughtProducts;

    final products = _search.isEmpty
        ? allBought
        : allBought.where((p) => _matchesProductSearch(p, _search)).toList();

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          // Lavender gradient covering the top area
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 200,
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
          ),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(allBought.length),
                if (allBought.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildSearchBar(),
                  const SizedBox(height: 8),
                ],
                Expanded(
                  child: orderProvider.isLoading && allBought.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : allBought.isEmpty
                      ? _buildNeverOrdered(context)
                      : products.isEmpty
                      ? _buildEmpty()
                      : _buildList(products),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: Consumer<CartModel>(
        builder: (context, cart, _) {
          if (cart.itemCount == 0) return const SizedBox.shrink();
          return const StickyCartBar();
        },
      ),
    );
  }

  Widget _buildHeader(int total) {
    return Container(
      color: Colors.transparent,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.10),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.history_rounded,
              color: AppColors.primary,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Order Again',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
              Text(
                total == 0
                    ? 'No purchases yet'
                    : '$total item${total > 1 ? 's' : ''} you\'ve ordered before',
                style: const TextStyle(
                  color: AppColors.textHint,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(12),
        ),
        child: TextField(
          controller: _searchController,
          style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: 'Search your past purchases...',
            hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 13),
            prefixIcon: const Icon(
              Icons.search,
              color: AppColors.textHint,
              size: 18,
            ),
            suffixIcon: IconButton(
              onPressed: _toggleVoiceSearch,
              icon: Icon(
                _isListening ? Icons.mic : Icons.mic_none_rounded,
                color: _isListening ? AppColors.primary : AppColors.textHint,
                size: 20,
              ),
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
    );
  }

  /// Shown when the user has NEVER placed any order
  Widget _buildNeverOrdered(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.shopping_bag_outlined,
                color: AppColors.primary,
                size: 44,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'No purchases yet',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Items you order will appear here so you can quickly reorder them.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textHint,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 28),
            GestureDetector(
              onTap: _goToShop,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withOpacity(0.30),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.storefront_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Place your order from here',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Shown when the user has orders but search returns nothing
  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.search_off_rounded,
              color: AppColors.primary,
              size: 36,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'No results found',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Try a different search term',
            style: TextStyle(color: AppColors.textHint, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<Map<String, dynamic>> products) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: products.length,
      itemBuilder: (context, i) => _BoughtItem(product: products[i]),
    );
  }
}

class _BoughtItem extends StatelessWidget {
  static const String _contactPurchaseNumber = '+91 9579177826';

  final Map<String, dynamic> product;
  const _BoughtItem({required this.product});
  int? _bulkTriggerQty(Map<String, dynamic> product) {
    final basePrice =
        ((product['basePrice'] as num?) ?? (product['price'] as num?) ?? 0)
            .toInt();
    final tiers = parsePricingTiers(product['pricingTiers']);
    for (final tier in tiers) {
      if (tier.price < basePrice) return tier.minQty;
    }

    final variableTierMode = (product['variableTierMode'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (variableTierMode == 'universal') {
      final percentageTiers = parsePercentagePricingTiers(
        product['variableUniversalTiers'],
      );
      for (final tier in percentageTiers) {
        if (tier.percentOff > 0) return tier.minQty;
      }
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = product['image'] as String? ?? '';
    final name = product['name'] as String? ?? 'Product';
    final brand = product['brand'] as String? ?? '';
    final price = (product['price'] as num?)?.toInt() ?? 0;
    final hasVisiblePrice = price > 0;
    final id = product['id'] as String? ?? '';
    void showContactMessage() {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Contact to purchase: $_contactPurchaseNumber')),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ProductDetailScreen(product: product),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: imageUrl.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: imageUrl,
                            fit: BoxFit.contain,
                            fadeInDuration: Duration.zero,
                            fadeOutDuration: Duration.zero,
                            memCacheWidth: 136,
                            maxWidthDiskCache: 136,
                            errorWidget: (_, __, ___) => const Icon(
                              Icons.image_outlined,
                              color: AppColors.textHint,
                            ),
                          )
                        : const Icon(
                            Icons.image_outlined,
                            color: AppColors.textHint,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                      if (brand.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          brand,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textHint,
                            fontSize: 11,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      if (hasVisiblePrice)
                        Text(
                          '₹$price',
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Consumer<CartModel>(
                  builder: (context, cart, _) {
                    final qty = id.isEmpty ? 0 : cart.quantityOf(id);
                    final bulkTriggerQty = _bulkTriggerQty(product);
                    final bulkReached =
                        bulkTriggerQty != null &&
                        qty >= bulkTriggerQty &&
                        qty > 0;

                    if (qty == 0) {
                      return _AddButton(
                        onTap: () {
                          if (price <= 0) {
                            showContactMessage();
                            return;
                          }
                          final payload = {
                            'id': id,
                            'name': name,
                            'brand': brand,
                            'image': imageUrl,
                            'price': price,
                            'productType':
                                product['productType'] ?? product['type'],
                            'variants': product['variants'],
                            'variableOptions': product['variableOptions'],
                          };
                          if (!ensureVariantSelectedBeforeQuickAdd(
                            context,
                            payload,
                          )) {
                            return;
                          }
                          context.read<CartModel>().add(payload);
                        },
                      );
                    }

                    if (bulkReached) {
                      return _AddButton(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ProductDetailScreen(
                                product: product,
                                autoOpenBulkOrderSheet: true,
                              ),
                            ),
                          );
                        },
                        label: 'Bulk',
                      );
                    }

                    return _QtyControl(
                      qty: qty,
                      onMinus: () => context.read<CartModel>().remove(id),
                      onPlus: () {
                        if (price <= 0) {
                          showContactMessage();
                          return;
                        }
                        final payload = {
                          'id': id,
                          'name': name,
                          'brand': brand,
                          'image': imageUrl,
                          'price': price,
                          'productType':
                              product['productType'] ?? product['type'],
                          'variants': product['variants'],
                          'variableOptions': product['variableOptions'],
                        };
                        if (!ensureVariantSelectedBeforeQuickAdd(
                          context,
                          payload,
                        )) {
                          return;
                        }
                        context.read<CartModel>().add(payload);
                        if (bulkTriggerQty != null &&
                            qty + 1 >= bulkTriggerQty) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ProductDetailScreen(
                                product: product,
                                autoOpenBulkOrderSheet: true,
                              ),
                            ),
                          );
                        }
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  final VoidCallback onTap;
  final String label;
  const _AddButton({required this.onTap, this.label = 'Add'});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _QtyControl extends StatelessWidget {
  final int qty;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  const _QtyControl({
    required this.qty,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: onMinus,
            child: const SizedBox(
              width: 32,
              height: 34,
              child: Icon(
                Icons.remove_rounded,
                color: AppColors.textSecondary,
                size: 16,
              ),
            ),
          ),
          SizedBox(
            width: 28,
            child: Text(
              '$qty',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
          GestureDetector(
            onTap: onPlus,
            child: const SizedBox(
              width: 32,
              height: 34,
              child: Icon(
                Icons.add_rounded,
                color: AppColors.textSecondary,
                size: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
