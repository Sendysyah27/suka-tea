import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/c10_models.dart';
import '../../data/outlet_service.dart';
import '../../data/package_service.dart';
import '../../data/stock_service.dart';
import '../../data/sync_service.dart';
import 'gudang_common.dart';

/// Kirim ke Gerai + top-up (Batch C10 WS3, FigCraft v32 frame 21).
/// Owner-only. Mode: "Kirim paket" (pilih paket — default gerai
/// terisi otomatis) / "Tambah stok" (item custom). Pilih gerai
/// (boleh banyak — dikirim SEQUENSIAL, satu per satu). Ringkasan:
/// item + gudang sesudah kirim + peringatan bila gudang akan
/// kosong / kurang (Kirim nonaktif + daftar kekurangan merah).
/// Kirim = atomik lokal (gudang −, gerai +) + event 'stock_send'
/// + syncNow. Server menolak ('gudang_kurang') -> stok lokal
/// dibalik + banner gagal + "Coba lagi" (form tetap terisi).
class SendStockPage extends StatefulWidget {
  const SendStockPage({super.key, this.packageId, this.outletId});

  /// Paket yang langsung dipilih (dari kartu paket).
  final String? packageId;

  /// Gerai yang langsung dipilih (dari Pantau Gerai / Dashboard).
  final String? outletId;

  @override
  State<SendStockPage> createState() => _SendStockPageState();
}

class _SendStockPageState extends State<SendStockPage> {
  bool _isTopUp = false;
  String? _packageId;
  final Set<String> _selectedOutlets = {};
  final List<_CustomRow> _customRows = [];
  String? _note;
  bool _sending = false;
  List<SendOutcome>? _lastResults;

  @override
  void initState() {
    super.initState();
    _packageId = widget.packageId;
    if (widget.outletId != null) _selectedOutlets.add(widget.outletId!);
    if (_selectedOutlets.isEmpty) {
      // Default: gerai aktif.
      _selectedOutlets.add(OutletService.instance.currentOutletId);
    }
    if (_packageId == null) {
      // Pre-fill paket default gerai yang dipilih.
      final def = PackageService.instance
          .defaultPackageIdFor(_selectedOutlets.first);
      if (def != null) _packageId = def;
    }
  }

  @override
  void dispose() {
    for (final r in _customRows) {
      r.qtyCtrl.dispose();
    }
    super.dispose();
  }

  List<SendItem> get _baseItems {
    if (!_isTopUp) {
      final pkg =
          _packageId == null ? null : PackageService.instance.packageById(_packageId!);
      if (pkg == null) return const [];
      return [
        for (final it in pkg.items)
          if (it.qty > 0)
            SendItem(stockName: it.stockName, qty: it.qty, unit: it.unit),
      ];
    }
    final items = <SendItem>[];
    for (final row in _customRows) {
      if (row.name == null) continue;
      final qty = parseQty(row.qtyCtrl.text) ?? 0;
      if (qty <= 0) continue;
      items.add(SendItem(
        stockName: row.name!,
        qty: qty,
        unit: row.unit,
      ));
    }
    return items;
  }

  List<String> get _gudangNames {
    final names = StockService.instance
        .stockByNameFor(gudangOutletId)
        .keys
        .toList()
      ..sort();
    return names;
  }

  String? _unitOf(String name) => StockService.instance
      .stockByNameFor(gudangOutletId)[name]
      ?.unit;

