import 'package:flutter/material.dart';
import 'package:purecuts/core/theme/app_theme.dart';

import 'product_models.dart';

class VariantSelector extends StatelessWidget {
  final List<ProductVariant> variants;
  final ProductVariant? selectedVariant;
  final ValueChanged<ProductVariant> onVariantSelected;

  const VariantSelector({
    super.key,
    required this.variants,
    required this.selectedVariant,
    required this.onVariantSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (variants.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: variants.map((variant) {
        final isSelected = selectedVariant?.id == variant.id;

        return GestureDetector(
          onTap: variant.inStock ? () => onVariantSelected(variant) : null,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 160),
            scale: isSelected ? 1.04 : 1.0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected ? AppColors.primary : AppColors.border,
                  width: isSelected ? 2 : 1,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: AppColors.primary.withOpacity(0.15),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Color circle with check overlay when selected
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: isSelected ? 32 : 28,
                        height: isSelected ? 32 : 28,
                        decoration: BoxDecoration(
                          color: variant.color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.black.withOpacity(0.08),
                            width: 1,
                          ),
                        ),
                      ),
                      if (isSelected)
                        const Icon(
                          Icons.check_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                      // Out-of-stock strike-through line
                      if (!variant.inStock)
                        Positioned.fill(
                          child: CustomPaint(painter: _StrikethroughPainter()),
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  // Shade name
                  SizedBox(
                    width: 64,
                    child: Text(
                      variant.shadeName,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: isSelected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: isSelected
                            ? AppColors.primary
                            : variant.inStock
                            ? AppColors.textSecondary
                            : AppColors.textHint,
                        height: 1.2,
                      ),
                    ),
                  ),
                  // Sold out label
                  if (!variant.inStock)
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Text(
                        'Sold Out',
                        style: TextStyle(
                          color: AppColors.error,
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// Draws a diagonal line across the color circle for out-of-stock variants.
class _StrikethroughPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.85)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * 0.2, size.height * 0.8),
      Offset(size.width * 0.8, size.height * 0.2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
