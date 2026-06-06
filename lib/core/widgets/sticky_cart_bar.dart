import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/models/cart_model.dart';
import '../../core/theme/app_theme.dart';
import '../../features/orders/checkout_screen.dart';

class StickyCartBar extends StatefulWidget {
  const StickyCartBar({super.key});

  @override
  State<StickyCartBar> createState() => _StickyCartBarState();
}

class _StickyCartBarState extends State<StickyCartBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _feedbackController;
  CartModel? _listenedCart;
  int _lastHandledTick = 0;
  String? _highlightProductId;

  @override
  void initState() {
    super.initState();
    _feedbackController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final cart = context.read<CartModel>();
    if (_listenedCart == cart) return;
    _listenedCart?.removeListener(_onCartChanged);
    _listenedCart = cart;
    _lastHandledTick = cart.addEventTick;
    cart.addListener(_onCartChanged);
  }

  void _onCartChanged() {
    final cart = _listenedCart;
    if (cart == null || !mounted) return;
    if (cart.addEventTick <= _lastHandledTick) return;

    _lastHandledTick = cart.addEventTick;
    _highlightProductId = cart.lastAddedProductId;
    _feedbackController.forward(from: 0);
    setState(() {});

    Future<void>.delayed(const Duration(milliseconds: 420), () {
      if (!mounted) return;
      setState(() => _highlightProductId = null);
    });
  }

  @override
  void dispose() {
    _listenedCart?.removeListener(_onCartChanged);
    _feedbackController.dispose();
    super.dispose();
  }

  Widget _previewCluster(List<CartItem> previews) {
    if (previews.isEmpty) {
      return Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(17),
        ),
        child: const Icon(
          Icons.shopping_bag_outlined,
          color: AppColors.primary,
          size: 17,
        ),
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) {
        final slide = Tween<Offset>(
          begin: const Offset(0.12, 0),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: slide, child: child),
        );
      },
      child: Row(
        key: ValueKey<String>(previews.map((e) => e.id).join('|')),
        mainAxisSize: MainAxisSize.min,
        children: List.generate(previews.length, (index) {
          final item = previews[index];
          final isHighlighted = item.id == _highlightProductId;
          final slotWidth = index == 0 ? 34.0 : 25.0;

          return SizedBox(
            width: slotWidth,
            child: Align(
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(17),
                  border: Border.all(
                    color: isHighlighted
                        ? Colors.white.withValues(alpha: 0.95)
                        : Colors.white.withValues(alpha: 0.80),
                    width: isHighlighted ? 1.8 : 1.2,
                  ),
                  boxShadow: isHighlighted
                      ? [
                          BoxShadow(
                            color: Colors.white.withValues(alpha: 0.35),
                            blurRadius: 9,
                            spreadRadius: 0.2,
                          ),
                        ]
                      : null,
                ),
                clipBehavior: Clip.antiAlias,
                child: CachedNetworkImage(
                  imageUrl: item.image,
                  fit: BoxFit.cover,
                  fadeInDuration: Duration.zero,
                  fadeOutDuration: Duration.zero,
                  memCacheWidth: 68,
                  maxWidthDiskCache: 68,
                  errorWidget: (_, error, stackTrace) => const Icon(
                    Icons.shopping_bag_outlined,
                    color: AppColors.primary,
                    size: 17,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<CartModel>(
      builder: (context, cart, _) {
        if (cart.itemCount == 0) return const SizedBox.shrink();
        final previews = cart.previewItems;
        final isEditMode = cart.isEditSessionActive;
        final itemLabel = cart.itemCount == 1
            ? '1 item'
            : '${cart.itemCount} items';

        return AnimatedBuilder(
          animation: _feedbackController,
          builder: (_, child) {
            final t = _feedbackController.value;
            final shake = math.sin(t * math.pi * 8) * 3.0 * (1 - t);
            final scaleX = 1 + (0.06 * math.sin(t * math.pi));

            return Transform.translate(
              offset: Offset(shake, 0),
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(scaleX, 1, 1),
                child: child,
              ),
            );
          },
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 8),
            child: SizedBox(
              height: 64,
              child: Center(
                child: GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const CheckoutScreen()),
                  ),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(11, 7, 11, 7),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [Color(0xFF5C138B), Color(0xFF5C138B)],
                      ),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(
                            0xFF5C138B,
                          ).withValues(alpha: 0.28),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _previewCluster(previews),
                        const SizedBox(width: 9),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isEditMode ? 'Edit order' : 'View cart',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                height: 1,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              isEditMode
                                  ? '$itemLabel in edit cart'
                                  : itemLabel,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.9),
                                fontWeight: FontWeight.w500,
                                fontSize: 11,
                                height: 1.1,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 7),
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(
                            Icons.arrow_forward_ios_rounded,
                            color: Colors.white,
                            size: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
