import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../core/utils/split_payment.dart';
import '../../core/widgets/screen_title.dart';
import 'qris_service.dart';
import 'qris_settings_page.dart';
import 'qris_settings_service.dart';

/// Layar Bayar QRIS — generate QR dinamis.
///
/// Mode FULL (default): nominal QRIS DIKUNCI = total keranjang, kasir
/// TIDAK BISA mengubah nominal (Sendy 24 Nov 2026 — rawan disalahgunakan
/// kasir). Tidak ada field custom, preset, atau bulatkan di mode ini.
/// QR berlaku 5 menit (timer). Konfirmasi bayar masih MANUAL di MVP:
/// kasir mengecek mutasi/rekening dulu, baru tap "Sudah Dibayar".
/// Page ini mengembalikan nominal yang dibayar (int) atau null bila batal.
///
/// Mode split ([splitMode] = true, Batch C2): nominal yang dimasukkan
/// adalah BAGIAN QRIS saja (min Rp1.000, harus kurang dari total) —
/// sisanya dibayar tunai di sheet berikutnya. Tombol konfirmasi jadi
/// "Lanjut ke Tunai" dan nilai yang dikembalikan = bagian QRIS.
class QrisPayPage extends StatefulWidget {
  const QrisPayPage({
    super.key,
    required this.total,
    required this.role,
    this.splitMode = false,
  });

  final int total;

  /// Peran pemanggil — dipakai untuk meneruskan ke Pengaturan QRIS
  /// (hanya Owner yang bisa mengubah pengaturan merchant).
  final AppRole role;

  /// true = mode split: nominal = bagian QRIS saja (< total).
  final bool splitMode;

  @override
  State<QrisPayPage> createState() => _QrisPayPageState();
}

class _QrisPayPageState extends State<QrisPayPage> {
  late final TextEditingController _nominalController;
  late int _nominal;

