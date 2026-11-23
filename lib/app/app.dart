import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/theme/app_icons.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/roles.dart';
import '../core/widgets/screen_title.dart';
import '../core/widgets/tap_feedback.dart';
import '../data/outlet_service.dart';
import '../features/kasir/kasir_page.dart';
import '../features/katalog/katalog_page.dart';
import '../features/keuangan/keuangan_page.dart';
import '../features/login/cashier_session.dart';
import '../features/login/kasir_pin_page.dart';
import '../features/login/login_page.dart';
import '../features/login/login_result.dart';
import '../features/pin/pin_dialog.dart';
import '../features/pin/settings_page.dart';
import '../features/qris/qris_settings_page.dart';
import '../features/qris/qris_settings_service.dart';
import '../features/laporan/laporan_page.dart';
import '../features/stok/stok_page.dart';

class SukaTeaApp extends StatelessWidget {
  const SukaTeaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SUKA TEA',
      theme: SukaTeaTheme.light,
      debugShowCheckedModeBanner: false,
      home: const _LoginGate(),
    );
  }
}

/// Gerbang login (Batch C4): sebelum login, yang tampil hanya
/// LoginPage (pilih gerai + PIN Kasir / PIN Owner). Sesudah login
/// sukses, shell dibuka dengan peran hasil login. Tutup app =
/// login lagi (peran hanya di memori sesi — sama seperti sebelum C4).
///
/// Batch C5: sesi KASIR disimpan lokal (CashierSessionService) —
/// buka app lagi langsung masuk gerai itu tanpa login ulang. Sesi
/// Owner TIDAK PERNAH disimpan. Kasir yang idle 15 menit dikunci
/// otomatis ke layar PIN Kasir gerai aktif (Timer.periodic 30 detik
/// + cek saat app resume; lock hanya bila shell adalah route
/// teratas, supaya sheet/dialog bayar tidak tertutup paksa).
class _LoginGate extends StatefulWidget {
  const _LoginGate();

  @override
  State<_LoginGate> createState() => _LoginGateState();
}

