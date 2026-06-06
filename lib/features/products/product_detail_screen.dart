import 'dart:typed_data';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/models/cart_model.dart';
import 'package:purecuts/core/services/image_bandwidth_telemetry.dart';
import 'package:purecuts/core/services/deep_link_service.dart';
import 'package:purecuts/core/services/firestore_service.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/core/widgets/product_card.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';
import 'package:purecuts/features/home/home_provider.dart';
import 'package:purecuts/features/orders/checkout_screen.dart';
import 'package:purecuts/features/orders/order_provider.dart';
import 'package:purecuts/features/products/detail/product_models.dart';
import 'package:purecuts/features/products/detail/product_repository.dart';
import 'package:purecuts/features/products/product_list_screen.dart';
import 'package:purecuts/features/support_chat/widgets/support_chat_fab.dart';
import 'package:purecuts/core/utils/tier_pricing.dart';
import 'package:share_plus/share_plus.dart';

class ProductDetailScreen extends StatefulWidget {
  final Map<String, dynamic> product;
  final bool autoOpenBulkOrderSheet;

  const ProductDetailScreen({
    super.key,
    required this.product,
    this.autoOpenBulkOrderSheet = false,
  });

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  final ProductRepository _repository = ProductRepository();
  final FirestoreService _firestoreService = FirestoreService();
  final ImagePicker _imagePicker = ImagePicker();
  final PageController _pageController = PageController();
  final ScrollController _contentScrollController = ScrollController();
  final Map<int, bool> _detailsExpandedByTab = {0: false, 1: false, 2: false};
  ProductState? _productState;
  int _selectedDetailsTab = 0;
  bool _loadingDetail = false;
  bool _isWishlisted = false;
  bool _wishlistActionInProgress = false;
  bool _checkingReviewEligibility = false;
  bool _canReview = false;
  bool _submittingReview = false;
  late final ConfettiController _tierConfettiController;
  bool _showBulkHint = false;
  bool _hasShownBulkHintOnce = false;
  int _bulkHintMessageIndex = 0;
  String? _bulkConfirmedCartItemId;
  int _bulkConfirmedQty = 0;
  Map<String, dynamic> _resolvedProductMap = <String, dynamic>{};
  bool _didAutoOpenBulkOrderSheet = false;
  Timer? _bulkHintHideTimer;
  Timer? _bulkHintRotateTimer;

  static const List<String> _bulkHintMessages = [
    'Buy in bulk to unlock discount 💜',
    'Add more, pay less per piece ✨',
    'Smart buy: bigger qty, better price 🔥',
  ];

