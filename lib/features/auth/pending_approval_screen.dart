import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/login/login_screen.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';
import 'package:purecuts/features/main_nav/main_nav_screen.dart';

class PendingApprovalScreen extends StatefulWidget {
  const PendingApprovalScreen({super.key});

  @override
  State<PendingApprovalScreen> createState() => _PendingApprovalScreenState();
}

class _PendingApprovalScreenState extends State<PendingApprovalScreen> {
  bool _navigated = false;

  bool _isApproved(Map<String, dynamic> data) {
    final status = (data['verificationStatus'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    return data['accessApproved'] == true ||
        data['isVerified'] == true ||
        status == 'approved';
  }

  String _status(Map<String, dynamic> data) {
    final status = (data['verificationStatus'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (status.isNotEmpty) return status;
    return _isApproved(data) ? 'approved' : 'pending';
  }

  void _goToMainNav() {
    if (_navigated || !mounted) return;
    _navigated = true;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const MainNavScreen()),
      (_) => false,
    );
  }

  Future<void> _logout() async {
    await context.read<AuthProvider>().signOut();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.lock_outline,
                  size: 56,
                  color: AppColors.error,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Session expired. Please login again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _logout,
                  child: const Text('Back to Login'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final stream = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots();

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: stream,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              );
            }

            final data = snapshot.data?.data() ?? const <String, dynamic>{};
            final approved = _isApproved(data);
            final status = _status(data);

            if (approved) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _goToMainNav(),
              );
            }

            final isRejected = status == 'rejected';
            final title = isRejected
                ? 'Access request rejected'
                : approved
                ? 'Access approved'
                : 'Waiting for admin approval';

            final subtitle = isRejected
                ? 'Your request was rejected by admin. Please contact support or update your details and try again.'
                : approved
                ? 'Redirecting you to the app...'
                : 'We received your request. Our team will review your details shortly.';

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: isRejected
                          ? AppColors.error.withOpacity(0.12)
                          : AppColors.primary.withOpacity(0.10),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isRejected
                          ? Icons.cancel_outlined
                          : approved
                          ? Icons.verified_outlined
                          : Icons.hourglass_top_rounded,
                      size: 48,
                      color: isRejected
                          ? AppColors.error
                          : approved
                          ? AppColors.success
                          : AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isRejected
                          ? AppColors.error.withOpacity(0.10)
                          : AppColors.warning.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Text(
                      'Status: ${status.toUpperCase()}',
                      style: TextStyle(
                        color: isRejected ? AppColors.error : AppColors.warning,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  if (!approved)
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: _logout,
                        icon: const Icon(Icons.logout),
                        label: const Text('Logout'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: AppColors.primary,
                          side: const BorderSide(color: AppColors.border),
                          elevation: 0,
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
