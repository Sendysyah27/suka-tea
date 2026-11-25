import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/outlet_service.dart';
import 'cashier_service.dart';

/// Detail Kasir (v40, frame 28 — halaman push dari chevron kartu
/// Kelola Kasir).
///
/// PIN Owner diteruskan dari Kelola Kasir (JANGAN minta PIN lagi —
/// halaman ini hanya bisa dibuka dari sana). Tiap toggle / checkbox
/// SIMPAN LANGSUNG ke server (satu field per panggilan); gagal =
/// toggle kembali + snack. Pop mengembalikan true bila ada perubahan
/// (list induk muat ulang).
class KasirDetailPage extends StatefulWidget {
  const KasirDetailPage({
    super.key,
    required this.cashier,
    required this.ownerPin,
  });

  final Cashier cashier;
  final String ownerPin;

  @override
  State<KasirDetailPage> createState() => _KasirDetailPageState();
}

class _KasirDetailPageState extends State<KasirDetailPage> {
  late bool _canVoid;
  late bool _canDiscount;
  late bool _canCloseShift;
  late bool _forcePinChange;
  late Set<String> _allowedOutlets;
  bool _changed = false;
  bool _busy = false;

  Cashier get _cashier => widget.cashier;

  @override
  void initState() {
    super.initState();
    _canVoid = _cashier.canVoid;
    _canDiscount = _cashier.canDiscount;
    _canCloseShift = _cashier.canCloseShift;
    _forcePinChange = _cashier.forcePinChange;
    // allowedOutletIds kosong = tidak dibatasi (perilaku lama) →
    // tampilkan ke-4 gerai tercentang.
    _allowedOutlets = _cashier.allowedOutletIds.isEmpty
        ? OutletService.instance.outlets.map((o) => o.id).toSet()
        : _cashier.allowedOutletIds.toSet();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _errorText(String? error) {
    switch (error) {
      case 'outlets_empty':
        return 'Pilih minimal 1 gerai.';
      case 'outlet_unknown':
        return 'Gerai tidak dikenal — muat ulang.';
      case 'cashier_not_found':
        return 'Kasir tidak ditemukan — muat ulang daftar.';
      case 'offline':
        return 'Tidak bisa terhubung — periksa koneksi.';
      default:
        return 'Gagal menyimpan — coba lagi.';
    }
  }

  /// Simpan satu field pengaturan; gagal = kembalikan nilai lama.
  Future<void> _saveSetting({
    bool? canVoid,
    bool? canDiscount,
    bool? canCloseShift,
    bool? forcePinChange,
    List<String>? outletIds,
    required void Function() revert,
  }) async {
    final result = await CashierService.instance.setCashierSettings(
      ownerPin: widget.ownerPin,
      cashierId: _cashier.id,
      canVoid: canVoid,
      canDiscount: canDiscount,
      canCloseShift: canCloseShift,
      forcePinChange: forcePinChange,
      outletIds: outletIds,
    );
    if (!mounted) return;
    if (result.ok) {
      setState(() => _changed = true);
    } else {
      setState(revert);
      _snack(_errorText(result.error));
    }
  }

  /// Paksa keluar (v40, frame 31) — hanya bila kasir sedang LIVE.
  Future<void> _kick() async {
    final live = isCashierLive(_cashier.lastSeenAt, DateTime.now());
    if (!live || _busy) return;
    final outletName = _outletName(_cashier.lastOutletId);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Paksa ${_cashier.name} keluar?'),
        content: Text(
          '${_cashier.name} sedang LIVE di $outletName. HP-nya akan '
          'terkunci dalam ~10 detik dan ${_cashier.name} harus login '
          'ulang dengan PIN.',
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
            child: const Text('Paksa keluar'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _busy = true);
    final result = await CashierService.instance.kickCashier(
      ownerPin: widget.ownerPin,
      cashierId: _cashier.id,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      _snack('${_cashier.name} akan dipaksa keluar (maks ~10 detik).');
      Navigator.of(context).pop(true);
    } else {
      _snack(_errorText(result.error));
    }
  }

  /// Resign dari Detail (v40, frame 29) — sama seperti dari list.
  Future<void> _resign() async {
    if (_busy) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Resignkan ${_cashier.name}?'),
        content: Text(
          '${_cashier.name} tidak bisa login lagi dengan PIN-nya. '
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
    setState(() => _busy = true);
    final ok = await CashierService.instance.resignCashier(
      ownerPin: widget.ownerPin,
      cashierId: _cashier.id,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _snack('${_cashier.name} diresign — masuk arsip.');
      Navigator.of(context).pop(true);
    } else {
      _snack('Gagal meresign kasir — coba lagi.');
    }
  }

  String _outletName(String? outletId) {
    if (outletId == null || outletId.isEmpty) return 'Gerai';
    for (final o in OutletService.instance.outlets) {
      if (o.id == outletId) return o.name;
    }
    return 'Gerai';
  }

  String _lastSeenText(DateTime now) {
    final seen = _cashier.lastSeenAt;
    if (seen == null) return '';
    final minutes = now.difference(seen).inMinutes;
    if (minutes <= 0) return 'Terakhir sync baru saja';
    if (minutes == 1) return 'Terakhir sync 1 menit lalu';
    return 'Terakhir sync $minutes menit lalu';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final live = isCashierLive(_cashier.lastSeenAt, now);
    final outlets = OutletService.instance.outlets;
    return PopScope(
      // Tombol kembali sistem Android juga harus mengembalikan
      // _changed (supaya list induk muat ulang) — canPop false +
      // pop manual di sini.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => Navigator.of(context).pop(_changed),
          ),
          title: ScreenTitle(_cashier.name),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16, top: 12),
              child: _StatusPill(active: _cashier.active),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (live) ...[
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: SukaTeaColors.emerald,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'LIVE · ${_outletName(_cashier.lastOutletId)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _lastSeenText(now),
                      style:
                          const TextStyle(color: SukaTeaColors.muted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            _sectionTitle('Izin'),
            _toggleRow(
              label: 'Boleh void',
              sub: 'Batalkan penjualan yang sudah tersimpan',
              value: _canVoid,
              onChanged: (v) {
                setState(() => _canVoid = v);
                unawaited(_saveSetting(
                  canVoid: v,
                  revert: () => _canVoid = !v,
                ));
              },
            ),
            _toggleRow(
              label: 'Boleh diskon',
              sub: 'Beri diskon di Kasir (nominal / persen)',
              value: _canDiscount,
              onChanged: (v) {
                setState(() => _canDiscount = v);
                unawaited(_saveSetting(
                  canDiscount: v,
                  revert: () => _canDiscount = !v,
                ));
              },
            ),
            _toggleRow(
              label: 'Boleh tutup shift',
              sub: 'Tutup shift & hitung selisih kas',
              value: _canCloseShift,
              onChanged: (v) {
                setState(() => _canCloseShift = v);
                unawaited(_saveSetting(
                  canCloseShift: v,
                  revert: () => _canCloseShift = !v,
                ));
              },
            ),
            const SizedBox(height: 16),
            _sectionTitle('Gerai'),
            Text(
              '${_cashier.name} hanya bisa login di gerai yang dicentang.',
              style: const TextStyle(color: SukaTeaColors.muted),
            ),
            const SizedBox(height: 8),
            for (final outlet in outlets)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(outlet.name),
                value: _allowedOutlets.contains(outlet.id),
                onChanged: (checked) {
                  if (checked == null) return;
                  final next = Set<String>.from(_allowedOutlets);
                  if (checked) {
                    next.add(outlet.id);
                  } else {
                    if (next.length <= 1) {
                      _snack('Minimal 1 gerai harus dicentang.');
                      return;
                    }
                    next.remove(outlet.id);
                  }
                  setState(() => _allowedOutlets = next);
                  unawaited(_saveSetting(
                    outletIds: next.toList(),
                    revert: () => _allowedOutlets =
                        _cashier.allowedOutletIds.isEmpty
                            ? outlets.map((o) => o.id).toSet()
                            : _cashier.allowedOutletIds.toSet(),
                  ));
                },
              ),
            const SizedBox(height: 16),
            _sectionTitle('Keamanan'),
            _toggleRow(
              label: 'Paksa ganti PIN',
              sub: 'Wajib ganti PIN saat login berikut',
              value: _forcePinChange,
              onChanged: (v) {
                setState(() => _forcePinChange = v);
                unawaited(_saveSetting(
                  forcePinChange: v,
                  revert: () => _forcePinChange = !v,
                ));
              },
            ),
            const SizedBox(height: 16),
            const Text(
              'Zona bahaya',
              style: TextStyle(
                color: SukaTeaColors.danger,
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: live && !_busy ? _kick : null,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      foregroundColor: SukaTeaColors.danger,
                    ),
                    child: const Text('Paksa keluar'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _resign,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      backgroundColor: SukaTeaColors.danger,
                    ),
                    child: const Text('Resign'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              live
                  ? 'Paksa keluar mengunci HP ${_cashier.name} dalam '
                      '~10 detik.'
                  : 'Paksa keluar hanya bisa dipakai bila kasir sedang '
                      'LIVE.',
              style: const TextStyle(color: SukaTeaColors.muted),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 16,
        ),
      ),
    );
  }

  Widget _toggleRow({
    required String label,
    required String sub,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  sub,
                  style: const TextStyle(color: SukaTeaColors.muted),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color:
            active ? SukaTeaColors.emerald : SukaTeaColors.border,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        active ? 'AKTIF' : 'NONAKTIF',
        style: TextStyle(
          color: active ? Colors.white : SukaTeaColors.muted,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}
