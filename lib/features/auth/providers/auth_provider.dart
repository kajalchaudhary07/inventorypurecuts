import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:purecuts/core/models/user_model.dart';
import 'package:purecuts/core/services/auth_service.dart';
import 'package:purecuts/core/services/payu_payment_service.dart';
import 'package:purecuts/core/services/push_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AuthStatus { initial, loading, authenticated, unauthenticated }

class AuthProvider extends ChangeNotifier {
  final AuthService _service = AuthService();
  static const String _userHeaderCacheKey = 'purecuts_user_header_cache_v2';

  UserModel? _user;
  AuthStatus _status = AuthStatus.initial;
  String? _error;

  // OTP state
  String? _verificationId;
  int? _resendToken;
  PhoneAuthCredential? _autoCredential;

  UserModel? get user => _user;
  AuthStatus get status => _status;
  String? get error => _error;
  PhoneAuthCredential? get autoCredential => _autoCredential;
  bool get isLoading => _status == AuthStatus.loading;
  bool get isAuthenticated => _status == AuthStatus.authenticated;

  AuthProvider() {
    unawaited(_hydrateCachedHeaderUser());
    _service.authStateChanges.listen((firebaseUser) async {
      if (firebaseUser == null) {
        _user = null;
        _status = AuthStatus.unauthenticated;
        unawaited(_clearCachedHeaderUser());
      } else {
        try {
          final cachedUid = (_user?.uid ?? '').trim();
          if (cachedUid.isNotEmpty && cachedUid != firebaseUser.uid) {
            _user = null;
          }
          final freshUser = await _service.getCurrentUserData();
          if (freshUser != null) {
            _user = freshUser;
          }
          if (_user != null) {
            unawaited(_cacheHeaderUser(_user!));
          }
          unawaited(PushNotificationService.instance.syncTokenForCurrentUser());
        } catch (e) {}
        _status = AuthStatus.authenticated;
      }
      notifyListeners();
    });
  }

  Future<void> _hydrateCachedHeaderUser() async {
    final currentUid = (_service.currentUser?.uid ?? '').trim();
    if (currentUid.isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_userHeaderCacheKey);
      if (raw == null || raw.trim().isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(decoded);
      final cachedUid = (map['uid'] ?? '').toString().trim();
      if (cachedUid.isEmpty || cachedUid != currentUid) return;

      final cachedUser = UserModel.fromMap(map, cachedUid);
      if (_user == null) {
        _user = cachedUser;
        notifyListeners();
      }
    } catch (e) {}
  }

