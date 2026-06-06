import 'package:flutter/material.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/home/home_screen.dart';
import 'package:purecuts/features/previously_bought/previously_bought_screen.dart';
import 'package:purecuts/features/categories/categories_screen.dart';
import 'package:purecuts/features/brands/brands_screen.dart';
import 'package:purecuts/features/support_chat/widgets/support_chat_fab.dart';

class MainNavScreen extends StatefulWidget {
  const MainNavScreen({super.key});
  @override
  State<MainNavScreen> createState() => _MainNavScreenState();
}

class _MainNavScreenState extends State<MainNavScreen> {
  int _index = 0;
  late final PageController _pageController;

  final List<Widget> _screens = const [
    HomeScreen(),
    PreviouslyBoughtScreen(),
    CategoriesScreen(),
    BrandsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _index, keepPage: true);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onNavTap(int i) {
    if (i == _index) return;

    if (i == 2) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.hideCurrentSnackBar();
      messenger?.clearSnackBars();
    }

    final isNearTab = (i - _index).abs() == 1;
    if (isNearTab) {
      _pageController.animateToPage(
        i,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      return;
    }

    _pageController.jumpToPage(i);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        onPageChanged: (i) {
          if (i == _index) return;
          setState(() => _index = i);
        },
        children: _screens,
      ),
      floatingActionButton: const Padding(
        padding: EdgeInsets.only(bottom: 58),
        child: SupportChatFab(),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14A855F7),
              blurRadius: 24,
              offset: Offset(0, -4),
            ),
            BoxShadow(
              color: Color(0x08000000),
              blurRadius: 8,
              offset: Offset(0, -1),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _index,
          onTap: _onNavTap,
          backgroundColor: Colors.transparent,
          elevation: 0,
          selectedItemColor: AppColors.primary,
          unselectedItemColor: AppColors.textHint,
          showSelectedLabels: true,
          showUnselectedLabels: true,
          type: BottomNavigationBarType.fixed,
          selectedLabelStyle: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
          unselectedLabelStyle: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.history_rounded),
              activeIcon: Icon(Icons.history_rounded),
              label: 'Order Again',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.grid_view_rounded),
              activeIcon: Icon(Icons.grid_view_rounded),
              label: 'Categories',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.storefront_outlined),
              activeIcon: Icon(Icons.storefront_rounded),
              label: 'Brands',
            ),
          ],
        ),
      ),
    );
  }
}
