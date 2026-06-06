import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/pending_approval_screen.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';

/// Unified two-step verification: Email → Phone OTP.
class VerificationScreen extends StatefulWidget {
  final String email;
  final String phoneNumber;
  final Map<String, dynamic> registrationData;

  const VerificationScreen({
    super.key,
    required this.email,
    required this.phoneNumber,
    required this.registrationData,
  });

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  // 0 = email step, 1 = phone step
  int _step = 0;

  // Email state
  bool _checkingEmail = false;
  bool _resendingEmail = false;

  // Phone state
  final List<TextEditingController> _otpControllers = List.generate(
    6,
    (_) => TextEditingController(),
  );
  final List<FocusNode> _focusNodes = List.generate(6, (_) => FocusNode());
  bool _otpLoading = false;
  bool _sendingOtp = false;
  bool _resendingOtp = false;
  int _secondsRemaining = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Listen for Android auto-verification
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AuthProvider>().addListener(_onAutoVerify);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (var c in _otpControllers) {
      c.dispose();
    }
    for (var n in _focusNodes) {
      n.dispose();
    }
    try {
      context.read<AuthProvider>().removeListener(_onAutoVerify);
    } catch (_) {}
    super.dispose();
  }

  // ── Email step ──────────────────────────────────────────────────────────

  Future<void> _checkEmailVerified() async {
    setState(() => _checkingEmail = true);
    final verified = await context.read<AuthProvider>().checkEmailVerified();
    if (!mounted) return;
    setState(() => _checkingEmail = false);

    if (verified) {
      // Move to phone step and send OTP
      setState(() {
        _step = 1;
        _sendingOtp = true;
      });
      _sendOtp();
    } else {
      _showSnack(
        'Email not yet verified. Please check your inbox.',
        AppColors.warning,
      );
    }
  }

  Future<void> _resendEmail() async {
    setState(() => _resendingEmail = true);
    await context.read<AuthProvider>().resendVerificationEmail();
    if (!mounted) return;
    setState(() => _resendingEmail = false);
    _showSnack('Verification email resent!', AppColors.success);
  }

  // ── Phone step ──────────────────────────────────────────────────────────

  Future<void> _sendOtp() async {
    final authProvider = context.read<AuthProvider>();
    final sent = await authProvider.sendOtp('+91${widget.phoneNumber}');
    if (!mounted) return;
    setState(() => _sendingOtp = false);
    if (sent) {
      _startTimer();
    } else {
      _showSnack(authProvider.error ?? 'Failed to send OTP', AppColors.error);
    }
  }

  void _startTimer() {
    _secondsRemaining = 60;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_secondsRemaining > 0) {
        setState(() => _secondsRemaining--);
      } else {
        t.cancel();
      }
    });
  }

  void _onAutoVerify() {
    if (!mounted || _step != 1) return;
    final cred = context.read<AuthProvider>().autoCredential;
    if (cred != null) _completeRegistration('');
  }

  void _verifyOtp() {
    final otp = _otpControllers.map((c) => c.text).join();
    if (otp.length != 6) {
      _showSnack('Please enter the complete 6-digit OTP', AppColors.warning);
      return;
    }
    _completeRegistration(otp);
  }

  Future<void> _completeRegistration(String otp) async {
    if (_otpLoading) return;
    setState(() => _otpLoading = true);
    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.linkPhoneAndSaveProfile(
      otp: otp,
      email: widget.email,
      registrationData: widget.registrationData,
    );
    if (!mounted) return;
    setState(() => _otpLoading = false);

    if (success) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const PendingApprovalScreen()),
        (_) => false,
      );
    } else {
      _showSnack(authProvider.error ?? 'Verification failed', AppColors.error);
    }
  }

  void _resendOtp() async {
    if (_secondsRemaining > 0) return;
    setState(() => _resendingOtp = true);
    final authProvider = context.read<AuthProvider>();
    final sent = await authProvider.resendOtp('+91${widget.phoneNumber}');
    if (!mounted) return;
    setState(() => _resendingOtp = false);
    if (sent) {
      _startTimer();
      _showSnack('OTP sent successfully', AppColors.success);
    } else {
      _showSnack(authProvider.error ?? 'Failed to resend OTP', AppColors.error);
    }
  }

  void _onOtpChanged(String value, int index) {
    if (value.isNotEmpty && index < 5) {
      _focusNodes[index + 1].requestFocus();
    }
    if (index == 5 && value.isNotEmpty) {
      if (_otpControllers.every((c) => c.text.isNotEmpty)) _verifyOtp();
    }
    setState(() {});
  }

  Future<void> _cancel() async {
    await context.read<AuthProvider>().signOut();
    if (!mounted) return;
    Navigator.pop(context);
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(_step == 0 ? 'Verify Email' : 'Verify Phone'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _cancel,
          tooltip: 'Cancel',
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          child: Column(
            children: [
              // Step indicator
              _stepIndicator(),
              const SizedBox(height: 32),
              if (_step == 0) _emailBody(),
              if (_step == 1) _phoneBody(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Step indicator ──────────────────────────────────────────────────────

  Widget _stepIndicator() {
    return Row(
      children: [
        _stepBadge(0, 'Email'),
        Expanded(
          child: Container(
            height: 2,
            color: _step >= 1 ? AppColors.primary : AppColors.border,
          ),
        ),
        _stepBadge(1, 'Phone'),
      ],
    );
  }

  Widget _stepBadge(int index, String label) {
    final active = _step >= index;
    return Column(
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: active ? AppColors.primary : AppColors.border,
          child: active && _step > index
              ? const Icon(Icons.check, size: 16, color: Colors.white)
              : Text(
                  '${index + 1}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: active ? Colors.white : AppColors.textHint,
                  ),
                ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: active ? AppColors.textPrimary : AppColors.textHint,
          ),
        ),
      ],
    );
  }

  // ── Email body ──────────────────────────────────────────────────────────

  Widget _emailBody() {
    return Column(
      children: [
        Container(
          width: 90,
          height: 90,
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.mark_email_unread_outlined,
            size: 44,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Check your inbox',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
              height: 1.5,
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
                text: '\n\nClick the link in the email, then tap below.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 36),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            onPressed: _checkingEmail ? null : _checkEmailVerified,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              elevation: 0,
            ),
            child: _checkingEmail
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    "I've verified my email →",
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
          ),
        ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: _resendingEmail ? null : _resendEmail,
          child: Text(
            _resendingEmail ? 'Sending...' : 'Resend verification email',
            style: TextStyle(
              color: _resendingEmail ? AppColors.textHint : AppColors.primary,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }

  // ── Phone body ──────────────────────────────────────────────────────────

  Widget _phoneBody() {
    if (_sendingOtp) {
      return Column(
        children: [
          const SizedBox(height: 48),
          const SizedBox(
            height: 28,
            width: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Sending OTP to +91 ${widget.phoneNumber}...',
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        Container(
          width: 90,
          height: 90,
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.phone_android,
            size: 44,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Verify your phone',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
              height: 1.5,
            ),
            children: [
              const TextSpan(text: 'Enter the 6-digit code sent to\n'),
              TextSpan(
                text: '+91 ${widget.phoneNumber}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),

        // OTP fields
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(6, (i) {
            final filled = _otpControllers[i].text.isNotEmpty;
            return Container(
              width: 48,
              height: 56,
              margin: EdgeInsets.only(left: i > 0 ? 8 : 0),
              child: TextFormField(
                controller: _otpControllers[i],
                focusNode: _focusNodes[i],
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                maxLength: 1,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
                decoration: InputDecoration(
                  counterText: '',
                  contentPadding: EdgeInsets.zero,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: filled ? AppColors.primary : AppColors.border,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: AppColors.primary,
                      width: 2,
                    ),
                  ),
                ),
                onChanged: (v) => _onOtpChanged(v, i),
              ),
            );
          }),
        ),
        const SizedBox(height: 28),

        // Verify button
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            onPressed: _otpLoading ? null : _verifyOtp,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              elevation: 0,
            ),
            child: _otpLoading
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'Verify & Complete',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
          ),
        ),
        const SizedBox(height: 16),

        // Resend OTP
        TextButton(
          onPressed: (_secondsRemaining > 0 || _resendingOtp)
              ? null
              : _resendOtp,
          child: Text(
            _resendingOtp
                ? 'Sending...'
                : _secondsRemaining > 0
                ? 'Resend OTP in ${_secondsRemaining}s'
                : 'Resend OTP',
            style: TextStyle(
              color: (_secondsRemaining > 0 || _resendingOtp)
                  ? AppColors.textHint
                  : AppColors.primary,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}
