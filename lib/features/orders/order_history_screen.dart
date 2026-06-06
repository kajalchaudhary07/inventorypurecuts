import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/models/order_model.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';
import 'package:purecuts/features/orders/order_provider.dart';
import 'package:purecuts/features/orders/order_details_screen.dart';
import 'package:purecuts/features/products/product_detail_screen.dart';

class OrderHistoryScreen extends StatefulWidget {
  const OrderHistoryScreen({super.key});

  @override
  State<OrderHistoryScreen> createState() => _OrderHistoryScreenState();
}

class _OrderHistoryScreenState extends State<OrderHistoryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  final ScrollController _scrollController = ScrollController();
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String? _lastHydratedUid;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final uid = context.read<AuthProvider>().user?.uid ?? '';
    if (uid.trim().isEmpty) return;

    final threshold = _scrollController.position.maxScrollExtent - 220;
    if (_scrollController.position.pixels >= threshold) {
      context.read<OrderProvider>().fetchMoreUserOrders(uid: uid);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uid = context.read<AuthProvider>().user?.uid ?? '';
    if (uid == _lastHydratedUid) return;
    _lastHydratedUid = uid;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final orders = context.read<OrderProvider>();
      if (uid.trim().isEmpty) {
        orders.clear();
      } else {
        orders.fetchUserOrders(uid: uid, forceRefresh: true);
        orders.loadPurchasedProducts(uid: uid, forceRefresh: true);
      }
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  String _normalizeStatus(String? value) {
    final s = (value ?? '').trim().toLowerCase();
    if (s == 'completed') return 'delivered';
    if (s == 'out_for_delivery') return 'processing';
    if (s == 'in_transit') return 'processing';
    if (s == 'packed') return 'processing';
    if (s == 'dispatched') return 'processing';
    return s;
  }

  String _normalizeSearchText(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s,_-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  List<String> _extractTags(Map<String, dynamic> source) {
    final tags = <String>{};

    final singleTag = (source['tag'] ?? '').toString().trim();
    if (singleTag.isNotEmpty) {
      tags.add(singleTag);
    }

    final rawTags = source['tags'];
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

  bool _matchesQuery(String query, List<dynamic> parts) {
    final normalizedQuery = _normalizeSearchText(query);
    if (normalizedQuery.isEmpty) return true;

    final searchable = _normalizeSearchText(parts.join(' '));
    if (searchable.isEmpty) return false;
    if (searchable.contains(normalizedQuery)) return true;

    final tokens = normalizedQuery
        .split(' ')
        .where((token) => token.trim().isNotEmpty)
        .toList(growable: false);

    return tokens.every(searchable.contains);
  }

  bool _matchesBoughtProductQuery(Map<String, dynamic> product, String query) {
    return _matchesQuery(query, [
      product['name'],
      product['brand'],
      product['category'],
      product['subCategory'] ?? product['subcategory'],
      product['subSubCategory'] ?? product['subsubCategory'],
      product['description'],
      product['lastOrderId'],
      ..._extractTags(product),
    ]);
  }

  bool _matchesOrderQuery(OrderModel order, String query) {
    final itemParts = <dynamic>[];
    for (final item in order.items) {
      itemParts.addAll([
        item['name'],
        item['brand'],
        item['category'],
        item['subCategory'] ?? item['subcategory'],
        item['subSubCategory'] ?? item['subsubCategory'],
        item['description'],
        ..._extractTags(item),
      ]);
    }

    return _matchesQuery(query, [order.orderId, ...itemParts]);
  }

  List<OrderModel> _getFilteredOrders(
    List<OrderModel> allOrders,
    int tabIndex,
  ) {
    var list = allOrders;

    // Filter by status
    if (tabIndex == 1) {
      // Completed orders
      list = list
          .where(
            (o) =>
                _normalizeStatus(o.status) == 'delivered' ||
                _normalizeStatus(o.status) == 'cancelled',
          )
          .toList();
    } else if (tabIndex == 2) {
      // Ongoing orders
      list = list
          .where(
            (o) =>
                _normalizeStatus(o.status) == 'placed' ||
                _normalizeStatus(o.status) == 'confirmed' ||
                _normalizeStatus(o.status) == 'processing' ||
                _normalizeStatus(o.status) == 'packed' ||
                _normalizeStatus(o.status) == 'dispatched' ||
                _normalizeStatus(o.status) == 'out_for_delivery' ||
                _normalizeStatus(o.status) == 'in_transit',
          )
          .toList();
    }

    // Search by order ID
    if (_searchQuery.isNotEmpty) {
      list = list.where((o) => _matchesOrderQuery(o, _searchQuery)).toList();
    }

    return list;
  }

  List<Map<String, dynamic>> _getFilteredBought(
    List<Map<String, dynamic>> allBought,
    int tabIndex,
  ) {
    var list = allBought;

    if (tabIndex == 1) {
      // Completed orders
      list = list.where((p) {
        final status = _normalizeStatus(
          (p['lastOrderStatus'] ?? p['status'] ?? 'placed').toString(),
        );
        return status == 'delivered' || status == 'cancelled';
      }).toList();
    } else if (tabIndex == 2) {
      // Ongoing orders (exclude completed)
      list = list.where((p) {
        final status = _normalizeStatus(
          (p['lastOrderStatus'] ?? p['status'] ?? 'placed').toString(),
        );
        return status == 'placed' ||
            status == 'confirmed' ||
            status == 'processing' ||
            status == 'packed' ||
            status == 'dispatched' ||
            status == 'out_for_delivery' ||
            status == 'in_transit';
      }).toList();
    }

    if (_searchQuery.isNotEmpty) {
      list = list
          .where((p) => _matchesBoughtProductQuery(p, _searchQuery))
          .toList();
    }

    DateTime _toDate(dynamic value) {
      if (value is DateTime) return value;
      if (value is Timestamp) return value.toDate();
      if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
      if (value is String)
        return DateTime.tryParse(value) ??
            DateTime.fromMillisecondsSinceEpoch(0);
      return DateTime.fromMillisecondsSinceEpoch(0);
    }

    list.sort(
      (a, b) =>
          _toDate(b['lastOrderedAt']).compareTo(_toDate(a['lastOrderedAt'])),
    );

    return list;
  }

  @override
  Widget build(BuildContext context) {
    final orderProvider = context.watch<OrderProvider>();
    final allBought = orderProvider.boughtProducts;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7FB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Order History',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 17,
          ),
        ),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabs,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primary,
          labelStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
          tabs: const [
            Tab(text: 'All Orders'),
            Tab(text: 'Completed'),
            Tab(text: 'Ongoing'),
          ],
        ),
      ),
      body: Column(
        children: [
          // Search bar
          Container(
            color: const Color(0xFFF7F7FB),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: 'Search orders...',
                prefixIcon: const Icon(
                  Icons.search,
                  color: AppColors.textHint,
                  size: 20,
                ),
                filled: true,
                fillColor: Colors.white,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 13),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFE7E7F0)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFE7E7F0)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(
                    color: AppColors.primary,
                    width: 1.2,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: (orderProvider.ordersLoading || orderProvider.isLoading)
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabs,
                    children: [0, 1, 2].map((i) {
                      final filteredOrders = _getFilteredOrders(
                        orderProvider.orders,
                        i,
                      );
                      final filteredBought = _getFilteredBought(allBought, i);

                      if (filteredOrders.isEmpty && filteredBought.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.receipt_long_outlined,
                                color: AppColors.textHint,
                                size: 52,
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'No orders yet',
                                style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      if (filteredOrders.isEmpty && filteredBought.isNotEmpty) {
                        final showFooterLoader =
                            orderProvider.ordersPagingLoading;
                        return ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(16),
                          itemCount:
                              filteredBought.length +
                              (showFooterLoader ? 1 : 0),
                          itemBuilder: (_, idx) {
                            if (idx >= filteredBought.length) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Center(
                                  child: SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.2,
                                    ),
                                  ),
                                ),
                              );
                            }
                            return _BoughtOrderCard(
                              product: filteredBought[idx],
                            );
                          },
                        );
                      }

                      final showFooterLoader =
                          orderProvider.ordersPagingLoading &&
                          _searchQuery.trim().isEmpty;

                      return ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount:
                            filteredOrders.length + (showFooterLoader ? 1 : 0),
                        itemBuilder: (_, idx) {
                          if (idx >= filteredOrders.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Center(
                                child: SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                  ),
                                ),
                              ),
                            );
                          }
                          return _OrderCard(order: filteredOrders[idx]);
                        },
                      );
                    }).toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

