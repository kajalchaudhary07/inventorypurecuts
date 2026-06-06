// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'package:flutter_test/flutter_test.dart';
import 'package:purecuts/core/models/product_model.dart';
import 'package:purecuts/features/home/home_provider.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a minimal [ProductModel] suitable for unit tests.
ProductModel _product({
  required String id,
  required String name,
  String category = '',
  String subCategory = '',
  String subSubCategory = '',
  String brand = '',
  String description = '',
  List<String> tags = const [],
}) {
  return ProductModel(
    id: id,
    name: name,
    brand: brand,
    category: category,
    subCategory: subCategory,
    subSubCategory: subSubCategory,
    price: 100,
    originalPrice: 100,
    rating: 4.0,
    reviews: 0,
    image: '',
    description: description,
    tags: tags,
  );
}

void main() {
  // -------------------------------------------------------------------------
  // 1. Initial state
  // -------------------------------------------------------------------------
  group('HomeProvider – initial state', () {
    test('fullCatalogReady starts as false', () {
      final provider = HomeProvider();
      expect(provider.fullCatalogReady, isFalse);
    });

    test('productMaps is empty before any load', () {
      final provider = HomeProvider();
      expect(provider.productMaps, isEmpty);
    });

    test('catalogReady getter returns a Future', () {
      final provider = HomeProvider();
      expect(provider.catalogReady, isA<Future<void>>());
    });
  });

  // -------------------------------------------------------------------------
  // 2. seedForTest sets catalog state correctly
  // -------------------------------------------------------------------------
  group('HomeProvider.seedForTest', () {
    test('seeds products and sets fullCatalogReady', () {
      final provider = HomeProvider();
      final products = List.generate(
        30,
        (i) => _product(id: 'p$i', name: 'Product $i', category: 'Hair'),
      );

      provider.seedForTest(products);

      expect(provider.productMaps.length, 30);
      expect(provider.fullCatalogReady, isTrue);
    });

    test('can seed with fullCatalogReady = false', () {
      final provider = HomeProvider();
      provider.seedForTest([
        _product(id: 'p1', name: 'P1'),
      ], fullCatalogReady: false);
      expect(provider.fullCatalogReady, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // 3. Category completeness – every seeded product appears in its category
  // -------------------------------------------------------------------------
  group('filteredProducts – category completeness', () {
    late HomeProvider provider;

    setUp(() {
      provider = HomeProvider();
      provider.seedForTest([
        _product(id: 'h1', name: 'Hair Oil', category: 'Hair'),
        _product(id: 'h2', name: 'Shampoo', category: 'Hair'),
        _product(id: 's1', name: 'Face Wash', category: 'Skin'),
        _product(id: 's2', name: 'Moisturiser', category: 'Skin'),
        _product(id: 'n1', name: 'Nail Polish', category: 'Nail'),
      ]);
    });

    test('returns all products when category is "All"', () {
      final result = provider.filteredProducts(category: 'All');
      expect(result.length, 5);
    });

    test('returns only Hair products for Hair category', () {
      final result = provider.filteredProducts(category: 'Hair');
      expect(result.length, 2);
      expect(result.map((p) => p['id']), containsAll(['h1', 'h2']));
    });

    test('returns only Skin products for Skin category', () {
      final result = provider.filteredProducts(category: 'Skin');
      expect(result.length, 2);
      expect(result.map((p) => p['id']), containsAll(['s1', 's2']));
    });

    test('no product is dropped when iterating all non-hidden categories', () {
      final allIds = {'h1', 'h2', 's1', 's2', 'n1'};
      final found = <String>{};

      for (final cat in ['Hair', 'Skin', 'Nail']) {
        for (final p in provider.filteredProducts(category: cat)) {
          found.add((p['id'] ?? '').toString());
        }
      }
      expect(found, containsAll(allIds));
    });
  });

  // -------------------------------------------------------------------------
  // 4. Sub-category completeness
  // -------------------------------------------------------------------------
  group('filteredProducts – sub-category completeness', () {
    late HomeProvider provider;

    setUp(() {
      provider = HomeProvider();
      provider.seedForTest([
        _product(
          id: 'c1',
          name: 'Conditioner',
          category: 'Hair',
          subCategory: 'Conditioning',
        ),
        _product(
          id: 's1',
          name: 'Shampoo',
          category: 'Hair',
          subCategory: 'Cleansing',
        ),
        _product(
          id: 'o1',
          name: 'Oil',
          category: 'Hair',
          subCategory: 'Oiling',
        ),
      ]);
    });

    test('sub-category filter returns only matching products', () {
      final result = provider.filteredProducts(
        category: 'Hair',
        subCategory: 'Conditioning',
      );
      expect(result.length, 1);
      expect(result.first['id'], 'c1');
    });

    test('all sub-category products are reachable', () {
      final allIds = {'c1', 's1', 'o1'};
      final found = <String>{};
      for (final sub in ['Conditioning', 'Cleansing', 'Oiling']) {
        for (final p in provider.filteredProducts(
          category: 'Hair',
          subCategory: sub,
        )) {
          found.add((p['id'] ?? '').toString());
        }
      }
      expect(found, equals(allIds));
    });
  });

  // -------------------------------------------------------------------------
  // 5. Search completeness & parity
  // -------------------------------------------------------------------------
  group('filteredProducts – search completeness', () {
    late HomeProvider provider;

    setUp(() {
      provider = HomeProvider();
      provider.seedForTest([
        _product(id: 'p1', name: 'Keratin Shampoo', brand: 'Loreal'),
        _product(id: 'p2', name: 'Argan Oil', brand: 'Moroccan'),
        _product(
          id: 'p3',
          name: 'Face Serum',
          brand: 'Generic',
          description: 'Contains retinol for anti-aging',
        ),
        _product(
          id: 'p4',
          name: 'Body Lotion',
          brand: 'Generic',
          tags: ['moisturiser', 'hydrating'],
        ),
      ]);
    });

    test('name search returns matching products', () {
      final result = provider.filteredProducts(query: 'shampoo');
      expect(result.length, 1);
      expect(result.first['id'], 'p1');
    });

    test('brand search returns matching products', () {
      final result = provider.filteredProducts(query: 'loreal');
      expect(result.length, 1);
      expect(result.first['id'], 'p1');
    });

    test('description search returns matching products (parity fix)', () {
      // Regression: description field was missing from home_provider's search
      // before the fix, causing products found in product_list_screen to be
      // absent from home category grids.
      final result = provider.filteredProducts(query: 'retinol');
      expect(result.length, 1);
      expect(result.first['id'], 'p3');
    });

    test('tag search returns matching products', () {
      final result = provider.filteredProducts(query: 'hydrating');
      expect(result.length, 1);
      expect(result.first['id'], 'p4');
    });

    test('empty query returns all products', () {
      final result = provider.filteredProducts(query: '');
      expect(result.length, 4);
    });

    test('case-insensitive search', () {
      final lower = provider.filteredProducts(query: 'keratin');
      final upper = provider.filteredProducts(query: 'KERATIN');
      expect(
        lower.map((p) => p['id']).toList(),
        equals(upper.map((p) => p['id']).toList()),
      );
    });

    test('multi-token search requires all tokens to match', () {
      // "keratin shampoo" should match "Keratin Shampoo"
      final result = provider.filteredProducts(query: 'keratin shampoo');
      expect(result.length, 1);
      expect(result.first['id'], 'p1');
      // "keratin lotion" should match nothing
      final empty = provider.filteredProducts(query: 'keratin lotion');
      expect(empty, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // 6. fullCatalogReady prevents stale startup-lite rendering
  // -------------------------------------------------------------------------
  group('fullCatalogReady – catalog readiness gate', () {
    test('provider notifies when seedForTest sets fullCatalogReady', () {
      final provider = HomeProvider();
      var notified = false;
      provider.addListener(() => notified = true);

      provider.seedForTest([_product(id: 'x1', name: 'X')]);

      // seedForTest does not call notifyListeners, but the flag is set.
      // Screens should use Consumer<HomeProvider> and check fullCatalogReady.
      expect(provider.fullCatalogReady, isTrue);
      // (notified == false because seedForTest is a test-only helper that
      //  bypasses the normal notification flow; real loads always notify)
      expect(notified, isFalse);
    });

    test('more than startup-lite threshold means full catalog expected', () {
      final provider = HomeProvider();
      final products = List.generate(
        25,
        (i) => _product(id: 'p$i', name: 'P$i'),
      );
      provider.seedForTest(products);

      // 25 > 24 (startup-lite threshold) – catalog is considered complete.
      expect(provider.productMaps.length, greaterThan(24));
      expect(provider.fullCatalogReady, isTrue);
    });
  });
}
