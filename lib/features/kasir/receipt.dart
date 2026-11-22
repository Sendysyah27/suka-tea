import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../data/models.dart';

/// Teks struk digital. Format yang sama dipakai nanti untuk cetak ESC/POS
/// 58mm (Fase 2) — tinggal ganti renderer, datanya sama. Teks ini TIDAK
/// lagi dipakai untuk tampilan dialog (dialog v2 pakai layout baris rapi,
/// bukan monospace bergaris putus-putus).
String buildReceiptText({
  required List<CartItem> items,
  required PaymentMethod method,
  required int total,
  required int paid,
  String cashier = 'Kasir',
}) {
  final buf = StringBuffer();
  buf.writeln('      SUKA TEA');
  buf.writeln('  Stand Es Teh');
  buf.writeln('--------------------------------');
  buf.writeln('Kasir : $cashier');
  buf.writeln('Waktu : ${DateTime.now().toString().substring(0, 16)}');
  buf.writeln('--------------------------------');
  for (final item in items) {
    buf.writeln('${item.qty}x ${item.label}');
    buf.writeln('    ${formatRupiah(item.unitPrice)}  =  ${formatRupiah(item.total)}');
  }
  buf.writeln('--------------------------------');
  buf.writeln('TOTAL        ${formatRupiah(total)}');
  buf.writeln('Bayar (${method.label})  ${formatRupiah(paid)}');
  buf.writeln('Kembali      ${formatRupiah(paid - total)}');
  buf.writeln('--------------------------------');
  buf.writeln('   Terima kasih sudah mampir!');
  return buf.toString();
}

/// Dialog struk digital v2 (MVP tanpa printer): baris rata kiri-kanan
/// dengan hairline tipis, TANPA teks monospace / garis putus-putus.
/// Bisa dibagikan ke WhatsApp / disimpan PDF (M2), dilihat ulang dari
/// riwayat.
class DigitalReceiptDialog extends StatelessWidget {
  const DigitalReceiptDialog({
    super.key,
    required this.items,
    required this.method,
    required this.total,
    required this.paid,
  });

  final List<CartItem> items;
  final PaymentMethod method;
  final int total;
  final int paid;

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

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final time =
        '${now.day}/${now.month}/${now.year} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      title: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: SukaTeaColors.emeraldSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.local_drink,
              color: SukaTeaColors.emerald,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SUKA TEA',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                ),
                Text(
                  'Struk Digital',
                  style: TextStyle(
                    fontSize: 13,
                    color: SukaTeaColors.muted,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: double.maxFinite,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _hairline(),
              const SizedBox(height: 12),
              _row('Waktu', time),
              const SizedBox(height: 4),
              _row('Cara bayar', method.label),
              const SizedBox(height: 12),
              _hairline(),
              const SizedBox(height: 12),
              for (final item in items)
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
                              '${item.qty}x ${item.label}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              formatRupiah(item.unitPrice),
                              style: const TextStyle(
                                color: SukaTeaColors.muted,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        formatRupiah(item.total),
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
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Bagikan via WhatsApp — M2')),
            );
          },
          child: const Text('Bagikan'),
        ),
        TextButton(
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Simpan PDF — M2')),
            );
          },
          child: const Text('Simpan PDF'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Selesai'),
        ),
      ],
    );
  }
}
