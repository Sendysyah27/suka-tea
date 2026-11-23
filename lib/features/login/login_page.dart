import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/roles.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/outlet_service.dart';
import '../pin/kasir_pin_service.dart';
import '../pin/pin_dialog.dart';
import 'cashier_session.dart';
import 'kasir_pin_page.dart';
import 'login_result.dart';

enum _LoginStep { select, pin }

/// Halaman Login (Batch C4, FigCraft v30 frame 13 "00 Login") —
/// DUA LANGKAH (redesain 23 Nov 2026, perintah Sendy: keypad PIN
/// Kasir lama terlalu besar di layar depan):
///
/// Langkah 1 (depan): pilih gerai + "Masuk sebagai Kasir" +
/// "Masuk sebagai Owner" (PIN Owner tetap di sini, dialog seperti
/// sebelumnya). Keypad PIN Kasir TIDAK ADA di layar ini.
/// - Tap "Masuk sebagai Kasir": cek KasirPinService.isPinSet(gerai) —
///   belum diatur / tidak bisa dicek -> langsung masuk Kasir
///   (fail-open, seperti sebelumnya); sudah diatur -> pindah ke
///   langkah 2 (layar PIN, keypad kecil).
/// - Tap "Masuk sebagai Owner": dialog PIN Owner gerai terpilih.
///
/// Langkah 2 (KasirPinPage): nama gerai + 6 dot + keypad compact
/// 72px + tombol "Masuk sebagai Kasir" 56px. Ganti gerai = kembali
/// ke langkah 1, PIN yang diketik dibuang (state KasirPinPage ikut
/// terbuang — dibangun ulang per gerai lewat ValueKey).
///
/// Sebelum C4, app langsung masuk Kasir tanpa login. Sekarang login
/// adalah gerbang sesi: tutup app = login lagi. Peran default
/// sesudah login = Kasir (fail closed); Owner hanya lewat PIN.
///
/// PIN Owner TIDAK ikut pola fail-open kasir (fail closed — PIN
/// Owner salah / tidak bisa dicek = tetap di halaman login).
///
/// Batch C5: langkah 1 juga minta NAMA KASIR (field teks di bawah
/// daftar gerai, sebelum tombol masuk). Nama wajib diisi untuk
/// masuk sebagai Kasir (validasi lokal, Owner tidak perlu nama) dan
/// disimpan bersama outlet sebagai sesi kasir — buka app lagi =
/// langsung masuk gerai itu tanpa login ulang (CashierSessionService).
/// Sesi Owner TIDAK PERNAH disimpan.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onSuccess});

  final ValueChanged<LoginResult> onSuccess;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  String _selectedOutletId = defaultOutletId;
  _LoginStep _step = _LoginStep.select;
  bool _busy = false;
  final _nameController = TextEditingController();
  String? _nameError;

  @override
  void initState() {
    super.initState();
    // Isi ulang nama kasir terakhir (sesi lama / ganti gerai) supaya
    // kasir tidak mengetik ulang tiap kali.
    _nameController.text =
        CashierSessionService.instance.cashierName ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _finish(AppRole role) {
    // Sama seperti KasirPinPage._finish: reset _busy dulu supaya
    // spinner tidak muter selamanya bila onSuccess tidak langsung
    // unmount halaman ini (ketangkep CI v27.3).
    if (_busy) setState(() => _busy = false);
    OutletService.instance.selectOutlet(_selectedOutletId);
    _handleSuccess(
      LoginResult(outletId: _selectedOutletId, role: role),
    );
  }

  /// Satu-satunya jalur sukses login dari halaman ini (langkah 1
  /// fail-open + langkah 2 PIN). Sesi kasir disimpan lokal di sini
  /// (outlet + nama kasir); sesi Owner TIDAK PERNAH disimpan.
  /// Simpan jalan tanpa await — save() mengisi field in-memory dulu
  /// sebelum tulis DB, jadi _LoginGate yang membaca hasSession
  /// sesudah onSuccess sudah melihat sesi.
  void _handleSuccess(LoginResult result) {
    if (result.role == AppRole.kasir) {
      unawaited(CashierSessionService.instance.save(
        outletId: result.outletId,
        cashierName: _nameController.text.trim(),
      ));
    }
    widget.onSuccess(result);
  }

  /// Tap "Masuk sebagai Kasir" di langkah 1: PIN Kasir sudah diatur
  /// -> layar PIN; belum diatur / tidak bisa dicek -> masuk langsung
  /// (fail-open, perilaku app sebelum C4, supaya kasir tetap bisa
  /// jualan offline).
  Future<void> _onKasirTap() async {
    if (_busy) return;
    // Nama kasir wajib (Batch C5) — tampil di AppBar + struk dan
    // disimpan di sesi. Validasi SEBELUM _busy supaya tombol tidak
    // terkunci saat nama kosong.
    if (_nameController.text.trim().isEmpty) {
      setState(() => _nameError = 'Isi nama kasir dulu.');
      return;
    }
    setState(() => _busy = true);
    final set =
        await KasirPinService.instance.isPinSet(_selectedOutletId);
    if (!mounted) return;
    if (set != true) {
      _finish(AppRole.kasir);
      return;
    }
    setState(() {
      _busy = false;
      _step = _LoginStep.pin;
    });
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
            if (_step == _LoginStep.pin) {
              final outlet = outlets.firstWhere(
                (o) => o.id == _selectedOutletId,
                orElse: () => outlets.isNotEmpty
                    ? outlets.first
                    : seedOutlets().first,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _LoginHeader(),
                  Expanded(
                    child: KasirPinPage(
                      key: ValueKey(_selectedOutletId),
                      outlet: outlet,
                      onBack: () =>
                          setState(() => _step = _LoginStep.select),
                      onSuccess: _handleSuccess,
                    ),
                  ),
                ],
              );
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _LoginHeader(),
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
                    'Nama Kasir',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nameController,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) {
                      if (_nameError != null) {
                        setState(() => _nameError = null);
                      }
                    },
                    decoration: InputDecoration(
                      hintText: 'cth: Budi',
                      errorText: _nameError,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
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
                    enabled: !_busy,
                    child: FilledButton(
                      onPressed: _busy ? null : _onKasirTap,
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

/// Wordmark + tagline + logo (FigCraft frame 13) — dipakai langkah
/// 1 dan langkah 2 supaya identitas layar login tetap sama.
class _LoginHeader extends StatelessWidget {
  const _LoginHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
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
      ],
    );
  }
}
