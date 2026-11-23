import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/outlet_service.dart';
import '../pin/kasir_pin_dialog.dart';
import '../pin/kasir_pin_service.dart';
import '../pin/pin_dialog.dart';

/// Ubah Gerai (Batch C4, FigCraft v29 frame 16): nama + alamat gerai,
/// status PIN Kasir + ubah PIN Kasir, simpan, hapus gerai.
///
/// "Ubah PIN Gerai" minta PIN Owner dulu (verifikasi ulang) — PIN
/// Owner yang diverifikasi diteruskan ke dialog PIN Kasir, yang
/// meneruskannya SEKALI ke Edge Function set-kasir-pin (server yang
/// memverifikasi). PIN tidak pernah disimpan di HP.
class GeraiEditPage extends StatefulWidget {
  const GeraiEditPage({super.key, required this.outlet});

  final Outlet outlet;

  @override
  State<GeraiEditPage> createState() => _GeraiEditPageState();
}

class _GeraiEditPageState extends State<GeraiEditPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  bool? _kasirPinSet;
  bool _loadingPin = true;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.outlet.name);
    _addressController =
        TextEditingController(text: widget.outlet.address);
    _loadKasirPinStatus();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _loadKasirPinStatus() async {
    final set =
        await KasirPinService.instance.isPinSet(widget.outlet.id);
    if (!mounted) return;
    setState(() {
      _kasirPinSet = set;
      _loadingPin = false;
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _snack('Nama gerai tidak boleh kosong.');
      return;
    }
    final ok = await OutletService.instance.updateOutlet(
      widget.outlet.id,
      name: name,
      address: _addressController.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      _snack('Gerai disimpan.');
      Navigator.of(context).pop();
    } else {
      _snack('Gagal menyimpan gerai — coba lagi.');
    }
  }

  /// Ubah PIN Kasir: (1) verifikasi PIN Owner gerai ini, (2) dialog
  /// PIN Kasir baru (2x ketik), (3) simpan via Edge Function.
  Future<void> _changeKasirPin() async {
    String? ownerPin;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PinEntryDialog(
        outletId: widget.outlet.id,
        onPinVerified: (pin) => ownerPin = pin,
      ),
    );
    if (ok != true || ownerPin == null || !mounted) return;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => KasirPinDialog(
        outletId: widget.outlet.id,
        ownerPin: ownerPin!,
      ),
    );
    if (changed == true) {
      _snack('PIN Kasir gerai diperbarui.');
      setState(() => _loadingPin = true);
      await _loadKasirPinStatus();
    }
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hapus gerai?'),
        content: Text(
          'Gerai "${widget.outlet.name}" akan dihapus dari daftar di '
          'HP ini. Transaksi & order Pending gerai ini TIDAK ikut '
          'terhapus — hanya tidak tampil lagi per gerai.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Hapus',
              style: TextStyle(color: SukaTeaColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final ok = await OutletService.instance.removeOutlet(widget.outlet.id);
    if (!mounted) return;
    if (ok) {
      _snack('Gerai dihapus.');
      Navigator.of(context).pop();
    } else {
      _snack('Gerai ini tidak bisa dihapus (gerai utama / gerai aktif).');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pinLabel = _loadingPin
        ? 'Memeriksa…'
        : _kasirPinSet == true
            ? 'PIN Kasir sudah diatur'
            : _kasirPinSet == false
                ? 'PIN Kasir belum diatur'
                : 'Status PIN tidak bisa dicek (offline / Edge Function belum di-deploy)';
    return Scaffold(
      appBar: AppBar(title: const ScreenTitle('Ubah Gerai')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Nama gerai',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              hintText: 'Gerai 1 — Stand Utama',
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Alamat gerai',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _addressController,
            decoration: const InputDecoration(
              hintText: 'Alamat gerai (isi dari Pengaturan)',
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'PIN Gerai',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (int i = 0; i < 6; i++)
                Container(
                  width: 12,
                  height: 12,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _kasirPinSet == true
                        ? SukaTeaColors.emerald
                        : SukaTeaColors.border,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            pinLabel,
            style: const TextStyle(color: SukaTeaColors.muted),
          ),
          const SizedBox(height: 4),
          const Text(
            'PIN kasir 6 digit — ubah butuh PIN Owner.',
            style: TextStyle(color: SukaTeaColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _changeKasirPin,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 56),
            ),
            child: const Text(
              'Ubah PIN Gerai',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 56),
            ),
            child: const Text(
              'Simpan',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _delete,
            child: const Text(
              'Hapus gerai',
              style: TextStyle(color: SukaTeaColors.danger),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Perubahan nama/alamat tersimpan di HP ini — sinkronisasi '
            'Supabase menyusul (migrasi 006).',
            textAlign: TextAlign.center,
            style: TextStyle(color: SukaTeaColors.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
