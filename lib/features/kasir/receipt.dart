import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
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
  buf.writeln('  Stand Es Teh');
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
class DigitalReceiptPage extends StatelessWidget {
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

  Future<void> _share(BuildContext context) async {
    final text = buildReceiptText(
      lines: lines,
      method: method,
      total: total,
      paid: paid,
      cashier: cashier,
      time: time,
    );
    try {
      await Share.share(text);
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
      lines: lines,
      method: method,
      total: total,
      paid: paid,
      cashier: cashier,
      time: time,
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
    final now = time ?? DateTime.now();
    final timeText =
        '${now.day}/${now.month}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return Scaffold(
      appBar: AppBar(title: const Text('Struk Digital')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
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
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                ),
                const Text(
                  'Stand Es Teh',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: SukaTeaColors.muted,
                  ),
                ),
                const SizedBox(height: 12),
                _hairline(),
                const SizedBox(height: 12),
                _row('Kasir', cashier),
                const SizedBox(height: 4),
                _row('Waktu', timeText),
                const SizedBox(height: 4),
                _row('Cara bayar', method.label),
                const SizedBox(height: 12),
                _hairline(),
                const SizedBox(height: 12),
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
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
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 2),
                _hairline(),
                const SizedBox(height: 12),
                _row('Total', formatRupiah(total), bold: true, size: 18),
                const SizedBox(height: 6),
                _row('Bayar (${method.label})', formatRupiah(paid)),
                const SizedBox(height: 6),
                _row('Kembali', formatRupiah(paid - total)),
                const SizedBox(height: 12),
                _hairline(),
                const SizedBox(height: 12),
                const Text(
                  'Terima kasih sudah mampir!',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: SukaTeaColors.muted),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 44,
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
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 44,
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
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 56),
                  ),
                  child: const Text('Selesai'),
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
