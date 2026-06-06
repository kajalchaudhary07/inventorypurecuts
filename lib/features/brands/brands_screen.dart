import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/models/cart_model.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/core/widgets/sticky_cart_bar.dart';
import 'package:purecuts/features/home/home_provider.dart';
import 'package:purecuts/features/products/product_list_screen.dart';

class BrandsScreen extends StatefulWidget {
  const BrandsScreen({super.key});

  @override
  State<BrandsScreen> createState() => _BrandsScreenState();
}

class _BrandsScreenState extends State<BrandsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
  void dispose() {
    _searchController.dispose();
    super.dispose();
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

  Widget _buildBrandLogo(String imagePath, String brandName) {
    final resolved = _normalizeImagePath(imagePath);

    if (resolved.isEmpty) {
      return Center(
        child: Text(
          (brandName.trim().isNotEmpty ? brandName.trim()[0] : '?')
              .toUpperCase(),
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 28,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    if (resolved.startsWith('assets/')) {
      return Image.asset(
        resolved,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Center(
          child: Text(
            (brandName.trim().isNotEmpty ? brandName.trim()[0] : '?')
                .toUpperCase(),
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 28,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }

    return CachedNetworkImage(
      imageUrl: resolved,
      fit: BoxFit.contain,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      memCacheWidth: 220,
      maxWidthDiskCache: 220,
      errorWidget: (_, __, ___) => Center(
        child: Text(
          (brandName.trim().isNotEmpty ? brandName.trim()[0] : '?')
              .toUpperCase(),
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 28,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final home = context.watch<HomeProvider>();
    final brands = home.brands;
    final query = _searchQuery.trim().toLowerCase();
    final filteredBrands = query.isEmpty
        ? brands
        : brands
              .where((brand) {
                final name = (brand['name'] ?? '')
                    .toString()
                    .trim()
                    .toLowerCase();
                return name.contains(query);
              })
              .toList(growable: false);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
          systemStatusBarContrastEnforced: false,
        ),
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
                AppColors.background,
              ],
              stops: [0.0, 0.18, 0.42, 0.70, 1.0],
            ),
          ),
        ),
        title: const Text(
          'Brands',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDE9FE),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFFD7CCFF)),
                    ),
                    child: Text(
                      '${filteredBrands.length} available',
                      style: const TextStyle(
                        color: AppColors.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Discover products by trusted brands',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFDCD0FF)),
                ),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) => setState(() => _searchQuery = value),
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Search brands',
                    hintStyle: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textHint,
                    ),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: AppColors.textHint,
                    ),
                    suffixIcon: _searchQuery.trim().isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                            icon: const Icon(
                              Icons.close_rounded,
                              size: 18,
                              color: AppColors.textHint,
                            ),
                          ),
                    border: InputBorder.none,
                    isCollapsed: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                ),
              ),
            ),
            Expanded(
              child: home.loading
                  ? const Center(child: CircularProgressIndicator())
                  : filteredBrands.isEmpty
                  ? const Center(
                      child: Text(
                        'No brands available',
                        style: TextStyle(
                          color: AppColors.textHint,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 1.22,
                          ),
                      itemCount: filteredBrands.length,
                      itemBuilder: (_, i) {
                        final brand = filteredBrands[i];
                        final name = (brand['name'] ?? '').toString();
                        final image = (brand['image'] ?? brand['logo'] ?? '')
                            .toString();

                        return Material(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ProductListScreen(initialBrand: name),
                                ),
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: _buildBrandLogo(image, name),
                            ),
                          ),
                        );
                      },
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
