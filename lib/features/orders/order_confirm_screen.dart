// lib/features/orders/order_confirm_screen.dart

import 'dart:math' as math;

import 'package:confetti/confetti.dart';
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/models/cart_model.dart';
import 'package:purecuts/core/services/firestore_service.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/core/theme/spacing.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';
import 'package:purecuts/features/main_nav/main_nav_screen.dart';
import 'package:purecuts/features/orders/order_provider.dart';

class OrderConfirmScreen extends StatefulWidget {
  final int total;
  final List<Map<String, dynamic>>? orderedItems;
  final Map<String, dynamic>? deliveryAddress;
  final Map<String, dynamic>? contactDetails;
  final String? paymentMethod;
  final Map<String, dynamic>? billDetails;
  final String? alreadyPlacedOrderRef;
  final bool persistOrder;

  const OrderConfirmScreen({
    super.key,
    required this.total,
    this.orderedItems,
    this.deliveryAddress,
    this.contactDetails,
    this.paymentMethod,
    this.billDetails,
    this.alreadyPlacedOrderRef,
    this.persistOrder = true,
  });

  @override
  State<OrderConfirmScreen> createState() => _OrderConfirmScreenState();
}

class _OrderConfirmScreenState extends State<OrderConfirmScreen>
    with SingleTickerProviderStateMixin {
  final FirestoreService _firestoreService = FirestoreService();
  late AnimationController _controller;
  late ConfettiController _confettiController;
  late Animation<double> _scaleAnim;
  String? _orderRef;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _confettiController = ConfettiController(
      duration: const Duration(milliseconds: 2200),
    );
    _scaleAnim = CurvedAnimation(parent: _controller, curve: Curves.elasticOut);
    _controller.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _confettiController.play();
    });

    // Defer provider mutations until after the first frame to avoid
    // notifyListeners() while widget tree is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _persistOrderAndSyncProviders();
    });
  }

  void _persistOrderAndSyncProviders() {
    // ✅ Save cart items to OrderProvider BEFORE clearing the cart
    final cart = context.read<CartModel>();
    final orders = context.read<OrderProvider>();
    final auth = context.read<AuthProvider>();
    final uid = auth.user?.uid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
    final provisionalOrderRef =
        (widget.alreadyPlacedOrderRef ?? '').trim().isNotEmpty
        ? widget.alreadyPlacedOrderRef!.trim()
        : _firestoreService.generateOrderRef();

    if (mounted) {
      setState(() => _orderRef = provisionalOrderRef);
    } else {
      _orderRef = provisionalOrderRef;
    }

    final orderedItems = widget.orderedItems?.isNotEmpty == true
        ? widget.orderedItems!
        : cart.items
              .map(
                (item) => {
                  'id': item.id,
                  'name': item.name,
                  'brand': item.brand,
                  'image': item.image,
                  'price': item.price,
                  'originalPrice': item.price,
                  'size': '',
                  'tag': '',
                  'quantity': item.quantity,
                },
              )
              .toList();

    orders.addOrderedItems(orderedItems);

    final shouldPersistOrder =
        widget.persistOrder &&
        (widget.alreadyPlacedOrderRef ?? '').trim().isEmpty;

    if (shouldPersistOrder &&
        uid.trim().isNotEmpty &&
        orderedItems.isNotEmpty) {
      _firestoreService
          .registerUserPurchase(
            uid: uid,
            items: orderedItems,
            total: widget.total,
            deliveryAddress: widget.deliveryAddress,
            contactDetails: widget.contactDetails,
            paymentMethod: widget.paymentMethod,
            billDetails: widget.billDetails,
            orderRefOverride: provisionalOrderRef,
            userProfile: auth.user?.toMap(),
          )
          .then((ref) {
            if (!mounted) return;
            if (ref == null || ref.trim().isEmpty) return;
            setState(() => _orderRef = ref.trim());
          })
          .catchError((error, stackTrace) {
            // Best effort persistence for review eligibility and order history.
          });
    }

    // ✅ Keep backward compatibility: clear cart only when this screen performs persistence.
    if (shouldPersistOrder) {
      cart.clear();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _confettiController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xxl),
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ScaleTransition(
                            scale: _scaleAnim,
                            child: Container(
                              width: 112,
                              height: 112,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    AppColors.primary,
                                    AppColors.primaryLight,
                                  ],
                                ),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.primary.withOpacity(0.4),
                                    blurRadius: 30,
                                    offset: const Offset(0, 10),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.check_rounded,
                                color: Colors.white,
                                size: 58,
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xxl),
                          const Text(
                            'Order Placed! 🎉',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 31,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            '₹${widget.total} • ${_orderRef ?? 'Generating Order ID...'}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pushAndRemoveUntil(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const MainNavScreen(),
                        ),
                        (_) => false,
                      ),
                      child: const Text('Continue Shopping'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          IgnorePointer(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConfettiWidget(
                confettiController: _confettiController,
                blastDirectionality: BlastDirectionality.explosive,
                shouldLoop: false,
                emissionFrequency: 0.085,
                numberOfParticles: 32,
                minBlastForce: 6,
                maxBlastForce: 16,
                gravity: 0.32,
                minimumSize: const Size(3, 3),
                maximumSize: const Size(7, 7),
                particleDrag: 0.05,
                colors: const [
                  AppColors.primary,
                  AppColors.primaryLight,
                  Color(0xFFFFD166),
                  Color(0xFF4ADE80),
                  Color(0xFF60A5FA),
                ],
              ),
            ),
          ),
          IgnorePointer(
            child: Align(
              alignment: Alignment.topLeft,
              child: ConfettiWidget(
                confettiController: _confettiController,
                blastDirectionality: BlastDirectionality.directional,
                blastDirection: math.pi / 4,
                shouldLoop: false,
                emissionFrequency: 0.06,
                numberOfParticles: 18,
                minBlastForce: 5,
                maxBlastForce: 14,
                gravity: 0.34,
                minimumSize: const Size(2.5, 2.5),
                maximumSize: const Size(6, 6),
                colors: const [
                  AppColors.primary,
                  AppColors.primaryLight,
                  Color(0xFFFFD166),
                  Color(0xFF4ADE80),
                  Color(0xFF60A5FA),
                ],
              ),
            ),
          ),
          IgnorePointer(
            child: Align(
              alignment: Alignment.topRight,
              child: ConfettiWidget(
                confettiController: _confettiController,
                blastDirectionality: BlastDirectionality.directional,
                blastDirection: (math.pi * 3) / 4,
                shouldLoop: false,
                emissionFrequency: 0.06,
                numberOfParticles: 18,
                minBlastForce: 5,
                maxBlastForce: 14,
                gravity: 0.34,
                minimumSize: const Size(2.5, 2.5),
                maximumSize: const Size(6, 6),
                colors: const [
                  AppColors.primary,
                  AppColors.primaryLight,
                  Color(0xFFFFD166),
                  Color(0xFF4ADE80),
                  Color(0xFF60A5FA),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
