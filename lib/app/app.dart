import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/theme/app_icons.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/roles.dart';
import '../features/kasir/kasir_page.dart';
import '../features/katalog/katalog_page.dart';
import '../features/keuangan/keuangan_page.dart';
import '../features/laporan/laporan_page.dart';
import '../features/stok/stok_page.dart';

class SruputApp extends StatelessWidget {
  const SruputApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sruput POS',
      theme: SruputTheme.light,
      debugShowCheckedModeBanner: false,
      home: const SruputShell(),
    );
  }
}

/// Shell + navigasi bawah 5 tab. Peran demo bisa diganti dari AppBar
/// (Owner/Kasir) — autentikasi nyata via Supabase Auth di M0.
class SruputShell extends StatefulWidget {
  const SruputShell({super.key});

  @override
  State<SruputShell> createState() => _SruputShellState();
}

class _SruputShellState extends State<SruputShell> {
  int _index = 0;
  AppRole _role = AppRole.owner;

  static const _titles = ['Kasir', 'Kelola Menu', 'Stok', 'Keuangan', 'Laporan'];

  List<Widget> get _pages => [
        KasirPage(role: _role),
        KatalogPage(role: _role),
        const StokPage(),
        KeuanganPage(role: _role),
        const LaporanPage(),
      ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ChoiceChip(
              label: Text(_role == AppRole.owner ? 'Owner' : 'Kasir'),
              selected: true,
              onSelected: (_) => setState(() {
                _role = _role == AppRole.owner ? AppRole.kasir : AppRole.owner;
              }),
            ),
          ),
        ],
      ),
      body: _pages[_index],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: SruputColors.emerald,
        unselectedItemColor: SruputColors.muted,
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
          SruputColors.muted,
          BlendMode.srcIn,
        ),
      ),
      activeIcon: SvgPicture.asset(
        asset,
        width: 24,
        height: 24,
        colorFilter: const ColorFilter.mode(
          SruputColors.emerald,
          BlendMode.srcIn,
        ),
      ),
      label: label,
    );
  }
}
