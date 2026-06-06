import 'package:flutter/material.dart';
import 'package:purecuts/core/utils/tier_pricing.dart';

class ProductVariant {
  final String id;
  final String attribute;
  final String value;
  final String sku;
  final String shadeName;
  final Color color;
  final String colorCode; // Raw hex string kept alongside parsed Color
  final int price;
  final int regularPrice;
  final int salePrice;
  final String pricingType;
  final List<PricingTier> pricingTiers;
  final String image;
  final int stock;
  final bool hasExplicitStock;

  const ProductVariant({
    required this.id,
    required this.attribute,
    required this.value,
    required this.sku,
    required this.shadeName,
    required this.color,
    required this.colorCode,
    required this.price,
    this.regularPrice = 0,
    this.salePrice = 0,
    this.pricingType = '',
    this.pricingTiers = const [],
    required this.image,
    this.stock = 0,
    this.hasExplicitStock = false,
  });

  bool get inStock => stock > 0;

  factory ProductVariant.fromMap(String id, Map<String, dynamic> map) {
    int? parseStock(dynamic raw) {
      if (raw == null) return null;
      if (raw is num) return raw.toInt();
      final text = raw.toString().trim();
      if (text.isEmpty) return null;
      return int.tryParse(text);
    }

    final rawStock =
        map['stock'] ??
        map['quantity'] ??
        map['qty'] ??
        map['inventory'] ??
        map['stockCount'];
    final parsedStock = parseStock(rawStock);
    final hasExplicitStockField =
        map.containsKey('stock') ||
        map.containsKey('quantity') ||
        map.containsKey('qty') ||
        map.containsKey('inventory') ||
        map.containsKey('stockCount');

    final rawColorCode = (map['colorCode'] ?? '').toString().trim();
    return ProductVariant(
      id: id,
      attribute: (map['attribute'] ?? 'variant').toString(),
      value: (map['value'] ?? map['shadeName'] ?? map['name'] ?? '').toString(),
      sku: (map['sku'] ?? '').toString(),
      shadeName: (map['shadeName'] ?? map['name'] ?? map['value'] ?? '')
          .toString(),
      color: _parseColor(map['colorCode']),
      colorCode: rawColorCode,
      price: (map['price'] as num?)?.toInt() ?? 0,
      regularPrice: (map['regularPrice'] as num?)?.toInt() ?? 0,
      salePrice: (map['salePrice'] as num?)?.toInt() ?? 0,
      pricingType: (map['pricingType'] ?? '').toString().trim(),
      pricingTiers: parsePricingTiers(map['pricingTiers']),
      image: (map['image'] ?? '').toString(),
      stock: parsedStock ?? 0,
      hasExplicitStock: hasExplicitStockField && parsedStock != null,
    );
  }

  static Color _parseColor(dynamic raw) {
    if (raw is int) return Color(raw);

    final value = (raw ?? '').toString().trim();
    if (value.isEmpty) return const Color(0xFFCBD5E1);

    if (value.startsWith('#')) {
      final hex = value.replaceFirst('#', '');
      final full = hex.length == 6 ? 'FF$hex' : hex;
      return Color(int.tryParse(full, radix: 16) ?? 0xFFCBD5E1);
    }

    if (value.startsWith('0x')) {
      return Color(int.tryParse(value) ?? 0xFFCBD5E1);
    }

    return const Color(0xFFCBD5E1);
  }
}

class ReviewModel {
  final String id;
  final String userName;
  final double rating;
  final String comment;
  final List<String> mediaUrls;
  final DateTime? createdAt;

  const ReviewModel({
    required this.id,
    required this.userName,
    required this.rating,
    required this.comment,
    this.mediaUrls = const [],
    this.createdAt,
  });

  factory ReviewModel.fromMap(String id, Map<String, dynamic> map) {
    return ReviewModel(
      id: id,
      userName: (map['userName'] ?? map['name'] ?? 'User').toString(),
      rating: (map['rating'] as num?)?.toDouble() ?? 0,
      comment: (map['comment'] ?? map['review'] ?? '').toString(),
      mediaUrls: ((map['mediaUrls'] as List?) ?? const [])
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      createdAt: _toDateTime(map['createdAt']),
    );
  }

  static DateTime? _toDateTime(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    try {
      final dynamic maybeTs = raw;
      if (maybeTs.toDate is Function) {
        return maybeTs.toDate() as DateTime;
      }
    } catch (_) {
      // no-op
    }
    return DateTime.tryParse(raw.toString());
  }
}

class Product {
  final String id;
  final String name;
  final String brand;
  final String description;
  final List<String> images;
  final List<ProductVariant> variants;
  final double rating;
  final int reviewCount;
  final List<ReviewModel> reviews;

  const Product({
    required this.id,
    required this.name,
    required this.brand,
    required this.description,
    required this.images,
    required this.variants,
    required this.rating,
    required this.reviewCount,
    required this.reviews,
  });

  ProductVariant? get defaultVariant =>
      variants.isNotEmpty ? variants.first : null;

