class PricingTier {
  final int minQty;
  final int? maxQty;
  final int price;

  const PricingTier({required this.minQty, this.maxQty, required this.price});

  Map<String, dynamic> toMap() => {
    'minQty': minQty,
    'maxQty': maxQty,
    'price': price,
  };
}

class PercentagePricingTier {
  final int minQty;
  final int? maxQty;
  final double percentOff;

  const PercentagePricingTier({
    required this.minQty,
    this.maxQty,
    required this.percentOff,
  });

  Map<String, dynamic> toMap() => {
    'minQty': minQty,
    'maxQty': maxQty,
    'percentOff': percentOff,
  };
}

int _toInt(dynamic value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  final text = (value ?? '').toString().trim();
  if (text.isEmpty) return fallback;

  final direct = int.tryParse(text);
  if (direct != null) return direct;

  final parsed = double.tryParse(text.replaceAll(RegExp(r'[^0-9.-]'), ''));
  return parsed?.toInt() ?? fallback;
}

double _toDouble(dynamic value, {double fallback = 0}) {
  if (value is num) return value.toDouble();
  final text = (value ?? '').toString().trim();
  if (text.isEmpty) return fallback;

  final direct = double.tryParse(text);
  if (direct != null) return direct;

  final parsed = double.tryParse(text.replaceAll(RegExp(r'[^0-9.-]'), ''));
  return parsed ?? fallback;
}

List<PricingTier> normalizePricingTiers(Iterable<PricingTier> tiers) {
  final byMinQty = <int, PricingTier>{};

  for (final tier in tiers) {
    if (tier.minQty < 1) continue;
    if (tier.price < 0) continue;

    final rawMax = tier.maxQty;
    final safeMax = rawMax == null
        ? null
        : (rawMax < tier.minQty ? tier.minQty : rawMax);
    final normalized = PricingTier(
      minQty: tier.minQty,
      maxQty: safeMax,
      price: tier.price,
    );

    final existing = byMinQty[tier.minQty];
    if (existing == null || normalized.price < existing.price) {
      byMinQty[tier.minQty] = normalized;
    }
  }

  final sorted = byMinQty.values.toList(growable: false)
    ..sort((a, b) => a.minQty.compareTo(b.minQty));

  final normalizedRanges = <PricingTier>[];
  for (var i = 0; i < sorted.length; i++) {
    final current = sorted[i];
    final next = i + 1 < sorted.length ? sorted[i + 1] : null;

    final inferredMax = next == null ? null : (next.minQty - 1);
    int? effectiveMax = current.maxQty;

    if (effectiveMax != null &&
        inferredMax != null &&
        effectiveMax > inferredMax) {
      effectiveMax = inferredMax;
    }

    if (effectiveMax == null && inferredMax != null) {
      effectiveMax = inferredMax;
    }

    if (effectiveMax != null && effectiveMax < current.minQty) {
      effectiveMax = current.minQty;
    }

    normalizedRanges.add(
      PricingTier(
        minQty: current.minQty,
        maxQty: effectiveMax,
        price: current.price,
      ),
    );
  }

  return List<PricingTier>.unmodifiable(normalizedRanges);
}

List<PricingTier> parsePricingTiers(dynamic raw) {
  if (raw is! Iterable) return const <PricingTier>[];

  final parsed = <PricingTier>[];
  for (final item in raw) {
    if (item is Map<String, dynamic>) {
      parsed.add(
        PricingTier(
          minQty: _toInt(item['minQty']),
          maxQty: item['maxQty'] == null ? null : _toInt(item['maxQty']),
          price: _toInt(item['price']),
        ),
      );
      continue;
    }

    if (item is Map) {
      parsed.add(
        PricingTier(
          minQty: _toInt(item['minQty']),
          maxQty: item['maxQty'] == null ? null : _toInt(item['maxQty']),
          price: _toInt(item['price']),
        ),
      );
    }
  }

  return normalizePricingTiers(parsed);
}

List<PercentagePricingTier> normalizePercentagePricingTiers(
  Iterable<PercentagePricingTier> tiers,
) {
  final byMinQty = <int, PercentagePricingTier>{};

  for (final tier in tiers) {
    if (tier.minQty < 1) continue;
    if (tier.percentOff < 0) continue;

    final normalizedPercent = tier.percentOff > 100 ? 100.0 : tier.percentOff;
    final rawMax = tier.maxQty;
    final safeMax = rawMax == null
        ? null
        : (rawMax < tier.minQty ? tier.minQty : rawMax);

    final normalized = PercentagePricingTier(
      minQty: tier.minQty,
      maxQty: safeMax,
      percentOff: normalizedPercent,
    );

    final existing = byMinQty[tier.minQty];
    if (existing == null || normalized.percentOff > existing.percentOff) {
      byMinQty[tier.minQty] = normalized;
    }
  }

  final sorted = byMinQty.values.toList(growable: false)
    ..sort((a, b) => a.minQty.compareTo(b.minQty));

  final normalizedRanges = <PercentagePricingTier>[];
  for (var i = 0; i < sorted.length; i++) {
    final current = sorted[i];
    final next = i + 1 < sorted.length ? sorted[i + 1] : null;

    final inferredMax = next == null ? null : (next.minQty - 1);
    int? effectiveMax = current.maxQty;

    if (effectiveMax != null &&
        inferredMax != null &&
        effectiveMax > inferredMax) {
      effectiveMax = inferredMax;
    }

    if (effectiveMax == null && inferredMax != null) {
      effectiveMax = inferredMax;
    }

    if (effectiveMax != null && effectiveMax < current.minQty) {
      effectiveMax = current.minQty;
    }

    normalizedRanges.add(
      PercentagePricingTier(
        minQty: current.minQty,
        maxQty: effectiveMax,
        percentOff: current.percentOff,
      ),
    );
  }

  return List<PercentagePricingTier>.unmodifiable(normalizedRanges);
}

