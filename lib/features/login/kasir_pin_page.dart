import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/roles.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/outlet_service.dart';
import '../pin/kasir_pin_service.dart';
import '../pin/pin_keypad.dart';
import '../pin/pin_service.dart';
import 'login_result.dart';

/// Layar PIN Kasir (langkah 2 login): nama gerai terpilih + 6 dot +
/// keypad COMPACT (tombol 72px — keypad besar lama ~110px terlalu
/// dominan di halaman login) + tombol "Masuk sebagai Kasir" 56px.
///
/// Dipakai LoginPage sesudah kasir memilih gerai yang PIN-nya sudah
/// diatur. Widget sendiri (bukan bagian dari LoginPage) supaya bisa
/// di-test langsung tanpa melewati langkah pilih gerai.
///
/// Verifikasi PIN SAMA seperti _enterKasir lama: salah -> error +
/// sisa percobaan; locked -> pesan 5 menit; unavailable / notSet ->
/// masuk langsung (offline-first, fail-open). PIN Owner TIDAK lewat
/// sini (tetap dialog di layar pilih gerai, fail closed).
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

  void _finish() {
    // Reset _busy DULU: spinner CircularProgressIndicator tidak
    // pernah berhenti sendiri — kalau _finish dipanggil dengan
    // _busy masih true, pumpAndSettle di test (dan frame di app
    // bila onSuccess tidak langsung unmount) tidak pernah selesai
    // (ketangkep CI v27.3: pumpAndSettle timed out).
    if (_busy) setState(() => _busy = false);
    OutletService.instance.selectOutlet(widget.outlet.id);
    widget.onSuccess(
      LoginResult(outletId: widget.outlet.id, role: AppRole.kasir),
    );
  }

  /// Masuk sebagai Kasir: PIN Kasir gerai terpilih (sudah dipastikan
  /// diatur oleh langkah 1 — isPinSet dicek lagi di sini supaya
  /// balapan (PIN dihapus di tengah jalan) tetap fail-open).
  Future<void> _enterKasir() async {
    if (_entered.length != PinService.pinLength || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final outletId = widget.outlet.id;
    final pin = _entered;
    final set = await KasirPinService.instance.isPinSet(outletId);
    if (!mounted) return;
    // Belum diatur / tidak bisa dicek (EF belum di-deploy / offline):
    // masuk langsung — perilaku app sebelum C4 (offline-first).
    if (set != true) {
      _finish();
      return;
    }
    final result = await KasirPinService.instance.verify(outletId, pin);
    if (!mounted) return;
    switch (result) {
      case PinVerifyResult.ok:
        _finish();
      case PinVerifyResult.notSet:
        // PIN dihapus di tengah jalan (balapan) — masuk langsung.
        _finish();
      case PinVerifyResult.wrong:
        setState(() {
          _entered = '';
          _busy = false;
          _error = 'PIN Kasir salah — sisa '
              '${KasirPinService.instance.remainingAttempts} percobaan.';
        });
      case PinVerifyResult.locked:
        setState(() {
          _entered = '';
          _busy = false;
          _error = 'Terlalu banyak percobaan salah. Coba lagi 5 menit lagi.';
        });
      case PinVerifyResult.unavailable:
        // Offline di tengah jalan — kasir tetap boleh masuk (offline-first).
        _finish();
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
            'Masukkan PIN Kasir 6 digit untuk gerai ini.',
            textAlign: TextAlign.center,
            style: TextStyle(color: SukaTeaColors.muted),
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
