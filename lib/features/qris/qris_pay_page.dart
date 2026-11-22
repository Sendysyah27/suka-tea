import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import 'qris_service.dart';
import 'qris_settings_page.dart';
import 'qris_settings_service.dart';

/// Layar Bayar QRIS — generate QR dinamis dengan nominal custom.
///
/// Nominal default = total keranjang, bisa diedit manual atau pakai preset.
/// QR berlaku 5 menit (timer). Konfirmasi bayar masih MANUAL di MVP:
/// kasir mengecek mutasi/rekening dulu, baru tap "Sudah Dibayar".
/// Page ini mengembalikan nominal yang dibayar (int) atau null bila batal.
class QrisPayPage extends StatefulWidget {
  const QrisPayPage({super.key, required this.total, required this.role});

  final int total;

  /// Peran pemanggil — dipakai untuk meneruskan ke Pengaturan QRIS
  /// (hanya Owner yang bisa mengubah pengaturan merchant).
  final AppRole role;

  @override
  State<QrisPayPage> createState() => _QrisPayPageState();
}

class _QrisPayPageState extends State<QrisPayPage> {
  late final TextEditingController _nominalController;
  late int _nominal;
  late final int _roundedUp;

  String? _payload;
  String? _merchantName;
  bool _demoMode = false;
  int _secondsLeft = 300;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _nominal = widget.total;
    _nominalController = TextEditingController(text: _nominal.toString());
    final rounded = ((widget.total + 999) ~/ 1000) * 1000;
    _roundedUp = rounded == widget.total ? rounded + 1000 : rounded;
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
      appBar: AppBar(title: const Text('Bayar QRIS')),
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
                color: SruputColors.emeraldDark,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nominalController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Nominal custom (Rp)',
                border: OutlineInputBorder(),
              ),
              onChanged: (text) {
                final value = int.tryParse(text.replaceAll(RegExp(r'[^0-9]'), ''));
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
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text('Total ${formatRupiah(widget.total)}'),
                  selected: _nominal == widget.total,
                  onSelected: (_) => _setNominal(widget.total),
                ),
                ChoiceChip(
                  label: Text('Bulatkan ${formatRupiah(_roundedUp)}'),
                  selected: _nominal == _roundedUp,
                  onSelected: (_) => _setNominal(_roundedUp),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _generate,
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
                    border: Border.all(color: SruputColors.border),
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
                  child: const Text('Batal'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: _payload == null
                      ? null
                      : () => Navigator.of(context).pop(_nominal),
                  child: const Text('Sudah Dibayar'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
