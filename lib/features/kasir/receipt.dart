import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/screen_title.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/models.dart';
import 'receipt_pdf.dart';

/// Teks struk digital. Format yang sama dipakai untuk cetak ESC/POS
/// 58mm (Fase 2) — tinggal ganti renderer, datanya sama.
String buildReceiptText({
  required List<ReceiptLine> lines,
  required PaymentMethod method,
  required int total,
  required int paid,
  String cashier = 'Kasir',
  DateTime? time,
}) {
  final now = time ?? DateTime.now();
  final buf = StringBuffer();
  buf.writeln('      SUKA TEA');
  buf.writeln('  Es Teh Kekinian');
  buf.writeln('--------------------------------');
  buf.writeln('Kasir : $cashier');
  buf.writeln('Waktu : ${now.toString().substring(0, 16)}');
  buf.writeln('--------------------------------');
  for (final line in lines) {
    buf.writeln('${line.qty}x ${line.name}');
    if (line.modifierText.isNotEmpty) buf.writeln('    ${line.modifierText}');
    buf.writeln(
      '    ${formatRupiah(line.unitPrice)}  =  ${formatRupiah(line.total)}',
    );
  }
  buf.writeln('--------------------------------');
  buf.writeln('TOTAL        ${formatRupiah(total)}');
  buf.writeln('Bayar (${method.label})  ${formatRupiah(paid)}');
  buf.writeln('Kembali      ${formatRupiah(paid - total)}');
  buf.writeln('--------------------------------');
  buf.writeln('   Terima kasih sudah mampir!');
  return buf.toString();
}

/// Struk digital — HALAMAN PENUH (mockup frame 03), bukan dialog:
/// header tengah, baris Kasir + Waktu + Cara bayar, item + modifier,
/// Total, Bayar, Kembali, tombol Bagikan (share sheet — user pilih
/// WhatsApp) + Simpan PDF + Selesai 56px.
///
/// Bagikan = FILE JPG hasil render preview struk di halaman ini
/// (RepaintBoundary + encode JPG), BUKAN teks — supaya yang diterima
/// di WhatsApp tampil sama persis dengan preview di app.
class DigitalReceiptPage extends StatefulWidget {
  const DigitalReceiptPage({
    super.key,
    required this.lines,
    required this.method,
    required this.total,
    required this.paid,
    this.cashier = 'Kasir',
    this.time,
  });

  final List<ReceiptLine> lines;
  final PaymentMethod method;
  final int total;
  final int paid;

  /// Nama kasir di struk: role aktif ("Kasir"/"Owner").
  final String cashier;

  /// Waktu transaksi (riwayat memakai waktu aslinya; kasir = sekarang).
  final DateTime? time;

  @override
  State<DigitalReceiptPage> createState() => _DigitalReceiptPageState();
}

class _DigitalReceiptPageState extends State<DigitalReceiptPage> {
  /// Kunci RepaintBoundary isi struk — untuk render JPG yang di-share.
  final _receiptKey = GlobalKey();

  Widget _hairline() {
    return const Divider(height: 1, color: SukaTeaColors.border);
  }

