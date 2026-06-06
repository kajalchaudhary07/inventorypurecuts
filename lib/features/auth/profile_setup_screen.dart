import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/pending_approval_screen.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';

class ProfileSetupScreen extends StatefulWidget {
  final String phoneNumber;
  const ProfileSetupScreen({super.key, required this.phoneNumber});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();

  final _salonNameController = TextEditingController();
  final _ownerNameController = TextEditingController();
  final _gstController = TextEditingController();
  final _udyamController = TextEditingController();
  final _stateController = TextEditingController();
  final _pincodeController = TextEditingController();
  final _emailController = TextEditingController();

  bool _loading = false;

  @override
  void dispose() {
    _salonNameController.dispose();
    _ownerNameController.dispose();
    _gstController.dispose();
    _udyamController.dispose();
    _stateController.dispose();
    _pincodeController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _completeSetup() async {
    if (!_formKey.currentState!.validate()) return;

    final gst = _gstController.text.trim().toUpperCase();
    final udyam = _udyamController.text.trim().toUpperCase();

    if (gst.isEmpty && udyam.isEmpty) {
      _showError('Please provide at least GST Number or Udyam Number');
      return;
    }

    setState(() => _loading = true);

    final data = {
      'salonName': _salonNameController.text.trim(),
      'ownerName': _ownerNameController.text.trim(),
      'gst': gst,
      'udyamNumber': udyam,
      'country': 'India',
      'state': _stateController.text.trim(),
      'pincode': _pincodeController.text.trim(),
      'email': _emailController.text.trim(),
      'phone': widget.phoneNumber,
    };

    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.saveNewUserProfile(data);

    if (!mounted) return;
    setState(() => _loading = false);

    if (success) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const PendingApprovalScreen()),
        (_) => false,
      );
    } else {
      _showError(authProvider.error ?? 'Setup failed. Please try again.');
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
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: false,
        title: const Text(
          'Salon Setup',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          children: [
            // ── Greeting ──────────────────────────────────────────────
            const Text(
              'Almost done!',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Tell us a bit about your salon to get started.',
              style: TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 28),

            // ── Salon Name ────────────────────────────────────────────
            _buildLabel('Salon Name'),
            const SizedBox(height: 6),
            _buildField(
              controller: _salonNameController,
              hint: 'e.g. Glamour Studio',
              icon: Icons.storefront_outlined,
              validator: _required('Salon name'),
            ),
            const SizedBox(height: 16),

            // ── Owner Name ────────────────────────────────────────────
            _buildLabel('Owner Name'),
            const SizedBox(height: 6),
            _buildField(
              controller: _ownerNameController,
              hint: 'Your full name',
              icon: Icons.person_outline_rounded,
              validator: _required('Owner name'),
            ),
            const SizedBox(height: 16),

            // ── Email (optional) ──────────────────────────────────────
            _buildLabel('Email Address', optional: true),
            const SizedBox(height: 6),
            _buildField(
              controller: _emailController,
              hint: 'salon@example.com',
              icon: Icons.email_outlined,
              inputType: TextInputType.emailAddress,
              validator: (v) {
                final val = v?.trim() ?? '';
                if (val.isEmpty) return null;
                if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(val)) {
                  return 'Enter a valid email address';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // ── GST (required) ────────────────────────────────────────
            _buildLabel('GST Number'),
            const SizedBox(height: 6),
            _buildField(
              controller: _gstController,
              hint: '22AAAAA0000A1Z5',
              icon: Icons.receipt_long_outlined,
              caps: TextCapitalization.characters,
              formatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                LengthLimitingTextInputFormatter(15),
              ],
              validator: (v) {
                final value = (v ?? '').trim();
                if (value.isEmpty) return null;
                if (value.length != 15)
                  return 'GST Number must be exactly 15 characters';
                return null;
              },
            ),
            const SizedBox(height: 16),

            // ── Udyam (required) ──────────────────────────────────────
            _buildLabel('Udyam Number'),
            const SizedBox(height: 6),
            _buildField(
              controller: _udyamController,
              hint: 'UDYAM-XX-00-0000000',
              icon: Icons.verified_user_outlined,
              caps: TextCapitalization.characters,
              formatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                LengthLimitingTextInputFormatter(16),
              ],
              validator: (v) {
                final value = (v ?? '').trim();
                if (value.isEmpty) return null;
                if (value.length != 16)
                  return 'Udyam Number must be exactly 16 characters';
                return null;
              },
            ),
            const SizedBox(height: 16),

            // ── State + Pincode Row ───────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildLabel('State'),
                      const SizedBox(height: 6),
                      _buildField(
                        controller: _stateController,
                        hint: 'Maharashtra',
                        icon: Icons.location_city_outlined,
                        validator: _required('State'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildLabel('Pincode'),
                      const SizedBox(height: 6),
                      _buildField(
                        controller: _pincodeController,
                        hint: '400001',
                        icon: Icons.pin_drop_outlined,
                        inputType: TextInputType.number,
                        formatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'Required';
                          if (v.trim().length != 6) return '6 digits';
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 36),

            // ── Submit Button ─────────────────────────────────────────
            SizedBox(
              height: 56,
              child: ElevatedButton(
                onPressed: _loading ? null : _completeSetup,
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
                        'Request Access',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Widget _buildLabel(String label, {bool optional = false}) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        if (optional) ...[
          const SizedBox(width: 6),
          const Text(
            'optional',
            style: TextStyle(fontSize: 11, color: AppColors.textHint),
          ),
        ],
      ],
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    TextInputType inputType = TextInputType.text,
    TextCapitalization caps = TextCapitalization.words,
    List<TextInputFormatter>? formatters,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: inputType,
      textCapitalization: caps,
      inputFormatters: formatters,
      validator: validator,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon, size: 18, color: AppColors.textHint),
      ),
    );
  }

  String? Function(String?) _required(String fieldName) {
    return (v) {
      if (v == null || v.trim().isEmpty) return '$fieldName is required';
      return null;
    };
  }
}
