import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:purecuts/core/constants/app_constants.dart';
import 'package:purecuts/core/constants/feature_flags.dart';
import 'package:purecuts/features/auth/login/login_screen.dart';
import 'package:purecuts/features/auth/pending_approval_screen.dart';
import 'package:purecuts/features/main_nav/main_nav_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _revealController;
  Timer? _watchdogTimer;
  bool _didNavigate = false;

  late final Animation<double> _fadeAnim;
  late final Animation<double> _logoScaleAnim;
  late final Animation<double> _taglineSlideAnim;

  bool _isApproved(Map<String, dynamic> data) {
    final status = (data['verificationStatus'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    return data['accessApproved'] == true ||
        data['isVerified'] == true ||
        status == 'approved';
  }

  void _navigateOnce(Widget destination) {
    if (!mounted || _didNavigate) return;
    _didNavigate = true;
    _watchdogTimer?.cancel();
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => destination,
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  Future<void> _resolveAndNavigate() async {
    await Future<void>.delayed(
      Duration(milliseconds: FeatureFlags.splashMinDurationMs),
    );
    if (!mounted || _didNavigate) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _navigateOnce(const LoginScreen());
      return;
    }

    final userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid);

    // Fast path: read any locally cached profile first.
    try {
      final cacheDoc = await userRef
          .get(const GetOptions(source: Source.cache))
          .timeout(
            Duration(
              milliseconds: (FeatureFlags.splashUserDocTimeoutMs / 2).round(),
            ),
          );
      if (cacheDoc.exists) {
        final data = cacheDoc.data() ?? const <String, dynamic>{};
        _navigateOnce(
          _isApproved(data)
              ? const MainNavScreen()
              : const PendingApprovalScreen(),
        );
        return;
      }
    } catch (_) {
      // Continue to bounded server fetch.
    }

    // Bounded server fetch: do not let splash block indefinitely.
    try {
      final serverDoc = await userRef.get().timeout(
        Duration(milliseconds: FeatureFlags.splashUserDocTimeoutMs),
      );
      if (serverDoc.exists) {
        final data = serverDoc.data() ?? const <String, dynamic>{};
        _navigateOnce(
          _isApproved(data)
              ? const MainNavScreen()
              : const PendingApprovalScreen(),
        );
        return;
      }
    } catch (_) {
      // Fall through to resilient signed-in fallback.
    }

    // Signed-in fallback: avoid trapping user on splash when profile fetch stalls.
    _navigateOnce(const MainNavScreen());
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemStatusBarContrastEnforced: false,
      ),
    );

    _revealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    );

    _fadeAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _revealController,
        curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic),
      ),
    );

    _logoScaleAnim = Tween<double>(begin: 0.86, end: 1.0).animate(
      CurvedAnimation(
        parent: _revealController,
        curve: const Interval(0.05, 0.62, curve: Curves.easeOutBack),
      ),
    );

    _taglineSlideAnim = Tween<double>(begin: 14, end: 0).animate(
      CurvedAnimation(
        parent: _revealController,
        curve: const Interval(0.25, 0.85, curve: Curves.easeOutCubic),
      ),
    );

    _revealController.forward();

    if (FeatureFlags.enableSplashWatchdog) {
      _watchdogTimer = Timer(
        Duration(milliseconds: FeatureFlags.splashWatchdogTimeoutMs),
        () {
          if (!mounted || _didNavigate) return;
          final hasUser = FirebaseAuth.instance.currentUser != null;
          _navigateOnce(hasUser ? const MainNavScreen() : const LoginScreen());
        },
      );
    }

    unawaited(_resolveAndNavigate());
  }

  @override
  void dispose() {
    _watchdogTimer?.cancel();
    _revealController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemStatusBarContrastEnforced: false,
      ),
      child: Scaffold(
        body: AnimatedBuilder(
          animation: _revealController,
          builder: (_, __) {
            return Container(
              width: double.infinity,
              height: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFFA99DE7),
                    Color(0xFFB6ACEA),
                    Color(0xFFC5BDF0),
                  ],
                ),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Opacity(
                      opacity: _fadeAnim.value,
                      child: Transform.translate(
                        offset: Offset(0, _taglineSlideAnim.value),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 28),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Transform.scale(
                                scale: _logoScaleAnim.value,
                                child: Image.asset(
                                  AppConstants.logoPath,
                                  width: 300,
                                  fit: BoxFit.contain,
                                ),
                              ),
                              const SizedBox(height: 2),
                              const Text(
                                'ONE-STOP PLATFORM FOR SALONS',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Color(0xFF1A1230),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 38,
                    left: 0,
                    right: 0,
                    child: Opacity(
                      opacity: 0.75,
                      child: const Text(
                        'Loading your professional experience...',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFF5C138B),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