class _BoughtOrderCard extends StatelessWidget {
  final Map<String, dynamic> product;
  const _BoughtOrderCard({required this.product});

  String _statusDisplay(String value) {
    final clean = value.trim().toLowerCase();
    if (clean.isEmpty) return 'Placed';
    if (clean == 'out_for_delivery') return 'Out for delivery';
    if (clean == 'in_transit') return 'In transit';
    return clean[0].toUpperCase() + clean.substring(1);
  }

  Color _statusFg(String status) {
    switch (status.trim().toLowerCase()) {
      case 'delivered':
        return const Color(0xFF0C9B4B);
      case 'cancelled':
        return const Color(0xFFC62828);
      case 'edited':
        return const Color(0xFF6D28D9);
      default:
        return AppColors.primary;
    }
  }

  Color _statusBg(String status) {
    switch (status.trim().toLowerCase()) {
      case 'delivered':
        return const Color(0xFFE9F8EF);
      case 'cancelled':
        return const Color(0xFFFFEDEE);
      case 'edited':
        return const Color(0xFFF3E8FF);
      default:
        return const Color(0xFFF1ECFF);
    }
  }

  String _formatDateTime(dynamic value) {
    DateTime? dt;
    if (value is DateTime) dt = value;
    if (value is Timestamp) dt = value.toDate();
    if (value is String) dt = DateTime.tryParse(value);
    if (value is int) dt = DateTime.fromMillisecondsSinceEpoch(value);
    if (dt == null) return 'Date/Time unavailable';
    return DateFormat('d MMM yyyy, h:mm a').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    final image = (product['image'] ?? '').toString();
    final name = (product['name'] ?? 'Product').toString();
    final brand = (product['brand'] ?? '').toString();
    final price = product['price'] ?? 0;
    final lastOrderId = (product['lastOrderId'] ?? '').toString();
    final lastStatus = (product['lastOrderStatus'] ?? 'Purchased').toString();
    final paymentMode = (product['lastPaymentMethod'] ?? '').toString();
    final lastOrderedAt = product['lastOrderedAt'];

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ProductDetailScreen(product: product),
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE8E8F1)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: image.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: image,
                      width: 68,
                      height: 68,
                      fit: BoxFit.cover,
                      fadeInDuration: Duration.zero,
                      fadeOutDuration: Duration.zero,
                      memCacheWidth: 136,
                      maxWidthDiskCache: 136,
                      errorWidget: (_, __, ___) => _placeholder(),
                    )
                  : _placeholder(),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: _statusBg(lastStatus),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          _statusDisplay(lastStatus),
                          style: TextStyle(
                            color: _statusFg(lastStatus),
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    brand,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatDateTime(lastOrderedAt),
                    style: const TextStyle(
                      color: AppColors.textHint,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    lastOrderId.isNotEmpty ? 'Order: $lastOrderId' : '-',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  if (paymentMode.trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      'Payment: ${paymentMode.toUpperCase()}',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 7),
                  Text(
                    '₹$price',
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
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

  Widget _placeholder() => Container(
    width: 68,
    height: 68,
    color: AppColors.surface,
    child: const Icon(Icons.image, color: AppColors.textHint, size: 28),
  );
}

class _OrderCard extends StatelessWidget {
  final OrderModel order;
  const _OrderCard({required this.order});

  Color _getStatusColor() {
    switch (order.status.toLowerCase()) {
      case 'delivered':
        return const Color(0xFF22C55E);
      case 'cancelled':
        return AppColors.error;
      case 'edited':
        return const Color(0xFF8B5CF6);
      case 'processing':
      case 'confirmed':
      case 'packed':
      case 'dispatched':
      case 'out_for_delivery':
      case 'in_transit':
        return AppColors.primary;
      case 'placed':
      default:
        return AppColors.textSecondary;
    }
  }

  Color _getStatusBackground() {
    switch (order.status.toLowerCase()) {
      case 'delivered':
        return const Color(0xFFDCFCE7);
      case 'cancelled':
        return const Color(0xFFFFEEEE);
      case 'edited':
        return const Color(0xFFF3E8FF);
      case 'processing':
      case 'confirmed':
      case 'packed':
      case 'dispatched':
      case 'out_for_delivery':
      case 'in_transit':
      case 'placed':
        return AppColors.primary.withOpacity(0.1);
      default:
        return AppColors.surface;
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _getStatusColor();
    final statusBg = _getStatusBackground();
    final productImage = order.items.isNotEmpty
        ? (order.items.first['image'] ?? '')
        : '';
    final actions = <Widget>[
      _actionBtn(
        label: 'Details',
        outline: true,
        minWidth: 102,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => OrderDetailsScreen(order: order)),
        ),
      ),
    ];

    if (order.canReorder) {
      actions.add(const SizedBox(height: 6));
      actions.add(
        _actionBtn(
          label: 'Reorder',
          outline: false,
          minWidth: 102,
          onTap: () {},
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE8E8F1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: (productImage.isNotEmpty)
                ? CachedNetworkImage(
                    imageUrl: productImage,
                    width: 68,
                    height: 68,
                    fit: BoxFit.cover,
                    fadeInDuration: Duration.zero,
                    fadeOutDuration: Duration.zero,
                    memCacheWidth: 136,
                    maxWidthDiskCache: 136,
                    errorWidget: (_, __, ___) => _buildPlaceholder(),
                  )
                : _buildPlaceholder(),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        order.orderId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: statusBg,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            order.statusDisplay,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  order.formattedDate,
                  style: const TextStyle(
                    color: AppColors.textHint,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${order.items.length} item(s) • ${order.deliveryAddressShort}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Payment: ${order.paymentMethod.toUpperCase()}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Text(
                        '₹${order.totalAmount}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: actions,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() => Container(
    width: 68,
    height: 68,
    color: AppColors.surface,
    child: const Icon(Icons.image, color: AppColors.textHint, size: 28),
  );

  Widget _actionBtn({
    required String label,
    required bool outline,
    required VoidCallback onTap,
    double minWidth = 0,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(minWidth: minWidth),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: outline ? Colors.white : AppColors.primary,
          border: Border.all(
            color: outline ? const Color(0xFFDADAEA) : AppColors.primary,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: outline ? AppColors.textSecondary : Colors.white,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
