import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/models/cart_model.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/core/widgets/product_card.dart';
import 'package:purecuts/core/widgets/sticky_cart_bar.dart';
import 'package:purecuts/features/home/home_provider.dart';

class SubSubCategoryScreen extends StatefulWidget {
  final String categoryName;
  final String initialSubCategory;
  final Set<String> purchasedProductIds;

  const SubSubCategoryScreen({
    super.key,
    required this.categoryName,
    required this.initialSubCategory,
    required this.purchasedProductIds,
  });

  @override
  State<SubSubCategoryScreen> createState() => _SubSubCategoryScreenState();
}

class _SubSubCategoryScreenState extends State<SubSubCategoryScreen> {
  static const int _pageSize = 12;

  final TextEditingController _searchController = TextEditingController();
  ScaffoldMessengerState? _messenger;
  String _searchQuery = '';
  String? _selectedBrand;
  String? _selectedSubCategory;
  String? _selectedSubSubCategory;
  int _visibleProductCount = _pageSize;
  int _currentFilteredProductCount = 0;

  void _clearTransientSnackbars() {
    _messenger?.hideCurrentSnackBar();
    _messenger?.clearSnackBars();
  }

  List<Map<String, dynamic>> _mergeUniqueProducts(
    List<Map<String, dynamic>> primary,
    List<Map<String, dynamic>> secondary,
  ) {
    final merged = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    void addAllUnique(List<Map<String, dynamic>> source) {
      for (final product in source) {
        final id = _baseProductId((product['id'] ?? '').toString());
        if (id.isNotEmpty) {
          if (!seenIds.add(id)) continue;
          merged.add(product);
          continue;
        }

        final fingerprint = product.toString();
        if (!seenIds.add(fingerprint)) continue;
        merged.add(product);
      }
    }

    addAllUnique(primary);
    addAllUnique(secondary);
    return merged;
  }

