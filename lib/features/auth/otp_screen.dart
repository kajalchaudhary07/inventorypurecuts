import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/features/auth/pending_approval_screen.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/profile_setup_screen.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';
import 'package:purecuts/features/main_nav/main_nav_screen.dart';

class OtpScreen extends StatefulWidget {
  final String phoneNumber;
  const OtpScreen({super.key, required this.phoneNumber});

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final List<TextEditingController> _controllers = List.generate(
    6,
    (_) => TextEditingController(),
  );
  final List<FocusNode> _focusNodes = List.generate(6, (_) => FocusNode());

  bool _loading = false;
  bool _resending = false;
  bool _autoVerifyTriggered = false;
  int _resendSeconds = 60;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
    // Handle Android auto-verified credential
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final authProvider = context.read<AuthProvider>();
      authProvider.addListener(_onAuthProviderChanged);
      _onAuthProviderChanged();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    try {
      context.read<AuthProvider>().removeListener(_onAuthProviderChanged);
    } catch (_) {}
    for (final c in _controllers) c.dispose();
    for (final f in _focusNodes) f.dispose();
    super.dispose();
  }

  void _onAuthProviderChanged() {
    if (!mounted || _autoVerifyTriggered || _loading || _resending) return;
    final authProvider = context.read<AuthProvider>();
    if (authProvider.autoCredential == null) return;
    _autoVerifyTriggered = true;
    _verifyWithOtp('auto');
  }

  void _startTimer() {
    _timer?.cancel();
    setState(() => _resendSeconds = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_resendSeconds == 0) {
        t.cancel();
      } else {
        setState(() => _resendSeconds--);
      }
    });
  }

  String get _otpCode => _controllers.map((c) => c.text).join();

  Future<void> _verifyWithOtp(String otp) async {
    if (_loading) return;
    setState(() => _loading = true);

    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.signInWithPhoneOtp(otp);

    if (!mounted) return;
    setState(() => _loading = false);

    if (!success) {
      _showError(authProvider.error ?? 'Invalid OTP. Please try again.');
      // Clear the boxes so user can retype
      for (final c in _controllers) c.clear();
      _focusNodes.first.requestFocus();
      return;
    }

    // success: use authoritative Firestore access-state to decide routing.
    // `authProvider.user` can be stale in rare auth-state timing cases.
    final gate = await authProvider.getCurrentUserAccessState();
    if (!mounted) return;

    if (!gate.exists) {
      // New user — fill in profile first.
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) =>
              ProfileSetupScreen(phoneNumber: '+91${widget.phoneNumber}'),
        ),
      );
      return;
    }

    if (gate.isApproved) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const MainNavScreen()),
        (_) => false,
      );
    } else {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const PendingApprovalScreen()),
        (_) => false,
      );
    }
  }

  Future<void> _onVerifyPressed() async {
    final code = _otpCode;
    if (code.length < 6) {
      _showError('Please enter the 6-digit OTP.');
      return;
    }
    await _verifyWithOtp(code);
  }

  Future<void> _resend() async {
    if (_resendSeconds > 0 || _loading || _resending) return;
    setState(() => _resending = true);
    final authProvider = context.read<AuthProvider>();
    final sent = await authProvider.resendOtp('+91${widget.phoneNumber}');
    if (!mounted) return;
    setState(() => _resending = false);
    if (sent) {
      _startTimer();
      for (final c in _controllers) c.clear();
      _focusNodes.first.requestFocus();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('OTP resent successfully.'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      _showError(authProvider.error ?? 'Could not resend OTP. Try again.');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: AppColors.textPrimary,
            size: 20,
          ),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),

            // ── Header ────────────────────────────────────────────────
            const Text(
              'Verify your number',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 10),
            RichText(
              text: TextSpan(
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                  height: 1.5,
                ),
                children: [
                  const TextSpan(text: 'OTP sent to '),
                  TextSpan(
                    text: '+91 ${widget.phoneNumber}',
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),

            // ── OTP Boxes ─────────────────────────────────────────────
            Row(
              children: List.generate(6, (i) {
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: i < 5 ? 8 : 0),
                    child: _OtpBox(
                      controller: _controllers[i],
                      focusNode: _focusNodes[i],
                      onChanged: (v) {
                        if (v.isNotEmpty) {
                          if (i < 5) {
                            _focusNodes[i + 1].requestFocus();
                          } else {
                            // Last box — auto-submit
                            _focusNodes[i].unfocus();
                            _onVerifyPressed();
                          }
                        }
                      },
                      onBackspace: () {
                        if (i > 0) _focusNodes[i - 1].requestFocus();
                      },
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 36),

            // ── Verify Button ─────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _loading ? null : _onVerifyPressed,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.primary.withOpacity(0.6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
                child: _loading
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'Verify & Continue',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 24),

            // ── Resend ────────────────────────────────────────────────
            Center(
              child: _resendSeconds > 0
                  ? Text(
                      'Resend OTP in $_resendSeconds s',
                      style: const TextStyle(
                        color: AppColors.textHint,
                        fontSize: 14,
                      ),
                    )
                  : TextButton(
                      onPressed: _resending || _loading ? null : _resend,
                      child: Text(
                        _resending ? 'Sending...' : 'Resend OTP',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Individual OTP input box ───────────────────────────────────────────────

class _OtpBox extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onBackspace;

  const _OtpBox({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onBackspace,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (_, value, __) {
        final filled = value.text.isNotEmpty;
        final focused = focusNode.hasFocus;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 56,
          decoration: BoxDecoration(
            color: filled ? AppColors.primary.withOpacity(0.10) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: filled
                  ? AppColors.primary
                  : focused
                  ? AppColors.primary.withOpacity(0.5)
                  : const Color(0xFFDEDEDE),
              width: filled || focused ? 2 : 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: filled
                    ? AppColors.primary.withOpacity(0.18)
                    : Colors.black.withOpacity(0.04),
                blurRadius: filled ? 10 : 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            textAlignVertical: TextAlignVertical.center,
            maxLength: 1,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: TextStyle(
              color: filled ? AppColors.primary : AppColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
            decoration: const InputDecoration(
              counterText: '',
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 16),
            ),
            onChanged: (value) {
              if (value.isEmpty) {
                onBackspace();
              }
              onChanged(value);
            },
          ),
        );
      },
    );
  }
}