  factory Product.fromMap(
    String id,
    Map<String, dynamic> map, {
    List<ProductVariant> variants = const [],
    List<ReviewModel> reviews = const [],
  }) {
    List<ProductVariant> parseInlineVariants(dynamic raw) {
      if (raw is! Iterable) return const [];
      final parsed = <ProductVariant>[];
      for (var i = 0; i < raw.length; i++) {
        final item = raw.elementAt(i);
        if (item is Map<String, dynamic>) {
          final variantId = (item['id'] ?? item['variantId'] ?? 'inline_$i')
              .toString();
          parsed.add(ProductVariant.fromMap(variantId, item));
        } else if (item is Map) {
          final converted = item.map(
            (key, value) => MapEntry(key.toString(), value),
          );
          final variantId =
              (converted['id'] ?? converted['variantId'] ?? 'inline_$i')
                  .toString();
          parsed.add(ProductVariant.fromMap(variantId, converted));
        }
      }
      return parsed;
    }

    List<String> toStringList(dynamic raw) {
      if (raw is! Iterable) return <String>[];
      try {
        return raw
            .where((e) => e != null)
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      } catch (_) {
        return <String>[];
      }
    }

    List<String> uniqueOrdered(Iterable<String> values) {
      final seen = <String>{};
      final ordered = <String>[];
      for (final value in values) {
        final item = value.trim();
        if (item.isEmpty) continue;
        if (seen.add(item)) ordered.add(item);
      }
      return ordered;
    }

    final rawImages = toStringList(map['images']);
    final rawAdditionalImages = toStringList(map['additionalImages']);
    final fallbackImage = (map['image'] ?? map['imageUrl'] ?? '').toString();

    final images = uniqueOrdered([
      if (fallbackImage.trim().isNotEmpty) fallbackImage,
      ...rawImages,
      ...rawAdditionalImages,
    ]);
    final effectiveVariants = variants.isNotEmpty
        ? variants
        : parseInlineVariants(map['variants']);
    final aggregateRating = (map['rating'] as num?)?.toDouble() ?? 0.0;
    final derivedRating = reviews.isEmpty
        ? aggregateRating
        : reviews.fold<double>(0.0, (sum, review) => sum + review.rating) /
              reviews.length;
    final derivedReviewCount = reviews.isNotEmpty
        ? reviews.length
        : ((map['reviewCount'] as num?)?.toInt() ??
              (map['reviews'] as num?)?.toInt() ??
              0);

    return Product(
      id: id,
      name: (map['name'] ?? '').toString(),
      brand: (map['brand'] ?? '').toString(),
      description: (map['description'] ?? '').toString(),
      images: images,
      variants: effectiveVariants,
      rating: derivedRating,
      reviewCount: derivedReviewCount,
      reviews: reviews,
    );
  }
}

class ProductState extends ChangeNotifier {
  ProductState({required Product product}) : _product = product {
    if (_product.variants.isNotEmpty) {
      _selectedVariant = _product.variants.first;
    }
  }

  Product _product;
  ProductVariant? _selectedVariant;
  int _selectedImageIndex = 0;

  Product get product => _product;
  ProductVariant? get selectedVariant => _selectedVariant;
  int get selectedImageIndex => _selectedImageIndex;

  int get currentPrice => _selectedVariant?.price ?? 0;
  int get currentStock => _selectedVariant?.stock ?? 0;

  String get primaryImage {
    if (_selectedVariant != null && _selectedVariant!.image.trim().isNotEmpty) {
      return _selectedVariant!.image;
    }
    return _product.images.isNotEmpty ? _product.images.first : '';
  }

  List<String> get displayImages {
    try {
      final seen = <String>{};
      final merged = <String>[];

      void addImage(String value) {
        final item = value.trim();
        if (item.isEmpty) return;
        if (seen.add(item)) merged.add(item);
      }

      // Keep product thumbnail first at all times.
      for (final image in _product.images.whereType<String>()) {
        addImage(image);
      }

      // Variant images are appended after the base product image list.
      for (final variant in _product.variants) {
        addImage(variant.image);
      }

      // Last-resort fallback.
      addImage(primaryImage);

      return merged;
    } catch (_) {
      return const <String>[];
    }
  }

  int _resolveImageIndexForVariant(ProductVariant? variant) {
    final images = displayImages;
    if (images.isEmpty) return 0;

    final variantImage = (variant?.image ?? '').trim();
    if (variantImage.isNotEmpty) {
      final exact = images.indexOf(variantImage);
      if (exact >= 0) return exact;
    }

    if (_selectedImageIndex >= 0 && _selectedImageIndex < images.length) {
      return _selectedImageIndex;
    }

    return 0;
  }

  void selectVariant(ProductVariant variant) {
    _selectedVariant = variant;
    _selectedImageIndex = _resolveImageIndexForVariant(variant);
    notifyListeners();
  }

  void setImageIndex(int index) {
    if (index < 0 || index >= displayImages.length) return;
    _selectedImageIndex = index;
    notifyListeners();
  }

  void replaceProduct(Product product) {
    _product = product;
    _selectedVariant = product.variants.isNotEmpty
        ? product.variants.first
        : null;
    _selectedImageIndex = _resolveImageIndexForVariant(_selectedVariant);
    notifyListeners();
  }
}
