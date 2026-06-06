import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';
import 'package:purecuts/features/auth/verification_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _salonNameController = TextEditingController();
  final _ownerNameController = TextEditingController();
  final _gstController = TextEditingController();
  final _countryController = TextEditingController(text: 'India');
  final _stateController = TextEditingController();
  final _pincodeController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _salonNameController.dispose();
    _ownerNameController.dispose();
    _gstController.dispose();
    _countryController.dispose();
    _stateController.dispose();
    _pincodeController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Map<String, dynamic> _registrationData() => {
    'salonName': _salonNameController.text.trim(),
    'ownerName': _ownerNameController.text.trim(),
    'gst': _gstController.text.trim(),
    'country': _countryController.text.trim(),
    'state': _stateController.text.trim(),
    'pincode': _pincodeController.text.trim(),
    'email': _emailController.text.trim(),
    'phone': _phoneController.text.trim(),
  };

  void _handleRegister() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _loading = true);
    final authProvider = context.read<AuthProvider>();

    final success = await authProvider.createEmailAccount(
      _emailController.text.trim(),
      _passwordController.text,
    );
    if (!mounted) return;
    setState(() => _loading = false);

    if (!success) {
      _showError(
        authProvider.error ?? 'Registration failed. Please try again.',
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VerificationScreen(
          email: _emailController.text.trim(),
          phoneNumber: _phoneController.text.trim(),
          registrationData: _registrationData(),
        ),
      ),
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
      body: Stack(
        children: [
          Positioned.fill(
            child: Opacity(
              opacity: 0.12,
              child: Image.asset(
                'assets/background/background.png',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: const Icon(
                        Icons.arrow_back_ios,
                        color: AppColors.textPrimary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'Register your salon',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Fill in your details to get started',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 28),

                    // ── Salon details ──────────────────────────────────
                    _sectionLabel('Salon Details'),
                    const SizedBox(height: 12),
                    _field(
                      controller: _salonNameController,
                      label: 'Salon Name',
                      icon: Icons.storefront_outlined,
                      hint: 'e.g. Royal Cuts',
                      validator: _required,
                    ),
                    const SizedBox(height: 14),
                    _field(
                      controller: _ownerNameController,
                      label: 'Owner Name',
                      icon: Icons.person_outline,
                      hint: 'Your full name',
                      validator: _required,
                    ),
                    const SizedBox(height: 14),
                    _field(
                      controller: _gstController,
                      label: 'GST Number (Optional)',
                      icon: Icons.receipt_long_outlined,
                      hint: 'e.g. 22ABCDE1234F1Z5',
                    ),
                    const SizedBox(height: 20),

                    // ── Location details ───────────────────────────────
                    _sectionLabel('Location'),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _field(
                            controller: _countryController,
                            label: 'Country',
                            icon: Icons.public,
                            hint: 'India',
                            validator: _required,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _field(
                            controller: _stateController,
                            label: 'State',
                            icon: Icons.location_city_outlined,
                            hint: 'Maharashtra',
                            validator: _required,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _field(
                      controller: _pincodeController,
                      label: 'Pincode',
                      icon: Icons.pin_drop_outlined,
                      hint: '411001',
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // ── Account details ────────────────────────────────
                    _sectionLabel('Account'),
                    const SizedBox(height: 12),
                    _field(
                      controller: _emailController,
                      label: 'Email Address',
                      icon: Icons.email_outlined,
                      hint: 'you@example.com',
                      keyboardType: TextInputType.emailAddress,
                      validator: (v) {
                        if (v?.trim().isEmpty ?? true) return 'Required';
                        if (!RegExp(
                          r'^[\w\-.]+@([\w-]+\.)+[\w-]{2,}$',
                        ).hasMatch(v!.trim())) {
                          return 'Enter a valid email';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    _phoneField(),
                    const SizedBox(height: 14),
                    _passwordField(),
                    const SizedBox(height: 32),

                    // ── Register button ────────────────────────────────
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton(
                        onPressed: _loading ? null : _handleRegister,
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
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : const Text(
                                'Create Account',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── Sign in link ───────────────────────────────────
                    Center(
                      child: GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: RichText(
                          text: const TextSpan(
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.textSecondary,
                            ),
                            children: [
                              TextSpan(text: 'Already have an account? '),
                              TextSpan(
                                text: 'Sign In',
                                style: TextStyle(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Reusable widgets ────────────────────────────────────────────────────

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      ),
    );
  }

  String? _required(String? v) =>
      (v?.trim().isEmpty ?? true) ? 'Required' : null;

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required String hint,
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          validator: validator,
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: Icon(icon, size: 20, color: AppColors.textHint),
          ),
        ),
      ],
    );
  }

  Widget _phoneField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Phone Number',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: _phoneController,
          keyboardType: TextInputType.phone,
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
          validator: (v) {
            if (v?.trim().isEmpty ?? true) return 'Required';
            if (v!.trim().length != 10) return 'Must be 10 digits';
            return null;
          },
        ),
      ],
    );
  }

  Widget _passwordField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Password',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          decoration: InputDecoration(
            hintText: 'At least 6 characters',
            prefixIcon: const Icon(
              Icons.lock_outline,
              size: 20,
              color: AppColors.textHint,
            ),
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                color: AppColors.textHint,
                size: 20,
              ),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          validator: (v) {
            if (v == null || v.isEmpty) return 'Required';
            if (v.length < 6) return 'At least 6 characters';
            return null;
          },
        ),
      ],
    );
  }
}
