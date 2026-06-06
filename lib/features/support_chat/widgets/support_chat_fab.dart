import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';
import 'package:purecuts/features/support_chat/presentation/support_chat_screen.dart';
import 'package:purecuts/features/support_chat/services/support_chat_service.dart';

class SupportChatFab extends StatelessWidget {
  const SupportChatFab({super.key, this.service});

  final SupportChatService? service;

  @override
  Widget build(BuildContext context) {
    return _SupportChatFabAnimated(service: service);
  }
}

class _SupportChatFabAnimated extends StatefulWidget {
  const _SupportChatFabAnimated({this.service});

  final SupportChatService? service;

  @override
  State<_SupportChatFabAnimated> createState() =>
      _SupportChatFabAnimatedState();
}

class _SupportChatFabAnimatedState extends State<_SupportChatFabAnimated>
    with SingleTickerProviderStateMixin {
  static const List<String> _messages = [
    'Support',
    'Need help?',
    'Place bulk orders here',
  ];

  late final AnimationController _floatController;
  Timer? _messageTimer;
  int _messageIndex = 0;

  @override
  void initState() {
    super.initState();
    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
      lowerBound: 0,
      upperBound: 1,
    )..repeat(reverse: true);

    _messageTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      setState(() {
        _messageIndex = (_messageIndex + 1) % _messages.length;
      });
    });
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    _floatController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final user = auth.user;
    if (user == null) {
      return const SizedBox.shrink();
    }

    final chatService = widget.service ?? SupportChatService();

    return StreamBuilder<int>(
      stream: chatService.unreadCountStreamForUser(user.uid),
      builder: (context, snapshot) {
        final unreadCount = snapshot.data ?? 0;

        return SizedBox(
          width: 220,
          height: 124,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                right: 0,
                bottom: 0,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    FloatingActionButton(
                      heroTag: null,
                      backgroundColor: AppColors.primary,
                      onPressed: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                SupportChatScreen(service: chatService),
                          ),
                        );
                      },
                      child: const Icon(Icons.support_agent_rounded),
                    ),
                    if (unreadCount > 0)
                      Positioned(
                        right: -3,
                        top: -3,
                        child: Container(
                          constraints: const BoxConstraints(
                            minWidth: 20,
                            minHeight: 20,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: Colors.white, width: 1.4),
                          ),
                          child: Text(
                            unreadCount > 99 ? '99+' : unreadCount.toString(),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Positioned(
                right: 8,
                bottom: 70,
                child: AnimatedBuilder(
                  animation: _floatController,
                  builder: (context, child) {
                    final offsetY = -3 * _floatController.value;
                    return Transform.translate(
                      offset: Offset(0, offsetY),
                      child: child,
                    );
                  },
                  child: IgnorePointer(
                    child: _SupportHintBubble(
                      message: _messages[_messageIndex],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SupportHintBubble extends StatelessWidget {
  const _SupportHintBubble({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.primary.withOpacity(0.25)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
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
              child: Text(
                message,
                key: ValueKey<String>(message),
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          Positioned(
            right: 18,
            bottom: -7,
            child: CustomPaint(
              size: const Size(12, 8),
              painter: _BubblePointerPainter(
                fillColor: Colors.white,
                borderColor: AppColors.primary.withOpacity(0.25),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BubblePointerPainter extends CustomPainter {
  const _BubblePointerPainter({
    required this.fillColor,
    required this.borderColor,
  });

  final Color fillColor;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, size.height)
      ..lineTo(0, 0)
      ..lineTo(size.width, 0)
      ..close();

    final fill = Paint()..color = fillColor;
    final border = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas.drawPath(path, fill);
    canvas.drawPath(path, border);
  }

  @override
  bool shouldRepaint(covariant _BubblePointerPainter oldDelegate) {
    return oldDelegate.fillColor != fillColor ||
        oldDelegate.borderColor != borderColor;
  }
}
