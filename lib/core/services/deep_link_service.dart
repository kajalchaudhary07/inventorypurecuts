import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:purecuts/core/navigation/app_navigator.dart';
import 'package:purecuts/features/products/product_detail_screen.dart';

class DeepLinkService {
  DeepLinkService._();

  static final DeepLinkService instance = DeepLinkService._();

  static const String _defaultShareHost = 'purecuts-11a7c.web.app';

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _uriSub;
  bool _initialized = false;
  String? _lastHandledToken;

  static Uri buildProductShareUri(String productId) {
    final cleanId = productId.trim();
    return Uri.https(_defaultShareHost, '/p/$cleanId');
  }

  Future<void> initialize() async {
    if (_initialized || _uriSub != null) return;
    _initialized = true;

    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        await _handleUri(initialUri);
      }
    } catch (_) {
      // Non-blocking.
    }

    _uriSub = _appLinks.uriLinkStream.listen((uri) {
      unawaited(_handleUri(uri));
    });
  }

  Future<void> dispose() async {
    await _uriSub?.cancel();
    _uriSub = null;
    _initialized = false;
  }

  Future<void> _handleUri(Uri uri) async {
    final productId = _extractProductId(uri);
    if (productId.isEmpty) return;

    final token = '${uri.toString()}::$productId';
    if (_lastHandledToken == token) return;
    _lastHandledToken = token;

    await _openProductDetail(productId);
  }

  String _extractProductId(Uri uri) {
    final segments = uri.pathSegments;
    if (segments.length >= 2 && segments.first.toLowerCase() == 'p') {
      return Uri.decodeComponent(segments[1].trim());
    }

    final queryId =
        (uri.queryParameters['productId'] ?? uri.queryParameters['pid'] ?? '')
            .trim();
    if (queryId.isNotEmpty) {
      return Uri.decodeComponent(queryId);
    }

    return '';
  }

  String _baseProductId(String value) {
    final id = value.trim();
    if (id.isEmpty) return '';
    final sep = id.indexOf('::');
    if (sep <= 0) return id;
    return id.substring(0, sep);
  }

  Future<void> _openProductDetail(String productId) async {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) {
      await Future.delayed(const Duration(milliseconds: 400));
    }

    final usableNavigator = appNavigatorKey.currentState;
    if (usableNavigator == null) return;

    final id = _baseProductId(productId);
    if (id.isEmpty) return;

    Map<String, dynamic> product = {'id': id};

    try {
      final doc = await FirebaseFirestore.instance
          .collection('products')
          .doc(id)
          .get();
      if (doc.exists) {
        product = {'id': doc.id, ...?doc.data()};
      }
    } catch (_) {
      // Fallback with id-only payload still allows ProductDetailScreen to load.
    }

    if (appNavigatorKey.currentContext == null) return;

    usableNavigator.push(
      MaterialPageRoute(builder: (_) => ProductDetailScreen(product: product)),
    );
  }
}
