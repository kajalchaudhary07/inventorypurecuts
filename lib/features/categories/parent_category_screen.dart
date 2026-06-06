import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/models/cart_model.dart';
import 'package:purecuts/core/services/firestore_service.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/core/widgets/product_card.dart';
import 'package:purecuts/core/widgets/sticky_cart_bar.dart';
import 'package:purecuts/features/categories/widgets/sub_subcategory_bottom_sheet.dart';
import 'package:purecuts/features/home/home_provider.dart';

class ParentCategoryScreen extends StatefulWidget {
  const ParentCategoryScreen({super.key, required this.categoryName});

  final String categoryName;

  @override
  State<ParentCategoryScreen> createState() => _ParentCategoryScreenState();
}

class _ParentCategoryScreenState extends State<ParentCategoryScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  ScaffoldMessengerState? _messenger;
  Set<String> _purchasedProductIds = <String>{};
  String? _selectedSubCategory;
  String? _selectedSubSubCategory;

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
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger ??= ScaffoldMessenger.maybeOf(context);
  }

  String _normalized(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
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
    final needle = _normalized(subCategory);

    final relaxed = fullPool
        .where((product) {
          return home
              .productSubCategoryCandidates(product)
              .any((candidate) => _normalized(candidate) == needle);
        })
        .toList(growable: false);

    return _mergeUniqueProducts(strict, relaxed);
  }

  List<Map<String, dynamic>> _productsForSelection(
    HomeProvider home,
    String category,
    String? subCategory,
    String? subSubCategory,
  ) {
    if ((subCategory ?? '').trim().isEmpty) {
      return home.filteredProducts(category: category);
    }

    final strict = home.filteredProducts(
      category: category,
      subCategory: subCategory,
      subSubCategory: subSubCategory,
    );
    var subProducts = _productsForSubCategory(home, category, subCategory!);

    if ((subSubCategory ?? '').trim().isNotEmpty) {
      final needle = _normalized(subSubCategory!);
      subProducts = subProducts
          .where((product) {
            return home
                .productSubSubCategoryCandidates(product)
                .any((candidate) => _normalized(candidate) == needle);
          })
          .toList(growable: false);
    }

    return _mergeUniqueProducts(strict, subProducts);
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

  Future<void> _refreshCategoryProducts() async {
    final home = context.read<HomeProvider>();
    await home.loadData(forceRefresh: true);
    await home.ensureVisibilityCatalogLoaded();
    await _resolvePurchasedProducts();
  }

  Future<void> _onSelectSubCategory(
    HomeProvider home,
    String categoryName,
    String subCategoryName,
  ) async {
    final subSub = home.subSubCategoriesFor(categoryName, subCategoryName);

    if (subSub.isEmpty) {
      if (!mounted) return;
      setState(() {
        _selectedSubCategory = subCategoryName;
        _selectedSubSubCategory = null;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _selectedSubCategory = subCategoryName;
      _selectedSubSubCategory = null;
    });

    final selected = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SubSubCategoryBottomSheet(
        title: 'Select ${subCategoryName.trim()} type',
        items: subSub,
        selected: _selectedSubSubCategory,
      ),
    );

    if (!mounted) return;
    setState(() {
      _selectedSubSubCategory = selected;
    });
  }

  @override
  Widget build(BuildContext context) {
    final home = context.watch<HomeProvider>();
    final categoryName = widget.categoryName.trim().isEmpty
        ? 'Category'
        : widget.categoryName.trim();

    final subCategories = home.subCategoriesFor(categoryName);
    final selectedSubCategoryName = (_selectedSubCategory ?? '').trim();

    final selectedSubSubName = (_selectedSubSubCategory ?? '').trim().isNotEmpty
        ? _selectedSubSubCategory
        : null;

    final products = _productsForSelection(
      home,
      categoryName,
      selectedSubCategoryName.isEmpty ? null : selectedSubCategoryName,
      selectedSubSubName,
    );

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
          title: Text(
            categoryName,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        body: (home.loading || !home.fullCatalogReady)
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 2),
                  if (subCategories.isNotEmpty)
                    SizedBox(
                      height: 54,
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        scrollDirection: Axis.horizontal,
                        itemCount: subCategories.length + 1,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          final isAll = i == 0;
                          final name = isAll
                              ? 'All'
                              : (subCategories[i - 1]['name'] ?? '').toString();
                          final isSelected = isAll
                              ? selectedSubCategoryName.isEmpty
                              : _normalized(name) ==
                                    _normalized(selectedSubCategoryName);

                          return ChoiceChip(
                            label: Text(name),
                            selected: isSelected,
                            onSelected: (_) {
                              if (isAll) {
                                setState(() {
                                  _selectedSubCategory = null;
                                  _selectedSubSubCategory = null;
                                });
                                return;
                              }

                              _onSelectSubCategory(home, categoryName, name);
                            },
                            selectedColor: const Color(0xFFEFF8E4),
                            labelStyle: TextStyle(
                              color: isSelected
                                  ? AppColors.success
                                  : AppColors.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(999),
                              side: BorderSide(
                                color: isSelected
                                    ? AppColors.success
                                    : const Color(0xFFE3E7EE),
                              ),
                            ),
                            backgroundColor: const Color(0xFFF7F9FC),
                          );
                        },
                      ),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.fromLTRB(14, 4, 14, 4),
                      child: Text(
                        'No sub-categories available for this category.',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  if ((selectedSubSubName ?? '').trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      child: Chip(
                        visualDensity: VisualDensity.compact,
                        backgroundColor: const Color(0xFFF2F6FF),
                        side: const BorderSide(color: Color(0xFFDAE6FF)),
                        label: Text(
                          selectedSubSubName!,
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () =>
                            setState(() => _selectedSubSubCategory = null),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _refreshCategoryProducts,
                      child: products.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                0,
                                12,
                                110,
                              ),
                              children: const [
                                SizedBox(height: 220),
                                Center(
                                  child: Text(
                                    'No products found for this selection',
                                    style: TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : GridView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                0,
                                12,
                                110,
                              ),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 2,
                                    mainAxisSpacing: 8,
                                    crossAxisSpacing: 8,
                                    childAspectRatio: 0.57,
                                  ),
                              itemCount: products.length,
                              itemBuilder: (_, i) {
                                final product = products[i];
                                final productId = _baseProductId(
                                  (product['id'] ?? '').toString(),
                                );
                                return ProductCard(
                                  product: product,
                                  showHeartIcon: false,
                                  showBoughtEarlierBadge: _purchasedProductIds
                                      .contains(productId),
                                  useFloatingVariantSnackbar: true,
                                );
                              },
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
