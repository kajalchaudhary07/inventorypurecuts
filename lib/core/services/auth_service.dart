import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:purecuts/core/models/user_model.dart';
import 'package:purecuts/core/services/firestore_service.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirestoreService _firestoreService = FirestoreService();

  User? get currentUser => _auth.currentUser;
  FirestoreService get firestoreService => _firestoreService;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // ── Registration: Create account with email + password ─────────────────

  Future<void> createEmailAccount(String email, String password) async {
    debugPrint('[AuthService] createEmailAccount: ${email.trim()}');
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    debugPrint(
      '[AuthService] Email account created. UID=${credential.user?.uid}',
    );
    await credential.user?.sendEmailVerification();
    debugPrint('[AuthService] Verification email sent.');
  }

  Future<void> resendVerificationEmail() async {
    debugPrint(
      '[AuthService] resendVerificationEmail for UID=${_auth.currentUser?.uid}',
    );
    await _auth.currentUser?.sendEmailVerification();
  }

  Future<bool> reloadAndCheckEmailVerified() async {
    await _auth.currentUser?.reload();
    final verified = _auth.currentUser?.emailVerified ?? false;
    debugPrint(
      '[AuthService] checkEmailVerified: $verified (UID=${_auth.currentUser?.uid})',
    );
    return verified;
  }

  // ── Step 2: Send phone OTP ────────────────────────────────────────────────

  Future<void> verifyPhoneNumber({
    required String phoneNumber,
    required void Function(String verificationId, int? resendToken) onCodeSent,
    required void Function(FirebaseAuthException e) onFailed,
    required void Function(PhoneAuthCredential credential) onAutoVerified,
    int? resendToken,
  }) async {
    debugPrint(
      '[AuthService] verifyPhoneNumber: $phoneNumber (resendToken=$resendToken)',
    );
    await _auth.verifyPhoneNumber(
      phoneNumber: phoneNumber,
      verificationCompleted: (credential) {
        debugPrint(
          '[AuthService] Phone auto-verified (Android silent verification).',
        );
        onAutoVerified(credential);
      },
      verificationFailed: (e) {
        debugPrint(
          '[AuthService] Phone verification failed — code: ${e.code}, message: ${e.message}',
        );
        onFailed(e);
      },
      codeSent: (verificationId, resendToken) {
        final previewLength = verificationId.length < 10
            ? verificationId.length
            : 10;
        debugPrint(
          '[AuthService] OTP code sent. verificationId=${verificationId.substring(0, previewLength)}…',
        );
        onCodeSent(verificationId, resendToken);
      },
      codeAutoRetrievalTimeout: (_) {
        debugPrint('[AuthService] Phone auto-retrieval timed out.');
      },
      forceResendingToken: resendToken,
      timeout: const Duration(seconds: 60),
    );
  }

  // ── Step 3: Link phone credential to existing email account ───────────────

  Future<void> linkPhoneCredential({
    required String verificationId,
    required String smsCode,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('No authenticated user found.');

    debugPrint('[AuthService] linkPhoneCredential: UID=${user.uid}');
    final phoneCredential = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: smsCode,
    );

    // Skip linking if phone is already linked (handles retry)
    final hasPhone = user.providerData.any((p) => p.providerId == 'phone');
    if (!hasPhone) {
      await user.linkWithCredential(phoneCredential);
      debugPrint('[AuthService] Phone credential linked to UID=${user.uid}');
    } else {
      debugPrint('[AuthService] Phone already linked — skipping link step.');
    }
  }

  // ── Registration Step 4: Save Firestore profile ───────────────────────────

  Future<UserModel> saveUserProfile({
    required Map<String, dynamic> registrationData,
    required String email,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('No authenticated user found.');

    final resolvedEmail = email.trim().isNotEmpty
        ? email.trim()
        : (user.email ?? '');
    debugPrint(
      '[AuthService] saveUserProfile: UID=${user.uid}, email=$resolvedEmail',
    );

    await user.updateDisplayName(registrationData['ownerName'] ?? '');

    final userModel = UserModel(
      uid: user.uid,
      name: registrationData['ownerName'] ?? '',
      email: resolvedEmail,
      phone: registrationData['phone'],
      salonName: registrationData['salonName'],
      ownerName: registrationData['ownerName'],
      gst: registrationData['gst'],
      udyamNumber: registrationData['udyamNumber'] ?? registrationData['udyam'],
      country: registrationData['country'],
      state: registrationData['state'],
      pincode: registrationData['pincode'],
      address: registrationData['address'],
      role: 'salon_owner',
      createdAt: DateTime.now(),
    );

    await _firestoreService.saveUserProfileWithPendingApproval(
      user: userModel,
      registrationData: registrationData,
    );
    debugPrint('[AuthService] Firestore profile saved for UID=${user.uid}');
    return userModel;
  }

  Future<({bool exists, bool isApproved, String verificationStatus})>
  getCurrentUserAccessState() async {
    final user = _auth.currentUser;
    if (user == null) {
      return (exists: false, isApproved: false, verificationStatus: 'missing');
    }
    return _firestoreService.getUserAccessState(user.uid);
  }

  // ── Login: Email + Password ───────────────────────────────────────────────

  Future<UserModel?> signInWithPassword(String email, String password) async {
    debugPrint('[AuthService] signInWithPassword: ${email.trim()}');
    final credential = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final uid = credential.user!.uid;
    debugPrint('[AuthService] Password sign-in succeeded. UID=$uid');
    return _firestoreService.getUserProfile(uid);
  }

  // ── Login: Phone OTP ──────────────────────────────────────────────────────

  Future<UserModel?> signInWithPhoneOtp({
    required String verificationId,
    required String smsCode,
  }) async {
    debugPrint('[AuthService] signInWithPhoneOtp: verifying OTP…');
    final credential = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: smsCode,
    );
    final userCredential = await _auth.signInWithCredential(credential);
    final uid = userCredential.user!.uid;
    debugPrint('[AuthService] Phone sign-in succeeded. UID=$uid');
    final profile = await _firestoreService.getUserProfile(uid);
    debugPrint(
      '[AuthService] Firestore profile: ${profile == null ? 'not found' : 'found'}',
    );
    return profile;
  }

  Future<UserModel?> signInWithAutoCredential(
    PhoneAuthCredential credential,
  ) async {
    debugPrint('[AuthService] signInWithAutoCredential (Android silent)…');
    final userCredential = await _auth.signInWithCredential(credential);
    final uid = userCredential.user!.uid;
    debugPrint('[AuthService] Auto-credential sign-in succeeded. UID=$uid');
    return _firestoreService.getUserProfile(uid);
  }

  // ── Auto-verify (Android silent verification) ─────────────────────────────

  Future<void> linkAutoVerifiedPhone(PhoneAuthCredential credential) async {
    final user = _auth.currentUser;
    if (user == null) {
      debugPrint(
        '[AuthService] linkAutoVerifiedPhone: no current user — skipping.',
      );
      return;
    }
    final hasPhone = user.providerData.any((p) => p.providerId == 'phone');
    if (!hasPhone) {
      debugPrint(
        '[AuthService] linkAutoVerifiedPhone: linking for UID=${user.uid}',
      );
      await user.linkWithCredential(credential);
      debugPrint('[AuthService] linkAutoVerifiedPhone: done.');
    } else {
      debugPrint(
        '[AuthService] linkAutoVerifiedPhone: phone already linked — skipping.',
      );
    }
  }

  // ── Sign Out ──────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    debugPrint('[AuthService] signOut: UID=${_auth.currentUser?.uid}');
    await _auth.signOut();
    debugPrint('[AuthService] signOut complete.');
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<UserModel?> getCurrentUserData() async {
    final user = _auth.currentUser;
    if (user == null) {
      debugPrint('[AuthService] getCurrentUserData: no current user.');
      return null;
    }
    debugPrint('[AuthService] getCurrentUserData: UID=${user.uid}');
    try {
      final data = await _firestoreService.getUserProfile(user.uid);
      debugPrint(
        '[AuthService] getCurrentUserData: ${data == null ? 'not found in Firestore' : 'loaded'} for UID=${user.uid}',
      );
      return data;
    } catch (e, st) {
      debugPrint('[AuthService] getCurrentUserData failed: $e\n$st');
      return null;
    }
  }

  /// Deletes the current Firebase Auth user. Used to roll back a failed registration.
  Future<void> deleteCurrentUser() async {
    debugPrint(
      '[AuthService] deleteCurrentUser: UID=${_auth.currentUser?.uid}',
    );
    try {
      await _auth.currentUser?.delete();
      debugPrint('[AuthService] deleteCurrentUser: done.');
    } catch (e, st) {
      debugPrint('[AuthService] deleteCurrentUser failed: $e\n$st');
    }
  }

  /// Update user profile information in Firestore
  Future<bool> updateUserProfile({
    required String uid,
    required Map<String, dynamic> data,
  }) async {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty) {
      debugPrint('[AuthService] updateUserProfile: empty UID provided');
      return false;
    }

    debugPrint('[AuthService] updateUserProfile: UID=$cleanUid');
    try {
      return await _firestoreService.updateUserProfile(
        uid: cleanUid,
        data: data,
      );
    } catch (e, st) {
      debugPrint('[AuthService] updateUserProfile failed: $e\n$st');
      return false;
    }
  }

  // ── Private Helpers ───────────────────────────────────────────────────────
}
