import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:confetti/confetti.dart';
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth;
import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/models/cart_model.dart';
import 'package:purecuts/core/constants/feature_flags.dart';
import 'package:purecuts/core/models/order_model.dart';
import 'package:purecuts/core/services/firestore_service.dart';
import 'package:purecuts/core/services/image_bandwidth_telemetry.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/core/theme/spacing.dart';
import 'package:purecuts/core/services/performance_trace_service.dart';
import 'package:purecuts/core/utils/product_image_contract.dart';
import 'package:purecuts/core/utils/variant_selection_guard.dart';
import 'package:purecuts/core/services/payu_payment_service.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';
import 'package:purecuts/features/home/home_provider.dart';
import 'package:purecuts/features/orders/order_confirm_screen.dart';
import 'package:purecuts/features/products/product_detail_screen.dart';

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({
    super.key,
    this.autoFinalizeRecoveredPayuOrder = false,
    this.editOrder,
  });

  final bool autoFinalizeRecoveredPayuOrder;
  final OrderModel? editOrder;

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  static const String _codPaymentMethod = 'Cash on Delivery';
  static const String _payuPaymentMethod =
      'Pay Online (UPI/Card/NetBanking/Wallet)';

  static const int _defaultPuneDeliveryCharge = 19;
  static const int _defaultMaharashtraDeliveryCharge = 30;
  static const int _defaultOutsideMaharashtraDeliveryCharge = 89;
  static const int _defaultFreeDeliveryThreshold = 1000;

  int _puneDeliveryCharge = _defaultPuneDeliveryCharge;
  int _maharashtraDeliveryCharge = _defaultMaharashtraDeliveryCharge;
  int _outsideMaharashtraDeliveryCharge =
      _defaultOutsideMaharashtraDeliveryCharge;
  int _freeDeliveryThreshold = _defaultFreeDeliveryThreshold;

  static const Set<String> _punePincodes = {
    '411001',
    '411002',
    '411003',
    '411004',
    '411005',
    '411006',
    '411007',
    '411008',
    '411009',
    '411010',
    '411011',
    '411012',
    '411013',
    '411014',
    '411015',
    '411016',
    '411017',
    '411018',
    '411019',
    '411020',
    '411021',
    '411022',
    '411023',
    '411024',
    '411025',
    '411026',
    '411027',
    '411028',
    '411029',
    '411030',
    '411031',
    '411032',
    '411033',
    '411034',
    '411035',
    '411036',
    '411037',
    '411038',
    '411039',
    '411040',
    '411041',
    '411042',
    '411043',
    '411044',
    '411045',
    '411046',
    '411047',
    '411048',
    '411050',
    '411051',
    '412001',
    '412108',
    '412115',
    '412207',
  };

  String _selectedPaymentMethod = _codPaymentMethod;

  final TextEditingController _line1Controller = TextEditingController();
  final TextEditingController _line2Controller = TextEditingController();
  final TextEditingController _landmarkController = TextEditingController();
  final TextEditingController _cityController = TextEditingController();
  final TextEditingController _stateController = TextEditingController();
  final TextEditingController _pincodeController = TextEditingController();
  final TextEditingController _mapLinkController = TextEditingController();
  final TextEditingController _receiverNameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _productSuggestionController =
      TextEditingController();

  final GlobalKey<FormState> _detailsFormKey = GlobalKey<FormState>();
  final List<Map<String, dynamic>> _savedAddresses = [];
  int _selectedAddressIndex = 0;
  bool _initialAddressPromptShown = false;
  bool _isPlacingOrder = false;
  String? _recoveredPayuTxnId;
  String? _recoveredPayuStatus;
  String? _recoveredSuccessfulPayuTxnId;
  bool _checkingRecoveredPayment = false;
  bool _autoFinalizeAttempted = false;
  bool _suggestionUploading = false;
  Trace? _checkoutLoadTrace;
  ConfettiController? _freeDeliveryConfettiController;
  bool _wasFreeDeliveryUnlocked = false;
  bool _showingFreeDeliveryPopup = false;
  bool _editSessionPrimed = false;

  ConfettiController _ensureFreeDeliveryConfettiController() {
    return _freeDeliveryConfettiController ??= ConfettiController(
      duration: const Duration(milliseconds: 1200),
    );
  }

  void _startCheckoutLoadTrace() {
    if (_checkoutLoadTrace != null) return;
    final trace = FirebasePerformance.instance.newTrace('checkout_load_time');
    _checkoutLoadTrace = trace;
    unawaited(trace.start());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_stopCheckoutLoadTrace());
    });
  }

  Future<void> _stopCheckoutLoadTrace() async {
    final trace = _checkoutLoadTrace;
    _checkoutLoadTrace = null;
    if (trace != null) {
      await trace.stop();
    }
  }

  String _friendlyPaymentNotCompletedMessage(String reasonRaw) {
    final reason = reasonRaw.trim().toLowerCase();
    if (reason.isEmpty) {
      return 'Payment not completed. Please try again.';
    }

    if (reason.contains('cancel')) {
      return 'Payment was cancelled. You can try again.';
    }

    final hasNetworkIssue =
        reason.contains('socketexception') ||
        reason.contains('failed host lookup') ||
        reason.contains('no address associated with hostname') ||
        reason.contains('network is unreachable') ||
        reason.contains('connection refused') ||
        reason.contains('connection reset') ||
        reason.contains('timeout') ||
        reason.contains('timed out');

    if (hasNetworkIssue) {
      return 'Unable to connect to payment service. Please check your internet and try again.';
    }

    if (reason == 'payment-error' ||
        reason.contains('sync-failure') ||
        reason.contains('sync-cancelled') ||
        reason.contains('failure') ||
        reason.contains('error')) {
      return 'Payment could not be completed right now. Please try again.';
    }

    return 'Payment not completed. Please try again.';
  }

  void _applyAddressEntry(Map<String, dynamic> entry) {
    final address = (entry['deliveryAddress'] is Map)
        ? Map<String, dynamic>.from(entry['deliveryAddress'] as Map)
        : const <String, dynamic>{};
    final contact = (entry['contactDetails'] is Map)
        ? Map<String, dynamic>.from(entry['contactDetails'] as Map)
        : const <String, dynamic>{};

    _line1Controller.text = (address['line1'] ?? '').toString();
    _line2Controller.text = (address['line2'] ?? '').toString();
    _landmarkController.text = (address['landmark'] ?? '').toString();
    _cityController.text = (address['city'] ?? '').toString();
    _stateController.text = (address['state'] ?? '').toString();
    _pincodeController.text = (address['pincode'] ?? '').toString();
    _mapLinkController.text = (address['mapLink'] ?? '').toString();
    _receiverNameController.text = (contact['receiverName'] ?? '').toString();
    _phoneController.text = (contact['phone'] ?? '').toString();
  }

  void _hydrateAddressesFromUser(AuthProvider auth) {
    final user = auth.user;
    final savedDeliveryDetails =
        user?.deliveryDetails ?? const <String, dynamic>{};

    final addressesFromDelivery = (savedDeliveryDetails['addresses'] is List)
        ? (savedDeliveryDetails['addresses'] as List)
              .whereType<Map>()
              .map((entry) => Map<String, dynamic>.from(entry))
              .toList(growable: true)
        : <Map<String, dynamic>>[];

    if (addressesFromDelivery.isEmpty) {
      final fallbackAddress =
          user?.deliveryAddressDetails ?? const <String, dynamic>{};
      final fallbackContact = user?.contactDetails ?? const <String, dynamic>{};
      final hasFallback = (fallbackAddress['line1'] ?? '')
          .toString()
          .trim()
          .isNotEmpty;
      if (hasFallback) {
        addressesFromDelivery.add({
          'deliveryAddress': Map<String, dynamic>.from(fallbackAddress),
          'contactDetails': Map<String, dynamic>.from(fallbackContact),
        });
      }
    }

    _savedAddresses
      ..clear()
      ..addAll(addressesFromDelivery);

    final preferredIndex =
        (savedDeliveryDetails['selectedAddressIndex'] as num?)?.toInt() ?? 0;
    _selectedAddressIndex = _savedAddresses.isEmpty
        ? 0
        : preferredIndex.clamp(0, _savedAddresses.length - 1);

    if (_savedAddresses.isNotEmpty) {
      _applyAddressEntry(_savedAddresses[_selectedAddressIndex]);
    }
  }

  @override
  void initState() {
    super.initState();
    _startCheckoutLoadTrace();
    _ensureFreeDeliveryConfettiController();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _editSessionPrimed || widget.editOrder == null) return;
      final cart = context.read<CartModel>();
      if (!cart.isEditSessionActive) {
        cart.startEditSession(widget.editOrder!);
      }
      _editSessionPrimed = true;
      setState(() {});
    });

    final auth = context.read<AuthProvider>();
    _hydrateAddressesFromUser(auth);

    if (_savedAddresses.isEmpty) {
      final user = auth.user;
      _stateController.text = (user?.state ?? '').toString();
      _pincodeController.text = (user?.pincode ?? '').toString();
      _receiverNameController.text = (user?.ownerName ?? user?.name ?? '')
          .toString();
      _phoneController.text = (user?.phone ?? '').toString();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _initialAddressPromptShown) return;
        _initialAddressPromptShown = true;
        _openDetailsBottomSheet(blocking: true, editIndex: null);
      });
    }

    Future.microtask(() {
      final home = context.read<HomeProvider>();
      if (home.productMaps.isEmpty && !home.loading) {
        home.loadData();
      }
    });

    unawaited(_loadDeliverySettings());

    unawaited(_recoverPendingOnlinePayment());
  }

  @override
  void dispose() {
    unawaited(_stopCheckoutLoadTrace());
    _freeDeliveryConfettiController?.dispose();
    _freeDeliveryConfettiController = null;
    _line1Controller.dispose();
    _line2Controller.dispose();
    _landmarkController.dispose();
    _cityController.dispose();
    _stateController.dispose();
    _pincodeController.dispose();
    _mapLinkController.dispose();
    _receiverNameController.dispose();
    _phoneController.dispose();
    _productSuggestionController.dispose();
    super.dispose();
  }

  String _baseProductId(String value) {
    final id = value.trim();
    if (id.isEmpty) return '';
    final sep = id.indexOf('::');
    if (sep <= 0) return id;
    return id.substring(0, sep);
  }

  int? _bulkTriggerQtyForCartItem(CartItem item) {
    final tiers = item.pricingTiers;
    if (tiers.isEmpty) return null;
    final basePrice = item.basePrice > 0 ? item.basePrice : item.price;
    for (final tier in tiers) {
      if (tier.price < basePrice) return tier.minQty;
    }
    return null;
  }

  Map<String, dynamic> _productMapFromCartItem(CartItem item) {
    return {
      'id': _baseProductId(item.id),
      'name': item.name,
      'brand': item.brand,
      'image': item.image,
      'price': item.price,
      'basePrice': item.basePrice,
      'pricingType': item.pricingType,
      'pricingTiers': item.pricingTiers
          .map((tier) => tier.toMap())
          .toList(growable: false),
    };
  }

  Map<String, dynamic>? _buildEditMeta(CartModel cart) {
    if (!cart.isEditSessionActive) return null;

    final order = widget.editOrder;
    final sourceDocId = (order?.orderDocumentId ?? cart.editSourceOrderId ?? '')
        .trim();
    final sourceOrderRef = (order?.orderId ?? cart.editSourceOrderRef ?? '')
        .trim();
    if (sourceDocId.isEmpty && sourceOrderRef.isEmpty) return null;

    return {
      'isEditOrder': true,
      'sourceOrderDocumentId': sourceDocId,
      'sourceOrderId': sourceDocId,
      'sourceOrderRef': sourceOrderRef,
      'windowHours': FeatureFlags.orderEditWindowHours,
      'lockedQuantities': cart.editLockedQuantities,
      'originalCreatedAt': order?.createdAt.toIso8601String(),
      'originalTotalAmount': order?.totalAmount ?? 0,
      'originalItemCount': order?.itemCount ?? 0,
      'originalPaymentMethod': order?.paymentMethod,
    };
  }

  void _openProductDetailFromCartItem(
    BuildContext context,
    CartItem item, {
    bool autoOpenBulkOrderSheet = false,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProductDetailScreen(
          product: _productMapFromCartItem(item),
          autoOpenBulkOrderSheet: autoOpenBulkOrderSheet,
        ),
      ),
    );
  }

  String _normalizedPhone(String value) {
    final cleaned = value.trim().replaceAll(RegExp(r'\D'), '');
    if (cleaned.length == 12 && cleaned.startsWith('91')) {
      return cleaned.substring(2);
    }
    return cleaned;
  }

  bool _validPhone(String value) {
    final normalized = _normalizedPhone(value);
    return normalized.length == 10;
  }

  bool _isDeliveryOrContactMissing() {
    return _line1Controller.text.trim().isEmpty ||
        _cityController.text.trim().isEmpty ||
        _stateController.text.trim().isEmpty ||
        _pincodeController.text.trim().isEmpty ||
        _receiverNameController.text.trim().isEmpty ||
        !_validPhone(_phoneController.text);
  }

  int _safeNonNegativeInt(dynamic value, int fallback) {
    if (value is int) return value < 0 ? fallback : value;
    if (value is num) {
      final casted = value.round();
      return casted < 0 ? fallback : casted;
    }
    final parsed = int.tryParse((value ?? '').toString().trim());
    if (parsed == null || parsed < 0) return fallback;
    return parsed;
  }

  Future<void> _loadDeliverySettings() async {
    final settings = await _firestoreService.getStoreAppSettings();
    if (!mounted || settings.isEmpty) return;

    final delivery = settings['delivery'];
    final deliveryMap = delivery is Map<String, dynamic>
        ? delivery
        : (delivery is Map ? Map<String, dynamic>.from(delivery) : null);
    if (deliveryMap == null) return;

    setState(() {
      _puneDeliveryCharge = _safeNonNegativeInt(
        deliveryMap['pune'],
        _defaultPuneDeliveryCharge,
      );
      _maharashtraDeliveryCharge = _safeNonNegativeInt(
        deliveryMap['maharashtra'],
        _defaultMaharashtraDeliveryCharge,
      );
      _outsideMaharashtraDeliveryCharge = _safeNonNegativeInt(
        deliveryMap['outsideMaharashtra'],
        _defaultOutsideMaharashtraDeliveryCharge,
      );
      _freeDeliveryThreshold = _safeNonNegativeInt(
        deliveryMap['freeThreshold'],
        _defaultFreeDeliveryThreshold,
      );
    });
  }

  Map<String, dynamic> _deliveryAddressMap() {
    return {
      'line1': _line1Controller.text.trim(),
      'line2': _line2Controller.text.trim(),
      'landmark': _landmarkController.text.trim(),
      'city': _cityController.text.trim(),
      'state': _stateController.text.trim(),
      'pincode': _pincodeController.text.trim(),
      'country': 'India',
      'mapLink': _mapLinkController.text.trim(),
    };
  }

  Map<String, dynamic> _contactDetailsMap() {
    final cleanedPhone = _normalizedPhone(_phoneController.text);
    return {
      'receiverName': _receiverNameController.text.trim(),
      'phone': cleanedPhone,
    };
  }

  int _itemTotal(CartModel cart) => cart.totalPrice;

  Map<String, dynamic> _activeDeliveryAddress() {
    if (_savedAddresses.isNotEmpty &&
        _selectedAddressIndex >= 0 &&
        _selectedAddressIndex < _savedAddresses.length) {
      final selected = _savedAddresses[_selectedAddressIndex];
      final selectedAddress = selected['deliveryAddress'];
      if (selectedAddress is Map) {
        return Map<String, dynamic>.from(selectedAddress);
      }
    }
    return _deliveryAddressMap();
  }

  bool _isPuneDelivery(Map<String, dynamic> deliveryAddress) {
    final city = (deliveryAddress['city'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final pincode = (deliveryAddress['pincode'] ?? '').toString().trim();
    return city == 'pune' ||
        city.contains('pune') ||
        _punePincodes.contains(pincode);
  }

  bool _isOutsideMaharashtra(Map<String, dynamic> deliveryAddress) {
    final state = (deliveryAddress['state'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (state.isEmpty) return false;
    return !(state == 'maharashtra' ||
        state == 'mh' ||
        state.contains('maharashtra'));
  }

  int _regionalDeliveryCharge() {
    final deliveryAddress = _activeDeliveryAddress();

    if (_isOutsideMaharashtra(deliveryAddress)) {
      return _outsideMaharashtraDeliveryCharge;
    }

    if (_isPuneDelivery(deliveryAddress)) {
      return _puneDeliveryCharge;
    }

    return _maharashtraDeliveryCharge;
  }

  int _calculateDeliveryCharge(int itemTotal) {
    final baseCharge = _regionalDeliveryCharge();

    if (itemTotal >= _freeDeliveryThreshold) {
      return 0;
    }

    return baseCharge;
  }

  int _amountToUnlockFreeDelivery(int itemTotal) {
    if (_calculateDeliveryCharge(itemTotal) == 0) return 0;
    final remaining =
        _freeDeliveryThreshold - (itemTotal + _regionalDeliveryCharge());
    return remaining > 0 ? remaining : 0;
  }

  int _grandTotal(CartModel cart) {
    final itemTotal = _itemTotal(cart);
    final deliveryCharge = _calculateDeliveryCharge(itemTotal);
    return itemTotal + deliveryCharge;
  }

  Future<void> _showFreeDeliveryUnlockedPopup() async {
    if (!mounted || _showingFreeDeliveryPopup) return;
    _showingFreeDeliveryPopup = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Future.delayed(const Duration(seconds: 1), () {
              if (!mounted || !_showingFreeDeliveryPopup) return;
              final navigator = Navigator.of(ctx);
              if (navigator.canPop()) {
                navigator.pop();
              }
            });
          });

          return Dialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 28),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Container(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFF1FFF5), Color(0xFFE8FFF0)],
                ),
                border: Border.all(color: const Color(0xFFBDE9CC)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: const Color(0xFF22A35A).withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.local_shipping_rounded,
                      color: const Color.fromARGB(255, 103, 7, 148),
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Free Delivery Unlocked! 🎉',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Awesome! Your order now qualifies for FREE delivery.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } finally {
      _showingFreeDeliveryPopup = false;
    }
  }

  Future<void> _clearPendingOnlinePaymentMarkers() async {
    await PayUPaymentService.clearPendingTransaction();
    if (!mounted) return;
    setState(() {
      _recoveredPayuTxnId = null;
      _recoveredPayuStatus = null;
      _recoveredSuccessfulPayuTxnId = null;
    });
  }

  Future<Map<String, dynamic>> _startPayUCheckoutDirect({
    required String amount,
    required String productInfo,
    required Map<String, dynamic> orderDraft,
  }) async {
    final paymentService = PayUPaymentService();
    StreamSubscription<Map<String, dynamic>>? eventSub;
    final completer = Completer<Map<String, dynamic>>();
    String txnId = '';

    void completeOnce(Map<String, dynamic> result) {
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }

    eventSub = paymentService.events.listen((event) {
      final type = (event['type'] ?? '').toString();

      if (type == 'cancel') {
        completeOnce({
          'status': 'cancelled',
          'txnid': txnId,
          'reason': 'payment-cancelled',
          'orderRef': '',
        });
        return;
      }

      if (type == 'error') {
        completeOnce({
          'status': 'failure',
          'txnid': txnId,
          'reason': 'payment-error',
          'orderRef': '',
        });
        return;
      }

      if (type == 'sync' || type == 'verify') {
        final status = (event['status'] ?? '').toString().toLowerCase();

        if (status == 'success') {
          completeOnce({
            'status': 'success',
            'txnid': (event['txnid'] ?? txnId).toString(),
            'reason': '',
            'orderRef': (event['orderRef'] ?? '').toString(),
          });
          return;
        }

        if (status == 'failure' || status == 'cancelled') {
          completeOnce({
            'status': status,
            'txnid': (event['txnid'] ?? txnId).toString(),
            'reason': 'sync-$status',
            'orderRef': '',
          });
        }
      }
    });

    try {
      final auth = context.read<AuthProvider>();
      final user = auth.user;
      final uid = (user?.uid ?? '').trim();
      final firstName = (user?.ownerName ?? user?.name ?? 'PureCuts User')
          .trim();
      final email = (user?.email ?? '').trim().isNotEmpty
          ? user!.email.trim()
          : 'customer@purecuts.app';
      final phone = (user?.phone ?? '9999999999').replaceAll(RegExp(r'\D'), '');

      txnId = await paymentService.startCheckout(
        userId: uid,
        amount: amount,
        productInfo: productInfo,
        firstName: firstName,
        email: email,
        phone: phone,
        orderDraft: orderDraft,
      );

      final result = await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => {
          'status': 'failure',
          'txnid': txnId,
          'reason': 'payment-timeout',
          'orderRef': '',
        },
      );

      return result;
    } catch (error) {
      return {
        'status': 'failure',
        'txnid': txnId,
        'reason': 'payment-error',
        'orderRef': '',
      };
    } finally {
      await eventSub.cancel();
      paymentService.dispose();
    }
  }

  Future<String?> _waitForBackendPayuOrderRef(
    String txnid, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final cleanTxnId = txnid.trim();
    if (cleanTxnId.isEmpty) return null;

    final deadline = DateTime.now().add(timeout);
    final paymentRef = FirebaseFirestore.instance
        .collection('payments')
        .doc(cleanTxnId);
    final ordersRef = FirebaseFirestore.instance.collection('orders');

    while (DateTime.now().isBefore(deadline)) {
      final snap = await paymentRef.get();
      if (!snap.exists) {
        await Future.delayed(const Duration(milliseconds: 750));
        continue;
      }

      final data = snap.data() ?? const <String, dynamic>{};
      final status = (data['status'] ?? '').toString().toLowerCase();
      final orderPlacementStatus = (data['orderPlacementStatus'] ?? '')
          .toString()
          .toLowerCase();
      final orderRef =
          (data['orderRef'] ?? data['orderId'] ?? data['orderNumber'] ?? '')
              .toString()
              .trim();

      if (orderRef.isNotEmpty &&
          (orderPlacementStatus == 'placed' || status == 'success')) {
        return orderRef;
      }

      try {
        final orderSnap = await ordersRef
            .where('paymentTxnId', isEqualTo: cleanTxnId)
            .limit(1)
            .get();
        if (orderSnap.docs.isNotEmpty) {
          final orderData = orderSnap.docs.first.data();
          final resolvedOrderRef =
              (orderData['orderRef'] ??
                      orderData['orderId'] ??
                      orderData['orderNumber'] ??
                      orderSnap.docs.first.id)
                  .toString()
                  .trim();
          if (resolvedOrderRef.isNotEmpty) {
            return resolvedOrderRef;
          }
        }
      } catch (_) {
        // Ignore query failures and keep polling the payment record.
      }

      if (status == 'failure' ||
          status == 'cancelled' ||
          orderPlacementStatus == 'failed-no-draft') {
        return null;
      }

      await Future.delayed(const Duration(milliseconds: 750));
    }

    return null;
  }

  Future<void> _recoverPendingOnlinePayment() async {
    final auth = context.read<AuthProvider>();
    final uid = auth.user?.uid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.trim().isEmpty) return;

    if (mounted) {
      setState(() {
        _checkingRecoveredPayment = true;
      });
    }

    try {
      final pendingTxnId = await PayUPaymentService.getPendingTxnIdForUser(uid);
      if ((pendingTxnId ?? '').trim().isEmpty) return;

      if (mounted) {
        setState(() {
          _recoveredPayuTxnId = pendingTxnId;
          _recoveredPayuStatus = 'recovering';
        });
      }

      final paymentDoc = await FirebaseFirestore.instance
          .collection('payments')
          .doc(pendingTxnId)
          .get();

      if (!paymentDoc.exists) {
        return;
      }

      final data = paymentDoc.data() ?? const <String, dynamic>{};
      final status = (data['status'] ?? '').toString().toLowerCase();
      final verified = data['hashVerified'] == true;

      if (mounted) {
        setState(() {
          _recoveredPayuStatus = status.isEmpty ? 'recovering' : status;
        });
      }

      if (status == 'success' && verified) {
        if (!mounted) return;
        setState(() {
          _recoveredPayuTxnId = pendingTxnId;
          _recoveredPayuStatus = 'success';
          _recoveredSuccessfulPayuTxnId = pendingTxnId;
        });
        _maybeAutoFinalizeRecoveredOrder();
        return;
      }

      if (status == 'failure' || status == 'cancelled') {
        await _clearPendingOnlinePaymentMarkers();
      }
    } catch (_) {
      // Non-blocking recovery path.
    } finally {
      if (mounted) {
        setState(() {
          _checkingRecoveredPayment = false;
        });
      }
    }
  }

  void _maybeAutoFinalizeRecoveredOrder() {
    if (!widget.autoFinalizeRecoveredPayuOrder) return;
    if (_autoFinalizeAttempted) return;
    if ((_recoveredSuccessfulPayuTxnId ?? '').trim().isEmpty) return;
    _autoFinalizeAttempted = true;

    if (_selectedPaymentMethod != _payuPaymentMethod) {
      setState(() {
        _selectedPaymentMethod = _payuPaymentMethod;
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isPlacingOrder) return;
      _placeOrder(
        cart: context.read<CartModel>(),
        home: context.read<HomeProvider>(),
        skipConfirmation: true,
      );
    });
  }

  List<Map<String, dynamic>> _recommendations({
    required CartModel cart,
    required HomeProvider home,
  }) {
    final allProducts = home.productMaps;
    if (allProducts.isEmpty || cart.items.isEmpty) return const [];

    final cartIds = cart.items
        .map((item) => _baseProductId(item.id))
        .where((id) => id.isNotEmpty)
        .toSet();

    final cartProducts = allProducts
        .where(
          (p) => cartIds.contains(_baseProductId((p['id'] ?? '').toString())),
        )
        .toList(growable: false);

    final cartTags = <String>{};
    final cartCategories = <String>{};

    for (final product in cartProducts) {
      final tag = (product['tag'] ?? '').toString().trim().toLowerCase();
      if (tag.isNotEmpty) cartTags.add(tag);
      final tags = product['tags'];
      if (tags is List) {
        for (final t in tags) {
          final normalized = t.toString().trim().toLowerCase();
          if (normalized.isNotEmpty) cartTags.add(normalized);
        }
      }
      final category = (product['category'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (category.isNotEmpty) cartCategories.add(category);
    }

    int scoreOf(Map<String, dynamic> product) {
      final productTagSet = <String>{};
      final single = (product['tag'] ?? '').toString().trim().toLowerCase();
      if (single.isNotEmpty) productTagSet.add(single);
      final tags = product['tags'];
      if (tags is List) {
        for (final t in tags) {
          final normalized = t.toString().trim().toLowerCase();
          if (normalized.isNotEmpty) productTagSet.add(normalized);
        }
      }

      final category = (product['category'] ?? '')
          .toString()
          .trim()
          .toLowerCase();

      final tagMatches = productTagSet.where(cartTags.contains).length;
      final categoryMatch = cartCategories.contains(category) ? 1 : 0;
      final rating = (product['rating'] as num?)?.toDouble() ?? 0;
      final reviews = (product['reviews'] as num?)?.toInt() ?? 0;

      return (tagMatches * 10000) +
          (categoryMatch * 1000) +
          (rating * 100).round() +
          reviews;
    }

    final candidates = allProducts
        .where(
          (p) => !cartIds.contains(_baseProductId((p['id'] ?? '').toString())),
        )
        .toList();

    candidates.sort((a, b) => scoreOf(b).compareTo(scoreOf(a)));

    final primary = candidates
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
              cartTags.contains(tag) || tags.any(cartTags.contains);
          final categoryMatch = cartCategories.contains(category);
          return tagMatch || categoryMatch;
        })
        .take(12)
        .toList(growable: true);

    if (primary.length < 12) {
      final already = primary
          .map((e) => _baseProductId((e['id'] ?? '').toString()))
          .toSet();
      for (final candidate in candidates) {
        final id = _baseProductId((candidate['id'] ?? '').toString());
        if (already.contains(id)) continue;
        primary.add(candidate);
        if (primary.length >= 12) break;
      }
    }

    return primary.take(12).toList(growable: false);
  }

  Future<void> _openDetailsBottomSheet({
    bool blocking = false,
    int? editIndex,
  }) async {
    if (editIndex != null &&
        editIndex >= 0 &&
        editIndex < _savedAddresses.length) {
      _applyAddressEntry(_savedAddresses[editIndex]);
    } else {
      _line1Controller.clear();
      _line2Controller.clear();
      _landmarkController.clear();
      _cityController.clear();
      _mapLinkController.clear();
      if (_savedAddresses.isEmpty) {
        final user = context.read<AuthProvider>().user;
        _stateController.text = (user?.state ?? _stateController.text)
            .toString();
        _pincodeController.text = (user?.pincode ?? _pincodeController.text)
            .toString();
        _receiverNameController.text =
            (user?.ownerName ?? user?.name ?? _receiverNameController.text)
                .toString();
        _phoneController.text = (user?.phone ?? _phoneController.text)
            .toString();
      }
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: !blocking,
      enableDrag: !blocking,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.round),
        ),
      ),
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            left: AppSpacing.lg,
            right: AppSpacing.lg,
            top: AppSpacing.lg,
            bottom:
                MediaQuery.of(sheetContext).viewInsets.bottom + AppSpacing.lg,
          ),
          child: Form(
            key: _detailsFormKey,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Add your delivery details',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'This is required once for smoother checkout next time.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _textField(_line1Controller, 'Address line 1*'),
                  const SizedBox(height: AppSpacing.md),
                  _textField(_line2Controller, 'Address line 2'),
                  const SizedBox(height: AppSpacing.md),
                  _textField(_landmarkController, 'Landmark'),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    children: [
                      Expanded(child: _textField(_cityController, 'City*')),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(child: _textField(_stateController, 'State*')),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _textField(
                    _pincodeController,
                    'Pincode*',
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _textField(_mapLinkController, 'Google maps link (optional)'),
                  const SizedBox(height: AppSpacing.md),
                  _textField(_receiverNameController, 'Receiver name*'),
                  const SizedBox(height: AppSpacing.md),
                  _textField(
                    _phoneController,
                    'Phone number*',
                    keyboardType: TextInputType.phone,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  if (editIndex != null &&
                      editIndex >= 0 &&
                      editIndex < _savedAddresses.length)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            Navigator.of(sheetContext).pop();
                            await _deleteAddress(editIndex);
                          },
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Delete this address'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.error,
                            side: const BorderSide(color: AppColors.error),
                          ),
                        ),
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        if (_line1Controller.text.trim().isEmpty ||
                            _cityController.text.trim().isEmpty ||
                            _stateController.text.trim().isEmpty ||
                            _pincodeController.text.trim().isEmpty ||
                            _receiverNameController.text.trim().isEmpty ||
                            !_validPhone(_phoneController.text)) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Please enter valid delivery/contact details.',
                              ),
                            ),
                          );
                          return;
                        }

                        final auth = context.read<AuthProvider>();
                        final newEntry = {
                          'deliveryAddress': _deliveryAddressMap(),
                          'contactDetails': _contactDetailsMap(),
                        };

                        final updatedList = List<Map<String, dynamic>>.from(
                          _savedAddresses,
                        );

                        int selectedIdx;
                        if (editIndex != null &&
                            editIndex >= 0 &&
                            editIndex < updatedList.length) {
                          updatedList[editIndex] = newEntry;
                          selectedIdx = editIndex;
                        } else {
                          updatedList.add(newEntry);
                          selectedIdx = updatedList.length - 1;
                        }

                        final saved = await auth.updateCheckoutDeliveryDetails(
                          deliveryAddress:
                              newEntry['deliveryAddress']
                                  as Map<String, dynamic>,
                          contactDetails:
                              newEntry['contactDetails']
                                  as Map<String, dynamic>,
                          addresses: updatedList,
                          selectedAddressIndex: selectedIdx,
                        );

                        if (!mounted) return;
                        if (!saved) {
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Unable to save details. Please try again.',
                              ),
                            ),
                          );
                          return;
                        }

                        setState(() {
                          _savedAddresses
                            ..clear()
                            ..addAll(updatedList);
                          _selectedAddressIndex = selectedIdx;
                          _applyAddressEntry(_savedAddresses[selectedIdx]);
                        });
                        Navigator.of(sheetContext).pop();
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          const SnackBar(
                            content: Text('Delivery details saved.'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      child: const Text('Save details'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _selectAddress(int index) async {
    if (index < 0 || index >= _savedAddresses.length) return;
    _applyAddressEntry(_savedAddresses[index]);

    final selectedEntry = _savedAddresses[index];
    final auth = context.read<AuthProvider>();
    await auth.updateCheckoutDeliveryDetails(
      deliveryAddress:
          selectedEntry['deliveryAddress'] as Map<String, dynamic>? ??
          const <String, dynamic>{},
      contactDetails:
          selectedEntry['contactDetails'] as Map<String, dynamic>? ??
          const <String, dynamic>{},
      addresses: _savedAddresses,
      selectedAddressIndex: index,
    );

    if (!mounted) return;
    setState(() {
      _selectedAddressIndex = index;
    });
  }

  Future<void> _deleteAddress(int index) async {
    if (index < 0 || index >= _savedAddresses.length) return;

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Delete address?'),
            content: const Text(
              'This address will be removed from your saved checkout addresses.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed) return;

    final updatedList = List<Map<String, dynamic>>.from(_savedAddresses)
      ..removeAt(index);

    final auth = context.read<AuthProvider>();
    bool saved = false;
    var nextSelectedIndex = 0;

    if (updatedList.isEmpty) {
      saved = await auth.updateCheckoutDeliveryDetails(
        deliveryAddress: const <String, dynamic>{},
        contactDetails: const <String, dynamic>{},
        addresses: const <Map<String, dynamic>>[],
        selectedAddressIndex: 0,
        allowEmptyAddresses: true,
      );
    } else {
      if (_selectedAddressIndex > index) {
        nextSelectedIndex = _selectedAddressIndex - 1;
      } else if (_selectedAddressIndex == index) {
        nextSelectedIndex = index.clamp(0, updatedList.length - 1);
      } else {
        nextSelectedIndex = _selectedAddressIndex;
      }

      final selectedEntry = updatedList[nextSelectedIndex];
      saved = await auth.updateCheckoutDeliveryDetails(
        deliveryAddress:
            selectedEntry['deliveryAddress'] as Map<String, dynamic>? ??
            const <String, dynamic>{},
        contactDetails:
            selectedEntry['contactDetails'] as Map<String, dynamic>? ??
            const <String, dynamic>{},
        addresses: updatedList,
        selectedAddressIndex: nextSelectedIndex,
      );
    }

    if (!mounted) return;

    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Unable to delete address right now. Please try again.',
          ),
        ),
      );
      return;
    }

    setState(() {
      _savedAddresses
        ..clear()
        ..addAll(updatedList);
      _selectedAddressIndex = updatedList.isEmpty ? 0 : nextSelectedIndex;

      if (updatedList.isEmpty) {
        _line1Controller.clear();
        _line2Controller.clear();
        _landmarkController.clear();
        _cityController.clear();
        _stateController.clear();
        _pincodeController.clear();
        _mapLinkController.clear();
        _receiverNameController.clear();
        _phoneController.text = (auth.user?.phone ?? '').toString();
      } else {
        _applyAddressEntry(_savedAddresses[_selectedAddressIndex]);
      }
    });

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Address deleted.')));
  }

  Widget _textField(
    TextEditingController controller,
    String hint, {
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 14, color: AppColors.textHint),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: 14,
        ),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
      ),
    );
  }

  Future<void> _submitProductSuggestionIfNeeded({
    required String uid,
    required String orderRef,
    required String orderId,
  }) async {
    final cleanText = _productSuggestionController.text.trim();
    if (cleanText.isEmpty) return;

    if (mounted) {
      setState(() {
        _suggestionUploading = true;
      });
    }

    try {
      await _firestoreService.createProductSuggestion(
        uid: uid,
        text: cleanText,
        orderRef: orderRef,
        orderId: orderId,
        meta: {'source': 'checkout', 'paymentMethod': _selectedPaymentMethod},
      );
    } finally {
      if (mounted) {
        setState(() {
          _suggestionUploading = false;
        });
      }
    }
  }

  Widget _buildProductSuggestionSection() {
    return _sectionCard(
      title: 'Product suggestion',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Want to suggest a product we should add? Enter a note below (optional).',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _productSuggestionController,
            maxLines: 3,
            maxLength: 1000,
            decoration: const InputDecoration(
              hintText: 'What product should we add?',
              counterText: '',
            ),
          ),
          if (_suggestionUploading) ...[
            const SizedBox(height: AppSpacing.md),
            const LinearProgressIndicator(minHeight: 2),
          ],
        ],
      ),
    );
  }

  Widget _compactRecommendationCard(Map<String, dynamic> product) {
    final image = resolveListImage(product);
    final price = (product['price'] as num?)?.toDouble() ?? 0;
    final originalPrice =
        (product['originalPrice'] as num?)?.toDouble() ?? price;
    final hasDiscount = originalPrice > price;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ProductDetailScreen(product: product),
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: AppColors.divider),
          ),
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Center(
                  child: CachedNetworkImage(
                    imageUrl: image,
                    fit: BoxFit.contain,
                    fadeInDuration: Duration.zero,
                    fadeOutDuration: Duration.zero,
                    memCacheWidth: 168,
                    maxWidthDiskCache: 168,
                    errorWidget: (_, __, ___) => const Icon(
                      Icons.image_outlined,
                      color: AppColors.textHint,
                      size: 20,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                (product['brand'] ?? '').toString(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                (product['name'] ?? '').toString(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 11,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '₹${price.toStringAsFixed(price.truncateToDouble() == price ? 0 : 2)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (hasDiscount)
                          Text(
                            '₹${originalPrice.toStringAsFixed(originalPrice.truncateToDouble() == originalPrice ? 0 : 2)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textHint,
                              fontSize: 10,
                              decoration: TextDecoration.lineThrough,
                              decorationColor: AppColors.textHint,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () {
                      if (!ensureVariantSelectedBeforeQuickAdd(
                        context,
                        product,
                      )) {
                        return;
                      }
                      context.read<CartModel>().add(product);
                    },
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(color: AppColors.primary),
                      ),
                      child: const Text(
                        'ADD',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _placeOrder({
    required CartModel cart,
    required HomeProvider home,
    bool skipConfirmation = false,
  }) async {
    if (_isPlacingOrder) return;

    final messenger = ScaffoldMessenger.maybeOf(context);

    setState(() {
      _isPlacingOrder = true;
    });

    try {
      await PerformanceTraceService.recordVoid('place_order_time', () async {
        if (_isDeliveryOrContactMissing()) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Please add delivery/contact details before placing order.',
              ),
            ),
          );
          return;
        }

        final itemTotal = _itemTotal(cart);
        final deliveryCharge = _calculateDeliveryCharge(itemTotal);
        final grandTotal = _grandTotal(cart);

        bool confirmed = true;
        // ── Confirmation dialog ──────────────────────────────────────────────────
        if (!skipConfirmation) {
          if (!mounted) return;
          confirmed =
              await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.xl),
                  ),
                  title: const Text(
                    'Confirm order',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                    ),
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Please review your order before placing it.',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      // Summary box
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(AppSpacing.md),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8F2FF),
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                          border: Border.all(color: const Color(0xFFE3D4F4)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Item count
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Items',
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  '${cart.items.length} item${cart.items.length == 1 ? '' : 's'}',
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            // Delivery charge row
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Delivery',
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  deliveryCharge == 0
                                      ? 'FREE'
                                      : '₹$deliveryCharge',
                                  style: TextStyle(
                                    color: deliveryCharge == 0
                                        ? Colors.green
                                        : AppColors.textPrimary,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(
                                vertical: AppSpacing.sm,
                              ),
                              child: Divider(height: 1),
                            ),
                            // Grand total
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Total',
                                  style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                                Text(
                                  '₹$grandTotal',
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            // Payment method
                            Row(
                              children: [
                                const Expanded(
                                  flex: 3,
                                  child: Text(
                                    'Payment',
                                    style: TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  flex: 5,
                                  child: Text(
                                    _selectedPaymentMethod,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(
                                      color: AppColors.textPrimary,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  actionsPadding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    0,
                    AppSpacing.md,
                    AppSpacing.md,
                  ),
                  actions: [
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              side: const BorderSide(color: AppColors.primary),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadius.xl,
                                ),
                              ),
                            ),
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(false),
                            child: const Text(
                              'Go back',
                              style: TextStyle(
                                color: AppColors.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadius.xl,
                                ),
                              ),
                            ),
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(true),
                            child: const Text(
                              'Confirm',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ) ??
              false;
        }

        // User cancelled — do nothing
        if (confirmed != true || !mounted) return;
        // ── End confirmation dialog ──────────────────────────────────────────────

        final auth = context.read<AuthProvider>();
        final uid =
            auth.user?.uid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
        final deliveryAddress = _deliveryAddressMap();
        final contactDetails = _contactDetailsMap();

        unawaited(
          auth
              .updateCheckoutDeliveryDetails(
                deliveryAddress: deliveryAddress,
                contactDetails: contactDetails,
              )
              .then((saved) {
                if (!saved || !mounted) return;
              })
              .catchError((_) {
                // Best-effort pre-save only. Order persistence still happens on confirmation.
              }),
        );

        final allProducts = home.productMaps;
        final productById = <String, Map<String, dynamic>>{
          for (final p in allProducts)
            _baseProductId((p['id'] ?? '').toString()): p,
        };

        final orderedItems = cart.items
            .map((item) {
              final product =
                  productById[_baseProductId(item.id)] ??
                  const <String, dynamic>{};
              return {
                'id': item.id,
                'name': item.name,
                'brand': item.brand,
                'image': item.image,
                'price': item.price,
                'originalPrice': (product['originalPrice'] ?? item.price),
                'size': (product['size'] ?? '').toString(),
                'tag': (product['tag'] ?? '').toString(),
                'tags': (product['tags'] is List)
                    ? List<String>.from(product['tags'])
                    : <String>[],
                'category': (product['category'] ?? '').toString(),
                'subCategory': (product['subCategory'] ?? '').toString(),
                'quantity': item.quantity,
              };
            })
            .toList(growable: false);

        final deliveryChargeValue = _calculateDeliveryCharge(itemTotal);
        var successfulPaymentTxnId = (_recoveredSuccessfulPayuTxnId ?? '')
            .trim();
        String? orderRef;
        final editMeta = _buildEditMeta(cart);

        if (_selectedPaymentMethod == _payuPaymentMethod) {
          if ((_recoveredSuccessfulPayuTxnId ?? '').trim().isEmpty) {
            final authUser = context.read<AuthProvider>().user;
            final draftCustomerName =
                (authUser?.ownerName ?? authUser?.name ?? '').trim();
            final draftCustomerEmail = (authUser?.email ?? '').trim();
            final draftCustomerPhone = (contactDetails['phone'] ?? '')
                .toString()
                .trim();

            final paymentResult = await PerformanceTraceService.record(
              'payment_time',
              () async {
                return _startPayUCheckoutDirect(
                  amount: grandTotal.toString(),
                  productInfo: 'PureCuts Order',
                  orderDraft: {
                    'uid': uid,
                    'userId': uid,
                    'customerId': uid,
                    'items': orderedItems,
                    'deliveryAddress': deliveryAddress,
                    'contactDetails': contactDetails,
                    'paymentMethod': _selectedPaymentMethod,
                    'itemTotal': itemTotal,
                    'deliveryCharge': deliveryChargeValue,
                    'handlingCharge': 0,
                    'grandTotal': grandTotal,
                    if (editMeta != null) 'editMeta': editMeta,
                    'customerName': draftCustomerName,
                    'customerEmail': draftCustomerEmail,
                    'customerPhone': draftCustomerPhone,
                  },
                );
              },
            );

            if (!mounted) return;

            final paymentStatus = (paymentResult['status'] ?? '')
                .toString()
                .toLowerCase();
            if (paymentStatus != 'success') {
              final reason = (paymentResult['reason'] ?? '').toString();
              final message = _friendlyPaymentNotCompletedMessage(reason);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(message)));
              return;
            }

            final resolvedOrderRef = (paymentResult['orderRef'] ?? '')
                .toString()
                .trim();
            if (resolvedOrderRef.isNotEmpty) {
              orderRef = resolvedOrderRef;
            }

            successfulPaymentTxnId = (paymentResult['txnid'] ?? '')
                .toString()
                .trim();
          }
        }

        if (uid.trim().isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Session expired. Please login again to place order.',
              ),
            ),
          );
          return;
        }

        try {
          if (_selectedPaymentMethod == _payuPaymentMethod) {
            if (successfulPaymentTxnId.isEmpty) {
              throw StateError('Missing payment transaction id.');
            }

            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Payment received. Finalizing your order...'),
                duration: Duration(seconds: 2),
              ),
            );

            orderRef = await _waitForBackendPayuOrderRef(
              successfulPaymentTxnId,
            );
          } else {
            orderRef = await _firestoreService.registerUserPurchase(
              uid: uid,
              items: orderedItems,
              total: grandTotal,
              deliveryAddress: deliveryAddress,
              contactDetails: contactDetails,
              paymentMethod: _selectedPaymentMethod,
              paymentTxnId: successfulPaymentTxnId,
              billDetails: {
                'itemTotal': itemTotal,
                'deliveryCharge': deliveryChargeValue,
                'handlingCharge': 0,
                'grandTotal': grandTotal,
              },
              editMeta: editMeta,
              userProfile: auth.user?.toMap(),
            );
          }
        } catch (error) {
          if (!mounted) return;
          final reason = error.toString().replaceFirst('StateError: ', '');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                reason.isNotEmpty
                    ? reason
                    : 'Order could not be saved right now. Please try again.',
              ),
            ),
          );
          return;
        }

        if ((orderRef ?? '').trim().isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Order could not be placed. Please try again.'),
            ),
          );
          return;
        }

        final resolvedOrderRef = (orderRef ?? '').trim();

        try {
          await _submitProductSuggestionIfNeeded(
            uid: uid,
            orderRef: resolvedOrderRef,
            orderId: resolvedOrderRef,
          );
        } catch (error) {
          if (mounted) {
            messenger?.showSnackBar(
              SnackBar(
                content: Text(
                  'Order placed, but suggestion could not be saved: ${error.toString().replaceFirst('StateError: ', '')}',
                ),
              ),
            );
          }
        }

        if (_selectedPaymentMethod == _payuPaymentMethod) {
          await _clearPendingOnlinePaymentMarkers();
        }

        // Clear cart only after confirmed order persistence.
        cart.clear();

        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => OrderConfirmScreen(
              total: grandTotal,
              orderedItems: orderedItems,
              deliveryAddress: deliveryAddress,
              contactDetails: contactDetails,
              paymentMethod: _selectedPaymentMethod,
              alreadyPlacedOrderRef: orderRef,
              persistOrder: _selectedPaymentMethod != _payuPaymentMethod,
              billDetails: {
                'itemTotal': itemTotal,
                'deliveryCharge': deliveryChargeValue,
                'handlingCharge': 0,
                'grandTotal': grandTotal,
              },
            ),
          ),
        );
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not place order right now. Please try again.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isPlacingOrder = false;
        });
      }
    }
  }

  IconData _paymentMethodIcon(String method) {
    if (method == _codPaymentMethod) {
      return Icons.local_shipping_outlined;
    }
    return Icons.account_balance_wallet_outlined;
  }

  String _paymentMethodSubtitle(String method) {
    if (method == _codPaymentMethod) {
      return 'Pay after delivery';
    }
    return 'UPI, Card, NetBanking, Wallet';
  }

  Future<void> _openPaymentMethodSheet() async {
    final methods = [_codPaymentMethod, _payuPaymentMethod];
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) {
        return SafeArea(
          child: Container(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            decoration: const BoxDecoration(
              color: Color(0xFFFDF9FF),
              borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
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
                      color: AppColors.divider,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                const Text(
                  'Choose payment method',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Select the option that works best for you.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                ...methods.map((method) {
                  final isSelected = _selectedPaymentMethod == method;
                  return Container(
                    margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        onTap: () => Navigator.pop(context, method),
                        child: Ink(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppColors.primary.withOpacity(0.08)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(AppRadius.lg),
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.primary.withOpacity(0.35)
                                  : AppColors.border,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? AppColors.primary.withOpacity(0.14)
                                      : AppColors.surface,
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.md,
                                  ),
                                ),
                                child: Icon(
                                  _paymentMethodIcon(method),
                                  color: isSelected
                                      ? AppColors.primary
                                      : AppColors.textSecondary,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: AppSpacing.md),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      method,
                                      style: const TextStyle(
                                        color: AppColors.textPrimary,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _paymentMethodSubtitle(method),
                                      style: const TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (isSelected)
                                const Icon(
                                  Icons.check_circle_rounded,
                                  color: AppColors.primary,
                                  size: 22,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );

    if (selected != null && mounted) {
      setState(() => _selectedPaymentMethod = selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartModel>();
    final home = context.watch<HomeProvider>();
    final isEditMode = cart.isEditSessionActive;

    for (final item in cart.items) {
      final url = item.image.trim();
      if (url.isEmpty) continue;
      unawaited(
        ImageBandwidthTelemetry.instance.trackImageLoad(
          screen: 'checkout_selected_items',
          imageUrl: url,
        ),
      );
    }

    if (cart.items.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(isEditMode ? 'Edit Order' : 'Checkout')),
        body: const Center(child: Text('Your cart is empty')),
      );
    }

    final itemTotal = _itemTotal(cart);
    final grandTotal = _grandTotal(cart);
    final amountToUnlockFreeDelivery = _amountToUnlockFreeDelivery(itemTotal);
    final freeDeliveryUnlocked = amountToUnlockFreeDelivery == 0;
    final freeDeliveryConfettiController =
        _ensureFreeDeliveryConfettiController();

    if (freeDeliveryUnlocked && !_wasFreeDeliveryUnlocked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        freeDeliveryConfettiController.play();
        unawaited(_showFreeDeliveryUnlockedPopup());
      });
    }
    _wasFreeDeliveryUnlocked = freeDeliveryUnlocked;

    final recommendations = _recommendations(cart: cart, home: home);

    final addressSummary = [
      _line1Controller.text.trim(),
      _line2Controller.text.trim(),
      _cityController.text.trim(),
      _stateController.text.trim(),
      _pincodeController.text.trim(),
    ].where((e) => e.isNotEmpty).join(', ');

    return Scaffold(
      backgroundColor: const Color(0xFFF1E5FF),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF1E5FF),
        elevation: 0,
        flexibleSpace: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFF0DEFF), Color(0xFFE8D2FF)],
            ),
          ),
        ),
        title: Text(
          isEditMode ? 'Edit Order' : 'Checkout',
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFEFDCFF), Color(0xFFE6CEFF), Color(0xFFF4E8FF)],
          ),
        ),
        child: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                188,
              ),
              children: [
                _sectionCard(
                  title: 'Selected items',
                  child: Column(
                    children: cart.items.map((item) {
                      final bulkTriggerQty = _bulkTriggerQtyForCartItem(item);
                      final bulkReached =
                          bulkTriggerQty != null &&
                          item.quantity >= bulkTriggerQty;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: Column(
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(AppRadius.md),
                              onTap: () =>
                                  _openProductDetailFromCartItem(context, item),
                              child: Row(
                                children: [
                                  Container(
                                    width: 56,
                                    height: 56,
                                    decoration: BoxDecoration(
                                      color: AppColors.surface,
                                      borderRadius: BorderRadius.circular(
                                        AppRadius.lg,
                                      ),
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(
                                        AppRadius.lg,
                                      ),
                                      child: CachedNetworkImage(
                                        imageUrl: item.image,
                                        fit: BoxFit.contain,
                                        fadeInDuration: Duration.zero,
                                        fadeOutDuration: Duration.zero,
                                        memCacheWidth: 112,
                                        maxWidthDiskCache: 112,
                                        errorWidget: (_, __, ___) => const Icon(
                                          Icons.image_outlined,
                                          color: AppColors.textHint,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: AppColors.textPrimary,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14,
                                          ),
                                        ),
                                        const SizedBox(height: AppSpacing.xs),
                                        Text(
                                          '₹${item.price} each',
                                          style: const TextStyle(
                                            color: AppColors.textSecondary,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    '₹${item.price * item.quantity}',
                                    style: const TextStyle(
                                      color: AppColors.textPrimary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: bulkReached
                                  ? SizedBox(
                                      height: 32,
                                      child: ElevatedButton(
                                        onPressed: () =>
                                            _openProductDetailFromCartItem(
                                              context,
                                              item,
                                              autoOpenBulkOrderSheet: true,
                                            ),
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
                                            horizontal: 12,
                                          ),
                                        ),
                                        child: const Text(
                                          'Bulk order',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
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
                                          InkWell(
                                            onTap: () => context
                                                .read<CartModel>()
                                                .remove(item.id),
                                            borderRadius: BorderRadius.circular(
                                              AppRadius.md,
                                            ),
                                            child: const SizedBox(
                                              width: 34,
                                              child: Icon(
                                                Icons.remove_rounded,
                                                color: AppColors.textSecondary,
                                                size: 16,
                                              ),
                                            ),
                                          ),
                                          SizedBox(
                                            width: 24,
                                            child: Text(
                                              '${item.quantity}',
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(
                                                color: AppColors.textPrimary,
                                                fontWeight: FontWeight.w700,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                          InkWell(
                                            onTap: () {
                                              context.read<CartModel>().add({
                                                'id': item.id,
                                                'name': item.name,
                                                'brand': item.brand,
                                                'image': item.image,
                                                'price': item.price,
                                                'basePrice': item.basePrice,
                                                'pricingType': item.pricingType,
                                                'pricingTiers': item
                                                    .pricingTiers
                                                    .map((tier) => tier.toMap())
                                                    .toList(growable: false),
                                              });
                                              if (bulkTriggerQty != null &&
                                                  item.quantity + 1 >=
                                                      bulkTriggerQty) {
                                                _openProductDetailFromCartItem(
                                                  context,
                                                  item,
                                                  autoOpenBulkOrderSheet: true,
                                                );
                                              }
                                            },
                                            borderRadius: BorderRadius.circular(
                                              AppRadius.md,
                                            ),
                                            child: const SizedBox(
                                              width: 34,
                                              child: Icon(
                                                Icons.add_rounded,
                                                color: AppColors.textSecondary,
                                                size: 16,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                _buildProductSuggestionSection(),
                const SizedBox(height: AppSpacing.lg),
                _sectionCard(
                  title: 'You might also like',
                  child: recommendations.isEmpty
                      ? const Text(
                          'No related products yet.',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        )
                      : Column(
                          children: [
                            SizedBox(
                              height: 410,
                              child: Stack(
                                children: [
                                  LayoutBuilder(
                                    builder: (context, constraints) {
                                      const spacing = AppSpacing.md;
                                      final cardHeight =
                                          (constraints.maxHeight - spacing) / 2;
                                      final cardWidth =
                                          (constraints.maxWidth - spacing) / 2;
                                      final aspectRatio =
                                          cardHeight / cardWidth;

                                      return Directionality(
                                        textDirection: TextDirection.rtl,
                                        child: GridView.builder(
                                          primary: false,
                                          physics:
                                              const BouncingScrollPhysics(),
                                          scrollDirection: Axis.horizontal,
                                          reverse: true,
                                          itemCount: recommendations.length,
                                          gridDelegate:
                                              SliverGridDelegateWithFixedCrossAxisCount(
                                                crossAxisCount: 2,
                                                mainAxisSpacing: spacing,
                                                crossAxisSpacing: spacing,
                                                childAspectRatio: aspectRatio,
                                              ),
                                          itemBuilder: (_, i) {
                                            final p = recommendations[i];
                                            final recommendationImage =
                                                resolveListImage(p);
                                            if (recommendationImage
                                                .isNotEmpty) {
                                              unawaited(
                                                ImageBandwidthTelemetry.instance
                                                    .trackImageLoad(
                                                      screen:
                                                          'checkout_recommendations',
                                                      imageUrl:
                                                          recommendationImage,
                                                    ),
                                              );
                                            }

                                            return Directionality(
                                              textDirection: TextDirection.ltr,
                                              child: _compactRecommendationCard(
                                                p,
                                              ),
                                            );
                                          },
                                        ),
                                      );
                                    },
                                  ),
                                  Positioned(
                                    left: 2,
                                    top: 0,
                                    bottom: 0,
                                    child: IgnorePointer(
                                      child: Center(
                                        child: Container(
                                          width: 26,
                                          height: 26,
                                          decoration: BoxDecoration(
                                            color: Colors.white.withOpacity(
                                              0.88,
                                            ),
                                            shape: BoxShape.circle,
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Color(0x16000000),
                                                blurRadius: 8,
                                                offset: Offset(0, 2),
                                              ),
                                            ],
                                          ),
                                          child: const Icon(
                                            Icons.chevron_left_rounded,
                                            size: 18,
                                            color: AppColors.textSecondary,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    right: 2,
                                    top: 0,
                                    bottom: 0,
                                    child: IgnorePointer(
                                      child: Center(
                                        child: Container(
                                          width: 26,
                                          height: 26,
                                          decoration: BoxDecoration(
                                            color: Colors.white.withOpacity(
                                              0.88,
                                            ),
                                            shape: BoxShape.circle,
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Color(0x16000000),
                                                blurRadius: 8,
                                                offset: Offset(0, 2),
                                              ),
                                            ],
                                          ),
                                          child: const Icon(
                                            Icons.chevron_right_rounded,
                                            size: 18,
                                            color: AppColors.textSecondary,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: const [
                                Icon(
                                  Icons.keyboard_double_arrow_left_rounded,
                                  size: 14,
                                  color: AppColors.textHint,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  'Swipe for more',
                                  style: TextStyle(
                                    color: AppColors.textHint,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                SizedBox(width: 4),
                                Icon(
                                  Icons.keyboard_double_arrow_right_rounded,
                                  size: 14,
                                  color: AppColors.textHint,
                                ),
                              ],
                            ),
                          ],
                        ),
                ),
                const SizedBox(height: AppSpacing.lg),
                _sectionCard(
                  title: 'Apply promo code',
                  child: Row(
                    children: [
                      const Icon(
                        Icons.sell_outlined,
                        color: AppColors.textHint,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: TextField(
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.textPrimary,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Enter promo code',
                            hintStyle: TextStyle(
                              color: AppColors.textHint,
                              fontSize: 14,
                            ),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 0,
                              vertical: 10,
                            ),
                          ),
                        ),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.sm,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Coupons will be available soon.'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                        child: const Text(
                          'Apply',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                _sectionCard(
                  title: 'Bill details',
                  child: Column(
                    children: [
                      _billRow('Items total', '₹$itemTotal'),
                      const SizedBox(height: AppSpacing.sm),
                      _billRow(
                        'Delivery charge',
                        _calculateDeliveryCharge(itemTotal) == 0
                            ? 'FREE'
                            : '₹${_calculateDeliveryCharge(itemTotal)}',
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      _billRow('Handling charge', '₹0'),
                      const SizedBox(height: AppSpacing.sm),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                        child: Divider(height: 1),
                      ),
                      _billRow('Grand total', '₹$grandTotal', bold: true),
                      const SizedBox(height: AppSpacing.sm),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          freeDeliveryUnlocked
                              ? '🎉 Free delivery unlocked for this order'
                              : 'Add product worth ₹$amountToUnlockFreeDelivery more to unlock FREE delivery',
                          style: const TextStyle(
                            color: Color(0xFF1B8D3F),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                _sectionCard(
                  title: 'Delivery section',
                  trailing: TextButton(
                    onPressed: () => _openDetailsBottomSheet(editIndex: null),
                    child: const Text('Add new address'),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_savedAddresses.isNotEmpty) ...[
                        const Text(
                          'Saved addresses',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Column(
                          children: List.generate(_savedAddresses.length, (
                            index,
                          ) {
                            final entry = _savedAddresses[index];
                            final address =
                                entry['deliveryAddress']
                                    as Map<String, dynamic>? ??
                                const <String, dynamic>{};
                            final contact =
                                entry['contactDetails']
                                    as Map<String, dynamic>? ??
                                const <String, dynamic>{};
                            final summary = [
                              (address['line1'] ?? '').toString(),
                              (address['line2'] ?? '').toString(),
                              (address['city'] ?? '').toString(),
                              (address['state'] ?? '').toString(),
                              (address['pincode'] ?? '').toString(),
                            ].where((e) => e.trim().isNotEmpty).join(', ');
                            final isSelected = index == _selectedAddressIndex;

                            return InkWell(
                              onTap: () => _selectAddress(index),
                              borderRadius: BorderRadius.circular(AppRadius.md),
                              child: Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(
                                  bottom: AppSpacing.sm,
                                ),
                                padding: const EdgeInsets.all(AppSpacing.md),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? AppColors.primary.withOpacity(0.08)
                                      : AppColors.surface,
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.md,
                                  ),
                                  border: Border.all(
                                    color: isSelected
                                        ? AppColors.primary.withOpacity(0.35)
                                        : AppColors.divider,
                                  ),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      isSelected
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_unchecked,
                                      color: isSelected
                                          ? AppColors.primary
                                          : AppColors.textHint,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            (contact['receiverName'] ?? '')
                                                    .toString()
                                                    .trim()
                                                    .isEmpty
                                                ? 'Address ${index + 1}'
                                                : (contact['receiverName'] ??
                                                          '')
                                                      .toString(),
                                            style: const TextStyle(
                                              color: AppColors.textPrimary,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 13,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            summary.isEmpty
                                                ? 'No address details'
                                                : summary,
                                            style: const TextStyle(
                                              color: AppColors.textSecondary,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          onPressed: () =>
                                              _openDetailsBottomSheet(
                                                editIndex: index,
                                              ),
                                          icon: const Icon(
                                            Icons.edit_outlined,
                                            size: 18,
                                            color: AppColors.textSecondary,
                                          ),
                                        ),
                                        IconButton(
                                          onPressed: () =>
                                              _deleteAddress(index),
                                          icon: const Icon(
                                            Icons.delete_outline,
                                            size: 18,
                                            color: AppColors.error,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }),
                        ),
                        const SizedBox(height: 6),
                      ],
                      const Text(
                        'Delivery address',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _savedAddresses.isEmpty
                            ? (addressSummary.isEmpty
                                  ? 'Not added yet'
                                  : addressSummary)
                            : [
                                (_savedAddresses[_selectedAddressIndex]['deliveryAddress']
                                            as Map<String, dynamic>? ??
                                        const <String, dynamic>{})['line1']
                                    .toString(),
                                (_savedAddresses[_selectedAddressIndex]['deliveryAddress']
                                            as Map<String, dynamic>? ??
                                        const <String, dynamic>{})['line2']
                                    .toString(),
                                (_savedAddresses[_selectedAddressIndex]['deliveryAddress']
                                            as Map<String, dynamic>? ??
                                        const <String, dynamic>{})['city']
                                    .toString(),
                                (_savedAddresses[_selectedAddressIndex]['deliveryAddress']
                                            as Map<String, dynamic>? ??
                                        const <String, dynamic>{})['state']
                                    .toString(),
                                (_savedAddresses[_selectedAddressIndex]['deliveryAddress']
                                            as Map<String, dynamic>? ??
                                        const <String, dynamic>{})['pincode']
                                    .toString(),
                              ].where((e) => e.trim().isNotEmpty).join(', '),
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      const Text(
                        'Contact details',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _savedAddresses.isEmpty
                            ? '${_receiverNameController.text.trim()} • ${_phoneController.text.trim()}'
                            : '${((_savedAddresses[_selectedAddressIndex]['contactDetails'] as Map<String, dynamic>? ?? const <String, dynamic>{})['receiverName'] ?? '').toString().trim()} • ${((_savedAddresses[_selectedAddressIndex]['contactDetails'] as Map<String, dynamic>? ?? const <String, dynamic>{})['phone'] ?? '').toString().trim()}',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  MediaQuery.of(context).padding.bottom + AppSpacing.md,
                ),
                decoration: const BoxDecoration(
                  color: Color(0xFFF6EEFF),
                  border: Border(top: BorderSide(color: AppColors.divider)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_checkingRecoveredPayment)
                      const Padding(
                        padding: EdgeInsets.only(bottom: AppSpacing.sm),
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                    if ((_recoveredPayuTxnId ?? '').trim().isNotEmpty)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: AppSpacing.md),
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        decoration: BoxDecoration(
                          color:
                              ((_recoveredPayuStatus ?? '').toLowerCase() ==
                                  'success')
                              ? const Color(0xFFEFFDF5)
                              : const Color(0xFFFFFBEB),
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          border: Border.all(
                            color:
                                ((_recoveredPayuStatus ?? '').toLowerCase() ==
                                    'success')
                                ? const Color(0xFFBBF7D0)
                                : const Color(0xFFFDE68A),
                          ),
                        ),
                        child: Text(
                          ((_recoveredPayuStatus ?? '').toLowerCase() ==
                                  'success')
                              ? (widget.autoFinalizeRecoveredPayuOrder
                                    ? 'Recovered payment detected. Finalizing your order now...'
                                    : 'Payment already completed. Tap Place Order to finish.')
                              : 'Recovered payment is being confirmed. Please wait or tap Place Order to retry finalization.',
                          style: TextStyle(
                            color:
                                ((_recoveredPayuStatus ?? '').toLowerCase() ==
                                    'success')
                                ? const Color(0xFF166534)
                                : const Color(0xFF92400E),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    GestureDetector(
                      onTap: _openPaymentMethodSheet,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.md,
                        ),
                        margin: const EdgeInsets.only(bottom: AppSpacing.md),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.account_balance_wallet_outlined,
                              color: AppColors.textSecondary,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _selectedPaymentMethod,
                                style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const Icon(
                              Icons.keyboard_arrow_up,
                              color: AppColors.textSecondary,
                            ),
                          ],
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadius.xl,
                                ),
                              ),
                            ),
                            onPressed: _isPlacingOrder
                                ? null
                                : _suggestionUploading
                                ? null
                                : () => _placeOrder(cart: cart, home: home),
                            child: _isPlacingOrder
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.4,
                                      color: Colors.white,
                                    ),
                                  )
                                : Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        '₹$grandTotal • Place Order',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 16,
                                        ),
                                      ),
                                      const SizedBox(width: AppSpacing.sm),
                                      const Icon(
                                        Icons.arrow_forward_ios_rounded,
                                        size: 14,
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: ConfettiWidget(
                  confettiController: _ensureFreeDeliveryConfettiController(),
                  blastDirectionality: BlastDirectionality.explosive,
                  shouldLoop: false,
                  emissionFrequency: 0.045,
                  numberOfParticles: 45,
                  minBlastForce: 9,
                  maxBlastForce: 18,
                  gravity: 0.22,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: const Color(0xFFFCF6FF),
        borderRadius: BorderRadius.circular(AppRadius.xxl),
        border: Border.all(color: const Color(0xFFE3D4F4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          child,
        ],
      ),
    );
  }

  Widget _billRow(String label, String value, {bool bold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: bold ? 20 : 14,
            fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
