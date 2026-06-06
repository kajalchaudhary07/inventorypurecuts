import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/otp_screen.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phoneController = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    final phone = _phoneController.text.trim();
    if (phone.length != 10) {
      _showError('Please enter a valid 10-digit phone number.');
      return;
    }
    setState(() => _loading = true);
    final authProvider = context.read<AuthProvider>();
    final sent = await authProvider.sendOtp('+91$phone');
    if (!mounted) return;
    setState(() => _loading = false);

    if (sent) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OtpScreen(phoneNumber: phone),
        ),
      );
    } else {
      _showError(authProvider.error ?? 'Failed to send OTP. Try again.');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.error),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SizedBox.expand(
        child: Stack(
          children: [
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFFEDE9FE),
                    Color(0xFFF5EEFF),
                    Color(0xFFFBFAFF),
                    Colors.white,
                  ],
                  stops: [0.0, 0.25, 0.5, 1.0],
                ),
              ),
            ),
          ),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  const SizedBox(height: 56),

                  // Logo
                  Image.asset(
                    'assets/icons/purecutslogo-removebg-preview.png',
                    height: 90,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Manage your salon smarter',
                    style: TextStyle(
                        fontSize: 15, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 52),

                  // Phone field
                  Align(
                    alignment: Alignment.centerLeft,
                    child: const Text(
                      'Phone Number',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    autofocus: true,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(10),
                    ],
                    decoration: const InputDecoration(
                      hintText: '10-digit mobile number',
                      prefixIcon: Icon(Icons.phone_outlined,
                          size: 20, color: AppColors.textHint),
                      prefixText: '+91 ',
                      prefixStyle: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    onSubmitted: (_) => _sendOtp(),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'We\'ll send a one-time password to this number',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textHint),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Send OTP button
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _sendOtp,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        elevation: 0,
                      ),
                      child: _loading
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.5, color: Colors.white),
                            )
                          : const Text(
                              'Send OTP',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700),
                            ),
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }
}