  @override
  void initState() {
    super.initState();
    _selectedSubCategory = widget.initialSubCategory;
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
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger ??= ScaffoldMessenger.maybeOf(context);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _resetPagination() {
    _visibleProductCount = _pageSize;
  }

  String _normalize(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  String _normalizeToken(String value) {
    return value
        .trim()
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

  bool _matchesSearchQuery(Map<String, dynamic> product, String rawQuery) {
    final query = _normalizeToken(rawQuery);
    if (query.isEmpty) return true;

    final searchable = _normalizeToken(
      [
        product['name'],
        product['brand'],
        product['category'],
        product['subCategory'] ?? product['subcategory'],
        product['subSubCategory'] ??
            product['subsubCategory'] ??
            product['sub_sub_category'],
        product['description'],
        product['shortDescription'],
        ..._productTags(product),
      ].join(' '),
    );

    if (searchable.isEmpty) return false;
    if (searchable.contains(query)) return true;

    final tokens = query
        .split(' ')
        .where((token) => token.trim().isNotEmpty)
        .toList(growable: false);

    return tokens.every(searchable.contains);
  }

  String _resolveBrandLogo(HomeProvider home, String brandName) {
    final normalized = _normalize(brandName);
    if (normalized.isEmpty) return '';

    for (final brand in home.brands) {
      final candidate = _normalize((brand['name'] ?? '').toString());
      if (candidate == normalized) {
        return (brand['image'] ?? brand['logo'] ?? brand['icon'] ?? '')
            .toString()
            .trim();
      }
    }

    return '';
  }

  String _baseProductId(String value) {
    final id = value.trim();
    if (id.isEmpty) return '';
    final sep = id.indexOf('::');
    if (sep <= 0) return id;
    return id.substring(0, sep);
  }

  List<Map<String, dynamic>> _productsForSubCategory(
    HomeProvider home,
    String category,
    String subCategory,
  ) {
    final strict = home.filteredProducts(
      category: category,
      subCategory: subCategory,
    );
    final fullPool = home.filteredProducts(category: 'All');
    final needle = _normalize(subCategory);

    final relaxed = fullPool
        .where((product) {
          return home
              .productSubCategoryCandidates(product)
              .any((candidate) => _normalize(candidate) == needle);
        })
        .toList(growable: false);

    return _mergeUniqueProducts(strict, relaxed);
  }

  List<Map<String, dynamic>> _productsForSelection(
    HomeProvider home,
    String category,
    String? subCategory,
    String? subSubCategory,
    String query,
  ) {
    if ((subCategory ?? '').trim().isEmpty) {
      return home.filteredProducts(category: category, query: query);
    }

    final strict = home.filteredProducts(
      category: category,
      subCategory: subCategory,
      subSubCategory: subSubCategory,
      query: query,
    );
    var subProducts = _productsForSubCategory(home, category, subCategory!);

    if ((subSubCategory ?? '').trim().isNotEmpty) {
      final needle = _normalize(subSubCategory!);
      subProducts = subProducts
          .where((product) {
            return home
                .productSubSubCategoryCandidates(product)
                .any((candidate) => _normalize(candidate) == needle);
          })
          .toList(growable: false);
    }

    final q = _normalize(query);
    if (q.isEmpty) return _mergeUniqueProducts(strict, subProducts);

    final relaxed = subProducts
        .where((product) => _matchesSearchQuery(product, q))
        .toList(growable: false);

    return _mergeUniqueProducts(strict, relaxed);
  }

  @override
  Widget build(BuildContext context) {
    final home = context.watch<HomeProvider>();
    final subCategories = home.subCategoriesFor(widget.categoryName);

    // Show a loading indicator until the full catalog is ready so that
    // newly-published products (outside the startup-lite pool) are not missed.
    if (home.loading || !home.fullCatalogReady) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          titleSpacing: 0,
          title: Text(
            widget.categoryName,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final subCategoryNameByKey = <String, String>{
      for (final s in subCategories)
        if ((s['name'] ?? '').toString().trim().isNotEmpty)
          _normalize((s['name'] ?? '').toString()): (s['name'] ?? '')
              .toString(),
    };

    final selectedSubCategoryKey = _normalize(_selectedSubCategory ?? '');
    final selectedSubCategory =
        subCategoryNameByKey.containsKey(selectedSubCategoryKey)
        ? subCategoryNameByKey[selectedSubCategoryKey]
        : (subCategories.isEmpty
              ? null
              : (subCategories.first['name'] ?? '').toString());

    final subSubCategories = selectedSubCategory == null
        ? const <Map<String, dynamic>>[]
        : home.subSubCategoriesFor(widget.categoryName, selectedSubCategory);

    final subSubCategoryNameByKey = <String, String>{
      for (final s in subSubCategories)
        if ((s['name'] ?? '').toString().trim().isNotEmpty)
          _normalize((s['name'] ?? '').toString()): (s['name'] ?? '')
              .toString(),
    };

    final selectedSubSubCategoryKey = _normalize(_selectedSubSubCategory ?? '');
    final selectedSubSubCategory =
        subSubCategoryNameByKey.containsKey(selectedSubSubCategoryKey)
        ? subSubCategoryNameByKey[selectedSubSubCategoryKey]
        : null;

    final products = _productsForSelection(
      home,
      widget.categoryName,
      selectedSubCategory,
      selectedSubSubCategory,
      _searchQuery,
    );

    final brands =
        products
            .map((p) => (p['brand'] ?? '').toString().trim())
            .where((brand) => brand.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final selectedBrand = brands.contains(_selectedBrand)
        ? _selectedBrand
        : null;
    final brandFilteredProducts = selectedBrand == null
        ? products
        : products
              .where(
                (p) =>
                    _normalize((p['brand'] ?? '').toString()) ==
                    _normalize(selectedBrand),
              )
              .toList(growable: false);

    _currentFilteredProductCount = brandFilteredProducts.length;
    final visibleCount = _visibleProductCount.clamp(
      0,
      _currentFilteredProductCount,
    );
    final visibleProducts = brandFilteredProducts
        .take(visibleCount)
        .toList(growable: false);
    final hasMoreProducts = visibleCount < _currentFilteredProductCount;

    return PopScope(
      onPopInvoked: (didPop) {
        _clearTransientSnackbars();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          titleSpacing: 0,
          title: Text(
            selectedSubCategory ?? widget.categoryName,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Container(
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE7EAF0)),
                ),
                child: TextField(
                  controller: _searchController,
                  onChanged: (v) => setState(() {
                    _searchQuery = v;
                    _resetPagination();
                  }),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textPrimary,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Search products',
                    hintStyle: TextStyle(
                      fontSize: 12,
                      color: AppColors.textHint,
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: AppColors.textHint,
                    ),
                    border: InputBorder.none,
                    isCollapsed: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 11),
                  ),
                ),
              ),
            ),
            if (brands.isNotEmpty)
              SizedBox(
                height: 66,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  scrollDirection: Axis.horizontal,
                  itemCount: brands.length + 1,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final isAll = i == 0;
                    final label = isAll ? 'All Brands' : brands[i - 1];
                    final logoPath = isAll
                        ? ''
                        : _resolveBrandLogo(home, brands[i - 1]);
                    final selected = isAll
                        ? selectedBrand == null
                        : selectedBrand == label;

                    return GestureDetector(
                      onTap: () => setState(() {
                        _selectedBrand = isAll ? null : label;
                        _resetPagination();
                      }),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 54,
                        height: 54,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFFEFF8E4)
                              : const Color(0xFFF4F6FA),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: selected
                                ? AppColors.success
                                : const Color(0xFFE1E5EA),
                          ),
                        ),
                        child: isAll
                            ? Icon(
                                Icons.apps_rounded,
                                size: 28,
                                color: selected
                                    ? AppColors.success
                                    : AppColors.textSecondary,
                              )
                            : _ThumbIcon(path: logoPath, size: 34),
                      ),
                    );
                  },
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
                child: Row(
                  children: [
                    Container(
                      width: 89,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F8FA),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: subSubCategories.length + 1,
                        separatorBuilder: (_, __) => const SizedBox(height: 3),
                        itemBuilder: (_, i) {
                          final isAll = i == 0;
                          final name = isAll
                              ? 'All'
                              : (subSubCategories[i - 1]['name'] ?? '')
                                    .toString();
                          final iconPath = isAll
                              ? null
                              : (subSubCategories[i - 1]['icon'] ??
                                        subSubCategories[i - 1]['image'])
                                    ?.toString();
                          final selected = isAll
                              ? selectedSubSubCategory == null
                              : _normalize(selectedSubSubCategory ?? '') ==
                                    _normalize(name);

                          return _SubSubRailItem(
                            label: name,
                            iconPath: iconPath,
                            selected: selected,
                            onTap: () => setState(() {
                              _selectedSubSubCategory = isAll ? null : name;
                              _resetPagination();
                            }),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: visibleProducts.isEmpty
                          ? const Center(
                              child: Text(
                                'No products found for this selection',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            )
                          : Column(
                              children: [
                                Expanded(
                                  child: GridView.builder(
                                    padding: const EdgeInsets.fromLTRB(
                                      0,
                                      0,
                                      0,
                                      8,
                                    ),
                                    gridDelegate:
                                        const SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: 2,
                                          mainAxisSpacing: 10,
                                          crossAxisSpacing: 10,
                                          childAspectRatio: 0.48,
                                        ),
                                    itemCount: visibleProducts.length,
                                    itemBuilder: (_, i) {
                                      final product = visibleProducts[i];
                                      final productId = _baseProductId(
                                        (product['id'] ?? '').toString(),
                                      );
                                      return ProductCard(
                                        product: product,
                                        showHeartIcon: false,
                                        useFloatingVariantSnackbar: true,
                                        showBoughtEarlierBadge: widget
                                            .purchasedProductIds
                                            .contains(productId),
                                      );
                                    },
                                  ),
                                ),
                                if (hasMoreProducts)
                                  Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      0,
                                      6,
                                      0,
                                      MediaQuery.of(context).padding.bottom +
                                          12,
                                    ),
                                    child: SizedBox(
                                      width: double.infinity,
                                      height: 38,
                                      child: OutlinedButton(
                                        onPressed: () {
                                          setState(() {
                                            _visibleProductCount =
                                                (_visibleProductCount +
                                                        _pageSize)
                                                    .clamp(
                                                      _pageSize,
                                                      _currentFilteredProductCount,
                                                    );
                                          });
                                        },
                                        style: OutlinedButton.styleFrom(
                                          side: const BorderSide(
                                            color: Color(0xFFD9DDE4),
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                        ),
                                        child: Text(
                                          'Load more (${_currentFilteredProductCount - visibleCount} left)',
                                          style: const TextStyle(
                                            color: AppColors.textSecondary,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                else
                                  SizedBox(
                                    height:
                                        MediaQuery.of(context).padding.bottom +
                                        12,
                                  ),
                              ],
                            ),
                    ),
                  ],
                ),
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
      ),
    );
  }
}

class _SubSubRailItem extends StatelessWidget {
  final String label;
  final String? iconPath;
  final bool selected;
  final VoidCallback onTap;

  const _SubSubRailItem({
    required this.label,
    required this.iconPath,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.fromLTRB(5, 7, 5, 7),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFEFF8E4) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.success : Colors.transparent,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(child: _ThumbIcon(path: iconPath ?? '', size: 50)),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? AppColors.success : AppColors.textSecondary,
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                height: 1.15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThumbIcon extends StatelessWidget {
  final String path;
  final double size;

  const _ThumbIcon({required this.path, this.size = 20});

  @override
  Widget build(BuildContext context) {
    const fallback = Icon(
      Icons.category_outlined,
      size: 17,
      color: AppColors.textSecondary,
    );

    final trimmed = path.trim();
    if (trimmed.isEmpty) return fallback;

    if (trimmed.startsWith('assets/')) {
      return Image.asset(
        trimmed,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => fallback,
      );
    }

    return CachedNetworkImage(
      imageUrl: trimmed,
      width: size,
      height: size,
      fit: BoxFit.contain,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      memCacheWidth: (size * 2).round(),
      maxWidthDiskCache: (size * 2).round(),
      errorWidget: (_, __, ___) => fallback,
    );
  }
}
