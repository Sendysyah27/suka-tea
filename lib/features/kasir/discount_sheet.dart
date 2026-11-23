import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/discount.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/tap_feedback.dart';

/// Sheet "Diskon manual" di keranjang Kasir: input nominal rupiah
/// (0..subtotal, angka saja — tanpa persen). Mengembalikan nominal
/// diskon yang diterapkan (int) atau null bila batal.
/// Diskon boleh dipakai Kasir maupun Owner — tercatat di riwayat
/// (SaleHistory.discount) supaya bisa diaudit.
Future<int?> showDiscountSheet(
  BuildContext context, {
  required int subtotal,
  required int currentDiscount,
}) async {
  var discount = clampDiscount(currentDiscount, subtotal);
  final controller = TextEditingController(text: discount.toString());
  final result = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) {
        final overLimit = discount > subtotal;
        final payable = payableAfterDiscount(subtotal, discount);
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Drag handle 30x4 (pola cash_sheet / frame 11).
              Center(
                child: Container(
                  width: 30,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFC9D6CE),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Diskon manual',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
              ),
              const SizedBox(height: 4),
              Text(
                'Subtotal ${formatRupiah(subtotal)}',
                style: const TextStyle(color: SukaTeaColors.muted),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Nominal diskon (Rp)',
                ),
                onChanged: (text) {
                  final value = int.tryParse(text);
                  if (value != null) {
                    setSheetState(() => discount = value);
                  }
                },
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Total bayar',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    formatRupiah(payable),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: SukaTeaColors.emerald,
                    ),
                  ),
                ],
              ),
              if (overLimit)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'Diskon tidak boleh melebihi subtotal.',
                    style: TextStyle(color: SukaTeaColors.danger),
                  ),
                ),
              const SizedBox(height: 16),
              TapFeedback(
                enabled: !overLimit,
                child: FilledButton(
                  onPressed: overLimit
                      ? null
                      : () => Navigator.of(context).pop(
                            clampDiscount(discount, subtotal),
                          ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 56),
                  ),
                  child: Text(
                    discount > 0
                        ? 'Terapkan diskon • -${formatRupiah(discount)}'
                        : 'Hapus diskon',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
  controller.dispose();
  return result;
}
