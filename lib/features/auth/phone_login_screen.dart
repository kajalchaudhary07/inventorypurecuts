import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/profile_setup_screen.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';
import 'package:purecuts/features/auth/pending_approval_screen.dart';
import 'package:purecuts/features/main_nav/main_nav_screen.dart';

/// Phone-number-based login screen for returning users.
/// Phase 1: Enter phone number → send OTP.
/// Phase 2: Enter OTP → sign in with signInWithPhoneOtp().
class PhoneLoginScreen extends StatefulWidget {
  const PhoneLoginScreen({super.key});

  @override
  State<PhoneLoginScreen> createState() => _PhoneLoginScreenState();
}

class _PhoneLoginScreenState extends State<PhoneLoginScreen> {
  final _phoneController = TextEditingController();
  final List<TextEditingController> _otpControllers = List.generate(
    6,
    (_) => TextEditingController(),
  );
  final List<FocusNode> _focusNodes = List.generate(6, (_) => FocusNode());

  bool _otpSent = false;
  bool _loading = false;
  bool _resending = false;
  int _secondsRemaining = 60;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AuthProvider>().addListener(_onAutoVerify);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _phoneController.dispose();
    for (final c in _otpControllers) c.dispose();
    for (final n in _focusNodes) n.dispose();
    try {
      context.read<AuthProvider>().removeListener(_onAutoVerify);
    } catch (_) {}
    super.dispose();
  }

  // Android auto-verified — the provider sets autoCredential; listen and act.
  void _onAutoVerify() {
    if (!mounted || !_otpSent) return;
    if (context.read<AuthProvider>().autoCredential != null) {
      _autoCompleteLogin();
    }
  }

  Future<void> _autoCompleteLogin() async {
    if (_loading) return;
    setState(() => _loading = true);
    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.signInWithPhoneOtp('');
    if (!mounted) return;
    setState(() => _loading = false);
    if (success) {
      await _goHome(authProvider);
    } else {
      _showError(authProvider.error ?? 'Auto-verification failed.');
    }
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
      setState(() {
        _otpSent = true;
        _secondsRemaining = 60;
      });
      _startTimer();
    } else {
      _showError(authProvider.error ?? 'Failed to send OTP.');
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _secondsRemaining = 60;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_secondsRemaining > 0) {
        setState(() => _secondsRemaining--);
      } else {
        t.cancel();
      }
    });
  }

  Future<void> _verifyOtp() async {
    final otp = _otpControllers.map((c) => c.text).join();
    if (otp.length != 6) {
      _showError('Please enter the complete 6-digit OTP.');
      return;
    }
    setState(() => _loading = true);
    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.signInWithPhoneOtp(otp);
    if (!mounted) return;
    setState(() => _loading = false);
    if (success) {
      await _goHome(authProvider);
    } else {
      _showError(authProvider.error ?? 'Verification failed.');
    }
  }

  Future<void> _resendOtp() async {
    if (_secondsRemaining > 0) return;
    setState(() => _resending = true);
    final authProvider = context.read<AuthProvider>();
    final sent = await authProvider.resendOtp(
      '+91${_phoneController.text.trim()}',
    );
    if (!mounted) return;
    setState(() => _resending = false);
    if (sent) {
      _startTimer();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('OTP resent'),
          backgroundColor: AppColors.success,
        ),
      );
    } else {
      _showError(authProvider.error ?? 'Failed to resend OTP.');
    }
  }

  void _onOtpChanged(String value, int index) {
    if (value.isNotEmpty && index < 5) {
      _focusNodes[index + 1].requestFocus();
    }
    if (index == 5 && value.isNotEmpty) {
      if (_otpControllers.every((c) => c.text.isNotEmpty)) {
        _verifyOtp();
      }
    }
    setState(() {});
  }

  Future<void> _goHome(AuthProvider authProvider) async {
    final gate = await authProvider.getCurrentUserAccessState();
    if (!mounted) return;

    if (!gate.exists) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => ProfileSetupScreen(
            phoneNumber: '+91${_phoneController.text.trim()}',
          ),
        ),
        (_) => false,
      );
      return;
    }

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => gate.isApproved
            ? const MainNavScreen()
            : const PendingApprovalScreen(),
      ),
      (_) => false,
    );
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
      appBar: AppBar(title: Text(_otpSent ? 'Verify OTP' : 'Login with Phone')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: _otpSent ? _buildOtpPhase() : _buildPhonePhase(),
        ),
      ),
    );
  }

  // ── Phase 1: Phone entry ──────────────────────────────────────────────────

  Widget _buildPhonePhase() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.phone_android,
              size: 40,
              color: AppColors.primary,
            ),
          ),
        ),
        const SizedBox(height: 28),
        const Center(
          child: Text(
            'Enter your phone number',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
              letterSpacing: -0.5,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 8),
        const Center(
          child: Text(
            "We'll send a one-time password to verify your identity.",
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 36),
        const Text(
          'Phone Number',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
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
            prefixIcon: Icon(
              Icons.phone_outlined,
              size: 20,
              color: AppColors.textHint,
            ),
            prefixText: '+91 ',
            prefixStyle: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
          onSubmitted: (_) => _sendOtp(),
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            onPressed: _loading ? null : _sendOtp,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              elevation: 0,
            ),
            child: _loading
                ? const SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'Send OTP',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
          ),
        ),
      ],
    );
  }

  // ── Phase 2: OTP entry ────────────────────────────────────────────────────

  Widget _buildOtpPhase() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.lock_clock_outlined,
            size: 40,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(height: 28),
        const Text(
          'Enter OTP',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
              height: 1.5,
            ),
            children: [
              const TextSpan(text: 'Code sent to '),
              TextSpan(
                text: '+91 ${_phoneController.text.trim()}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 36),

        // OTP boxes
        Row(
          children: List.generate(6, (index) {
            return Expanded(
              child: Container(
                height: 54,
                margin: EdgeInsets.only(left: index == 0 ? 0 : 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _otpControllers[index].text.isNotEmpty
                        ? AppColors.primary
                        : AppColors.border,
                    width: _otpControllers[index].text.isNotEmpty ? 2 : 1,
                  ),
                ),
                child: TextField(
                  controller: _otpControllers[index],
                  focusNode: _focusNodes[index],
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  maxLength: 1,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    counterText: '',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onChanged: (v) => _onOtpChanged(v, index),
                  onTap: () {
                    _otpControllers[index].clear();
                    setState(() {});
                  },
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 28),

        // Resend timer
        if (_secondsRemaining > 0)
          Text(
            'Resend code in ${_secondsRemaining}s',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
          )
        else
          GestureDetector(
            onTap: _resending ? null : _resendOtp,
            child: Text(
              _resending ? 'Sending...' : 'Resend Code',
              style: TextStyle(
                color: _resending ? AppColors.textHint : AppColors.primary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        const SizedBox(height: 32),

        // Verify button
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            onPressed: _loading ? null : _verifyOtp,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              elevation: 0,
            ),
            child: _loading
                ? const SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'Verify & Sign In',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
          ),
        ),
        const SizedBox(height: 20),

        // Change phone number
        TextButton(
          onPressed: () => setState(() {
            _otpSent = false;
            for (final c in _otpControllers) c.clear();
            _timer?.cancel();
          }),
          child: const Text(
            'Change phone number',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
