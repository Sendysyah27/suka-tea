import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/outlet_service.dart';

/// Ubah Gerai (Batch C4, FigCraft v29 frame 16): nama + alamat gerai,
/// simpan, hapus gerai.
///
/// Batch C8.2: bagian "PIN Gerai" DIHAPUS — PIN kasir per-gerai
/// (C4/C5) tidak lagi dipakai. Kasir didaftarkan Owner di halaman
/// "Kelola Kasir" (Pengaturan) dan PIN-nya berlaku di semua gerai.
/// PIN Kasir gerai yang lama tidak bisa diubah dari sini lagi.
class GeraiEditPage extends StatefulWidget {
  const GeraiEditPage({super.key, required this.outlet});

  final Outlet outlet;

  @override
  State<GeraiEditPage> createState() => _GeraiEditPageState();
}

class _GeraiEditPageState extends State<GeraiEditPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.outlet.name);
    _addressController =
        TextEditingController(text: widget.outlet.address);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
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
