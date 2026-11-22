import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/theme/app_icons.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/roles.dart';
import '../features/kasir/kasir_page.dart';
import '../features/katalog/katalog_page.dart';
import '../features/keuangan/keuangan_page.dart';
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
      home: const SukaTeaShell(),
    );
  }
}

/// Shell + navigasi bawah 5 tab. Peran default = Kasir (fail closed).
/// Mode Owner HANYA terbuka lewat PIN Owner (hash bcrypt di Supabase,
/// verifikasi via Edge Function). Turun ke Kasir tidak perlu PIN.
/// Pengaturan (PIN, outlet) juga hanya bisa dibuka sesudah PIN benar.
class SukaTeaShell extends StatefulWidget {
  const SukaTeaShell({super.key});

  @override
  State<SukaTeaShell> createState() => _SukaTeaShellState();
}

class _SukaTeaShellState extends State<SukaTeaShell> {
  int _index = 0;
  AppRole _role = AppRole.kasir;

  static const _titles = ['Kasir', 'Kelola Menu', 'Stok', 'Keuangan', 'Laporan'];

  List<Widget> get _pages => [
        KasirPage(role: _role),
        KatalogPage(role: _role),
        const StokPage(),
        KeuanganPage(role: _role),
        const LaporanPage(),
      ];

  /// Minta PIN Owner. true = PIN benar, peran jadi Owner.
  Future<bool> _unlockOwner() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PinEntryDialog(),
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
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
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
              label: Text(_role == AppRole.owner ? 'Owner' : 'Kasir'),
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
      body: _pages[_index],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: SukaTeaColors.emerald,
        unselectedItemColor: SukaTeaColors.muted,
        items: [
          _item(AppIcons.kasir, 'Kasir'),
          _item(AppIcons.menu, 'Menu'),
          _item(AppIcons.stok, 'Stok'),
          _item(AppIcons.keuangan, 'Keuangan'),
          _item(AppIcons.laporan, 'Laporan'),
        ],
      ),
    );
  }

  BottomNavigationBarItem _item(String asset, String label) {
    return BottomNavigationBarItem(
      icon: SvgPicture.asset(
        asset,
        width: 24,
        height: 24,
        colorFilter: const ColorFilter.mode(
          SukaTeaColors.muted,
          BlendMode.srcIn,
        ),
      ),
      activeIcon: SvgPicture.asset(
        asset,
        width: 24,
        height: 24,
        colorFilter: const ColorFilter.mode(
          SukaTeaColors.emerald,
          BlendMode.srcIn,
        ),
      ),
      label: label,
    );
  }
}