  String get _currentUserId => context.read<AuthProvider>().user?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _resolvedProductMap = Map<String, dynamic>.from(widget.product);
    _tierConfettiController = ConfettiController(
      duration: const Duration(milliseconds: 800),
    );
    _productState = ProductState(product: _fallbackProduct(widget.product));
    _productState!.addListener(_onProductStateChanged);
    _loadWishlistState();
    _checkReviewEligibility();
    _loadProductDetail();
  }

  @override
  void dispose() {
    _productState?.removeListener(_onProductStateChanged);
    _productState?.dispose();
    _pageController.dispose();
    _contentScrollController.dispose();
    _tierConfettiController.dispose();
    _bulkHintHideTimer?.cancel();
    _bulkHintRotateTimer?.cancel();
    super.dispose();
  }

  void _scrollToImageSection() {
    if (!_contentScrollController.hasClients) return;
    if (_contentScrollController.offset <= 32) return;

    _contentScrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _syncCarouselToSelectedImage() {
    final targetIndex = _productState?.selectedImageIndex ?? 0;
    if (!_pageController.hasClients) return;

    final currentPage = _pageController.page;
    final roundedCurrent = currentPage == null ? 0 : currentPage.round();
    if (roundedCurrent == targetIndex) return;

    _pageController.animateToPage(
      targetIndex,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _onProductStateChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncCarouselToSelectedImage();
      _scrollToImageSection();
    });
  }

  void _onVariantSelected(ProductVariant variant) {
    _productState?.selectVariant(variant);
    _scrollToImageSection();
  }

  Product _fallbackProduct(Map<String, dynamic> raw) {
    final id = (raw['id'] ?? '').toString();
    return Product.fromMap(id, raw);
  }

  Future<void> _loadProductDetail() async {
    final productId = (widget.product['id'] ?? '').toString().trim();
    if (productId.isEmpty) return;
    final uid = _currentUserId;
    final rawType = (widget.product['productType'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final allowVariantFallback = rawType.isEmpty || rawType == 'variable';
    setState(() => _loadingDetail = true);
    try {
      var product = await _repository.getProductById(
        productId,
        currentUserId: uid,
      );

      try {
        final doc = await FirebaseFirestore.instance
            .collection('products')
            .doc(productId)
            .get();
        final data = doc.data();
        if (mounted && data != null) {
          setState(() {
            _resolvedProductMap = {
              ..._resolvedProductMap,
              ...data,
              'id': productId,
            };
          });
        }
      } catch (_) {
        // Keep PDP resilient when metadata refresh fails.
      }

      if (allowVariantFallback && product.variants.isEmpty) {
        try {
          final fallbackVariants = await _firestoreService.getProductVariants(
            productId,
          );
          if (fallbackVariants.isNotEmpty) {
            product = Product(
              id: product.id,
              name: product.name,
              brand: product.brand,
              description: product.description,
              images: product.images,
              variants: fallbackVariants,
              rating: product.rating,
              reviewCount: product.reviewCount,
              reviews: product.reviews,
            );
          }
        } catch (e) {}
      }

      if (!mounted || _productState == null) return;
      _productState!.replaceProduct(product);
      _migrateBaseCartQuantityToSelectedVariantIfNeeded();
      _maybeAutoOpenBulkOrderSheet();
    } catch (e) {
    } finally {
      if (mounted) setState(() => _loadingDetail = false);
    }
  }

  void _migrateBaseCartQuantityToSelectedVariantIfNeeded() {
    if (!mounted) return;

    final selectedCartId = _cartItemId;
    final baseId = _baseProductId(selectedCartId);
    if (selectedCartId.isEmpty || baseId.isEmpty || selectedCartId == baseId) {
      return;
    }

    final cart = context.read<CartModel>();
    final variantQty = cart.quantityOf(selectedCartId);
    if (variantQty > 0) return;

    final baseQty = cart.quantityOf(baseId);
    if (baseQty <= 0) return;

    cart.setQuantity(_cartPayload, baseQty);
    cart.setQuantity({'id': baseId}, 0);
  }

  void _maybeAutoOpenBulkOrderSheet() {
    if (!widget.autoOpenBulkOrderSheet) return;
    if (_didAutoOpenBulkOrderSheet) return;
    if (!_hasTierPricing) return;

    _didAutoOpenBulkOrderSheet = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _onBulkOrderPressed();
    });
  }

  Product get _product => _productState!.product;
  ProductVariant? get _selectedVariant => _productState!.selectedVariant;

  String get _productId {
    final idFromState = _product.id.trim();
    if (idFromState.isNotEmpty) return idFromState;
    return (widget.product['id'] ?? '').toString().trim();
  }

  Future<void> _loadWishlistState() async {
    final uid = context.read<AuthProvider>().user?.uid ?? '';
    final productId = _productId;
    if (uid.isEmpty || productId.isEmpty) return;

    try {
      final liked = await _firestoreService.isProductFavorited(
        uid: uid,
        productId: productId,
      );
      if (!mounted) return;
      setState(() => _isWishlisted = liked);
    } catch (e) {
      // Keep UI resilient even if this request fails.
    }
  }

  Map<String, dynamic> _favoriteSnapshot() {
    return {
      'name': _product.name,
      'brand': _product.brand,
      'image': _displayImage,
      'price': _currentPrice,
      'category': (_resolvedProductMap['category'] ?? '').toString(),
    };
  }

  Future<void> _toggleWishlist() async {
    if (_wishlistActionInProgress) return;

    final messenger = ScaffoldMessenger.of(context);
    final uid = context.read<AuthProvider>().user?.uid ?? '';
    final productId = _productId;
    if (uid.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Please sign in to save favourites.')),
      );
      return;
    }
    if (productId.isEmpty) return;

    final nextValue = !_isWishlisted;
    setState(() {
      _isWishlisted = nextValue;
      _wishlistActionInProgress = true;
    });

    try {
      await _firestoreService.setProductFavorited(
        uid: uid,
        productId: productId,
        isFavorited: nextValue,
        productData: _favoriteSnapshot(),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isWishlisted = !nextValue);
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not update favourite. Try again.')),
      );
    } finally {
      if (mounted) {
        setState(() => _wishlistActionInProgress = false);
      }
    }
  }

  Future<void> _shareProduct() async {
    final messenger = ScaffoldMessenger.of(context);
    final productId = _productId.trim();
    if (productId.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Product link is not ready yet.')),
      );
      return;
    }

    try {
      final shareUri = DeepLinkService.buildProductShareUri(productId);
      final productName = _product.name.trim();
      final message = productName.isNotEmpty
          ? '$productName\n\nCheck this out on PureCuts:\n$shareUri'
          : 'Check this product on PureCuts:\n$shareUri';
      await Share.share(
        message,
        subject: productName.isEmpty ? 'PureCuts Product' : productName,
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open share options.')),
      );
    }
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
    return 'https://firebasestorage.googleapis.com/v0/b/purecuts-11a7c.firebasestorage.app/o/${Uri.encodeComponent(path)}?alt=media';
  }

  Widget _buildImage(String imagePath, {BoxFit fit = BoxFit.contain}) {
    final resolved = _normalizeImagePath(imagePath);
    Widget placeholder() {
      return LayoutBuilder(
        builder: (context, constraints) {
          final shortest = constraints.biggest.shortestSide;
          final iconSize = shortest.isFinite
              ? (shortest * 0.34).clamp(14.0, 56.0)
              : 36.0;
          final spinnerSize = shortest.isFinite
              ? (shortest * 0.22).clamp(10.0, 20.0)
              : 14.0;

          return DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFF6F5FA), Color(0xFFEFEDF6)],
              ),
            ),
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.image_outlined,
                    size: iconSize,
                    color: const Color(0xFFC9C6D6),
                  ),
                  SizedBox(
                    width: spinnerSize,
                    height: spinnerSize,
                    child: const CircularProgressIndicator(strokeWidth: 1.8),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    if (resolved.isEmpty) return placeholder();
    if (resolved.startsWith('assets/')) {
      return Image.asset(
        resolved,
        fit: fit,
        errorBuilder: (_, __, ___) => placeholder(),
      );
    }

    unawaited(
      ImageBandwidthTelemetry.instance.trackImageLoad(
        screen: 'product_detail',
        imageUrl: resolved,
      ),
    );

    return CachedNetworkImage(
      imageUrl: resolved,
      fit: fit,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (_, __) => placeholder(),
      errorWidget: (_, __, ___) => placeholder(),
    );
  }

  String _normalizeKey(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  String _variantLabel(ProductVariant variant) {
    final shade = variant.shadeName.trim();
    if (shade.isNotEmpty) return shade;
    final value = variant.value.trim();
    if (value.isNotEmpty) return value;
    return 'Variant';
  }

  bool _isColorVariant(ProductVariant variant) {
    final attributeKey = _normalizeKey(variant.attribute);
    final isColorAttribute =
        attributeKey.contains('color') ||
        attributeKey.contains('shade') ||
        attributeKey.contains('tone');

    final raw = variant.colorCode.trim().toLowerCase();
    final hasExplicitColorCode =
        raw.isNotEmpty &&
        raw != '#cbd5e1' &&
        raw != '0xffcbd5e1' &&
        raw != 'cbd5e1' &&
        raw != 'ff_cbd5e1';

    return isColorAttribute && hasExplicitColorCode;
  }

  String _humanizeLabel(String raw) {
    final text = raw
        .trim()
        .replaceAll(RegExp(r'[_\-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) return '';

    final words = text
        .split(' ')
        .where((w) => w.trim().isNotEmpty)
        .map((word) {
          final trimmed = word.trim();
          if (trimmed.isEmpty) return '';
          if (trimmed.length == 1) return trimmed.toUpperCase();
          return '${trimmed[0].toUpperCase()}${trimmed.substring(1)}';
        })
        .where((w) => w.isNotEmpty)
        .toList();

    return words.join(' ');
  }

  String _variantSectionTitle(List<ProductVariant> variants) {
    final dashboardTitle = (widget.product['variableOptions'] ?? '')
        .toString()
        .trim();
    if (dashboardTitle.isNotEmpty) return dashboardTitle;

    if (variants.isEmpty) return 'Choose Option';

    final rawAttr = variants
        .map((v) => v.attribute.trim())
        .firstWhere((attr) => attr.isNotEmpty, orElse: () => '');

    final humanized = _humanizeLabel(rawAttr);
    if (humanized.isNotEmpty) return humanized;

    return 'Choose Option';
  }

  Widget _buildVariantOptionTile(
    ProductVariant variant,
    bool isSelected, {
    required bool compactMode,
    required VoidCallback onSelect,
  }) {
    final label = _variantLabel(variant);
    final isColor = _isColorVariant(variant);
    const selectedSurface = Color(0xFFF3ECFF);
    const unselectedSurface = Color(0xFFF8F9FC);
    const selectedBorder = AppColors.primary;
    const unselectedBorder = Color(0xFFDDE2EE);
    const selectedText = Color(0xFF4B1FA8);
    const unselectedText = Color(0xFF5A6272);

    if (isColor) {
      return GestureDetector(
        onTap: onSelect,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: compactMode ? 34 : 30,
                height: compactMode ? 34 : 30,
                decoration: BoxDecoration(
                  color: variant.color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected
                        ? AppColors.primary
                        : const Color(0xFFD9D9E3),
                    width: isSelected ? 2.5 : 1,
                  ),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: AppColors.primary.withOpacity(0.2),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: compactMode ? 88 : double.infinity,
                child: Text(
                  label,
                  maxLines: compactMode ? 1 : 2,
                  overflow: compactMode
                      ? TextOverflow.ellipsis
                      : TextOverflow.clip,
                  softWrap: !compactMode,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isSelected
                        ? AppColors.primary
                        : AppColors.textSecondary,
                    fontSize: compactMode ? 12 : 11,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: onSelect,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        alignment: Alignment.center,
        constraints: compactMode
            ? const BoxConstraints(minWidth: 72, maxWidth: 104)
            : const BoxConstraints(minWidth: 0),
        padding: EdgeInsets.symmetric(
          horizontal: compactMode ? 10 : 8,
          vertical: compactMode ? 8 : 8,
        ),
        decoration: BoxDecoration(
          color: isSelected ? selectedSurface : unselectedSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? selectedBorder : unselectedBorder,
            width: isSelected ? 1.8 : 1,
          ),
          boxShadow: isSelected
              ? const [
                  BoxShadow(
                    color: Color(0x1A7C3AED),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          maxLines: compactMode ? 1 : 2,
          overflow: compactMode ? TextOverflow.ellipsis : TextOverflow.clip,
          softWrap: !compactMode,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isSelected ? selectedText : unselectedText,
            fontSize: compactMode ? 12 : 12,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
            letterSpacing: 0.1,
          ),
        ),
      ),
    );
  }

  String _resolveBrandLogo(HomeProvider home, String brandName) {
    final normalizedBrand = _normalizeKey(brandName);
    if (normalizedBrand.isEmpty) return '';

    for (final brand in home.brands) {
      final candidateName = (brand['name'] ?? '').toString();
      if (_normalizeKey(candidateName) == normalizedBrand) {
        final logo = (brand['image'] ?? brand['logo'] ?? brand['icon'] ?? '')
            .toString()
            .trim();
        if (logo.isNotEmpty) return logo;
      }
    }

    return '';
  }

  Widget _buildBrandLogo(String imagePath) {
    final resolved = _normalizeImagePath(imagePath);
    final placeholder = Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: const Color(0xFFF2F2F7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(
        Icons.storefront_outlined,
        size: 22,
        color: AppColors.textHint,
      ),
    );

    if (resolved.isEmpty) return placeholder;

    final imageWidget = resolved.startsWith('assets/')
        ? Image.asset(
            resolved,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => placeholder,
          )
        : CachedNetworkImage(
            imageUrl: resolved,
            fit: BoxFit.cover,
            fadeInDuration: Duration.zero,
            fadeOutDuration: Duration.zero,
            memCacheWidth: 92,
            maxWidthDiskCache: 92,
            errorWidget: (_, __, ___) => placeholder,
          );

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(width: 46, height: 46, child: imageWidget),
    );
  }

  List<String> _toCleanList(dynamic raw) {
    if (raw == null) return const [];

    if (raw is List) {
      return raw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }

    final text = raw.toString().trim();
    if (text.isEmpty) return const [];

    final parts = text
        .split(RegExp(r'\n|•|\||;'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    return parts.isNotEmpty ? parts : [text];
  }

  List<String> _extractHighlights() {
    final candidates = [
      widget.product['highlights'],
      widget.product['highlight'],
      widget.product['keyHighlights'],
      widget.product['features'],
      widget.product['benefits'],
    ];

    for (final candidate in candidates) {
      final items = _toCleanList(candidate);
      if (items.isNotEmpty) return items;
    }
    return const [];
  }

  List<String> _extractHowToUse() {
    final candidates = [
      widget.product['howToUse'],
      widget.product['how_to_use'],
      widget.product['usage'],
      widget.product['directions'],
      widget.product['instructions'],
    ];

    for (final candidate in candidates) {
      final items = _toCleanList(candidate);
      if (items.isNotEmpty) return items;
    }
    return const [];
  }

  bool _isLikelyImageUrl(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    if (!(v.startsWith('http://') || v.startsWith('https://'))) return false;

    final lower = v.toLowerCase();
    final hasImageExt = RegExp(
      r'\.(png|jpe?g|webp|gif|bmp|heic)(\?|#|$)',
      caseSensitive: false,
    ).hasMatch(lower);

    return hasImageExt || lower.contains('firebasestorage.googleapis.com');
  }

  Widget _buildDescriptionImage(String imageUrl) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: double.infinity,
          height: 180,
          child: _buildImage(imageUrl, fit: BoxFit.cover),
        ),
      ),
    );
  }

  Widget _buildRichDescription(String rawText) {
    final content = rawText.trim();
    if (content.isEmpty) {
      return const Text(
        'No description available for this product.',
        style: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 15,
          height: 1.42,
        ),
      );
    }

    final imageTagRegex = RegExp(
      r'!\[[^\]]*\]\((https?:\/\/[^\s)]+)\)',
      caseSensitive: false,
      multiLine: true,
    );

    final widgets = <Widget>[];

    void addChunk(String chunk) {
      final lines = chunk.split('\n').map((line) => line.trimRight()).toList();
      final textLines = <String>[];

      void flushText() {
        final text = textLines.join('\n').trim();
        if (text.isEmpty) return;
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              text,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15,
                height: 1.42,
              ),
            ),
          ),
        );
        textLines.clear();
      }

      for (final line in lines) {
        final trimmed = line.trim();
        if (_isLikelyImageUrl(trimmed)) {
          flushText();
          widgets.add(_buildDescriptionImage(trimmed));
          continue;
        }
        textLines.add(line);
      }
      flushText();
    }

    var cursor = 0;
    for (final match in imageTagRegex.allMatches(content)) {
      final before = content.substring(cursor, match.start);
      addChunk(before);

      final imageUrl = (match.group(1) ?? '').trim();
      if (imageUrl.isNotEmpty) {
        widgets.add(_buildDescriptionImage(imageUrl));
      }

      cursor = match.end;
    }

    if (cursor < content.length) {
      addChunk(content.substring(cursor));
    }

    if (widgets.isEmpty) {
      addChunk(content);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  bool _isTabExpanded(int tabIndex) => _detailsExpandedByTab[tabIndex] ?? false;

  void _toggleTabExpanded(int tabIndex) {
    setState(() {
      _detailsExpandedByTab[tabIndex] = !_isTabExpanded(tabIndex);
    });
  }

  void _setDetailsTab(int tabIndex) {
    if (tabIndex < 0 || tabIndex > 2) return;
    setState(() => _selectedDetailsTab = tabIndex);
  }

  void _onDetailsHorizontalSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -120 && _selectedDetailsTab < 2) {
      _setDetailsTab(_selectedDetailsTab + 1);
      return;
    }
    if (velocity > 120 && _selectedDetailsTab > 0) {
      _setDetailsTab(_selectedDetailsTab - 1);
    }
  }

  Future<void> _checkReviewEligibility() async {
    final uid = context.read<AuthProvider>().user?.uid ?? '';
    final productId = _productId;
    final localOrderProvider = context.read<OrderProvider>();
    final localBought =
        localOrderProvider.hasBought(productId) ||
        localOrderProvider.hasBought(_baseProductId(productId));

    if (localBought) {
      if (!mounted) return;
      setState(() {
        _canReview = true;
        _checkingReviewEligibility = false;
      });
      return;
    }

    if (uid.isEmpty || productId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _canReview = false;
        _checkingReviewEligibility = false;
      });
      return;
    }

    setState(() => _checkingReviewEligibility = true);
    try {
      final allowed = await _firestoreService.hasUserPurchasedProduct(
        uid: uid,
        productId: productId,
      );
      if (!mounted) return;
      setState(() => _canReview = allowed);
    } catch (_) {
      if (!mounted) return;
      setState(() => _canReview = false);
    } finally {
      if (mounted) setState(() => _checkingReviewEligibility = false);
    }
  }

  String _baseProductId(String value) {
    final id = value.trim();
    final sep = id.indexOf('::');
    if (sep <= 0) return id;
    return id.substring(0, sep);
  }

  Future<void> _showReviewEligibilityMessage() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 22),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Review locked',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Only users who have bought this product can write a review. Place an order first, then you can share your rating, images, and videos.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 14,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Got it'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  ReviewModel? get _myReview {
    final uid = _currentUserId;
    if (uid.isEmpty) return null;
    for (final review in _product.reviews) {
      if (review.id == uid) return review;
    }
    return null;
  }

  Future<void> _deleteMyReview() async {
    final uid = _currentUserId;
    if (uid.isEmpty || _productId.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete review?'),
        content: const Text('This will remove your review from this product.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    try {
      await _firestoreService.deleteProductReview(
        uid: uid,
        productId: _productId,
      );
      if (!mounted) return;
      scaffoldMessenger.showSnackBar(
        const SnackBar(content: Text('Review deleted.')),
      );
      await _loadProductDetail();
    } catch (e) {
      if (!mounted) return;
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Could not delete review: $e')),
      );
    }
  }

  Future<void> _openReviewComposer([ReviewModel? initialReview]) async {
    final uid = _currentUserId;
    if (uid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to write a review.')),
      );
      return;
    }

    if (!_canReview && initialReview == null) {
      await _showReviewEligibilityMessage();
      return;
    }

    final commentController = TextEditingController(
      text: initialReview?.comment ?? '',
    );
    var ratingValue = initialReview?.rating ?? 5.0;
    final pickedFiles = <XFile>[];
    final existingMediaUrls = <String>[...?(initialReview?.mediaUrls)];
    var uploadProgress = 0.0;
    var uploadStatusText = '';
    var sheetClosed = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        initialReview == null
                            ? 'Write a Review'
                            : 'Edit Review',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Rating: ${ratingValue.toStringAsFixed(1)}',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Slider(
                        value: ratingValue,
                        min: 1,
                        max: 5,
                        divisions: 8,
                        label: ratingValue.toStringAsFixed(1),
                        onChanged: (v) => setModalState(() => ratingValue = v),
                      ),
                      TextField(
                        controller: commentController,
                        minLines: 3,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          hintText: 'Share your experience with this product',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _submittingReview
                                ? null
                                : () async {
                                    // On Android 13+, this uses system photo picker without broad media permissions
                                    final image = await _imagePicker.pickImage(
                                      source: ImageSource.gallery,
                                    );
                                    if (image == null) return;
                                    setModalState(
                                      () => pickedFiles.add(image),
                                    );
                                  },
                            icon: const Icon(Icons.image_outlined),
                            label: const Text('Add Images'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _submittingReview
                                ? null
                                : () async {
                                    // Camera doesn't require storage/media permissions
                                    final image = await _imagePicker.pickImage(
                                      source: ImageSource.camera,
                                      imageQuality: 85,
                                    );
                                    if (image == null) return;
                                    setModalState(() => pickedFiles.add(image));
                                  },
                            icon: const Icon(Icons.photo_camera_outlined),
                            label: const Text('Use Camera'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _submittingReview
                                ? null
                                : () async {
                                    // On Android 13+, this uses system video picker without broad media permissions
                                    final video = await _imagePicker.pickVideo(
                                      source: ImageSource.gallery,
                                    );
                                    if (video == null) return;
                                    setModalState(() => pickedFiles.add(video));
                                  },
                            icon: const Icon(Icons.videocam_outlined),
                            label: const Text('Add Video'),
                          ),
                        ],
                      ),
                      if (pickedFiles.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        const Text(
                          'Selected media',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: List.generate(pickedFiles.length, (i) {
                            final file = pickedFiles[i];
                            return _PickedReviewMediaTile(
                              file: file,
                              onRemove: () =>
                                  setModalState(() => pickedFiles.removeAt(i)),
                            );
                          }),
                        ),
                      ],
                      if (existingMediaUrls.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        const Text(
                          'Existing media',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: List.generate(existingMediaUrls.length, (
                            i,
                          ) {
                            final url = existingMediaUrls[i];
                            return _ExistingReviewMediaTile(
                              url: url,
                              onRemove: () => setModalState(
                                () => existingMediaUrls.removeAt(i),
                              ),
                            );
                          }),
                        ),
                      ],
                      if (_submittingReview) ...[
                        const SizedBox(height: 12),
                        Text(
                          uploadStatusText.isEmpty
                              ? 'Uploading media...'
                              : uploadStatusText,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          minHeight: 6,
                          borderRadius: BorderRadius.circular(999),
                          value: pickedFiles.isEmpty
                              ? null
                              : uploadProgress.clamp(0.0, 1.0),
                          backgroundColor: const Color(0xFFEFE9FF),
                        ),
                      ],
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _submittingReview
                              ? null
                              : () async {
                                  final comment = commentController.text.trim();
                                  if (comment.isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Please enter your review comment.',
                                        ),
                                      ),
                                    );
                                    return;
                                  }

                                  final scaffoldMessenger =
                                      ScaffoldMessenger.of(context);
                                  final navigator = Navigator.of(ctx);
                                  final userName =
                                      context.read<AuthProvider>().user?.name ??
                                      'Verified Buyer';
                                  final userEmail =
                                      context
                                          .read<AuthProvider>()
                                          .user
                                          ?.email ??
                                      '';
                                  final userPhone =
                                      context
                                          .read<AuthProvider>()
                                          .user
                                          ?.phone ??
                                      '';

                                  setState(() => _submittingReview = true);
                                  setModalState(() {
                                    uploadProgress = pickedFiles.isEmpty
                                        ? 0.0
                                        : 0.02;
                                    uploadStatusText = pickedFiles.isEmpty
                                        ? 'Submitting review...'
                                        : 'Uploading media...';
                                  });
                                  try {
                                    final uploadedMediaUrls =
                                        await _firestoreService.uploadReviewMedia(
                                          uid: uid,
                                          productId: _productId,
                                          files: pickedFiles,
                                          onProgress: (progress) {
                                            if (!mounted) return;
                                            setModalState(() {
                                              uploadProgress = progress;
                                              uploadStatusText =
                                                  'Uploading media... ${(progress * 100).round()}%';
                                            });
                                          },
                                        );

                                    if (mounted) {
                                      setModalState(() {
                                        uploadProgress = 1.0;
                                        uploadStatusText =
                                            'Submitting review...';
                                      });
                                    }

                                    await _firestoreService.submitProductReview(
                                      uid: uid,
                                      productId: _productId,
                                      productName: _product.name,
                                      productImage: _displayImage,
                                      userName: userName,
                                      userEmail: userEmail,
                                      userPhone: userPhone,
                                      rating: ratingValue,
                                      comment: comment,
                                      mediaUrls: [
                                        ...existingMediaUrls,
                                        ...uploadedMediaUrls,
                                      ],
                                    );

                                    if (!mounted) return;
                                    sheetClosed = true;
                                    navigator.pop();
                                    scaffoldMessenger.showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          initialReview == null
                                              ? 'Review submitted!'
                                              : 'Review updated!',
                                        ),
                                      ),
                                    );
                                    await _loadProductDetail();
                                  } catch (e) {
                                    if (mounted) {
                                      scaffoldMessenger.showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            e.toString().replaceFirst(
                                              'StateError: ',
                                              '',
                                            ),
                                          ),
                                        ),
                                      );
                                    }
                                  } finally {
                                    if (mounted) {
                                      setState(() => _submittingReview = false);
                                      if (!sheetClosed) {
                                        setModalState(() {
                                          uploadProgress = 0.0;
                                          uploadStatusText = '';
                                        });
                                      }
                                    }
                                  }
                                },
                          child: Text(
                            _submittingReview
                                ? 'Submitting...'
                                : 'Submit Review',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDetailsTabBody({
    required int tabIndex,
    required String description,
    required List<String> highlights,
    required List<String> howToUse,
  }) {
    final hasDescription = description.trim().isNotEmpty;
    final isExpanded = _isTabExpanded(tabIndex);

    if (tabIndex == 0) {
      final content = hasDescription
          ? description
          : 'No description available for this product.';
      final hasMediaMarkup = RegExp(
        r'!\[[^\]]*\]\((https?:\/\/[^\s)]+)\)',
        caseSensitive: false,
      ).hasMatch(content);
      final shouldCollapse = !hasMediaMarkup && content.length > 210;
      final displayText = (!isExpanded && shouldCollapse)
          ? '${content.substring(0, 210).trim()}...'
          : content;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildRichDescription(displayText),
          if (shouldCollapse)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () {
                  _toggleTabExpanded(tabIndex);
                },
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(isExpanded ? 'Read Less' : 'Read More'),
                    const SizedBox(width: 2),
                    const Icon(Icons.chevron_right_rounded, size: 16),
                  ],
                ),
              ),
            ),
        ],
      );
    }

    final items = tabIndex == 1 ? highlights : howToUse;
    final fallback = tabIndex == 1
        ? 'No highlights available for this product.'
        : 'How-to-use instructions are not available yet.';

    if (items.isEmpty) {
      return Text(
        fallback,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 14,
          height: 1.4,
        ),
      );
    }

    final shouldCollapse = items.length > 4;
    final displayItems = (!isExpanded && shouldCollapse)
        ? items.take(4).toList()
        : items;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...displayItems.map(
          (item) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 7),
                  child: Icon(
                    Icons.circle,
                    size: 6,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (shouldCollapse)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                _toggleTabExpanded(tabIndex);
              },
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(isExpanded ? 'Read Less' : 'Read More'),
            ),
          ),
      ],
    );
  }

  List<Map<String, dynamic>> _recommendedItems(List<Map<String, dynamic>> all) {
    if (all.isEmpty) return const [];

    final currentProductId = _baseProductId(_product.id);
    final currentCategory = (_resolvedProductMap['category'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    final currentTags = <String>{};
    final currentTag = (_resolvedProductMap['tag'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (currentTag.isNotEmpty) currentTags.add(currentTag);

    final tags = _resolvedProductMap['tags'];
    if (tags is List) {
      for (final t in tags) {
        final normalized = t.toString().trim().toLowerCase();
        if (normalized.isNotEmpty) currentTags.add(normalized);
      }
    }

    int scoreOf(Map<String, dynamic> product) {
      final productTagSet = <String>{};
      final single = (product['tag'] ?? '').toString().trim().toLowerCase();
      if (single.isNotEmpty) productTagSet.add(single);

      final productTags = product['tags'];
      if (productTags is List) {
        for (final t in productTags) {
          final normalized = t.toString().trim().toLowerCase();
          if (normalized.isNotEmpty) productTagSet.add(normalized);
        }
      }

      final category = (product['category'] ?? '')
          .toString()
          .trim()
          .toLowerCase();

      final tagMatches = productTagSet.where(currentTags.contains).length;
      final categoryMatch =
          currentCategory.isNotEmpty && currentCategory == category ? 1 : 0;
      final rating = (product['rating'] as num?)?.toDouble() ?? 0;
      final reviews = (product['reviews'] as num?)?.toInt() ?? 0;

      return (tagMatches * 10000) +
          (categoryMatch * 1000) +
          (rating * 100).round() +
          reviews;
    }

    final candidates = all
        .where(
          (p) => _baseProductId((p['id'] ?? '').toString()) != currentProductId,
        )
        .toList(growable: false);

    if (candidates.isEmpty) return const [];

    final sorted = List<Map<String, dynamic>>.from(candidates)
      ..sort((a, b) => scoreOf(b).compareTo(scoreOf(a)));

    final primary = sorted
        .where((p) {
          final category = (p['category'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          final tag = (p['tag'] ?? '').toString().trim().toLowerCase();
          final tags = p['tags'] is List
              ? (p['tags'] as List)
                    .map((e) => e.toString().trim().toLowerCase())
                    .toSet()
              : <String>{};
          final tagMatch =
              currentTags.contains(tag) || tags.any(currentTags.contains);
          final categoryMatch =
              currentCategory.isNotEmpty && currentCategory == category;
          return tagMatch || categoryMatch;
        })
        .take(6)
        .toList(growable: true);

    if (primary.length < 6) {
      final already = primary
          .map((e) => _baseProductId((e['id'] ?? '').toString()))
          .toSet();
      for (final candidate in sorted) {
        final id = _baseProductId((candidate['id'] ?? '').toString());
        if (already.contains(id)) continue;
        primary.add(candidate);
        if (primary.length >= 6) break;
      }
    }

    return primary.take(6).toList(growable: false);
  }

  int _compareVariantAscending(ProductVariant a, ProductVariant b) {
    String normalizeVariantText(ProductVariant v) {
      final shade = v.shadeName.trim();
      if (shade.isNotEmpty) return shade;
      final value = v.value.trim();
      if (value.isNotEmpty) return value;
      return v.attribute.trim();
    }

    final aText = normalizeVariantText(a);
    final bText = normalizeVariantText(b);

    double? parseLeadingNumber(String text) {
      final match = RegExp(r'^\s*([0-9]+(?:\.[0-9]+)?)').firstMatch(text);
      final raw = match?.group(1);
      if (raw == null) return null;
      return double.tryParse(raw);
    }

    final aNum = parseLeadingNumber(aText);
    final bNum = parseLeadingNumber(bText);

    if (aNum != null && bNum != null) {
      final numCmp = aNum.compareTo(bNum);
      if (numCmp != 0) return numCmp;
      return aText.toLowerCase().compareTo(bText.toLowerCase());
    }

    if (aNum != null && bNum == null) return -1;
    if (aNum == null && bNum != null) return 1;

    return aText.toLowerCase().compareTo(bText.toLowerCase());
  }

  String get _variableTierMode {
    return (_resolvedProductMap['variableTierMode'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
  }

  List<PercentagePricingTier> get _variableUniversalPercentageTiers {
    return parsePercentagePricingTiers(
      _resolvedProductMap['variableUniversalTiers'],
    );
  }

  int get _selectedVariantBasePrice {
    return (_selectedVariant?.price ?? 0) > 0
        ? (_selectedVariant?.price ?? 0)
        : ((_resolvedProductMap['price'] as num?) ?? 0).toInt();
  }

  int get _selectedVariantOriginalPrice {
    // Use variant's regularPrice if available, otherwise fall back to product-level originalPrice
    if (_selectedVariant != null && (_selectedVariant!.regularPrice ?? 0) > 0) {
      return _selectedVariant!.regularPrice;
    }
    return ((_resolvedProductMap['originalPrice'] as num?) ?? 0).toInt();
  }

  String get _effectivePricingType {
    final variantType = (_selectedVariant?.pricingType ?? '').trim();
    if (variantType.isNotEmpty) return variantType;

    final variantHasExplicitTiers =
        _selectedVariant != null && _selectedVariant!.pricingTiers.isNotEmpty;
    if (variantHasExplicitTiers) return 'tier';

    if (_variableTierMode == 'universal' &&
        _variableUniversalPercentageTiers.isNotEmpty) {
      return 'tier';
    }

    return (_resolvedProductMap['pricingType'] ?? '').toString().trim();
  }

  List<PricingTier> get _effectivePricingTiers {
    if (_selectedVariant != null && _selectedVariant!.pricingTiers.isNotEmpty) {
      return normalizePricingTiers(_selectedVariant!.pricingTiers);
    }

    if (_variableTierMode == 'universal' &&
        _variableUniversalPercentageTiers.isNotEmpty) {
      return derivePricingTiersFromPercentage(
        basePrice: _selectedVariantBasePrice,
        percentageTiers: _variableUniversalPercentageTiers,
      );
    }

    return parsePricingTiers(_resolvedProductMap['pricingTiers']);
  }

  bool get _hasTierPricing {
    final tiers = _effectivePricingTiers;
    if (tiers.isEmpty) return false;

    final type = _effectivePricingType.toLowerCase();
    return type.isEmpty || type == 'tier';
  }

  int _tierUnitPriceForQuantity(int quantity) {
    final basePrice = _selectedVariantBasePrice;

    if (!_hasTierPricing) return basePrice;

    return unitPriceForQuantity(
      quantity: quantity,
      basePrice: basePrice,
      pricingTiers: _effectivePricingTiers,
    );
  }

  String _tierLabel(PricingTier tier) => 'Buy ${tierRangeLabel(tier)}';

  int _tierIndex(List<PricingTier> tiers, int quantity) {
    return tierIndexForQuantity(quantity: quantity, pricingTiers: tiers);
  }

  String get _bulkHintText => _bulkHintMessages[_bulkHintMessageIndex];

  void _onBulkOrderPressed() {
    if (_showBulkHint) {
      setState(() => _showBulkHint = false);
    }
    _bulkHintHideTimer?.cancel();
    _bulkHintRotateTimer?.cancel();
    _openTierPricingSheet();
  }

  void _invalidateBulkConfirmation() {
    if (!mounted) return;
    if (_bulkConfirmedCartItemId == null && _bulkConfirmedQty == 0) return;
    setState(() {
      _bulkConfirmedCartItemId = null;
      _bulkConfirmedQty = 0;
    });
  }

  void _maybeShowBulkOrderHint({required bool hasTierPricing}) {
    if (!hasTierPricing || _hasShownBulkHintOnce) return;
    _hasShownBulkHintOnce = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      setState(() => _showBulkHint = true);

      _bulkHintRotateTimer?.cancel();
      _bulkHintRotateTimer = Timer.periodic(const Duration(seconds: 2), (
        timer,
      ) {
        if (!mounted || !_showBulkHint) {
          timer.cancel();
          return;
        }

        setState(() {
          _bulkHintMessageIndex =
              (_bulkHintMessageIndex + 1) % _bulkHintMessages.length;
        });
      });

      _bulkHintHideTimer?.cancel();
      _bulkHintHideTimer = Timer(const Duration(seconds: 8), () {
        if (!mounted) return;
        _bulkHintRotateTimer?.cancel();
        setState(() => _showBulkHint = false);
      });
    });
  }

  Future<void> _openTierPricingSheet() async {
    final tiers = _effectivePricingTiers;
    if (tiers.isEmpty) return;
    final cartModel = context.read<CartModel>();

    final basePrice = _selectedVariantBasePrice;
    final cartQty = cartModel.quantityOf(_cartItemId);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        var qty = cartQty > 0 ? cartQty : 1;

        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final unitPrice = unitPriceForQuantity(
              quantity: qty,
              basePrice: basePrice,
              pricingTiers: tiers,
            );
            final total = unitPrice * qty;
            final upcomingTier = nextPricingTier(
              quantity: qty,
              pricingTiers: tiers,
            );
            final activeIndex = _tierIndex(tiers, qty);
            final hasExactRangeMatch = tiers.any(
              (tier) =>
                  qty >= tier.minQty &&
                  (tier.maxQty == null || qty <= tier.maxQty!),
            );
            final savings = savingsForQuantity(
              quantity: qty,
              basePrice: basePrice,
              unitPrice: unitPrice,
            );

            return SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE2E5ED),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Bulk Pricing Offers',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ...tiers.asMap().entries.map((entry) {
                      final tier = entry.value;
                      final index = entry.key;
                      final isBest = entry.key == tiers.length - 1;
                      final isActive = activeIndex == index;
                      final rangeMatched =
                          qty >= tier.minQty &&
                          (tier.maxQty == null || qty <= tier.maxQty!);
                      final isSelectedRange =
                          rangeMatched || (!hasExactRangeMatch && isActive);
                      final previousTierPrice = index > 0
                          ? tiers[index - 1].price
                          : basePrice;
                      final showActiveStrike =
                          isSelectedRange && previousTierPrice > tier.price;
                      final perUnitSaved = showActiveStrike
                          ? (previousTierPrice - tier.price)
                          : 0;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: isActive
                              ? const Color(0xFFEDE7FF)
                              : (isBest
                                    ? const Color(0xFFFFF7E6)
                                    : const Color(0xFFF7F7FB)),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isActive
                                ? const Color(0xFFBFA4FF)
                                : (isBest
                                      ? const Color(0xFFFFDFA4)
                                      : const Color(0xFFE9EAF0)),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${_tierLabel(tier)} →',
                                    style: const TextStyle(
                                      color: AppColors.textPrimary,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (perUnitSaved > 0) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      'Save ₹${perUnitSaved * qty} at qty $qty',
                                      style: const TextStyle(
                                        color: Color(0xFF2D7A22),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (showActiveStrike)
                              Row(
                                children: [
                                  Text(
                                    '₹$previousTierPrice',
                                    style: const TextStyle(
                                      color: AppColors.textHint,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      decoration: TextDecoration.lineThrough,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                              ),
                            Text(
                              '₹${tier.price}',
                              style: TextStyle(
                                color: isActive
                                    ? AppColors.primary
                                    : AppColors.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (isBest)
                              Padding(
                                padding: const EdgeInsets.only(left: 8, top: 2),
                                child: const Text(
                                  'Best Value 🔥',
                                  style: TextStyle(
                                    color: Color(0xFFB77700),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 6),
                    Stack(
                      alignment: Alignment.centerRight,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'Quantity',
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              decoration: BoxDecoration(
                                color: AppColors.primary,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  IconButton(
                                    onPressed: qty <= 1
                                        ? null
                                        : () => setSheetState(() => qty--),
                                    icon: const Icon(
                                      Icons.remove,
                                      color: Colors.white,
                                    ),
                                  ),
                                  Text(
                                    '$qty',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () {
                                      final before = _tierIndex(tiers, qty);
                                      setSheetState(() => qty++);
                                      final after = _tierIndex(tiers, qty);
                                      if (after > before) {
                                        _tierConfettiController.play();
                                      }
                                    },
                                    icon: const Icon(
                                      Icons.add,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        Positioned(
                          right: 54,
                          child: IgnorePointer(
                            child: SizedBox(
                              width: 90,
                              height: 34,
                              child: ConfettiWidget(
                                confettiController: _tierConfettiController,
                                blastDirectionality:
                                    BlastDirectionality.explosive,
                                shouldLoop: false,
                                emissionFrequency: 0.03,
                                numberOfParticles: 12,
                                maxBlastForce: 8,
                                minBlastForce: 4,
                                gravity: 0.26,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF4F8FF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFD9E8FF)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Total ₹$total',
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            savings > 0
                                ? 'Saved ₹$savings at this quantity'
                                : (upcomingTier != null
                                      ? 'Add ${upcomingTier.minQty - qty} more for ₹${upcomingTier.price} each'
                                      : 'Best tier unlocked 🎉'),
                            style: TextStyle(
                              color: savings > 0
                                  ? const Color(0xFF2D7A22)
                                  : AppColors.textSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          cartModel.setQuantity(_cartPayload, qty);
                          if (mounted) {
                            setState(() {
                              _bulkConfirmedCartItemId = _cartItemId;
                              _bulkConfirmedQty = qty;
                            });
                          }
                          if (!mounted) return;
                          Navigator.of(sheetContext).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Saved quantity: $qty (₹$unitPrice each)',
                              ),
                              duration: const Duration(milliseconds: 1200),
                            ),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text(
                          'Save',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  int get _currentPrice {
    return _tierUnitPriceForQuantity(1);
  }

  bool get _manageStockEnabled {
    final raw = widget.product['manageStock'];
    if (raw is bool) return raw;

    final text = (raw ?? '').toString().trim().toLowerCase();
    if (text.isEmpty) return true;
    if (text == 'false' || text == '0' || text == 'no' || text == 'off') {
      return false;
    }
    return true;
  }

  int? _parseStockValue(dynamic raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toInt();
    final text = raw.toString().trim();
    if (text.isEmpty) return null;
    return int.tryParse(text);
  }

  int? get _currentStock {
    if (!_manageStockEnabled) return null;

    if (_selectedVariant != null) {
      final variant = _selectedVariant!;
      if (variant.hasExplicitStock) return variant.stock;

      // Legacy fallback: variable products may keep stock only on product doc.
      return _parseStockValue(
        widget.product['stock'] ??
            widget.product['quantity'] ??
            widget.product['qty'] ??
            widget.product['inventory'] ??
            widget.product['stockCount'],
      );
    }

    return _parseStockValue(
      widget.product['stock'] ??
          widget.product['quantity'] ??
          widget.product['qty'] ??
          widget.product['inventory'] ??
          widget.product['stockCount'],
    );
  }

  bool get _isOutOfStock {
    final stock = _currentStock;
    if (stock == null) return false;
    return stock <= 0;
  }

  String get _cartItemId {
    final baseId = _product.id;
    final variantId = (_selectedVariant?.id ?? '').trim();
    if (baseId.isEmpty) return '';
    return variantId.isEmpty ? baseId : '$baseId::$variantId';
  }

  String get _displaySize {
    final v = (_selectedVariant?.shadeName ?? '').trim();
    if (v.isNotEmpty) return v;
    return (widget.product['size'] ?? '').toString().trim();
  }

  String get _displayImage {
    final imgs = _productState?.displayImages ?? const <String>[];
    final idx = _productState?.selectedImageIndex ?? 0;
    if (imgs.isNotEmpty && idx >= 0 && idx < imgs.length) return imgs[idx];
    if (_product.images.isNotEmpty) return _product.images.first;
    return (widget.product['fullImageUrl'] ??
            widget.product['imageUrl'] ??
            widget.product['image'] ??
            '')
        .toString();
  }

  Map<String, dynamic> get _cartPayload {
    final baseName = _product.name.trim();
    final variantName = (_selectedVariant?.shadeName ?? '').trim();
    final composedName = variantName.isEmpty
        ? baseName
        : '$baseName • $variantName';
    return {
      ..._resolvedProductMap,
      'id': _cartItemId,
      'name': composedName,
      'brand': _product.brand,
      'image': _displayImage,
      'price': _currentPrice,
      'basePrice': _selectedVariantBasePrice,
      'pricingType': _effectivePricingType,
      'pricingTiers': _effectivePricingTiers
          .map((tier) => tier.toMap())
          .toList(growable: false),
      'size': _displaySize,
      'variantId': (_selectedVariant?.id ?? '').trim(),
      'variantName': variantName,
    };
  }

  @override
  Widget build(BuildContext context) {
    final home = context.watch<HomeProvider>();
    final recommended = _recommendedItems(home.productMaps);

    final name = _product.name.trim().isNotEmpty
        ? _product.name
        : (widget.product['name'] ?? '').toString();
    final brand = _product.brand.trim().isNotEmpty
        ? _product.brand
        : (widget.product['brand'] ?? '').toString();
    final brandLogo = _resolveBrandLogo(home, brand);
    final description = _product.description.trim().isNotEmpty
        ? _product.description
        : (widget.product['description'] ?? '').toString();
    final highlights = _extractHighlights();
    final howToUse = _extractHowToUse();
    final reviewItems = _product.reviews.take(10).toList();
    final derivedReviewCount = reviewItems.isNotEmpty ? reviewItems.length : 0;
    final reviews = [
      _product.reviewCount,
      derivedReviewCount,
      ((widget.product['reviews'] as num?) ?? 0).toInt(),
    ].reduce((a, b) => a > b ? a : b);
    final derivedRating = reviewItems.isNotEmpty
        ? reviewItems.fold<double>(0.0, (sum, review) => sum + review.rating) /
              reviewItems.length
        : 0.0;
    final rating = derivedRating > 0
        ? derivedRating
        : (_product.rating > 0
              ? _product.rating
              : ((widget.product['rating'] as num?) ?? 0).toDouble());
    final myReview = _myReview;
    final price = _currentPrice;
    final effectiveTiers = _effectivePricingTiers;
    final hasTierPricing = _hasTierPricing;
    _maybeShowBulkOrderHint(hasTierPricing: hasTierPricing);
    final originalPrice = _selectedVariantOriginalPrice;
    final hasDiscount = originalPrice > price;
    final hasVisiblePrice = price > 0;
    final discountPct = hasDiscount
        ? (((originalPrice - price) / originalPrice) * 100).round()
        : 0;
    final variants = List<ProductVariant>.from(_product.variants)
      ..sort(_compareVariantAscending);
    const variantGridSwitchThreshold = 4;
    final hasLongVariantLabels = variants.any(
      (variant) => _variantLabel(variant).trim().length > 12,
    );
    final variantGridCrossAxisCount = hasLongVariantLabels ? 2 : 3;
    const variantGridMainAxisSpacing = 8.0;
    final variantGridTileHeight = hasLongVariantLabels ? 66.0 : 56.0;
    const variantGridMinHeight = 68.0;
    const variantGridMaxHeight = 246.0;
    final showVariantGrid = variants.length > variantGridSwitchThreshold;
    final variantGridRows = (variants.length / variantGridCrossAxisCount)
        .ceil()
        .clamp(1, 999);
    final calculatedVariantGridHeight =
        (variantGridRows * variantGridTileHeight) +
        ((variantGridRows - 1) * variantGridMainAxisSpacing);
    final variantGridHeight = calculatedVariantGridHeight.clamp(
      variantGridMinHeight,
      variantGridMaxHeight,
    );
    final variantGridNeedsScroll =
        calculatedVariantGridHeight > variantGridMaxHeight;

    final imageList = _productState?.displayImages ?? const <String>[];
    final selectedImageIndex = _productState?.selectedImageIndex ?? 0;
    final carouselImages = imageList.isNotEmpty
        ? imageList
        : (_product.images.isNotEmpty
              ? _product.images
              : [
                  (widget.product['fullImageUrl'] ??
                          widget.product['imageUrl'] ??
                          widget.product['image'] ??
                          '')
                      .toString(),
                ]);

    return Scaffold(
      backgroundColor: Colors.white,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.all(8),
          child: _CircleIconButton(
            icon: Icons.arrow_back_ios_rounded,
            onTap: () => Navigator.pop(context),
          ),
        ),
        actions: [
          if (_loadingDetail)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _CircleIconButton(
              icon: _isWishlisted
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              iconColor: _isWishlisted
                  ? const Color(0xFFE53935)
                  : AppColors.textPrimary,
              onTap: _toggleWishlist,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _CircleIconButton(
              icon: Icons.ios_share_outlined,
              onTap: _shareProduct,
            ),
          ),
        ],
      ),
      bottomNavigationBar: _BottomCartBar(
        cartItem: _cartPayload,
        displaySize: _displaySize,
        displayPrice: price,
        basePrice: _selectedVariantBasePrice,
        pricingType: _effectivePricingType,
        pricingTiers: effectiveTiers,
        isOutOfStock: _isOutOfStock,
        onBulkOrderTap: _onBulkOrderPressed,
        onManualQuantityChange: _invalidateBulkConfirmation,
        bulkConfirmedCartItemId: _bulkConfirmedCartItemId,
        bulkConfirmedQty: _bulkConfirmedQty,
      ),
      floatingActionButton: const SupportChatFab(),
      body: SingleChildScrollView(
        controller: _contentScrollController,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 1. IMAGE CAROUSEL ─────────────────────────────────────────
            _ProductImageCarousel(
              images: carouselImages,
              selectedIndex: selectedImageIndex,
              pageController: _pageController,
              onPageChanged: (i) {
                _productState?.setImageIndex(i);
                _scrollToImageSection();
              },
              buildImage: _buildImage,
            ),

            // ── 2. MAIN PRODUCT INFO CARD ─────────────────────────────────
            Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Brand pill
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF2F2F7),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            brand.isNotEmpty ? brand.toUpperCase() : 'BRAND',
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Product name
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      name,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                      ),
                    ),
                  ),

                  // Rating badge
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color.fromARGB(255, 139, 32, 19),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                rating.toStringAsFixed(1),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(width: 3),
                              const Icon(
                                Icons.star_rounded,
                                size: 13,
                                color: Colors.white,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$reviews Ratings',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (hasTierPricing) ...[
                          const Spacer(),
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              FilledButton.icon(
                                onPressed: _onBulkOrderPressed,
                                icon: const Icon(
                                  Icons.local_offer_rounded,
                                  size: 16,
                                ),
                                label: const Text('Bulk order'),
                                style:
                                    FilledButton.styleFrom(
                                      backgroundColor: const Color(0xFF6C2BFF),
                                      foregroundColor: Colors.white,
                                      shadowColor: const Color(0x806C2BFF),
                                      elevation: 1.5,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                      minimumSize: Size.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(11),
                                      ),
                                      textStyle: const TextStyle(
                                        fontSize: 11.8,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.1,
                                      ),
                                    ).copyWith(
                                      overlayColor:
                                          const MaterialStatePropertyAll(
                                            Color(0x22FFFFFF),
                                          ),
                                    ),
                              ),
                              Positioned(
                                top: -44,
                                right: -2,
                                child: IgnorePointer(
                                  ignoring: true,
                                  child: AnimatedOpacity(
                                    duration: const Duration(milliseconds: 250),
                                    opacity: _showBulkHint ? 1 : 0,
                                    child: AnimatedSlide(
                                      duration: const Duration(
                                        milliseconds: 260,
                                      ),
                                      offset: _showBulkHint
                                          ? Offset.zero
                                          : const Offset(0.08, 0.12),
                                      curve: Curves.easeOutCubic,
                                      child: Container(
                                        constraints: const BoxConstraints(
                                          maxWidth: 190,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 7,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF2D1A63),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          boxShadow: const [
                                            BoxShadow(
                                              color: Color(0x332D1A63),
                                              blurRadius: 10,
                                              offset: Offset(0, 4),
                                            ),
                                          ],
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.trending_down_rounded,
                                              color: Color(0xFFE7D6FF),
                                              size: 12,
                                            ),
                                            const SizedBox(width: 5),
                                            Flexible(
                                              child: Text(
                                                _bulkHintText,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 10.7,
                                                  height: 1.15,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            const Icon(
                                              Icons.south_east_rounded,
                                              color: Color(0xFFD7B8FF),
                                              size: 12,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),

                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
                    child: Divider(height: 1, color: Color(0xFFF0F0F5)),
                  ),

                  if (hasVisiblePrice) ...[
                    // Price section
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '₹$price',
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 30,
                              fontWeight: FontWeight.w900,
                              height: 1,
                            ),
                          ),
                          if (hasDiscount) ...[
                            const SizedBox(width: 10),
                            Text(
                              '₹$originalPrice',
                              style: const TextStyle(
                                color: AppColors.textHint,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                decoration: TextDecoration.lineThrough,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE8F5E9),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '$discountPct% OFF',
                                style: const TextStyle(
                                  color: Color(0xFF2D7A22),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
                      child: Text(
                        'MRP inclusive of all taxes',
                        style: TextStyle(
                          color: AppColors.textHint,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                  if (_isOutOfStock)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text(
                        'Out of stock',
                        style: TextStyle(
                          color: Color(0xFFE53935),
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text(
                        _currentStock == null
                            ? 'In stock'
                            : 'In stock (${_currentStock! < 0 ? 0 : _currentStock!})',
                        style: const TextStyle(
                          color: Color(0xFF2D7A22),
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),

                  if (variants.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Divider(height: 1, color: Color(0xFFF0F0F5)),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _variantSectionTitle(variants),
                            style: const TextStyle(
                              color: Color(0xFF1E2433),
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.1,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Tap to choose your preferred option',
                            style: TextStyle(
                              color: Color(0xFF7C8597),
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (variantGridNeedsScroll) ...[
                            const SizedBox(height: 4),
                            const Text(
                              'Scroll to see more options',
                              style: TextStyle(
                                color: Color(0xFF8B94A8),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (showVariantGrid)
                      SizedBox(
                        height: variantGridHeight,
                        child: GridView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: variantGridCrossAxisCount,
                                mainAxisSpacing: variantGridMainAxisSpacing,
                                crossAxisSpacing: variantGridMainAxisSpacing,
                                childAspectRatio: hasLongVariantLabels
                                    ? 1.30
                                    : 1.65,
                              ),
                          itemCount: variants.length,
                          itemBuilder: (_, i) {
                            final variant = variants[i];
                            final isSelected =
                                _selectedVariant?.id == variant.id;
                            return _buildVariantOptionTile(
                              variant,
                              isSelected,
                              compactMode: false,
                              onSelect: () => _onVariantSelected(variant),
                            );
                          },
                        ),
                      )
                    else
                      SizedBox(
                        height: 90,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                          scrollDirection: Axis.horizontal,
                          itemCount: variants.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(width: 10),
                          itemBuilder: (_, i) {
                            final variant = variants[i];
                            final isSelected =
                                _selectedVariant?.id == variant.id;
                            return _buildVariantOptionTile(
                              variant,
                              isSelected,
                              compactMode: true,
                              onSelect: () => _onVariantSelected(variant),
                            );
                          },
                        ),
                      ),
                  ],

                  const SizedBox(height: 16),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── 3. PRODUCT DETAILS TABBED CARD ───────────────────────────
            _SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Product Details',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      for (final tab in const [
                        'Description',
                        'Highlights',
                        'How to use',
                      ])
                        Expanded(
                          child: InkWell(
                            onTap: () {
                              _setDetailsTab(
                                const [
                                  'Description',
                                  'Highlights',
                                  'How to use',
                                ].indexOf(tab),
                              );
                            },
                            child: Column(
                              children: [
                                Text(
                                  tab,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color:
                                        _selectedDetailsTab ==
                                            const [
                                              'Description',
                                              'Highlights',
                                              'How to use',
                                            ].indexOf(tab)
                                        ? AppColors.primary
                                        : AppColors.textSecondary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 180),
                                  height: 3,
                                  decoration: BoxDecoration(
                                    color:
                                        _selectedDetailsTab ==
                                            const [
                                              'Description',
                                              'Highlights',
                                              'How to use',
                                            ].indexOf(tab)
                                        ? AppColors.primary
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                  Container(
                    width: double.infinity,
                    height: 1,
                    color: const Color(0xFFE9E9EF),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7F7FA),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragEnd: _onDetailsHorizontalSwipe,
                      child: _buildDetailsTabBody(
                        tabIndex: _selectedDetailsTab,
                        description: description,
                        highlights: highlights,
                        howToUse: howToUse,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // Delivery section removed as requested.

            // ── 5. BRAND CARD ─────────────────────────────────────────────
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: brand.trim().isEmpty
                  ? null
                  : () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              ProductListScreen(initialBrand: brand),
                        ),
                      );
                    },
              child: _SectionCard(
                child: Row(
                  children: [
                    _buildBrandLogo(brandLogo),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            brand.isNotEmpty ? brand : 'Brand',
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Text(
                            'Tap to explore all products',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF2F2F7),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.chevron_right_rounded,
                        color: AppColors.textHint,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ── 6. RATINGS & REVIEWS (UI ONLY) ───────────────────────────
            _SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Ratings & Reviews',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (_checkingReviewEligibility)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        OutlinedButton.icon(
                          onPressed: () => _openReviewComposer(myReview),
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          label: Text(
                            myReview != null
                                ? 'Edit Review'
                                : (_canReview
                                      ? 'Write Review'
                                      : 'Bought users only'),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.primary,
                            side: const BorderSide(color: Color(0xFFE1D8FF)),
                            backgroundColor: const Color(0xFFFCFAFF),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFAFAFE),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFEAEAF3)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF3F1FB),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.star_rounded,
                                color: Color(0xFFF5B70A),
                                size: 18,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                rating.toStringAsFixed(1),
                                style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '$reviews ratings',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (reviewItems.isNotEmpty)
                    ...reviewItems.map(
                      (review) => _ReviewPreviewTile(
                        isOwnReview: review.id == _currentUserId,
                        userName: review.userName,
                        rating: review.rating,
                        comment: review.comment,
                        mediaUrls: review.mediaUrls,
                        onEdit: review.id == _currentUserId
                            ? () => _openReviewComposer(review)
                            : null,
                        onDelete: review.id == _currentUserId
                            ? _deleteMyReview
                            : null,
                      ),
                    )
                  else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFAFAFE),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE8E8F1)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'No reviews for this product yet.',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Be the first one to review this product.',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 42,
                            child: OutlinedButton.icon(
                              onPressed: _openReviewComposer,
                              icon: const Icon(
                                Icons.rate_review_outlined,
                                size: 16,
                              ),
                              label: const Text('Write a review'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.primary,
                                side: const BorderSide(
                                  color: Color(0xFFE1D8FF),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── 7. RECOMMENDED SECTION ────────────────────────────────────
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Recommended for you',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 4),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Curated picks for your salon',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
            const SizedBox(height: 12),
            if (recommended.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text(
                  'Recommendations will appear here soon.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              )
            else
              SizedBox(
                height: 250,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  scrollDirection: Axis.horizontal,
                  itemCount: recommended.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (_, i) => SizedBox(
                    width: 174,
                    child: ProductCard(product: recommended[i]),
                  ),
                ),
              ),
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// IMAGE CAROUSEL
// ─────────────────────────────────────────────────────────────────────────────

class _ProductImageCarousel extends StatelessWidget {
  final List<String> images;
  final int selectedIndex;
  final PageController pageController;
  final ValueChanged<int> onPageChanged;
  final Widget Function(String, {BoxFit fit}) buildImage;

  const _ProductImageCarousel({
    required this.images,
    required this.selectedIndex,
    required this.pageController,
    required this.onPageChanged,
    required this.buildImage,
  });

  void _openZoomViewer(BuildContext context, int initialIndex) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.95),
      builder: (_) => _ProductImageZoomViewer(
        images: images,
        initialIndex: initialIndex,
        buildImage: buildImage,
        onPageChanged: onPageChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final mainImageHeight = (screenHeight * 0.40).clamp(260.0, 340.0);

    return Container(
      color: Colors.white,
      child: Column(
        children: [
          // Main swipeable image
          SizedBox(
            height: mainImageHeight,
            child: PageView.builder(
              controller: pageController,
              itemCount: images.length,
              onPageChanged: onPageChanged,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: () => _openZoomViewer(context, i),
                        child: buildImage(images[i], fit: BoxFit.contain),
                      ),
                    ),
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.45),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Icon(
                          Icons.zoom_in_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (images.length > 1) ...[
            // Clickable thumbnail strip (removed pill-dot indicators)
            SizedBox(
              height: 64,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                scrollDirection: Axis.horizontal,
                itemCount: images.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final active = i == selectedIndex;
                  return GestureDetector(
                    onTap: () {
                      pageController.animateToPage(
                        i,
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeInOut,
                      );
                      onPageChanged(i);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 52,
                      height: 52,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: active
                              ? AppColors.primary
                              : const Color(0xFFE0E0E8),
                          width: active ? 2 : 1,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: buildImage(images[i], fit: BoxFit.cover),
                      ),
                    ),
                  );
                },
              ),
            ),
          ] else
            const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _ProductImageZoomViewer extends StatefulWidget {
  final List<String> images;
  final int initialIndex;
  final Widget Function(String, {BoxFit fit}) buildImage;
  final ValueChanged<int> onPageChanged;

  const _ProductImageZoomViewer({
    required this.images,
    required this.initialIndex,
    required this.buildImage,
    required this.onPageChanged,
  });

  @override
  State<_ProductImageZoomViewer> createState() =>
      _ProductImageZoomViewerState();
}

class _ProductImageZoomViewerState extends State<_ProductImageZoomViewer> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.images.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '${_index + 1}/${widget.images.length}',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2, bottom: 8),
            child: Text(
              'Pinch to zoom',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.images.length,
              onPageChanged: (i) {
                setState(() => _index = i);
                widget.onPageChanged(i);
              },
              itemBuilder: (_, i) {
                return InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Center(
                    child: widget.buildImage(
                      widget.images[i],
                      fit: BoxFit.contain,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION CARD WRAPPER
// ─────────────────────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final Widget child;

  const _SectionCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION HEADER / PINCODE FIELD removed (no longer used).

class _ReviewPreviewTile extends StatelessWidget {
  final String userName;
  final double rating;
  final String comment;
  final List<String> mediaUrls;
  final bool isOwnReview;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _ReviewPreviewTile({
    required this.userName,
    required this.rating,
    required this.comment,
    this.mediaUrls = const [],
    this.isOwnReview = false,
    this.onEdit,
    this.onDelete,
  });

  bool _isVideoUrl(String url) {
    final value = url.toLowerCase();
    return value.contains('.mp4') ||
        value.contains('.mov') ||
        value.contains('.avi') ||
        value.contains('.mkv') ||
        value.contains('/video/');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7FA),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  userName.trim().isNotEmpty ? userName : 'Reviewer',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (isOwnReview)
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') {
                      onEdit?.call();
                    } else if (value == 'delete') {
                      onDelete?.call();
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem<String>(
                      value: 'edit',
                      child: Text('Edit review'),
                    ),
                    PopupMenuItem<String>(
                      value: 'delete',
                      child: Text('Delete review'),
                    ),
                  ],
                ),
              const Icon(
                Icons.star_rounded,
                size: 14,
                color: Color(0xFFF5B70A),
              ),
              const SizedBox(width: 2),
              Text(
                rating > 0 ? rating.toStringAsFixed(1) : '0.0',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            comment.trim().isNotEmpty
                ? comment
                : 'Review text will be available here.',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          if (mediaUrls.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 62,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: mediaUrls.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final url = mediaUrls[i];
                  final isVideo = _isVideoUrl(url);
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 62,
                      height: 62,
                      color: const Color(0xFFEFEFF5),
                      child: isVideo
                          ? Stack(
                              fit: StackFit.expand,
                              children: [
                                const ColoredBox(color: Color(0xFFE8E8F0)),
                                const Center(
                                  child: Icon(
                                    Icons.play_circle_fill_rounded,
                                    color: AppColors.textSecondary,
                                    size: 24,
                                  ),
                                ),
                              ],
                            )
                          : CachedNetworkImage(
                              imageUrl: url,
                              fit: BoxFit.cover,
                              fadeInDuration: Duration.zero,
                              fadeOutDuration: Duration.zero,
                              memCacheWidth: 124,
                              maxWidthDiskCache: 124,
                              errorWidget: (_, __, ___) => const Icon(
                                Icons.image_not_supported_outlined,
                                color: AppColors.textHint,
                              ),
                            ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ExistingReviewMediaTile extends StatelessWidget {
  final String url;
  final VoidCallback onRemove;

  const _ExistingReviewMediaTile({required this.url, required this.onRemove});

  bool get _isVideo {
    final value = url.toLowerCase();
    return value.contains('.mp4') ||
        value.contains('.mov') ||
        value.contains('.avi') ||
        value.contains('.mkv') ||
        value.contains('.webm') ||
        value.contains('/video/');
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 84,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5FA),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE6E6EF)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 72,
                  height: 72,
                  child: _isVideo
                      ? Container(
                          color: const Color(0xFFE9E9F2),
                          child: const Center(
                            child: Icon(
                              Icons.play_circle_fill_rounded,
                              size: 28,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        )
                      : CachedNetworkImage(
                          imageUrl: url,
                          fit: BoxFit.cover,
                          fadeInDuration: Duration.zero,
                          fadeOutDuration: Duration.zero,
                          memCacheWidth: 144,
                          maxWidthDiskCache: 144,
                          errorWidget: (_, __, ___) => Container(
                            color: const Color(0xFFE9E9F2),
                            child: const Icon(
                              Icons.image_not_supported_outlined,
                              color: AppColors.textHint,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _isVideo ? 'Video' : 'Image',
                style: const TextStyle(
                  fontSize: 10,
                  color: AppColors.textSecondary,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 24,
              height: 24,
              decoration: const BoxDecoration(
                color: AppColors.textPrimary,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}

class _PickedReviewMediaTile extends StatelessWidget {
  final XFile file;
  final VoidCallback onRemove;

  const _PickedReviewMediaTile({required this.file, required this.onRemove});

  bool get _isVideo {
    final value = file.name.toLowerCase();
    return value.endsWith('.mp4') ||
        value.endsWith('.mov') ||
        value.endsWith('.avi') ||
        value.endsWith('.mkv') ||
        value.endsWith('.webm');
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 84,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5FA),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE6E6EF)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 72,
                  height: 72,
                  child: _isVideo
                      ? Container(
                          color: const Color(0xFFE9E9F2),
                          child: const Center(
                            child: Icon(
                              Icons.play_circle_fill_rounded,
                              size: 28,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        )
                      : FutureBuilder<Uint8List>(
                          future: file.readAsBytes(),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) {
                              return Container(
                                color: const Color(0xFFE9E9F2),
                                child: const Center(
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              );
                            }
                            return Image.memory(
                              snapshot.data!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color: const Color(0xFFE9E9F2),
                                child: const Icon(
                                  Icons.image_not_supported_outlined,
                                  color: AppColors.textHint,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                file.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 10,
                  color: AppColors.textSecondary,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 24,
              height: 24,
              decoration: const BoxDecoration(
                color: AppColors.textPrimary,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CIRCLE ICON BUTTON (AppBar)
// ─────────────────────────────────────────────────────────────────────────────

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color iconColor;

  const _CircleIconButton({
    required this.icon,
    required this.onTap,
    this.iconColor = AppColors.textPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(icon, size: 18, color: iconColor),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BOTTOM CART BAR
// ─────────────────────────────────────────────────────────────────────────────

class _BottomCartBar extends StatelessWidget {
  static const String _contactPurchaseNumber = '+91 9579177826';

  final Map<String, dynamic> cartItem;
  final String displaySize;
  final int displayPrice;
  final int basePrice;
  final String pricingType;
  final List<PricingTier> pricingTiers;
  final bool isOutOfStock;
  final VoidCallback? onBulkOrderTap;
  final VoidCallback? onManualQuantityChange;
  final String? bulkConfirmedCartItemId;
  final int bulkConfirmedQty;

  const _BottomCartBar({
    required this.cartItem,
    required this.displaySize,
    required this.displayPrice,
    required this.basePrice,
    required this.pricingType,
    required this.pricingTiers,
    required this.isOutOfStock,
    this.onBulkOrderTap,
    this.onManualQuantityChange,
    this.bulkConfirmedCartItemId,
    this.bulkConfirmedQty = 0,
  });

  @override
  Widget build(BuildContext context) {
    final cartId = (cartItem['id'] ?? '').toString();
    void showContactMessage() {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contact to purchase: +91 9579177826')),
      );
    }

    return SafeArea(
      top: false,
      child: Consumer<CartModel>(
        builder: (_, cart, __) {
          final qty = cart.quantityOf(cartId);
          final normalizedPricingType = pricingType.trim().toLowerCase();
          final hasTierPricing =
              pricingTiers.isNotEmpty &&
              (normalizedPricingType.isEmpty ||
                  normalizedPricingType == 'tier');
          int? discountedTierTriggerQty;
          if (hasTierPricing) {
            for (final tier in pricingTiers) {
              if (tier.price < basePrice) {
                discountedTierTriggerQty = tier.minQty;
                break;
              }
            }
          }
          final bulkSelectionConfirmed =
              bulkConfirmedCartItemId == cartId && bulkConfirmedQty == qty;
          final requiresBulkSelection =
              discountedTierTriggerQty != null &&
              qty >= discountedTierTriggerQty &&
              !bulkSelectionConfirmed;
          final resolvedDisplayPrice = hasTierPricing
              ? unitPriceForQuantity(
                  quantity: qty > 0 ? qty : 1,
                  basePrice: basePrice,
                  pricingTiers: pricingTiers,
                )
              : displayPrice;
          final displayAmount = qty > 0
              ? (resolvedDisplayPrice * qty)
              : resolvedDisplayPrice;
          final hasVisiblePrice = displayAmount > 0;
          final contactOnlyPurchase = displayPrice <= 0;
          final Widget trailingAction = contactOnlyPurchase && qty == 0
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Contact: $_contactPurchaseNumber',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 170,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: cartId.isEmpty ? null : showContactMessage,
                        child: const Text(
                          'Contact to purchase',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : SizedBox(
                  width: qty == 0 ? 170 : 225,
                  height: 50,
                  child: isOutOfStock
                      ? ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFBDBDBD),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: null,
                          child: const Text(
                            'Out of stock',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : qty == 0
                      ? ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: cartId.isEmpty
                              ? null
                              : () {
                                  if (contactOnlyPurchase) {
                                    showContactMessage();
                                    return;
                                  }
                                  onManualQuantityChange?.call();
                                  cart.add(cartItem);
                                },
                          child: Text(
                            contactOnlyPurchase
                                ? 'Contact to purchase'
                                : 'Add to cart',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : Row(
                          children: [
                            Container(
                              width: 104,
                              decoration: BoxDecoration(
                                color: AppColors.primary,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: IconButton(
                                      onPressed: () {
                                        onManualQuantityChange?.call();
                                        cart.remove(cartId);
                                      },
                                      icon: const Icon(
                                        Icons.remove,
                                        color: Colors.white,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '$qty',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  Expanded(
                                    child: IconButton(
                                      onPressed: () {
                                        if (contactOnlyPurchase) {
                                          showContactMessage();
                                          return;
                                        }
                                        onManualQuantityChange?.call();
                                        cart.add(cartItem);
                                      },
                                      icon: const Icon(
                                        Icons.add,
                                        color: Colors.white,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: requiresBulkSelection
                                    ? onBulkOrderTap
                                    : () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                const CheckoutScreen(),
                                          ),
                                        );
                                      },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                child: Text(
                                  requiresBulkSelection
                                      ? 'Bulk order'
                                      : 'Checkout',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                );
          return Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 16,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: Row(
              children: [
                // Price info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (displaySize.isNotEmpty)
                        Text(
                          displaySize,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      if (hasVisiblePrice) ...[
                        Text(
                          '₹$displayAmount',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 26,
                            fontWeight: FontWeight.w900,
                            height: 1.1,
                          ),
                        ),
                        const Text(
                          'Incl. all taxes',
                          style: TextStyle(
                            color: AppColors.textHint,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(width: 10),

                // Add to Cart / qty stepper + checkout
                trailingAction,
              ],
            ),
          );
        },
      ),
    );
  }
}
