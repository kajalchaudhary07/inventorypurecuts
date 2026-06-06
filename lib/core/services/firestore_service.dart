import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'dart:io';
import 'package:purecuts/core/models/product_model.dart';
import 'package:purecuts/core/models/user_model.dart';
import 'package:purecuts/core/constants/feature_flags.dart';
import 'package:purecuts/core/services/performance_trace_service.dart';
import 'package:purecuts/features/products/detail/product_models.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  static const String _usersCollection = 'users';
  static const String _productsCollection = 'products';
  static const String _ordersCollection = 'orders';
  static const String _productSharesCollection = 'productShares';
  static const String _productReviewsCollection = 'productReviews';
  static const String _productSuggestionsCollection = 'productSuggestions';
  static const String _bannersCollection = 'banners';
  static const String _verificationRequestsCollection = 'verificationRequests';
  static const Duration _bannerCacheTtl = Duration(minutes: 10);
  static List<Map<String, dynamic>>? _bannerCache;
  static DateTime? _bannerCacheAt;
  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(
    region: 'us-central1',
  );

  List<Map<String, dynamic>> _cloneMapList(List<Map<String, dynamic>> source) {
    return source
        .map((row) => <String, dynamic>{...row})
        .toList(growable: false);
  }

  String _firstNonEmpty(List<dynamic> values) {
    for (final value in values) {
      final resolved = (value ?? '').toString().trim();
      if (resolved.isNotEmpty) return resolved;
    }
    return '';
  }

  int _clampLimit({
    required int value,
    required int fallback,
    required int max,
  }) {
    final safe = value <= 0 ? fallback : value;
    return safe > max ? max : safe;
  }

  Future<Map<String, dynamic>> getStoreAppSettings() async {
    try {
      final snap = await _db.collection('app_settings').doc('store').get();
      if (!snap.exists) return const <String, dynamic>{};
      final data = snap.data();
      if (data == null) return const <String, dynamic>{};
      return Map<String, dynamic>.from(data);
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  void _traceQuery(
    String operation,
    Stopwatch stopwatch, {
    Map<String, Object?> details = const {},
  }) {
    if (!FeatureFlags.enablePerfTelemetry || !kDebugMode) return;
    final payload = {'elapsedMs': stopwatch.elapsedMilliseconds, ...details};
    debugPrint('[FirestoreService][$operation] $payload');
  }

  bool _isPublishedProduct(Map<String, dynamic> data) {
    String normalize(dynamic value) {
      return (value ?? '').toString().trim().toLowerCase();
    }

    bool? boolLike(dynamic value) {
      if (value is bool) return value;
      if (value is num) return value != 0;
      final text = normalize(value);
      if (text.isEmpty) return null;
      if (text == 'true' || text == '1' || text == 'yes' || text == 'on') {
        return true;
      }
      if (text == 'false' || text == '0' || text == 'no' || text == 'off') {
        return false;
      }
      return null;
    }

    // Exclude products marked as inventory-only (not for the app)
    final isInventoryOnly = boolLike(data['isInventoryOnly']);
    if (isInventoryOnly == true) {
      return false;
    }

    final visibility = normalize(data['visibility']);
    final status = normalize(data['status']);
    final publishState = normalize(
      data['publishStatus'] ?? data['productStatus'] ?? data['state'],
    );
    final isPublishedFlag = boolLike(data['isPublished']);
    final isActiveFlag = boolLike(data['isActive']);
    final activeFlag = boolLike(data['active']);

    const positiveStates = {
      'publish',
      'published',
      'public',
      'active',
      'visible',
      'live',
    };

    // Dashboard product visibility is controlled primarily via visibility.
    // Honor it first to match admin behavior exactly.
    if (visibility.isNotEmpty) {
      if (visibility == 'draft') return false;
      if (positiveStates.contains(visibility)) return true;
    }

    if (isPublishedFlag != null) return isPublishedFlag;

    if (positiveStates.contains(status)) return true;
    if (positiveStates.contains(publishState)) return true;

    const negativeStates = {
      'draft',
      'hidden',
      'inactive',
      'archived',
      'private',
      'unpublished',
      'deleted',
      'trash',
    };

    if (negativeStates.contains(status) ||
        negativeStates.contains(publishState)) {
      return false;
    }

    // Treat explicit inactive flags as hidden only when no explicit publish
    // signal exists; this avoids suppressing records that are Published in
    // dashboard but carry legacy active fields.
    if (isActiveFlag == false || activeFlag == false) {
      return false;
    }

    // Default to visible for legacy docs missing explicit publish flags.
    return true;
  }

  static const int _defaultProductPageBatch = 24;

  Future<Uint8List> _compressImageForUpload(Uint8List bytes) async {
    if (bytes.isEmpty) return bytes;
    try {
      final compressed = await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: 1600,
        minHeight: 1600,
        quality: 78,
        format: CompressFormat.jpeg,
      );
      if (compressed.isNotEmpty && compressed.length < bytes.length) {
        return compressed;
      }
      return bytes;
    } catch (_) {
      return bytes;
    }
  }

  Future<
    ({
      List<ProductModel> products,
      DocumentSnapshot<Map<String, dynamic>>? lastDocument,
      bool hasMore,
    })
  >
  getProductsPage({
    int limit = _defaultProductPageBatch,
    DocumentSnapshot<Map<String, dynamic>>? startAfterDoc,
  }) async {
    return PerformanceTraceService.record('api_network_request_time', () async {
      final safeLimit = _clampLimit(
        value: limit,
        fallback: _defaultProductPageBatch,
        max: FeatureFlags.maxProductPageSize,
      );
      final sw = Stopwatch()..start();

      // Single Firestore query per call. The cursor always advances past every
      // raw document (published or not) so the outer loadData loop can paginate
      // without gaps. The previous inner-while approach corrupted the cursor
      // when breaking early due to safeLimit, causing products beyond the break
      // point to be silently skipped.
      Query<Map<String, dynamic>> query = _db
          .collection(_productsCollection)
          .orderBy(FieldPath.documentId)
          .limit(safeLimit);

      if (startAfterDoc != null) {
        query = query.startAfterDocument(startAfterDoc);
      }

      final snap = await query.get();
      final collected = <ProductModel>[];

      for (final doc in snap.docs) {
        if (!_isPublishedProduct(doc.data())) continue;
        try {
          collected.add(ProductModel.fromMap(doc.data(), doc.id));
        } catch (_) {
          // Skip malformed docs instead of aborting the whole page.
        }
      }

      // hasMore is true when the Firestore page was full – there may be more.
      final hasMore = snap.docs.length >= safeLimit;
      // Cursor = last raw doc so the next call correctly starts after it,
      // even if some docs in this page were filtered out as unpublished.
      final cursor = snap.docs.isEmpty ? startAfterDoc : snap.docs.last;

      _traceQuery(
        'getProductsPage',
        sw,
        details: {
          'requestedLimit': limit,
          'appliedLimit': safeLimit,
          'rawDocs': snap.docs.length,
          'returned': collected.length,
          'hasMore': hasMore,
        },
      );
      return (products: collected, lastDocument: cursor, hasMore: hasMore);
    });
  }

  Future<
    ({
      List<ProductModel> products,
      DocumentSnapshot<Map<String, dynamic>>? lastDocument,
      bool hasMore,
    })
  >
  getProductsPageFiltered({
    int limit = _defaultProductPageBatch,
    DocumentSnapshot<Map<String, dynamic>>? startAfterDoc,
    String? category,
    String? brand,
  }) async {
    final cleanCategory = (category ?? '').trim();
    final cleanBrand = (brand ?? '').trim();
    final safeLimit = _clampLimit(
      value: limit,
      fallback: _defaultProductPageBatch,
      max: FeatureFlags.maxProductPageSize,
    );
    final sw = Stopwatch()..start();

    // Single Firestore query per call – same fix as getProductsPage.
    // The inner-while loop caused cursor corruption when docs were filtered
    // client-side, silently skipping products beyond the safeLimit break.
    Query<Map<String, dynamic>> query = _db
        .collection(_productsCollection)
        .orderBy(FieldPath.documentId)
        .limit(safeLimit);

    if (cleanCategory.isNotEmpty) {
      query = query.where('category', isEqualTo: cleanCategory);
    }
    if (cleanBrand.isNotEmpty) {
      query = query.where('brand', isEqualTo: cleanBrand);
    }
    if (startAfterDoc != null) {
      query = query.startAfterDocument(startAfterDoc);
    }

    final snap = await query.get();
    final collected = <ProductModel>[];

    for (final doc in snap.docs) {
      if (!_isPublishedProduct(doc.data())) continue;
      try {
        collected.add(ProductModel.fromMap(doc.data(), doc.id));
      } catch (_) {
        // Skip malformed docs instead of aborting the whole page.
      }
    }

    final hasMore = snap.docs.length >= safeLimit;
    final cursor = snap.docs.isEmpty ? startAfterDoc : snap.docs.last;

    _traceQuery(
      'getProductsPageFiltered',
      sw,
      details: {
        'requestedLimit': limit,
        'appliedLimit': safeLimit,
        'category': cleanCategory,
        'brand': cleanBrand,
        'rawDocs': snap.docs.length,
        'returned': collected.length,
        'hasMore': hasMore,
      },
    );
    return (products: collected, lastDocument: cursor, hasMore: hasMore);
  }

  Future<List<ProductModel>> getLatestPublishedProducts({
    int limit = _defaultProductPageBatch,
  }) async {
    final safeLimit = _clampLimit(
      value: limit,
      fallback: _defaultProductPageBatch,
      max: FeatureFlags.maxProductPageSize,
    );
    final sw = Stopwatch()..start();

    try {
      final snap = await _db
          .collection(_productsCollection)
          .orderBy('createdAt', descending: true)
          .limit(safeLimit)
          .get();

      final collected = <ProductModel>[];
      for (final doc in snap.docs) {
        if (!_isPublishedProduct(doc.data())) continue;
        try {
          collected.add(ProductModel.fromMap(doc.data(), doc.id));
        } catch (_) {
          // Skip malformed docs instead of aborting the whole page.
        }
      }

      _traceQuery(
        'getLatestPublishedProducts',
        sw,
        details: {
          'requestedLimit': limit,
          'appliedLimit': safeLimit,
          'rawDocs': snap.docs.length,
          'returned': collected.length,
          'fallback': false,
        },
      );
      return collected;
    } catch (_) {
      final page = await getProductsPage(limit: safeLimit);
      _traceQuery(
        'getLatestPublishedProducts',
        sw,
        details: {
          'requestedLimit': limit,
          'appliedLimit': safeLimit,
          'returned': page.products.length,
          'fallback': true,
        },
      );
      return page.products;
    }
  }

  String _baseProductId(String value) {
    final id = value.trim();
    if (id.isEmpty) return '';
    final sep = id.indexOf('::');
    if (sep <= 0) return id;
    return id.substring(0, sep);
  }

  String _orderDocIdFromPaymentTxn(String txnId) {
    final cleaned = txnId.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return 'payu_${cleaned.isEmpty ? 'unknown' : cleaned}';
  }

  String _editOrderDocId(String sourceKey) {
    final cleaned = sourceKey.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return 'edit_${cleaned.isEmpty ? 'unknown' : cleaned}';
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _queryOrdersByUid({
    required String uid,
    int maxOrders = 200,
  }) async {
    final safeLimit = _clampLimit(
      value: maxOrders,
      fallback: 200,
      max: FeatureFlags.maxOrdersFetch,
    );
    try {
      final ordered = await _db
          .collection(_ordersCollection)
          .where('uid', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(safeLimit)
          .get();
      return ordered.docs;
    } catch (_) {
      final plain = await _db
          .collection(_ordersCollection)
          .where('uid', isEqualTo: uid)
          .limit(safeLimit)
          .get();
      return plain.docs;
    }
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  _queryLegacyOrdersByUid({required String uid, int maxOrders = 200}) async {
    final safeLimit = _clampLimit(
      value: maxOrders,
      fallback: 200,
      max: FeatureFlags.maxOrdersFetch,
    );
    final snapshots = await Future.wait([
      _db
          .collection(_ordersCollection)
          .where('userId', isEqualTo: uid)
          .limit(safeLimit)
          .get(),
      _db
          .collection(_ordersCollection)
          .where('customerId', isEqualTo: uid)
          .limit(safeLimit)
          .get(),
    ]);

    final merged = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final snap in snapshots) {
      for (final doc in snap.docs) {
        merged[doc.id] = doc;
      }
    }
    return merged.values.toList(growable: false);
  }

  // ── Create user profile (only if it doesn't already exist) ───────────────

  Future<void> createUserProfile(UserModel user) async {
    final ref = _db.collection('users').doc(user.uid);
    final doc = await ref.get();
    if (!doc.exists) {
      await ref.set(user.toMap());
    }
  }

  // ── Overwrite / update user profile ───────────────────────────────────────

  Future<void> setUserProfile(UserModel user) async {
    await _db.collection('users').doc(user.uid).set(user.toMap());
  }

  Future<void> saveUserProfileWithPendingApproval({
    required UserModel user,
    required Map<String, dynamic> registrationData,
  }) async {
    final uid = user.uid.trim();
    if (uid.isEmpty) {
      throw Exception('User UID is required');
    }

    final userRef = _db.collection(_usersCollection).doc(uid);
    final userSnap = await userRef.get();
    const accessApproved = false;
    const isVerified = false;
    const verificationStatus = 'pending';

    final payload = {
      ...user.toMap(),
      'verificationStatus': verificationStatus,
      'accessApproved': accessApproved,
      'isVerified': isVerified,
      'verificationUpdatedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      if (!accessApproved) 'verifiedAt': null,
      if (verificationStatus != 'rejected') 'rejectedAt': null,
    };

    if (userSnap.exists) {
      payload.remove('createdAt');
    }

    await userRef.set(payload, SetOptions(merge: true));

    final gstNumber = _firstNonEmpty([
      registrationData['gstNumber'],
      registrationData['gst'],
      user.gst,
    ]);

    final udyamNumber = _firstNonEmpty([
      registrationData['udyamNumber'],
      registrationData['udyam'],
      registrationData['msmeNumber'],
      user.udyamNumber,
    ]);

    String sanitizeAlphaNum(String value) =>
        value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();

    final gstSanitized = sanitizeAlphaNum(gstNumber);
    final udyamSanitized = sanitizeAlphaNum(udyamNumber);

    if (gstSanitized.isEmpty && udyamSanitized.isEmpty) {
      throw Exception('Please provide at least GST Number or Udyam Number');
    }

    if (gstSanitized.isNotEmpty && gstSanitized.length != 15) {
      throw Exception('GST Number must be exactly 15 characters');
    }

    if (udyamSanitized.isNotEmpty && udyamSanitized.length != 16) {
      throw Exception('Udyam Number must be exactly 16 characters');
    }

    await _db.collection(_verificationRequestsCollection).add({
      'userId': uid,
      'uid': uid,
      'createdBy': uid,
      'email': user.email,
      'phone': user.phone,
      'ownerName': _firstNonEmpty([
        registrationData['ownerName'],
        user.ownerName,
        user.name,
      ]),
      'salonName': _firstNonEmpty([
        registrationData['salonName'],
        user.salonName,
      ]),
      'state': _firstNonEmpty([registrationData['state'], user.state]),
      'pincode': _firstNonEmpty([registrationData['pincode'], user.pincode]),
      if (gstSanitized.isNotEmpty) 'gstNumber': gstSanitized,
      if (udyamSanitized.isNotEmpty) 'udyamNumber': udyamSanitized,
      'status': 'pending',
      'approved': false,
      'rejected': false,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<({bool exists, bool isApproved, String verificationStatus})>
  getUserAccessState(String uid) async {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty) {
      return (exists: false, isApproved: false, verificationStatus: 'missing');
    }

    final snap = await _db.collection(_usersCollection).doc(cleanUid).get();
    if (!snap.exists) {
      return (exists: false, isApproved: false, verificationStatus: 'missing');
    }

    final data = snap.data() ?? const <String, dynamic>{};
    final statusRaw = (data['verificationStatus'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final approved =
        data['accessApproved'] == true ||
        data['isVerified'] == true ||
        statusRaw == 'approved';

    final status = statusRaw.isNotEmpty
        ? statusRaw
        : (approved ? 'approved' : 'pending');

    bool hasNonEmpty(dynamic value) =>
        (value ?? '').toString().trim().isNotEmpty;

    // Guard against partial/legacy user docs: if user is not approved and core
    // onboarding fields are missing, treat as profile-not-created so the app
    // routes to ProfileSetup instead of PendingApproval.
    final hasCoreProfile =
        hasNonEmpty(data['ownerName']) &&
        hasNonEmpty(data['salonName']) &&
        hasNonEmpty(data['state']) &&
        hasNonEmpty(data['pincode']);

    final treatAsExistingProfile = approved || hasCoreProfile;

    return (
      exists: treatAsExistingProfile,
      isApproved: approved,
      verificationStatus: status,
    );
  }

  // ── Update a single field in user profile ────────────────────────────────

  Future<void> updateUserField(String uid, String field, dynamic value) async {
    await _db.collection('users').doc(uid).update({field: value});
  }

  Future<void> updateUserFields(String uid, Map<String, dynamic> data) async {
    if (uid.trim().isEmpty || data.isEmpty) return;
    await _db.collection('users').doc(uid).set(data, SetOptions(merge: true));
  }

  // ── Fetch user profile ────────────────────────────────────────────────────

  Future<UserModel?> getUserProfile(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (doc.exists) return UserModel.fromMap(doc.data()!, uid);
    return null;
  }

  /// Update user profile in Firestore
  Future<bool> updateUserProfile({
    required String uid,
    required Map<String, dynamic> data,
  }) async {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty || data.isEmpty) {
      debugPrint(
        '[FirestoreService] updateUserProfile: invalid params (uid=${cleanUid.isEmpty ? 'empty' : 'ok'}, data=${data.isEmpty ? 'empty' : 'ok'})',
      );
      return false;
    }

    try {
      final updateData = {...data, 'updatedAt': FieldValue.serverTimestamp()};
      await _db
          .collection(_usersCollection)
          .doc(cleanUid)
          .set(updateData, SetOptions(merge: true));
      debugPrint(
        '[FirestoreService] updateUserProfile: success for UID=$cleanUid',
      );
      return true;
    } catch (e, st) {
      debugPrint(
        '[FirestoreService] updateUserProfile failed for UID=$cleanUid: $e\n$st',
      );
      return false;
    }
  }

  // ── Fetch all products ────────────────────────────────────────────────────

  Future<List<ProductModel>> getProducts() async {
    final snap = await _db.collection('products').get();
    return snap.docs
        .where((doc) => _isPublishedProduct(doc.data()))
        .map((doc) => ProductModel.fromMap(doc.data(), doc.id))
        .toList();
  }

  Future<String> createProduct(Map<String, dynamic> data) async {
    final ref = await _db.collection('products').add({
      ...data,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  Future<String> createVariant(
    String productId,
    Map<String, dynamic> data,
  ) async {
    final ref = await _db
        .collection('products')
        .doc(productId)
        .collection('variants')
        .add({...data, 'createdAt': FieldValue.serverTimestamp()});
    return ref.id;
  }

  Future<List<ProductVariant>> getProductVariants(String productId) async {
    return PerformanceTraceService.record('api_network_request_time', () async {
      final snap = await _db
          .collection('products')
          .doc(productId)
          .collection('variants')
          .orderBy('createdAt')
          .get();

      return snap.docs
          .map((doc) => ProductVariant.fromMap(doc.id, doc.data()))
          .toList();
    });
  }

  // ── Fetch products by category ────────────────────────────────────────────

  Future<List<ProductModel>> getProductsByCategory(String category) async {
    final snap = await _db
        .collection('products')
        .where('category', isEqualTo: category)
        .get();
    return snap.docs
        .where((doc) => _isPublishedProduct(doc.data()))
        .map((doc) => ProductModel.fromMap(doc.data(), doc.id))
        .toList();
  }

  int _toOrderIndex(dynamic value) {
    if (value is num) return value.toInt();
    final parsed = int.tryParse((value ?? '').toString());
    return parsed ?? 9999;
  }

  DateTime _toDateSafe(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    final parsed = DateTime.tryParse((value ?? '').toString());
    return parsed ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<String> _resolveMediaUrl(dynamic value) async {
    final raw = (value ?? '').toString().trim();
    if (raw.isEmpty) return '';

    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (raw.startsWith('assets/')) return raw;

    try {
      if (raw.startsWith('gs://')) {
        return await _storage.refFromURL(raw).getDownloadURL();
      }

      final normalized = raw.startsWith('/') ? raw.substring(1) : raw;
      return await _storage.ref(normalized).getDownloadURL();
    } catch (_) {
      return raw;
    }
  }

  bool _isVideoLike(dynamic value) {
    final raw = (value ?? '').toString().trim().toLowerCase();
    if (raw.isEmpty) return false;
    if (raw.startsWith('data:video/')) return true;
    return RegExp(r'\.(mp4|mov|m4v|webm|ogv|m3u8)(\?|#|$)').hasMatch(raw);
  }

  String _inferBannerMediaType(Map<String, dynamic> raw) {
    final explicit = (raw['mediaType'] ?? '').toString().trim().toLowerCase();
    if (explicit == 'video' || explicit == 'image') return explicit;

    final source =
        raw['mediaUrl'] ?? raw['video'] ?? raw['image'] ?? raw['imageUrl'];
    return _isVideoLike(source) ? 'video' : 'image';
  }

  Future<List<Map<String, dynamic>>> getBanners({
    bool forceRefresh = false,
  }) async {
    final now = DateTime.now();
    final cacheAge = _bannerCacheAt == null
        ? null
        : now.difference(_bannerCacheAt!);
    final hasFreshCache =
        !forceRefresh &&
        _bannerCache != null &&
        cacheAge != null &&
        cacheAge <= _bannerCacheTtl;

    if (hasFreshCache) {
      return _cloneMapList(_bannerCache!);
    }

    final rows = <Map<String, dynamic>>[];

    try {
      final ordered = await _db
          .collection(_bannersCollection)
          .orderBy('createdAt', descending: true)
          .get();
      rows.addAll(ordered.docs.map((doc) => {'id': doc.id, ...doc.data()}));
    } catch (_) {
      final fallback = await _db.collection(_bannersCollection).get();
      rows.addAll(fallback.docs.map((doc) => {'id': doc.id, ...doc.data()}));
    }

    final normalized = <Map<String, dynamic>>[];

    for (final raw in rows) {
      final mediaType = _inferBannerMediaType(raw);
      final mediaUrl = await _resolveMediaUrl(
        raw['mediaUrl'] ??
            raw['video'] ??
            raw['image'] ??
            raw['imageUrl'] ??
            raw['bannerImage'],
      );

      final banner = {
        ...raw,
        'id': (raw['id'] ?? '').toString(),
        'title': (raw['title'] ?? '').toString().trim(),
        'subtitle': (raw['subtitle'] ?? '').toString().trim(),
        'mediaType': mediaType,
        'mediaUrl': mediaUrl,
        'image': mediaUrl,
        'link': (raw['link'] ?? '/products').toString().trim(),
        'active': raw['active'] != false,
        'order': _toOrderIndex(raw['order']),
        'createdAt': _toDateSafe(raw['createdAt']),
        'updatedAt': _toDateSafe(raw['updatedAt']),
      };

      if ((banner['mediaUrl'] as String).isNotEmpty &&
          banner['active'] == true) {
        normalized.add(banner);
      }
    }

    normalized.sort((a, b) {
      final orderCmp = (a['order'] as int).compareTo((b['order'] as int));
      if (orderCmp != 0) return orderCmp;

      final bUpdated = (b['updatedAt'] as DateTime);
      final aUpdated = (a['updatedAt'] as DateTime);
      return bUpdated.compareTo(aUpdated);
    });

    _bannerCache = _cloneMapList(normalized);
    _bannerCacheAt = now;

    return _cloneMapList(normalized);
  }

  // ── Fetch categories ──────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getCategories() async {
    try {
      final snap = await _db.collection('categories').orderBy('order').get();
      if (snap.docs.isEmpty) return [];
      return snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
    } catch (_) {
      final snap = await _db.collection('categories').get();
      if (snap.docs.isEmpty) return [];
      final rows = snap.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .toList(growable: false);
      rows.sort(
        (a, b) =>
            _toOrderIndex(a['order']).compareTo(_toOrderIndex(b['order'])),
      );
      return rows;
    }
  }

  Future<List<Map<String, dynamic>>> getSubCategories() async {
    final snap = await _db.collection('subCategories').get();
    if (snap.docs.isEmpty) return [];
    final rows = snap.docs
        .map((doc) => {'id': doc.id, ...doc.data()})
        .toList(growable: false);
    rows.sort((a, b) {
      final catCmp = (a['parentCategory'] ?? '')
          .toString()
          .toLowerCase()
          .compareTo((b['parentCategory'] ?? '').toString().toLowerCase());
      if (catCmp != 0) return catCmp;
      return (a['name'] ?? '').toString().toLowerCase().compareTo(
        (b['name'] ?? '').toString().toLowerCase(),
      );
    });
    return rows;
  }

  Future<List<Map<String, dynamic>>> getSubSubCategories() async {
    final snap = await _db.collection('subSubCategories').get();
    if (snap.docs.isEmpty) return [];
    final rows = snap.docs
        .map((doc) => {'id': doc.id, ...doc.data()})
        .toList(growable: false);
    rows.sort((a, b) {
      final catCmp = (a['parentCategory'] ?? '')
          .toString()
          .toLowerCase()
          .compareTo((b['parentCategory'] ?? '').toString().toLowerCase());
      if (catCmp != 0) return catCmp;
      final subCmp = (a['parentSubCategory'] ?? '')
          .toString()
          .toLowerCase()
          .compareTo((b['parentSubCategory'] ?? '').toString().toLowerCase());
      if (subCmp != 0) return subCmp;
      return (a['name'] ?? '').toString().toLowerCase().compareTo(
        (b['name'] ?? '').toString().toLowerCase(),
      );
    });
    return rows;
  }

  Future<List<Map<String, dynamic>>> getBrands() async {
    final snap = await _db.collection('brands').get();
    if (snap.docs.isEmpty) return [];
    final brands = snap.docs
        .map((doc) => {'id': doc.id, ...doc.data()})
        .toList();
    brands.sort(
      (a, b) => (a['name'] ?? '').toString().toLowerCase().compareTo(
        (b['name'] ?? '').toString().toLowerCase(),
      ),
    );
    return brands;
  }

  Future<bool> isProductFavorited({
    required String uid,
    required String productId,
  }) async {
    if (uid.trim().isEmpty || productId.trim().isEmpty) return false;

    try {
      final userDoc = await _db.collection(_usersCollection).doc(uid).get();
      final data = userDoc.data() ?? const <String, dynamic>{};
      final list =
          (data['favoriteProductIds'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[];
      return list.contains(productId);
    } catch (_) {
      return false;
    }
  }

  Future<void> setProductFavorited({
    required String uid,
    required String productId,
    required bool isFavorited,
    Map<String, dynamic>? productData,
  }) async {
    if (uid.trim().isEmpty || productId.trim().isEmpty) return;

    await _db.collection(_usersCollection).doc(uid).set({
      'favoriteProductIds': isFavorited
          ? FieldValue.arrayUnion([productId])
          : FieldValue.arrayRemove([productId]),
      'favoriteProductMeta.$productId': isFavorited
          ? {
              ...?productData,
              'productId': productId,
              'updatedAt': FieldValue.serverTimestamp(),
            }
          : FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<List<Map<String, dynamic>>> getUserFavoritedProducts({
    required String uid,
  }) async {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty) return const [];

    final userDoc = await _db.collection(_usersCollection).doc(cleanUid).get();
    final userData = userDoc.data() ?? const <String, dynamic>{};

    final ids =
        (userData['favoriteProductIds'] as List?)
            ?.map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList() ??
        const <String>[];
    if (ids.isEmpty) return const [];

    final favoriteSet = ids.toSet();
    final products = <Map<String, dynamic>>[];

    for (var i = 0; i < ids.length; i += 10) {
      final end = (i + 10 < ids.length) ? i + 10 : ids.length;
      final chunk = ids.sublist(i, end);
      final snap = await _db
          .collection(_productsCollection)
          .where(FieldPath.documentId, whereIn: chunk)
          .get();

      for (final doc in snap.docs) {
        final data = doc.data();
        products.add({'id': doc.id, ...data});
      }
    }

    products.retainWhere(
      (p) => favoriteSet.contains((p['id'] ?? '').toString().trim()),
    );

    products.sort((a, b) {
      final ai = ids.indexOf((a['id'] ?? '').toString());
      final bi = ids.indexOf((b['id'] ?? '').toString());
      if (ai < 0 && bi < 0) return 0;
      if (ai < 0) return 1;
      if (bi < 0) return -1;
      return ai.compareTo(bi);
    });

    return products;
  }

  Future<void> recordProductShare({
    required String productId,
    required String uid,
    String? channel,
    Map<String, dynamic>? meta,
  }) async {
    if (productId.trim().isEmpty) return;

    final normalizedUid = uid.trim();

    if (normalizedUid.isNotEmpty) {
      await _db.collection(_usersCollection).doc(normalizedUid).set({
        'sharedProductIds': FieldValue.arrayUnion([productId]),
        'lastSharedProduct': {
          'productId': productId,
          'channel': channel ?? 'system_share_sheet',
          'meta': meta ?? {},
          'updatedAt': FieldValue.serverTimestamp(),
        },
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    try {
      await _db.collection(_productSharesCollection).add({
        'productId': productId,
        'uid': normalizedUid.isEmpty ? 'anonymous' : normalizedUid,
        'channel': channel ?? 'system_share_sheet',
        'meta': meta ?? {},
        'createdAt': FieldValue.serverTimestamp(),
      });

      await _db.collection(_productsCollection).doc(productId).set({
        'sharedCount': FieldValue.increment(1),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      // Best-effort analytics for restricted rules; ignore failures.
    }
  }

  dynamic _toCallableSafeValue(dynamic value) {
    if (value == null || value is bool || value is num || value is String) {
      return value;
    }

    if (value is Timestamp) {
      return value.toDate().toIso8601String();
    }

    if (value is DateTime) {
      return value.toIso8601String();
    }

    if (value is Iterable) {
      return value.map(_toCallableSafeValue).toList(growable: false);
    }

    if (value is Map) {
      final out = <String, dynamic>{};
      value.forEach((key, val) {
        out[key.toString()] = _toCallableSafeValue(val);
      });
      return out;
    }

    return value.toString();
  }

  Future<String?> _createCodOrderViaCallable({
    required String uid,
    required List<Map<String, dynamic>> items,
    required int total,
    Map<String, dynamic>? deliveryAddress,
    Map<String, dynamic>? contactDetails,
    String? paymentMethod,
    Map<String, dynamic>? billDetails,
    Map<String, dynamic>? editMeta,
    Map<String, dynamic>? userProfile,
  }) async {
    final callable = _functions.httpsCallable('createCodOrder');

    final compactProfile = {
      'name': (userProfile?['name'] ?? '').toString(),
      'ownerName': (userProfile?['ownerName'] ?? '').toString(),
      'email': (userProfile?['email'] ?? '').toString(),
      'phone': (userProfile?['phone'] ?? '').toString(),
      'mobile': (userProfile?['mobile'] ?? '').toString(),
      'pincode': (userProfile?['pincode'] ?? '').toString(),
      'country': (userProfile?['country'] ?? '').toString(),
    };

    Map<String, dynamic> payload() => {
      'uid': uid,
      'items': _toCallableSafeValue(items),
      'total': total,
      'deliveryAddress': _toCallableSafeValue(
        deliveryAddress ?? const <String, dynamic>{},
      ),
      'contactDetails': _toCallableSafeValue(
        contactDetails ?? const <String, dynamic>{},
      ),
      'paymentMethod': (paymentMethod ?? '').toString().trim().isEmpty
          ? 'Cash on Delivery'
          : paymentMethod,
      'billDetails': _toCallableSafeValue(
        billDetails ?? const <String, dynamic>{},
      ),
      'editMeta': _toCallableSafeValue(editMeta ?? const <String, dynamic>{}),
      'userProfile': _toCallableSafeValue(compactProfile),
    };

    Future<String?> invoke() async {
      final response = await callable.call(payload());
      final data = response.data;
      if (data is! Map) return null;
      final map = data.map((k, v) => MapEntry(k.toString(), v));
      final orderRef = _firstNonEmpty([
        map['orderRef'],
        map['orderId'],
        map['orderNumber'],
      ]);
      return orderRef.isEmpty ? null : orderRef;
    }

    try {
      return await invoke();
    } on FirebaseFunctionsException catch (e) {
      final code = e.code.toLowerCase();
      if (code == 'unauthenticated' || code == 'permission-denied') {
        await _auth.currentUser?.getIdToken(true);
        return await invoke();
      }
      debugPrint(
        '[FirestoreService] createCodOrder callable failed: code=${e.code}, message=${e.message}, details=${e.details}',
      );
      rethrow;
    } catch (e, st) {
      debugPrint(
        '[FirestoreService] createCodOrder callable unexpected failure: $e\n$st',
      );
      rethrow;
    }
  }

  Future<String?> registerUserPurchase({
    required String uid,
    required List<Map<String, dynamic>> items,
    required int total,
    Map<String, dynamic>? deliveryAddress,
    Map<String, dynamic>? contactDetails,
    String? paymentMethod,
    String? paymentTxnId,
    Map<String, dynamic>? billDetails,
    Map<String, dynamic>? editMeta,
    String? orderRefOverride,
    Map<String, dynamic>? userProfile,
  }) async {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty || items.isEmpty) return null;

    final productIds = items
        .map((e) => _baseProductId((e['id'] ?? '').toString()))
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);

    if (productIds.isEmpty) return null;

    final cleanPaymentTxnId = (paymentTxnId ?? '').trim();

    if (cleanPaymentTxnId.isEmpty) {
      try {
        return await _createCodOrderViaCallable(
          uid: cleanUid,
          items: items,
          total: total,
          deliveryAddress: deliveryAddress,
          contactDetails: contactDetails,
          paymentMethod: paymentMethod,
          billDetails: billDetails,
          editMeta: editMeta,
          userProfile: userProfile,
        );
      } on FirebaseFunctionsException catch (e) {
        final msg =
            'COD order save failed (functions:${e.code}) ${e.message ?? ''}'
                .trim();
        throw StateError(msg);
      }
    }

    if (cleanPaymentTxnId.isNotEmpty) {
      try {
        final existingByTxn = await _db
            .collection(_ordersCollection)
            .where('paymentTxnId', isEqualTo: cleanPaymentTxnId)
            .limit(1)
            .get();
        if (existingByTxn.docs.isNotEmpty) {
          final existingData = existingByTxn.docs.first.data();
          return _firstNonEmpty([
            existingData['orderRef'],
            existingData['orderId'],
            existingData['orderNumber'],
          ]);
        }
      } catch (_) {
        // Continue with normal flow if lookup query fails.
      }
    }

    DocumentReference<Map<String, dynamic>> orderDoc;
    String orderRef;
    final hasExplicitOrderRef = (orderRefOverride ?? '').trim().isNotEmpty;
    orderDoc = _db
        .collection(_ordersCollection)
        .doc(_orderDocIdFromPaymentTxn(cleanPaymentTxnId));
    orderRef = hasExplicitOrderRef
        ? orderRefOverride!.trim()
        : generateOrderRef(entropy: orderDoc.id.substring(0, 6));

    final userData = userProfile ?? const <String, dynamic>{};
    final authUser = _auth.currentUser;

    final customerName =
        (userData['name'] ??
                userData['ownerName'] ??
                authUser?.displayName ??
                contactDetails?['receiverName'] ??
                '')
            .toString()
            .trim();
    final customerEmail = (userData['email'] ?? authUser?.email ?? '')
        .toString()
        .trim();
    final customerPhone =
        (userData['phone'] ?? userData['mobile'] ?? authUser?.phoneNumber ?? '')
            .toString()
            .trim();

    final normalizedDeliveryAddress = {
      ...?deliveryAddress,
      'line1': (deliveryAddress?['line1'] ?? '').toString().trim(),
      'line2': (deliveryAddress?['line2'] ?? '').toString().trim(),
      'landmark': (deliveryAddress?['landmark'] ?? '').toString().trim(),
      'city': (deliveryAddress?['city'] ?? '').toString().trim(),
      'state': (deliveryAddress?['state'] ?? '').toString().trim(),
      'pincode':
          (deliveryAddress?['pincode'] ??
                  deliveryAddress?['postalCode'] ??
                  userData['pincode'] ??
                  '')
              .toString()
              .trim(),
      'country': (deliveryAddress?['country'] ?? userData['country'] ?? 'India')
          .toString()
          .trim(),
      'mapLink': (deliveryAddress?['mapLink'] ?? '').toString().trim(),
    };

    final normalizedContactDetails = {
      ...?contactDetails,
      'receiverName': (contactDetails?['receiverName'] ?? customerName)
          .toString()
          .trim(),
      'phone': (contactDetails?['phone'] ?? customerPhone).toString().trim(),
    };

    final normalizedEditMeta = editMeta is Map
        ? {
            'isEditOrder': editMeta?['isEditOrder'] == true,
            'sourceOrderDocumentId': (editMeta?['sourceOrderDocumentId'] ?? '')
                .toString()
                .trim(),
            'sourceOrderId': (editMeta?['sourceOrderId'] ?? '')
                .toString()
                .trim(),
            'sourceOrderRef': (editMeta?['sourceOrderRef'] ?? '')
                .toString()
                .trim(),
            'windowHours':
                int.tryParse((editMeta?['windowHours'] ?? '0').toString()) ?? 0,
            'lockedQuantities': editMeta?['lockedQuantities'] is Map
                ? Map<String, dynamic>.from(editMeta?['lockedQuantities'])
                : <String, dynamic>{},
            'originalCreatedAt': (editMeta?['originalCreatedAt'] ?? '')
                .toString()
                .trim(),
            'originalTotalAmount':
                int.tryParse(
                  (editMeta?['originalTotalAmount'] ?? 0).toString(),
                ) ??
                0,
            'originalItemCount':
                int.tryParse(
                  (editMeta?['originalItemCount'] ?? 0).toString(),
                ) ??
                0,
            'originalPaymentMethod': (editMeta?['originalPaymentMethod'] ?? '')
                .toString()
                .trim(),
          }
        : null;

    final sourceEditOrderRef = _normalizeOrderRef(
      (normalizedEditMeta?['sourceOrderRef'] ?? '').toString(),
    );
    final sourceEditOrderDocId =
        (normalizedEditMeta?['sourceOrderDocumentId'] ??
                normalizedEditMeta?['sourceOrderId'] ??
                '')
            .toString()
            .trim();
    final isEditOrder =
        normalizedEditMeta != null &&
        normalizedEditMeta['isEditOrder'] == true &&
        sourceEditOrderRef.isNotEmpty;

    if (isEditOrder && sourceEditOrderDocId.isNotEmpty) {
      orderDoc = _db
          .collection(_ordersCollection)
          .doc(_editOrderDocId(sourceEditOrderDocId));
    }

    orderRef = hasExplicitOrderRef
        ? orderRefOverride!.trim()
        : (isEditOrder
              ? sourceEditOrderRef
              : generateOrderRef(entropy: orderDoc.id.substring(0, 6)));

    final normalizedDeliveryDetails = {
      'deliveryAddress': normalizedDeliveryAddress,
      'contactDetails': normalizedContactDetails,
      'deliveryPlaced': true,
      'lastOrderRef': orderRef,
    };

    final addressLine1 = (normalizedDeliveryAddress['line1'] ?? '')
        .toString()
        .trim();
    final addressLine2 = (normalizedDeliveryAddress['line2'] ?? '')
        .toString()
        .trim();
    final addressCity = (normalizedDeliveryAddress['city'] ?? '')
        .toString()
        .trim();
    final addressState = (normalizedDeliveryAddress['state'] ?? '')
        .toString()
        .trim();
    final addressPincode = (normalizedDeliveryAddress['pincode'] ?? '')
        .toString()
        .trim();

    final addressSummary = [
      addressLine1,
      addressLine2,
      addressCity,
      addressState,
      addressPincode,
    ].where((e) => e.isNotEmpty).join(', ');

    var totalItems = 0;
    final normalizedItems = items
        .asMap()
        .entries
        .map((entry) {
          final index = entry.key;
          final item = entry.value;
          final productId = _baseProductId((item['id'] ?? '').toString());
          final quantity = (item['quantity'] ?? item['qty'] ?? 1) is num
              ? (item['quantity'] ?? item['qty'] ?? 1) as num
              : num.tryParse(
                      (item['quantity'] ?? item['qty'] ?? 1).toString(),
                    ) ??
                    1;
          totalItems += quantity.toInt();

          return {
            ...item,
            'id': productId.isEmpty ? (item['id'] ?? '') : productId,
            'productId': productId,
            'quantity': quantity,
            'orderId': orderRef,
            'orderItemId':
                '$orderRef-I${(index + 1).toString().padLeft(2, '0')}',
          };
        })
        .toList(growable: false);

    final payload = {
      'orderId': orderRef,
      'orderRef': orderRef,
      'orderNumber': orderRef,
      'uid': cleanUid,
      'userId': cleanUid,
      'customerId': cleanUid,
      'customerName': customerName,
      'customerEmail': customerEmail,
      'customerPhone': (normalizedContactDetails['phone'] ?? customerPhone)
          .toString(),
      'phone': (normalizedContactDetails['phone'] ?? customerPhone).toString(),
      'deliveryAddress': normalizedDeliveryAddress,
      'address': addressSummary.isNotEmpty
          ? addressSummary
          : (userData['address'] ?? '').toString(),
      'contactDetails': normalizedContactDetails,
      'paymentMethod': (paymentMethod ?? '').toString().trim(),
      'paymentTxnId': cleanPaymentTxnId,
      'billDetails': {...?billDetails},
      'items': normalizedItems,
      'productIds': productIds,
      'itemCount': normalizedItems.length,
      'itemsCount': normalizedItems.length,
      'totalItems': totalItems,
      'total': total,
      'amount': total,
      'totalAmount': total,
      'grandTotal': total,
      'deliveryPlaced': true,
      'status': isEditOrder ? 'edited' : 'placed',
      'orderStatus': isEditOrder ? 'edited' : 'placed',
      'paymentStatus': cleanPaymentTxnId.isEmpty ? 'pending' : 'paid',
      if (normalizedEditMeta != null) 'editMeta': normalizedEditMeta,
      if (normalizedEditMeta != null)
        'isEditOrder': normalizedEditMeta['isEditOrder'] == true,
      if (normalizedEditMeta != null)
        'originalOrderDocumentId': normalizedEditMeta['sourceOrderDocumentId'],
      if (normalizedEditMeta != null)
        'originalOrderId': normalizedEditMeta['sourceOrderId'],
      if (normalizedEditMeta != null)
        'originalOrderRef': normalizedEditMeta['sourceOrderRef'],
      if (normalizedEditMeta != null)
        'editWindowHours': normalizedEditMeta['windowHours'],
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    var persistedOrderRef = orderRef;
    if (cleanPaymentTxnId.isNotEmpty) {
      await _db.runTransaction((tx) async {
        final existingSnap = await tx.get(orderDoc);
        if (existingSnap.exists && !isEditOrder) {
          final existing = existingSnap.data() ?? const <String, dynamic>{};
          persistedOrderRef = _firstNonEmpty([
            existing['orderRef'],
            existing['orderId'],
            existing['orderNumber'],
            orderRef,
          ]);
          return;
        }

        tx.set(orderDoc, payload, SetOptions(merge: isEditOrder));
      });
    } else {
      await orderDoc.set(payload);
    }

    final sourceOrderDocumentId =
        (normalizedEditMeta?['sourceOrderDocumentId'] ?? '').toString().trim();
    if (sourceOrderDocumentId.isNotEmpty &&
        sourceOrderDocumentId != orderDoc.id) {
      await _db.collection(_ordersCollection).doc(sourceOrderDocumentId).set({
        'status': 'edited',
        'orderStatus': 'edited',
        'editedAt': FieldValue.serverTimestamp(),
        'editedByOrderId': persistedOrderRef,
        'editedByOrderDocumentId': orderDoc.id,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    unawaited(
      _db
          .collection(_usersCollection)
          .doc(cleanUid)
          .set({
            'purchasedProductIds': FieldValue.arrayUnion(productIds),
            'deliveryAddressDetails': normalizedDeliveryAddress,
            'contactDetails': normalizedContactDetails,
            'deliveryDetails': {
              ...normalizedDeliveryDetails,
              'lastOrderRef': persistedOrderRef,
              'updatedAt': FieldValue.serverTimestamp(),
            },
            'deliveryPlaced': true,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true))
          .catchError((error, stackTrace) {
            debugPrint(
              '[FirestoreService] registerUserPurchase post-write user update failed for UID=$cleanUid: $error',
            );
          }),
    );

    return persistedOrderRef;
  }

  String generateOrderRef({DateTime? now, String? entropy}) {
    final when = now ?? DateTime.now();
    final ymd =
        '${when.year}${when.month.toString().padLeft(2, '0')}${when.day.toString().padLeft(2, '0')}';
    final source = (entropy ?? when.microsecondsSinceEpoch.toString())
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
        .toUpperCase();
    final suffix = source.isEmpty
        ? '000000'
        : source.padRight(6, '0').substring(0, 6);
    return 'PC-$ymd-$suffix';
  }

  String _normalizeOrderRef(String value) {
    final clean = value.trim();
    if (clean.isEmpty) return '';
    return clean.startsWith('#') ? clean.substring(1).trim() : clean;
  }

  /// Fetch user orders from Firestore
  Future<
    ({
      List<Map<String, dynamic>> orders,
      DocumentSnapshot<Map<String, dynamic>>? lastDocument,
      bool hasMore,
      bool usedLegacyFallback,
    })
  >
  getUserOrdersPage({
    required String uid,
    int limit = 20,
    DocumentSnapshot<Map<String, dynamic>>? startAfterDoc,
  }) async {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty) {
      return (
        orders: const <Map<String, dynamic>>[],
        lastDocument: null,
        hasMore: false,
        usedLegacyFallback: false,
      );
    }

    final safeLimit = _clampLimit(
      value: limit,
      fallback: 20,
      max: FeatureFlags.maxOrdersPageSize,
    );
    final sw = Stopwatch()..start();

    Query<Map<String, dynamic>> canonicalQuery = _db
        .collection(_ordersCollection)
        .where('uid', isEqualTo: cleanUid)
        .orderBy('createdAt', descending: true)
        .limit(safeLimit);

    if (startAfterDoc != null) {
      canonicalQuery = canonicalQuery.startAfterDocument(startAfterDoc);
    }

    try {
      final canonicalSnap = await canonicalQuery.get();
      if (canonicalSnap.docs.isNotEmpty || startAfterDoc != null) {
        final orders = canonicalSnap.docs
            .map((doc) => {'id': doc.id, ...doc.data()})
            .toList();
        final hasMore = canonicalSnap.docs.length >= safeLimit;
        final lastDoc = canonicalSnap.docs.isNotEmpty
            ? canonicalSnap.docs.last
            : startAfterDoc;

        _traceQuery(
          'getUserOrdersPage',
          sw,
          details: {
            'uid': cleanUid,
            'requestedLimit': limit,
            'appliedLimit': safeLimit,
            'returned': orders.length,
            'hasMore': hasMore,
            'legacyFallback': false,
          },
        );
        return (
          orders: orders,
          lastDocument: lastDoc,
          hasMore: hasMore,
          usedLegacyFallback: false,
        );
      }

      final legacyDocs = await _queryLegacyOrdersByUid(
        uid: cleanUid,
        maxOrders: safeLimit,
      );

      DateTime toDate(dynamic value) {
        if (value is Timestamp) return value.toDate();
        if (value is DateTime) return value;
        if (value is num) {
          return DateTime.fromMillisecondsSinceEpoch(value.toInt());
        }
        return DateTime.fromMillisecondsSinceEpoch(0);
      }

      final merged = <String, Map<String, dynamic>>{};
      for (final doc in legacyDocs) {
        final data = {'id': doc.id, ...doc.data()};
        final key = (data['orderId'] ?? data['orderRef'] ?? doc.id).toString();
        merged[key] = data;
      }

      final rows = merged.values.toList(growable: false)
        ..sort(
          (a, b) => toDate(b['createdAt']).compareTo(toDate(a['createdAt'])),
        );

      _traceQuery(
        'getUserOrdersPage',
        sw,
        details: {
          'uid': cleanUid,
          'requestedLimit': limit,
          'appliedLimit': safeLimit,
          'returned': rows.length,
          'hasMore': false,
          'legacyFallback': true,
        },
      );
      return (
        orders: rows,
        lastDocument: null,
        hasMore: false,
        usedLegacyFallback: true,
      );
    } catch (_) {
      final fallbackQuery = _db
          .collection(_ordersCollection)
          .where('uid', isEqualTo: cleanUid)
          .limit(safeLimit);
      final fallbackSnap = await fallbackQuery.get();
      final orders = fallbackSnap.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .toList();
      final hasMore = fallbackSnap.docs.length >= safeLimit;
      final lastDoc = fallbackSnap.docs.isNotEmpty
          ? fallbackSnap.docs.last
          : null;

      _traceQuery(
        'getUserOrdersPage',
        sw,
        details: {
          'uid': cleanUid,
          'requestedLimit': limit,
          'appliedLimit': safeLimit,
          'returned': orders.length,
          'hasMore': hasMore,
          'legacyFallback': false,
          'queryFallback': true,
        },
      );
      return (
        orders: orders,
        lastDocument: lastDoc,
        hasMore: hasMore,
        usedLegacyFallback: false,
      );
    }
  }

  /// Fetch user orders from Firestore
  Future<List<Map<String, dynamic>>> getUserOrders({
    required String uid,
    int maxOrders = 200,
  }) async {
    try {
      final page = await getUserOrdersPage(
        uid: uid,
        limit: maxOrders,
        startAfterDoc: null,
      );
      return page.orders;
    } catch (e, st) {
      final cleanUid = uid.trim();
      debugPrint(
        '[FirestoreService] getUserOrders failed for UID=$cleanUid: $e\n$st',
      );
      return const [];
    }
  }

  Future<bool> cancelOrderByUser({
    required String uid,
    required String orderRef,
    String orderDocumentId = '',
    String reason = 'Cancelled by user',
  }) async {
    final cleanUid = uid.trim();
    final cleanOrderRef = orderRef.trim();
    final cleanOrderDocumentId = orderDocumentId.trim();
    if (cleanUid.isEmpty ||
        (cleanOrderRef.isEmpty && cleanOrderDocumentId.isEmpty)) {
      return false;
    }

    Future<QuerySnapshot<Map<String, dynamic>>> _lookup({
      required String ownerField,
      required String refField,
      required String refValue,
    }) {
      return _db
          .collection(_ordersCollection)
          .where(ownerField, isEqualTo: cleanUid)
          .where(refField, isEqualTo: refValue)
          .limit(1)
          .get();
    }

    DocumentReference<Map<String, dynamic>>? targetRef;

    try {
      if (cleanOrderDocumentId.isNotEmpty) {
        final directRef = _db
            .collection(_ordersCollection)
            .doc(cleanOrderDocumentId);
        final directSnap = await directRef.get();
        if (directSnap.exists) {
          final data = directSnap.data() ?? const <String, dynamic>{};
          final owner = _firstNonEmpty([
            data['uid'],
            data['userId'],
            data['customerId'],
          ]);
          if (owner == cleanUid || owner.isEmpty) {
            targetRef = directRef;
          }
        }
      }

      final ownerFields = ['uid', 'userId', 'customerId'];
      final refFields = ['orderId', 'orderRef', 'orderNumber'];
      final refVariants = <String>{};
      if (cleanOrderRef.isNotEmpty) {
        refVariants.add(cleanOrderRef);
        if (cleanOrderRef.startsWith('#')) {
          refVariants.add(cleanOrderRef.replaceFirst('#', ''));
        } else {
          refVariants.add('#$cleanOrderRef');
        }
      }

      if (targetRef == null && refVariants.isNotEmpty) {
        for (final ownerField in ownerFields) {
          for (final refField in refFields) {
            for (final refValue in refVariants) {
              final snap = await _lookup(
                ownerField: ownerField,
                refField: refField,
                refValue: refValue,
              );
              if (snap.docs.isNotEmpty) {
                targetRef = snap.docs.first.reference;
                break;
              }
            }
            if (targetRef != null) break;
          }
          if (targetRef != null) break;
        }
      }

      if (targetRef == null) {
        return false;
      }

      await targetRef.update({
        'status': 'cancelled',
        'orderStatus': 'cancelled',
        'cancelledBy': 'user',
        'cancelledByUid': cleanUid,
        'cancellationSource': 'app_user',
        'cancellationReason': reason.trim().isEmpty
            ? 'Cancelled by user'
            : reason.trim(),
        'cancelledAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getUserPurchasedProducts({
    required String uid,
  }) async {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty) return const [];

    final userDoc = await _db.collection(_usersCollection).doc(cleanUid).get();
    final data = userDoc.data() ?? const <String, dynamic>{};
    final profileUpdatedAt = data['deliveryDetails'] is Map
        ? (data['deliveryDetails'] as Map)['updatedAt']
        : data['updatedAt'];
    final purchasedIds =
        (data['purchasedProductIds'] as List?)
            ?.map((e) => _baseProductId(e.toString()))
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList(growable: false) ??
        const <String>[];

    if (purchasedIds.isEmpty) {
      try {
        final orderDocs = await _queryOrdersByUid(uid: cleanUid);
        final docs = orderDocs.isNotEmpty
            ? orderDocs
            : await _queryLegacyOrdersByUid(uid: cleanUid);

        DateTime toDate(dynamic value) {
          if (value is Timestamp) return value.toDate();
          if (value is DateTime) return value;
          if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
          return DateTime.fromMillisecondsSinceEpoch(0);
        }

        final mergedOrderDocs = <Map<String, dynamic>>[];
        final seenOrderKeys = <String>{};
        for (final doc in docs) {
          final data = doc.data();
          final key = (data['orderId'] ?? data['orderRef'] ?? doc.id)
              .toString();
          if (seenOrderKeys.add(key)) {
            mergedOrderDocs.add(data);
          }
        }

        mergedOrderDocs.sort(
          (a, b) => toDate(b['createdAt']).compareTo(toDate(a['createdAt'])),
        );

        final fallback = <String, Map<String, dynamic>>{};
        for (final order in mergedOrderDocs) {
          final createdAt = toDate(order['createdAt']);
          final orderId = (order['orderId'] ?? order['orderRef'] ?? '')
              .toString();
          final orderStatus =
              (order['status'] ?? order['orderStatus'] ?? 'placed').toString();
          final paymentMethod = (order['paymentMethod'] ?? '').toString();
          final items = (order['items'] as List?) ?? const [];

          for (final item in items) {
            if (item is! Map) continue;
            final normalized = item.map(
              (key, value) => MapEntry(key.toString(), value),
            );
            final productId = _baseProductId(
              (normalized['id'] ?? '').toString(),
            );
            if (productId.isEmpty || fallback.containsKey(productId)) {
              continue;
            }
            fallback[productId] = {
              ...normalized,
              'id': productId,
              'lastOrderedAt': createdAt,
              'lastOrderId': orderId,
              'lastOrderStatus': orderStatus,
              'lastPaymentMethod': paymentMethod,
            };
          }
        }
        return fallback.values.toList(growable: false);
      } catch (_) {
        return const [];
      }
    }

    final productsById = <String, Map<String, dynamic>>{};
    const chunkSize = 10;

    for (var i = 0; i < purchasedIds.length; i += chunkSize) {
      final chunk = purchasedIds.sublist(
        i,
        i + chunkSize > purchasedIds.length
            ? purchasedIds.length
            : i + chunkSize,
      );
      final snap = await _db
          .collection(_productsCollection)
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      for (final doc in snap.docs) {
        productsById[doc.id] = ProductModel.fromMap(
          doc.data(),
          doc.id,
        ).toProductMap();
      }
    }

    try {
      final canonical = await _queryOrdersByUid(uid: cleanUid);
      final orderDocs = canonical.isNotEmpty
          ? canonical
          : await _queryLegacyOrdersByUid(uid: cleanUid);

      final latestMetaByProduct = <String, Map<String, dynamic>>{};
      DateTime toDate(dynamic value) {
        if (value is Timestamp) return value.toDate();
        if (value is DateTime) return value;
        if (value is int) {
          return DateTime.fromMillisecondsSinceEpoch(value);
        }
        return DateTime.fromMillisecondsSinceEpoch(0);
      }

      for (final doc in orderDocs) {
        final data = doc.data();
        final createdAt = toDate(data['createdAt']);
        final orderId = (data['orderId'] ?? data['orderRef'] ?? doc.id)
            .toString();
        final status = (data['status'] ?? data['orderStatus'] ?? 'placed')
            .toString();
        final paymentMethod = (data['paymentMethod'] ?? '').toString();
        final items = (data['items'] as List?) ?? const [];

        for (final item in items) {
          if (item is! Map) continue;
          final normalized = item.map((k, v) => MapEntry(k.toString(), v));
          final pid = _baseProductId(
            (normalized['id'] ?? normalized['productId'] ?? '').toString(),
          );
          if (pid.isEmpty) continue;

          final existing = latestMetaByProduct[pid];
          if (existing == null ||
              toDate(existing['lastOrderedAt']).isBefore(createdAt)) {
            latestMetaByProduct[pid] = {
              'lastOrderedAt': createdAt,
              'lastOrderId': orderId,
              'lastOrderStatus': status,
              'lastPaymentMethod': paymentMethod,
            };
          }
        }
      }

      for (final id in productsById.keys.toList(growable: false)) {
        final meta = latestMetaByProduct[id];
        if (meta == null) continue;
        productsById[id] = {...productsById[id]!, ...meta};
      }
    } catch (_) {
      // Best-effort metadata enrichment only.
    }

    final orderedProducts = purchasedIds
        .map((id) => productsById[id])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);

    for (var i = 0; i < orderedProducts.length; i++) {
      final product = orderedProducts[i];
      if (product['lastOrderedAt'] != null) continue;
      orderedProducts[i] = {...product, 'lastOrderedAt': profileUpdatedAt};
    }

    if (orderedProducts.isNotEmpty) return orderedProducts;

    return const [];
  }

  Future<bool> hasUserPurchasedProduct({
    required String uid,
    required String productId,
  }) async {
    final cleanUid = uid.trim();
    final cleanProductId = _baseProductId(productId);
    if (cleanUid.isEmpty || cleanProductId.isEmpty) return false;

    try {
      final userDoc = await _db
          .collection(_usersCollection)
          .doc(cleanUid)
          .get();
      final data = userDoc.data() ?? const <String, dynamic>{};
      final purchased =
          (data['purchasedProductIds'] as List?)
              ?.map((e) => _baseProductId(e.toString()))
              .toList() ??
          const <String>[];
      if (purchased.contains(cleanProductId)) return true;

      final orders = await _db
          .collection(_ordersCollection)
          .where('uid', isEqualTo: cleanUid)
          .where('productIds', arrayContains: cleanProductId)
          .limit(1)
          .get();
      if (orders.docs.isNotEmpty) return true;

      final legacyUserIdOrders = await _db
          .collection(_ordersCollection)
          .where('userId', isEqualTo: cleanUid)
          .where('productIds', arrayContains: cleanProductId)
          .limit(1)
          .get();
      if (legacyUserIdOrders.docs.isNotEmpty) return true;

      final legacyCustomerOrders = await _db
          .collection(_ordersCollection)
          .where('customerId', isEqualTo: cleanUid)
          .where('productIds', arrayContains: cleanProductId)
          .limit(1)
          .get();
      return legacyCustomerOrders.docs.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> uploadReviewMedia({
    required String uid,
    required String productId,
    required List<XFile> files,
    ValueChanged<double>? onProgress,
  }) async {
    if (files.isEmpty) return const [];
    final cleanUid = uid.trim();
    final cleanProductId = _baseProductId(productId);
    if (cleanUid.isEmpty || cleanProductId.isEmpty) return const [];

    final uploaded = <String>[];
    final failed = <String>[];
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      try {
        final lower = file.name.toLowerCase();
        final isVideo =
            lower.endsWith('.mp4') ||
            lower.endsWith('.mov') ||
            lower.endsWith('.avi') ||
            lower.endsWith('.mkv');
        String contentType;
        if (isVideo) {
          contentType = 'video/mp4';
        } else {
          contentType = 'image/jpeg';
        }

        final ext = file.name.contains('.')
            ? file.name.substring(file.name.lastIndexOf('.'))
            : '';
        final ref = _storage.ref(
          'reviews/$cleanProductId/$cleanUid/${DateTime.now().millisecondsSinceEpoch}$ext',
        );
        UploadTask uploadTask;
        if (isVideo && !kIsWeb && file.path.isNotEmpty) {
          uploadTask = ref.putFile(
            File(file.path),
            SettableMetadata(
              contentType: contentType,
              cacheControl: 'public,max-age=31536000,immutable',
            ),
          );
        } else {
          final rawBytes = await file.readAsBytes();
          final uploadBytes = isVideo
              ? rawBytes
              : await _compressImageForUpload(rawBytes);
          uploadTask = ref.putData(
            uploadBytes,
            SettableMetadata(
              contentType: contentType,
              cacheControl: 'public,max-age=31536000,immutable',
            ),
          );
        }

        final sub = uploadTask.snapshotEvents.listen((snapshot) {
          final total = snapshot.totalBytes;
          final fileProgress = total > 0
              ? (snapshot.bytesTransferred / total).clamp(0.0, 1.0)
              : 0.0;
          final overall = ((index + fileProgress) / files.length).clamp(
            0.0,
            1.0,
          );
          onProgress?.call(overall);
        });

        final task = await uploadTask;
        await sub.cancel();
        onProgress?.call(((index + 1) / files.length).clamp(0.0, 1.0));
        final url = await task.ref.getDownloadURL();
        uploaded.add(url);
      } catch (e) {
        failed.add('${file.name}: $e');
      }
    }

    if (files.isNotEmpty && uploaded.isEmpty) {
      throw StateError(
        'Could not upload media. Please check storage permissions/rules and try again.',
      );
    }
    if (failed.isNotEmpty) {
      throw StateError(
        'Uploaded ${uploaded.length}/${files.length} files. Some files failed to upload.',
      );
    }

    onProgress?.call(1.0);

    return uploaded;
  }

  Future<Map<String, String>> uploadProductSuggestionImage({
    required String uid,
    required XFile file,
    ValueChanged<double>? onProgress,
  }) async {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty) {
      throw StateError(
        'User uid is required to upload product suggestion media.',
      );
    }

    final lower = file.name.toLowerCase();
    final isImage =
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif');

    if (!isImage) {
      throw StateError(
        'Only image files are supported for product suggestions.',
      );
    }

    final ext = file.name.contains('.')
        ? file.name.substring(file.name.lastIndexOf('.'))
        : '.jpg';
    final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final storagePath =
        'productSuggestions/$cleanUid/${DateTime.now().millisecondsSinceEpoch}_$safeName';

    final rawBytes = await file.readAsBytes();
    final uploadBytes = await _compressImageForUpload(rawBytes);
    final task = _storage
        .ref(storagePath)
        .putData(
          uploadBytes,
          SettableMetadata(
            contentType:
                'image/${ext.replaceFirst('.', '').toLowerCase() == 'png' ? 'png' : 'jpeg'}',
            cacheControl: 'public,max-age=31536000,immutable',
          ),
        );

    final sub = task.snapshotEvents.listen((snapshot) {
      final total = snapshot.totalBytes;
      final progress = total > 0
          ? (snapshot.bytesTransferred / total).clamp(0.0, 1.0)
          : 0.0;
      onProgress?.call(progress);
    });

    final snap = await task;
    await sub.cancel();
    onProgress?.call(1.0);

    return {
      'imageUrl': await snap.ref.getDownloadURL(),
      'imagePath': storagePath,
    };
  }

  Future<String> createProductSuggestion({
    required String uid,
    required String text,
    required String orderRef,
    required String orderId,
    String imageUrl = '',
    String imagePath = '',
    String status = 'submitted',
    Map<String, dynamic>? meta,
  }) async {
    final cleanUid = uid.trim();
    final cleanText = text.trim();
    final cleanOrderRef = orderRef.trim();
    final cleanOrderId = orderId.trim();

    if (cleanUid.isEmpty ||
        cleanText.isEmpty ||
        cleanOrderRef.isEmpty ||
        cleanOrderId.isEmpty) {
      throw StateError('Missing product suggestion fields.');
    }

    final payload = {
      'uid': cleanUid,
      'text': cleanText,
      'imageUrl': imageUrl.trim(),
      'imagePath': imagePath.trim(),
      'orderRef': cleanOrderRef,
      'orderId': cleanOrderId,
      'status': status.trim().isEmpty ? 'submitted' : status.trim(),
      'adminNotes': '',
      if (meta != null && meta.isNotEmpty) 'meta': meta,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    final ref = await _db
        .collection(_productSuggestionsCollection)
        .add(payload);
    return ref.id;
  }

  Future<List<Map<String, dynamic>>> getProductSuggestionsPage({
    int limit = 25,
    DocumentSnapshot<Map<String, dynamic>>? startAfterDoc,
  }) async {
    final safeLimit = _clampLimit(value: limit, fallback: 25, max: 100);
    Query<Map<String, dynamic>> query = _db
        .collection(_productSuggestionsCollection)
        .orderBy('createdAt', descending: true)
        .limit(safeLimit);

    if (startAfterDoc != null) {
      query = query.startAfterDocument(startAfterDoc);
    }

    try {
      final snap = await query.get();
      return snap.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .toList(growable: false);
    } catch (_) {
      final snap = await _db.collection(_productSuggestionsCollection).get();
      final rows = snap.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .toList(growable: false);
      rows.sort(
        (a, b) =>
            _toDateSafe(b['createdAt']).compareTo(_toDateSafe(a['createdAt'])),
      );
      return rows.length > safeLimit ? rows.sublist(0, safeLimit) : rows;
    }
  }

  Future<Map<String, dynamic>?> getProductSuggestionById(String id) async {
    final cleanId = id.trim();
    if (cleanId.isEmpty) return null;
    final snap = await _db
        .collection(_productSuggestionsCollection)
        .doc(cleanId)
        .get();
    if (!snap.exists) return null;
    return {'id': snap.id, ...snap.data()!};
  }

  Future<void> updateProductSuggestion(
    String id,
    Map<String, dynamic> data,
  ) async {
    final cleanId = id.trim();
    if (cleanId.isEmpty || data.isEmpty) return;
    await _db.collection(_productSuggestionsCollection).doc(cleanId).set({
      ...data,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> deleteProductSuggestion(String id) async {
    final cleanId = id.trim();
    if (cleanId.isEmpty) return;
    await _db.collection(_productSuggestionsCollection).doc(cleanId).delete();
  }

  Future<void> submitProductReview({
    required String uid,
    required String productId,
    required String userName,
    required double rating,
    required String comment,
    List<String> mediaUrls = const [],
    String? userEmail,
    String? userPhone,
    String? productName,
    String? productImage,
  }) async {
    final cleanUid = uid.trim();
    final cleanProductId = _baseProductId(productId);
    if (cleanUid.isEmpty || cleanProductId.isEmpty) return;

    final canReview = await hasUserPurchasedProduct(
      uid: cleanUid,
      productId: cleanProductId,
    );
    if (!canReview) {
      throw StateError('Only users who bought this product can review it.');
    }

    final reviewRef = _db
        .collection(_productsCollection)
        .doc(cleanProductId)
        .collection('reviews')
        .doc(cleanUid);

    final existingReview = await reviewRef.get();
    final reviewMirrorId = '${cleanProductId}_$cleanUid';
    final authUser = _auth.currentUser;
    final userDoc = await _db.collection(_usersCollection).doc(cleanUid).get();
    final userData = userDoc.data() ?? const <String, dynamic>{};
    final resolvedEmail = (userEmail ?? '').trim().isNotEmpty
        ? userEmail!.trim()
        : (authUser?.email ?? userData['email'] ?? '').toString().trim();
    final resolvedPhone = (userPhone ?? '').trim().isNotEmpty
        ? userPhone!.trim()
        : (authUser?.phoneNumber ?? userData['phone'] ?? '').toString().trim();

    final payload = {
      'uid': cleanUid,
      'userId': cleanUid,
      'productId': cleanProductId,
      'productName': (productName ?? '').trim(),
      'productImage': (productImage ?? '').trim(),
      'userName': userName.trim().isEmpty ? 'Verified Buyer' : userName.trim(),
      'userEmail': resolvedEmail,
      'userPhone': resolvedPhone,
      'rating': rating,
      'comment': comment.trim(),
      'mediaUrls': mediaUrls,
      'status': 'pending',
      'approved': false,
      'visibility': 'author_only',
      'updatedAt': FieldValue.serverTimestamp(),
      if (!existingReview.exists) 'createdAt': FieldValue.serverTimestamp(),
    };

    await reviewRef.set(payload, SetOptions(merge: true));
    await _db
        .collection(_productReviewsCollection)
        .doc(reviewMirrorId)
        .set(payload, SetOptions(merge: true));
  }

  Future<void> deleteProductReview({
    required String uid,
    required String productId,
  }) async {
    final cleanUid = uid.trim();
    final cleanProductId = _baseProductId(productId);
    if (cleanUid.isEmpty || cleanProductId.isEmpty) return;

    final reviewMirrorId = '${cleanProductId}_$cleanUid';

    await _db
        .collection(_productsCollection)
        .doc(cleanProductId)
        .collection('reviews')
        .doc(cleanUid)
        .delete();

    try {
      await _db
          .collection(_productReviewsCollection)
          .doc(reviewMirrorId)
          .delete();
    } catch (_) {
      // Keep delete resilient if mirror doc is missing.
    }
  }
}