  void _addCustomRow() {
    final used = _customRows.map((r) => r.name).toSet();
    final available = _gudangNames.where((n) => !used.contains(n)).toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Semua bahan sudah ada di daftar.')),
      );
      return;
    }
    setState(() {
      _customRows.add(_CustomRow(
        name: available.first,
        qtyCtrl: TextEditingController(),
        unit: _unitOf(available.first) ?? 'pcs',
      ));
    });
  }

  Future<void> _send() async {
    if (_sending) return;
    final items = _baseItems;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isTopUp
                ? 'Isi dulu bahan + jumlah yang mau ditambah.'
                : 'Paket masih kosong — isi jumlahnya dulu di Ubah Paket.',
          ),
        ),
      );
      return;
    }
    if (_selectedOutlets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pilih gerai tujuan dulu.')),
      );
      return;
    }
    setState(() => _sending = true);
    final results = await PackageService.instance.sendToOutlets(
      outletIds: _selectedOutlets.toList(),
      packageId: _isTopUp ? null : _packageId,
      customItems: _isTopUp ? items : const [],
      note: _note ?? '',
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      _lastResults = results;
    });
    final okCount = results.where((r) => r.ok).length;
    if (okCount > 0) {
      unawaited(SyncService.instance.syncNow());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            okCount == results.length
                ? 'Terkirim ke $okCount gerai.'
                : 'Terkirim ke $okCount dari ${results.length} gerai — '
                    'cek yang gagal di bawah.',
          ),
        ),
      );
    }
  }

  /// "Coba lagi" untuk kiriman yang gagal di server: isi ulang
  /// form dari pemberitahuan gagal (mode Tambah stok + item yang
  /// sama + gerai yang sama).
  void _retryFailed(FailedSendNotice notice) {
    setState(() {
      _isTopUp = true;
      _customRows.clear();
      for (final it in notice.items) {
        _customRows.add(_CustomRow(
          name: it.stockName,
          qtyCtrl: TextEditingController(text: qtyText(it.qty)),
          unit: it.unit,
        ));
      }
      _selectedOutlets
        ..clear()
        ..add(notice.outletId);
      _lastResults = null;
    });
    PackageService.instance.clearFailedNotice(notice.sendId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const ScreenTitle('Kirim ke Gerai')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          PackageService.instance,
          StockService.instance,
          OutletService.instance,
        ]),
        builder: (context, _) {
          final gudangByName =
              StockService.instance.stockByNameFor(gudangOutletId);
          final items = _baseItems;
          final totalPerItem = <String, double>{};
          for (final it in items) {
            totalPerItem[it.stockName] =
                (totalPerItem[it.stockName] ?? 0) +
                    it.qty * _selectedOutlets.length;
          }
          final shortages = checkGudang(
            [
              for (final e in totalPerItem.entries)
                SendItem(
                  stockName: e.key,
                  qty: e.value,
                  unit: items
                          .firstWhere((i) => i.stockName == e.key)
                          .unit,
                ),
            ],
            gudangByName,
          );
          final failedNotices = PackageService.instance.failedNotices;
          final todaySends = PackageService.instance.sends
              .where((s) {
                final now = DateTime.now();
                return s.sentAt.year == now.year &&
                    s.sentAt.month == now.month &&
                    s.sentAt.day == now.day;
              })
              .take(5)
              .toList();
          final packages = PackageService.instance.activePackages;
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (failedNotices.isNotEmpty)
                for (final notice in failedNotices)
                  Card(
                    color: SukaTeaColors.deleteBg,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Kiriman ke ${outletName(notice.outletId)} GAGAL',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: SukaTeaColors.danger,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(notice.message),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              FilledButton(
                                onPressed: () => _retryFailed(notice),
                                child: const Text('Coba lagi'),
                              ),
                              const SizedBox(width: 8),
                              TextButton(
                                onPressed: () => PackageService.instance
                                    .clearFailedNotice(notice.sendId),
                                child: const Text('Tutup'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          for (final mode in const ['Kirim paket', 'Tambah stok'])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(mode),
                                selected: _isTopUp ==
                                    (mode == 'Tambah stok'),
                                onSelected: (_) => setState(
                                  () => _isTopUp = mode == 'Tambah stok',
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const GudangSectionTitle('Gerai tujuan'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final o in OutletService.instance.outlets)
                            FilterChip(
                              label: Text(o.name),
                              selected:
                                  _selectedOutlets.contains(o.id),
                              onSelected: (selected) {
                                setState(() {
                                  if (selected) {
                                    _selectedOutlets.add(o.id);
                                  } else {
                                    _selectedOutlets.remove(o.id);
                                  }
                                });
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (!_isTopUp) ...[
                        const GudangSectionTitle('Paket'),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          initialValue: _packageId,
                          decoration: const InputDecoration(
                            labelText: 'Paket kiriman',
                          ),
                          items: [
                            for (final p in packages)
                              DropdownMenuItem(
                                value: p.id,
                                child: Text(p.name),
                              ),
                          ],
                          onChanged: (v) =>
                              setState(() => _packageId = v),
                        ),
                      ] else ...[
                        const GudangSectionTitle('Bahan tambahan'),
                        const SizedBox(height: 8),
                        if (_customRows.isEmpty)
                          const Text(
                            'Belum ada bahan — tambah di bawah.',
                            style: TextStyle(color: SukaTeaColors.muted),
                          ),
                        for (var i = 0; i < _customRows.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  flex: 5,
                                  child: DropdownButtonFormField<String>(
                                    initialValue: _customRows[i].name,
                                    decoration: const InputDecoration(
                                      labelText: 'Bahan',
                                    ),
                                    items: [
                                      for (final n in _gudangNames)
                                        DropdownMenuItem(
                                          value: n,
                                          child: Text(n),
                                        ),
                                    ],
                                    onChanged: (v) {
                                      if (v == null) return;
                                      setState(() {
                                        _customRows[i].name = v;
                                        _customRows[i].unit =
                                            _unitOf(v) ?? 'pcs';
                                      });
                                    },
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  flex: 3,
                                  child: TextField(
                                    controller: _customRows[i].qtyCtrl,
                                    keyboardType: const TextInputType
                                        .numberWithOptions(decimal: true),
                                    decoration: InputDecoration(
                                      labelText:
                                          'Jumlah (${_customRows[i].unit})',
                                    ),
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => setState(
                                    () => _customRows.removeAt(i),
                                  ),
                                  tooltip: 'Hapus bahan',
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: SukaTeaColors.danger,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        OutlinedButton.icon(
                          onPressed: _addCustomRow,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Tambah bahan'),
                        ),
                      ],
                      const SizedBox(height: 16),
                      const GudangSectionTitle('Ringkasan kiriman'),
                      const SizedBox(height: 8),
                      if (items.isEmpty)
                        const Text(
                          'Belum ada bahan yang dikirim.',
                          style: TextStyle(color: SukaTeaColors.muted),
                        )
                      else
                        for (final it in items)
                          GudangRow(
                            label:
                                '${it.stockName} × ${_selectedOutlets.length} gerai',
                            value:
                                '${qtyText(it.qty * _selectedOutlets.length)} ${it.unit} '
                                '(gudang sesudah: ${qtyText((gudangByName[it.stockName]?.qty ?? 0) - it.qty * _selectedOutlets.length)} ${it.unit})',
                          ),
                      if (shortages.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: SukaTeaColors.deleteBg,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Gudang kurang:',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: SukaTeaColors.danger,
                                ),
                              ),
                              for (final s in shortages)
                                Text(
                                  '${s.stockName} kurang ${qtyText(s.missing)} ${s.unit} '
                                  '(gudang ${qtyText(s.available)} ${s.unit})',
                                  style: const TextStyle(
                                    color: SukaTeaColors.danger,
                                  ),
                                ),
                              const Text(
                                'Kirim dulu stok masuk, atau kurangi jumlah.',
                                style: TextStyle(
                                  color: SukaTeaColors.danger,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      GudangPrimaryButton(
                        label: _sending
                            ? 'Mengirim…'
                            : 'Kirim ke ${_selectedOutlets.length} gerai',
                        onPressed: (_sending || shortages.isNotEmpty)
                            ? null
                            : _send,
                        icon: Icons.local_shipping,
                      ),
                      if (_lastResults != null) ...[
                        const SizedBox(height: 12),
                        for (final r in _lastResults!)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(
                              children: [
                                Icon(
                                  r.ok
                                      ? Icons.check_circle
                                      : Icons.error,
                                  size: 18,
                                  color: r.ok
                                      ? SukaTeaColors.emerald
                                      : SukaTeaColors.danger,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    r.ok
                                        ? '${outletName(r.outletId)}: terkirim.'
                                        : '${outletName(r.outletId)}: ${r.message}',
                                    style: TextStyle(
                                      color: r.ok
                                          ? SukaTeaColors.ink
                                          : SukaTeaColors.danger,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const GudangSectionTitle('Kiriman hari ini'),
              const SizedBox(height: 8),
              if (todaySends.isEmpty)
                const GudangEmptyState(
                  message: 'Belum ada kiriman hari ini.',
                )
              else
                for (final s in todaySends)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${outletName(s.outletId)}'
                                  '${s.packageName.isNotEmpty ? ' • ${s.packageName}' : ' • Tambah stok'}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Chip(
                                label: Text(
                                  s.status == 'gagal' ? 'Gagal' : 'Terkirim',
                                ),
                                backgroundColor: s.status == 'gagal'
                                    ? SukaTeaColors.deleteBg
                                    : SukaTeaColors.emeraldSoft,
                                labelStyle: TextStyle(
                                  color: s.status == 'gagal'
                                      ? SukaTeaColors.danger
                                      : SukaTeaColors.emeraldDark,
                                  fontWeight: FontWeight.w600,
                                ),
                                side: BorderSide.none,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${s.sentAt.hour.toString().padLeft(2, '0')}:'
                            '${s.sentAt.minute.toString().padLeft(2, '0')}'
                            ' • ${s.sentBy}'
                            '${s.items.map((i) => ' • ${i.stockName} ${qtyText(i.qty)} ${i.unit}').join()}',
                            style: const TextStyle(
                              color: SukaTeaColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

class _CustomRow {
  _CustomRow({required this.name, required this.qtyCtrl, required this.unit});

  String? name;
  TextEditingController qtyCtrl;
  String unit;
}
