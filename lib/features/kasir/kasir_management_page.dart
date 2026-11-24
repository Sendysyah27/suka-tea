import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/screen_title.dart';
import '../../core/widgets/tap_feedback.dart';
import '../pin/pin_dialog.dart';
import '../pin/pin_service.dart';
import 'cashier_service.dart';

/// Kelola Kasir (Batch C8.2 — registri kasir Owner).
/// HANYA Owner (halaman ini dibuka dari Pengaturan yang sudah
/// terkunci PIN Owner). Owner mendaftarkan kasir (nama + PIN 6 digit,
/// berlaku di semua gerai), mengubah PIN kasir, dan menonaktifkan /
/// mengaktifkan kasir.
///
/// PIN Owner diminta SEKALI saat halaman dibuka (PinEntryDialog,
/// pola C3) dan dipakai ulang untuk tiap aksi SELAMA halaman ini
/// terbuka — PIN hanya hidup di memori State halaman ini, TIDAK
/// PERNAH disimpan ke disk. Server memverifikasi ulang PIN Owner di
/// tiap panggilan Edge Function, jadi memakai ulang di sini tidak
/// mengurangi keamanan.
class KasirManagementPage extends StatefulWidget {
  const KasirManagementPage({super.key});

  @override
  State<KasirManagementPage> createState() => _KasirManagementPageState();
}

class _KasirManagementPageState extends State<KasirManagementPage> {
  List<Cashier>? _cashiers;
  bool _loading = true;
  String? _error;

