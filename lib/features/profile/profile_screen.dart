import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';
import 'package:purecuts/features/auth/edit_profile_screen.dart';
import 'package:purecuts/features/orders/order_history_screen.dart';
import 'package:purecuts/features/auth/login/login_screen.dart';
import 'package:url_launcher/url_launcher.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    final name = user?.ownerName ?? user?.name ?? '';
    final initial = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : '?';

    // Build address string
    final addressParts = [
      if (user?.address != null && user!.address!.isNotEmpty) user.address!,
      if (user?.state != null && user!.state!.isNotEmpty) user.state!,
      if (user?.pincode != null && user!.pincode!.isNotEmpty) user.pincode!,
    ];
    final address = addressParts.join(', ');

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: false,
        title: const Text(
          'Profile',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 17,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, color: AppColors.textPrimary),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const EditProfileScreen()),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          // ── Full-screen lavender gradient top half ──────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Builder(
              builder: (context) => Container(
                height: MediaQuery.of(context).size.height * 0.52,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFFB69DF8),
                      Color(0xFFC4B5FD),
                      Color(0xFFDDD6FE),
                      Color(0xFFEDE9FE),
                      Colors.white,
                    ],
                    stops: [0.0, 0.18, 0.42, 0.70, 1.0],
                  ),
                ),
              ),
            ),
          ),
          // ── Scrollable content ──────────────────────────────────────
          ListView(
            padding: EdgeInsets.zero,
            children: [
              // Spacer so avatar sits below the transparent AppBar
              const SafeArea(bottom: false, child: SizedBox.shrink()),
              // ── Avatar + name (full width on gradient) ─────────────
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Column(
                  children: [
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withOpacity(0.22),
                            blurRadius: 22,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Text(
                          initial,
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      name.isNotEmpty ? name : 'My Profile',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.60),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        user?.role == 'salon_owner' ? 'Salon Owner' : 'Member',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // ── All padded sections ────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Salon Info
                    _section('Salon Details'),
                    const SizedBox(height: 8),
                    _card([
                      if (user?.salonName != null &&
                          user!.salonName!.isNotEmpty)
                        _row(
                          Icons.storefront_outlined,
                          'Salon Name',
                          user.salonName!,
                        ),
                      if (user?.ownerName != null &&
                          user!.ownerName!.isNotEmpty) ...[
                        _divider(),
                        _row(Icons.person_outline, 'Owner', user.ownerName!),
                      ],
                      if (user?.gst != null && user!.gst!.isNotEmpty) ...[
                        _divider(),
                        _row(Icons.receipt_long_outlined, 'GST', user.gst!),
                      ],
                    ]),
                    const SizedBox(height: 20),
                    // Contact
                    _section('Contact'),
                    const SizedBox(height: 8),
                    _card([
                      if (user?.phone != null && user!.phone!.isNotEmpty)
                        _row(Icons.phone_outlined, 'Phone', user.phone!),
                      if (user?.email != null && user!.email.isNotEmpty) ...[
                        _divider(),
                        _row(Icons.email_outlined, 'Email', user.email),
                      ],
                    ]),
                    const SizedBox(height: 20),
                    // Address
                    _section('Address'),
                    const SizedBox(height: 8),
                    _card([
                      _row(
                        Icons.location_on_outlined,
                        'Salon Address',
                        address.isNotEmpty ? address : 'Not set',
                      ),
                    ]),
                    const SizedBox(height: 20),
                    // Account
                    _section('Account'),
                    const SizedBox(height: 8),
                    _card([
                      _navRow(
                        context,
                        Icons.receipt_long_outlined,
                        'Order History',
                        () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const OrderHistoryScreen(),
                            ),
                          );
                        },
                      ),
                      _divider(),
                      _navRow(
                        context,
                        Icons.help_outline,
                        'Help & Support',
                        () {},
                      ),
                      _divider(),
                      _navRow(
                        context,
                        Icons.shield_outlined,
                        'Privacy Policy',
                        () => _openPrivacyPolicy(context),
                      ),
                    ]),
                    const SizedBox(height: 24),
                    // Logout
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.error,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: AppColors.error.withOpacity(0.06),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.logout_rounded, size: 18),
                      label: const Text(
                        'Logout',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      onPressed: () => _showLogout(context),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section(String text) => Text(
    text,
    style: const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: AppColors.textHint,
      letterSpacing: 0.6,
    ),
  );

  Widget _card(List<Widget> children) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0CA855F7),
          blurRadius: 20,
          offset: Offset(0, 5),
        ),
        BoxShadow(
          color: Color(0x07000000),
          blurRadius: 6,
          offset: Offset(0, 1),
        ),
      ],
    ),
    child: Column(children: children),
  );

  Widget _row(IconData icon, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppColors.primary, size: 18),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(fontSize: 11, color: AppColors.textHint),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _navRow(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(icon, color: AppColors.textSecondary, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const Icon(Icons.chevron_right, color: AppColors.textHint, size: 18),
        ],
      ),
    ),
  );

  Widget _divider() => const Divider(height: 1, thickness: 1, indent: 46);

  Future<void> _openPrivacyPolicy(BuildContext context) async {
    final uri = Uri.parse(
      'https://sites.google.com/view/purecuts-privacy-policy/home',
    );
    try {
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication) ||
          await launchUrl(uri, mode: LaunchMode.platformDefault) ||
          await launchUrl(uri, mode: LaunchMode.inAppBrowserView);

      if (!launched && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to open privacy policy.')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to open privacy policy.')),
        );
      }
    }
  }

  void _showLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Logout',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await context.read<AuthProvider>().signOut();
              if (context.mounted) {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (_) => false,
                );
              }
            },
            child: const Text(
              'Logout',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
  }
}
