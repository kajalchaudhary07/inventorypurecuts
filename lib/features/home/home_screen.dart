import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart' as fb_auth;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/services/firestore_service.dart';
import 'package:purecuts/core/services/image_bandwidth_telemetry.dart';
import 'package:purecuts/core/services/payu_payment_service.dart';
import 'package:purecuts/core/services/push_notification_service.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/core/utils/product_image_contract.dart';
import 'package:purecuts/core/utils/tier_pricing.dart';
import 'package:purecuts/core/utils/variant_selection_guard.dart';
import 'package:purecuts/core/widgets/product_card.dart';
import 'package:purecuts/core/widgets/shimmer_widgets.dart';
import 'package:purecuts/core/widgets/sticky_cart_bar.dart';
import 'package:purecuts/core/models/cart_model.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';
import 'package:purecuts/features/categories/parent_category_screen.dart';
import 'package:purecuts/features/categories/categories_screen.dart';
import 'package:purecuts/features/favorites/favorites_screen.dart';
import 'package:purecuts/features/home/home_provider.dart';
import 'package:purecuts/features/location/location_picker_sheet.dart';
import 'package:purecuts/features/orders/checkout_screen.dart';
import 'package:purecuts/features/products/product_detail_screen.dart';
import 'package:purecuts/features/products/product_list_screen.dart';
import 'package:purecuts/features/profile/profile_screen.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:video_player/video_player.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const double _bannerHeight = 132;
  static const Duration _bannerInitialSlideDelay = Duration(seconds: 7);
  final PageController _bannerPageController = PageController();
  final GlobalKey _headerSearchBarKey = GlobalKey();
  final GlobalKey _categoriesSectionKey = GlobalKey();
  final GlobalKey _hotDealsSectionKey = GlobalKey();
  Timer? _bannerAutoSlideTimer;
  int _currentBannerPage = 0;
  int _bannerCountForTimer = 0;
  Set<String> _purchasedProductIds = <String>{};
  final ScrollController _contentScrollController = ScrollController();
  final FirestoreService _firestoreService = FirestoreService();
  bool _hasOrderHistory = false;
  bool _orderHistoryResolved = false;
  bool _orderHistoryLoading = false;
  bool _payuRecoveryLoading = false;
  String? _sessionNotifiedRecoveryTxnId;
  bool _showStickySearch = false;
  bool _showStickyCategories = false;
  bool _stickyLabelsOnly = false;
  double? _stickySearchShowOffset;
  double? _stickyShowOffset;
  static const double _stickySearchBarHeight = 56;
  static const double _stickyCategoryTopWhenSearchVisible =
      _stickySearchBarHeight + 2;
  static const double _stickySearchHysteresis = 20;
  static const double _stickyCategoryHysteresis = 16;
  AnimationController? _bannerImageZoomController;
  Animation<double> _bannerImageZoomAnimation =
      const AlwaysStoppedAnimation<double>(1.0);
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechReady = false;
  bool _isListening = false;
  bool _speechDialogVisible = false;
  bool _showAllPopularProducts = false;
  String? _speechLocaleId;
  ValueNotifier<String>? _activeTranscript;
  bool _pendingVoiceSubmit = false;
  StreamSubscription<fb_auth.User?>? _authStateSub;
  Timer? _payuRecoveryRetryTimer;
  Timer? _payuRecoveryPollTimer;
  int _payuRecoveryPollAttempts = 0;
  int _hotDealsShuffleSeed = DateTime.now().microsecondsSinceEpoch;
  int _recommendedShuffleSeed = DateTime.now().microsecondsSinceEpoch + 1;
  bool _stickyThresholdRecalcQueued = false;

  static const int _maxPayuRecoveryPollAttempts = 20;
  static const Duration _payuRecoveryPollInterval = Duration(seconds: 3);

  void _stopPayuRecoveryPolling() {
    _payuRecoveryPollTimer?.cancel();
    _payuRecoveryPollTimer = null;
    _payuRecoveryPollAttempts = 0;
  }

  void _ensurePayuRecoveryPolling() {
    if (_payuRecoveryPollTimer != null) return;
    _payuRecoveryPollAttempts = 0;
    _payuRecoveryPollTimer = Timer.periodic(_payuRecoveryPollInterval, (_) {
      if (!mounted) {
        _stopPayuRecoveryPolling();
        return;
      }
      if (_payuRecoveryPollAttempts >= _maxPayuRecoveryPollAttempts) {
        _stopPayuRecoveryPolling();
        return;
      }
      _payuRecoveryPollAttempts += 1;
      unawaited(_resolvePayuRecoveryAction(force: true));
    });
  }

  String _speechErrorMessage(dynamic error) {
    final rawMsg = (error?.errorMsg ?? error?.toString() ?? '').toString();
    final msg = rawMsg.toLowerCase();
    if (msg.contains('no_match') ||
        msg.contains('no match') ||
        msg.contains('speech_timeout') ||
        msg.contains('speech timeout') ||
        msg.contains('aborted')) {
      return 'Didn\'t catch that. Try speaking a little slower.';
    }
    if (msg.contains('permission') || msg.contains('not allowed')) {
      return 'Microphone permission is required. Please enable it in settings.';
    }
    final permanent = (error?.permanent == true);
    return permanent
        ? 'Microphone is unavailable right now. Please try again.'
        : 'Listening stopped. Tap mic and try again.';
  }

  void _ensureBannerImageZoomReady() {
    if (_bannerImageZoomController != null) return;

    final controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    );

    _bannerImageZoomController = controller;
    _bannerImageZoomAnimation = Tween<double>(
      begin: 1.0,
      end: 1.08,
    ).animate(CurvedAnimation(parent: controller, curve: Curves.easeInOut));

    controller.repeat(reverse: true);
  }

  void _addToCart(Map<String, dynamic> product) {
    if (!ensureVariantSelectedBeforeQuickAdd(context, product)) {
      return;
    }
    context.read<CartModel>().add(product);
  }

  String _baseProductId(String value) {
    final id = value.trim();
    if (id.isEmpty) return '';
    final sep = id.indexOf('::');
    if (sep <= 0) return id;
    return id.substring(0, sep);
  }

  Future<void> _refreshHomeData() async {
    _hotDealsShuffleSeed = DateTime.now().microsecondsSinceEpoch;
    _recommendedShuffleSeed = DateTime.now().microsecondsSinceEpoch + 1;
    await Future.wait([
      context.read<HomeProvider>().loadData(forceRefresh: true),
      _resolveOrderHistory(force: true),
      _resolvePayuRecoveryAction(force: true),
    ]);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recalculateStickyThresholds();
    });
  }

  Future<void> _resolvePayuRecoveryAction({bool force = false}) async {
    if (_payuRecoveryLoading && !force) return;

    final uid = fb_auth.FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty) {
      _stopPayuRecoveryPolling();
      if (!mounted) return;
      setState(() {
        _payuRecoveryLoading = false;
        _sessionNotifiedRecoveryTxnId = null;
      });
      return;
    }

    _payuRecoveryLoading = true;
    try {
      final pendingTxnId = await PayUPaymentService.getPendingTxnIdForUser(uid);
      if ((pendingTxnId ?? '').trim().isEmpty) {
        _stopPayuRecoveryPolling();
        if (!mounted) return;
        setState(() {
          _sessionNotifiedRecoveryTxnId = null;
        });
        return;
      }

      final paymentDoc = await FirebaseFirestore.instance
          .collection('payments')
          .doc(pendingTxnId)
          .get();

      if (!paymentDoc.exists) {
        await PayUPaymentService.clearPendingTransaction();
        _stopPayuRecoveryPolling();
        if (!mounted) return;
        setState(() {
          _sessionNotifiedRecoveryTxnId = null;
        });
        return;
      }

      final data = paymentDoc.data() ?? const <String, dynamic>{};
      final status = (data['status'] ?? '').toString().toLowerCase();
      final verified = data['hashVerified'] == true;
      final orderPlacementStatus = (data['orderPlacementStatus'] ?? '')
          .toString()
          .toLowerCase();
      final orderRef =
          (data['orderRef'] ?? data['orderId'] ?? data['orderNumber'] ?? '')
              .toString()
              .trim();

      if (status == 'failure' || status == 'cancelled') {
        await PayUPaymentService.clearPendingTransaction();
        _stopPayuRecoveryPolling();
        if (!mounted) return;
        setState(() {
          _sessionNotifiedRecoveryTxnId = null;
        });
        return;
      }

      final placed =
          orderRef.isNotEmpty &&
          (orderPlacementStatus == 'placed' || status == 'success');

      if (!mounted) return;
      final recoveryTxnId = (status == 'success' && verified)
          ? pendingTxnId
          : null;

      final shouldNotifyRecovery =
          (recoveryTxnId ?? '').trim().isNotEmpty &&
          !placed &&
          _sessionNotifiedRecoveryTxnId != recoveryTxnId;

      if (shouldNotifyRecovery) {
        _stopPayuRecoveryPolling();
        _sessionNotifiedRecoveryTxnId = recoveryTxnId;
        unawaited(
          PushNotificationService.instance.showPayuRecoveryNotification(
            txnId: recoveryTxnId,
          ),
        );
      } else {
        final shouldKeepPolling =
            !placed &&
            (status == 'initiated' ||
                status == 'pending' ||
                status == 'submitted' ||
                (status == 'success' && !verified) ||
                (recoveryTxnId ?? '').trim().isEmpty);
        if (shouldKeepPolling) {
          _ensurePayuRecoveryPolling();
        } else {
          _stopPayuRecoveryPolling();
        }
      }
    } catch (_) {
      // Non-blocking home banner hydration.
    } finally {
      _payuRecoveryLoading = false;
    }
  }

  Future<void> _resolveOrderHistory({bool force = false}) async {
    if (_orderHistoryLoading) return;
    if (_orderHistoryResolved && !force) return;

    final uid = fb_auth.FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty) {
      if (!mounted) return;
      setState(() {
        _hasOrderHistory = false;
        _orderHistoryResolved = true;
        _purchasedProductIds = <String>{};
      });
      return;
    }

    _orderHistoryLoading = true;
    try {
      final purchased = await _firestoreService.getUserPurchasedProducts(
        uid: uid,
      );
      if (!mounted) return;
      final purchasedIds = purchased
          .map((p) => _baseProductId((p['id'] ?? '').toString()))
          .where((id) => id.isNotEmpty)
          .toSet();
      setState(() {
        _hasOrderHistory = purchased.isNotEmpty;
        _orderHistoryResolved = true;
        _purchasedProductIds = purchasedIds;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hasOrderHistory = false;
        _orderHistoryResolved = true;
        _purchasedProductIds = <String>{};
      });
    } finally {
      _orderHistoryLoading = false;
    }
  }

  void _openProductDetail(Map<String, dynamic> product) {
    _openProductDetailWithOptions(product);
  }

  void _openProductDetailWithOptions(
    Map<String, dynamic> product, {
    bool autoOpenBulkOrderSheet = false,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProductDetailScreen(
          product: product,
          autoOpenBulkOrderSheet: autoOpenBulkOrderSheet,
        ),
      ),
    );
  }

  int? _bulkTriggerQty(Map<String, dynamic> product) {
    final basePrice =
        ((product['basePrice'] as num?) ?? (product['price'] as num?) ?? 0)
            .toInt();
    final tiers = parsePricingTiers(product['pricingTiers']);
    for (final tier in tiers) {
      if (tier.price < basePrice) return tier.minQty;
    }

    final variableTierMode = (product['variableTierMode'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (variableTierMode == 'universal') {
      final percentageTiers = parsePercentagePricingTiers(
        product['variableUniversalTiers'],
      );
      for (final tier in percentageTiers) {
        if (tier.percentOff > 0) return tier.minQty;
      }
    }

    return null;
  }

  void _openProductSearch({String? query}) {
    final trimmed = query?.trim() ?? '';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ProductListScreen(initialQuery: trimmed.isEmpty ? null : trimmed),
      ),
    );
  }

  Future<void> _initSpeech() async {
    final available = await _speech.initialize(
      onStatus: (status) {
        if (!mounted) return;
        final normalized = status.toLowerCase();
        final listening = normalized.contains('listening');
        if (_isListening != listening) {
          setState(() => _isListening = listening);
        }
        if (!listening && _pendingVoiceSubmit) {
          final spoken = (_activeTranscript?.value ?? '').trim();
          if (spoken.isNotEmpty &&
              spoken != 'Listening...' &&
              !spoken.startsWith('Didn\'t catch')) {
            _submitVoiceQuery(spoken);
            return;
          }
        }
        if (!listening &&
            _activeTranscript != null &&
            _activeTranscript!.value == 'Listening...') {
          _activeTranscript!.value =
              'Didn\'t catch that. Try speaking again clearly.';
        }
      },
      onError: (error) {
        if (!mounted) return;
        setState(() => _isListening = false);
        if (_activeTranscript != null) {
          final current = _activeTranscript!.value.trim();
          if (current.isEmpty || current == 'Listening...') {
            _activeTranscript!.value = _speechErrorMessage(error);
          }
        }
      },
    );

    if (!mounted) return;
    if (available) {
      try {
        final systemLocale = await _speech.systemLocale();
        final locales = await _speech.locales();
        if (systemLocale != null && systemLocale.localeId.trim().isNotEmpty) {
          _speechLocaleId = systemLocale.localeId;
        } else {
          final preferred = locales.where((l) {
            final id = l.localeId.toLowerCase();
            return id == 'en_in' || id.startsWith('en_');
          });
          _speechLocaleId =
              (preferred.isNotEmpty
                      ? preferred.first
                      : locales.isNotEmpty
                      ? locales.first
                      : null)
                  ?.localeId;
        }
      } catch (_) {
        // Keep locale null to let plugin choose device default.
      }
    }

    if (!mounted) return;

    setState(() {
      _speechReady = available;
      if (!available) {
        _isListening = false;
      }
    });
  }

  Future<void> _toggleVoiceSearch() async {
    if (!_speechReady) {
      await _initSpeech();
    }

    if (!_speechReady) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Voice search is unavailable on this device.'),
        ),
      );
      return;
    }

    if (_isListening) {
      _pendingVoiceSubmit = false;
      await _speech.stop();
      _closeSpeechDialog();
      if (!mounted) return;
      setState(() => _isListening = false);
      return;
    }

    final transcript = ValueNotifier<String>('Listening...');
    _activeTranscript = transcript;
    _showSpeechDialog(
      title: 'Voice search',
      transcript: transcript,
      onSubmit: () {
        final spoken = transcript.value.trim();
        if (spoken.isEmpty || spoken == 'Listening...') return;
        _submitVoiceQuery(spoken);
      },
    );

    var launched = false;
    _pendingVoiceSubmit = true;
    await _speech.cancel();
    final started = await _speech.listen(
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.search,
        partialResults: true,
        cancelOnError: false,
      ),
      listenFor: const Duration(seconds: 20),
      pauseFor: const Duration(seconds: 5),
      localeId: _speechLocaleId,
      onResult: (result) {
        if (!mounted || launched) return;
        final spoken = result.recognizedWords.trim();
        transcript.value = spoken.isEmpty ? 'Listening...' : spoken;
        if (!result.finalResult || spoken.isEmpty) return;
        launched = true;
        _submitVoiceQuery(spoken);
      },
    );

    if (!started) {
      _pendingVoiceSubmit = false;
      _closeSpeechDialog();
      _activeTranscript = null;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not start voice input. Please try again.'),
        ),
      );
    }

    if (!mounted) return;
    setState(() => _isListening = started);
  }

  void _submitVoiceQuery(String spoken) {
    if (!_pendingVoiceSubmit || !mounted) return;
    _pendingVoiceSubmit = false;
    _closeSpeechDialog();
    setState(() => _isListening = false);
    _openProductSearch(query: spoken);
  }

  void _closeSpeechDialog() {
    if (!_speechDialogVisible || !mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    _speechDialogVisible = false;
    _activeTranscript = null;
  }

  void _showSpeechDialog({
    required String title,
    required ValueNotifier<String> transcript,
    required VoidCallback onSubmit,
  }) {
    if (!mounted || _speechDialogVisible) return;
    _speechDialogVisible = true;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: ValueListenableBuilder<String>(
            valueListenable: transcript,
            builder: (_, text, __) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _isListening ? Icons.mic : Icons.mic_none_rounded,
                        color: _isListening
                            ? AppColors.primary
                            : AppColors.textHint,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(_isListening ? 'Listening...' : 'Tap mic to speak'),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      text,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await _speech.stop();
                _closeSpeechDialog();
                if (!mounted) return;
                setState(() => _isListening = false);
              },
              child: const Text('Cancel'),
            ),
            FilledButton(onPressed: onSubmit, child: const Text('Search')),
          ],
        );
      },
    ).whenComplete(() {
      _speechDialogVisible = false;
      _activeTranscript = null;
      transcript.dispose();
    });
  }

  Widget _buildSmallCartControl(Map<String, dynamic> product) {
    return Consumer<CartModel>(
      builder: (_, cart, __) {
        final qty = cart.quantityOf((product['id'] ?? '').toString());
        final bulkTriggerQty = _bulkTriggerQty(product);
        final bulkReached =
            bulkTriggerQty != null && qty >= bulkTriggerQty && qty > 0;

        if (qty == 0) {
          return GestureDetector(
            onTap: () => _addToCart(product),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.10),
                    blurRadius: 6,
                  ),
                ],
              ),
              child: const Icon(Icons.add, color: AppColors.primary, size: 16),
            ),
          );
        }

        if (bulkReached) {
          return GestureDetector(
            onTap: () => _openProductDetailWithOptions(
              product,
              autoOpenBulkOrderSheet: true,
            ),
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.10),
                    blurRadius: 6,
                  ),
                ],
              ),
              child: const Center(
                child: Text(
                  'BULK',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          );
        }

        return Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.10), blurRadius: 6),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () => cart.remove((product['id'] ?? '').toString()),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.remove, color: Colors.white, size: 14),
                ),
              ),
              Text(
                '$qty',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              GestureDetector(
                onTap: () {
                  _addToCart(product);
                  if (bulkTriggerQty != null && qty + 1 >= bulkTriggerQty) {
                    _openProductDetailWithOptions(
                      product,
                      autoOpenBulkOrderSheet: true,
                    );
                  }
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.add, color: Colors.white, size: 14),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildWideCartControl(Map<String, dynamic> product) {
    return Consumer<CartModel>(
      builder: (_, cart, __) {
        final qty = cart.quantityOf((product['id'] ?? '').toString());
        final bulkTriggerQty = _bulkTriggerQty(product);
        final bulkReached =
            bulkTriggerQty != null && qty >= bulkTriggerQty && qty > 0;

        if (qty == 0) {
          return SizedBox(
            width: double.infinity,
            height: 30,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
                elevation: 0,
              ),
              onPressed: () => _addToCart(product),
              child: const Text('Add to Cart'),
            ),
          );
        }

        if (bulkReached) {
          return SizedBox(
            width: double.infinity,
            height: 30,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
                elevation: 0,
              ),
              onPressed: () => _openProductDetailWithOptions(
                product,
                autoOpenBulkOrderSheet: true,
              ),
              child: const Text('Bulk order'),
            ),
          );
        }

        return Container(
          width: double.infinity,
          height: 30,
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => cart.remove((product['id'] ?? '').toString()),
                  child: const Center(
                    child: Icon(Icons.remove, color: Colors.white, size: 16),
                  ),
                ),
              ),
              Text(
                '$qty',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    _addToCart(product);
                    if (bulkTriggerQty != null && qty + 1 >= bulkTriggerQty) {
                      _openProductDetailWithOptions(
                        product,
                        autoOpenBulkOrderSheet: true,
                      );
                    }
                  },
                  child: const Center(
                    child: Icon(Icons.add, color: Colors.white, size: 16),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
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

  double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    final raw = value.toString().trim();
    if (raw.isEmpty) return 0;
    final cleaned = raw.replaceAll(RegExp(r'[^0-9.-]'), '');
    return double.tryParse(cleaned) ?? 0;
  }

  int? _resolveDiscountPercent(Map<String, dynamic> product) {
    final explicitCandidates = [
      product['discountPercent'],
      product['discount_percentage'],
      product['discount'],
      product['offerPercent'],
      product['offerPercentage'],
      product['offer'],
    ];

    for (final candidate in explicitCandidates) {
      final parsed = _toDouble(candidate);
      if (parsed > 0) {
        return parsed.round().clamp(1, 99);
      }
    }

    final original = _toDouble(
      product['originalPrice'] ?? product['mrp'] ?? product['listPrice'],
    );
    final sale = _toDouble(product['price'] ?? product['salePrice']);

    if (original <= 0 || sale <= 0 || sale >= original) return null;

    final pct = (((original - sale) / original) * 100).round();
    if (pct <= 0) return null;
    return pct.clamp(1, 99);
  }

  Widget _buildProductImage(
    String imagePath, {
    double? width,
    double? height,
    BoxFit fit = BoxFit.contain,
  }) {
    final resolved = _normalizeImagePath(imagePath);

    if (resolved.isEmpty) {
      return Container(
        width: width,
        height: height,
        color: AppColors.surface,
        child: const Icon(Icons.image, color: AppColors.textHint, size: 32),
      );
    }

    if (!resolved.startsWith('assets/')) {
      unawaited(
        ImageBandwidthTelemetry.instance.trackImageLoad(
          screen: 'home_product_image',
          imageUrl: resolved,
        ),
      );

      int? toCachePx(double? logicalPixels) {
        if (logicalPixels == null || !logicalPixels.isFinite) return null;
        if (logicalPixels <= 0) return null;
        final scaled = logicalPixels * MediaQuery.of(context).devicePixelRatio;
        if (!scaled.isFinite || scaled <= 0) return null;
        return scaled.round();
      }

      final targetHeight = toCachePx(height);
      final targetWidth = toCachePx(width);

      return CachedNetworkImage(
        imageUrl: resolved,
        width: width,
        height: height,
        fit: fit,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        memCacheHeight: targetHeight,
        memCacheWidth: targetWidth,
        maxHeightDiskCache: targetHeight,
        maxWidthDiskCache: targetWidth,
        placeholder: (_, __) => Container(
          width: width,
          height: height,
          color: AppColors.surface,
          child: const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            ),
          ),
        ),
        errorWidget: (_, __, ___) => Container(
          width: width,
          height: height,
          color: AppColors.surface,
          child: const Icon(Icons.image, color: AppColors.textHint, size: 32),
        ),
      );
    }

    return Image.asset(
      resolved,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (_, __, ___) => Container(
        width: width,
        height: height,
        color: AppColors.surface,
        child: const Icon(Icons.image, color: AppColors.textHint, size: 32),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _hotDealsShuffleSeed = DateTime.now().microsecondsSinceEpoch;
    _recommendedShuffleSeed = DateTime.now().microsecondsSinceEpoch + 1;
    WidgetsBinding.instance.addObserver(this);
    _ensureBannerImageZoomReady();
    _initSpeech();
    _contentScrollController.addListener(_updateStickyCategories);

    _authStateSub = fb_auth.FirebaseAuth.instance.authStateChanges().listen((
      user,
    ) {
      if (!mounted || user == null) return;
      unawaited(_resolvePayuRecoveryAction(force: true));
    });

    _payuRecoveryRetryTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      unawaited(_resolvePayuRecoveryAction(force: true));
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final hp = context.read<HomeProvider>();
      Future.wait([
        // Load the startup-lite pool first, then hydrate the full visibility
        // catalog so category and search sections never render partial data.
        hp.loadData().then((_) => hp.ensureVisibilityCatalogLoaded()),
        _resolveOrderHistory(force: true),
        _resolvePayuRecoveryAction(force: true),
      ]);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recalculateStickyThresholds();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (mounted) {
        setState(() {
          _hotDealsShuffleSeed = DateTime.now().microsecondsSinceEpoch;
          _recommendedShuffleSeed = DateTime.now().microsecondsSinceEpoch + 1;
        });
      }
      unawaited(_resolvePayuRecoveryAction(force: true));
    }
  }

  void _recalculateStickyThresholds() {
    if (!mounted || !_contentScrollController.hasClients) return;

    final currentOffset = _contentScrollController.offset;
    final safeTop = MediaQuery.of(context).padding.top;
    final stickyAnchorGlobal = safeTop - 2;

    final searchContext = _headerSearchBarKey.currentContext;
    if (searchContext != null) {
      final searchBox = searchContext.findRenderObject() as RenderBox?;
      if (searchBox != null) {
        final searchTopGlobal = searchBox.localToGlobal(Offset.zero).dy;
        _stickySearchShowOffset =
            currentOffset + (searchTopGlobal - stickyAnchorGlobal);
      }
    }

    final categoriesContext = _categoriesSectionKey.currentContext;
    if (categoriesContext != null) {
      final categoriesBox = categoriesContext.findRenderObject() as RenderBox?;
      if (categoriesBox != null) {
        final categoriesTopGlobal = categoriesBox.localToGlobal(Offset.zero).dy;
        _stickyShowOffset =
            currentOffset + (categoriesTopGlobal - stickyAnchorGlobal);
      }
    }

    if (_stickyShowOffset == null || _stickySearchShowOffset == null) {
      _queueStickyThresholdRecalc();
      return;
    }

    _updateStickyCategories();
  }

  void _queueStickyThresholdRecalc() {
    if (!mounted || _stickyThresholdRecalcQueued) return;
    _stickyThresholdRecalcQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stickyThresholdRecalcQueued = false;
      if (!mounted) return;
      _recalculateStickyThresholds();
    });
  }

  void _updateStickyCategories() {
    if (!mounted || !_contentScrollController.hasClients) return;

    if (_stickyShowOffset == null || _stickySearchShowOffset == null) {
      _queueStickyThresholdRecalc();
      return;
    }

    final offset = _contentScrollController.offset;
    final stickySearchOffset = _stickySearchShowOffset ?? double.infinity;
    final stickyCategoryOffset = _stickyShowOffset ?? double.infinity;

    final searchShowThreshold = stickySearchOffset;
    final searchHideThreshold = stickySearchOffset - _stickySearchHysteresis;
    final categoryShowThreshold = stickyCategoryOffset;
    final categoryHideThreshold =
        stickyCategoryOffset - _stickyCategoryHysteresis;

    final shouldShowSearch = _showStickySearch
        ? offset >= searchHideThreshold
        : offset >= searchShowThreshold;
    final shouldShowSticky = _showStickyCategories
        ? offset >= categoryHideThreshold
        : offset >= categoryShowThreshold;
    const labelsOnly = false;

    if (shouldShowSearch != _showStickySearch ||
        shouldShowSticky != _showStickyCategories ||
        labelsOnly != _stickyLabelsOnly) {
      setState(() {
        _showStickySearch = shouldShowSearch;
        _showStickyCategories = shouldShowSticky;
        _stickyLabelsOnly = labelsOnly;
      });
    }
  }

  void _syncBannerAutoSlide(
    int bannerCount,
    List<Map<String, dynamic>> banners,
  ) {
    if (_bannerCountForTimer == bannerCount) {
      if (bannerCount > 1 && _bannerAutoSlideTimer == null) {
        _setAutoSlideTimer(banners, _currentBannerPage);
      }
      return;
    }

    _bannerCountForTimer = bannerCount;
    _currentBannerPage = 0;
    _bannerAutoSlideTimer?.cancel();

    if (bannerCount <= 1) return;

    _setAutoSlideTimer(banners, 0, useInitialDelay: true);
  }

  bool _isBannerVideo(Map<String, dynamic> banner) {
    final mediaType = (banner['mediaType'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final mediaUrl = (banner['mediaUrl'] ?? banner['image'] ?? '').toString();

    return mediaType == 'video' ||
        RegExp(
          r'\.(mp4|mov|m4v|webm|ogv|m3u8)(\?|#|$)',
          caseSensitive: false,
        ).hasMatch(mediaUrl);
  }

  void _setAutoSlideTimer(
    List<Map<String, dynamic>> banners,
    int currentIndex, {
    bool useInitialDelay = false,
  }) {
    _bannerAutoSlideTimer?.cancel();

    if (banners.isEmpty) return;
    final safeIndex = currentIndex.clamp(0, banners.length - 1);

    final currentBanner = banners[safeIndex];
    final isVideo = _isBannerVideo(currentBanner);
    final duration = useInitialDelay
        ? _bannerInitialSlideDelay
        : (isVideo ? const Duration(seconds: 10) : const Duration(seconds: 4));

    _bannerAutoSlideTimer = Timer(duration, () {
      if (!_bannerPageController.hasClients) {
        _setAutoSlideTimer(banners, safeIndex);
        return;
      }

      final nextPage = (safeIndex + 1) % banners.length;
      _bannerPageController.animateToPage(
        nextPage,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeInOut,
      );
    });
  }

  Widget _buildBannerImage(String imageUrl) {
    final normalized = _normalizeImagePath(imageUrl);

    if (normalized.isEmpty) {
      return Container(
        color: AppColors.surface,
        child: const Icon(Icons.image, color: AppColors.textHint, size: 30),
      );
    }

    if (normalized.startsWith('assets/')) {
      return Image.asset(
        normalized,
        width: double.infinity,
        height: _bannerHeight,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: AppColors.surface,
          child: const Icon(Icons.image, color: AppColors.textHint, size: 30),
        ),
      );
    }

    final targetWidth = (MediaQuery.of(context).size.width * 2).round();

    unawaited(
      ImageBandwidthTelemetry.instance.trackImageLoad(
        screen: 'home_banner',
        imageUrl: normalized,
      ),
    );

    return CachedNetworkImage(
      imageUrl: normalized,
      fit: BoxFit.cover,
      width: double.infinity,
      height: _bannerHeight,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      memCacheWidth: targetWidth,
      maxWidthDiskCache: targetWidth,
      placeholder: (_, __) => Container(
        color: AppColors.surface,
        child: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      errorWidget: (_, __, ___) => Container(
        color: AppColors.surface,
        child: const Icon(Icons.image, color: AppColors.textHint, size: 30),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authStateSub?.cancel();
    _payuRecoveryRetryTimer?.cancel();
    _stopPayuRecoveryPolling();
    _speech.stop();
    _contentScrollController.removeListener(_updateStickyCategories);
    _contentScrollController.dispose();
    _bannerAutoSlideTimer?.cancel();
    _bannerPageController.dispose();
    _bannerImageZoomController?.dispose();
    super.dispose();
  }

  void _openLocationPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<AuthProvider>(),
        child: const LocationPickerSheet(),
      ),
    );
  }

  String _categoryName(Map<String, dynamic> category) {
    final raw = (category['name'] ?? '').toString().trim();
    return raw.isNotEmpty ? raw : 'Category';
  }

  void _openCategory(String categoryName) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ParentCategoryScreen(categoryName: categoryName),
      ),
    );
  }

  Widget _buildStickyCategoryBar(HomeProvider home) {
    final cats = home.categories;
    if (cats.isEmpty) {
      return const SizedBox.shrink();
    }

    Widget buildIcon(String? iconPath) {
      final cleaned = (iconPath ?? '').trim();
      if (cleaned.isEmpty) {
        return const Icon(
          Icons.category_outlined,
          color: AppColors.textHint,
          size: 16,
        );
      }
      if (cleaned.startsWith('assets/')) {
        return Image.asset(
          cleaned,
          width: 16,
          height: 16,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const Icon(
            Icons.category_outlined,
            color: AppColors.textHint,
            size: 16,
          ),
        );
      }
      return CachedNetworkImage(
        imageUrl: cleaned,
        width: 16,
        height: 16,
        fit: BoxFit.contain,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        memCacheWidth: 48,
        maxWidthDiskCache: 48,
        errorWidget: (_, __, ___) => const Icon(
          Icons.category_outlined,
          color: AppColors.textHint,
          size: 16,
        ),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      padding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: _stickyLabelsOnly ? 7 : 9,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(0),
        boxShadow: const [
          BoxShadow(
            color: Color(0x15000000),
            blurRadius: 12,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: SizedBox(
        height: _stickyLabelsOnly ? 34 : 40,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: cats.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (_, i) {
            final cat = cats[i];
            final name = _categoryName(cat);
            final rawIconPath = cat['icon'] ?? cat['image'];
            final iconPath = rawIconPath == null
                ? null
                : rawIconPath.toString();

            return GestureDetector(
              onTap: () => _openCategory(name),
              child: Container(
                constraints: BoxConstraints(
                  minWidth: _stickyLabelsOnly ? 86 : 92,
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: _stickyLabelsOnly ? 10 : 9,
                  vertical: _stickyLabelsOnly ? 8 : 7,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F2FA),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFE4DFEF)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.max,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (!_stickyLabelsOnly) ...[
                      buildIcon(iconPath),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      name,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: _stickyLabelsOnly ? 12 : 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildStickySearchBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(
              color: Color(0x16A855F7),
              blurRadius: 14,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () => _openProductSearch(),
                child: const Row(
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Icon(
                        Icons.search,
                        color: AppColors.textHint,
                        size: 20,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'Search hair color, scissors, shampoos...',
                        style: TextStyle(
                          color: AppColors.textHint,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              onPressed: _toggleVoiceSearch,
              icon: Icon(
                _isListening ? Icons.mic : Icons.mic_none_rounded,
                color: _isListening ? AppColors.primary : AppColors.textHint,
                size: 20,
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _ensureBannerImageZoomReady();
    final home = context.watch<HomeProvider>();
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          // Lavender gradient covering top half of screen
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: screenHeight * 0.52,
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
          ),
          SafeArea(
            child: Stack(
              children: [
                RefreshIndicator(
                  onRefresh: _refreshHomeData,
                  child: SingleChildScrollView(
                    controller: _contentScrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.of(context).padding.bottom + 120,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildHeader(),
                        home.loading ? _buildShimmer() : _buildContent(home),
                      ],
                    ),
                  ),
                ),
                if (!home.loading)
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    left: 0,
                    right: 0,
                    top: -2,
                    child: IgnorePointer(
                      ignoring: !_showStickySearch,
                      child: AnimatedSlide(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        offset: _showStickySearch
                            ? Offset.zero
                            : const Offset(0, -0.10),
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          opacity: _showStickySearch ? 1 : 0,
                          child: _buildStickySearchBar(),
                        ),
                      ),
                    ),
                  ),
                if (!home.loading)
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    left: 0,
                    right: 0,
                    top: _showStickySearch
                        ? _stickyCategoryTopWhenSearchVisible
                        : -2,
                    child: IgnorePointer(
                      ignoring: !_showStickyCategories,
                      child: AnimatedSlide(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                        offset: _showStickyCategories
                            ? Offset.zero
                            : const Offset(0, -0.10),
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeOutCubic,
                          opacity: _showStickyCategories ? 1 : 0,
                          child: _buildStickyCategoryBar(home),
                        ),
                      ),
                    ),
                  ),
              ],
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
    );
  }

  Widget _buildHeader() {
    final user = context.watch<AuthProvider>().user;

    // Line 1: salon name (bold)
    final salonName = (user?.salonName?.isNotEmpty == true)
        ? user!.salonName!
        : 'My Salon';

    // Line 2: picked address → fallback to state, pincode
    String locationLine = 'Tap to set delivery area';
    if (user != null) {
      if (user.address != null && user.address!.isNotEmpty) {
        locationLine = user.address!;
      } else {
        final parts = <String>[];
        if (user.state?.isNotEmpty == true) parts.add(user.state!);
        if (user.pincode?.isNotEmpty == true) parts.add(user.pincode!);
        if (parts.isNotEmpty) locationLine = parts.join(', ');
      }
    }

    return Container(
      color: Colors.transparent,
      child: Column(
        children: [
          // Location + Cart + Avatar row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => _openLocationPicker(),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.10),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.location_on,
                      color: AppColors.primary,
                      size: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _openLocationPicker(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'DELIVERY TO',
                              style: TextStyle(
                                color: AppColors.primary,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                              ),
                            ),
                            Icon(
                              Icons.expand_more,
                              color: AppColors.primary,
                              size: 14,
                            ),
                          ],
                        ),
                        Text(
                          salonName,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          locationLine,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
                // Cart icon
                Consumer<CartModel>(
                  builder: (_, cart, __) => GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const CheckoutScreen()),
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.shopping_cart_outlined,
                            color: AppColors.textPrimary,
                            size: 22,
                          ),
                        ),
                        if (cart.itemCount > 0)
                          Positioned(
                            top: -2,
                            right: -2,
                            child: Container(
                              width: 18,
                              height: 18,
                              decoration: const BoxDecoration(
                                color: AppColors.primary,
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  '${cart.itemCount}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(width: 8),
                // Favourites icon
                GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const FavoritesScreen()),
                  ),
                  child: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.favorite_border_rounded,
                      color: AppColors.textPrimary,
                      size: 22,
                    ),
                  ),
                ),

                const SizedBox(width: 8),
                // Avatar with initials — taps to Profile
                GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ProfileScreen()),
                  ),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.20),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.primary.withOpacity(0.20),
                      ),
                    ),
                    child: Center(
                      child: user != null
                          ? Text(
                              (user.ownerName ?? user.name).trim().isNotEmpty
                                  ? (user.ownerName ?? user.name)
                                        .trim()[0]
                                        .toUpperCase()
                                  : '?',
                              style: const TextStyle(
                                color: Color.fromARGB(255, 249, 249, 249),
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            )
                          : const Icon(
                              Icons.person,
                              color: AppColors.primary,
                              size: 20,
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Search bar
          Padding(
            key: _headerSearchBarKey,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x16A855F7),
                    blurRadius: 14,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => _openProductSearch(),
                      child: const Row(
                        children: [
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: Icon(
                              Icons.search,
                              color: AppColors.textHint,
                              size: 20,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              'Search hair color, scissors, shampoos...',
                              style: TextStyle(
                                color: AppColors.textHint,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _toggleVoiceSearch,
                    icon: Icon(
                      _isListening ? Icons.mic : Icons.mic_none_rounded,
                      color: _isListening
                          ? AppColors.primary
                          : AppColors.textHint,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
          const Divider(height: 1, thickness: 0.5, color: Color(0xFFF0EBFF)),
        ],
      ),
    );
  }

  Widget _buildShimmer() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const ShimmerBox(width: double.infinity, height: 120, radius: 16),
          const SizedBox(height: 20),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.60,
            ),
            itemCount: 4,
            itemBuilder: (_, __) => const ProductCardShimmer(),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(HomeProvider home) {
    if (_stickyShowOffset == null || _stickySearchShowOffset == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _recalculateStickyThresholds();
      });
    }

    final products = home.productMaps;
    final banners = home.banners;
    final hasBannerData = banners.isNotEmpty;
    _syncBannerAutoSlide(banners.length, banners);
    final unassignedProducts = products
        .where((p) => !_hasExplicitHomeSection(p))
        .toList();
    final user = context.watch<AuthProvider>().user;
    final createdAt = user?.createdAt;
    final fallbackByAccountAge =
        createdAt != null && DateTime.now().difference(createdAt).inDays <= 14;
    final isNewUser = _orderHistoryResolved
        ? !_hasOrderHistory
        : fallbackByAccountAge;
    final hotDealsItems = _productsForSection(products, const [
      'hot_deals',
      'start_first_order',
    ]);
    final recommendedItems = _productsForSection(products, const [
      'recommended_salon',
      'recommended',
    ]);
    final mostBoughtItems = _productsForSection(products, const [
      'most_bought',
      'most_bought_products',
      'bestseller',
    ]);
    final popularItems = _productsForSection(products, const [
      'popular_products',
      'popular',
    ]);
    final popularFallbackItems = unassignedProducts
        .where((p) => p['isPopular'] == true)
        .toList();

    final discountedItems = products
        .where((p) => _resolveDiscountPercent(p) != null)
        .toList();

    final fallbackBrowseItems = isNewUser
        ? _recommendedForNewUser(unassignedProducts)
        : unassignedProducts;
    final hotDealsSeed = _mergeUniqueProductLists(
      hotDealsItems,
      discountedItems,
      maxItems: 24,
    );
    final browseItems = _randomizeHotDealsForView(
      _mergeUniqueProductLists(hotDealsSeed, fallbackBrowseItems, maxItems: 24),
    );
    final recommendedSourceItems = recommendedItems.isNotEmpty
        ? recommendedItems
        : unassignedProducts;
    final recommendedDisplayItems = _randomizeRecommendationsForView(
      recommendedSourceItems
          .where((p) => _toDouble(p['price'] ?? p['salePrice']) > 0)
          .toList(),
    );
    final mostBoughtDisplayItems = mostBoughtItems.isNotEmpty
        ? mostBoughtItems
        : unassignedProducts;
    final popularBaseItems = popularItems.isNotEmpty
        ? popularItems
        : (popularFallbackItems.isNotEmpty
              ? popularFallbackItems
              : unassignedProducts);
    final popularDisplayItems = _sortProductsByRecency(popularBaseItems);
    final visiblePopularItems = _showAllPopularProducts
        ? popularDisplayItems
        : popularDisplayItems.take(8).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Categories section
        Container(
          key: _categoriesSectionKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionHeader('Categories', 'View All'),
              const SizedBox(height: 12),
              _buildCategoriesGrid(home),
            ],
          ),
        ),
        if (hasBannerData) ...[
          const SizedBox(height: 14),
          _buildBannerCarousel(banners),
        ],
        const SizedBox(height: 20),
        // Hot deals section
        Container(
          key: _hotDealsSectionKey,
          child: _buildHotDealsHeader(context),
        ),
        const SizedBox(height: 12),
        _buildRecentlyOrdered(browseItems),
        const SizedBox(height: 20),
        // Recommended section
        Container(
          color: const Color(0xFFFAF8FF),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Recommended for Your Salon',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 200,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  scrollDirection: Axis.horizontal,
                  itemCount: recommendedDisplayItems.length > 4
                      ? 4
                      : recommendedDisplayItems.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (_, i) {
                    final p = recommendedDisplayItems[i];
                    return _buildRecommendedCard(p);
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Most Bought Products section
        _buildSectionHeader('Most Bought Products', 'See all'),
        const SizedBox(height: 12),
        _buildMostBought(mostBoughtDisplayItems),
        const SizedBox(height: 20),
        // Popular Products grid
        _buildSectionHeader('Popular Products', 'See all'),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.58,
            ),
            itemCount: visiblePopularItems.length,
            itemBuilder: (_, i) {
              final product = visiblePopularItems[i];
              final productId = _baseProductId(
                (product['id'] ?? '').toString(),
              );
              return ProductCard(
                product: product,
                showHeartIcon: false,
                showBoughtEarlierBadge: _purchasedProductIds.contains(
                  productId,
                ),
                onAddToCart: _addToCart,
              );
            },
          ),
        ),
        if (popularDisplayItems.length > 8)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.center,
              child: OutlinedButton(
                onPressed: () {
                  setState(() {
                    _showAllPopularProducts = !_showAllPopularProducts;
                  });
                },
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFE1D8FF)),
                  foregroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                child: Text(
                  _showAllPopularProducts
                      ? 'Show less popular products'
                      : 'View all popular products',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        SizedBox(height: MediaQuery.of(context).padding.bottom + 120),
      ],
    );
  }

  List<Map<String, dynamic>> _productsForSection(
    List<Map<String, dynamic>> products,
    List<String> sectionAliases,
  ) {
    String normalize(String value) => value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');

    final normalizedAliases = sectionAliases.map(normalize).toSet();

    bool matchesPlacementFlag(Map<String, dynamic> p) {
      if ((normalizedAliases.contains('start_first_order') ||
              normalizedAliases.contains('hot_deals')) &&
          (p['showInStartFirstOrder'] == true || p['showInHotDeals'] == true)) {
        return true;
      }
      if ((normalizedAliases.contains('recommended_salon') ||
              normalizedAliases.contains('recommended')) &&
          (p['showInRecommendedSalon'] == true || p['isRecommended'] == true)) {
        return true;
      }
      if ((normalizedAliases.contains('most_bought') ||
              normalizedAliases.contains('most_bought_products') ||
              normalizedAliases.contains('bestseller')) &&
          p['showInMostBought'] == true) {
        return true;
      }
      if ((normalizedAliases.contains('popular_products') ||
              normalizedAliases.contains('popular')) &&
          (p['showInPopularProducts'] == true || p['isPopular'] == true)) {
        return true;
      }
      return false;
    }

    bool matches(Map<String, dynamic> p) {
      final homeSection = normalize(
        (p['homeSection'] ?? p['home_section'] ?? p['section'] ?? '')
            .toString(),
      );
      final tag = normalize((p['tag'] ?? '').toString());
      return normalizedAliases.contains(homeSection) ||
          normalizedAliases.contains(tag) ||
          matchesPlacementFlag(p);
    }

    return products.where(matches).toList();
  }

  List<Map<String, dynamic>> _sortProductsByRecency(
    List<Map<String, dynamic>> products,
  ) {
    DateTime parseDate(dynamic value) {
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      if (value is num) {
        return DateTime.fromMillisecondsSinceEpoch(value.toInt());
      }
      final parsed = DateTime.tryParse((value ?? '').toString().trim());
      return parsed ?? DateTime.fromMillisecondsSinceEpoch(0);
    }

    DateTime productRecency(Map<String, dynamic> product) {
      return parseDate(
        product['updatedAt'] ?? product['createdAt'] ?? product['publishedAt'],
      );
    }

    final sorted = List<Map<String, dynamic>>.from(products)
      ..sort((a, b) => productRecency(b).compareTo(productRecency(a)));
    return sorted;
  }

  bool _hasExplicitHomeSection(Map<String, dynamic> product) {
    final value =
        (product['homeSection'] ??
                product['home_section'] ??
                product['section'] ??
                '')
            .toString()
            .trim();
    return value.isNotEmpty;
  }

  String _productIdentity(Map<String, dynamic> product) {
    final rawId = (product['id'] ?? '').toString().trim();
    final baseId = _baseProductId(rawId);
    if (baseId.isNotEmpty) return 'id:$baseId';

    final name = (product['name'] ?? '').toString().trim().toLowerCase();
    final brand = (product['brand'] ?? '').toString().trim().toLowerCase();
    return 'nb:$brand::$name';
  }

  List<Map<String, dynamic>> _mergeUniqueProductLists(
    List<Map<String, dynamic>> primary,
    List<Map<String, dynamic>> secondary, {
    int? maxItems,
  }) {
    final merged = <Map<String, dynamic>>[];
    final seen = <String>{};

    void pushAll(List<Map<String, dynamic>> source) {
      for (final item in source) {
        if (maxItems != null && merged.length >= maxItems) return;
        final key = _productIdentity(item);
        if (seen.add(key)) {
          merged.add(item);
        }
      }
    }

    pushAll(primary);
    pushAll(secondary);
    return merged;
  }

  List<Map<String, dynamic>> _randomizeHotDealsForView(
    List<Map<String, dynamic>> products,
  ) {
    if (products.length <= 1) return products;
    final shuffled = List<Map<String, dynamic>>.from(products);
    shuffled.shuffle(Random(_hotDealsShuffleSeed));
    return shuffled;
  }

  List<Map<String, dynamic>> _randomizeRecommendationsForView(
    List<Map<String, dynamic>> products,
  ) {
    if (products.length <= 1) return products;
    final shuffled = List<Map<String, dynamic>>.from(products);
    shuffled.shuffle(Random(_recommendedShuffleSeed));
    return shuffled;
  }

  List<Map<String, dynamic>> _recommendedForNewUser(
    List<Map<String, dynamic>> products,
  ) {
    final sorted = List<Map<String, dynamic>>.from(products)
      ..sort((a, b) {
        final aScore =
            ((a['rating'] as num?) ?? 0) * 100 + ((a['reviews'] as num?) ?? 0);
        final bScore =
            ((b['rating'] as num?) ?? 0) * 100 + ((b['reviews'] as num?) ?? 0);
        return bScore.compareTo(aScore);
      });
    return sorted.take(8).toList();
  }

  Widget _buildHotDealsHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Hot Deals',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'Recommended for you',
                style: TextStyle(
                  color: AppColors.textHint,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProductListScreen()),
            ),
            child: Row(
              children: [
                Text(
                  'Shop now',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: 2),
                const Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: AppColors.primary,
                  size: 10,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, String? action) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (action != null)
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CategoriesScreen()),
              ),
              child: Text(
                action,
                style: const TextStyle(
                  color: AppColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCategoriesGrid(HomeProvider home) {
    final cats = home.categories;
    return SizedBox(
      height: 108,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: cats.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final cat = cats[i];
          final rawIconPath = cat['icon'] ?? cat['image'];
          final iconPath = rawIconPath == null ? null : rawIconPath.toString();
          final categoryName =
              (cat['name']?.toString().trim().isNotEmpty ?? false)
              ? cat['name'].toString()
              : 'Category';

          return SizedBox(
            width: 82,
            child: GestureDetector(
              onTap: () => _openCategory(categoryName),
              child: Column(
                children: [
                  Container(
                    height: 70,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x10A855F7),
                          blurRadius: 12,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Center(
                      child: iconPath == null || iconPath.isEmpty
                          ? const Icon(
                              Icons.category_outlined,
                              color: AppColors.textHint,
                              size: 32,
                            )
                          : iconPath.startsWith('assets/')
                          ? Image.asset(
                              iconPath,
                              width: 36,
                              height: 36,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => const Icon(
                                Icons.category_outlined,
                                color: AppColors.textHint,
                                size: 32,
                              ),
                            )
                          : CachedNetworkImage(
                              imageUrl: iconPath,
                              width: 36,
                              height: 36,
                              fit: BoxFit.contain,
                              fadeInDuration: Duration.zero,
                              fadeOutDuration: Duration.zero,
                              memCacheWidth: 108,
                              maxWidthDiskCache: 108,
                              errorWidget: (_, __, ___) => const Icon(
                                Icons.category_outlined,
                                color: AppColors.textHint,
                                size: 32,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    categoryName,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBannerCarousel(List<Map<String, dynamic>> banners) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: _bannerHeight,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: PageView.builder(
                controller: _bannerPageController,
                itemCount: banners.length,
                onPageChanged: (index) {
                  if (!mounted) return;
                  setState(() {
                    _currentBannerPage = index;
                  });
                  // Adjust timer based on current banner type
                  _setAutoSlideTimer(banners, index);
                },
                itemBuilder: (_, index) {
                  final banner = banners[index];
                  final mediaUrl = (banner['mediaUrl'] ?? banner['image'] ?? '')
                      .toString();
                  final mediaType = (banner['mediaType'] ?? '')
                      .toString()
                      .trim()
                      .toLowerCase();
                  final isVideo =
                      mediaType == 'video' ||
                      RegExp(
                        r'\.(mp4|mov|m4v|webm|ogv|m3u8)(\?|#|$)',
                        caseSensitive: false,
                      ).hasMatch(mediaUrl);
                  final title = (banner['title'] ?? '').toString();
                  final subtitle = (banner['subtitle'] ?? '').toString();

                  return Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x12000000),
                          blurRadius: 12,
                          offset: Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        isVideo
                            ? _BannerVideo(url: mediaUrl)
                            : AnimatedBuilder(
                                animation: _bannerImageZoomAnimation,
                                child: _buildBannerImage(mediaUrl),
                                builder: (_, child) => Transform.scale(
                                  scale: _bannerImageZoomAnimation.value,
                                  alignment: Alignment.center,
                                  child: child,
                                ),
                              ),
                        if (title.isNotEmpty || subtitle.isNotEmpty)
                          Positioned(
                            left: 12,
                            right: 12,
                            bottom: 12,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (title.isNotEmpty)
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      shadows: [
                                        Shadow(
                                          color: Color(0xAA000000),
                                          blurRadius: 6,
                                          offset: Offset(0, 1),
                                        ),
                                      ],
                                    ),
                                  ),
                                if (subtitle.isNotEmpty)
                                  Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      shadows: [
                                        Shadow(
                                          color: Color(0xAA000000),
                                          blurRadius: 5,
                                          offset: Offset(0, 1),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(banners.length.clamp(1, 8), (index) {
              final selected = index == _currentBannerPage;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: selected ? 20 : 7,
                height: 7,
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.primary
                      : AppColors.primary.withOpacity(0.30),
                  borderRadius: BorderRadius.circular(10),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildMostBought(List<Map<String, dynamic>> products) {
    // Sort by reviews count as a proxy for most bought
    final sorted = List<Map<String, dynamic>>.from(products)
      ..sort(
        (a, b) => ((b['reviews'] as num?) ?? 0).compareTo(
          (a['reviews'] as num?) ?? 0,
        ),
      );
    final top = sorted.take(6).toList();
    return SizedBox(
      height: 175,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: top.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final p = top[i];
          return GestureDetector(
            onTap: () => _openProductDetail(p),
            child: Container(
              width: 130,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x0A000000),
                    blurRadius: 10,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(14),
                        ),
                        child: _buildProductImage(
                          resolveListImage(p),
                          height: 100,
                          width: 130,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (p['name'] ?? '').toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '\u20B9${p['price']}',
                              style: const TextStyle(
                                color: AppColors.primary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            _buildSmallCartControl(p),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRecentlyOrdered(List<Map<String, dynamic>> products) {
    return SizedBox(
      height: 165,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: products.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final p = products[i];
          final productId = _baseProductId((p['id'] ?? '').toString());
          final showBoughtEarlier = _purchasedProductIds.contains(productId);
          final salePrice = _toDouble(p['price'] ?? p['salePrice']).round();
          final originalPrice = _toDouble(
            p['originalPrice'] ?? p['mrp'] ?? p['listPrice'],
          ).round();
          final hasVisiblePrice = salePrice > 0;
          final hasVisibleOriginal =
              hasVisiblePrice && originalPrice > salePrice;
          final discountPercent = _resolveDiscountPercent(p);
          final hasDiscount = discountPercent != null;
          return GestureDetector(
            onTap: () => _openProductDetail(p),
            child: SizedBox(
              width: 120,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      Container(
                        height: 110,
                        width: 120,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x0A000000),
                              blurRadius: 10,
                              offset: Offset(0, 3),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: _buildProductImage(
                            resolveListImage(p),
                            height: 110,
                            width: 120,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 6,
                        right: 6,
                        child: _buildSmallCartControl(p),
                      ),
                      if (showBoughtEarlier)
                        Positioned(
                          top: 6,
                          left: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.success,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'Bought earlier',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 7.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      if (hasDiscount)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF3B30),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '-$discountPercent%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    (p['brand'] ?? '').toString(),
                    style: const TextStyle(
                      color: AppColors.textHint,
                      fontSize: 10,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    (p['name'] ?? '').toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (hasVisiblePrice) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          '₹$salePrice',
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (hasVisibleOriginal) ...[
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '₹$originalPrice',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textHint,
                                fontSize: 9,
                                decoration: TextDecoration.lineThrough,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRecommendedCard(Map<String, dynamic> p) {
    return GestureDetector(
      onTap: () => _openProductDetail(p),
      child: Container(
        width: 230,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Color(0x12A855F7),
              blurRadius: 20,
              offset: Offset(0, 6),
            ),
            BoxShadow(
              color: Color(0x08000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
              child: Stack(
                children: [
                  Container(
                    height: 95,
                    width: double.infinity,
                    color: Colors.white,
                    child: _buildProductImage(
                      resolveListImage(p),
                      height: 95,
                      width: double.infinity,
                      fit: BoxFit.contain,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              (p['name'] ?? '').toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              (p['brand'] ?? '').toString(),
                              style: const TextStyle(
                                color: AppColors.textHint,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '\u20B9${p['price']}',
                            style: const TextStyle(
                              color: AppColors.primary,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            '\u20B9${p['originalPrice']}',
                            style: TextStyle(
                              color: AppColors.textHint,
                              fontSize: 10,
                              decoration: TextDecoration.lineThrough,
                              decorationColor: AppColors.textHint,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  _buildWideCartControl(p),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BannerVideo extends StatefulWidget {
  const _BannerVideo({required this.url});

  final String url;

  @override
  State<_BannerVideo> createState() => _BannerVideoState();
}

class _BannerVideoState extends State<_BannerVideo> {
  VideoPlayerController? _controller;
  Future<void>? _initFuture;

  @override
  void initState() {
    super.initState();
    _setupController();
  }

  @override
  void didUpdateWidget(covariant _BannerVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _disposeController();
      _setupController();
    }
  }

  String _normalizeVideoUrl(String raw) {
    final url = raw.trim();
    if (url.isEmpty) return '';

    // If already a full HTTP/HTTPS URL, return as-is
    if (url.startsWith('http://') || url.startsWith('https://')) {
      // Ensure Firebase Storage URLs have ?alt=media for proper streaming
      if (url.contains('firebasestorage.googleapis.com') &&
          !url.contains('alt=media')) {
        return '$url?alt=media';
      }
      return url;
    }

    // If gs:// format, convert to HTTPS with ?alt=media
    if (url.startsWith('gs://')) {
      final withoutScheme = url.substring(5);
      final slash = withoutScheme.indexOf('/');
      if (slash > 0 && slash < withoutScheme.length - 1) {
        final bucket = withoutScheme.substring(0, slash);
        final objectPath = withoutScheme.substring(slash + 1);
        return 'https://firebasestorage.googleapis.com/v0/b/$bucket/o/${Uri.encodeComponent(objectPath)}?alt=media';
      }
    }

    return url;
  }

  void _setupController() {
    final rawUrl = widget.url.trim();
    if (rawUrl.isEmpty) return;

    final normalizedUrl = _normalizeVideoUrl(rawUrl);
    if (normalizedUrl.isEmpty) return;

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(normalizedUrl),
    );
    _controller = controller;
    _initFuture = controller
        .initialize()
        .then((_) async {
          await controller.setLooping(true);
          await controller.setVolume(0);
          await controller.play();
          if (mounted) setState(() {});
        })
        .catchError((error) {});
  }

  Future<void> _disposeController() async {
    final c = _controller;
    _controller = null;
    _initFuture = null;
    if (c != null) {
      await c.dispose();
    }
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || _initFuture == null) {
      return Container(
        color: AppColors.surface,
        child: const Icon(Icons.videocam_off, color: AppColors.textHint),
      );
    }

    return FutureBuilder<void>(
      future: _initFuture,
      builder: (_, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            color: AppColors.surface,
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        if (snapshot.hasError) {
          return Container(
            color: AppColors.surface,
            child: const Center(
              child: Icon(
                Icons.error_outline,
                color: AppColors.textHint,
                size: 32,
              ),
            ),
          );
        }

        if (snapshot.connectionState != ConnectionState.done ||
            !_controller!.value.isInitialized) {
          return Container(
            color: AppColors.surface,
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _controller!.value.size.width,
              height: _controller!.value.size.height,
              child: VideoPlayer(_controller!),
            ),
          ),
        );
      },
    );
  }
}
