import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/utils/money.dart';
import '../../data/models.dart';

/// Render struk ke PDF (teks sama seperti struk, rapi kiri-kanan).
/// Dipakai tombol "Simpan PDF" di halaman struk.
Future<Uint8List> buildReceiptPdfBytes({
  required List<ReceiptLine> lines,
  required PaymentMethod method,
  required int total,
  required int paid,
  String cashier = 'Kasir',
  DateTime? time,
}) async {
  final now = time ?? DateTime.now();
  final timeText =
      '${now.day}/${now.month}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  final doc = pw.Document();

  pw.Widget row(String left, String right, {bool bold = false}) {
    final style = pw.TextStyle(
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      fontSize: 12,
    );
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [pw.Text(left, style: style), pw.Text(right, style: style)],
    );
  }

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.roll80,
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text(
            'SUKA TEA',
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              fontSize: 16,
            ),
          ),
          pw.Text(
            'Stand Es Teh',
            textAlign: pw.TextAlign.center,
            style: const pw.TextStyle(fontSize: 11),
          ),
          pw.SizedBox(height: 8),
          pw.Divider(),
          pw.SizedBox(height: 4),
          row('Kasir', cashier),
          row('Waktu', timeText),
          row('Cara bayar', method.label),
          pw.SizedBox(height: 4),
          pw.Divider(),
          pw.SizedBox(height: 4),
          for (final line in lines) ...[
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        '${line.qty}x ${line.name}',
                        style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                      ),
                      if (line.modifierText.isNotEmpty)
                        pw.Text(
                          line.modifierText,
                          style: const pw.TextStyle(fontSize: 10),
                        ),
                      pw.Text(
                        formatRupiah(line.unitPrice),
                        style: const pw.TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                ),
                pw.Text(
                  formatRupiah(line.total),
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                ),
              ],
            ),
            pw.SizedBox(height: 6),
          ],
          pw.Divider(),
          pw.SizedBox(height: 4),
          row('TOTAL', formatRupiah(total), bold: true),
          row('Bayar (${method.label})', formatRupiah(paid)),
          row('Kembali', formatRupiah(paid - total)),
          pw.SizedBox(height: 4),
          pw.Divider(),
          pw.SizedBox(height: 8),
          pw.Text(
            'Terima kasih sudah mampir!',
            textAlign: pw.TextAlign.center,
            style: const pw.TextStyle(fontSize: 11),
          ),
        ],
      ),
    ),
  );
  return doc.save();
}

/// Simpan PDF struk ke perangkat. Mengembalikan path file, atau null
/// bila gagal. Urutan lokasi:
/// 1. Folder Download publik (/storage/emulated/0/Download) — tempat
///    yang paling mudah ditemukan user.
/// 2. Folder dokumen eksternal app (getExternalStorageDirectory) —
///    bila Download tidak bisa ditulis (scoped storage).
/// 3. Folder dokumen app (getApplicationDocumentsDirectory).
/// Nama file: struk-suka-tea-YYYYMMDD-HHmmss.pdf
Future<String?> saveReceiptPdf({
  required List<ReceiptLine> lines,
  required PaymentMethod method,
  required int total,
  required int paid,
  String cashier = 'Kasir',
  DateTime? time,
}) async {
  try {
    final bytes = await buildReceiptPdfBytes(
      lines: lines,
      method: method,
      total: total,
      paid: paid,
      cashier: cashier,
      time: time,
    );
    final now = time ?? DateTime.now();
    final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final fileName = 'struk-suka-tea-$stamp.pdf';

    final candidates = <Directory?>[];
    try {
      candidates.add(Directory('/storage/emulated/0/Download'));
    } catch (_) {
      // Bukan Android — lewati.
    }
    try {
      candidates.add(await getExternalStorageDirectory());
    } catch (_) {
      // iOS / tidak tersedia.
    }
    try {
      candidates.add(await getApplicationDocumentsDirectory());
    } catch (_) {
      // Tidak tersedia.
    }
    for (final dir in candidates) {
      if (dir == null) continue;
      try {
        if (!await dir.exists()) continue;
        final file = File('${dir.path}/$fileName');
        await file.writeAsBytes(bytes);
        return file.path;
      } catch (_) {
        continue;
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}
