import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/phone_verification_screen.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';

class EmailVerificationScreen extends StatefulWidget {
  final String email;
  final Map<String, dynamic> registrationData;

  const EmailVerificationScreen({
    super.key,
    required this.email,
    required this.registrationData,
  });

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  bool _checking = false;
  bool _resending = false;

  Future<void> _checkVerified() async {
    setState(() => _checking = true);
    final authProvider = context.read<AuthProvider>();
    final verified = await authProvider.checkEmailVerified();
    if (!mounted) return;
    setState(() => _checking = false);

    if (verified) {
      _goToPhoneVerification();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Email not yet verified. Please check your inbox.'),
          backgroundColor: AppColors.warning,
        ),
      );
    }
  }

  Future<void> _resendEmail() async {
    setState(() => _resending = true);
    final authProvider = context.read<AuthProvider>();
    await authProvider.resendVerificationEmail();
    if (!mounted) return;
    setState(() => _resending = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Verification email resent!'),
        backgroundColor: AppColors.success,
      ),
    );
  }

  void _goToPhoneVerification() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => PhoneVerificationScreen(
          phoneNumber: widget.registrationData['phone'] as String,
          registrationData: widget.registrationData,
        ),
      ),
    );
  }

  Future<void> _cancel() async {
    // Sign out the partially-created account so the user can retry cleanly
    final authProvider = context.read<AuthProvider>();
    await authProvider.signOut();
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Verify Email'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _cancel,
          tooltip: 'Cancel & go back',
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Icon
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.mark_email_unread_outlined,
                  size: 50,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(height: 32),

              const Text(
                'Check your inbox',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                  letterSpacing: -0.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),

              RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppColors.textSecondary,
                    height: 1.6,
                  ),
                  children: [
                    const TextSpan(text: 'We sent a verification link to\n'),
                    TextSpan(
                      text: widget.email,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const TextSpan(
                      text:
                          '\n\nClick the link in the email, then tap the button below.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 48),

              // Primary CTA
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: _checking ? null : _checkVerified,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  child: _checking
                      ? const SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          "I've verified my email →",
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 20),

              // Resend
              TextButton(
                onPressed: _resending ? null : _resendEmail,
                child: Text(
                  _resending ? 'Sending...' : 'Resend verification email',
                  style: TextStyle(
                    color: _resending ? AppColors.textHint : AppColors.primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
