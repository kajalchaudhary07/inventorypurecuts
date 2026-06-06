import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

class OrderModel {
  static const int editWindowHours = 12;

  final String orderDocumentId;
  final String orderId;
  final String uid;
  final String customerName;
  final String customerEmail;
  final String customerPhone;
  final Map<String, dynamic> deliveryAddress;
  final Map<String, dynamic> contactDetails;
  final List<Map<String, dynamic>> items;
  final int totalAmount;
  final int itemCount;
  final String paymentMethod;
  final Map<String, dynamic>? billDetails;
  final Map<String, dynamic>? editMeta;
  final String? originalOrderDocumentId;
  final String? originalOrderId;
  final String? originalOrderRef;
  final String status;
  final DateTime createdAt;
  final DateTime? updatedAt;

  const OrderModel({
    required this.orderDocumentId,
    required this.orderId,
    required this.uid,
    required this.customerName,
    required this.customerEmail,
    required this.customerPhone,
    required this.deliveryAddress,
    required this.contactDetails,
    required this.items,
    required this.totalAmount,
    required this.itemCount,
    required this.paymentMethod,
    this.billDetails,
    this.editMeta,
    this.originalOrderDocumentId,
    this.originalOrderId,
    this.originalOrderRef,
    required this.status,
    required this.createdAt,
    this.updatedAt,
  });

  factory OrderModel.fromMap(Map<String, dynamic> map) {
    DateTime _toDate(dynamic value) {
      if (value is Timestamp) return value.toDate();
      if (value is DateTime) return value;
      if (value is num)
        return DateTime.fromMillisecondsSinceEpoch(value.toInt());
      if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
      return DateTime.now();
    }

    final rawItems = (map['items'] as List?) ?? const [];
    final normalizedItems = rawItems
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .toList(growable: false);

    int _asInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    final normalizedStatus = (map['status'] ?? map['orderStatus'] ?? 'placed')
        .toString()
        .trim()
        .toLowerCase();

    final editMeta = map['editMeta'] is Map
        ? Map<String, dynamic>.from(map['editMeta'])
        : null;
    final originalOrderDocumentId =
        (map['originalOrderDocumentId'] ??
                editMeta?['sourceOrderDocumentId'] ??
                '')
            .toString()
            .trim();
    final originalOrderId =
        (map['originalOrderId'] ??
                map['sourceOrderId'] ??
                editMeta?['sourceOrderId'] ??
                '')
            .toString()
            .trim();
    final originalOrderRef =
        (map['originalOrderRef'] ??
                map['sourceOrderRef'] ??
                editMeta?['sourceOrderRef'] ??
                '')
            .toString()
            .trim();

    return OrderModel(
      orderDocumentId: (map['id'] ?? map['docId'] ?? '').toString().trim(),
      orderId: map['orderId'] ?? map['orderRef'] ?? map['orderNumber'] ?? '',
      uid: map['uid'] ?? map['userId'] ?? map['customerId'] ?? '',
      customerName: map['customerName'] ?? '',
      customerEmail: map['customerEmail'] ?? '',
      customerPhone: map['customerPhone'] ?? map['phone'] ?? '',
      deliveryAddress: map['deliveryAddress'] is Map
          ? Map<String, dynamic>.from(map['deliveryAddress'])
          : {},
      contactDetails: map['contactDetails'] is Map
          ? Map<String, dynamic>.from(map['contactDetails'])
          : {},
      items: normalizedItems,
      totalAmount: _asInt(
        map['total'] ??
            map['amount'] ??
            map['totalAmount'] ??
            map['grandTotal'] ??
            0,
      ),
      itemCount: _asInt(
        map['itemCount'] ?? map['itemsCount'] ?? normalizedItems.length,
      ),
      paymentMethod: ((map['paymentMethod'] ?? '').toString().trim().isNotEmpty)
          ? (map['paymentMethod'] ?? '').toString().trim()
          : 'COD',
      billDetails: map['billDetails'] is Map
          ? Map<String, dynamic>.from(map['billDetails'])
          : null,
      editMeta: editMeta,
      originalOrderDocumentId: originalOrderDocumentId.isEmpty
          ? null
          : originalOrderDocumentId,
      originalOrderId: originalOrderId.isEmpty ? null : originalOrderId,
      originalOrderRef: originalOrderRef.isEmpty ? null : originalOrderRef,
      status: normalizedStatus,
      createdAt: _toDate(map['createdAt']),
      updatedAt: map['updatedAt'] != null ? _toDate(map['updatedAt']) : null,
    );
  }

  /// Format created date as "5 Mar 2026"
  String get formattedDate {
    return DateFormat('d MMM yyyy').format(createdAt);
  }

  /// Format created date and time as "5 Mar 2026, 2:30 PM"
  String get formattedDateTime {
    return DateFormat('d MMM yyyy, h:mm a').format(createdAt);
  }

  /// Format time as "2:30 PM"
  String get formattedTime {
    return DateFormat('h:mm a').format(createdAt);
  }

  /// Get delivery address as single line "Line1, City, State, Pincode"
  String get deliveryAddressString {
    final parts = [
      deliveryAddress['line1'] ?? '',
      deliveryAddress['city'] ?? '',
      deliveryAddress['state'] ?? '',
      deliveryAddress['pincode'] ?? '',
    ].where((e) => e.toString().isNotEmpty).toList();
    return parts.join(', ');
  }

  /// Get short delivery address "City, Pincode"
  String get deliveryAddressShort {
    final city = deliveryAddress['city'] ?? '';
    final pincode = deliveryAddress['pincode'] ?? '';
    return [city, pincode].where((e) => e.toString().isNotEmpty).join(', ');
  }

  /// Get receiver name from contactDetails

  String get receiverName {
    return contactDetails['receiverName'] ?? customerName;
  }

  /// Get receiver phone from contactDetails
  String get receiverPhone {
    return contactDetails['phone'] ?? customerPhone;
  }

  /// Get status display name (capitalized)
  String get statusDisplay {
    final clean = status.trim().toLowerCase();
    if (clean.isEmpty) return 'Placed';
    if (clean == 'edited') return 'Edited';
    if (clean == 'out_for_delivery') return 'Out for delivery';
    if (clean == 'in_transit') return 'In transit';
    return clean[0].toUpperCase() + clean.substring(1);
  }

  /// Determine if order can be cancelled
  bool get canCancel {
    return status == 'placed' || status == 'confirmed';
  }

  bool get canEdit {
    const editableStatuses = {'placed', 'confirmed', 'processing', 'packed'};
    return editableStatuses.contains(status.trim().toLowerCase()) &&
        DateTime.now().isBefore(editWindowEndsAt);
  }

  DateTime get editWindowEndsAt {
    return createdAt.add(const Duration(hours: editWindowHours));
  }

  bool get hasEditHistory {
    return (originalOrderDocumentId ?? '').trim().isNotEmpty ||
        (originalOrderId ?? '').trim().isNotEmpty ||
        (originalOrderRef ?? '').trim().isNotEmpty ||
        editMeta != null;
  }

  /// Determine if order can be reordered
  bool get canReorder {
    return status == 'delivered' || status == 'cancelled';
  }

  /// Get items as formatted list for display
  List<Map<String, dynamic>> get itemsList {
    return items.cast<Map<String, dynamic>>();
  }

  /// Total item quantity
  int get totalItemQuantity {
    return items.fold<int>(
      0,
      (sum, item) => sum + ((item['quantity'] ?? 1) as int),
    );
  }
}
