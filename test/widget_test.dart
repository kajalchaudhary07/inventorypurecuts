import 'package:flutter_test/flutter_test.dart';
import 'package:purecuts/features/products/detail/product_models.dart';

void main() {
  test('ProductVariant parses hex color and stock state', () {
    final variant = ProductVariant.fromMap('v1', {
      'name': 'Ebony',
      'colorCode': '#112233',
      'price': 249,
      'image': 'assets/products/ebony.png',
      'stock': 5,
    });

    expect(variant.id, 'v1');
    expect(variant.shadeName, 'Ebony');
    expect(variant.price, 249);
    expect(variant.inStock, isTrue);
    expect(variant.color.value, 0xFF112233);
  });

  test('Product merges image list with fallback image and computes defaults', () {
    final product = Product.fromMap('p1', {
      'name': 'Pro Color',
      'brand': 'Matrix',
      'images': ['a.png', 'b.png'],
      'image': 'hero.png',
      'rating': 4.6,
      'reviewCount': 12,
    });

    expect(product.id, 'p1');
    expect(product.images, containsAll(['a.png', 'b.png', 'hero.png']));
    expect(product.rating, 4.6);
    expect(product.reviewCount, 12);
  });
}
