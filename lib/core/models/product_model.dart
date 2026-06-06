import 'package:purecuts/core/utils/product_image_contract.dart';
import 'package:purecuts/core/utils/tier_pricing.dart';

class ProductModel {
  final String id;
  final String name;
  final String brand;
  final String productType;
  final int stock;
  final bool manageStock;
  final String category;
  final String categoryName;
  final String parentCategory;
  final String subCategory;
  final String subSubCategory;
  final List<String> selectedCategories;
  final List<String> categoryPathNames;
  final int price;
  final int originalPrice;
  final String? _pricingType;
  final List<PricingTier>? _pricingTiers;
  final String? _variableTierMode;
  final List<PercentagePricingTier>? _variableUniversalTiers;
  final double rating;
  final int reviews;
  final String image;
  final String thumbnailUrl;
  final String fullImageUrl;
  final List<String> additionalImages;
  final List<String> images;
  final String tag;
  final List<String> tags;
  final String size;
  final String deliveryTime;
  final String highlights;
  final String description;
  final String howToUse;
  final String homeSection;
  final bool isPopular;
  final bool isRecommended;
  final bool showInStartFirstOrder;
  final bool showInRecommendedSalon;
  final bool showInMostBought;
  final bool showInPopularProducts;

  String get pricingType => _pricingType ?? '';
  List<PricingTier> get pricingTiers => _pricingTiers ?? const <PricingTier>[];
  String get variableTierMode => _variableTierMode ?? '';
  List<PercentagePricingTier> get variableUniversalTiers =>
      _variableUniversalTiers ?? const <PercentagePricingTier>[];

  const ProductModel({
    required this.id,
    required this.name,
    required this.brand,
    this.productType = '',
    this.stock = 0,
    this.manageStock = true,
    required this.category,
    this.categoryName = '',
    this.parentCategory = '',
    this.subCategory = '',
    this.subSubCategory = '',
    this.selectedCategories = const [],
    this.categoryPathNames = const [],
    required this.price,
    required this.originalPrice,
    String? pricingType,
    List<PricingTier>? pricingTiers,
    String? variableTierMode,
    List<PercentagePricingTier>? variableUniversalTiers,
    required this.rating,
    required this.reviews,
    required this.image,
    this.thumbnailUrl = '',
    this.fullImageUrl = '',
    this.additionalImages = const [],
    this.images = const [],
    this.tag = '',
    this.tags = const [],
    this.size = '',
    this.deliveryTime = '',
    this.highlights = '',
    this.description = '',
    this.howToUse = '',
    this.homeSection = '',
    this.isPopular = false,
    this.isRecommended = false,
    this.showInStartFirstOrder = false,
    this.showInRecommendedSalon = false,
    this.showInMostBought = false,
    this.showInPopularProducts = false,
  }) : _pricingType = pricingType,
       _pricingTiers = pricingTiers,
       _variableTierMode = variableTierMode,
       _variableUniversalTiers = variableUniversalTiers;

