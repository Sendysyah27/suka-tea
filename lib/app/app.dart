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
import '../features/login/login_page.dart';
import '../features/pin/pin_dialog.dart';
import '../features/pin/settings_page.dart';
import '../features/qris/qris_settings_page.dart';
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
class _LoginGate extends StatefulWidget {
  const _LoginGate();

  @override
  State<_LoginGate> createState() => _LoginGateState();
}

class _LoginGateState extends State<_LoginGate> {
  LoginResult? _login;

  @override
  Widget build(BuildContext context) {
    final login = _login;
    if (login == null) {
      return LoginPage(
        onSuccess: (result) => setState(() => _login = result),
      );
    }
    // Key per login supaya shell + semua halaman dibuat ulang segar
    // tiap login (keranjang/riwayat tidak bocor antar sesi).
    return SukaTeaShell(
      key: ValueKey(login.outletId + login.role.name),
      initialRole: login.role,
    );
  }
}

/// Shell + navigasi bawah 5 tab. Peran awal = hasil login (default
/// Kasir, fail closed). Mode Owner HANYA terbuka lewat PIN Owner
/// (hash bcrypt di Supabase, verifikasi via Edge Function). Turun ke
/// Kasir tidak perlu PIN.
/// Pengaturan (PIN, outlet) juga hanya bisa dibuka sesudah PIN benar.
class SukaTeaShell extends StatefulWidget {
  const SukaTeaShell({super.key, this.initialRole = AppRole.kasir});

  /// Peran dari halaman Login (Kasir / Owner).
  final AppRole initialRole;

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
        LaporanPage(role: _role),
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
              listenable: OutletService.instance,
              builder: (context, _) {
                return Text(
                  OutletService.instance.currentOutlet.name,
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
