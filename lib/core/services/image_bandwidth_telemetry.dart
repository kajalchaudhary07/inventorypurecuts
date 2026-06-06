import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:purecuts/core/constants/feature_flags.dart';

class _ImageScreenStats {
  _ImageScreenStats(this.screen);

  final String screen;
  final Set<String> _uniqueUrls = <String>{};
  int renderCount = 0;
  int cacheHits = 0;
  int cacheMisses = 0;
  int unresolvedLoads = 0;
  int estimatedNetworkBytes = 0;
  int cachedBytesServed = 0;

  int get uniqueUrls => _uniqueUrls.length;

  bool markUnique(String url) => _uniqueUrls.add(url);

  Map<String, Object> toMap() {
    return {
      'screen': screen,
      'renders': renderCount,
      'uniqueUrls': uniqueUrls,
      'cacheHits': cacheHits,
      'cacheMisses': cacheMisses,
      'unresolvedLoads': unresolvedLoads,
      'estimatedNetworkBytes': estimatedNetworkBytes,
      'cachedBytesServed': cachedBytesServed,
    };
  }
}

class ImageBandwidthTelemetry {
  ImageBandwidthTelemetry._();

  static final ImageBandwidthTelemetry instance = ImageBandwidthTelemetry._();

  final DefaultCacheManager _cacheManager = DefaultCacheManager();
  final Map<String, _ImageScreenStats> _statsByScreen =
      <String, _ImageScreenStats>{};
  final Map<String, Future<void>> _pendingByKey = <String, Future<void>>{};
  final Set<String> _pendingResolutionKeys = <String>{};
  final Set<String> _unresolvedKeys = <String>{};
  int _sampleCount = 0;

  bool get _enabled => FeatureFlags.enableImageBandwidthTelemetry && kDebugMode;

  Future<void> trackImageLoad({
    required String screen,
    required String imageUrl,
  }) async {
    if (!_enabled) return;

    final cleanScreen = screen.trim().isEmpty ? 'unknown' : screen.trim();
    final url = imageUrl.trim();
    if (url.isEmpty || url.startsWith('assets/')) return;

    final stats = _statsByScreen.putIfAbsent(
      cleanScreen,
      () => _ImageScreenStats(cleanScreen),
    );
    stats.renderCount += 1;

    final uniqueKey = '$cleanScreen::$url';
    if (!stats.markUnique(url)) {
      if (_unresolvedKeys.contains(uniqueKey)) {
        _scheduleUnresolvedResolution(
          stats: stats,
          imageUrl: imageUrl,
          resolutionKey: uniqueKey,
        );
      }
      _maybePrintSummary();
      return;
    }

    if (_pendingByKey.containsKey(uniqueKey)) return;

    final task = _measureUniqueUrl(
      stats: stats,
      imageUrl: url,
      resolutionKey: uniqueKey,
    );
    _pendingByKey[uniqueKey] = task;
    try {
      await task;
    } finally {
      _pendingByKey.remove(uniqueKey);
    }
  }

  Future<void> _measureUniqueUrl({
    required _ImageScreenStats stats,
    required String imageUrl,
    required String resolutionKey,
  }) async {
    FileInfo? before;
    try {
      before = await _cacheManager.getFileFromCache(imageUrl);
    } catch (_) {
      before = null;
    }

    final wasCacheHit = before != null;

    FileInfo? after = before;
    if (after == null) {
      // Let image pipeline fetch + persist, with a few retries.
      for (var i = 0; i < 5 && after == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        try {
          after = await _cacheManager.getFileFromCache(imageUrl);
        } catch (_) {
          after = null;
        }
      }
    }

    final cacheFile = after ?? before;
    int byteSize = 0;
    if (cacheFile != null) {
      try {
        byteSize = await cacheFile.file.length();
      } catch (_) {
        byteSize = 0;
      }
    }

    if (wasCacheHit) {
      stats.cacheHits += 1;
      if (byteSize > 0) stats.cachedBytesServed += byteSize;
    } else if (after != null) {
      stats.cacheMisses += 1;
      if (byteSize > 0) stats.estimatedNetworkBytes += byteSize;
    } else {
      // Could not confidently determine hit/miss yet.
      stats.unresolvedLoads += 1;
      _unresolvedKeys.add(resolutionKey);
      _scheduleUnresolvedResolution(
        stats: stats,
        imageUrl: imageUrl,
        resolutionKey: resolutionKey,
      );
    }

    _sampleCount += 1;
    _maybePrintSummary();
  }

  void _scheduleUnresolvedResolution({
    required _ImageScreenStats stats,
    required String imageUrl,
    required String resolutionKey,
  }) {
    if (_pendingResolutionKeys.contains(resolutionKey)) return;
    _pendingResolutionKeys.add(resolutionKey);

    unawaited(
      Future<void>.delayed(const Duration(seconds: 2), () async {
        try {
          final fileInfo = await _cacheManager.getFileFromCache(imageUrl);
          if (fileInfo == null) return;

          int byteSize = 0;
          try {
            byteSize = await fileInfo.file.length();
          } catch (_) {
            byteSize = 0;
          }

          if (stats.unresolvedLoads > 0) {
            stats.unresolvedLoads -= 1;
          }
          _unresolvedKeys.remove(resolutionKey);
          stats.cacheMisses += 1;
          if (byteSize > 0) {
            stats.estimatedNetworkBytes += byteSize;
          }

          _sampleCount += 1;
          _maybePrintSummary();
        } catch (_) {
          // Keep unresolved if still unavailable.
        } finally {
          _pendingResolutionKeys.remove(resolutionKey);
        }
      }),
    );
  }

  Map<String, Map<String, Object>> snapshot() {
    return _statsByScreen.map((key, value) => MapEntry(key, value.toMap()));
  }

  void _maybePrintSummary() {
    if (_sampleCount <= 0 || _sampleCount % 20 != 0) return;

    final totalUnique = <String>{};
    var totalRenders = 0;
    var totalHits = 0;
    var totalMisses = 0;
    var totalUnresolved = 0;
    var totalNetworkBytes = 0;
    var totalCachedBytes = 0;

    for (final item in _statsByScreen.values) {
      totalRenders += item.renderCount;
      totalHits += item.cacheHits;
      totalMisses += item.cacheMisses;
      totalUnresolved += item.unresolvedLoads;
      totalNetworkBytes += item.estimatedNetworkBytes;
      totalCachedBytes += item.cachedBytesServed;
      totalUnique.addAll(item._uniqueUrls);
    }

    debugPrint(
      '[ImageBandwidthTelemetry] '
      '{screen: TOTAL, renders: $totalRenders, uniqueUrls: ${totalUnique.length}, '
      'cacheHits: $totalHits, cacheMisses: $totalMisses, unresolvedLoads: $totalUnresolved, '
      'estimatedNetworkBytes: $totalNetworkBytes, cachedBytesServed: $totalCachedBytes}',
    );
    for (final screen in _statsByScreen.values) {
      debugPrint(
        '[ImageBandwidthTelemetry][${screen.screen}] ${screen.toMap()}',
      );
    }
  }
}
