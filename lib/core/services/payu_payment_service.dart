import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:payu_checkoutpro_flutter/PayUConstantKeys.dart';
import 'package:payu_checkoutpro_flutter/payu_checkoutpro_flutter.dart';
import 'package:purecuts/core/constants/feature_flags.dart';
import 'package:purecuts/core/services/performance_trace_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Production-safe PayU service:
/// - SALT never exists in app code
/// - hash generation/verification delegated to backend
/// - supports all methods through CheckoutPro (UPI/Cards/NB/Wallets)
class PayUPaymentService implements PayUCheckoutProProtocol {
  PayUPaymentService()
    : _checkoutPro = PayUCheckoutProFlutter(_singleton),
      _backendBaseUrl = FeatureFlags.payuBackendBaseUrl,
      _merchantKey = FeatureFlags.payuMerchantKey,
      _environment = FeatureFlags.payuEnvironment {
    _singleton._bind(this);
  }

  static final _ServiceProxy _singleton = _ServiceProxy();

  final PayUCheckoutProFlutter _checkoutPro;
  final String _backendBaseUrl;
  final String _merchantKey;
  final String _environment;

  final StreamController<Map<String, dynamic>> _eventsController =
      StreamController<Map<String, dynamic>>.broadcast();

  Map<String, dynamic>? _activeTxn;

  static const String _pendingTxnIdKey = 'payu_pending_txnid';
  static const String _pendingTxnUserIdKey = 'payu_pending_uid';

  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  /// Safe wrapper to prevent adding events to a closed stream
  void _safeAddEvent(Map<String, dynamic> event) {
    if (!_eventsController.isClosed) {
      _eventsController.add(event);
    }
  }

  static Future<String?> getPendingTxnIdForUser(String userId) async {
    final cleanUid = userId.trim();
    if (cleanUid.isEmpty) return null;

    final prefs = await SharedPreferences.getInstance();
    final pendingUid = (prefs.getString(_pendingTxnUserIdKey) ?? '').trim();
    if (pendingUid != cleanUid) return null;

    final pendingTxn = (prefs.getString(_pendingTxnIdKey) ?? '').trim();
    return pendingTxn.isEmpty ? null : pendingTxn;
  }

