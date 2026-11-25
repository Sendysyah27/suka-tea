import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/roles.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/outlet_service.dart';
import '../kasir/cashier_service.dart';
import '../pin/pin_keypad.dart';
import '../pin/pin_service.dart';
import 'login_result.dart';

/// Layar PIN Kasir (langkah 2 login): nama gerai terpilih + 6 dot +
/// keypad COMPACT (tombol 72px — keypad besar lama ~110px terlalu
/// dominan di halaman login) + tombol "Masuk sebagai Kasir" 56px.
///
/// Dipakai LoginPage sesudah kasir memilih gerai, dan layar kunci
/// auto-lock 15 menit di _LoginGate.
///
/// Batch C8.2 — login kasir BARU: PIN diverifikasi via Edge Function
/// `verify-cashier-pin` (cocok ke SEMUA kasir aktif — PIN berlaku di
/// semua gerai). Sukses = identitas kasir (id + nama) dari SERVER.
/// FAIL CLOSED: PIN salah / terkunci / belum ada kasir terdaftar /
/// server tidak bisa dihubungi = TIDAK masuk (tidak ada lagi
/// fail-open seperti PIN per-gerai lama C4/C5).
class KasirPinPage extends StatefulWidget {
  const KasirPinPage({
    super.key,
    required this.outlet,
    required this.onBack,
    required this.onSuccess,
  });

  /// Gerai yang dipilih di langkah 1 (nama + alamat tampil di atas).
  final Outlet outlet;

  /// Kembali ke pilih gerai (PIN yang diketik dibuang — state widget
  /// ini ikut terbuang karena LoginPage membangunnya ulang per gerai).
  final VoidCallback onBack;

  final ValueChanged<LoginResult> onSuccess;

  @override
  State<KasirPinPage> createState() => _KasirPinPageState();
}

class _KasirPinPageState extends State<KasirPinPage> {
  String _entered = '';
  String? _error;
  bool _busy = false;

  void _onDigit(String digit) {
    if (_busy || _entered.length >= PinService.pinLength) return;
    setState(() {
      _entered += digit;
      _error = null;
    });
  }