List<PercentagePricingTier> parsePercentagePricingTiers(dynamic raw) {
  if (raw is! Iterable) return const <PercentagePricingTier>[];

  final parsed = <PercentagePricingTier>[];
  for (final item in raw) {
    if (item is Map<String, dynamic>) {
      parsed.add(
        PercentagePricingTier(
          minQty: _toInt(item['minQty']),
          maxQty: item['maxQty'] == null ? null : _toInt(item['maxQty']),
          percentOff: _toDouble(item['percentOff']),
        ),
      );
      continue;
    }

    if (item is Map) {
      parsed.add(
        PercentagePricingTier(
          minQty: _toInt(item['minQty']),
          maxQty: item['maxQty'] == null ? null : _toInt(item['maxQty']),
          percentOff: _toDouble(item['percentOff']),
        ),
      );
    }
  }

  return normalizePercentagePricingTiers(parsed);
}

List<PricingTier> derivePricingTiersFromPercentage({
  required int basePrice,
  required Iterable<PercentagePricingTier> percentageTiers,
}) {
  final safeBase = basePrice < 0 ? 0 : basePrice;
  final normalized = normalizePercentagePricingTiers(percentageTiers);
  if (normalized.isEmpty) return const <PricingTier>[];

  final derived = normalized
      .map((tier) {
        final safePercent = tier.percentOff < 0
            ? 0
            : (tier.percentOff > 100 ? 100 : tier.percentOff);
        final discounted = (safeBase * ((100 - safePercent) / 100)).round();
        final safePrice = discounted < 0 ? 0 : discounted;
        return PricingTier(
          minQty: tier.minQty,
          maxQty: tier.maxQty,
          price: safePrice,
        );
      })
      .toList(growable: false);

  return normalizePricingTiers(derived);
}

int tierIndexForQuantity({
  required int quantity,
  required Iterable<PricingTier> pricingTiers,
}) {
  final safeQty = quantity < 1 ? 1 : quantity;
  final tiers = normalizePricingTiers(pricingTiers);
  if (tiers.isEmpty) return -1;

  var fallbackIndex = -1;
  for (var i = 0; i < tiers.length; i++) {
    final tier = tiers[i];
    final inRange =
        safeQty >= tier.minQty &&
        (tier.maxQty == null || safeQty <= tier.maxQty!);
    if (inRange) return i;

    if (safeQty >= tier.minQty) fallbackIndex = i;
  }

  return fallbackIndex;
}

PricingTier? activePricingTier({
  required int quantity,
  required Iterable<PricingTier> pricingTiers,
}) {
  final tiers = normalizePricingTiers(pricingTiers);
  final idx = tierIndexForQuantity(quantity: quantity, pricingTiers: tiers);
  if (idx < 0 || idx >= tiers.length) return null;
  return tiers[idx];
}

int unitPriceForQuantity({
  required int quantity,
  required int basePrice,
  required Iterable<PricingTier> pricingTiers,
}) {
  final safeQty = quantity < 1 ? 1 : quantity;
  final tiers = normalizePricingTiers(pricingTiers);
  if (tiers.isEmpty) return basePrice;

  var resolved = basePrice;
  for (final tier in tiers) {
    if (safeQty >= tier.minQty) {
      resolved = tier.price;
    } else {
      break;
    }
  }

  return resolved;
}

PricingTier? nextPricingTier({
  required int quantity,
  required Iterable<PricingTier> pricingTiers,
}) {
  final safeQty = quantity < 1 ? 1 : quantity;
  final tiers = normalizePricingTiers(pricingTiers);
  for (final tier in tiers) {
    if (tier.minQty > safeQty) return tier;
  }

  return null;
}

String tierRangeLabel(PricingTier tier) {
  final max = tier.maxQty;
  if (max == null) return '${tier.minQty}+';
  if (max <= tier.minQty) return '${tier.minQty}';
  return '${tier.minQty}-${max}';
}

int savingsForQuantity({
  required int quantity,
  required int basePrice,
  required int unitPrice,
}) {
  final safeQty = quantity < 1 ? 1 : quantity;
  final perUnit = basePrice - unitPrice;
  if (perUnit <= 0) return 0;
  return perUnit * safeQty;
}
