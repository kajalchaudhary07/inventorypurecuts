import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:purecuts/core/constants/app_constants.dart';
import 'package:purecuts/core/constants/feature_flags.dart';
import 'package:purecuts/core/models/product_model.dart';
import 'package:purecuts/core/services/firestore_service.dart';
import 'package:purecuts/core/services/performance_trace_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HomeProvider extends ChangeNotifier {
  static const int _homeInitialProductLimit = 24;
  static const int _homeFullCatalogPageSize = 180;
  static const int _homeMaxProductPool = 20000;
  static const String _homeCacheKey = 'purecuts_home_bootstrap_cache_v1';
  static const Set<String> _hiddenCategoryNames = {
    'nail',
    'beard',
    'wax',
    'offers',
  };

  // Lazy initialization: tests that only exercise in-memory filtering
  // (filteredProducts / seedForTest) never call _service, so Firebase.instance
  // is never triggered in a unit-test environment.
  late final FirestoreService _service = FirestoreService();
  static Future<SharedPreferences>? _prefsFuture;

  List<ProductModel> _products = [];
  List<Map<String, dynamic>> _banners = [];
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _subCategories = [];
  List<Map<String, dynamic>> _subSubCategories = [];
  List<Map<String, dynamic>> _brands = [];
  bool _loading = false;
  bool _taxonomyLoading = false;
  String? _error;
  bool _hasLoadedOnce = false;
  bool _hasAttemptedFullCatalogLoad = false;

  // Shared in-flight futures – callers await these instead of firing duplicate
  // Firestore fetches while a load is already in flight.
  Completer<void>? _loadDataCompleter;
  Completer<void>? _visibilityCatalogCompleter;

  /// True only after the full paginated catalog has been loaded and all
  /// products have been merged into [productMaps]. Screens that filter or
  /// search the catalog must wait for this before rendering results.
  bool _fullCatalogReady = false;

  static Future<SharedPreferences> _prefs() {
    return _prefsFuture ??= SharedPreferences.getInstance();
  }

  dynamic _jsonSafe(dynamic value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is DateTime) return value.toIso8601String();
    if (value is List) {
      return value.map(_jsonSafe).toList(growable: false);
    }
    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(key.toString(), _jsonSafe(item)),
      );
    }
    return value.toString();
  }

  List<Map<String, dynamic>> _safeMapList(dynamic value) {
    if (value is! List) return const <Map<String, dynamic>>[];
    return value
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  List<ProductModel> _decodeProducts(dynamic value) {
    if (value is! List) return const <ProductModel>[];
    final products = <ProductModel>[];
    for (final row in value.whereType<Map>()) {
      final map = Map<String, dynamic>.from(row);
      final id = (map['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      try {
        products.add(ProductModel.fromMap(map, id));
      } catch (_) {
        // Skip malformed cached rows.
      }
    }
    return products;
  }

  Future<bool> _hydrateStartupCache() async {
    if (!FeatureFlags.enableHomeStartupCache) return false;
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_homeCacheKey);
      if (raw == null || raw.trim().isEmpty) return false;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;
      final payload = Map<String, dynamic>.from(decoded);

      final cachedProducts = _decodeProducts(payload['products']);
      final cachedBanners = _safeMapList(payload['banners']);
      final cachedCategories = _safeMapList(payload['categories']);
      final cachedSubCategories = _safeMapList(payload['subCategories']);
      final cachedSubSubCategories = _safeMapList(payload['subSubCategories']);
      final cachedBrands = _safeMapList(payload['brands']);

      // Startup hydration is considered successful only when product data exists.
      // Categories can still be shown from AppConstants, but an empty product cache
      // should not short-circuit network loading.
      if (cachedProducts.isEmpty) return false;

      _products = cachedProducts;
      _banners = cachedBanners;
      if (cachedCategories.isNotEmpty) _categories = cachedCategories;
      if (cachedSubCategories.isNotEmpty) _subCategories = cachedSubCategories;
      if (cachedSubSubCategories.isNotEmpty) {
        _subSubCategories = cachedSubSubCategories;
      }
      if (cachedBrands.isNotEmpty) _brands = cachedBrands;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _persistStartupCache() async {
    if (!FeatureFlags.enableHomeStartupCache) return;
    if (_products.isEmpty) return;
    try {
      final prefs = await _prefs();
      final payload = {
        'savedAt': DateTime.now().toIso8601String(),
        'products': _products.map((p) => _jsonSafe(p.toProductMap())).toList(),
        'banners': _jsonSafe(_banners),
        'categories': _jsonSafe(_categories),
        'subCategories': _jsonSafe(_subCategories),
        'subSubCategories': _jsonSafe(_subSubCategories),
        'brands': _jsonSafe(_brands),
      };
      await prefs.setString(_homeCacheKey, jsonEncode(payload));
    } catch (_) {
      // Best-effort cache write only.
    }
  }

  Future<List<Map<String, dynamic>>> _timedListFetch(
    Future<List<Map<String, dynamic>>> future,
    Duration timeout,
  ) async {
    try {
      return await future.timeout(timeout);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<List<ProductModel>> _fallbackProductsFetch({int limit = 24}) async {
    try {
      final page = await _service
          .getProductsPage(limit: limit)
          .timeout(const Duration(seconds: 12));
      return page.products;
    } catch (_) {
      return const <ProductModel>[];
    }
  }

  Future<bool> _hydrateFullCatalogFromServer() async {
    final merged = <String, ProductModel>{
      for (final product in _products)
        if (product.id.trim().isNotEmpty) product.id.trim(): product,
    };

    DocumentSnapshot<Map<String, dynamic>>? cursor;
    var hasMore = true;
    String? lastCursorId;
    var fetchedAny = false;

    while (hasMore && merged.length < _homeMaxProductPool) {
      final remaining = _homeMaxProductPool - merged.length;
      if (remaining <= 0) break;

      final page = await _service.getProductsPageFiltered(
        limit: remaining < _homeFullCatalogPageSize
            ? remaining
            : _homeFullCatalogPageSize,
        startAfterDoc: cursor,
        category: null,
        brand: null,
      );

      for (final product in page.products) {
        final id = product.id.trim();
        if (id.isEmpty) continue;
        merged[id] = product;
      }

      fetchedAny = fetchedAny || page.products.isNotEmpty;
      final nextCursor = page.lastDocument;
      final nextCursorId = nextCursor?.id;
      final cursorStalled =
          nextCursorId != null && nextCursorId == lastCursorId;

      cursor = nextCursor;
      hasMore = page.hasMore && cursor != null && !cursorStalled;
      lastCursorId = nextCursorId;

      if (page.products.isEmpty && !hasMore) break;
    }

    if (merged.isEmpty) return false;

    _products = merged.values.toList(growable: false);
    _hasLoadedOnce = true;
    _hasAttemptedFullCatalogLoad =
        !hasMore || merged.length >= _homeMaxProductPool;

    return fetchedAny;
  }

  String _safeString(dynamic value, {String fallback = ''}) {
    final text = (value ?? fallback).toString().trim();
    return text;
  }

  List<ProductModel> get products => _products;
  List<Map<String, dynamic>> get banners => _banners;

  List<Map<String, dynamic>> get categories {
    final hasRemoteCategories = _categories.isNotEmpty;
    final source = hasRemoteCategories ? _categories : AppConstants.categories;
    final merged = <String, Map<String, dynamic>>{};

    for (final category in source) {
      final normalized = _normalizeCategory(category);
      final key = _normalizedKey(_safeString(normalized['name']));
      if (_hiddenCategoryNames.contains(key)) continue;
      merged[key] = normalized;
    }

    for (final category in AppConstants.categories) {
      final normalized = _normalizeCategory(category);
      final key = _normalizedKey(_safeString(normalized['name']));
      if (_hiddenCategoryNames.contains(key)) continue;

      if (!hasRemoteCategories) {
        merged.putIfAbsent(key, () => normalized);
        continue;
      }

      // Firestore is source-of-truth when available.
      // Only enrich already-present categories (e.g., fill missing icon).
      if (merged.containsKey(key)) {
        final existing = merged[key] ?? const <String, dynamic>{};
        merged[key] = {
          ...normalized,
          ...existing,
          'icon': (existing['icon'] ?? '').toString().trim().isNotEmpty
              ? existing['icon']
              : normalized['icon'],
        };
      }
    }

    return merged.values.toList();
  }

  List<Map<String, dynamic>> get subCategories {
    final hasRemoteSubCategories = _subCategories.isNotEmpty;
    final source = hasRemoteSubCategories
        ? _subCategories
        : AppConstants.subCategories;
    final merged = <String, Map<String, dynamic>>{};

    for (final subCategory in source) {
      final normalized = _normalizeSubCategory(subCategory);
      final parentKey = _normalizedKey(
        _safeString(normalized['parentCategory']),
      );
      if (_hiddenCategoryNames.contains(parentKey)) continue;
      final key =
          '$parentKey::${_normalizedKey(_safeString(normalized['name']))}';
      merged[key] = normalized;
    }

    for (final subCategory in AppConstants.subCategories) {
      final normalized = _normalizeSubCategory(subCategory);
      final parentKey = _normalizedKey(
        _safeString(normalized['parentCategory']),
      );
      if (_hiddenCategoryNames.contains(parentKey)) continue;
      final key =
          '$parentKey::${_normalizedKey(_safeString(normalized['name']))}';

      if (!hasRemoteSubCategories) {
        merged.putIfAbsent(key, () => normalized);
        continue;
      }

      // Do not introduce extra fallback sub-categories when Firestore data exists.
      if (merged.containsKey(key)) {
        final existing = merged[key] ?? const <String, dynamic>{};
        merged[key] = {
          ...normalized,
          ...existing,
          'icon': (existing['icon'] ?? '').toString().trim().isNotEmpty
              ? existing['icon']
              : normalized['icon'],
        };
      }
    }

    final items = merged.values.toList();
    items.sort(
      (a, b) => _safeString(
        a['name'],
      ).toLowerCase().compareTo(_safeString(b['name']).toLowerCase()),
    );
    return items;
  }

  List<Map<String, dynamic>> get brands {
    if (_brands.isNotEmpty) {
      return _brands
          .map(
            (brand) => {
              ...brand,
              'name': (brand['name'] ?? '').toString(),
              'image': (brand['image'] ?? brand['logo'] ?? '').toString(),
            },
          )
          .where((brand) => _safeString(brand['name']).isNotEmpty)
          .toList();
    }

    final merged = <String, Map<String, dynamic>>{};
    for (final product in productMaps) {
      final name = (product['brand'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final key = _normalizedKey(name);
      merged.putIfAbsent(key, () => {'id': key, 'name': name, 'image': ''});
    }
    final items = merged.values.toList();
    items.sort(
      (a, b) => _safeString(
        a['name'],
      ).toLowerCase().compareTo(_safeString(b['name']).toLowerCase()),
    );
    return items;
  }

  List<Map<String, dynamic>> get subSubCategories {
    final hasRemoteSubSubCategories = _subSubCategories.isNotEmpty;
    final source = hasRemoteSubSubCategories
        ? _subSubCategories
        : AppConstants.subSubCategories;
    final merged = <String, Map<String, dynamic>>{};

    for (final subSubCategory in source) {
      final normalized = _normalizeSubSubCategory(subSubCategory);
      final parentCategoryKey = _normalizedKey(
        _safeString(normalized['parentCategory']),
      );
      if (_hiddenCategoryNames.contains(parentCategoryKey)) continue;

      final key =
          '$parentCategoryKey::${_normalizedKey(_safeString(normalized['parentSubCategory']))}::${_normalizedKey(_safeString(normalized['name']))}';
      merged[key] = normalized;
    }

    for (final subSubCategory in AppConstants.subSubCategories) {
      final normalized = _normalizeSubSubCategory(subSubCategory);
      final parentCategoryKey = _normalizedKey(
        _safeString(normalized['parentCategory']),
      );
      if (_hiddenCategoryNames.contains(parentCategoryKey)) continue;
      final key =
          '$parentCategoryKey::${_normalizedKey(_safeString(normalized['parentSubCategory']))}::${_normalizedKey(_safeString(normalized['name']))}';

      if (!hasRemoteSubSubCategories) {
        merged.putIfAbsent(key, () => normalized);
        continue;
      }

      // Do not inject extra fallback rows when Firestore data exists.
      if (merged.containsKey(key)) {
        final existing = merged[key] ?? const <String, dynamic>{};
        merged[key] = {
          ...normalized,
          ...existing,
          'icon': (existing['icon'] ?? '').toString().trim().isNotEmpty
              ? existing['icon']
              : normalized['icon'],
        };
      }
    }

    final items = merged.values.toList();
    items.sort(
      (a, b) => _safeString(
        a['name'],
      ).toLowerCase().compareTo(_safeString(b['name']).toLowerCase()),
    );
    return items;
  }

  bool get loading => _loading;
  String? get error => _error;

  /// Whether the full visibility catalog has been loaded. Screens should
  /// check this (or await [ensureVisibilityCatalogLoaded]) before filtering.
  bool get fullCatalogReady => _fullCatalogReady;

  /// Awaitable shorthand: resolves once the full catalog is ready.
  Future<void> get catalogReady => ensureVisibilityCatalogLoaded();

  String _normalizedKey(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    return normalized.replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  String _normalizeSearchText(String? value) {
    return (value ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s,_-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  List<String> _stringList(dynamic raw) {
    final values = <String>{};

    void collect(dynamic node) {
      if (node == null) return;

      if (node is String) {
        for (final item in node.split(RegExp(r'[,|/&;>]+'))) {
          final value = item.trim();
          if (value.isNotEmpty) values.add(value);
        }
        return;
      }

      if (node is num || node is bool) {
        final value = node.toString().trim();
        if (value.isNotEmpty) values.add(value);
        return;
      }

      if (node is Map) {
        const preferredKeys = [
          'name',
          'title',
          'label',
          'category',
          'categoryName',
          'parentCategory',
          'subCategory',
          'subSubCategory',
          'value',
        ];

        for (final key in preferredKeys) {
          if (node.containsKey(key)) collect(node[key]);
        }

        for (final entry in node.entries) {
          final entryKey = entry.key.toString();
          if (preferredKeys.contains(entryKey)) continue;
          collect(entry.value);
        }
        return;
      }

      if (node is Iterable) {
        for (final item in node) {
          collect(item);
        }
        return;
      }

      final value = node.toString().trim();
      if (value.isNotEmpty) values.add(value);
    }

    collect(raw);
    return values.toList(growable: false);
  }

  List<String> _categoryCandidates(Map<String, dynamic> product) {
    final values = <String>{};

    values.addAll(_stringList(product['category']));
    values.addAll(_stringList(product['categoryName']));
    values.addAll(_stringList(product['parentCategory']));

    values.addAll(_stringList(product['selectedCategories']));
    values.addAll(_stringList(product['categoryPathNames']));

    return values.where((value) => value.trim().isNotEmpty).toList();
  }

  List<String> productSubCategoryCandidates(Map<String, dynamic> product) {
    final values = <String>{};

    values.addAll(_stringList(product['subCategory']));
    values.addAll(_stringList(product['subcategory']));
    values.addAll(_stringList(product['sub_category']));

    values.addAll(_stringList(product['selectedSubCategory']));
    values.addAll(_stringList(product['selectedSubcategory']));
    values.addAll(_stringList(product['subCategoryName']));
    values.addAll(_stringList(product['sub_category_name']));

    values.addAll(_stringList(product['selectedSubCategories']));
    values.addAll(_stringList(product['selectedSubCategoryNames']));

    final path = _stringList(product['categoryPathNames']);
    if (path.length >= 2) values.add(path[1]);

    final selectedCategories = _stringList(product['selectedCategories']);
    if (selectedCategories.length >= 2) values.add(selectedCategories[1]);

    return values.where((value) => value.trim().isNotEmpty).toList();
  }

  List<String> productSubSubCategoryCandidates(Map<String, dynamic> product) {
    final values = <String>{};

    values.addAll(_stringList(product['subSubCategory']));
    values.addAll(_stringList(product['subsubCategory']));
    values.addAll(_stringList(product['sub_sub_category']));

    values.addAll(_stringList(product['selectedSubSubCategory']));
    values.addAll(_stringList(product['selectedSubsubcategory']));
    values.addAll(_stringList(product['subSubCategoryName']));
    values.addAll(_stringList(product['sub_sub_category_name']));

    values.addAll(_stringList(product['selectedSubSubCategories']));

    final path = _stringList(product['categoryPathNames']);
    if (path.length >= 3) values.add(path[2]);

    final selectedCategories = _stringList(product['selectedCategories']);
    if (selectedCategories.length >= 3) values.add(selectedCategories[2]);

    return values.where((value) => value.trim().isNotEmpty).toList();
  }

  bool _matchesCategory(Map<String, dynamic> product, String category) {
    if (category.trim().isEmpty || category == 'All') return true;

    final selected = _normalizedKey(category);
    if (selected.isEmpty) return true;

    for (final candidate in _categoryCandidates(product)) {
      final key = _normalizedKey(candidate);
      if (key.isEmpty) continue;
      if (key == selected) return true;
    }

    // Fallback: infer parent category from taxonomy when products miss direct
    // category fields but still carry valid sub-category metadata.
    for (final productSubCategory in productSubCategoryCandidates(product)) {
      final productSubCategoryKey = _normalizedKey(productSubCategory);
      if (productSubCategoryKey.isEmpty) continue;
      for (final sub in subCategories) {
        final subNameKey = _normalizedKey(_safeString(sub['name']));
        if (subNameKey.isEmpty || subNameKey != productSubCategoryKey) {
          continue;
        }
        final parentKey = _normalizedKey(_safeString(sub['parentCategory']));
        if (parentKey == selected) return true;
      }
    }

    for (final productSubSubCategory in productSubSubCategoryCandidates(
      product,
    )) {
      final productSubSubCategoryKey = _normalizedKey(productSubSubCategory);
      if (productSubSubCategoryKey.isEmpty) continue;
      for (final subSub in subSubCategories) {
        final subSubNameKey = _normalizedKey(_safeString(subSub['name']));
        if (subSubNameKey.isEmpty ||
            subSubNameKey != productSubSubCategoryKey) {
          continue;
        }
        final parentKey = _normalizedKey(_safeString(subSub['parentCategory']));
        if (parentKey == selected) return true;
      }
    }

    return false;
  }

  List<String> _productTags(Map<String, dynamic> product) {
    final tags = <String>{};

    final singleTag = (product['tag'] ?? '').toString().trim();
    if (singleTag.isNotEmpty) tags.add(singleTag);

    final rawTags = product['tags'];
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

    return tags.toList();
  }

  bool _matchesSearchQuery(Map<String, dynamic> product, String query) {
    final normalizedQuery = _normalizeSearchText(query);
    if (normalizedQuery.isEmpty) return true;

    final searchableText = _normalizeSearchText(
      [
        product['name'],
        product['brand'],
        product['category'],
        productSubCategory(product),
        productSubSubCategory(product),
        product['description'],
        product['shortDescription'],
        product['subtitle'] ?? product['subTitle'],
        ..._productTags(product),
      ].join(' '),
    );

    if (searchableText.isEmpty) return false;
    if (searchableText.contains(normalizedQuery)) return true;

    final queryTokens = normalizedQuery
        .split(' ')
        .where((token) => token.trim().isNotEmpty)
        .toList();
    if (queryTokens.isEmpty) return true;

    return queryTokens.every(searchableText.contains);
  }

  Map<String, dynamic> _normalizeCategory(Map<String, dynamic> category) {
    return {
      ...category,
      'name': category['name'] ?? 'Category',
      'icon': category['icon'] ?? category['image'],
    };
  }

  Map<String, dynamic> _normalizeSubCategory(Map<String, dynamic> subCategory) {
    return {
      ...subCategory,
      'name': subCategory['name'] ?? 'Subcategory',
      'parentCategory':
          subCategory['parentCategory'] ??
          subCategory['category'] ??
          subCategory['parent'] ??
          '',
      'icon': subCategory['icon'] ?? subCategory['image'],
    };
  }

  Map<String, dynamic> _normalizeSubSubCategory(
    Map<String, dynamic> subSubCategory,
  ) {
    return {
      ...subSubCategory,
      'name': subSubCategory['name'] ?? 'Sub-subcategory',
      'parentCategory':
          subSubCategory['parentCategory'] ??
          subSubCategory['category'] ??
          subSubCategory['parent'] ??
          '',
      'parentSubCategory':
          subSubCategory['parentSubCategory'] ??
          subSubCategory['subCategory'] ??
          subSubCategory['parentSubcategory'] ??
          subSubCategory['parentSub'] ??
          '',
      'icon': subSubCategory['icon'] ?? subSubCategory['image'],
    };
  }

  List<Map<String, dynamic>> subCategoriesFor(String category) {
    final categoryKey = _normalizedKey(category);
    return subCategories
        .where(
          (subCategory) =>
              _normalizedKey(_safeString(subCategory['parentCategory'])) ==
              categoryKey,
        )
        .toList();
  }

  List<Map<String, dynamic>> subSubCategoriesFor(
    String category,
    String subCategory,
  ) {
    final categoryKey = _normalizedKey(category);
    final subCategoryKey = _normalizedKey(subCategory);
    return subSubCategories
        .where(
          (subSubCategory) =>
              _normalizedKey(_safeString(subSubCategory['parentCategory'])) ==
                  categoryKey &&
              _normalizedKey(
                    _safeString(subSubCategory['parentSubCategory']),
                  ) ==
                  subCategoryKey,
        )
        .toList();
  }

  String productSubCategory(Map<String, dynamic> product) {
    String fromKeys(Map<String, dynamic> source, List<String> keys) {
      for (final key in keys) {
        final values = _stringList(source[key]);
        if (values.isNotEmpty) return values.first;
      }
      return '';
    }

    final directCandidates = <String>[
      ..._stringList(product['subCategory']),
      ..._stringList(product['subcategory']),
      ..._stringList(product['sub_category']),
    ];
    final direct = directCandidates.firstWhere(
      (value) => value.trim().isNotEmpty,
      orElse: () => '',
    );
    if (direct.isNotEmpty) return direct;

    final mapDirect = fromKeys(product, const [
      'selectedSubCategory',
      'selectedSubcategory',
      'subCategoryName',
      'sub_category_name',
    ]);
    if (mapDirect.isNotEmpty) return mapDirect;

    final selectedSubCategories = _stringList(product['selectedSubCategories']);
    if (selectedSubCategories.isNotEmpty) return selectedSubCategories.first;

    final selectedSubCategoryNames = _stringList(
      product['selectedSubCategoryNames'],
    );
    if (selectedSubCategoryNames.isNotEmpty) {
      return selectedSubCategoryNames.first;
    }

    final path = _stringList(product['categoryPathNames']);
    if (path.length >= 2) return path[1];

    final selectedCategories = _stringList(product['selectedCategories']);
    if (selectedCategories.length >= 2) return selectedCategories[1];

    return '';
  }

  String productSubSubCategory(Map<String, dynamic> product) {
    String fromKeys(Map<String, dynamic> source, List<String> keys) {
      for (final key in keys) {
        final values = _stringList(source[key]);
        if (values.isNotEmpty) return values.first;
      }
      return '';
    }

    final directCandidates = <String>[
      ..._stringList(product['subSubCategory']),
      ..._stringList(product['subsubCategory']),
      ..._stringList(product['sub_sub_category']),
    ];
    final direct = directCandidates.firstWhere(
      (value) => value.trim().isNotEmpty,
      orElse: () => '',
    );
    if (direct.isNotEmpty) return direct;

    final mapDirect = fromKeys(product, const [
      'selectedSubSubCategory',
      'selectedSubsubcategory',
      'subSubCategoryName',
      'sub_sub_category_name',
    ]);
    if (mapDirect.isNotEmpty) return mapDirect;

    final selectedSubSubCategories = _stringList(
      product['selectedSubSubCategories'],
    );
    if (selectedSubSubCategories.isNotEmpty) {
      return selectedSubSubCategories.first;
    }

    final path = _stringList(product['categoryPathNames']);
    if (path.length >= 3) return path[2];

    final selectedCategories = _stringList(product['selectedCategories']);
    if (selectedCategories.length >= 3) return selectedCategories[2];

    return '';
  }

  Future<void> ensureVisibilityCatalogLoaded() async {
    // Dedup: return the in-flight future if already running.
    if (_visibilityCatalogCompleter != null) {
      return _visibilityCatalogCompleter!.future;
    }

    // If loadData is in flight, wait for it to complete before proceeding.
    if (_loadDataCompleter != null) await _loadDataCompleter!.future;

    // Nothing to do – full catalog already loaded.
    if (_fullCatalogReady) return;
    if (_hasAttemptedFullCatalogLoad) {
      _fullCatalogReady = true;
      notifyListeners();
      return;
    }

    _visibilityCatalogCompleter = Completer<void>();
    try {
      // Retry a few times because large catalogs can hit transient network delays.
      for (var attempt = 0; attempt < 3; attempt++) {
        await loadData(forceRefresh: true);
        if (_hasAttemptedFullCatalogLoad) break;
      }

      if (!_hasAttemptedFullCatalogLoad) {
        final hydrated = await _hydrateFullCatalogFromServer();
        if (hydrated) {
          _error = null;
          notifyListeners();
          unawaited(_persistStartupCache());
        }
      }

      _fullCatalogReady = true;
      final count = productMaps.length;
      if (count <= _homeInitialProductLimit) {
        debugPrint(
          '[CatalogWarn] Full catalog contains only $count products '
          '(≤ startup-lite threshold of $_homeInitialProductLimit). '
          'A partial dataset may have been returned by Firestore.',
        );
      } else {
        debugPrint('[CatalogInfo] Full catalog loaded: $count products.');
      }
      notifyListeners();
      _visibilityCatalogCompleter?.complete();
    } catch (e) {
      debugPrint('[CatalogError] ensureVisibilityCatalogLoaded failed: $e');
      // Keep visibility flow resilient; existing pool remains usable.
      // Complete so any waiting callers are unblocked.
      _visibilityCatalogCompleter?.complete();
    } finally {
      _visibilityCatalogCompleter = null;
    }
  }

  /// Returns all products as the legacy Map format (for widgets that expect Map)
  List<Map<String, dynamic>> get productMaps {
    return _products.map((p) => p.toProductMap()).toList();
  }

  /// Seed the catalog directly for unit tests without hitting Firestore.
  /// Call this from test files only.
  @visibleForTesting
  void seedForTest(
    List<ProductModel> products, {
    bool fullCatalogReady = true,
  }) {
    _products = List.from(products);
    _hasLoadedOnce = true;
    _hasAttemptedFullCatalogLoad = fullCatalogReady;
    _fullCatalogReady = fullCatalogReady;
  }

  Future<void> _hydrateTaxonomyInBackground() async {
    if (_taxonomyLoading) return;
    _taxonomyLoading = true;
    try {
      final results = await Future.wait<List<Map<String, dynamic>>>([
        _service.getCategories(),
        _service.getSubCategories(),
        _service.getSubSubCategories(),
        _service.getBrands(),
      ]);

      final cats = results[0];
      final subCats = results[1];
      final subSubCats = results[2];
      final brands = results[3];
      var changed = false;

      if (cats.isNotEmpty) {
        _categories = cats;
        changed = true;
      }
      if (subCats.isNotEmpty) {
        _subCategories = subCats;
        changed = true;
      }
      if (subSubCats.isNotEmpty) {
        _subSubCategories = subSubCats;
        changed = true;
      }
      if (brands.isNotEmpty) {
        _brands = brands;
        changed = true;
      }

      if (changed) notifyListeners();
    } catch (_) {
      // Best-effort background enrichment only.
    } finally {
      _taxonomyLoading = false;
    }
  }

  Future<void> loadData({bool forceRefresh = false}) async {
    // Dedup: all concurrent callers share the in-flight future so none silently
    // return with partial data while a load is already in progress.
    if (_loadDataCompleter != null) return _loadDataCompleter!.future;
    if (!forceRefresh && _hasLoadedOnce) return;

    _loadDataCompleter = Completer<void>();
    try {
      await PerformanceTraceService.recordVoid('home_load_time', () async {
        final startupLite =
            FeatureFlags.enableHomeStartupLite &&
            !forceRefresh &&
            !_hasLoadedOnce;
        final canUseStartupCache =
            FeatureFlags.enableHomeStartupCache && startupLite;
        var hydratedFromCache = false;

        if (canUseStartupCache) {
          hydratedFromCache = await _hydrateStartupCache();
          if (hydratedFromCache) {
            notifyListeners();
          }
        }

        _loading = !hydratedFromCache;
        _error = null;
        notifyListeners();

        final targetPool = startupLite
            ? FeatureFlags.homeStartupProductPool
            : _homeMaxProductPool;
        final fetched = <ProductModel>[];
        DocumentSnapshot<Map<String, dynamic>>? cursor;
        var hasMore = true;
        var timedOut = false;

        try {
          final productsTimeout = Duration(
            milliseconds: FeatureFlags.homeProductsPageTimeoutMs,
          );

          while (hasMore && fetched.length < targetPool) {
            final remaining = targetPool - fetched.length;
            if (remaining <= 0) break;
            final pageSize = startupLite
                ? _homeInitialProductLimit
                : _homeFullCatalogPageSize;

            try {
              final pageFuture = _service.getProductsPage(
                limit: remaining < pageSize ? remaining : pageSize,
                startAfterDoc: cursor,
              );
              final page = startupLite
                  ? await pageFuture.timeout(productsTimeout)
                  : await pageFuture;

              fetched.addAll(page.products);
              cursor = page.lastDocument;
              hasMore = page.hasMore;
            } on TimeoutException {
              timedOut = true;
              break;
            }
          }

          if (fetched.isEmpty) {
            final fallback = await _fallbackProductsFetch(limit: 24);
            if (fallback.isNotEmpty) {
              fetched.addAll(fallback);
            }
          }

          if (startupLite) {
            final latest = await _service.getLatestPublishedProducts(
              limit: _homeInitialProductLimit,
            );
            if (latest.isNotEmpty) {
              final merged = <String, ProductModel>{
                for (final product in latest)
                  if (product.id.trim().isNotEmpty) product.id.trim(): product,
              };

              for (final product in fetched) {
                final id = product.id.trim();
                if (id.isEmpty || merged.containsKey(id)) continue;
                merged[id] = product;
              }

              fetched
                ..clear()
                ..addAll(
                  merged.values.take(targetPool).toList(growable: false),
                );
            }
          }

          final fullLoadRequested = forceRefresh || !startupLite;
          final fullCatalogComplete =
              !timedOut && (!hasMore || fetched.length >= _homeMaxProductPool);
          _hasAttemptedFullCatalogLoad =
              fullLoadRequested && fullCatalogComplete;

          final deferTaxonomy =
              FeatureFlags.enableDeferredHomeTaxonomy && startupLite;
          final bannersTimeout = Duration(
            milliseconds: FeatureFlags.homeBannersTimeoutMs,
          );
          final taxonomyTimeout = Duration(
            milliseconds: FeatureFlags.homeTaxonomyTimeoutMs,
          );

          final results = await Future.wait<List<Map<String, dynamic>>>([
            _timedListFetch(
              _service.getBanners(forceRefresh: forceRefresh),
              bannersTimeout,
            ),
            if (deferTaxonomy)
              Future.value(const <Map<String, dynamic>>[])
            else
              _timedListFetch(_service.getCategories(), taxonomyTimeout),
            if (deferTaxonomy)
              Future.value(const <Map<String, dynamic>>[])
            else
              _timedListFetch(_service.getSubCategories(), taxonomyTimeout),
            if (deferTaxonomy)
              Future.value(const <Map<String, dynamic>>[])
            else
              _timedListFetch(_service.getSubSubCategories(), taxonomyTimeout),
            if (deferTaxonomy)
              Future.value(const <Map<String, dynamic>>[])
            else
              _timedListFetch(_service.getBrands(), taxonomyTimeout),
          ]);
          if (fetched.isNotEmpty) {
            _products = fetched;
            _hasLoadedOnce = true;
          }
          _banners = results[0];
          final cats = results[1];
          final subCats = results[2];
          final subSubCats = results[3];
          final brands = results[4];
          // If Firestore has categories, use them; otherwise fall back to constants
          if (cats.isNotEmpty) _categories = cats;
          if (subCats.isNotEmpty) _subCategories = subCats;
          if (subSubCats.isNotEmpty) _subSubCategories = subSubCats;
          if (brands.isNotEmpty) _brands = brands;

          if (timedOut && !_hasAttemptedFullCatalogLoad) {
            _error = 'Home data load timed out. Retrying in background...';
          }

          if (deferTaxonomy) {
            unawaited(_hydrateTaxonomyInBackground());
          }

          unawaited(_persistStartupCache());
        } on TimeoutException {
          _error = 'Home data load timed out. Please pull to refresh.';
          if (fetched.isNotEmpty) {
            _products = fetched;
            _hasLoadedOnce = true;
          }
          _hasAttemptedFullCatalogLoad = false;
          if (_products.isEmpty) {
            final fallback = await _fallbackProductsFetch(limit: 24);
            if (fallback.isNotEmpty) {
              _products = fallback;
              _error = null;
              _hasLoadedOnce = true;
              unawaited(_persistStartupCache());
            }
          }
        } catch (e) {
          _error = e.toString();
          if (fetched.isNotEmpty) {
            _products = fetched;
            _hasLoadedOnce = true;
          }
          _hasAttemptedFullCatalogLoad = false;
          if (_products.isEmpty) {
            final fallback = await _fallbackProductsFetch(limit: 24);
            if (fallback.isNotEmpty) {
              _products = fallback;
              _error = null;
              _hasLoadedOnce = true;
              unawaited(_persistStartupCache());
            }
          }
        }

        _loading = false;
        notifyListeners();
      });
    } finally {
      // Ensure all concurrent callers are unblocked whether or not an
      // unexpected error escaped the PerformanceTraceService wrapper.
      final c = _loadDataCompleter;
      _loadDataCompleter = null;
      if (c != null && !c.isCompleted) c.complete();
    }
  }

  List<Map<String, dynamic>> filteredProducts({
    String category = 'All',
    String? subCategory,
    String? subSubCategory,
    String query = '',
    String sort = 'popular',
  }) {
    final allProducts = List<Map<String, dynamic>>.from(productMaps);
    var list = List<Map<String, dynamic>>.from(allProducts);

    list = list
        .where((product) => _matchesCategory(product, category))
        .toList();

    if ((subCategory ?? '').trim().isNotEmpty) {
      final selectedSubCategoryKey = _normalizedKey(subCategory);
      list = list
          .where(
            (product) => productSubCategoryCandidates(product).any(
              (candidate) =>
                  _normalizedKey(candidate) == selectedSubCategoryKey,
            ),
          )
          .toList();
    }

    if ((subSubCategory ?? '').trim().isNotEmpty) {
      final selectedSubSubCategoryKey = _normalizedKey(subSubCategory);
      list = list
          .where(
            (product) => productSubSubCategoryCandidates(product).any(
              (candidate) =>
                  _normalizedKey(candidate) == selectedSubSubCategoryKey,
            ),
          )
          .toList();
    }

    if (query.isNotEmpty) {
      list = list.where((p) => _matchesSearchQuery(p, query)).toList();
    }

    if (sort == 'low') {
      list.sort((a, b) => (a['price'] as num).compareTo(b['price'] as num));
    } else if (sort == 'high') {
      list.sort((a, b) => (b['price'] as num).compareTo(a['price'] as num));
    } else if (sort == 'rating') {
      list.sort((a, b) => (b['rating'] as num).compareTo(a['rating'] as num));
    }

    return list;
  }
}
