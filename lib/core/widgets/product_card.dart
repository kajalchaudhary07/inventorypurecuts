import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'package:purecuts/core/services/firestore_service.dart';
import 'package:purecuts/core/services/image_bandwidth_telemetry.dart';
import 'package:purecuts/core/utils/product_image_contract.dart';
import 'package:purecuts/core/utils/tier_pricing.dart';
import 'package:purecuts/core/utils/variant_selection_guard.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/cart_model.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../../features/products/product_detail_screen.dart';
import '../../features/products/detail/product_models.dart';
import '../../features/products/product_list_screen.dart';

class ProductCard extends StatefulWidget {
  final Map<String, dynamic> product;
  final ValueChanged<Map<String, dynamic>>? onAddToCart;
  final bool showHeartIcon;
  final bool showBoughtEarlierBadge;
  final bool useFloatingVariantSnackbar;

  const ProductCard({
    super.key,
    required this.product,
    this.onAddToCart,
    this.showHeartIcon = true,
    this.showBoughtEarlierBadge = false,
    this.useFloatingVariantSnackbar = false,
  });

  @override
  State<ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends State<ProductCard> {
  static final Map<String, bool> _favoriteCache = <String, bool>{};
  static final Map<String, int> _variantCountCache = <String, int>{};
  static const String _contactPurchaseNumber = '+91 9579177826';

  final FirestoreService _firestoreService = FirestoreService();
  bool _isWishlisted = false;
  bool _wishlistLoading = false;
  bool _isOpeningVariantSheet = false;

  Map<String, dynamic> get product => widget.product;

  String _baseProductId(String value) {
    final id = value.trim();
    if (id.isEmpty) return '';
    final sep = id.indexOf('::');
    if (sep <= 0) return id;
    return id.substring(0, sep);
  }

  String _productId() {
    return _baseProductId((product['id'] ?? '').toString());
  }

  String _cacheKey(String uid, String productId) => '$uid::$productId';

  Map<String, dynamic> _favoriteSnapshot() {
    return {
      'name': (product['name'] ?? '').toString(),
      'brand': (product['brand'] ?? '').toString(),
      'image': resolveListImage(product),
      'price': product['price'],
      'originalPrice': product['originalPrice'],
      'category': (product['category'] ?? '').toString(),
      'rating': product['rating'],
      'reviews': product['reviews'],
      'tag': (product['tag'] ?? '').toString(),
    };
  }

  @override
  void initState() {
    super.initState();
    _loadWishlistState();
    _loadVariantCountIfNeeded();
  }

  Future<void> _loadVariantCountIfNeeded() async {
    if (!quickAddRequiresVariantSelection(product)) return;
    
    final baseId = _productId();
    if (baseId.isEmpty || _variantCountCache.containsKey(baseId)) return;
    
    try {
      final variants = await _resolveVariantsForQuickAdd();
      if (variants.isNotEmpty && mounted) {
        _variantCountCache[baseId] = variants.length;
        setState(() {});
      }
    } catch (_) {
      // Silently fail; default "Options" label will be shown
    }
  }

  @override
  void didUpdateWidget(covariant ProductCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = _baseProductId((oldWidget.product['id'] ?? '').toString());
    final newId = _productId();
    if (oldId != newId || oldWidget.showHeartIcon != widget.showHeartIcon) {
      _loadWishlistState();
    }
  }

  Future<void> _loadWishlistState() async {
    if (!widget.showHeartIcon) return;
    final uid = context.read<AuthProvider>().user?.uid ?? '';
    final productId = _productId();
    if (uid.isEmpty || productId.isEmpty) return;

    final key = _cacheKey(uid, productId);
    final cached = _favoriteCache[key];
    if (cached != null) {
      if (mounted) setState(() => _isWishlisted = cached);
      return;
    }

    try {
      final liked = await _firestoreService.isProductFavorited(
        uid: uid,
        productId: productId,
      );
      _favoriteCache[key] = liked;
      if (!mounted) return;
      setState(() => _isWishlisted = liked);
    } catch (_) {
      // Keep UI resilient; heart remains default state.
    }
  }

  Future<void> _toggleWishlist(BuildContext context) async {
    if (_wishlistLoading) return;

    final messenger = ScaffoldMessenger.of(context);
    final uid = context.read<AuthProvider>().user?.uid ?? '';
    final productId = _productId();

    if (uid.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Please sign in to save favourites.')),
      );
      return;
    }
    if (productId.isEmpty) return;

    final next = !_isWishlisted;
    final key = _cacheKey(uid, productId);

    setState(() {
      _isWishlisted = next;
      _wishlistLoading = true;
    });
    _favoriteCache[key] = next;

    try {
      await _firestoreService.setProductFavorited(
        uid: uid,
        productId: productId,
        isFavorited: next,
        productData: _favoriteSnapshot(),
      );
    } catch (_) {
      _favoriteCache[key] = !next;
      if (!mounted) return;
      setState(() => _isWishlisted = !next);
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not update favourite. Try again.')),
      );
    } finally {
      if (mounted) {
        setState(() => _wishlistLoading = false);
      }
    }
  }

  void _handleAddToCart(BuildContext context) {
    if (quickAddRequiresVariantSelection(product)) {
      unawaited(_openVariantQuickAddSheet());
      return;
    }

    if (_isOutOfStock) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This product is currently out of stock.'),
        ),
      );
      return;
    }

    final price = (product['price'] as num?)?.toInt() ?? 0;
    if (price <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Contact to purchase: $_contactPurchaseNumber')),
      );
      return;
    }

    if (widget.onAddToCart != null) {
      widget.onAddToCart!(product);
      return;
    }
    context.read<CartModel>().add(product);
  }

  bool _variantInStock(ProductVariant variant) {
    if (variant.hasExplicitStock) return variant.stock > 0;
    return !_isOutOfStock;
  }

  Future<List<ProductVariant>> _resolveVariantsForQuickAdd() async {
    final baseId = _productId();
    if (baseId.isEmpty) return const <ProductVariant>[];

    // Try inline variants first
    try {
      final inline = Product.fromMap(baseId, product).variants;
      if (inline.isNotEmpty) {
        _variantCountCache[baseId] = inline.length;
        if (mounted) setState(() {});
        return inline;
      }
    } catch (_) {}

    // Fallback to cached or fetch from Firestore
    try {
      final fetched = await _firestoreService.getProductVariants(baseId);
      _variantCountCache[baseId] = fetched.length;
      if (mounted) setState(() {});
      return fetched;
    } catch (_) {
      return const <ProductVariant>[];
    }
  }

  int _inlineVariantOptionsCount() {
    final baseId = _productId();
    
    // Check cache first
    if (_variantCountCache.containsKey(baseId)) {
      return _variantCountCache[baseId]!;
    }
    
    // Try to count from inline variants
    Iterable? raw;
    if (product['variants'] is Iterable && (product['variants'] as Iterable).isNotEmpty) {
      raw = product['variants'] as Iterable;
    } else if (product['productVariants'] is Iterable && (product['productVariants'] as Iterable).isNotEmpty) {
      raw = product['productVariants'] as Iterable;
    } else if (product['variantOptions'] is Iterable && (product['variantOptions'] as Iterable).isNotEmpty) {
      raw = product['variantOptions'] as Iterable;
    }
    
    if (raw != null) {
      int count = 0;
      for (final item in raw) {
        if (item == null) continue;
        if (item is Map && item.isNotEmpty) {
          count++;
        } else if (item is String && item.toString().trim().isNotEmpty) {
          count++;
        } else if (item is Iterable) {
          for (final inner in item) {
            if (inner == null) continue;
            if (inner is Map && inner.isNotEmpty) {
              count++;
            } else if (inner is String && inner.toString().trim().isNotEmpty) {
              count++;
            }
          }
        }
      }
      if (count > 0) return count;
    }
    
    // Check for variable options hint
    final varOptions = (product['variableOptions'] ?? '').toString().trim();
    if (varOptions.isNotEmpty) {
      // Try to parse if it's a count
      final parsed = int.tryParse(varOptions);
      if (parsed != null && parsed > 0) return parsed;
    }
    
    // Check for shadeCount or similar fields
    if (product['shadeCount'] is int && product['shadeCount'] > 0) {
      return product['shadeCount'] as int;
    }
    if (product['optionsCount'] is int && product['optionsCount'] > 0) {
      return product['optionsCount'] as int;
    }
    
    // Fallback: return 0 (will show "Options" instead of count)
    return 0;
  }

  Map<String, dynamic> _variantCartPayload(ProductVariant variant) {
    final baseId = _productId();
    final variantId = variant.id.trim();
    final label =
        (variant.shadeName.isNotEmpty ? variant.shadeName : variant.value)
            .trim();
    final baseName = (product['name'] ?? '').toString().trim();
    final name = label.isEmpty ? baseName : '$baseName • $label';
    final image = variant.image.trim().isNotEmpty
        ? variant.image.trim()
        : resolveListImage(product);
    final price = variant.price > 0
        ? variant.price
        : (product['price'] as num?)?.toInt() ?? 0;
    final basePrice = variant.price > 0
        ? variant.price
        : (product['basePrice'] as num?)?.toInt() ?? price;

    return {
      ...product,
      'id': variantId.isEmpty ? baseId : '$baseId::$variantId',
      'name': name,
      'image': image,
      'price': price,
      'basePrice': basePrice,
      'variantId': variantId,
      'variantName': label,
    };
  }

  Future<void> _openVariantQuickAddSheet() async {
    if (_isOpeningVariantSheet) return;
    _isOpeningVariantSheet = true;
    try {
      final variants = await _resolveVariantsForQuickAdd();
      if (!mounted) return;
      if (variants.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Options are loading. Please open product details.'),
          ),
        );
        _openProductDetail(context);
        return;
      }

      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (sheetCtx) {
          return FractionallySizedBox(
            heightFactor: 0.62,
            child: StatefulBuilder(
              builder: (ctx, setState) {
                final inset = MediaQuery.of(ctx).viewInsets.bottom;

                // Build image list from various product fields and dedupe.
                final images = <String>[];
                void push(dynamic node) {
                  if (node == null) return;
                  if (node is String) {
                    final s = node.trim();
                    if (s.isNotEmpty) images.add(s);
                    return;
                  }
                  if (node is Iterable) {
                    for (final it in node) {
                      if (it == null) continue;
                      final s = it.toString().trim();
                      if (s.isNotEmpty) images.add(s);
                    }
                  }
                }

                push(product['images']);
                push(product['additionalImages']);
                push(product['image']);
                push(product['imageUrl']);
                push(product['fullImageUrl']);
                if (images.isEmpty) images.add(resolveListImage(product));

                // Preserve order while removing duplicates
                final seen = <String>{};
                final imagesToShow = <String>[];
                for (final s in images) {
                  final t = s.trim();
                  if (t.isEmpty) continue;
                  if (seen.add(t)) imagesToShow.add(t);
                }
                if (imagesToShow.isEmpty) imagesToShow.add(resolveListImage(product));

                final pageController = PageController();
                var currentImage = 0;

                return Padding(
                  padding: EdgeInsets.only(bottom: inset),
                  child: Column(
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      const SizedBox(height: 2),
                      Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFFD5D9E4),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              (product['name'] ?? '').toString(),
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            SizedBox(
                              height: 160,
                              child: Stack(
                                children: [
                                  PageView.builder(
                                    controller: pageController,
                                    itemCount: imagesToShow.length,
                                    onPageChanged: (i) =>
                                        setState(() => currentImage = i),
                                    itemBuilder: (p, i) =>
                                        _buildProductImage(p, imagesToShow[i]),
                                  ),
                                  Positioned(
                                    left: 4,
                                    top: 0,
                                    bottom: 0,
                                    child: Center(
                                      child: IconButton(
                                        splashRadius: 18,
                                        onPressed: () {
                                          final page = (currentImage - 1).clamp(0, imagesToShow.length - 1);
                                          if (pageController.hasClients) {
                                            pageController.animateToPage(
                                              page,
                                              duration: const Duration(milliseconds: 250),
                                              curve: Curves.easeInOut,
                                            );
                                          }
                                        },
                                        icon: const Icon(
                                          Icons.chevron_left_rounded,
                                          color: Colors.black54,
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    right: 4,
                                    top: 0,
                                    bottom: 0,
                                    child: Center(
                                      child: IconButton(
                                        splashRadius: 18,
                                        onPressed: () {
                                          final page = (currentImage + 1).clamp(0, imagesToShow.length - 1);
                                          if (pageController.hasClients) {
                                            pageController.animateToPage(
                                              page,
                                              duration: const Duration(milliseconds: 250),
                                              curve: Curves.easeInOut,
                                            );
                                          }
                                        },
                                        icon: const Icon(
                                          Icons.chevron_right_rounded,
                                          color: Colors.black54,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 2),
                            // image page indicators removed per design
                            const SizedBox.shrink(),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            shrinkWrap: true,
                            itemCount: variants.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            padding: const EdgeInsets.only(top: 8, bottom: 16),
                            itemBuilder: (lCtx, idx) {
                              final v = variants[idx];
                              final inStock = _variantInStock(v);
                              final vImg = v.image.trim().isNotEmpty
                                  ? v.image.trim()
                                  : resolveListImage(product);
                              final vLabel =
                                  (v.shadeName.isNotEmpty
                                          ? v.shadeName
                                          : v.value)
                                      .trim();
                              final vPrice = v.price > 0
                                  ? v.price
                                  : (product['price'] as num?)?.toInt() ?? 0;
                              final vOriginal = v.regularPrice > 0
                                  ? v.regularPrice
                                  : (product['originalPrice'] as num?)
                                            ?.toInt() ??
                                        0;
                              final showOriginal =
                                  vOriginal > vPrice && vOriginal > 0;
                              final discount = showOriginal
                                  ? (((vOriginal - vPrice) / vOriginal) * 100)
                                        .round()
                                  : 0;

                              final payload = _variantCartPayload(v);

                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: const Color(0xFFE8EDF7),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.04),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: SizedBox(
                                        width: 56,
                                        height: 56,
                                        child: _buildProductImage(lCtx, vImg),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            vLabel,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: AppColors.textPrimary,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  vPrice > 0
                                                      ? '₹$vPrice'
                                                      : 'Price on request',
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: AppColors.textPrimary,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                              if (showOriginal)
                                                const SizedBox(width: 4),
                                              if (showOriginal)
                                                Flexible(
                                                  child: Text(
                                                    '₹$vOriginal',
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      color:
                                                          AppColors.textSecondary,
                                                      fontSize: 10,
                                                      decoration: TextDecoration
                                                          .lineThrough,
                                                      fontWeight: FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                              if (showOriginal)
                                                const SizedBox(width: 4),
                                              if (showOriginal)
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 4,
                                                        vertical: 2,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: AppColors.success
                                                        .withOpacity(0.12),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          6,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    '$discount%',
                                                    maxLines: 1,
                                                    style: const TextStyle(
                                                      color: AppColors.success,
                                                      fontSize: 10,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Consumer<CartModel>(
                                      builder: (cCtx, cart, _) {
                                        final q = cart.quantityOf(
                                          (payload['id'] ?? '').toString(),
                                        );
                                        if (!inStock) {
                                          return SizedBox(
                                            width: 44,
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 4,
                                                vertical: 0,
                                              ),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFD6D9E6),
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                              child: const Center(
                                                child: Text(
                                                  'OUT',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 9,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          );
                                        }
                                        if (q == 0) {
                                          return SizedBox(
                                            width: 44,
                                            child: ElevatedButton(
                                              onPressed: () => cart.add(payload),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor:
                                                    AppColors.primary,
                                                elevation: 0,
                                                padding: EdgeInsets.zero,
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                              ),
                                              child: const Text(
                                                'ADD',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 9,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                          );
                                        }
                                        return SizedBox(
                                          width: 56,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: AppColors.primary,
                                              borderRadius: BorderRadius.circular(
                                                6,
                                              ),
                                            ),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: IconButton(
                                                    onPressed: () => cart.remove(
                                                      (payload['id'] ?? '')
                                                          .toString(),
                                                    ),
                                                    icon: const Icon(
                                                      Icons.remove,
                                                      color: Colors.white,
                                                      size: 11,
                                                    ),
                                                    padding: EdgeInsets.zero,
                                                    iconSize: 11,
                                                  ),
                                                ),
                                                Text(
                                                  '$q',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.w600,
                                                    fontSize: 9,
                                                  ),
                                                ),
                                                Expanded(
                                                  child: IconButton(
                                                    onPressed: () =>
                                                        cart.add(payload),
                                                    icon: const Icon(
                                                      Icons.add,
                                                      color: Colors.white,
                                                      size: 11,
                                                    ),
                                                    padding: EdgeInsets.zero,
                                                    iconSize: 11,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      );
    } finally {
      _isOpeningVariantSheet = false;
    }
  }

  bool _boolFromDynamic(dynamic raw, {required bool fallback}) {
    if (raw is bool) return raw;
    final text = (raw ?? '').toString().trim().toLowerCase();
    if (text.isEmpty) return fallback;
    if (text == 'true' || text == '1' || text == 'yes' || text == 'on') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'no' || text == 'off') {
      return false;
    }
    return fallback;
  }

  int? _intFromDynamic(dynamic raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toInt();
    final text = raw.toString().trim();
    if (text.isEmpty) return null;
    return int.tryParse(text);
  }

  bool get _isOutOfStock {
    final manageStock = _boolFromDynamic(
      product['manageStock'],
      fallback: true,
    );
    if (!manageStock) return false;

    final stock = _intFromDynamic(
      product['stock'] ??
          product['quantity'] ??
          product['qty'] ??
          product['inventory'] ??
          product['stockCount'],
    );

    // If stock is missing, treat as available (legacy docs).
    if (stock == null) return false;
    return stock <= 0;
  }

  void _openProductDetail(BuildContext context) {
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProductDetailScreen(product: product)),
    );
  }

  void _openProductDetailForBulkOrder(BuildContext context) {
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ProductDetailScreen(product: product, autoOpenBulkOrderSheet: true),
      ),
    );
  }

  int? _bulkTriggerQty(Map<String, dynamic> p) {
    final basePrice = ((p['basePrice'] as num?) ?? (p['price'] as num?) ?? 0)
        .toInt();
    final tiers = parsePricingTiers(p['pricingTiers']);
    for (final tier in tiers) {
      if (tier.price < basePrice) return tier.minQty;
    }

    final variableTierMode = (p['variableTierMode'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (variableTierMode == 'universal') {
      final percentageTiers = parsePercentagePricingTiers(
        p['variableUniversalTiers'],
      );
      for (final tier in percentageTiers) {
        if (tier.percentOff > 0) return tier.minQty;
      }
    }

    return null;
  }

  void _openSimilarProducts(BuildContext context) {
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
    final tag = (product['tag'] ?? '').toString().trim();
    final brand = (product['brand'] ?? '').toString().trim();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProductListScreen(
          initialTag: tag.isNotEmpty ? tag : null,
          initialBrand: tag.isEmpty && brand.isNotEmpty ? brand : null,
        ),
      ),
    );
  }

  String _normalizeImagePath(String raw) {
    final path = raw.trim();
    if (path.isEmpty) return '';

    if (path.startsWith('http://') || path.startsWith('https://')) return path;

    if (path.startsWith('gs://')) {
      final withoutScheme = path.substring(5);
      final slash = withoutScheme.indexOf('/');
      if (slash <= 0 || slash == withoutScheme.length - 1) return path;
      final bucket = withoutScheme.substring(0, slash);
      final objectPath = withoutScheme.substring(slash + 1);
      return 'https://firebasestorage.googleapis.com/v0/b/$bucket/o/${Uri.encodeComponent(objectPath)}?alt=media';
    }

    if (path.startsWith('assets/')) return path;

    // Raw storage object path, e.g. "products/image.png"
    return 'https://firebasestorage.googleapis.com/v0/b/purecuts-11a7c.firebasestorage.app/o/${Uri.encodeComponent(path)}?alt=media';
  }

  Widget _buildProductImage(BuildContext context, String imagePath, {double? height}) {
    final resolved = _normalizeImagePath(imagePath);
    const defaultHeight = 110.0;
    final useHeight = height ?? defaultHeight;
    final targetHeight = (useHeight * MediaQuery.of(context).devicePixelRatio).round();
    if (resolved.isEmpty) {
      return Container(
        height: useHeight,
        color: AppColors.surface,
        child: const Icon(Icons.image, color: AppColors.textHint, size: 40),
      );
    }

    if (!resolved.startsWith('assets/')) {
      unawaited(
        ImageBandwidthTelemetry.instance.trackImageLoad(
          screen: 'product_card',
          imageUrl: resolved,
        ),
      );

      return CachedNetworkImage(
        imageUrl: resolved,
        height: useHeight,
        width: double.infinity,
        fit: BoxFit.contain,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        memCacheHeight: targetHeight,
        maxHeightDiskCache: targetHeight,
        placeholder: (_, __) => Container(
          height: useHeight,
          color: AppColors.surface,
          child: const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            ),
          ),
        ),
        errorWidget: (_, __, ___) => Container(
          height: useHeight,
          color: AppColors.surface,
          child: const Icon(Icons.image, color: AppColors.textHint, size: 40),
        ),
      );
    }

    return Image.asset(
      resolved,
      height: useHeight,
      width: double.infinity,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => Container(
        height: useHeight,
        color: AppColors.surface,
        child: const Icon(Icons.image, color: AppColors.textHint, size: 40),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final productId = (product['id'] ?? '').toString();
    final qty = context.select<CartModel, int>(
      (cart) => cart.quantityOf(productId),
    );
    final bulkTriggerQty = _bulkTriggerQty(product);
    final bulkReached =
        bulkTriggerQty != null && qty >= bulkTriggerQty && qty > 0;

    final int priceValue = (product['price'] as num?)?.toInt() ?? 0;
    final int originalPriceValue =
        (product['originalPrice'] as num?)?.toInt() ?? 0;
    final bool hasVisiblePrice = priceValue > 0;
    final bool hasVisibleDiscount =
        hasVisiblePrice && originalPriceValue > priceValue;

    return GestureDetector(
      onTap: () => _openProductDetail(context),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.divider.withOpacity(0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min, // ← key fix: don't expand unbounded
          children: [
            // ── Image area ───────────────────────────────────────────
            Stack(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(12),
                  ),
                  child: _buildProductImage(context, resolveListImage(product), height: 140),
                ),

                // Heart
                if (widget.showHeartIcon)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _toggleWishlist(context),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: _wishlistLoading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.8,
                                  color: AppColors.primary,
                                ),
                              )
                            : Icon(
                                _isWishlisted
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                size: 16,
                                color: _isWishlisted
                                    ? const Color(0xFFE53935)
                                    : AppColors.textHint,
                              ),
                      ),
                    ),
                  ),

                // Discount badge
                if (hasVisibleDiscount)
                  Positioned(
                    top: 6,
                    right: widget.showHeartIcon ? 30 : 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF3B30),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '-${(((product['originalPrice'] as num) - (product['price'] as num)) / (product['originalPrice'] as num) * 100).round()}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),

                if (_isOutOfStock)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE53935),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'Out of stock',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),

                // Bought earlier badge
                if (widget.showBoughtEarlierBadge)
                  Positioned(
                    top: _isOutOfStock ? 30 : 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.success,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'Bought earlier',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),

                // Size badge
                Positioned(
                  bottom: 6,
                  left: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.inventory_2_outlined,
                          size: 10,
                          color: AppColors.success,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          product['size'] ?? '100 g',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // ADD / stepper button
                Positioned(
                  bottom: 6,
                  right: 6,
                  child: _isOutOfStock
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE0E0E0),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: const Color(0xFFBDBDBD),
                              width: 1.2,
                            ),
                          ),
                          child: const Text(
                            'OUT',
                            style: TextStyle(
                              color: Color(0xFF757575),
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : qty == 0
                      ? GestureDetector(
                          onTap: () => _handleAddToCart(context),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: AppColors.primary,
                                width: 1.5,
                              ),
                            ),
                            child: Builder(builder: (ctx) {
                              final requiresVariant = quickAddRequiresVariantSelection(product);
                              final inlineCount = _inlineVariantOptionsCount();
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'ADD',
                                    style: TextStyle(
                                      color: AppColors.primary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (requiresVariant) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      inlineCount > 0
                                          ? '$inlineCount options'
                                          : 'Options',
                                      style: TextStyle(
                                        color: AppColors.success,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ],
                              );
                            }),
                          ),
                        )
                      : bulkReached
                      ? GestureDetector(
                          onTap: () => _openProductDetailForBulkOrder(context),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'BULK',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        )
                      : Container(
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              GestureDetector(
                                onTap: () =>
                                    context.read<CartModel>().remove(productId),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 4,
                                  ),
                                  child: Icon(
                                    Icons.remove,
                                    color: Colors.white,
                                    size: 14,
                                  ),
                                ),
                              ),
                              Text(
                                '$qty',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                              GestureDetector(
                                onTap: () {
                                  _handleAddToCart(context);
                                  if (bulkTriggerQty != null &&
                                      qty + 1 >= bulkTriggerQty) {
                                    _openProductDetailForBulkOrder(context);
                                  }
                                },
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 4,
                                  ),
                                  child: Icon(
                                    Icons.add,
                                    color: Colors.white,
                                    size: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ],
            ),

            // ── Product details ───────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Brand
                  Text(
                    product['brand'] ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),

                  // Name
                  Text(
                    product['name'] ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 4),

                  // Rating
                  Row(
                    children: [
                      Icon(Icons.star, color: AppColors.warning, size: 11),
                      const SizedBox(width: 2),
                      Text(
                        '${product['rating'] ?? ''}',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          '(${product['reviews'] ?? ''})',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textHint,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),

                  // Price row
                  if (hasVisiblePrice) ...[
                    Row(
                      children: [
                        Text(
                          '₹$priceValue',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 5),
                        if (hasVisibleDiscount)
                          Flexible(
                            child: Text(
                              '₹$originalPriceValue',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textHint,
                                fontSize: 10,
                                decoration: TextDecoration.lineThrough,
                                decorationColor: AppColors.textHint,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],

                  // See more
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openSimilarProducts(context),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'See more like this',
                          style: TextStyle(
                            fontSize: 10,
                            color: AppColors.success,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.arrow_forward_ios,
                          size: 8,
                          color: AppColors.success,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
