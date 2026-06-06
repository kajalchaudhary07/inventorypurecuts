import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:purecuts/core/services/payu_payment_service.dart';
import 'package:purecuts/features/auth/providers/auth_provider.dart';

/// Example payment screen that:
/// 1) starts PayU CheckoutPro flow
/// 2) listens to backend-authored Firestore payment status
/// 3) does not trust client callback for success confirmation
class PayUPaymentScreen extends StatefulWidget {
  const PayUPaymentScreen({
    super.key,
    required this.amount,
    required this.productInfo,
    this.orderDraft,
  });

  final String amount;
  final String productInfo;
  final Map<String, dynamic>? orderDraft;

  @override
  State<PayUPaymentScreen> createState() => _PayUPaymentScreenState();
}

class _PayUPaymentScreenState extends State<PayUPaymentScreen> {
  late final PayUPaymentService _paymentService;
  StreamSubscription<Map<String, dynamic>>? _eventSub;

  String? _txnId;
  bool _loading = false;
  bool _finalizingOrder = false;
  String? _errorText;
  bool _resultSent = false;

  String _friendlyPaymentError(Object? error) {
    final raw = (error ?? '').toString().trim();
    if (raw.isEmpty) {
      return 'Could not start payment right now. Please try again.';
    }

    final message = raw.toLowerCase();

    final hasNetworkIssue =
        message.contains('socketexception') ||
        message.contains('failed host lookup') ||
        message.contains('no address associated with hostname') ||
        message.contains('network is unreachable') ||
        message.contains('connection refused') ||
        message.contains('connection reset');

    if (hasNetworkIssue) {
      return 'Unable to connect to payment service. Check your internet and try again.';
    }

    if (message.contains('timeout') || message.contains('timed out')) {
      return 'Payment service is taking too long to respond. Please try again.';
    }

    final hasBackendIssue =
        message.contains('generate-hash') ||
        message.contains('verify-payment') ||
        message.contains('sync-payment-status') ||
        message.contains('cloudfunctions') ||
        message.contains('unable to generate hash') ||
        message.contains('unable to verify payment') ||
        message.contains('unable to sync payment status');

    if (hasBackendIssue) {
      return 'Payment service is temporarily unavailable. Please try again in a moment.';
    }

    if (message.contains('cancel')) {
      return 'Payment cancelled. You can retry.';
    }

    return 'Could not start payment right now. Please try again.';
  }

  void _completeFlow({
    required String status,
    String reason = '',
    String orderRef = '',
  }) {
    if (_resultSent || !mounted) return;
    _resultSent = true;
    Navigator.of(context).pop({
      'status': status,
      'txnid': _txnId ?? '',
      'reason': reason,
      'orderRef': orderRef,
    });
  }

  bool _isOrderPlaced(Map<String, dynamic> data) {
    final status = (data['status'] ?? '').toString().toLowerCase();
    final orderPlacementStatus = (data['orderPlacementStatus'] ?? '')
        .toString()
        .toLowerCase();
    final orderRef =
        (data['orderRef'] ?? data['orderId'] ?? data['orderNumber'] ?? '')
            .toString()
            .trim();
    return orderRef.isNotEmpty &&
        (orderPlacementStatus == 'placed' || status == 'success');
  }