  Widget _row(String left, String right, {bool bold = false, double? size}) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      fontSize: size,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(left, style: style),
        Text(right, style: style),
      ],
    );
  }

  /// Render isi struk (yang di dalam RepaintBoundary) jadi file JPG,
  /// lalu bagikan lewat share sheet. Tombol-tombol di bawah struk TIDAK
  /// ikut ke gambar — yang di-share hanya struknya, sama persis dengan
  /// preview di halaman ini.
  Future<void> _share(BuildContext context) async {
    try {
      final boundary =
          _receiptKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('Struk belum tampil.');
      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      final ByteData? byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (byteData == null) throw StateError('Gagal merender struk.');
      final decoded = img.decodePng(byteData.buffer.asUint8List());
      if (decoded == null) throw StateError('Gagal membaca gambar struk.');
      final jpg = img.encodeJpg(decoded, quality: 92);
      final now = widget.time ?? DateTime.now();
      final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}-'
          '${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}'
          '${now.second.toString().padLeft(2, '0')}';
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/struk-suka-tea-$stamp.jpg');
      await file.writeAsBytes(jpg);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/jpeg')],
        text: 'Struk SUKA TEA',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal membagikan struk: $e')),
        );
      }
    }
  }

  Future<void> _savePdf(BuildContext context) async {
    final path = await saveReceiptPdf(
      lines: widget.lines,
      method: widget.method,
      total: widget.total,
      paid: widget.paid,
      cashier: widget.cashier,
      time: widget.time,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          path == null
              ? 'Gagal menyimpan PDF.'
              : 'PDF tersimpan: $path',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.time ?? DateTime.now();
    final timeText =
        '${now.day}/${now.month}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return Scaffold(
      appBar: AppBar(title: const ScreenTitle('Struk Digital')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Isi struk — dibungkus RepaintBoundary supaya tombol
                // Bagikan bisa me-render-nya jadi JPG. Container putih
                // di dalam boundary: JPG tidak punya transparansi, jadi
                // latar harus dicat putih eksplisit (kalau tidak, sudut
                // transparan jadi hitam di JPG).
                // PENTING: padding 24 HARUS di dalam boundary — padding
                // Card (20) + padding halaman (16) ada DI LUAR boundary,
                // jadi tanpa padding ini teks di JPG nempel ke tepi gambar
                // dan tidak kelihatan seperti struk (ketahuan 23 Nov 14:01:
                // "terlalu mepet ke teks").
                RepaintBoundary(
                  key: _receiptKey,
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Ikon 44x44 di tengah — Column stretch, jadi harus
                        // dibungkus Center supaya tidak melebar se-kartu.
                        Center(
                          child: Container(
                            width: 44,
                            height: 44,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: SukaTeaColors.emeraldSoft,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.local_drink,
                              color: SukaTeaColors.emerald,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'SUKA TEA',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                        const Text(
                          'Es Teh Kekinian',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: SukaTeaColors.muted,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _hairline(),
                        const SizedBox(height: 12),
                        _row('Kasir', widget.cashier),
                        const SizedBox(height: 4),
                        _row('Waktu', timeText),
                        const SizedBox(height: 4),
                        _row('Cara bayar', widget.method.label),
                        const SizedBox(height: 12),
                        _hairline(),
                        const SizedBox(height: 12),
                        for (final line in widget.lines)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${line.qty}x ${line.name}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      if (line.modifierText.isNotEmpty)
                                        Text(
                                          line.modifierText,
                                          style: const TextStyle(
                                            color: SukaTeaColors.muted,
                                            fontSize: 12,
                                          ),
                                        ),
                                      Text(
                                        formatRupiah(line.unitPrice),
                                        style: const TextStyle(
                                          color: SukaTeaColors.muted,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  formatRupiah(line.total),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 2),
                        _hairline(),
                        const SizedBox(height: 12),
                        // TOTAL 17 Bold + pill "LUNAS" emerald di samping label
                        // (FigCraft frame 03, v23): pill solid 56x22, teks
                        // putih 11 Bold; nominal emerald (bukan ink).
                        Row(
                          children: [
                            const Text(
                              'TOTAL',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 17,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              width: 56,
                              height: 22,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: SukaTeaColors.emerald,
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: const Text(
                                'LUNAS',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              formatRupiah(widget.total),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 17,
                                color: SukaTeaColors.emerald,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        _row(
                          'Bayar (${widget.method.label})',
                          formatRupiah(widget.paid),
                        ),
                        const SizedBox(height: 6),
                        _row('Kembali', formatRupiah(widget.paid - widget.total)),
                        const SizedBox(height: 12),
                        _hairline(),
                        const SizedBox(height: 12),
                        const Text(
                          'Terima kasih sudah mampir!',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: SukaTeaColors.muted),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 44,
                        child: TapFeedback(
                          child: OutlinedButton(
                            onPressed: () => _share(context),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 44),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              'Bagikan',
                              style: TextStyle(
                                color: SukaTeaColors.emerald,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 44,
                        child: TapFeedback(
                          child: OutlinedButton(
                            onPressed: () => _savePdf(context),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 44),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              'Simpan PDF',
                              style: TextStyle(
                                color: SukaTeaColors.emerald,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TapFeedback(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 56),
                    ),
                    child: const Text('Selesai'),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Struk tersimpan — bisa dibuka lagi dari Riwayat',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: SukaTeaColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
