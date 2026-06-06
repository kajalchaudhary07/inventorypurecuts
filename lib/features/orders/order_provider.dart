// lib/core/models/order_provider.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:purecuts/core/constants/feature_flags.dart';
import 'package:purecuts/core/models/order_model.dart';
import 'package:purecuts/core/services/firestore_service.dart';

class OrderProvider extends ChangeNotifier {
  OrderProvider({FirestoreService? firestoreService})
    : _firestoreService = firestoreService ?? FirestoreService();

  final FirestoreService _firestoreService;

  // productId → full product map
  final Map<String, Map<String, dynamic>> _boughtProducts = {};
  bool _loading = false;
  String? _loadedUid;

  // Orders list
  final List<OrderModel> _orders = [];
  bool _ordersLoading = false;
  bool _ordersPagingLoading = false;
  bool _ordersHasMore = true;
  bool _ordersLegacyMode = false;
  DocumentSnapshot<Map<String, dynamic>>? _ordersCursor;
  String? _ordersLoadedUid;
  String? _ordersError;
  String _activeAuthUid = '';

  List<Map<String, dynamic>> get boughtProducts =>
      _boughtProducts.values.toList();
  bool get isLoading => _loading;

  List<OrderModel> get orders => _orders;
  bool get ordersLoading => _ordersLoading;
  bool get ordersPagingLoading => _ordersPagingLoading;
  bool get hasMoreOrders => _ordersHasMore;
  String? get ordersError => _ordersError;

  bool hasBought(String productId) => _boughtProducts.containsKey(productId);