  factory ProductModel.fromMap(Map<String, dynamic> map, String id) {
    String stringValue(dynamic value, {String fallback = ''}) {
      final text = (value ?? fallback).toString().trim();
      return text;
    }

    String firstText(dynamic raw, {List<String> preferredKeys = const []}) {
      String pick(dynamic value) {
        if (value == null) return '';
        if (value is String || value is num || value is bool) {
          return value.toString().trim();
        }
        if (value is Map) {
          if (preferredKeys.isNotEmpty) {
            for (final key in preferredKeys) {
              if (!value.containsKey(key)) continue;
              final nested = pick(value[key]);
              if (nested.isNotEmpty) return nested;
            }
          }

          for (final entry in value.entries) {
            final nested = pick(entry.value);
            if (nested.isNotEmpty) return nested;
          }
          return '';
        }
        if (value is Iterable) {
          for (final item in value) {
            final nested = pick(item);
            if (nested.isNotEmpty) return nested;
          }
        }
        return '';
      }

      return pick(raw);
    }

    List<String> toStringList(
      dynamic raw, {
      List<String> preferredKeys = const ['name', 'title', 'label', 'value'],
    }) {
      final values = <String>{};

      void collect(dynamic value) {
        if (value == null) return;

        if (value is String) {
          final text = value.trim();
          if (text.isNotEmpty) values.add(text);
          return;
        }

        if (value is num || value is bool) {
          final text = value.toString().trim();
          if (text.isNotEmpty) values.add(text);
          return;
        }

        if (value is Map) {
          for (final key in preferredKeys) {
            if (!value.containsKey(key)) continue;
            collect(value[key]);
          }

          // If preferred keys did not yield values, fall back to scanning all.
          if (values.isEmpty) {
            for (final entry in value.entries) {
              collect(entry.value);
            }
          }
          return;
        }

        if (value is Iterable) {
          for (final item in value) {
            collect(item);
          }
        }
      }

      collect(raw);
      return values.toList(growable: false);
    }

    bool boolValue(dynamic value, {bool fallback = false}) {
      if (value is bool) return value;
      final text = (value ?? '').toString().trim().toLowerCase();
      if (text.isEmpty) return fallback;
      if (text == 'true' || text == '1' || text == 'yes' || text == 'on') {
        return true;
      }
      if (text == 'false' || text == '0' || text == 'no' || text == 'off') {
        return false;
      }
      return fallback;
    }

    int intValue(dynamic value, {int fallback = 0}) {
      if (value is num) return value.toInt();
      final text = (value ?? '').toString().trim();
      if (text.isEmpty) return fallback;
      final direct = int.tryParse(text);
      if (direct != null) return direct;

      final sanitized = text.replaceAll(RegExp(r'[^0-9.-]'), '');
      if (sanitized.isEmpty) return fallback;
      final parsed = double.tryParse(sanitized);
      return parsed?.toInt() ?? fallback;
    }

    double doubleValue(dynamic value, {double fallback = 0.0}) {
      if (value is num) return value.toDouble();
      final text = (value ?? '').toString().trim();
      if (text.isEmpty) return fallback;

      final direct = double.tryParse(text);
      if (direct != null) return direct;

      final sanitized = text.replaceAll(RegExp(r'[^0-9.-]'), '');
      if (sanitized.isEmpty) return fallback;
      return double.tryParse(sanitized) ?? fallback;
    }

    List<String> parseTagValues(dynamic raw) {
      if (raw == null) return <String>[];

      if (raw is String) {
        return raw
            .split(RegExp(r'[,|/&;]+'))
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      }

      if (raw is Iterable) {
        return raw
            .where((e) => e != null)
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      }

      final single = raw.toString().trim();
      return single.isEmpty ? <String>[] : <String>[single];
    }

    final additionalImages = toStringList(
      map['additionalImages'],
      preferredKeys: const ['url', 'image', 'imageUrl', 'src', 'path', 'name'],
    );
    final images = toStringList(
      map['images'],
      preferredKeys: const ['url', 'image', 'imageUrl', 'src', 'path', 'name'],
    );
    final parsedTags = parseTagValues(map['tags']);
    final singleTag = stringValue(map['tag']);
    final tags = <String>{...parsedTags};
    if (singleTag.isNotEmpty) tags.add(singleTag);

    final thumbnail = resolveThumbnailImage(map);
    final fullImage = resolveFullImage(map);
    final listImage = thumbnail.isNotEmpty
        ? thumbnail
        : (fullImage.isNotEmpty
              ? fullImage
              : (images.isNotEmpty
                    ? images.first
                    : (additionalImages.isNotEmpty
                          ? additionalImages.first
                          : '')));

    return ProductModel(
      id: id,
      name: stringValue(map['name'] ?? map['title'] ?? map['productName']),
      brand: stringValue(
        map['brand'] ?? map['brandName'] ?? map['manufacturer'],
      ),
      productType: stringValue(map['productType'] ?? map['type']),
      stock: intValue(
        map['stock'] ??
            map['quantity'] ??
            map['qty'] ??
            map['inventory'] ??
            map['stockCount'],
      ),
      manageStock: boolValue(map['manageStock'], fallback: true),
      category: firstText(
        map['category'] ?? map['categoryName'],
        preferredKeys: const ['name', 'title', 'label', 'value'],
      ),
      categoryName: firstText(
        map['categoryName'] ?? map['category'],
        preferredKeys: const ['name', 'title', 'label', 'value'],
      ),
      parentCategory: firstText(
        map['parentCategory'],
        preferredKeys: const ['name', 'title', 'label', 'value'],
      ),
      subCategory: firstText(
        map['subCategory'] ??
            map['subcategory'] ??
            map['sub_category'] ??
            map['selectedSubCategory'] ??
            map['subCategoryName'],
        preferredKeys: const ['name', 'title', 'label', 'value'],
      ),
      subSubCategory: firstText(
        map['subSubCategory'] ??
            map['subsubCategory'] ??
            map['sub_sub_category'] ??
            map['selectedSubSubCategory'] ??
            map['subSubCategoryName'],
        preferredKeys: const ['name', 'title', 'label', 'value'],
      ),
      selectedCategories: toStringList(
        map['selectedCategories'],
        preferredKeys: const [
          'name',
          'title',
          'label',
          'value',
          'category',
          'categoryName',
          'parentCategory',
          'subCategory',
          'subSubCategory',
        ],
      ),
      categoryPathNames: toStringList(
        map['categoryPathNames'],
        preferredKeys: const [
          'name',
          'title',
          'label',
          'value',
          'category',
          'categoryName',
          'parentCategory',
          'subCategory',
          'subSubCategory',
        ],
      ),
      price: intValue(map['price']),
      originalPrice: intValue(map['originalPrice']),
      pricingType: stringValue(map['pricingType']),
      pricingTiers: parsePricingTiers(map['pricingTiers']),
      variableTierMode: stringValue(map['variableTierMode']),
      variableUniversalTiers: parsePercentagePricingTiers(
        map['variableUniversalTiers'],
      ),
      rating: doubleValue(map['rating']),
      reviews: intValue(map['reviews']),
      image: listImage,
      thumbnailUrl: thumbnail,
      fullImageUrl: fullImage,
      additionalImages: additionalImages,
      images: images,
      tag: singleTag,
      tags: tags.toList(growable: false),
      size: stringValue(map['size']),
      deliveryTime: stringValue(map['deliveryTime']),
      highlights: stringValue(map['highlights'] ?? map['shortDescription']),
      description: stringValue(
        map['description'] ?? map['shortDescription'] ?? map['highlights'],
      ),
      howToUse: stringValue(
        map['howToUse'] ?? map['how_to_use'] ?? map['usage'],
      ),
      homeSection: stringValue(
        map['homeSection'] ?? map['home_section'] ?? map['section'],
      ),
      isPopular: boolValue(map['isPopular']),
      isRecommended: boolValue(map['isRecommended']),
      showInStartFirstOrder: boolValue(map['showInStartFirstOrder']),
      showInRecommendedSalon: boolValue(map['showInRecommendedSalon']),
      showInMostBought: boolValue(map['showInMostBought']),
      showInPopularProducts: boolValue(map['showInPopularProducts']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'brand': brand,
      'productType': productType,
      'stock': stock,
      'manageStock': manageStock,
      'category': category,
      'categoryName': categoryName,
      'parentCategory': parentCategory,
      'subCategory': subCategory,
      'subSubCategory': subSubCategory,
      'subsubCategory': subSubCategory,
      'sub_sub_category': subSubCategory,
      'selectedCategories': selectedCategories,
      'categoryPathNames': categoryPathNames,
      'price': price,
      'originalPrice': originalPrice,
      'pricingType': pricingType,
      'pricingTiers': pricingTiers
          .map((tier) => tier.toMap())
          .toList(growable: false),
      'variableTierMode': variableTierMode,
      'variableUniversalTiers': variableUniversalTiers
          .map((tier) => tier.toMap())
          .toList(growable: false),
      'rating': rating,
      'reviews': reviews,
      'image': image,
      'thumbnailUrl': thumbnailUrl,
      'thumbnail': thumbnailUrl,
      'thumb': thumbnailUrl,
      'fullImageUrl': fullImageUrl,
      'additionalImages': additionalImages,
      'images': images,
      'tag': tag,
      'tags': tags,
      'size': size,
      'deliveryTime': deliveryTime,
      'highlights': highlights,
      'description': description,
      'howToUse': howToUse,
      'how_to_use': howToUse,
      'usage': howToUse,
      'homeSection': homeSection,
      'isPopular': isPopular,
      'isRecommended': isRecommended,
      'showInStartFirstOrder': showInStartFirstOrder,
      'showInRecommendedSalon': showInRecommendedSalon,
      'showInMostBought': showInMostBought,
      'showInPopularProducts': showInPopularProducts,
    };
  }

  /// Convert to the legacy product map format used by widgets/cart.
  Map<String, dynamic> toProductMap() {
    return {
      'id': id,
      'name': name,
      'brand': brand,
      'productType': productType,
      'stock': stock,
      'manageStock': manageStock,
      'category': category,
      'categoryName': categoryName,
      'parentCategory': parentCategory,
      'subCategory': subCategory,
      'subSubCategory': subSubCategory,
      'subsubCategory': subSubCategory,
      'sub_sub_category': subSubCategory,
      'selectedCategories': selectedCategories,
      'categoryPathNames': categoryPathNames,
      'price': price,
      'originalPrice': originalPrice,
      'pricingType': pricingType,
      'pricingTiers': pricingTiers
          .map((tier) => tier.toMap())
          .toList(growable: false),
      'variableTierMode': variableTierMode,
      'variableUniversalTiers': variableUniversalTiers
          .map((tier) => tier.toMap())
          .toList(growable: false),
      'rating': rating,
      'reviews': reviews,
      'image': image,
      'imageUrl': fullImageUrl.isNotEmpty ? fullImageUrl : image,
      'thumbnailUrl': thumbnailUrl,
      'thumbnail': thumbnailUrl,
      'thumb': thumbnailUrl,
      'fullImageUrl': fullImageUrl,
      'additionalImages': additionalImages,
      'images': images,
      'tag': tag,
      'tags': tags,
      'size': size,
      'deliveryTime': deliveryTime,
      'highlights': highlights,
      'description': description,
      'howToUse': howToUse,
      'how_to_use': howToUse,
      'usage': howToUse,
      'homeSection': homeSection,
      'isPopular': isPopular,
      'isRecommended': isRecommended,
      'showInStartFirstOrder': showInStartFirstOrder,
      'showInRecommendedSalon': showInRecommendedSalon,
      'showInMostBought': showInMostBought,
      'showInPopularProducts': showInPopularProducts,
    };
  }
}