  Future<void> _cacheHeaderUser(UserModel user) async {
    try {
      final uid = user.uid.trim();
      if (uid.isEmpty) return;

      final payload = {
        'uid': uid,
        'name': user.name,
        'email': user.email,
        'phone': user.phone,
        'salonName': user.salonName,
        'ownerName': user.ownerName,
        'address': user.address,
        'country': user.country,
        'state': user.state,
        'pincode': user.pincode,
        'deliveryAddressDetails': user.deliveryAddressDetails,
        'contactDetails': user.contactDetails,
        'deliveryDetails': user.deliveryDetails,
      };

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_userHeaderCacheKey, jsonEncode(payload));
    } catch (e) {}
  }

  Future<void> _clearCachedHeaderUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_userHeaderCacheKey);
    } catch (e) {}
  }

  void _setLoading() {
    _status = AuthStatus.loading;
    _error = null;
    notifyListeners();
  }

  void _setError(String message) {
    _error = message;
    _status = AuthStatus.unauthenticated;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  // ── Registration: Create email account with password ────────────────────

  Future<bool> createEmailAccount(String email, String password) async {
    try {
      _setLoading();
      await _service.createEmailAccount(email, password);
      _status = AuthStatus.unauthenticated;
      notifyListeners();
      return true;
    } on FirebaseAuthException catch (e) {
      _setError(_friendlyError(e));
      return false;
    } catch (e) {
      _setError('Failed to create account. Please try again.');
      return false;
    }
  }

  // ── Email Verification Helpers ───────────────────────────────────────────────

  Future<bool> checkEmailVerified() async {
    try {
      return await _service.reloadAndCheckEmailVerified();
    } catch (e) {
      return false;
    }
  }

  Future<void> resendVerificationEmail() async {
    try {
      await _service.resendVerificationEmail();
    } catch (e) {}
  }

  // ── Signup Step 2: Send OTP to phone ─────────────────────────────────────

  Future<bool> sendOtp(String phoneNumber) async {
    final completer = Completer<bool>();
    _autoCredential = null;
    _setLoading();
    try {
      await _service.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        onCodeSent: (verificationId, resendToken) {
          _verificationId = verificationId;
          _resendToken = resendToken;
          _status = AuthStatus.unauthenticated;
          notifyListeners();
          if (!completer.isCompleted) completer.complete(true);
        },
        onFailed: (e) {
          _setError(_friendlyError(e));
          if (!completer.isCompleted) completer.complete(false);
        },
        onAutoVerified: (credential) {
          // Android silently verified the phone
          _autoCredential = credential;
          notifyListeners();
          if (!completer.isCompleted) completer.complete(true);
        },
      );
    } catch (e) {
      _setError('Failed to start phone verification. Please try again.');
      if (!completer.isCompleted) completer.complete(false);
    }

    return completer.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        _setError('Verification timed out. Please try again.');
        return false;
      },
    );
  }

  // ── Resend OTP ────────────────────────────────────────────────────────────

  Future<bool> resendOtp(String phoneNumber) async {
    final completer = Completer<bool>();
    _autoCredential = null;
    _setLoading();
    try {
      await _service.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        resendToken: _resendToken,
        onCodeSent: (verificationId, resendToken) {
          _verificationId = verificationId;
          _resendToken = resendToken;
          _status = AuthStatus.unauthenticated;
          notifyListeners();
          if (!completer.isCompleted) completer.complete(true);
        },
        onFailed: (e) {
          _setError(_friendlyError(e));
          if (!completer.isCompleted) completer.complete(false);
        },
        onAutoVerified: (credential) {
          _autoCredential = credential;
          notifyListeners();
          if (!completer.isCompleted) completer.complete(true);
        },
      );
    } catch (e) {
      _setError('Failed to resend OTP. Please try again.');
      if (!completer.isCompleted) completer.complete(false);
    }

    return completer.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        _setError('Verification timed out. Please try again.');
        return false;
      },
    );
  }

  // ── Signup Step 3: Link phone OTP + save profile ──────────────────────────
  // Links the verified phone number to the existing email/password account,
  // then writes the Firestore profile.

  Future<bool> linkPhoneAndSaveProfile({
    required String otp,
    required String email,
    required Map<String, dynamic> registrationData,
  }) async {
    if (_verificationId == null && _autoCredential == null) {
      _setError('Session expired. Please request a new OTP.');
      return false;
    }
    try {
      _setLoading();

      if (_autoCredential != null) {
        // Android auto-verified — link directly
        await _service.linkAutoVerifiedPhone(_autoCredential!);
      } else {
        await _service.linkPhoneCredential(
          verificationId: _verificationId!,
          smsCode: otp,
        );
      }

      _user = await _service.saveUserProfile(
        registrationData: registrationData,
        email: email,
      );
      if (_user != null) {
        unawaited(_cacheHeaderUser(_user!));
      }
      _status = AuthStatus.authenticated;
      notifyListeners();
      return true;
    } on FirebaseAuthException catch (e) {
      // Roll back the email account on failure so user can retry cleanly
      await _service.deleteCurrentUser();
      _setError(_friendlyError(e));
      return false;
    } catch (e) {
      await _service.deleteCurrentUser();
      _setError(e.toString().replaceFirst('Exception: ', ''));
      return false;
    }
  }

  // ── Login: Phone OTP (existing users) ────────────────────────────────────
  // sendOtp() must be called first. Handles Android auto-verified and manual OTP.

  Future<bool> signInWithPhoneOtp(String otp) async {
    if (_verificationId == null && _autoCredential == null) {
      _setError('Session expired. Please request a new OTP.');
      return false;
    }
    try {
      _setLoading();

      if (_autoCredential != null) {
        _user = await _service.signInWithAutoCredential(_autoCredential!);
      } else {
        _user = await _service.signInWithPhoneOtp(
          verificationId: _verificationId!,
          smsCode: otp,
        );
      }

      if (_user != null) {
        unawaited(_cacheHeaderUser(_user!));
      }

      // _user == null means new user — caller will navigate to ProfileSetupScreen
      _status = AuthStatus.authenticated;
      notifyListeners();
      return true;
    } on FirebaseAuthException catch (e) {
      _setError(_friendlyError(e));
      return false;
    } catch (e) {
      _setError(e.toString().replaceFirst('Exception: ', ''));
      return false;
    }
  }

  // ── Login: Email + Password ───────────────────────────────────────────────

  Future<bool> signInWithPassword(String email, String password) async {
    try {
      _setLoading();
      _user = await _service.signInWithPassword(email, password);
      if (_user == null) {
        _setError('No account found. Please register first.');
        return false;
      }
      unawaited(_cacheHeaderUser(_user!));
      _status = AuthStatus.authenticated;
      notifyListeners();
      return true;
    } on FirebaseAuthException catch (e) {
      _setError(_friendlyError(e));
      return false;
    } catch (e) {
      _setError('Sign-in failed. Please try again.');
      return false;
    }
  }

  Future<({bool exists, bool isApproved, String verificationStatus})>
  getCurrentUserAccessState() async {
    try {
      return await _service.getCurrentUserAccessState();
    } catch (e) {
      return (exists: false, isApproved: false, verificationStatus: 'missing');
    }
  }

  // ── New User Profile Setup (after phone OTP verified) ────────────────────

  Future<bool> saveNewUserProfile(Map<String, dynamic> data) async {
    try {
      _setLoading();
      _user = await _service.saveUserProfile(
        registrationData: data,
        email: data['email'] ?? '',
      );
      if (_user != null) {
        unawaited(_cacheHeaderUser(_user!));
      }
      _status = AuthStatus.authenticated;
      notifyListeners();
      return true;
    } catch (e) {
      _setError('Failed to save profile. Please try again.');
      return false;
    }
  }

  // ── Sign Out ──────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    await _service.signOut();
    await PayUPaymentService.clearPendingTransaction();
    _user = null;
    _status = AuthStatus.unauthenticated;
    unawaited(_clearCachedHeaderUser());
    notifyListeners();
  }

  // ── Update Delivery Address ───────────────────────────────────────────────────────

  Future<void> updateAddress(String address) async {
    final uid = _service.currentUser?.uid;
    if (uid == null || _user == null) return;
    try {
      await _service.firestoreService.updateUserField(uid, 'address', address);
      _user = _user!.copyWith(address: address);
      unawaited(_cacheHeaderUser(_user!));
      notifyListeners();
    } catch (e) {}
  }

  Future<bool> updateCheckoutDeliveryDetails({
    required Map<String, dynamic> deliveryAddress,
    required Map<String, dynamic> contactDetails,
    List<Map<String, dynamic>>? addresses,
    int? selectedAddressIndex,
    bool allowEmptyAddresses = false,
  }) async {
    final uid = _service.currentUser?.uid;
    if (uid == null) return false;

    final addressLine = [
      (deliveryAddress['line1'] ?? '').toString().trim(),
      (deliveryAddress['line2'] ?? '').toString().trim(),
      (deliveryAddress['city'] ?? '').toString().trim(),
      (deliveryAddress['state'] ?? '').toString().trim(),
      (deliveryAddress['pincode'] ?? '').toString().trim(),
    ].where((part) => part.isNotEmpty).join(', ');

    final normalizedDelivery = {
      ...deliveryAddress,
      'line1': (deliveryAddress['line1'] ?? '').toString().trim(),
      'line2': (deliveryAddress['line2'] ?? '').toString().trim(),
      'landmark': (deliveryAddress['landmark'] ?? '').toString().trim(),
      'city': (deliveryAddress['city'] ?? '').toString().trim(),
      'state': (deliveryAddress['state'] ?? '').toString().trim(),
      'pincode': (deliveryAddress['pincode'] ?? '').toString().trim(),
      'country': (deliveryAddress['country'] ?? 'India').toString().trim(),
      'mapLink': (deliveryAddress['mapLink'] ?? '').toString().trim(),
    };

    final normalizedContact = {
      ...contactDetails,
      'receiverName': (contactDetails['receiverName'] ?? '').toString().trim(),
      'phone': (contactDetails['phone'] ?? _user?.phone ?? '')
          .toString()
          .trim(),
    };

    final existingDeliveryDetails = _user?.deliveryDetails;
    final existingAddresses = (existingDeliveryDetails?['addresses'] is List)
        ? (existingDeliveryDetails!['addresses'] as List)
              .whereType<Map>()
              .map((entry) => Map<String, dynamic>.from(entry))
              .toList(growable: false)
        : const <Map<String, dynamic>>[];

    final incomingAddresses = addresses ?? existingAddresses;

    final normalizedAddresses = incomingAddresses
        .map((entry) {
          final rawAddress = (entry['deliveryAddress'] is Map)
              ? Map<String, dynamic>.from(entry['deliveryAddress'] as Map)
              : <String, dynamic>{};
          final rawContact = (entry['contactDetails'] is Map)
              ? Map<String, dynamic>.from(entry['contactDetails'] as Map)
              : <String, dynamic>{};

          return {
            'deliveryAddress': {
              ...rawAddress,
              'line1': (rawAddress['line1'] ?? '').toString().trim(),
              'line2': (rawAddress['line2'] ?? '').toString().trim(),
              'landmark': (rawAddress['landmark'] ?? '').toString().trim(),
              'city': (rawAddress['city'] ?? '').toString().trim(),
              'state': (rawAddress['state'] ?? '').toString().trim(),
              'pincode': (rawAddress['pincode'] ?? '').toString().trim(),
              'country': (rawAddress['country'] ?? 'India').toString().trim(),
              'mapLink': (rawAddress['mapLink'] ?? '').toString().trim(),
            },
            'contactDetails': {
              ...rawContact,
              'receiverName': (rawContact['receiverName'] ?? '')
                  .toString()
                  .trim(),
              'phone': (rawContact['phone'] ?? '').toString().trim(),
            },
          };
        })
        .where(
          (entry) => (entry['deliveryAddress'] as Map<String, dynamic>)['line1']
              .toString()
              .trim()
              .isNotEmpty,
        )
        .toList(growable: true);

    if (normalizedAddresses.isEmpty && !allowEmptyAddresses) {
      normalizedAddresses.add({
        'deliveryAddress': normalizedDelivery,
        'contactDetails': normalizedContact,
      });
    }

    final existingSelectedIndex =
        (existingDeliveryDetails?['selectedAddressIndex'] as num?)?.toInt();
    var safeSelectedIndex =
        (selectedAddressIndex ?? existingSelectedIndex ?? 0);
    Map<String, dynamic> selectedAddress;
    Map<String, dynamic> selectedContact;

    if (normalizedAddresses.isEmpty) {
      safeSelectedIndex = 0;
      selectedAddress = {
        'line1': '',
        'line2': '',
        'landmark': '',
        'city': '',
        'state': '',
        'pincode': '',
        'country': 'India',
        'mapLink': '',
      };
      selectedContact = {
        'receiverName': '',
        'phone': (_user?.phone ?? '').toString().trim(),
      };
    } else {
      if (safeSelectedIndex < 0 ||
          safeSelectedIndex >= normalizedAddresses.length) {
        safeSelectedIndex = 0;
      }

      final selectedEntry = normalizedAddresses[safeSelectedIndex];
      selectedAddress =
          selectedEntry['deliveryAddress'] as Map<String, dynamic>;
      selectedContact = selectedEntry['contactDetails'] as Map<String, dynamic>;
    }

    final normalizedDeliveryDetails = {
      'deliveryAddress': selectedAddress,
      'contactDetails': selectedContact,
      'addresses': normalizedAddresses,
      'selectedAddressIndex': safeSelectedIndex,
      'deliveryPlaced': false,
      'updatedAt': DateTime.now().toIso8601String(),
    };

    final selectedAddressLine = [
      (selectedAddress['line1'] ?? '').toString().trim(),
      (selectedAddress['line2'] ?? '').toString().trim(),
      (selectedAddress['city'] ?? '').toString().trim(),
      (selectedAddress['state'] ?? '').toString().trim(),
      (selectedAddress['pincode'] ?? '').toString().trim(),
    ].where((part) => part.isNotEmpty).join(', ');

    try {
      await _service.firestoreService.updateUserFields(uid, {
        'address': selectedAddressLine.isNotEmpty
            ? selectedAddressLine
            : addressLine,
        'country': selectedAddress['country'],
        'state': selectedAddress['state'],
        'pincode': selectedAddress['pincode'],
        'deliveryAddressDetails': selectedAddress,
        'contactDetails': selectedContact,
        'deliveryDetails': normalizedDeliveryDetails,
        'deliveryPlaced': false,
        'phone': selectedContact['phone'],
      });

      if (_user != null) {
        _user = _user!.copyWith(
          address: selectedAddressLine.isNotEmpty
              ? selectedAddressLine
              : addressLine,
          country: selectedAddress['country']?.toString(),
          state: selectedAddress['state']?.toString(),
          pincode: selectedAddress['pincode']?.toString(),
          phone: selectedContact['phone']?.toString(),
          deliveryAddressDetails: selectedAddress,
          contactDetails: selectedContact,
          deliveryDetails: normalizedDeliveryDetails,
        );
        unawaited(_cacheHeaderUser(_user!));
      } else {
        _user = await _service.getCurrentUserData();
        if (_user != null) {
          unawaited(_cacheHeaderUser(_user!));
        }
      }
      notifyListeners();
      return true;
    } catch (e) {
      return false;
    }
  }

  // ── Update User Profile ───────────────────────────────────────────────────

  Future<bool> updateUserProfile(Map<String, dynamic> data) async {
    try {
      _setLoading();
      final uid = _service.currentUser?.uid;
      if (uid == null || uid.trim().isEmpty) {
        _setError('User not authenticated. Please log in again.');
        return false;
      }

      final success = await _service.updateUserProfile(uid: uid, data: data);

      if (!success) {
        _setError('Failed to update profile. Please try again.');
        return false;
      }

      // Reload user data
      _user = await _service.getCurrentUserData();
      if (_user != null) {
        unawaited(_cacheHeaderUser(_user!));
      }
      _status = AuthStatus.authenticated;
      notifyListeners();

      return true;
    } catch (e) {
      _setError('Failed to update profile. Please try again.');
      return false;
    }
  }

  // ── Error Messages ────────────────────────────────────────────────────────

  String _friendlyError(FirebaseAuthException e) {
    switch (e.code) {
      case 'user-not-found':
        return 'No account found with this email.';
      case 'wrong-password':
      case 'invalid-credential':
        return 'Invalid email or password.';
      case 'email-already-in-use':
        return 'An account already exists with this email.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'weak-password':
        return 'Password is too weak. Use at least 6 characters.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      case 'invalid-phone-number':
        return 'Invalid phone number.';
      case 'invalid-verification-code':
        return 'Incorrect OTP. Please check and try again.';
      case 'session-expired':
        return 'OTP expired. Please request a new one.';
      case 'credential-already-in-use':
        return 'This phone number is already linked to another account.';
      case 'provider-already-linked':
        return 'Phone already linked to this account.';
      case 'account-exists-with-different-credential':
        return 'An account already exists with this email using a different sign-in method.';
      case 'network-request-failed':
        return 'No internet connection. Please check your network and try again.';
      case 'sign-in-failed':
      case 'internal-error':
        return 'Google sign-in failed. Please try again.';
      case 'popup-closed-by-user':
      case 'cancelled-popup-request':
        return 'Sign-in was cancelled. Please try again.';
      default:
        return e.message ?? 'Authentication failed. Please try again.';
    }
  }
}
