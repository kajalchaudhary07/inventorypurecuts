import 'dart:async';
import 'dart:ui';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/navigation/app_navigator.dart';
import 'package:purecuts/core/services/deep_link_service.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/core/models/cart_model.dart';
import 'package:purecuts/core/services/push_notification_service.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';
import 'package:purecuts/features/home/home_provider.dart';
import 'package:purecuts/features/orders/order_provider.dart';

import 'package:purecuts/features/splash/splash_screen.dart';
import 'firebase_options.dart';

late final CartModel _initialCartModel;

class _SlideLeftPageTransitionsBuilder extends PageTransitionsBuilder {
  const _SlideLeftPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    const curve = Curves.easeOutCubic;

    final inAnimation = Tween<Offset>(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).chain(CurveTween(curve: curve)).animate(animation);

    final outAnimation = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(-0.08, 0),
    ).chain(CurveTween(curve: curve)).animate(secondaryAnimation);

    return SlideTransition(
      position: outAnimation,
      child: SlideTransition(position: inAnimation, child: child),
    );
  }
}

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );

      final crashlytics = FirebaseCrashlytics.instance;
      final performance = FirebasePerformance.instance;

      await performance.setPerformanceCollectionEnabled(true);

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        crashlytics.recordFlutterFatalError(details);
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        crashlytics.recordError(error, stack, fatal: true);
        return true;
      };

      try {
        _initialCartModel = await CartModel.create();
      } catch (_) {
        _initialCartModel = CartModel.empty();
      }

      runApp(const PureCutsApp());
    },
    (error, stack) async {
      await FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    },
  );
}

class PureCutsApp extends StatefulWidget {
  const PureCutsApp({super.key});

  @override
  State<PureCutsApp> createState() => _PureCutsAppState();
}

class _PureCutsAppState extends State<PureCutsApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PushNotificationService.instance.initialize();
      unawaited(DeepLinkService.instance.initialize());
    });
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider<CartModel>.value(value: _initialCartModel),
        ChangeNotifierProvider(create: (_) => HomeProvider()),
        ChangeNotifierProxyProvider<AuthProvider, OrderProvider>(
          create: (_) => OrderProvider(),
          update: (_, auth, orders) {
            final resolved = orders ?? OrderProvider();
            resolved.syncAuthUid(auth.user?.uid);
            return resolved;
          },
        ),
      ],
      child: MaterialApp(
        navigatorKey: appNavigatorKey,
        title: 'PureCuts',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light.copyWith(
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: _SlideLeftPageTransitionsBuilder(),
              TargetPlatform.iOS: _SlideLeftPageTransitionsBuilder(),
              TargetPlatform.macOS: _SlideLeftPageTransitionsBuilder(),
              TargetPlatform.windows: _SlideLeftPageTransitionsBuilder(),
              TargetPlatform.linux: _SlideLeftPageTransitionsBuilder(),
              TargetPlatform.fuchsia: _SlideLeftPageTransitionsBuilder(),
            },
          ),
        ),
        home: const SplashScreen(),
      ),
    );
  }
}