  /// PIN Owner yang terbukti saat halaman dibuka (memori saja).
  String? _ownerPin;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _askOwnerPin());
  }

  /// Minta PIN Owner dulu — tanpa bukti Owner, halaman ini tidak
  /// bisa dibuka (daftar kasir hanya dibaca sesudah PIN benar).
  Future<void> _askOwnerPin() async {
    // ownerPin di-assign di dalam closure onPinVerified, jadi TIDAK
    // ter-promote: cek null + `!` wajib di tiap pemakaian (pelajaran
    // CI v27.1 — pola sama seperti _save di Pengaturan QRIS).
    String? ownerPin;
    final pinOk = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PinEntryDialog(
        onPinVerified: (pin) => ownerPin = pin,
      ),
    );
    if (pinOk != true || ownerPin == null || !mounted) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    _ownerPin = ownerPin!;
    await _reload();
  }

  Future<void> _reload() async {
    if (_ownerPin == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await CashierService.instance.listCashiers(
      ownerPin: _ownerPin!,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.ok) {
        _cashiers = result.cashiers;
      } else {
        _error = 'Daftar kasir tidak bisa dimuat — periksa koneksi / '
            'Edge Function belum di-deploy.';
      }
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _errorText(String? error) {
    switch (error) {
      case 'pin_taken':
        return 'PIN sudah dipakai kasir lain — pilih PIN lain.';
      case 'name_taken':
        return 'Nama sudah dipakai kasir lain.';
      case 'name_invalid':
        return 'Nama kasir wajib diisi (maks 50 karakter).';
      case 'pin_invalid':
        return 'PIN kasir harus 6 digit angka.';
      case 'cashier_not_found':
        return 'Kasir tidak ditemukan — muat ulang daftar.';
      case 'offline':
        return 'Tidak bisa terhubung — periksa koneksi.';
      default:
        return 'Gagal — coba lagi.';
    }
  }

  /// Tambah kasir: dialog nama + PIN 2x, lalu daftar + muat ulang.
  Future<void> _addCashier() async {
    if (_ownerPin == null) return;
    final input = await showDialog<_CashierInput>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _AddCashierDialog(),
    );
    if (input == null || !mounted) return;
    final result = await CashierService.instance.registerCashier(
      ownerPin: _ownerPin!,
      name: input.name,
      pin: input.pin,
    );
    if (!mounted) return;
    if (result.ok) {
      _snack('Kasir ${input.name} terdaftar.');
      await _reload();
    } else {
      _snack(_errorText(result.error));
    }
  }

  /// Ubah PIN kasir: dialog PIN baru 2x.
  Future<void> _changePin(Cashier cashier) async {
    if (_ownerPin == null) return;
    final pin = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ChangePinDialog(cashierName: cashier.name),
    );
    if (pin == null || !mounted) return;
    final result = await CashierService.instance.setCashierPin(
      ownerPin: _ownerPin!,
      cashierId: cashier.id,
      pin: pin,
    );
    if (!mounted) return;
    if (result.ok) {
      _snack('PIN ${cashier.name} diperbarui.');
    } else {
      _snack(_errorText(result.error));
    }
  }

  /// Nonaktifkan / aktifkan lagi kasir (konfirmasi dulu).
  Future<void> _toggleActive(Cashier cashier) async {
    if (_ownerPin == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(cashier.active ? 'Nonaktifkan kasir?' : 'Aktifkan kasir?'),
        content: Text(
          cashier.active
              ? '${cashier.name} tidak bisa login lagi dengan PIN-nya '
                  'sampai diaktifkan kembali.'
              : '${cashier.name} bisa login lagi dengan PIN-nya.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(cashier.active ? 'Nonaktifkan' : 'Aktifkan'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final ok = await CashierService.instance.setCashierActive(
      ownerPin: _ownerPin!,
      cashierId: cashier.id,
      active: !cashier.active,
    );
    if (!mounted) return;
    if (ok) {
      _snack(
        cashier.active
            ? '${cashier.name} dinonaktifkan.'
            : '${cashier.name} diaktifkan.',
      );
      await _reload();
    } else {
      _snack('Gagal mengubah status kasir — coba lagi.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const ScreenTitle('Kelola Kasir')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Kasir didaftarkan Owner (nama + PIN 6 digit). PIN '
                'berlaku di SEMUA gerai — kasir login dengan PIN saja, '
                'nama tidak diketik sendiri.',
                style: TextStyle(color: SukaTeaColors.muted),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: TapFeedback(
              child: FilledButton.icon(
                onPressed: _ownerPin == null ? null : _addCashier,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 56),
                ),
                icon: const Icon(Icons.person_add),
                label: const Text('Tambah Kasir'),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _error!,
                      style: const TextStyle(color: SukaTeaColors.danger),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _reload,
                      child: const Text('Coba lagi'),
                    ),
                  ],
                ),
              ),
            )
          else if (_cashiers == null || _cashiers!.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Belum ada kasir terdaftar.\n'
                  'Daftarkan kasir pertama supaya ada yang bisa login.',
                  style: TextStyle(color: SukaTeaColors.muted),
                ),
              ),
            )
          else
            for (final cashier in _cashiers!) _cashierCard(cashier),
        ],
      ),
    );
  }

  Widget _cashierCard(Cashier cashier) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    cashier.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: cashier.active
                        ? SukaTeaColors.emerald
                        : SukaTeaColors.border,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    cashier.active ? 'AKTIF' : 'NONAKTIF',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _changePin(cashier),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    child: const Text('Ubah PIN'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _toggleActive(cashier),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    child: Text(
                      cashier.active ? 'Nonaktifkan' : 'Aktifkan',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Hasil dialog tambah kasir: nama + PIN baru.
typedef _CashierInput = ({String name, String pin});

/// Dialog tambah kasir: nama + PIN 6 digit + konfirmasi PIN.
/// Controller hidup di State (pola C5) — dispose hanya di dispose().
class _AddCashierDialog extends StatefulWidget {
  const _AddCashierDialog();

  @override
  State<_AddCashierDialog> createState() => _AddCashierDialogState();
}

class _AddCashierDialogState extends State<_AddCashierDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _pinController;
  late final TextEditingController _confirmController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _pinController = TextEditingController();
    _confirmController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    final pin = _pinController.text.trim();
    final confirm = _confirmController.text.trim();
    if (!isValidCashierName(name)) {
      setState(() => _error = 'Nama kasir wajib diisi (maks 50 karakter).');
      return;
    }
    if (!PinService.isValidPin(pin)) {
      setState(() => _error = 'PIN kasir harus 6 digit angka.');
      return;
    }
    if (pin != confirm) {
      setState(() => _error = 'PIN tidak sama — ulangi dari awal.');
      return;
    }
    Navigator.of(context).pop((name: name, pin: pin));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Tambah Kasir'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Nama + PIN diberikan Owner — kasir login dengan PIN ini '
              'di semua gerai.',
              style: TextStyle(color: SukaTeaColors.muted),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Nama kasir',
                hintText: 'cth: Budi',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pinController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'PIN kasir (6 digit)',
              ),
            ),
            TextField(
              controller: _confirmController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Ulangi PIN kasir',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: SukaTeaColors.danger),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Daftarkan'),
        ),
      ],
    );
  }
}

/// Dialog ubah PIN kasir: PIN baru 6 digit + konfirmasi.
class _ChangePinDialog extends StatefulWidget {
  const _ChangePinDialog({required this.cashierName});

  final String cashierName;

  @override
  State<_ChangePinDialog> createState() => _ChangePinDialogState();
}

class _ChangePinDialogState extends State<_ChangePinDialog> {
  late final TextEditingController _pinController;
  late final TextEditingController _confirmController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _pinController = TextEditingController();
    _confirmController = TextEditingController();
  }

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _pinController.text.trim();
    final confirm = _confirmController.text.trim();
    if (!PinService.isValidPin(pin)) {
      setState(() => _error = 'PIN kasir harus 6 digit angka.');
      return;
    }
    if (pin != confirm) {
      setState(() => _error = 'PIN tidak sama — ulangi dari awal.');
      return;
    }
    Navigator.of(context).pop(pin);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Ubah PIN — ${widget.cashierName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _pinController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'PIN baru (6 digit)',
              ),
            ),
            TextField(
              controller: _confirmController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Ulangi PIN baru',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: SukaTeaColors.danger),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Simpan PIN'),
        ),
      ],
    );
  }
}
