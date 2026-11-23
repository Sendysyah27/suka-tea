import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/roles.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/outlet_service.dart';
import '../pin/kasir_pin_service.dart';
import '../pin/pin_dialog.dart';
import '../pin/pin_keypad.dart';
import '../pin/pin_service.dart';

/// Hasil login: gerai yang dipilih + peran sesi ini.
class LoginResult {
  const LoginResult({required this.outletId, required this.role});

  final String outletId;
  final AppRole role;
}

/// Halaman Login (Batch C4, FigCraft v30 frame 13 "00 Login"):
/// pilih gerai + PIN Kasir -> "Masuk sebagai Kasir", atau
/// "Masuk sebagai Owner" (PIN Owner gerai terpilih -> menu Owner).
///
/// Sebelum C4, app langsung masuk Kasir tanpa login. Sekarang login
/// adalah gerbang sesi: tutup app = login lagi. Peran default
/// sesudah login = Kasir (fail closed); Owner hanya lewat PIN.
///
/// PIN Kasir: bila PIN Kasir gerai itu BELUM diatur (atau Edge
/// Function verify-kasir-pin belum di-deploy / offline), kasir masuk
/// langsung — perilaku app sebelum C4, supaya kasir tetap bisa
/// jualan offline. PIN Kasir hanya mengunci bila sudah diatur DAN
/// fungsinya sudah di-deploy. PIN Owner TIDAK ikut pola ini
/// (fail closed — PIN Owner salah / tidak bisa dicek = tetap di
/// halaman login).
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onSuccess});

  final ValueChanged<LoginResult> onSuccess;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  String _selectedOutletId = defaultOutletId;
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

  void _finish(AppRole role) {
    OutletService.instance.selectOutlet(_selectedOutletId);
    widget.onSuccess(
      LoginResult(outletId: _selectedOutletId, role: role),
    );
  }

  /// Masuk sebagai Kasir: PIN Kasir gerai terpilih (bila sudah diatur).
  Future<void> _enterKasir() async {
    if (_entered.length != PinService.pinLength || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final outletId = _selectedOutletId;
    final pin = _entered;
    final set = await KasirPinService.instance.isPinSet(outletId);
    if (!mounted) return;
    // Belum diatur / tidak bisa dicek (EF belum di-deploy / offline):
    // masuk langsung — perilaku app sebelum C4 (offline-first).
    if (set != true) {
      _finish(AppRole.kasir);
      return;
    }
    final result = await KasirPinService.instance.verify(outletId, pin);
    if (!mounted) return;
    switch (result) {
      case PinVerifyResult.ok:
        _finish(AppRole.kasir);
      case PinVerifyResult.notSet:
        // PIN dihapus di tengah jalan (balapan) — masuk langsung.
        _finish(AppRole.kasir);
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
        _finish(AppRole.kasir);
    }
  }

  /// Masuk sebagai Owner: dialog PIN Owner gerai terpilih (sudah
  /// menangani PIN belum diatur -> buat PIN baru, seperti sebelum C4).
  Future<void> _enterOwner() async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PinEntryDialog(outletId: _selectedOutletId),
    );
    if (ok == true && mounted) _finish(AppRole.owner);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: OutletService.instance,
          builder: (context, _) {
            final outlets = OutletService.instance.outlets;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  // Wordmark + tagline (FigCraft frame 13).
                  const Text(
                    'SUKA TEA',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 26,
                      color: SukaTeaColors.emerald,
                      letterSpacing: 2.6,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Container(
                      width: 28,
                      height: 4,
                      decoration: BoxDecoration(
                        color: SukaTeaColors.emerald,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Es Teh Kekinian — Kasir',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: SukaTeaColors.muted),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        color: SukaTeaColors.tint,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      alignment: Alignment.center,
                      child: SvgPicture.asset(
                        AppIcons.navKasir,
                        width: 64,
                        height: 64,
                        colorFilter: const ColorFilter.mode(
                          SukaTeaColors.emerald,
                          BlendMode.srcIn,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Pilih Gerai',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < outlets.length; i++)
                    _outletCard(outlets[i], i + 1),
                  const SizedBox(height: 16),
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
                  const SizedBox(height: 12),
                  PinKeypad(
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
                  const SizedBox(height: 16),
                  const Text(
                    'Masuk sebagai Owner butuh PIN Owner gerai ini.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: SukaTeaColors.muted,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Lupa PIN? Hubungi Owner',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: SukaTeaColors.emerald,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TapFeedback(
                    enabled: !_busy &&
                        _entered.length == PinService.pinLength,
                    child: FilledButton(
                      onPressed: _entered.length == PinService.pinLength &&
                              !_busy
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
                  TapFeedback(
                    enabled: !_busy,
                    child: OutlinedButton(
                      onPressed: _busy ? null : _enterOwner,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 56),
                      ),
                      child: const Text(
                        'Masuk sebagai Owner',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _outletCard(Outlet outlet, int number) {
    final selected = outlet.id == _selectedOutletId;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: _busy
            ? null
            : () => setState(() {
                  _selectedOutletId = outlet.id;
                  _entered = '';
                  _error = null;
                }),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? SukaTeaColors.tint : SukaTeaColors.card,
            border: Border.all(
              color: selected
                  ? SukaTeaColors.emerald
                  : SukaTeaColors.border,
              width: selected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: SukaTeaColors.emerald,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$number',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      outlet.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      outlet.address.isEmpty
                          ? 'Alamat gerai (isi dari Pengaturan)'
                          : outlet.address,
                      style: const TextStyle(
                        color: SukaTeaColors.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected
                      ? SukaTeaColors.emerald
                      : Colors.transparent,
                  border: selected
                      ? null
                      : Border.all(
                          color: SukaTeaColors.border,
                          width: 1.5,
                        ),
                ),
                child: selected
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
