import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../data/models.dart';

/// Teks struk digital. Format yang sama dipakai nanti untuk cetak ESC/POS
/// 58mm (Fase 2) — tinggal ganti renderer, datanya sama.
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

/// Dialog struk digital (MVP tanpa printer): tampil di app, bisa dibagikan
/// ke WhatsApp / disimpan PDF (M2), dan dilihat ulang dari riwayat.
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

  @override
  Widget build(BuildContext context) {
    final text = buildReceiptText(
      items: items,
      method: method,
      total: total,
      paid: paid,
    );
    return AlertDialog(
      title: const Text('Struk Digital'),
      content: SingleChildScrollView(
        child: Container(
          width: double.maxFinite,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: SukaTeaColors.leafBg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
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
