import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/core/theme/spacing.dart';
import 'package:purecuts/core/models/cart_model.dart';
import 'package:purecuts/core/utils/tier_pricing.dart';
import 'package:purecuts/features/main_nav/main_nav_screen.dart';
import 'package:purecuts/features/orders/checkout_screen.dart';
import 'package:purecuts/features/products/product_detail_screen.dart';

class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
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
        leading: GestureDetector(
          onTap: () => Navigator.pop(context),
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Icon(
              Icons.arrow_back_ios_new_rounded,
              color: AppColors.textPrimary,
              size: 18,
            ),
          ),
        ),
        title: const Text(
          'Cart',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 18,
            letterSpacing: -0.3,
          ),
        ),
        centerTitle: true,
        actions: [
          Consumer<CartModel>(
            builder: (_, cart, __) => cart.itemCount > 0
                ? TextButton(
                    onPressed: () => context.read<CartModel>().clear(),
                    child: const Text(
                      'Clear',
                      style: TextStyle(
                        color: AppColors.textHint,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      body: Consumer<CartModel>(
        builder: (_, cart, __) {
          if (cart.items.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.shopping_bag_outlined,
                      color: AppColors.primary,
                      size: 36,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  const Text(
                    'Your cart is empty',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  const Text(
                    'Add products to get started',
                    style: TextStyle(color: AppColors.textHint, fontSize: 14),
                  ),
                ],
              ),
            );
          }

          final tax = (cart.totalPrice * 0.08).round();
          final grandTotal = cart.totalPrice + tax;
          final isEditMode = cart.isEditSessionActive;

          return Stack(
            children: [
              ListView(
                padding: const EdgeInsets.only(bottom: 140),
                children: [
                  if (isEditMode)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.md,
                        AppSpacing.lg,
                        AppSpacing.sm,
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF7F2FF),
                          borderRadius: BorderRadius.circular(AppRadius.xl),
                          border: Border.all(color: const Color(0xFFE3D4F4)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.edit_outlined,
                              color: AppColors.primary,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Edit mode: the original order items are locked. You can add more products, and only the added items will be charged.',
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 12.5,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (isEditMode)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        0,
                        AppSpacing.lg,
                        AppSpacing.sm,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: AppColors.primary),
                            foregroundColor: AppColors.primary,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppRadius.lg),
                            ),
                          ),
                          onPressed: () {
                            Navigator.of(context).pushAndRemoveUntil(
                              MaterialPageRoute(
                                builder: (_) => const MainNavScreen(),
                              ),
                              (route) => false,
                            );
                          },
                          icon: const Icon(
                            Icons.add_shopping_cart_rounded,
                            size: 18,
                          ),
                          label: const Text(
                            'Add More Items',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.sm),
                  // Cart items
                  ...cart.items.map((item) => _CartItem(item: item)),
                  const SizedBox(height: AppSpacing.lg),
                  // Promo code
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(AppRadius.xxl),
                      ),
                      child: Row(
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(left: AppSpacing.lg),
                            child: Icon(
                              Icons.sell_outlined,
                              color: AppColors.textHint,
                              size: 18,
                            ),
                          ),
                          Expanded(
                            child: TextField(
                              style: const TextStyle(
                                fontSize: 14,
                                color: AppColors.textPrimary,
                              ),
                              decoration: const InputDecoration(
                                hintText: 'Enter promo code',
                                hintStyle: TextStyle(
                                  color: AppColors.textHint,
                                  fontSize: 14,
                                ),
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: AppSpacing.md,
                                  vertical: AppSpacing.lg,
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(AppSpacing.xs),
                            child: TextButton(
                              style: TextButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.md,
                                  ),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.lg,
                                  vertical: AppSpacing.md,
                                ),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () {},
                              child: const Text(
                                'Apply',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  // Order summary card
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(AppRadius.xxl),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Order Summary',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          _summaryRow('Subtotal', '\u20B9${cart.totalPrice}'),
                          const SizedBox(height: AppSpacing.md),
                          _summaryRow(
                            'Shipping',
                            'FREE',
                            valueColor: AppColors.success,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          _summaryRow('Tax (8%)', '\u20B9$tax'),
                          const Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: AppSpacing.md,
                            ),
                            child: Divider(
                              height: 1,
                              thickness: 1,
                              color: AppColors.divider,
                            ),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Total',
                                style: TextStyle(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                              Text(
                                '\u20B9$grandTotal',
                                style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 20,
                                  letterSpacing: -0.5,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ),
              // Sticky checkout bar
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    AppSpacing.xl,
                    AppSpacing.md,
                    AppSpacing.xl,
                    MediaQuery.of(context).padding.bottom + AppSpacing.md,
                  ),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(
                      top: BorderSide(color: AppColors.divider, width: 1),
                    ),
                  ),
                  child: Row(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'TOTAL',
                            style: TextStyle(
                              color: AppColors.textHint,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.0,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '\u20B9$grandTotal',
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w800,
                              fontSize: 22,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: AppSpacing.lg),
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 15),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppRadius.xl),
                            ),
                            elevation: 0,
                          ),
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const CheckoutScreen(),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                isEditMode
                                    ? 'Continue Edit Order'
                                    : 'Proceed to Checkout',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                              SizedBox(width: 6),
                              Icon(Icons.arrow_forward_rounded, size: 16),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _summaryRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
        ),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? AppColors.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _CartItem extends StatelessWidget {
  final dynamic item;
  const _CartItem({required this.item});

  int? _bulkTriggerQty() {
    if (item.pricingTiers is! List<PricingTier>) return null;
    final tiers = item.pricingTiers as List<PricingTier>;
    if (tiers.isEmpty) return null;
    final basePrice = (item.basePrice as int?) ?? (item.price as int?) ?? 0;
    for (final tier in tiers) {
      if (tier.price < basePrice) return tier.minQty;
    }
    return null;
  }

  Map<String, dynamic> _toProductMap() {
    return {
      'id': item.id,
      'name': item.name,
      'brand': item.brand,
      'image': item.image,
      'price': item.price,
      'basePrice': item.basePrice,
      'pricingType': item.pricingType,
      'pricingTiers': (item.pricingTiers as List<PricingTier>)
          .map((tier) => tier.toMap())
          .toList(growable: false),
    };
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartModel>();
    final locked = cart.isLockedItem(item.id);
    final triggerQty = _bulkTriggerQty();
    final bulkReached =
        triggerQty != null && (item.quantity as int) >= triggerQty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.xxl),
        ),
        child: Row(
          children: [
            // Product image
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                child: CachedNetworkImage(
                  imageUrl: item.image,
                  width: 72,
                  height: 72,
                  fit: BoxFit.contain,
                  fadeInDuration: Duration.zero,
                  fadeOutDuration: Duration.zero,
                  memCacheWidth: 144,
                  maxWidthDiskCache: 144,
                  errorWidget: (_, __, ___) => const Icon(
                    Icons.image_outlined,
                    color: AppColors.textHint,
                    size: 28,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          item.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: locked
                            ? null
                            : () {
                                final cartModel = context.read<CartModel>();
                                for (int i = 0; i < item.quantity; i++) {
                                  cartModel.remove(item.id);
                                }
                              },
                        child: const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: Icon(
                            Icons.close_rounded,
                            color: AppColors.textHint,
                            size: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '\u20B9${item.price}',
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                      // Qty pill / bulk action
                      bulkReached
                          ? SizedBox(
                              height: 32,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.md,
                                    ),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  textStyle: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => ProductDetailScreen(
                                        product: _toProductMap(),
                                        autoOpenBulkOrderSheet: true,
                                      ),
                                    ),
                                  );
                                },
                                child: const Text('Bulk order'),
                              ),
                            )
                          : Container(
                              height: 32,
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.md,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _qtyBtn(
                                    Icons.remove,
                                    () => context.read<CartModel>().remove(
                                      item.id,
                                    ),
                                    enabled:
                                        !locked ||
                                        item.quantity >
                                            cart.lockedQuantityOf(item.id),
                                  ),
                                  SizedBox(
                                    width: 30,
                                    child: Text(
                                      '${item.quantity}',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: AppColors.textPrimary,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  _qtyBtn(Icons.add, () {
                                    context.read<CartModel>().add({
                                      'id': item.id,
                                      'name': item.name,
                                      'brand': item.brand,
                                      'image': item.image,
                                      'price': item.price,
                                      'basePrice': item.basePrice,
                                      'pricingType': item.pricingType,
                                      'pricingTiers':
                                          (item.pricingTiers
                                                  as List<PricingTier>)
                                              .map((tier) => tier.toMap())
                                              .toList(growable: false),
                                    });
                                    if (triggerQty != null &&
                                        (item.quantity as int) + 1 >=
                                            triggerQty) {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => ProductDetailScreen(
                                            product: _toProductMap(),
                                            autoOpenBulkOrderSheet: true,
                                          ),
                                        ),
                                      );
                                    }
                                  }),
                                ],
                              ),
                            ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _qtyBtn(IconData icon, VoidCallback onTap, {bool enabled = true}) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Icon(
          icon,
          color: enabled ? AppColors.textSecondary : AppColors.textHint,
          size: 14,
        ),
      ),
    );
  }
}
