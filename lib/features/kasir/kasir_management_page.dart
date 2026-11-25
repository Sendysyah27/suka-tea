import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/screen_title.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/outlet_service.dart';
import '../pin/pin_dialog.dart';
import '../pin/pin_service.dart';
import 'cashier_service.dart';
import 'kasir_detail_page.dart';

/// Kelola Kasir (Batch C8.2 — registri kasir Owner; v40: Resign +
/// arsip, badge LIVE, Ubah Nama + PIN).
/// HANYA Owner (halaman ini dibuka dari Pengaturan yang sudah
/// terkunci PIN Owner). Owner mendaftarkan kasir (nama + PIN 6 digit,
/// berlaku di semua gerai), mengubah nama + PIN kasir, menonaktifkan /
/// mengaktifkan kasir, dan meresign kasir (masuk arsip — nama + PIN
/// langsung bisa dipakai kasir baru).
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

/// Format tanggal pendek Indonesia: "22 Nov 09:12".
String formatShortDateTime(DateTime dt) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun',
    'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des',
  ];
  final d = dt.day.toString().padLeft(2, '0');
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '$d ${months[dt.month - 1]} $h:$m';
}

/// Format tanggal pendek Indonesia: "12 Nov".
String formatShortDate(DateTime dt) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun',
    'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des',
  ];
  return '${dt.day} ${months[dt.month - 1]}';
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
      case 'outlets_empty':
        return 'Pilih minimal 1 gerai.';
      case 'outlet_unknown':
        return 'Gerai tidak dikenal — muat ulang daftar.';
      case 'nothing_to_update':
        return 'Tidak ada yang diubah.';
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

  /// Ubah kasir (v40, frame 33): nama baru + PIN baru (kosong =
  /// tidak diubah). Kirim hanya yang berubah.
  Future<void> _editCashier(Cashier cashier) async {
    if (_ownerPin == null) return;
    final input = await showDialog<_EditCashierInput>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _EditCashierDialog(cashier: cashier),
    );
    if (input == null || !mounted) return;
    final nameChanged =
        input.name.isNotEmpty && input.name != cashier.name;
    final pinChanged = input.pin != null && input.pin!.isNotEmpty;
    if (!nameChanged && !pinChanged) return;
    final result = await CashierService.instance.updateCashierNamePin(
      ownerPin: _ownerPin!,
      cashierId: cashier.id,
      name: nameChanged ? input.name : null,
      pin: pinChanged ? input.pin : null,
    );
    if (!mounted) return;
    if (result.ok) {
      _snack('Kasir ${input.name} diperbarui.');
      await _reload();
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

  /// Resignkan kasir (v40, frame 29): masuk arsip, nama + PIN
  /// langsung bisa dipakai kasir baru.
  Future<void> _resignCashier(Cashier cashier) async {
    if (_ownerPin == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Resignkan ${cashier.name}?'),
        content: Text(
          '${cashier.name} tidak bisa login lagi dengan PIN-nya. '
          'Riwayat jualannya tetap tersimpan, dan nama + PIN-nya '
          'bisa dipakai kasir baru.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: SukaTeaColors.danger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Resign'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final ok = await CashierService.instance.resignCashier(
      ownerPin: _ownerPin!,
      cashierId: cashier.id,
    );
    if (!mounted) return;
    if (ok) {
      _snack('${cashier.name} diresign — masuk arsip.');
      await _reload();
    } else {
      _snack('Gagal meresign kasir — coba lagi.');
    }
  }

  /// Aktifkan lagi dari arsip Resign (v40).
  Future<void> _reactivate(Cashier cashier) async {
    if (_ownerPin == null) return;
    final ok = await CashierService.instance.setCashierActive(
      ownerPin: _ownerPin!,
      cashierId: cashier.id,
      active: true,
    );
    if (!mounted) return;
    if (ok) {
      _snack('${cashier.name} diaktifkan lagi.');
      await _reload();
    } else {
      _snack('Gagal mengaktifkan kasir — coba lagi.');
    }
  }

  /// Buka Detail Kasir (frame 28) — muat ulang list saat kembali.
  Future<void> _openDetail(Cashier cashier) async {
    if (_ownerPin == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => KasirDetailPage(
          cashier: cashier,
          ownerPin: _ownerPin!,
        ),
      ),
    );
    if (changed == true && mounted) await _reload();
  }

  String _outletName(String? outletId) {
    if (outletId == null || outletId.isEmpty) return '—';
    for (final o in OutletService.instance.outlets) {
      if (o.id == outletId) return o.name;
    }
    return 'Gerai';
  }

  /// Sub-teks kartu kasir (v40): gerai + terakhir sync/aktif.
  String _lastSeenText(Cashier cashier, DateTime now) {
    final outlet = _outletName(cashier.lastOutletId);
    final seen = cashier.lastSeenAt;
    if (seen == null) return '$outlet · belum pernah login';
    final minutes = now.difference(seen).inMinutes;
    if (isCashierLive(seen, now)) {
      if (minutes <= 0) return '$outlet · terakhir sync baru saja';
      if (minutes == 1) return '$outlet · terakhir sync 1 mnt lalu';
      return '$outlet · terakhir sync $minutes mnt lalu';
    }
    return '$outlet · terakhir aktif ${formatShortDateTime(seen)}';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final split = _cashiers == null
        ? null
        : splitCashierArchive(_cashiers!);
    return Scaffold(
      appBar: AppBar(title: const ScreenTitle('Kelola Kasir')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Kasir didaftarkan Owner (nama + PIN 6 digit).\n'
                'Batasi gerai per kasir dari Detail.',
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
          else ...[
            Text(
              'Kasir aktif (${split!.main.length})',
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            for (final cashier in split.main)
              _cashierCard(cashier, now),
            if (split.resigned.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Kasir Resign (${split.resigned.length})',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              for (final cashier in split.resigned)
                _resignedCard(cashier),
              const SizedBox(height: 12),
              const Text(
                'Kasir resign tidak bisa login. Nama + PIN-nya bisa '
                'dipakai kasir baru.',
                style: TextStyle(color: SukaTeaColors.muted),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _statusPill({
    required String label,
    required Color bg,
    required Color fg,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _cashierCard(Cashier cashier, DateTime now) {
    final live = isCashierLive(cashier.lastSeenAt, now);
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
                if (live)
                  _statusPill(
                    label: 'LIVE',
                    bg: SukaTeaColors.emerald,
                    fg: Colors.white,
                  ),
                if (live) const SizedBox(width: 6),
                // v40: NONAKTIF = pill abu + teks muted (desain v33) —
                // BUKAN putih-di-atas-border seperti badge lama.
                _statusPill(
                  label: cashier.active ? 'AKTIF' : 'NONAKTIF',
                  bg: cashier.active
                      ? SukaTeaColors.emerald
                      : SukaTeaColors.border,
                  fg: cashier.active
                      ? Colors.white
                      : SukaTeaColors.muted,
                ),
                IconButton(
                  onPressed: () => _openDetail(cashier),
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Detail kasir',
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _lastSeenText(cashier, now),
              style: const TextStyle(color: SukaTeaColors.muted),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _editCashier(cashier),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    child: const Text('Ubah'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: cashier.active
                        ? () => _resignCashier(cashier)
                        : () => _toggleActive(cashier),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      foregroundColor: cashier.active
                          ? SukaTeaColors.danger
                          : SukaTeaColors.emerald,
                    ),
                    child: Text(
                      cashier.active ? 'Resign' : 'Aktifkan',
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

  Widget _resignedCard(Cashier cashier) {
    final resignedAt = cashier.resignedAt;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cashier.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    resignedAt == null
                        ? 'Resign'
                        : 'Resign ${formatShortDate(resignedAt)}',
                    style: const TextStyle(color: SukaTeaColors.muted),
                  ),
                ],
              ),
            ),
            OutlinedButton(
              onPressed: () => _reactivate(cashier),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 48),
              ),
              child: const Text('Aktifkan lagi'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Hasil dialog tambah kasir: nama + PIN baru.
typedef _CashierInput = ({String name, String pin});

/// Hasil dialog ubah kasir (v40, frame 33): nama (selalu terisi) +
/// PIN baru (null = tidak diubah).
typedef _EditCashierInput = ({String name, String? pin});

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

/// Dialog ubah kasir (v40, frame 33): nama + PIN baru.
/// PIN dikosongkan = tidak diubah. Nama yang sama = tidak diubah.
class _EditCashierDialog extends StatefulWidget {
  const _EditCashierDialog({required this.cashier});

  final Cashier cashier;

  @override
  State<_EditCashierDialog> createState() => _EditCashierDialogState();
}

class _EditCashierDialogState extends State<_EditCashierDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _pinController;
  late final TextEditingController _confirmController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.cashier.name);
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
    if (pin.isNotEmpty) {
      if (!PinService.isValidPin(pin)) {
        setState(() => _error = 'PIN baru harus 6 digit angka.');
        return;
      }
      if (pin != confirm) {
        setState(() => _error = 'PIN tidak sama — ulangi dari awal.');
        return;
      }
    }
    Navigator.of(context).pop(
      (name: name, pin: pin.isEmpty ? null : pin),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ubah Kasir'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Nama',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pinController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'PIN baru (6 digit)',
                hintText: 'Kosongkan bila tidak diubah',
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
            const SizedBox(height: 8),
            const Text(
              'Nama baru dipakai di penjualan berikutnya. Riwayat '
              'lama tetap pakai nama lama.',
              style: TextStyle(color: SukaTeaColors.muted),
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
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