  static Future<void> clearPendingTransaction() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingTxnIdKey);
    await prefs.remove(_pendingTxnUserIdKey);
  }

  Future<void> _persistPendingTransaction({
    required String txnId,
    required String userId,
  }) async {
    final cleanTxnId = txnId.trim();
    final cleanUid = userId.trim();
    if (cleanTxnId.isEmpty || cleanUid.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingTxnIdKey, cleanTxnId);
    await prefs.setString(_pendingTxnUserIdKey, cleanUid);
  }

  String generateTxnId() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    return 'PC$ms';
  }

  Future<String> startCheckout({
    required String userId,
    required String amount,
    required String productInfo,
    required String firstName,
    required String email,
    required String phone,
    Map<String, dynamic>? orderDraft,
  }) async {
    final txnId = generateTxnId();

    _activeTxn = {
      'txnid': txnId,
      'amount': _normalizeAmount(amount),
      'productinfo': productInfo,
      'firstname': firstName,
      'email': email,
      'phone': phone,
      'userId': userId,
    };

    // Pre-flight call: creates initiated payment record in backend + validates payload.
    final preflight = await _requestHash({
      'txnid': txnId,
      'amount': _activeTxn!['amount'],
      'productinfo': productInfo,
      'firstname': firstName,
      'email': email,
      'phone': phone,
      'userId': userId,
      if (orderDraft != null) 'orderDraft': orderDraft,
    });

    final resolvedKey =
        (preflight['key'] ?? _merchantKey).toString().trim().isNotEmpty
        ? (preflight['key'] ?? _merchantKey).toString().trim()
        : _merchantKey;
    final resolvedEnvironment =
        (preflight['environment'] ?? _environment).toString().trim().isNotEmpty
        ? (preflight['environment'] ?? _environment).toString().trim()
        : _environment;

    final normalizedUserId = userId.trim().isNotEmpty ? userId.trim() : phone;
    final userCredential = '$resolvedKey:$normalizedUserId';

    _activeTxn!['amount'] = _normalizeAmount(_activeTxn!['amount'].toString());

    await _persistPendingTransaction(txnId: txnId, userId: userId);

    final payUPaymentParams = {
      PayUPaymentParamKey.key: resolvedKey,
      PayUPaymentParamKey.amount: _activeTxn!['amount'],
      PayUPaymentParamKey.productInfo: productInfo,
      PayUPaymentParamKey.firstName: firstName,
      PayUPaymentParamKey.email: email,
      PayUPaymentParamKey.phone: phone,
      PayUPaymentParamKey.android_surl: FeatureFlags.payuAndroidSuccessUrl,
      PayUPaymentParamKey.android_furl: FeatureFlags.payuAndroidFailureUrl,
      PayUPaymentParamKey.ios_surl: FeatureFlags.payuIosSuccessUrl,
      PayUPaymentParamKey.ios_furl: FeatureFlags.payuIosFailureUrl,
      PayUPaymentParamKey.environment: resolvedEnvironment,
      // Required for saved-card related flows; prevents "user_credentials is missing" errors.
      PayUPaymentParamKey.userCredential: userCredential,
      PayUPaymentParamKey.transactionId: txnId,
      PayUPaymentParamKey.additionalParam: {
        PayUAdditionalParamKeys.udf1: userId,
        PayUAdditionalParamKeys.udf2: 'purecuts',
      },
      PayUPaymentParamKey.enableNativeOTP: true,
    };

    final payUCheckoutProConfig = {
      PayUCheckoutProConfigKeys.merchantName: 'PureCuts',
      PayUCheckoutProConfigKeys.showExitConfirmationOnCheckoutScreen: true,
      PayUCheckoutProConfigKeys.showExitConfirmationOnPaymentScreen: true,
      PayUCheckoutProConfigKeys.autoSelectOtp: true,
      PayUCheckoutProConfigKeys.merchantResponseTimeout: 30000,
      // Prevent SDK from forcing saved-card storage paths when credentials are not available.
      PayUCheckoutProConfigKeys.enableSavedCard: false,
      // Keep method ordering broad to surface all options.
      PayUCheckoutProConfigKeys.paymentModesOrder: [
        {'UPI': ''},
        {'CARD': ''},
        {'NB': ''},
        {'WALLET': ''},
      ],
    };

    unawaited(
      _checkoutPro
          .openCheckoutScreen(
            payUPaymentParams: payUPaymentParams,
            payUCheckoutProConfig: payUCheckoutProConfig,
          )
          .catchError((error) {
            _safeAddEvent({
              'type': 'error',
              'txnid': txnId,
              'message': error.toString(),
            });
          }),
    );

    return txnId;
  }

  String _normalizeAmount(String rawAmount) {
    final parsed = double.tryParse(rawAmount.trim());
    if (parsed == null || parsed <= 0) {
      return rawAmount.trim();
    }
    return parsed.toStringAsFixed(2);
  }

  Future<Map<String, dynamic>> _requestHash(
    Map<String, dynamic> payload,
  ) async {
    return PerformanceTraceService.record('api_network_request_time', () async {
      final uri = Uri.parse('$_backendBaseUrl/generate-hash');
      final response = await http.post(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      final map = _decodeJson(response.body);
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          map['ok'] != true) {
        throw Exception(map['error']?.toString() ?? 'Unable to generate hash.');
      }

      return map;
    });
  }

  Future<Map<String, dynamic>> _verifyPayment(
    Map<String, dynamic> payload,
  ) async {
    return PerformanceTraceService.record('api_network_request_time', () async {
      final uri = Uri.parse('$_backendBaseUrl/verify-payment');
      final response = await http.post(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      final map = _decodeJson(response.body);
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          map['ok'] != true) {
        throw Exception(
          map['error']?.toString() ?? 'Unable to verify payment.',
        );
      }

      return map;
    });
  }

  Future<Map<String, dynamic>> _syncPaymentStatus({
    required String txnid,
    required String userId,
  }) async {
    return PerformanceTraceService.record('api_network_request_time', () async {
      final uri = Uri.parse('$_backendBaseUrl/sync-payment-status');
      final response = await http.post(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'txnid': txnid, 'userId': userId}),
      );

      final map = _decodeJson(response.body);
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          map['ok'] != true) {
        throw Exception(
          map['error']?.toString() ?? 'Unable to sync payment status.',
        );
      }

      return map;
    });
  }

  Map<String, dynamic> _decodeJson(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
      return {'raw': decoded};
    } catch (_) {
      return {'raw': source};
    }
  }

  Map<String, dynamic> _normalizeResponse(dynamic response) {
    if (response is Map<String, dynamic>) return response;
    if (response is Map) {
      return response.map((key, value) => MapEntry(key.toString(), value));
    }
    if (response is String && response.trim().isNotEmpty) {
      return _decodeJson(response);
    }
    return <String, dynamic>{};
  }

  Map<String, dynamic> _expandCallbackPayload(dynamic response) {
    final base = _normalizeResponse(response);
    final expanded = <String, dynamic>{...base};

    Map<String, dynamic> asMap(dynamic value) {
      if (value is Map<String, dynamic>) return value;
      if (value is Map) {
        return value.map((key, value) => MapEntry(key.toString(), value));
      }
      if (value is String && value.trim().isNotEmpty) {
        final decoded = _decodeJson(value);
        if (decoded.isNotEmpty && decoded['raw'] == null) {
          return decoded;
        }
      }
      return const <String, dynamic>{};
    }

    const nestedKeys = [
      'result',
      'response',
      'payuResponse',
      'merchantResponse',
      'data',
    ];
    for (final key in nestedKeys) {
      final nested = asMap(base[key]);
      if (nested.isEmpty) continue;
      for (final entry in nested.entries) {
        expanded.putIfAbsent(entry.key, () => entry.value);
      }
    }

    return expanded;
  }

  String _firstValue(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = (map[key] ?? '').toString().trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  Future<void> _handleTerminalCallback({
    required String status,
    required dynamic response,
  }) async {
    final txn = _activeTxn;
    if (txn == null) return;

    final payload = _expandCallbackPayload(response);
    final callbackHash = _firstValue(payload, [
      'hash',
      'payuHash',
      'payment_hash',
      'txnHash',
      'responseHash',
    ]);

    if ((status == 'success' || status == 'failure') && callbackHash.isEmpty) {
      final resolvedTxnId =
          _firstValue(payload, ['txnid', 'transactionId', 'txnId']).isNotEmpty
          ? _firstValue(payload, ['txnid', 'transactionId', 'txnId'])
          : (txn['txnid'] ?? '').toString();
      final resolvedUserId = (txn['userId'] ?? '').toString();

      _safeAddEvent({
        'type': 'pending',
        'txnid': resolvedTxnId,
        'message':
            'Payment callback received without hash. Waiting for confirmation sync.',
      });

      if (resolvedTxnId.isNotEmpty && resolvedUserId.isNotEmpty) {
        unawaited(
          _syncPaymentStatus(txnid: resolvedTxnId, userId: resolvedUserId)
              .then((syncResult) async {
                _safeAddEvent({
                  'type': 'sync',
                  'txnid': resolvedTxnId,
                  ...syncResult,
                });
                final status = (syncResult['status'] ?? '')
                    .toString()
                    .toLowerCase();
                if (status == 'success' ||
                    status == 'failure' ||
                    status == 'cancelled') {
                  await clearPendingTransaction();
                }
              })
              .catchError((error) {
                _safeAddEvent({
                  'type': 'pending',
                  'txnid': resolvedTxnId,
                  'message': 'Confirmation sync failed once: $error',
                });
              }),
        );
      }
      return;
    }

    final verifyPayload = {
      'status': status,
      'hash': callbackHash,
      'txnid':
          _firstValue(payload, ['txnid', 'transactionId', 'txnId']).isNotEmpty
          ? _firstValue(payload, ['txnid', 'transactionId', 'txnId'])
          : txn['txnid'],
      'amount': _firstValue(payload, ['amount']).isNotEmpty
          ? _firstValue(payload, ['amount'])
          : txn['amount'],
      'productinfo':
          _firstValue(payload, ['productinfo', 'productInfo']).isNotEmpty
          ? _firstValue(payload, ['productinfo', 'productInfo'])
          : (txn['productinfo'] ?? ''),
      'firstname': _firstValue(payload, ['firstname', 'firstName']).isNotEmpty
          ? _firstValue(payload, ['firstname', 'firstName'])
          : (txn['firstname'] ?? ''),
      'email': _firstValue(payload, ['email']).isNotEmpty
          ? _firstValue(payload, ['email'])
          : (txn['email'] ?? ''),
      'key': _firstValue(payload, ['key']).isNotEmpty
          ? _firstValue(payload, ['key'])
          : _merchantKey,
      'additionalCharges': payload['additionalCharges'] ?? '',
      'mihpayid': _firstValue(payload, ['mihpayid', 'mihPayId']),
      'mode': payload['mode'] ?? '',
      'userId': txn['userId'] ?? '',
      'udf1': payload['udf1'] ?? txn['userId'] ?? '',
      'udf2': payload['udf2'] ?? 'purecuts',
      'udf3': payload['udf3'] ?? '',
      'udf4': payload['udf4'] ?? '',
      'udf5': payload['udf5'] ?? '',
    };

    try {
      final verifyResult = await _verifyPayment(verifyPayload);
      _safeAddEvent({'type': 'verify', 'txnid': txn['txnid'], ...verifyResult});
      await clearPendingTransaction();
    } catch (error) {
      _safeAddEvent({
        'type': 'error',
        'txnid': txn['txnid'],
        'message': error.toString(),
      });
    }
  }

  @override
  Future<void> generateHash(Map response) async {
    final txn = _activeTxn;
    if (txn == null) return;

    try {
      final hashString =
          (response[PayUHashConstantsKeys.hashString] ??
                  response['hash_string'] ??
                  '')
              .toString();

      String resolvedHashName =
          (response[PayUHashConstantsKeys.hashName] ??
                  response['hash_name'] ??
                  response['name'] ??
                  '')
              .toString()
              .trim();

      if (resolvedHashName.isEmpty) {
        resolvedHashName = _deriveHashNameFromHashString(hashString);
      }

      final hashPayload = {
        if (resolvedHashName.isNotEmpty) 'hashName': resolvedHashName,
        'hashString': hashString,
        'txnid': txn['txnid'],
        'amount': txn['amount'],
        'productinfo': txn['productinfo'],
        'firstname': txn['firstname'],
        'email': txn['email'],
        'userId': txn['userId'],
      };

      final hashResponse = await _requestHash(hashPayload);
      final hash = (hashResponse['hash'] ?? '').toString();
      if (hash.isEmpty) {
        throw Exception('Empty hash returned by backend.');
      }

      if (resolvedHashName.isNotEmpty) {
        await _checkoutPro.hashGenerated(hash: {resolvedHashName: hash});
      } else {
        // Fallback: provide hash under common SDK names when callback omits hashName.
        await _checkoutPro.hashGenerated(
          hash: {
            'payment_hash': hash,
            'get_sdk_configuration': hash,
            'get_checkout_details': hash,
            'get_all_offer_details': hash,
            'quickPayEvent': hash,
          },
        );
      }
    } catch (error) {
      _safeAddEvent({
        'type': 'error',
        'txnid': txn['txnid'],
        'message': 'Hash generation failed: $error',
      });
    }
  }

  String _deriveHashNameFromHashString(String hashString) {
    final raw = hashString.trim();
    if (raw.isEmpty) return '';

    // Typical callback format: merchantKey|hashName|payload|
    final segments = raw.split('|');
    if (segments.length >= 2) {
      final candidate = segments[1].trim();
      if (candidate.isNotEmpty && !candidate.startsWith('{')) {
        return candidate;
      }
    }
    return '';
  }

  @override
  Future<void> onPaymentSuccess(dynamic response) async {
    await _handleTerminalCallback(status: 'success', response: response);
  }

  @override
  Future<void> onPaymentFailure(dynamic response) async {
    await _handleTerminalCallback(status: 'failure', response: response);
  }

  @override
  Future<void> onPaymentCancel(Map? response) async {
    final txn = _activeTxn;
    if (txn == null) return;

    _safeAddEvent({
      'type': 'cancel',
      'txnid': txn['txnid'],
      'message': 'Payment cancelled by user.',
    });

    await _handleTerminalCallback(
      status: 'cancelled',
      response: response ?? {},
    );
  }

  @override
  Future<void> onError(Map? response) async {
    final txn = _activeTxn;
    _safeAddEvent({
      'type': 'error',
      'txnid': txn?['txnid'] ?? '',
      'message': response?.toString() ?? 'Unknown PayU error',
    });
    await clearPendingTransaction();
  }

  void dispose() {
    _eventsController.close();
  }
}

class _ServiceProxy implements PayUCheckoutProProtocol {
  PayUPaymentService? _service;

  void _bind(PayUPaymentService service) {
    _service = service;
  }

  @override
  generateHash(Map response) => _service?.generateHash(response);

  @override
  onError(Map? response) => _service?.onError(response);

  @override
  onPaymentCancel(Map? response) => _service?.onPaymentCancel(response);

  @override
  onPaymentFailure(response) => _service?.onPaymentFailure(response);

  @override
  onPaymentSuccess(response) => _service?.onPaymentSuccess(response);
}
