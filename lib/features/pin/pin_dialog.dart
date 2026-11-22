import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'pin_service.dart';

/// Dialog PIN 6 digit: titik + keypad angka (desain v2).
///
/// Alur (semua lewat Supabase, PIN tidak pernah tersimpan di HP):
/// - Verifikasi: masukkan PIN -> cocok = mode Owner terbuka.
///   Belum ada PIN (notSet) -> dialog beralih ke buat PIN baru.
/// - Ubah PIN (`requireCurrentPin: true`): PIN lama dulu, lalu PIN baru 2x.
/// Mengembalikan `true` lewat Navigator.pop bila berhasil, `false` bila batal.
class PinEntryDialog extends StatefulWidget {
  const PinEntryDialog({super.key, this.requireCurrentPin = false});

  /// true = ubah PIN (minta PIN lama dulu). false = verifikasi / setup.
  final bool requireCurrentPin;

  @override
  State<PinEntryDialog> createState() => _PinEntryDialogState();
}

enum _Step { enter, createNew, createConfirm }

class _PinEntryDialogState extends State<PinEntryDialog> {
  _Step _step = _Step.enter;
  String _entered = '';
  String? _currentPin;
  String? _newPin;
  String? _error;
  bool _busy = false;

  String get _title {
    switch (_step) {
      case _Step.enter:
        return widget.requireCurrentPin ? 'Masukkan PIN Lama' : 'Masukkan PIN Owner';
      case _Step.createNew:
        return 'Buat PIN Baru';
      case _Step.createConfirm:
        return 'Ulangi PIN Baru';
    }
  }

  String get _subtitle {
    switch (_step) {
      case _Step.enter:
        return widget.requireCurrentPin
            ? 'PIN lama diperlukan untuk mengubah PIN.'
            : 'Mode Owner dikunci PIN. PIN hanya tersimpan di Supabase.';
      case _Step.createNew:
        return 'PIN 6 digit angka.';
      case _Step.createConfirm:
        return 'Ketik ulang PIN baru yang sama.';
    }
  }

  void _onDigit(String digit) {
    if (_busy || PinService.instance.isLocked) return;
    if (_entered.length >= PinService.pinLength) return;
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
    setState(() => _busy = true);
    if (_step == _Step.enter) {
      final result = await PinService.instance.verify(entered);
      if (!mounted) return;
      switch (result) {
        case PinVerifyResult.ok:
          if (widget.requireCurrentPin) {
            setState(() {
              _currentPin = entered;
              _entered = '';
              _step = _Step.createNew;
              _busy = false;
            });
          } else {
            Navigator.of(context).pop(true);
          }
        case PinVerifyResult.notSet:
          // Belum ada PIN: langsung ke buat PIN baru.
          setState(() {
            _currentPin = null;
            _entered = '';
            _step = _Step.createNew;
            _busy = false;
            _error = 'Belum ada PIN Owner — buat PIN baru.';
          });
        case PinVerifyResult.wrong:
          setState(() {
            _entered = '';
            _busy = false;
            _error = 'PIN salah — sisa ${PinService.instance.remainingAttempts} percobaan.';
          });
        case PinVerifyResult.locked:
          setState(() {
            _entered = '';
            _busy = false;
            _error = 'Terlalu banyak percobaan salah. Coba lagi 5 menit lagi.';
          });
        case PinVerifyResult.unavailable:
          setState(() {
            _entered = '';
            _busy = false;
            _error = 'Tidak bisa verifikasi PIN — periksa koneksi / Edge Function belum di-deploy.';
          });
      }
      return;
    }
    if (_step == _Step.createNew) {
      setState(() {
        _newPin = entered;
        _entered = '';
        _step = _Step.createConfirm;
        _busy = false;
      });
      return;
    }
    // _Step.createConfirm
    if (entered != _newPin) {
      setState(() {
        _entered = '';
        _step = _Step.createNew;
        _busy = false;
        _error = 'PIN tidak sama — ulangi dari awal.';
      });
      return;
    }
    final ok = await PinService.instance.setPin(
      currentPin: _currentPin,
      newPin: _newPin!,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _entered = '';
        _busy = false;
        _error = 'Gagal menyimpan PIN — periksa koneksi / Edge Function belum di-deploy.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = PinService.instance.isLocked;
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      title: Text(_title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: SukaTeaColors.muted),
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
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: 12,
              itemBuilder: (context, i) {
                if (i == 9) return const SizedBox.shrink();
                if (i == 11) {
                  return _keyButton(
                    icon: Icons.backspace_outlined,
                    onTap: _onBackspace,
                  );
                }
                final digit = i == 10 ? '0' : '${i + 1}';
                return _keyButton(
                  label: digit,
                  onTap: locked ? null : () => _onDigit(digit),
                );
              },
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

  Widget _keyButton({
    String? label,
    IconData? icon,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: SukaTeaColors.leafBg,
          border: Border.all(color: SukaTeaColors.border),
        ),
        child: Center(
          child: label != null
              ? Text(
                  label,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : Icon(icon, color: SukaTeaColors.ink),
        ),
      ),
    );
  }
}
