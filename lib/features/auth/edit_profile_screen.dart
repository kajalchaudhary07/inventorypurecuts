import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _salonNameController = TextEditingController();
  final _ownerNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _stateController = TextEditingController();
  final _pincodeController = TextEditingController();
  final _addressController = TextEditingController();
  final _gstController = TextEditingController();

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  void _loadUserData() {
    final user = context.read<AuthProvider>().user;
    if (user != null) {
      _salonNameController.text = user.salonName ?? '';
      _ownerNameController.text = user.ownerName ?? user.name;
      _phoneController.text = user.phone ?? '';
      _emailController.text = user.email;
      _stateController.text = user.state ?? '';
      _pincodeController.text = user.pincode ?? '';
      _addressController.text = user.address ?? '';
      _gstController.text = user.gst ?? '';
    }
  }

  @override
  void dispose() {
    _salonNameController.dispose();
    _ownerNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _stateController.dispose();
    _pincodeController.dispose();
    _addressController.dispose();
    _gstController.dispose();
    super.dispose();
  }

  Future<void> _saveChanges() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);

    final authProvider = context.read<AuthProvider>();
    final updateData = {
      'salonName': _salonNameController.text.trim(),
      'ownerName': _ownerNameController.text.trim(),
      'phone': _phoneController.text.trim(),
      'email': _emailController.text.trim(),
      'state': _stateController.text.trim(),
      'pincode': _pincodeController.text.trim(),
      'address': _addressController.text.trim(),
      'gst': _gstController.text.trim(),
    };

    final success = await authProvider.updateUserProfile(updateData);

    if (!mounted) return;
    setState(() => _loading = false);

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Profile updated successfully'),
          backgroundColor: Color(0xFF22C55E),
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(authProvider.error ?? 'Failed to update profile'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1E5FF),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF1E5FF),
        elevation: 0,
        flexibleSpace: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFF0DEFF), Color(0xFFE8D2FF)],
            ),
          ),
        ),
        title: const Text(
          'Edit Profile',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFEFDCFF), Color(0xFFE6CEFF), Color(0xFFF4E8FF)],
          ),
        ),
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // Salon Name
              _buildLabel('Salon Name', required: false),
              const SizedBox(height: 8),
              _buildTextField(
                controller: _salonNameController,
                hint: 'Your salon name',
                icon: Icons.storefront_outlined,
              ),
              const SizedBox(height: 20),

              // Owner Name
              _buildLabel('Owner Name', required: true),
              const SizedBox(height: 8),
              _buildTextField(
                controller: _ownerNameController,
                hint: 'Your full name',
                icon: Icons.person_outline,
                validator: (v) {
                  if (v == null || v.trim().isEmpty)
                    return 'Owner name is required';
                  return null;
                },
              ),
              const SizedBox(height: 20),

              // Phone
              _buildLabel('Phone Number', required: true),
              const SizedBox(height: 8),
              _buildTextField(
                controller: _phoneController,
                hint: '10-digit phone number',
                icon: Icons.phone_outlined,
                inputType: TextInputType.phone,
                formatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
                ],
                validator: (v) {
                  if (v == null || v.trim().isEmpty)
                    return 'Phone number is required';
                  if (v.trim().length != 10)
                    return 'Enter 10-digit phone number';
                  return null;
                },
              ),
              const SizedBox(height: 20),

              // Email
              _buildLabel('Email Address', required: false),
              const SizedBox(height: 8),
              _buildTextField(
                controller: _emailController,
                hint: 'your.email@example.com',
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
              const SizedBox(height: 20),

              // Address
              _buildLabel('Address', required: false),
              const SizedBox(height: 8),
              _buildTextField(
                controller: _addressController,
                hint: 'Street address',
                icon: Icons.location_on_outlined,
                maxLines: 2,
              ),
              const SizedBox(height: 20),

              // State
              _buildLabel('State', required: false),
              const SizedBox(height: 8),
              _buildTextField(
                controller: _stateController,
                hint: 'Maharashtra',
                icon: Icons.location_city_outlined,
              ),
              const SizedBox(height: 20),

              // Pincode
              _buildLabel('Pincode', required: false),
              const SizedBox(height: 8),
              _buildTextField(
                controller: _pincodeController,
                hint: '400001',
                icon: Icons.pin_drop_outlined,
                inputType: TextInputType.number,
                formatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
              ),
              const SizedBox(height: 20),

              // GST
              _buildLabel('GST Number', required: false),
              const SizedBox(height: 8),
              _buildTextField(
                controller: _gstController,
                hint: '22AAAAA0000A1Z5',
                icon: Icons.receipt_long_outlined,
                caps: TextCapitalization.characters,
              ),
              const SizedBox(height: 32),

              // Save Button
              SizedBox(
                height: 56,
                child: ElevatedButton(
                  onPressed: _loading ? null : _saveChanges,
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
                          'Save Changes',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 12),

              // Cancel Button
              SizedBox(
                height: 56,
                child: OutlinedButton(
                  onPressed: _loading ? null : () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.primary),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String text, {bool required = false}) => Text(
    required ? '$text *' : text,
    style: const TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: AppColors.textPrimary,
    ),
  );

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    TextInputType inputType = TextInputType.text,
    TextCapitalization caps = TextCapitalization.none,
    List<TextInputFormatter>? formatters,
    int maxLines = 1,
    String? Function(String?)? validator,
  }) => TextFormField(
    controller: controller,
    decoration: InputDecoration(
      hintText: hint,
      prefixIcon: Icon(icon, color: AppColors.primary, size: 20),
      filled: true,
      fillColor: Colors.white,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.error),
      ),
    ),
    keyboardType: inputType,
    textCapitalization: caps,
    inputFormatters: formatters,
    maxLines: maxLines,
    minLines: maxLines == 1 ? 1 : maxLines,
    validator: validator,
  );
}
