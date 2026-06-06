import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String uid;
  final String name;
  final String email;
  final String? phone;
  final String? salonName;
  final String? ownerName;
  final String? gst;
  final String? udyamNumber;
  final String? address;
  final String? country;
  final String? state;
  final String? pincode;
  final Map<String, dynamic>? deliveryAddressDetails;
  final Map<String, dynamic>? contactDetails;
  final Map<String, dynamic>? deliveryDetails;
  final String role;
  final DateTime? createdAt;

  const UserModel({
    required this.uid,
    required this.name,
    required this.email,
    this.phone,
    this.salonName,
    this.ownerName,
    this.gst,
    this.udyamNumber,
    this.address,
    this.country,
    this.state,
    this.pincode,
    this.deliveryAddressDetails,
    this.contactDetails,
    this.deliveryDetails,
    this.role = 'salon_owner',
    this.createdAt,
  });

  factory UserModel.fromMap(Map<String, dynamic> map, String uid) {
    return UserModel(
      uid: uid,
      name: map['name'] ?? '',
      email: map['email'] ?? '',
      phone: map['phone'],
      salonName: map['salonName'],
      ownerName: map['ownerName'],
      gst: map['gst'],
      udyamNumber: map['udyamNumber'] ?? map['udyam'],
      address: map['address'],
      country: map['country'],
      state: map['state'],
      pincode: map['pincode'],
      deliveryAddressDetails: map['deliveryAddressDetails'] is Map
          ? Map<String, dynamic>.from(map['deliveryAddressDetails'] as Map)
          : null,
      contactDetails: map['contactDetails'] is Map
          ? Map<String, dynamic>.from(map['contactDetails'] as Map)
          : null,
      deliveryDetails: map['deliveryDetails'] is Map
          ? Map<String, dynamic>.from(map['deliveryDetails'] as Map)
          : null,
      role: map['role'] ?? 'salon_owner',
      createdAt: map['createdAt'] != null
          ? (map['createdAt'] as Timestamp).toDate()
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'email': email,
      'phone': phone,
      'salonName': salonName,
      'ownerName': ownerName,
      'gst': gst,
      'udyamNumber': udyamNumber,
      'address': address,
      'country': country,
      'state': state,
      'pincode': pincode,
      'deliveryAddressDetails': deliveryAddressDetails,
      'contactDetails': contactDetails,
      'deliveryDetails': deliveryDetails,
      'role': role,
      'createdAt': createdAt != null
          ? Timestamp.fromDate(createdAt!)
          : FieldValue.serverTimestamp(),
    };
  }

  UserModel copyWith({
    String? uid,
    String? name,
    String? email,
    String? phone,
    String? salonName,
    String? ownerName,
    String? gst,
    String? udyamNumber,
    Object? address = _sentinel,
    String? country,
    String? state,
    String? pincode,
    Object? deliveryAddressDetails = _sentinel,
    Object? contactDetails = _sentinel,
    Object? deliveryDetails = _sentinel,
    String? role,
    DateTime? createdAt,
  }) {
    return UserModel(
      uid: uid ?? this.uid,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      salonName: salonName ?? this.salonName,
      ownerName: ownerName ?? this.ownerName,
      gst: gst ?? this.gst,
      udyamNumber: udyamNumber ?? this.udyamNumber,
      address: address == _sentinel ? this.address : address as String?,
      country: country ?? this.country,
      state: state ?? this.state,
      pincode: pincode ?? this.pincode,
      deliveryAddressDetails: deliveryAddressDetails == _sentinel
          ? this.deliveryAddressDetails
          : deliveryAddressDetails as Map<String, dynamic>?,
      contactDetails: contactDetails == _sentinel
          ? this.contactDetails
          : contactDetails as Map<String, dynamic>?,
      deliveryDetails: deliveryDetails == _sentinel
          ? this.deliveryDetails
          : deliveryDetails as Map<String, dynamic>?,
      role: role ?? this.role,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

const Object _sentinel = Object();
