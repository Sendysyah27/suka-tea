import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/cash.dart';
import '../../core/utils/money.dart';

/// Sheet "Uang diterima" untuk bayar tunai: chip nominal cepat
/// (Uang pas + pecahan >= total), input manual, kembalian live.
/// Mengembalikan nominal diterima (int) atau null bila batal.
/// Tombol konfirmasi nonaktif bila diterima < total.
Future<int?> showCashReceivedSheet(
  BuildContext context,
  int total,
) async {
  var received = total;
  final controller = TextEditingController(text: total.toString());
  final amounts = quickCashAmounts(total);
  final result = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) {
        final change = computeChange(received, total);
        void setReceived(int value) {
          setSheetState(() {
            received = value;
            controller.text = value.toString();
          });
        }

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
              const Text(
                'Uang diterima',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
              ),
              const SizedBox(height: 4),
              Text(
                'Total belanja ${formatRupiah(total)}',
                style: const TextStyle(color: SukaTeaColors.muted),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final amount in amounts)
                    ChoiceChip(
                      label: Text(
                        amount == total
                            ? 'Uang pas ${formatRupiah(amount)}'
                            : formatRupiah(amount),
                      ),
                      selected: received == amount,
                      onSelected: (_) => setReceived(amount),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Nominal manual (Rp)',
                ),
                onChanged: (text) {
                  final value = int.tryParse(text);
                  if (value != null && value >= 0) {
                    setSheetState(() => received = value);
                  }
                },
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Kembalian',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  Text(
                    formatRupiah(change),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: change < 0
                          ? SukaTeaColors.danger
                          : SukaTeaColors.emeraldDark,
                    ),
                  ),
                ],
              ),
              if (change < 0)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'Uang diterima kurang dari total.',
                    style: TextStyle(color: SukaTeaColors.danger),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: received < total
                    ? null
                    : () => Navigator.of(context).pop(received),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 56),
                ),
                child: Text(
                  'Konfirmasi • ${formatRupiah(received)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
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
