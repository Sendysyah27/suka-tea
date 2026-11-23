import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/theme/app_theme.dart';

/// Halaman Scan QRIS (Batch C4 / Tugas 6): kamera full-screen +
/// bingkai scan + tombol senter + Batal. Dipakai dari Pengaturan QRIS
/// (Owner-only — halaman pemanggil sudah gate canManageMenu).
///
/// Alur: deteksi pertama yang punya rawValue TIDAK KOSONG langsung
/// dihentikan (detectionSpeed.noDuplicates + flag _handled supaya
/// deteksi berulang tidak memproses 2x), lalu pop dengan payload
/// ter-trim. Halaman pemanggil yang mengisi field + menjalankan
/// validasi (processScannedPayload) — halaman ini TIDAK menyimpan
/// apa pun dan TIDAK menampilkan payload mentah.
///
/// Kamera ditolak / tidak tersedia: TIDAK crash / layar merah.
/// State error controller ditampilkan sebagai kartu pesan jelas
/// ("izinkan kamera di Pengaturan HP") + tombol Batal.
class QrisScanPage extends StatefulWidget {
  const QrisScanPage({super.key});

  @override
  State<QrisScanPage> createState() => _QrisScanPageState();
}

class _QrisScanPageState extends State<QrisScanPage> {
  late final MobileScannerController _controller;
  var _handled = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
    );
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) continue;
      _handled = true;
      // Hentikan scan SEBELUM pop supaya tidak ada deteksi susulan
      // yang memproses / menutup halaman 2x.
      unawaited(_controller.stop());
      if (mounted) Navigator.of(context).pop(raw.trim());
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QRIS'),
        actions: [
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              final torchOn = state.torchState == TorchState.on;
              return IconButton(
                tooltip: torchOn ? 'Matikan senter' : 'Nyalakan senter',
                onPressed: () => unawaited(_controller.toggleTorch()),
                icon: Icon(
                  torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                ),
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            placeholderBuilder: (_) => const Center(
              child: CircularProgressIndicator(),
            ),
          ),
          // Bingkai scan di tengah + petunjuk.
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 260,
                  height: 260,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: SukaTeaColors.emerald,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'Arahkan ke kode QRIS statis merchant',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          // Kamera error (ditolak / tidak tersedia): kartu pesan jelas.
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              if (state.error == null) return const SizedBox.shrink();
              return Container(
                color: SukaTeaColors.leafBg,
                alignment: Alignment.center,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.no_photography,
                            size: 40,
                            color: SukaTeaColors.danger,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Kamera tidak bisa dipakai',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Izinkan kamera untuk SUKA TEA di Pengaturan HP '
                            '(Aplikasi > SUKA TEA > Izin > Kamera), lalu '
                            'coba lagi. Atau tempel kode QRIS secara manual.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: SukaTeaColors.muted),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Batal'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          // Tombol Batal di bawah (selalu terlihat, di luar kartu error).
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 56),
                backgroundColor: Colors.white,
              ),
              child: const Text('Batal'),
            ),
          ),
        ],
      ),
    );
  }
}
