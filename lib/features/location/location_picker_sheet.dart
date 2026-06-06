import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/theme/app_theme.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';

class LocationPickerSheet extends StatefulWidget {
  const LocationPickerSheet({super.key});

  @override
  State<LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<LocationPickerSheet> {
  final _manualController = TextEditingController();
  bool _detecting = false;
  String? _detectedAddress;
  String? _error;

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  Future<void> _useCurrentLocation() async {
    setState(() {
      _detecting = true;
      _error = null;
      _detectedAddress = null;
    });

    try {
      // Check permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(() {
          _error = 'Location permission denied. Please enter area manually.';
          _detecting = false;
        });
        return;
      }

      // Check service
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _error = 'Please enable location services on your device.';
          _detecting = false;
        });
        return;
      }

      // Try last known position first (instant)
      Position? position = await Geolocator.getLastKnownPosition();

      // If no cached position, get current one
      position ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 30),
        ),
      );

      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isEmpty) throw Exception('No address found');

      final p = placemarks.first;
      // Show area + city only (e.g. "Wagholi, Pune") — skip state for brevity
      final parts = <String>[];
      if (p.subLocality != null && p.subLocality!.isNotEmpty) {
        parts.add(p.subLocality!);
      }
      if (p.locality != null && p.locality!.isNotEmpty) {
        parts.add(p.locality!);
      }
      // Fallback to administrativeArea if no locality found
      if (parts.isEmpty &&
          p.administrativeArea != null &&
          p.administrativeArea!.isNotEmpty) {
        parts.add(p.administrativeArea!);
      }

      setState(() {
        _detectedAddress = parts.join(', ');
        _detecting = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not detect location: ${e.runtimeType}. Please enter manually.';
        _detecting = false;
      });
    }
  }

  Future<void> _saveAddress(String address) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return;
    await context.read<AuthProvider>().updateAddress(trimmed);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final currentAddress = context.read<AuthProvider>().user?.address;

    return Container(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 32,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          const Text(
            'Select delivery location',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Products will be delivered to this address',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),

          // Current saved address banner
          if (currentAddress != null && currentAddress.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.location_on_rounded,
                      color: AppColors.primary, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      currentAddress,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 20),

          // Use current location button
          InkWell(
            onTap: _detecting ? null : _useCurrentLocation,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                border: Border.all(
                    color: AppColors.primary.withOpacity(0.3), width: 1.5),
                borderRadius: BorderRadius.circular(12),
                color: AppColors.primary.withOpacity(0.03),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: _detecting
                        ? Padding(
                            padding: const EdgeInsets.all(10),
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: AppColors.primary,
                            ),
                          )
                        : const Icon(Icons.my_location_rounded,
                            color: AppColors.primary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _detecting
                              ? 'Detecting your location...'
                              : 'Use my current location',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                        if (_detectedAddress != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            _detectedAddress!,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ] else if (!_detecting) ...[
                          const SizedBox(height: 2),
                          const Text(
                            'Using GPS to find your area',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textHint,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_detectedAddress != null)
                    TextButton(
                      onPressed: () => _saveAddress(_detectedAddress!),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                      ),
                      child: const Text('Use',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                ],
              ),
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.info_outline, size: 14, color: Colors.red),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _error!,
                    style: const TextStyle(fontSize: 12, color: Colors.red),
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 20),

          // OR divider
          Row(
            children: [
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'OR',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade400,
                    letterSpacing: 1,
                  ),
                ),
              ),
              const Expanded(child: Divider()),
            ],
          ),

          const SizedBox(height: 16),

          // Manual text entry
          TextField(
            controller: _manualController,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              hintText: 'Enter area, locality or pincode',
              prefixIcon: const Icon(Icons.search_rounded,
                  size: 20, color: AppColors.textHint),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward_rounded,
                    color: AppColors.primary),
                onPressed: () => _saveAddress(_manualController.text),
              ),
            ),
            onSubmitted: _saveAddress,
          ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
