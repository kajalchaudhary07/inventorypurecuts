import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:purecuts/core/theme/app_theme.dart';

class SubSubCategoryBottomSheet extends StatelessWidget {
  const SubSubCategoryBottomSheet({
    super.key,
    required this.title,
    required this.items,
    this.selected,
  });

  final String title;
  final List<Map<String, dynamic>> items;
  final String? selected;

  String _normalized(String value) => value.trim().toLowerCase();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 460),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 8),
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD1D5DB),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Text(
                title,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Divider(height: 1, thickness: 1, color: Color(0xFFF0F2F6)),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                itemCount: items.length + 1,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (_, i) {
                  final isAll = i == 0;
                  final name = isAll
                      ? 'All'
                      : (items[i - 1]['name'] ?? '').toString().trim();
                  final iconPath = isAll
                      ? ''
                      : (items[i - 1]['icon'] ?? items[i - 1]['image'] ?? '')
                            .toString();

                  final isSelected = isAll
                      ? (selected ?? '').trim().isEmpty
                      : _normalized(name) == _normalized(selected ?? '');

                  return Material(
                    color: isSelected
                        ? const Color(0xFFEFF8E4)
                        : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Navigator.pop(context, isAll ? null : name),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(9),
                                border: Border.all(
                                  color: const Color(0xFFE5E7EB),
                                ),
                              ),
                              child: Center(
                                child: _ThumbIcon(path: iconPath, size: 18),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                name,
                                style: TextStyle(
                                  color: isSelected
                                      ? AppColors.success
                                      : AppColors.textPrimary,
                                  fontSize: 13,
                                  fontWeight: isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                ),
                              ),
                            ),
                            if (isSelected)
                              const Icon(
                                Icons.check_circle,
                                color: AppColors.success,
                                size: 18,
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThumbIcon extends StatelessWidget {
  const _ThumbIcon({required this.path, this.size = 20});

  final String path;
  final double size;

  @override
  Widget build(BuildContext context) {
    const fallback = Icon(
      Icons.category_outlined,
      size: 16,
      color: AppColors.textSecondary,
    );

    final trimmed = path.trim();
    if (trimmed.isEmpty) return fallback;

    if (trimmed.startsWith('assets/')) {
      return Image.asset(
        trimmed,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => fallback,
      );
    }

    return CachedNetworkImage(
      imageUrl: trimmed,
      width: size,
      height: size,
      fit: BoxFit.contain,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      memCacheWidth: (size * 2).round(),
      maxWidthDiskCache: (size * 2).round(),
      errorWidget: (_, __, ___) => fallback,
    );
  }
}