  void _notifySafely() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase != SchedulerPhase.idle) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (hasListeners) notifyListeners();
      });
      return;
    }
    notifyListeners();
  }

  void syncAuthUid(String? uid) {
    final nextUid = (uid ?? '').trim();
    if (nextUid == _activeAuthUid) return;

    final shouldClear = _activeAuthUid.isNotEmpty && nextUid != _activeAuthUid;
    _activeAuthUid = nextUid;

    if (nextUid.isEmpty || shouldClear) {
      // Defer clear to avoid setState during build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        clear();
      });
    }
  }

  String _baseProductId(String value) {
    final id = value.trim();
    final sep = id.indexOf('::');
    if (sep <= 0) return id;
    return id.substring(0, sep);
  }

  void _storeItem(Map<String, dynamic> item) {
    final id = _baseProductId((item['id'] ?? '').toString());
    if (id.isEmpty) return;
    _boughtProducts[id] = {...item, 'id': id};
  }

  Future<void> loadPurchasedProducts({
    required String uid,
    bool forceRefresh = false,
  }) async {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty) {
      clear();
      return;
    }
    if (_loading) return;
    if (!forceRefresh && _loadedUid == cleanUid && _boughtProducts.isNotEmpty) {
      return;
    }

    _loading = true;
    _notifySafely();

    final existing = _loadedUid == cleanUid
        ? List<Map<String, dynamic>>.from(_boughtProducts.values)
        : const <Map<String, dynamic>>[];

    try {
      final remoteItems = await _firestoreService.getUserPurchasedProducts(
        uid: cleanUid,
      );

      _boughtProducts.clear();
      for (final item in remoteItems) {
        _storeItem(item);
      }
      for (final item in existing) {
        _storeItem(item);
      }
      _loadedUid = cleanUid;
    } finally {
      _loading = false;
      _notifySafely();
    }
  }

  /// Fetch user orders from Firestore
  Future<void> fetchUserOrders({
    required String uid,
    bool forceRefresh = false,
  }) async {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty) {
      _orders.clear();
      _ordersError = null;
      _notifySafely();
      return;
    }

    if (_ordersLoading) return;
    if (!forceRefresh && _ordersLoadedUid == cleanUid && _orders.isNotEmpty) {
      return;
    }

    _ordersLoading = true;
    _ordersError = null;
    _ordersPagingLoading = false;
    _notifySafely();

    try {
      _ordersCursor = null;
      _ordersHasMore = true;
      _ordersLegacyMode = false;

      _orders.clear();

      if (!FeatureFlags.enableOrdersPaging) {
        final orderDocs = await _firestoreService.getUserOrders(
          uid: cleanUid,
          maxOrders: FeatureFlags.maxOrdersFetch,
        );
        for (final doc in orderDocs) {
          _orders.add(OrderModel.fromMap(doc));
        }
        _orders.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        _ordersHasMore = false;
      } else {
        final page = await _firestoreService.getUserOrdersPage(
          uid: cleanUid,
          limit: FeatureFlags.defaultOrdersPageSize,
          startAfterDoc: null,
        );
        for (final row in page.orders) {
          _orders.add(OrderModel.fromMap(row));
        }
        _orders.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        _ordersCursor = page.lastDocument;
        _ordersHasMore = page.hasMore;
        _ordersLegacyMode = page.usedLegacyFallback;
      }

      _ordersLoadedUid = cleanUid;
      _ordersError = null;
    } catch (e) {
      _ordersError = 'Failed to load orders. Please try again.';
    } finally {
      _ordersLoading = false;
      _notifySafely();
    }
  }

  Future<void> fetchMoreUserOrders({required String uid}) async {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty) return;
    if (!FeatureFlags.enableOrdersPaging) return;
    if (_ordersLoading || _ordersPagingLoading || !_ordersHasMore) return;
    if (_ordersLoadedUid != cleanUid) return;
    if (_ordersLegacyMode) {
      _ordersHasMore = false;
      _notifySafely();
      return;
    }

    _ordersPagingLoading = true;
    _notifySafely();

    try {
      final page = await _firestoreService.getUserOrdersPage(
        uid: cleanUid,
        limit: FeatureFlags.defaultOrdersPageSize,
        startAfterDoc: _ordersCursor,
      );

      final existingKeys = _orders
          .map(
            (o) => (o.orderId.trim().isNotEmpty
                ? o.orderId
                : o.hashCode.toString()),
          )
          .toSet();

      for (final row in page.orders) {
        final model = OrderModel.fromMap(row);
        final key = model.orderId.trim().isNotEmpty
            ? model.orderId
            : model.hashCode.toString();
        if (existingKeys.add(key)) {
          _orders.add(model);
        }
      }

      _orders.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _ordersCursor = page.lastDocument;
      _ordersHasMore = page.hasMore;
      _ordersLegacyMode = page.usedLegacyFallback;
    } catch (e) {
      _ordersHasMore = false;
    } finally {
      _ordersPagingLoading = false;
      _notifySafely();
    }
  }

  /// Get orders filtered by status
  List<OrderModel> getOrdersByStatus(String status) {
    return _orders.where((o) => o.status == status.toLowerCase()).toList();
  }

  /// Search orders by ID
  List<OrderModel> searchOrders(String query) {
    if (query.isEmpty) return _orders;
    final q = query.toLowerCase();
    return _orders.where((o) => o.orderId.toLowerCase().contains(q)).toList();
  }

  void clear() {
    _boughtProducts.clear();
    _loadedUid = null;
    _loading = false;
    _orders.clear();
    _ordersLoadedUid = null;
    _ordersLoading = false;
    _ordersPagingLoading = false;
    _ordersHasMore = true;
    _ordersLegacyMode = false;
    _ordersCursor = null;
    _ordersError = null;
    _notifySafely();
  }

  /// Call this after a successful order confirmation
  void addOrderedItems(List<Map<String, dynamic>> items) {
    final now = DateTime.now();
    for (final item in items) {
      _storeItem({
        ...item,
        'lastOrderedAt': item['lastOrderedAt'] ?? now,
        'lastOrderStatus': item['lastOrderStatus'] ?? 'placed',
      });
    }
    _notifySafely();
  }
}
