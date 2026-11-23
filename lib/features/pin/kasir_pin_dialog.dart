import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'kasir_pin_service.dart';
import 'pin_keypad.dart';
import 'pin_service.dart';

/// Dialog atur PIN Kasir gerai (Batch C4): PIN baru 6 digit, ketik
/// 2x (buat + ulangi). Dipakai dari Ubah Gerai — PIN Owner gerai itu
/// SUDAH diverifikasi dulu di halaman pemanggil, lalu diteruskan
/// lewat [ownerPin] supaya Edge Function set-kasir-pin boleh menimpa
/// PIN Kasir lama tanpa PIN Kasir lama (PIN Owner TIDAK PERNAH
/// disimpan — hanya diteruskan sekali ke server).
/// Mengembalikan `true` lewat Navigator.pop bila berhasil.
class KasirPinDialog extends StatefulWidget {
  const KasirPinDialog({
    super.key,
    required this.outletId,
    required this.ownerPin,
  });

  final String outletId;

  /// PIN Owner gerai itu (sudah diverifikasi di pemanggil).
  final String ownerPin;

  @override
  State<KasirPinDialog> createState() => _KasirPinDialogState();
}

class _KasirPinDialogState extends State<KasirPinDialog> {
  var _confirmStep = false;
  String _entered = '';
  String? _newPin;
  String? _error;
  bool _busy = false;

  void _onDigit(String digit) {
    if (_busy || _entered.length >= PinService.pinLength) return;
    setState(() {
      _entered += digit;
      _error = null;
    });
    if (_entered.length == PinService.pinLength) {
      _submit();
    }
  }

  void _onBackspace() {
    if (_busy || _entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  Future<void> _submit() async {
    final entered = _entered;
    if (!_confirmStep) {
      setState(() {
        _newPin = entered;
        _entered = '';
        _confirmStep = true;
      });
      return;
    }
    if (entered != _newPin) {
      setState(() {
        _entered = '';
        _confirmStep = false;
        _error = 'PIN tidak sama — ulangi dari awal.';
      });
      return;
    }
    setState(() => _busy = true);
    final ok = await KasirPinService.instance.setPin(
      outletId: widget.outletId,
      ownerPin: widget.ownerPin,
      newPin: _newPin!,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _entered = '';
        _confirmStep = false;
        _busy = false;
        _error = 'Gagal menyimpan PIN Kasir — periksa koneksi / '
            'Edge Function set-kasir-pin belum di-deploy.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      title: Text(
        _confirmStep ? 'Ulangi PIN Kasir Baru' : 'Buat PIN Kasir Baru',
        textAlign: TextAlign.center,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'PIN Kasir 6 digit angka — dipakai kasir untuk masuk ke gerai ini.',
              textAlign: TextAlign.center,
              style: TextStyle(color: SukaTeaColors.muted),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int i = 0; i < PinService.pinLength; i++)
                  Container(
                    width: 16,
                    height: 16,
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < _entered.length
                          ? SukaTeaColors.emerald
                          : SukaTeaColors.border,
                    ),
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: SukaTeaColors.danger),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 16),
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
            const SizedBox(height: 20),
            PinKeypad(
              onDigit: _onDigit,
              onBackspace: _onBackspace,
              enabled: !_busy,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Batal'),
        ),
      ],
    );
  }
}
