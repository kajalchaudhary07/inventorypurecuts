import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/pending_approval_screen.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';

class PhoneVerificationScreen extends StatefulWidget {
  final String phoneNumber;
  final Map<String, dynamic> registrationData;

  const PhoneVerificationScreen({
    super.key,
    required this.phoneNumber,
    required this.registrationData,
  });

  @override
  State<PhoneVerificationScreen> createState() =>
      _PhoneVerificationScreenState();
}

class _PhoneVerificationScreenState extends State<PhoneVerificationScreen> {
  final List<TextEditingController> _otpControllers = List.generate(
    6,
    (_) => TextEditingController(),
  );
  final List<FocusNode> _focusNodes = List.generate(6, (_) => FocusNode());

  bool _loading = false;
  bool _resending = false;
  bool _sendingInitial = true;
  bool _sendFailed = false;
  String? _sendError;
  int _secondsRemaining = 60;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Send OTP when the screen opens (not from login screen)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sendInitialOtp();
      // Listen for Android auto-verification
      final authProvider = context.read<AuthProvider>();
      authProvider.addListener(_onAutoVerify);
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
    // Remove listener safely
    try {
      context.read<AuthProvider>().removeListener(_onAutoVerify);
    } catch (_) {}
    super.dispose();
  }

  void _onAutoVerify() {
    if (!mounted) return;
    final authProvider = context.read<AuthProvider>();
    final cred = authProvider.autoCredential;
    if (cred != null) {
      // Android auto-verified the phone — complete registration automatically
      _autoCompleteRegistration(cred);
    }
  }

  Future<void> _autoCompleteRegistration(dynamic phoneCredential) async {
    if (_loading) return;
    setState(() => _loading = true);
    final authProvider = context.read<AuthProvider>();
    // The auto-credential is already stored in the provider; pass empty OTP.
    final success = await authProvider.linkPhoneAndSaveProfile(
      otp: '',
      email: (widget.registrationData['email'] as String?) ?? '',
      registrationData: widget.registrationData,
    );
    if (!mounted) return;
    setState(() => _loading = false);

    if (success) {
      _navigateToHome();
    } else {
      _showError(authProvider.error ?? 'Auto-verification failed');
    }
  }

  Future<void> _sendInitialOtp() async {
    setState(() {
      _sendFailed = false;
      _sendError = null;
    });
    final authProvider = context.read<AuthProvider>();
    final sent = await authProvider.sendOtp('+91${widget.phoneNumber}');
    if (!mounted) return;
    setState(() {
      _sendingInitial = false;
      _sendFailed = !sent;
      _sendError = sent ? null : (authProvider.error ?? 'Failed to send OTP');
    });
    if (sent) {
      _startTimer();
    }
  }

  void _startTimer() {
    _secondsRemaining = 60;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 0) {
        setState(() => _secondsRemaining--);
      } else {
        timer.cancel();
      }
    });
  }

  void _verifyOtp() async {
    final otp = _otpControllers.map((c) => c.text).join();
    if (otp.length != 6) {
      _showError('Please enter the complete 6-digit OTP');
      return;
    }

    setState(() => _loading = true);
    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.linkPhoneAndSaveProfile(
      otp: otp,
      email: (widget.registrationData['email'] as String?) ?? '',
      registrationData: widget.registrationData,
    );
    if (!mounted) return;
    setState(() => _loading = false);

    if (success) {
      _navigateToHome();
    } else {
      _showError(authProvider.error ?? 'Verification failed');
    }
  }

  void _resendOtp() async {
    if (_secondsRemaining > 0) return;
    setState(() => _resending = true);
    final authProvider = context.read<AuthProvider>();
    final sent = await authProvider.resendOtp('+91${widget.phoneNumber}');
    if (!mounted) return;
    setState(() => _resending = false);
    if (sent) {
      _startTimer();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('OTP sent successfully'),
          backgroundColor: AppColors.success,
        ),
      );
    } else {
      _showError(authProvider.error ?? 'Failed to resend OTP');
    }
  }

  void _onOtpChanged(String value, int index) {
    if (value.isNotEmpty && index < 5) {
      _focusNodes[index + 1].requestFocus();
    }
    // Auto-verify when all 6 digits are filled
    if (index == 5 && value.isNotEmpty) {
      if (_otpControllers.every((c) => c.text.isNotEmpty)) {
        _verifyOtp();
      }
    }
    setState(() {}); // refresh border colors
  }

  void _navigateToHome() {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const PendingApprovalScreen()),
      (_) => false,
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.error),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify Phone'), elevation: 0),
      body: Stack(
        children: [
          // Background
          Positioned.fill(
            child: Container(
              color: const Color(0xFFf8f5ff),
              child: Opacity(
                opacity: 0.15,
                child: Image.asset(
                  'assets/background/background.png',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
          // Content — wrapped in SingleChildScrollView to prevent overflow
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 32,
                    ),
                    child: IntrinsicHeight(
                      child: Column(
                        children: [
                          const SizedBox(height: 24),

                          // Icon
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

                          // Title
                          const Text(
                            'Verify your phone number',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 10),

                          // Description
                          RichText(
                            textAlign: TextAlign.center,
                            text: TextSpan(
                              style: const TextStyle(
                                fontSize: 14,
                                color: AppColors.textSecondary,
                                height: 1.5,
                              ),
                              children: [
                                TextSpan(
                                  text: _sendingInitial
                                      ? 'Sending verification code to\n'
                                      : 'We sent a verification code to\n',
                                ),
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

                          // Sending spinner or error state
                          if (_sendingInitial) ...[
                            const SizedBox(height: 32),
                            const SizedBox(
                              height: 28,
                              width: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: AppColors.primary,
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Sending OTP...',
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ] else if (_sendFailed) ...[
                            const SizedBox(height: 32),
                            Container(
                              width: 70,
                              height: 70,
                              decoration: BoxDecoration(
                                color: AppColors.error.withOpacity(0.1),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.error_outline,
                                size: 36,
                                color: AppColors.error,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _sendError ?? 'Failed to send OTP',
                              style: const TextStyle(
                                color: AppColors.error,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: ElevatedButton.icon(
                                onPressed: _sendInitialOtp,
                                icon: const Icon(Icons.refresh, size: 20),
                                label: const Text('Retry'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  elevation: 0,
                                ),
                              ),
                            ),
                          ],

                          // OTP fields and rest — only shown after OTP is sent
                          if (!_sendingInitial && !_sendFailed) ...[
                            const SizedBox(height: 36),

                            // OTP Input Fields
                            Row(
                              children: List.generate(6, (index) {
                                return Expanded(
                                  child: Container(
                                    height: 54,
                                    margin: EdgeInsets.only(
                                      left: index == 0 ? 0 : 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color:
                                            _otpControllers[index]
                                                .text
                                                .isNotEmpty
                                            ? AppColors.primary
                                            : AppColors.border,
                                        width:
                                            _otpControllers[index]
                                                .text
                                                .isNotEmpty
                                            ? 2
                                            : 1,
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
                                      inputFormatters: [
                                        FilteringTextInputFormatter.digitsOnly,
                                      ],
                                      decoration: const InputDecoration(
                                        counterText: '',
                                        border: InputBorder.none,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                      onChanged: (value) =>
                                          _onOtpChanged(value, index),
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

                            // Resend OTP
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
                                    color: _resending
                                        ? AppColors.textHint
                                        : AppColors.primary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                          ],

                          const Spacer(),

                          // Verify button
                          if (!_sendingInitial && !_sendFailed)
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: ElevatedButton(
                                onPressed: _loading ? null : _verifyOtp,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
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
                                        'Verify & Continue',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                              ),
                            ),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
