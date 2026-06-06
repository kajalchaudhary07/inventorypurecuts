String _cleanImageValue(dynamic value) {
  final text = (value ?? '').toString().trim();
  return text;
}

List<String> _toImageList(dynamic raw) {
  if (raw is! Iterable) return const <String>[];
  final values = <String>[];
  for (final item in raw) {
    final candidate = _cleanImageValue(item);
    if (candidate.isNotEmpty) values.add(candidate);
  }
  return values;
}

String resolveThumbnailImage(Map<String, dynamic> product) {
  final candidates = [
    product['thumbnailUrl'],
    product['thumbnail'],
    product['thumb'],
    product['imageThumb'],
    product['smallImage'],
  ];

  for (final raw in candidates) {
    final value = _cleanImageValue(raw);
    if (value.isNotEmpty) return value;
  }
  return '';
}

String resolveFullImage(Map<String, dynamic> product) {
  final candidates = [
    product['fullImageUrl'],
    product['fullImage'],
    product['largeImage'],
    product['imageUrl'],
    product['image'],
  ];

  for (final raw in candidates) {
    final value = _cleanImageValue(raw);
    if (value.isNotEmpty) return value;
  }
  return '';
}

String resolveListImage(Map<String, dynamic> product) {
  final thumbnail = resolveThumbnailImage(product);
  if (thumbnail.isNotEmpty) return thumbnail;

  final full = resolveFullImage(product);
  if (full.isNotEmpty) return full;

  final images = _toImageList(product['images']);
  if (images.isNotEmpty) return images.first;

  final additional = _toImageList(product['additionalImages']);
  if (additional.isNotEmpty) return additional.first;

  return '';
}
