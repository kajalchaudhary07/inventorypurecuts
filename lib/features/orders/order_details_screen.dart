import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';

import 'package:purecuts/core/constants/feature_flags.dart';
import 'package:purecuts/core/models/cart_model.dart';
import 'package:purecuts/core/models/order_model.dart';
import 'package:purecuts/core/services/firestore_service.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';
import 'package:purecuts/features/cart/cart_screen.dart';
import 'package:purecuts/features/orders/order_provider.dart';
import 'package:purecuts/features/products/product_detail_screen.dart';

class OrderDetailsScreen extends StatelessWidget {
  final OrderModel order;

  static const List<String> _cancelReasonOptions = [
    'Changed my mind',
    'Ordered by mistake',
    'Found better price elsewhere',
    'Delivery taking too long',
    'Need to change address or contact details',
    'Payment issue',
    'Other',
  ];

  const OrderDetailsScreen({super.key, required this.order});

  @override
  Widget build(BuildContext context) {
    final statusSteps = ['Placed', 'Confirmed', 'Processing', 'Delivered'];
    final currentStepIndex = _getCurrentStepIndex(order.status);

    return Scaffold(
      backgroundColor: const Color(0xFFF8F7FA),
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
                Color(0xFFF8F7FA),
              ],
              stops: [0.0, 0.18, 0.42, 0.70, 1.0],
            ),
          ),
        ),
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: AppColors.textPrimary,
            size: 18,
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Order Details',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 17,
            letterSpacing: -0.3,
          ),
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (order.hasEditHistory) ...[
            _buildInfoCard(
              icon: Icons.history_rounded,
              title: 'Edited order',
              message:
                  'This order was edited from ${order.originalOrderRef ?? order.originalOrderId ?? order.originalOrderDocumentId ?? 'the previous order'}.',
            ),
            const SizedBox(height: 12),
          ],

          // Order Header
          _buildCard(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        order.orderId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        order.formattedDateTime,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          const Icon(
                            Icons.payment_rounded,
                            size: 12,
                            color: AppColors.textHint,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            order.paymentMethod.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _getStatusColor(order.status).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _getStatusColor(order.status).withOpacity(0.3),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    order.statusDisplay,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _getStatusColor(order.status),
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Status Timeline
          _buildCard(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 20),
            child: _buildTimeline(statusSteps, currentStepIndex),
          ),
          const SizedBox(height: 12),

          // Edit window indicator
          if (order.canEdit || order.canCancel) _buildEditWindowBanner(),
          if (order.canEdit || order.canCancel)
            const SizedBox(height: 20)
          else
            const SizedBox(height: 20),

          // Delivery Address
          _sectionLabel('Delivery Address'),
          const SizedBox(height: 8),
          _buildCard(
            padding: const EdgeInsets.all(16),
            child: _buildAddressSection(
              receiverName: order.receiverName,
              receiverPhone: order.receiverPhone,
              address: order.deliveryAddressString,
            ),
          ),
          const SizedBox(height: 20),

          // Items
          _sectionLabel('Items (${order.items.length})'),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFEEEEF0)),
            ),
            child: Column(children: _buildItemsList(context)),
          ),
          const SizedBox(height: 20),

          // Bill Details
          _sectionLabel('Bill Details'),
          const SizedBox(height: 8),
          _buildCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                const SizedBox(height: 8),
                _buildBillRow(
                  'Item Total',
                  '₹${order.billDetails?['itemTotal'] ?? order.totalAmount}',
                ),
                _buildDivider(),
                _buildBillRow(
                  'Delivery Charge',
                  order.billDetails?['deliveryCharge'] == 0
                      ? 'FREE'
                      : '₹${order.billDetails?['deliveryCharge'] ?? 0}',
                  valueColor: order.billDetails?['deliveryCharge'] == 0
                      ? const Color(0xFF22C55E)
                      : null,
                ),
                _buildDivider(),
                _buildBillRow(
                  'Handling Charge',
                  '₹${order.billDetails?['handlingCharge'] ?? 0}',
                ),
                const SizedBox(height: 4),
                Container(height: 1, color: const Color(0xFFE8E8EC)),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Grand Total',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.2,
                      ),
                    ),
                    Text(
                      '₹${order.totalAmount}',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Payment & Contact — two-column row
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 420;
              return Flex(
                direction: isNarrow ? Axis.vertical : Axis.horizontal,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: isNarrow ? 0 : 1,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sectionLabel('Payment Method'),
                        const SizedBox(height: 8),
                        _buildCard(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.account_balance_wallet_outlined,
                                size: 16,
                                color: AppColors.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  order.paymentMethod.toUpperCase(),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.primary,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: isNarrow ? 0 : 12, height: isNarrow ? 12 : 0),
                  Expanded(
                    flex: isNarrow ? 0 : 1,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sectionLabel('Customer Email'),
                        const SizedBox(height: 8),
                        _buildCard(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.mail_outline_rounded,
                                size: 16,
                                color: AppColors.textHint,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: SelectableText(
                                  order.customerEmail.trim().isEmpty
                                      ? '—'
                                      : order.customerEmail,
                                  maxLines: 3,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textSecondary,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),

          // Action Buttons
          if (order.canCancel)
            SizedBox(
              height: 48,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.error, width: 1.2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  backgroundColor: AppColors.error.withOpacity(0.03),
                ),
                onPressed: () => _showCancelConfirmation(context),
                child: const Text(
                  'Cancel Order',
                  style: TextStyle(
                    color: AppColors.error,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          if (order.canEdit) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => _startEditOrder(context),
                icon: const Icon(Icons.edit_outlined, size: 17),
                label: const Text(
                  'Edit Order',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.lock_clock_outlined,
                  size: 13,
                  color: AppColors.textHint,
                ),
                const SizedBox(width: 5),
                Text(
                  'Edit window closes ${FeatureFlags.orderEditWindowHours}h after order placement',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textHint,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ],
          if (order.canReorder) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 52,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => _showReorderConfirmation(context),
                child: const Text(
                  'Reorder',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─── UI Helpers ──────────────────────────────────────────────────────────────

  Widget _buildCard({required Widget child, EdgeInsets? padding}) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFFEEEEF0)),
    ),
    padding: padding,
    child: child,
  );

  Widget _buildEditWindowBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.access_time_rounded,
            size: 16,
            color: Color(0xFFD97706),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF92400E),
                  height: 1.4,
                ),
                children: [
                  const TextSpan(text: 'Orders can only be edited within '),
                  TextSpan(
                    text: '${FeatureFlags.orderEditWindowHours} hours',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const TextSpan(text: ' of placement.'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
    text.toUpperCase(),
    style: const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: AppColors.textHint,
      letterSpacing: 0.8,
    ),
  );

  Widget _buildDivider() =>
      const Divider(height: 1, thickness: 1, color: Color(0xFFF2F2F4));

  Widget _buildTimeline(List<String> steps, int currentIndex) {
    return Row(
      children: List.generate(steps.length, (i) {
        final isCompleted = i <= currentIndex;
        final isLast = i == steps.length - 1;

        return Expanded(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        // connector line left
                        if (i > 0)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              height: 2,
                              width: double.infinity,
                              color: i <= currentIndex
                                  ? AppColors.primary.withOpacity(0.4)
                                  : const Color(0xFFE8E8EC),
                            ),
                          ),
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isCompleted
                                ? AppColors.primary
                                : Colors.white,
                            border: Border.all(
                              color: isCompleted
                                  ? AppColors.primary
                                  : const Color(0xFFDDDDE0),
                              width: 1.5,
                            ),
                          ),
                          child: Center(
                            child: isCompleted
                                ? const Icon(
                                    Icons.check_rounded,
                                    color: Colors.white,
                                    size: 14,
                                  )
                                : Text(
                                    '${i + 1}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.textHint,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      steps[i],
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: isCompleted
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: isCompleted
                            ? AppColors.textPrimary
                            : AppColors.textHint,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              if (!isLast)
                Container(
                  height: 2,
                  width: 16,
                  color: i < currentIndex
                      ? AppColors.primary.withOpacity(0.4)
                      : const Color(0xFFE8E8EC),
                ),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildAddressSection({
    required String receiverName,
    required String receiverPhone,
    required String address,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Icon(
            Icons.person_outline_rounded,
            size: 15,
            color: AppColors.textHint,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              receiverName,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 5),
      Row(
        children: [
          const Icon(Icons.phone_outlined, size: 14, color: AppColors.textHint),
          const SizedBox(width: 6),
          Text(
            receiverPhone,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.location_on_outlined,
            size: 15,
            color: AppColors.textHint,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              address,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    ],
  );

  List<Widget> _buildItemsList(BuildContext context) {
    final lockedQuantities = _editLockedQuantities();

    return order.items.asMap().entries.map((entry) {
      final i = entry.key;
      final item = entry.value;
      final isLast = i == order.items.length - 1;

      final qty = (item['quantity'] ?? 1) is num
          ? (item['quantity'] as num).toInt()
          : int.tryParse((item['quantity'] ?? '1').toString()) ?? 1;
      final price = (item['price'] ?? 0) is num
          ? (item['price'] as num).toDouble()
          : double.tryParse((item['price'] ?? '0').toString()) ?? 0;
      final product = _toProductPayload(item);
      final imageUrl = (product['image'] ?? '').toString();
      final productId = (item['productId'] ?? item['id'] ?? '')
          .toString()
          .trim();
      final lockedQty = lockedQuantities[productId] ?? 0;
      final chargeableQty = qty > lockedQty ? qty - lockedQty : 0;

      void openProduct() {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ProductDetailScreen(product: product),
          ),
        );
      }

      return Column(
        children: [
          InkWell(
            onTap: openProduct,
            borderRadius: isLast
                ? const BorderRadius.vertical(bottom: Radius.circular(14))
                : BorderRadius.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  InkWell(
                    onTap: openProduct,
                    borderRadius: BorderRadius.circular(10),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: imageUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: imageUrl,
                              width: 58,
                              height: 58,
                              fit: BoxFit.cover,
                              fadeInDuration: Duration.zero,
                              fadeOutDuration: Duration.zero,
                              memCacheWidth: 116,
                              maxWidthDiskCache: 116,
                              errorWidget: (_, __, ___) => _itemPlaceholder(),
                            )
                          : _itemPlaceholder(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item['name'] ?? 'Product',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          lockedQty > 0
                              ? '${item['brand'] ?? ''}  •  Qty: $qty (+$lockedQty prev)'
                              : '${item['brand'] ?? ''}  •  Qty: $qty',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '₹${(price * chargeableQty).toStringAsFixed(0)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!isLast)
            const Divider(
              height: 1,
              thickness: 1,
              indent: 84,
              color: Color(0xFFF2F2F4),
            ),
        ],
      );
    }).toList();
  }

  Widget _itemPlaceholder() => Container(
    width: 58,
    height: 58,
    decoration: BoxDecoration(
      color: const Color(0xFFF4F4F6),
      borderRadius: BorderRadius.circular(10),
    ),
    child: const Icon(
      Icons.image_outlined,
      color: AppColors.textHint,
      size: 22,
    ),
  );

  Map<String, int> _editLockedQuantities() {
    final editMeta = order.editMeta;
    final raw = editMeta == null ? null : editMeta['lockedQuantities'];
    if (raw is! Map) return const <String, int>{};

    final out = <String, int>{};
    raw.forEach((key, value) {
      final qty = value is num
          ? value.toInt()
          : int.tryParse(value.toString()) ?? 0;
      final productId = key.toString().trim();
      if (productId.isNotEmpty && qty > 0) {
        out[productId] = qty;
      }
    });
    return out;
  }

  Map<String, dynamic> _toProductPayload(Map<String, dynamic> item) {
    final rawId = (item['productId'] ?? item['id'] ?? '').toString().trim();
    final normalizedId = rawId.contains('::')
        ? rawId.split('::').first.trim()
        : rawId;

    return {
      ...item,
      'id': normalizedId,
      'productId': normalizedId,
      'price': item['price'] ?? 0,
      'name': (item['name'] ?? 'Product').toString(),
      'brand': (item['brand'] ?? '').toString(),
      'image': (item['image'] ?? '').toString(),
      'description': (item['description'] ?? '').toString(),
    };
  }

  Widget _buildBillRow(String label, String value, {Color? valueColor}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: valueColor ?? AppColors.textPrimary,
              ),
            ),
          ],
        ),
      );

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'delivered':
        return const Color(0xFF22C55E);
      case 'cancelled':
        return AppColors.error;
      case 'edited':
        return const Color(0xFF8B5CF6);
      case 'processing':
      case 'confirmed':
        return AppColors.primary;
      case 'placed':
      default:
        return AppColors.textSecondary;
    }
  }

  int _getCurrentStepIndex(String status) {
    switch (status.toLowerCase()) {
      case 'placed':
        return 0;
      case 'confirmed':
        return 1;
      case 'processing':
        return 2;
      case 'delivered':
        return 3;
      default:
        return 0;
    }
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F2FF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE6D8FF)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.primary, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _startEditOrder(BuildContext context) {
    if (!order.canEdit) return;

    context.read<CartModel>().startEditSession(order);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CartScreen()),
    );
  }

  Future<void> _cancelOrder(
    BuildContext context, {
    required String selectedReason,
  }) async {
    final auth = context.read<AuthProvider>();
    final uid = (auth.user?.uid ?? order.uid).trim();

    if (uid.isEmpty || order.orderId.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to cancel order right now')),
      );
      return;
    }

    bool success = false;
    try {
      final service = FirestoreService();
      success = await service.cancelOrderByUser(
        uid: uid,
        orderRef: order.orderId,
        orderDocumentId: order.orderDocumentId,
        reason: selectedReason,
      );
    } catch (_) {
      success = false;
    }

    if (!context.mounted) return;

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Order cancellation failed. Please try again.'),
        ),
      );
      return;
    }

    await context.read<OrderProvider>().fetchUserOrders(
      uid: uid,
      forceRefresh: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await context.read<OrderProvider>().loadPurchasedProducts(
      uid: uid,
      forceRefresh: true,
    );

    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Order cancelled successfully')),
    );
    Navigator.pop(context);
  }

  void _showCancelConfirmation(BuildContext context) {
    String selectedReason = _cancelReasonOptions.first;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text(
            'Cancel Order',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Please choose a reason for cancellation:',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: selectedReason,
                isExpanded: true,
                decoration: InputDecoration(
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFFE0E0E4)),
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                items: _cancelReasonOptions
                    .map(
                      (reason) => DropdownMenuItem<String>(
                        value: reason,
                        child: Text(
                          reason,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value == null) return;
                  setStateDialog(() => selectedReason = value);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'No',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _cancelOrder(context, selectedReason: selectedReason);
              },
              child: const Text(
                'Yes, Cancel',
                style: TextStyle(
                  color: AppColors.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showReorderConfirmation(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Reorder',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        content: const Text(
          'Add all items from this order to your cart?',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Items added to cart')),
              );
            },
            child: const Text(
              'Add to Cart',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