class _LoginGateState extends State<_LoginGate>
    with WidgetsBindingObserver {
  LoginResult? _login;
  Timer? _idleTimer;
  bool _locked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Restore sesi kasir (Batch C5): outlet + nama kasir sudah
    // disimpan di Drift oleh LoginPage._handleSuccess. Outlet tidak
    // ditemukan (dihapus Owner) = sesi dianggap tidak ada.
    final session = CashierSessionService.instance;
    final outletId = session.outletId;
    if (outletId != null &&
        OutletService.instance.outletById(outletId) != null) {
      OutletService.instance.selectOutlet(outletId);
      QrisSettingsService.instance.currentOutletId = outletId;
      unawaited(QrisSettingsService.instance.load());
      _login = LoginResult(outletId: outletId, role: AppRole.kasir);
      session.touch();
      _startIdleTimer();
    }
  }

  @override
  void dispose() {
    _stopIdleTimer();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Kembali dari background: cek idle (kasir bisa saja
    // meninggalkan app > 15 menit di background).
    if (state == AppLifecycleState.resumed) _checkIdleLock();
  }

  void _startIdleTimer() {
    _stopIdleTimer();
    _idleTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkIdleLock(),
    );
  }

  void _stopIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  /// Satu-satunya jalur sukses login (LoginPage langkah 1 fail-open,
  /// langkah 2 PIN, dan PIN Owner). Sesi kasir sudah disimpan oleh
  /// LoginPage._handleSuccess sebelum onSuccess dipanggil.
  void _applyLogin(LoginResult result) {
    // Gerai aktif baru diketahui di sini (bukan di main) —
    // QRIS merchant dibaca dari Supabase untuk gerai ini.
    // load() jalan tanpa ditunggu supaya login tidak tertahan;
    // halaman QRIS membaca dari memori sesudah load selesai.
    QrisSettingsService.instance.currentOutletId = result.outletId;
    unawaited(QrisSettingsService.instance.load());
    setState(() => _login = result);
    if (result.role == AppRole.kasir) {
      CashierSessionService.instance.touch();
      _startIdleTimer();
    }
  }

  /// Keluar gerai: hapus sesi kasir + kembali ke layar pilih gerai.
  /// Dipakai tombol "Ganti Gerai" di Laporan dan tombol kembali di
  /// layar kunci.
  Future<void> _logout() async {
    _stopIdleTimer();
    await CashierSessionService.instance.clear();
    if (mounted) setState(() => _login = null);
  }

  /// Cek apakah sudah waktunya auto-lock. Lock HANYA saat ada sesi
  /// kasir aktif dan tidak ada modal/route di atas shell
  /// (ModalRoute.of(...).isCurrent == false saat sheet bayar,
  /// dialog PIN Owner, struk, atau halaman Pengaturan sedang
  /// terbuka — lock ditunda sampai tick berikutnya).
  void _checkIdleLock() {
    if (!mounted || _locked) return;
    final login = _login;
    if (login == null || login.role != AppRole.kasir) return;
    if (!shouldAutoLock(
      lastActive: CashierSessionService.instance.lastActive,
      now: DateTime.now(),
    )) {
      return;
    }
    if (ModalRoute.of(context)?.isCurrent != true) return;
    _lock();
  }

  /// Kunci ke layar PIN Kasir gerai aktif. Shell tetap ter-mount di
  /// bawah route kunci, jadi keranjang + tab yang terbuka TIDAK
  /// hilang. PIN benar = pop + jam idle direset. Tombol kembali =
  /// keluar gerai (sesi dihapus, balik ke layar pilih gerai).
  /// PIN Kasir belum diatur = masuk langsung (fail-open, jalur yang
  /// sama seperti login awal).
  Future<void> _lock() async {
    if (_locked || !mounted) return;
    final login = _login;
    if (login == null) return;
    _locked = true;
    final outlet = OutletService.instance.outletById(login.outletId) ??
        OutletService.instance.currentOutlet;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PopScope(
          canPop: false,
          child: Scaffold(
            appBar: AppBar(title: const ScreenTitle('Gerai Terkunci')),
            body: SafeArea(
              child: KasirPinPage(
                outlet: outlet,
                onBack: () {
                  // Kembali = keluar gerai.
                  unawaited(_logout());
                  Navigator.of(context).pop();
                },
                onSuccess: (_) {
                  Navigator.of(context).pop();
                },
              ),
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    _locked = false;
    // Masih login (bukan logout dari tombol kembali): reset jam idle.
    if (_login != null) CashierSessionService.instance.touch();
  }

  @override
  Widget build(BuildContext context) {
    final login = _login;
    if (login == null) {
      return LoginPage(onSuccess: _applyLogin);
    }
    // Key per login supaya shell + semua halaman dibuat ulang segar
    // tiap login (keranjang/riwayat tidak bocor antar sesi).
    // Listener PointerDown: tiap tap di mana pun di shell mereset
    // jam idle auto-lock (transaksi selesai juga memanggil touch()
    // lewat _selesaikanBayar di KasirPage).
    return Listener(
      onPointerDown: (_) => CashierSessionService.instance.touch(),
      child: SukaTeaShell(
        key: ValueKey(login.outletId + login.role.name),
        initialRole: login.role,
        onExitGerai: _logout,
      ),
    );
  }
}

/// Shell + navigasi bawah 5 tab. Peran awal = hasil login (default
/// Kasir, fail closed). Mode Owner HANYA terbuka lewat PIN Owner
/// (hash bcrypt di Supabase, verifikasi via Edge Function). Turun ke
/// Kasir tidak perlu PIN.
/// Pengaturan (PIN, outlet) juga hanya bisa dibuka sesudah PIN benar.
class SukaTeaShell extends StatefulWidget {
  const SukaTeaShell({
    super.key,
    this.initialRole = AppRole.kasir,
    required this.onExitGerai,
  });

  /// Peran dari halaman Login (Kasir / Owner).
  final AppRole initialRole;

  /// Keluar gerai (hapus sesi kasir + kembali ke layar pilih gerai).
  /// Dipanggil tombol "Ganti Gerai" di LaporanPage.
  final VoidCallback onExitGerai;

  @override
  State<SukaTeaShell> createState() => _SukaTeaShellState();
}

class _SukaTeaShellState extends State<SukaTeaShell> {
  int _index = 0;
  late AppRole _role;

  @override
  void initState() {
    super.initState();
    _role = widget.initialRole;
  }

  static const _titles = ['Kasir', 'Kelola Menu', 'Stok', 'Keuangan', 'Laporan'];

  List<Widget> get _pages => [
        KasirPage(role: _role),
        KatalogPage(role: _role),
        StokPage(role: _role),
        KeuanganPage(role: _role),
        LaporanPage(role: _role, onExitGerai: widget.onExitGerai),
      ];

  /// Minta PIN Owner gerai aktif. true = PIN benar, peran jadi Owner.
  Future<bool> _unlockOwner() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PinEntryDialog(
        outletId: OutletService.instance.currentOutletId,
      ),
    );
    if (ok == true) {
      setState(() => _role = AppRole.owner);
      return true;
    }
    return false;
  }

  Future<void> _openSettings() async {
    if (_role != AppRole.owner) {
      final unlocked = await _unlockOwner();
      if (!unlocked) return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          outletId: OutletService.instance.currentOutletId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Judul + underline emerald (FigCraft title_block, v23) +
        // nama gerai aktif di bawahnya (Batch C4 — supaya kasir
        // selalu tahu gerai mana yang sedang dibuka).
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ScreenTitle(_titles[_index]),
            const SizedBox(height: 2),
            ListenableBuilder(
              listenable: Listenable.merge([
                OutletService.instance,
                CashierSessionService.instance,
              ]),
              builder: (context, _) {
                // Batch C5: nama kasir dari sesi tampil di bawah
                // judul (Owner tidak punya nama kasir — hanya nama
                // gerai).
                final cashier = _role == AppRole.kasir
                    ? CashierSessionService.instance.cashierName
                    : null;
                final outletName =
                    OutletService.instance.currentOutlet.name;
                return Text(
                  cashier == null || cashier.isEmpty
                      ? outletName
                      : '$outletName • Kasir: $cashier',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: SukaTeaColors.muted,
                    fontWeight: FontWeight.w500,
                  ),
                );
              },
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Pengaturan',
            onPressed: _openSettings,
            icon: SvgPicture.asset(
              AppIcons.pengaturan,
              width: 24,
              height: 24,
            ),
          ),
          IconButton(
            tooltip: 'Pengaturan QRIS',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => QrisSettingsPage(role: _role),
              ),
            ),
            icon: const Icon(Icons.qr_code_2),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ChoiceChip(
              // FigCraft frame 01: tombol Owner 74x32 r16 emerald,
              // label putih 13 SemiBold (bukan label ink dari chipTheme).
              label: Text(
                _role == AppRole.owner ? 'Owner' : 'Kasir',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              selected: true,
              onSelected: (_) async {
                if (_role == AppRole.owner) {
                  // Turun ke Kasir tidak perlu PIN.
                  setState(() => _role = AppRole.kasir);
                } else {
                  // Naik ke Owner wajib PIN.
                  await _unlockOwner();
                }
              },
            ),
          ),
        ],
      ),
      // Ganti menu: fade + slide halus (320ms, easeOutCubic masuk /
      // easeIn keluar), bukan ganti kasar. KeyedSubtree per tab supaya
      // AnimatedSwitcher membedakan tiap halaman (kelima halaman
      // tipenya memang beda, kunci ini membuat niatnya eksplisit).
      // Halaman lama tetap di-unmount sesudah transisi — sama seperti
      // sebelum animasi (pindah tab memang membuat ulang halaman,
      // mis. keranjang Kasir).
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.03, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: KeyedSubtree(
          key: ValueKey<int>(_index),
          child: _pages[_index],
        ),
      ),
      // Navbar 2026 (FigCraft v26): bar putih 63px + hairline di atas,
      // 5 tab ikon garis Lucide 24px + label 11px. Tab aktif: pill
      // tint #EAF6EF 48x32 r16 di belakang ikon + ikon/label emerald
      // SemiBold; nonaktif: ikon/label muted Medium. BottomNavigationBar
      // bawaan tidak bisa memberi pill di belakang ikon aktif, jadi
      // nav kustom (Row + InkWell).
      // SafeArea di LUAR Container: bar tetap 63px persis, inset gesture
      // HP (bilah navigasi) jadi padding di bawah bar, bukan memotong
      // isi tab (SafeArea di dalam Container 63px bisa overflow 2px
      // bila inset > 14dp).
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          height: 63,
          decoration: const BoxDecoration(
            color: SukaTeaColors.card,
            border: Border(top: BorderSide(color: SukaTeaColors.border)),
          ),
          child: Row(
            children: [
              _navTab(AppIcons.navKasir, 'Kasir', 0),
              _navTab(AppIcons.navMenu, 'Menu', 1),
              _navTab(AppIcons.navStok, 'Stok', 2),
              _navTab(AppIcons.navKeuangan, 'Keuangan', 3),
              _navTab(AppIcons.navLaporan, 'Laporan', 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navTab(String asset, String label, int index) {
    final active = _index == index;
    return Expanded(
      child: TapFeedback(
        child: InkWell(
          onTap: () => setState(() => _index = index),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Pill aktif: AnimatedContainer supaya tint muncul halus
              // (250ms, easeOutCubic), bukan pop. Ikon + label ikut
              // berubah warna.
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                width: 48,
                height: 32,
                decoration: BoxDecoration(
                  color:
                      active ? SukaTeaColors.tint : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: SvgPicture.asset(
                    asset,
                    width: 24,
                    height: 24,
                    colorFilter: ColorFilter.mode(
                      active ? SukaTeaColors.emerald : SukaTeaColors.muted,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight:
                      active ? FontWeight.w600 : FontWeight.w500,
                  color: active
                      ? SukaTeaColors.emerald
                      : SukaTeaColors.muted,
                ),
                child: Text(label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