  @override
  void initState() {
    super.initState();
    _paymentService = PayUPaymentService();
    _eventSub = _paymentService.events.listen((event) {
      if (!mounted) return;

      if ((event['type'] ?? '').toString() == 'pending') {
        setState(() {
          _loading = false;
        });
      }

      if ((event['type'] ?? '').toString() == 'sync') {
        final syncStatus = (event['status'] ?? '').toString().toLowerCase();

        if (syncStatus == 'success') {
          setState(() {
            _finalizingOrder = true;
          });
          return;
        }

        if (syncStatus == 'failure' || syncStatus == 'cancelled') {
          _completeFlow(status: syncStatus, reason: 'sync-$syncStatus');
          return;
        }
      }

      if ((event['type'] ?? '').toString() == 'error') {
        final rawError = event['message']?.toString() ?? '';
        _completeFlow(status: 'failure', reason: 'payment-error');
        setState(() {
          _errorText = _friendlyPaymentError(rawError);
          _loading = false;
        });
      }

      if ((event['type'] ?? '').toString() == 'cancel') {
        _completeFlow(status: 'cancelled', reason: 'payment-cancelled');
        setState(() {
          _errorText = 'Payment cancelled. You can retry.';
          _loading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _paymentService.dispose();
    super.dispose();
  }

  Future<void> _startPayment() async {
    if (_loading || (_txnId ?? '').trim().isNotEmpty) return;

    setState(() {
      _loading = true;
      _errorText = null;
    });

    try {
      final auth = context.read<AuthProvider>();
      final user = auth.user;
      final uid = user?.uid ?? '';
      final firstName = (user?.ownerName ?? user?.name ?? 'PureCuts User')
          .trim();
      final email = (user?.email ?? '').trim().isNotEmpty
          ? user!.email.trim()
          : 'customer@purecuts.app';
      final phone = (user?.phone ?? '9999999999').replaceAll(RegExp(r'\D'), '');

      final txnId = await _paymentService.startCheckout(
        userId: uid,
        amount: widget.amount,
        productInfo: widget.productInfo,
        firstName: firstName,
        email: email,
        phone: phone,
        orderDraft: widget.orderDraft,
      );

      if (!mounted) return;
      setState(() {
        _txnId = txnId;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText = _friendlyPaymentError(error);
        _loading = false;
      });
    }
  }

  ({Color color, IconData icon, String title, String subtitle}) _statusVisuals({
    required String status,
    required bool verified,
  }) {
    switch (status) {
      case 'success':
        return (
          color: verified ? const Color(0xFF16A34A) : const Color(0xFFF59E0B),
          icon: verified ? Icons.verified_rounded : Icons.pending_rounded,
          title: verified ? 'Payment successful' : 'Processing confirmation',
          subtitle: verified
              ? 'Your transaction has been securely verified.'
              : 'Payment is received. Waiting for final verification.',
        );
      case 'failure':
        return (
          color: const Color(0xFFDC2626),
          icon: Icons.error_outline_rounded,
          title: 'Payment failed',
          subtitle: 'No worries — you can retry this payment safely.',
        );
      case 'cancelled':
        return (
          color: const Color(0xFFEA580C),
          icon: Icons.cancel_outlined,
          title: 'Payment cancelled',
          subtitle: 'You cancelled the flow. You can start again anytime.',
        );
      default:
        return (
          color: const Color(0xFFF59E0B),
          icon: Icons.hourglass_bottom_rounded,
          title: 'Payment in progress',
          subtitle: 'Waiting for secure backend status update.',
        );
    }
  }

  Widget _buildHeroCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF7C3AED), Color(0xFF5C138B)],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2D5C138B),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.lock_rounded, color: Colors.white, size: 18),
              SizedBox(width: 6),
              Text(
                'Secure payment',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '₹${widget.amount}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.productInfo,
            style: const TextStyle(
              color: Color(0xFFEDE9FE),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMethodHintCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE9DDF9)),
      ),
      child: const Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _MethodChip(icon: Icons.qr_code_rounded, label: 'UPI'),
          _MethodChip(icon: Icons.credit_card_rounded, label: 'Card'),
          _MethodChip(icon: Icons.account_balance_rounded, label: 'NetBanking'),
          _MethodChip(
            icon: Icons.account_balance_wallet_rounded,
            label: 'Wallet',
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final txnId = _txnId;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F3FB),
      appBar: AppBar(
        title: const Text('Pay with PayU'),
        centerTitle: true,
        backgroundColor: const Color(0xFFF6F3FB),
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeroCard(),
              const SizedBox(height: 14),
              ElevatedButton.icon(
                onPressed: _loading ? null : _startPayment,
                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.lock_open_rounded, size: 18),
                label: Text(
                  _loading
                      ? 'Opening secure checkout...'
                      : 'Continue to secure checkout',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF5C138B),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 54),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFECACA)),
                  ),
                  child: Text(
                    _errorText!,
                    style: const TextStyle(
                      color: Color(0xFFB91C1C),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (txnId == null) ...[
                const Text(
                  'Payment methods',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 10),
                _buildMethodHintCard(),
                const SizedBox(height: 14),
                const Text(
                  'Your transaction will start after tapping the button above.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
                ),
              ] else
                StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection('payments')
                      .doc(txnId)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData || !snapshot.data!.exists) {
                      return Container(
                        margin: const EdgeInsets.only(top: 2),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFE5E7EB)),
                        ),
                        child: const Row(
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Waiting for backend payment status...',
                                style: TextStyle(color: Color(0xFF4B5563)),
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    final data =
                        snapshot.data!.data() ?? const <String, dynamic>{};
                    final status = (data['status'] ?? 'initiated').toString();
                    final verified = data['hashVerified'] == true;
                    final orderReady = _isOrderPlaced(data);

                    if (status == 'success' && verified && orderReady) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        setState(() {
                          _errorText = null;
                          _finalizingOrder = false;
                        });
                        _completeFlow(
                          status: 'success',
                          orderRef:
                              (data['orderRef'] ??
                                      data['orderId'] ??
                                      data['orderNumber'] ??
                                      '')
                                  .toString()
                                  .trim(),
                        );
                      });
                    } else if (status == 'success' && verified) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        if (!_finalizingOrder) {
                          setState(() {
                            _errorText = null;
                            _finalizingOrder = true;
                          });
                        }
                      });
                    } else if (status == 'failure' || status == 'cancelled') {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        setState(() {
                          _errorText = null;
                          _finalizingOrder = false;
                        });
                        _completeFlow(status: status, reason: status);
                      });
                    }

                    final visuals = _statusVisuals(
                      status: status,
                      verified: verified,
                    );

                    final subtitle =
                        status == 'success' && verified && !orderReady
                        ? 'Payment received. Finalizing your order on the server...'
                        : visuals.subtitle;

                    return Container(
                      margin: const EdgeInsets.only(top: 2),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE5E7EB)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: visuals.color.withOpacity(0.12),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  visuals.icon,
                                  size: 20,
                                  color: visuals.color,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      visuals.title,
                                      style: TextStyle(
                                        color: visuals.color,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      subtitle,
                                      style: const TextStyle(
                                        color: Color(0xFF6B7280),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _InfoRow(label: 'Transaction ID', value: txnId),
                          _InfoRow(
                            label: 'Amount',
                            value: '₹${data['amount'] ?? widget.amount}',
                          ),
                          _InfoRow(
                            label: 'PayU status',
                            value: (data['payuStatus'] ?? '-').toString(),
                          ),
                          _InfoRow(
                            label: 'Hash verification',
                            value: verified ? 'Verified' : 'Pending',
                          ),
                          if (_finalizingOrder ||
                              (status == 'success' && verified && !orderReady))
                            const Padding(
                              padding: EdgeInsets.only(top: 10),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Finalizing order... please keep this screen open for a moment.',
                                      style: TextStyle(
                                        color: Color(0xFF4B5563),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (status == 'failure' || status == 'cancelled') ...[
                            const SizedBox(height: 10),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: () => _completeFlow(
                                  status: status,
                                  reason: status,
                                ),
                                icon: const Icon(Icons.arrow_back_rounded),
                                label: const Text('Back to checkout'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MethodChip extends StatelessWidget {
  const _MethodChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F5FF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE9DDF9)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: const Color(0xFF5C138B)),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: Color(0xFF374151),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              maxLines: 2,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF111827),
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