  void _onBackspace() {
    if (_busy || _entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  void _finish({String? cashierId, String? cashierName}) {
    // Reset _busy DULU: spinner CircularProgressIndicator tidak
    // pernah berhenti sendiri — kalau _finish dipanggil dengan
    // _busy masih true, pumpAndSettle di test (dan frame di app
    // bila onSuccess tidak langsung unmount) tidak pernah selesai
    // (ketangkep CI v27.3: pumpAndSettle timed out).
    if (_busy) setState(() => _busy = false);
    OutletService.instance.selectOutlet(widget.outlet.id);
    widget.onSuccess(
      LoginResult(
        outletId: widget.outlet.id,
        role: AppRole.kasir,
        cashierId: cashierId,
        cashierName: cashierName,
      ),
    );
  }

  /// Masuk sebagai Kasir: PIN diverifikasi ke server (identitas dari
  /// server). Fail closed — tidak ada jalan masuk tanpa PIN yang
  /// cocok dengan kasir terdaftar.
  Future<void> _enterKasir() async {
    if (_entered.length != PinService.pinLength || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final outletId = widget.outlet.id;
    final pin = _entered;
    final result = await CashierService.instance.verifyPin(
      pin,
      outletId: outletId,
    );
    if (!mounted) return;
    switch (result.result) {
      case CashierVerifyResult.ok:
        // v40: Owner memaksa ganti PIN → kasir WAJIB ganti PIN
        // sendiri SEBELUM masuk POS (PIN lama sudah terbukti, jadi
        // sheet hanya minta PIN BARU 2x).
        if (result.permissions.forcePinChange) {
          setState(() => _busy = false);
          final changed = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => _ChangeOwnPinDialog(oldPin: pin),
          );
          if (changed != true || !mounted) {
            setState(() {
              _entered = '';
              _error = 'PIN harus diganti dulu — minta PIN baru ke Owner '
                  'bila lupa.';
            });
            return;
          }
        }
        _finish(
          cashierId: result.cashierId,
          cashierName: result.name,
        );
      case CashierVerifyResult.wrong:
        setState(() {
          _entered = '';
          _busy = false;
          _error = 'PIN salah — sisa '
              '${CashierService.instance.remainingAttempts} percobaan.';
        });
      case CashierVerifyResult.locked:
        setState(() {
          _entered = '';
          _busy = false;
          _error = 'Terlalu banyak percobaan salah. Coba lagi 5 menit lagi.';
        });
      case CashierVerifyResult.notFound:
        setState(() {
          _entered = '';
          _busy = false;
          _error = 'Belum ada kasir terdaftar — minta Owner daftarkan dulu.';
        });
      case CashierVerifyResult.outletNotAllowed:
        setState(() {
          _entered = '';
          _busy = false;
          _error = 'Kasir ini tidak boleh login di gerai ini — minta '
              'Owner centang gerai ini di Detail Kasir.';
        });
      case CashierVerifyResult.unavailable:
        setState(() {
          _entered = '';
          _busy = false;
          _error = 'Tidak bisa verifikasi — cek koneksi.';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : widget.onBack,
              icon: const Icon(Icons.chevron_left),
              label: const Text('Pilih gerai'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.outlet.name,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 20,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.outlet.address.isEmpty
                ? 'Alamat gerai (isi dari Pengaturan)'
                : widget.outlet.address,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: SukaTeaColors.muted,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Masukkan PIN Kasir 6 digit.',
            textAlign: TextAlign.center,
            style: TextStyle(color: SukaTeaColors.muted),
          ),
          const SizedBox(height: 4),
          const Text(
            'PIN diberikan Owner — berlaku di semua gerai.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: SukaTeaColors.muted,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'PIN Kasir',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 12),
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
          const SizedBox(height: 16),
          PinKeypad(
            compact: true,
            onDigit: _onDigit,
            onBackspace: _onBackspace,
            enabled: !_busy,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: SukaTeaColors.danger),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 12),
            const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ],
          const SizedBox(height: 20),
          TapFeedback(
            enabled: !_busy &&
                _entered.length == PinService.pinLength,
            child: FilledButton(
              onPressed: _entered.length == PinService.pinLength && !_busy
                  ? _enterKasir
                  : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 56),
              ),
              child: const Text(
                'Masuk sebagai Kasir',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Lupa PIN? Hubungi Owner',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: SukaTeaColors.emerald,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// Dialog ganti PIN sendiri (v40 — alur "Paksa ganti PIN").
/// PIN lama SUDAH terbukti saat login, jadi dialog hanya minta PIN
/// BARU 2x. Sukses = true (kasir lanjut masuk POS); batal = false
/// (kembali ke layar PIN — kasir tidak bisa masuk sebelum ganti).
class _ChangeOwnPinDialog extends StatefulWidget {
  const _ChangeOwnPinDialog({required this.oldPin});

  final String oldPin;

  @override
  State<_ChangeOwnPinDialog> createState() => _ChangeOwnPinDialogState();
}

class _ChangeOwnPinDialogState extends State<_ChangeOwnPinDialog> {
  late final TextEditingController _pinController;
  late final TextEditingController _confirmController;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _pinController = TextEditingController();
    _confirmController = TextEditingController();
  }

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _pinController.text.trim();
    final confirm = _confirmController.text.trim();
    if (!PinService.isValidPin(pin)) {
      setState(() => _error = 'PIN baru harus 6 digit angka.');
      return;
    }
    if (pin != confirm) {
      setState(() => _error = 'PIN tidak sama — ulangi dari awal.');
      return;
    }
    if (pin == widget.oldPin) {
      setState(() => _error = 'PIN baru harus beda dari PIN lama.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await CashierService.instance.changeOwnPin(
      oldPin: widget.oldPin,
      newPin: pin,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _error = result.error == 'pin_taken'
            ? 'PIN sudah dipakai kasir lain — pilih PIN lain.'
            : result.error == 'wrong'
                ? 'PIN lama tidak cocok — ulangi login.'
                : 'Gagal ganti PIN — coba lagi.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ganti PIN Kasir'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Owner meminta PIN diganti. Masukkan PIN baru (6 digit) — '
              'PIN lama tidak bisa dipakai lagi.',
              style: TextStyle(color: SukaTeaColors.muted),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pinController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'PIN baru (6 digit)',
              ),
            ),
            TextField(
              controller: _confirmController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Ulangi PIN baru',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: SukaTeaColors.danger),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('Simpan PIN Baru'),
        ),
      ],
    );
  }
}