  String? _payload;
  String? _merchantName;
  bool _demoMode = false;
  int _secondsLeft = 300;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Mode split: nominal awal = bagian QRIS default (di bawah total),
    // bukan total — total bukan nilai split yang valid.
    // Mode full: nominal DIKUNCI = total, tidak ada jalan mengubahnya
    // (field custom + preset + bulatkan tidak dirender — lihat build).
    _nominal = widget.splitMode
        ? defaultSplitQrisAmount(widget.total)
        : widget.total;
    _nominalController = TextEditingController(text: _nominal.toString());
    _merchantName = QrisSettingsService.instance.merchantName;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _nominalController.dispose();
    super.dispose();
  }

  String? get _merchantPayload {
    if (_demoMode) return QrisService.sampleStaticPayload();
    return QrisSettingsService.instance.staticPayload;
  }

  /// Error validasi mode split (null = valid / bukan mode split).
  /// Dipakai menonaktifkan Generate + menampilkan pesan live.
  String? get _splitError => widget.splitMode
      ? splitQrisError(qrisAmount: _nominal, total: widget.total)
      : null;

  void _startTimer() {
    _timer?.cancel();
    setState(() => _secondsLeft = 300);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_secondsLeft <= 1) {
        timer.cancel();
        setState(() => _payload = null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('QR kedaluwarsa — generate ulang.')),
        );
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  void _generate() {
    // Validasi split dipegang DI SINI juga, bukan cuma di tombol
    // (tombol nonaktif saat error) — supaya tidak ada jalur apa pun
    // (ketik, preset) yang bisa generate QR bagian >= total.
    final splitError = _splitError;
    if (splitError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(splitError)),
      );
      return;
    }
    final payload = _merchantPayload;
    if (payload == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('QRIS merchant belum diatur.')),
      );
      return;
    }
    try {
      final generated = QrisService.generateDynamic(
        staticPayload: payload,
        amount: _nominal,
      );
      setState(() {
        _payload = generated;
        _merchantName = QrisService.merchantName(payload);
      });
      _startTimer();
    } on ArgumentError catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message.toString())),
      );
    } on FormatException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
  }

  void _setNominal(int value) {
    setState(() {
      _nominal = value;
      _nominalController.text = value.toString();
      _payload = null;
      _timer?.cancel();
    });
  }

  String get _timerText {
    final m = (_secondsLeft ~/ 60).toString().padLeft(2, '0');
    final s = (_secondsLeft % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final merchantReady = _merchantPayload != null;
    return Scaffold(
      appBar: AppBar(
        title: ScreenTitle(
          widget.splitMode ? 'Bayar QRIS (Split)' : 'Bayar QRIS',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_demoMode)
            const Card(
              color: Color(0xFFFFF3CD),
              child: ListTile(
                title: Text('CONTOH — bukan QRIS asli'),
                subtitle: Text('Tampilan demo saja. Jangan dipakai untuk pembayaran nyata.'),
              ),
            ),
          if (!merchantReady)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'QRIS merchant belum diatur.',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Text(
                      'Minta Owner menempel kode QRIS statis di Pengaturan QRIS.',
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => QrisSettingsPage(
                              role: widget.role,
                            ),
                          ),
                        );
                        setState(() {
                          _merchantName =
                              QrisSettingsService.instance.merchantName;
                        });
                      },
                      child: const Text('Buka Pengaturan QRIS'),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _demoMode = true),
                      child: const Text('Lihat contoh tampilan (CONTOH)'),
                    ),
                  ],
                ),
              ),
            ),
          if (merchantReady) ...[
            if (_merchantName != null)
              Text(
                _merchantName!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            const SizedBox(height: 8),
            Text(
              formatRupiah(_nominal),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: SukaTeaColors.emerald,
              ),
            ),
            const SizedBox(height: 12),
            // Mode FULL: nominal DIKUNCI = total keranjang. Tidak ada
            // field custom / preset / bulatkan — kasir tidak bisa
            // generate QR dengan nominal lain (Sendy 24 Nov 2026).
            if (!widget.splitMode) ...[
              const Text(
                'Nominal QRIS = total keranjang — tidak bisa diubah.',
                textAlign: TextAlign.center,
                style: TextStyle(color: SukaTeaColors.muted),
              ),
              const SizedBox(height: 12),
            ],
            // Mode SPLIT: nominal bagian QRIS BOLEH diatur custom
            // (min Rp1.000, harus kurang dari total — lihat
            // split_payment.dart). Semua kontrol tetap seperti dulu.
            if (widget.splitMode) ...[
              TextField(
                controller: _nominalController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Nominal custom (Rp)',
                  border: OutlineInputBorder(),
                ),
                onChanged: (text) {
                  final value =
                      int.tryParse(text.replaceAll(RegExp(r'[^0-9]'), ''));
                  if (value != null && value > 0) {
                    setState(() {
                      _nominal = value;
                      _payload = null;
                      _timer?.cancel();
                    });
                  }
                },
              ),
              const SizedBox(height: 8),
              const Text(
                'Bagian QRIS — sisanya dibayar tunai.',
                style: TextStyle(color: SukaTeaColors.muted),
              ),
              const SizedBox(height: 4),
              Text(
                _splitError ??
                    'Sisa tunai: ${formatRupiah(splitCashRemainder(total: widget.total, qrisAmount: _nominal))}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: _splitError != null
                      ? SukaTeaColors.danger
                      : SukaTeaColors.emerald,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final preset in [5000, 10000, 20000, 50000, 100000])
                    ChoiceChip(
                      label: Text(formatRupiah(preset)),
                      selected: _nominal == preset,
                      onSelected: (_) => _setNominal(preset),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              onPressed: _splitError != null ? null : _generate,
              icon: const Icon(Icons.qr_code),
              label: Text(_payload == null ? 'Generate QR' : 'Generate Ulang'),
            ),
            if (_payload != null) ...[
              const SizedBox(height: 16),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: SukaTeaColors.border),
                  ),
                  child: QrImageView(
                    data: _payload!,
                    version: QrVersions.auto,
                    size: 240,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Berlaku $_timerText',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const Text(
                'Cek mutasi/rekening sebelum tap Sudah Dibayar.',
                textAlign: TextAlign.center,
              ),
            ],
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 56),
                  ),
                  child: const Text('Batal'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: _payload == null
                      ? null
                      : () => Navigator.of(context).pop(_nominal),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 56),
                  ),
                  child: Text(
                    widget.splitMode ? 'Lanjut ke Tunai' : 'Sudah Dibayar',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
