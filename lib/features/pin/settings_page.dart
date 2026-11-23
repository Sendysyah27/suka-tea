import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/outlet_service.dart';
import '../../data/supabase_client.dart';
import '../gerai/gerai_list_page.dart';
import 'pin_dialog.dart';
import 'pin_service.dart';

/// Pengaturan — datanya HANYA dari Supabase (perintah Sendy 22 Nov 2026).
/// Halaman ini hanya bisa dibuka sesudah mode Owner terbuka (PIN).
/// Tidak ada pengaturan yang tersimpan lokal di HP — kecuali daftar
/// gerai (Batch C4): daftar gerai lokal di Drift karena Supabase
/// `outlets` hanya bisa dibaca member (app belum sign-in / Auth M0);
/// Supabase adalah sumber kebenaran di masa depan (migrasi 006).
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.outletId});

  /// Gerai yang PIN Owner-nya dipakai di halaman ini (null = default).
  final String? outletId;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _pinSet;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final set = await PinService.instance.isPinSet(
      outletId: widget.outletId,
    );
    if (!mounted) return;
    setState(() {
      _pinSet = set;
      _loading = false;
    });
  }

  Future<void> _changePin() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PinEntryDialog(
        requireCurrentPin: _pinSet == true,
        outletId: widget.outletId,
      ),
    );
    if (ok != true || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('PIN Owner diperbarui.')),
    );
    setState(() => _loading = true);
    await _loadStatus();
  }

  @override
  Widget build(BuildContext context) {
    final supabaseOn = SupabaseService.instance.isConfigured;
    return Scaffold(
      appBar: AppBar(title: const ScreenTitle('Pengaturan')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'PIN Owner',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _loading
                        ? 'Memeriksa status PIN…'
                        : _pinSet == true
                            ? 'PIN sudah diatur. Mode Owner dikunci PIN.'
                            : _pinSet == false
                                ? 'PIN belum diatur. Atur PIN supaya mode Owner terkunci.'
                                : 'Status PIN tidak bisa dicek (offline / Edge Function belum di-deploy).',
                    style: const TextStyle(color: SukaTeaColors.muted),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _loading ? null : _changePin,
                    child: Text(_pinSet == true ? 'Ubah PIN' : 'Atur PIN'),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'PIN hanya tersimpan di Supabase sebagai hash — tidak pernah tersimpan di HP ini.',
                    style: TextStyle(
                      color: SukaTeaColors.muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Outlet',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                  ),
                  const SizedBox(height: 4),
                  ListenableBuilder(
                    listenable: OutletService.instance,
                    builder: (context, _) {
                      final outlet =
                          OutletService.instance.currentOutlet;
                      return Text(
                        outlet?.name ?? 'Gerai 1 — Stand Utama',
                      );
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Supabase: ${supabaseOn ? 'Terhubung' : 'Belum dikonfigurasi (mode offline)'}',
                    style: const TextStyle(color: SukaTeaColors.muted),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Baris Gerai (Batch C4, FigCraft v29 frame 09): daftar,
          // pantau, dan ubah gerai — semua di menu Owner.
          Card(
            child: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const GeraiListPage(),
                ),
              ),
              borderRadius: BorderRadius.circular(20),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.storefront, color: SukaTeaColors.emerald),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Gerai',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                            ),
                          ),
                          Text(
                            '4 gerai — pantau & atur',
                            style: TextStyle(color: SukaTeaColors.muted),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: SukaTeaColors.muted),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tentang',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'SUKA TEA v0.1.0 — POS kasir es teh.\n'
                    'Semua pengaturan (PIN, QRIS, menu) tersimpan di Supabase, bukan di HP.',
                    style: TextStyle(color: SukaTeaColors.muted),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
