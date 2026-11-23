import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/cash.dart';
import '../../core/utils/money.dart';
import '../../core/utils/sheet_pop.dart';
import '../../core/widgets/tap_feedback.dart';

/// Sheet "Uang diterima" untuk bayar tunai: chip nominal cepat
/// (Uang pas + pecahan >= total), input manual, kembalian live.
/// Mengembalikan nominal diterima (int) atau null bila batal.
/// Tombol konfirmasi nonaktif bila diterima < total.
///
/// [subtitle] = teks pengganti "Total belanja RpX" — dipakai alur
/// split (Batch C2) untuk menampilkan "Sisa tunai setelah QRIS RpX".
///
/// Tombol konfirmasi TIDAK pop langsung: pop jalan lewat
/// [popSheetSafely] — unfocus TextField + tunggu satu frame dulu.
/// Pop langsung saat TextField masih fokus = layar merah debug
/// (assertion '_dependents.isEmpty', 23 Nov 2026 16:01).
Future<int?> showCashReceivedSheet(
  BuildContext context,
  int total, {
  String? subtitle,
}) async {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _CashSheetContent(total: total, subtitle: subtitle),
  );
}

/// Isi sheet sebagai StatefulWidget sendiri supaya TextEditingController
/// hidup PERSIS selama subtree sheet (initState -> dispose).
///
/// POLA LAMA SALAH (CI v25.2, 23 Nov 2026): controller dibuat di luar
/// builder + `dispose()` langsung sesudah `await showModalBottomSheet`.
/// Future sheet selesai saat pop() dipanggil, SEMENTARA animasi keluar
/// masih jalan + subtree masih rebuild — controller yang sudah
/// di-dispose masih dipakai (`_AnimatedState.didUpdateWidget` ->
/// addListener) + Column overflow 99748px saat teardown. Hasilnya
/// 4 test gagal ("used after being disposed"). Di sini dispose jalan
/// saat State di-unmount sesudah animasi keluar selesai — controller
/// tidak pernah dipakai sesudah dispose.
class _CashSheetContent extends StatefulWidget {
  const _CashSheetContent({required this.total, this.subtitle});

  final int total;

  /// Teks pengganti "Total belanja RpX" (null = teks default).
  final String? subtitle;

  @override
  State<_CashSheetContent> createState() => _CashSheetContentState();
}

class _CashSheetContentState extends State<_CashSheetContent> {
  late int received;
  late final TextEditingController controller;

  @override
  void initState() {
    super.initState();
    received = widget.total;
    controller = TextEditingController(text: widget.total.toString());
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void setReceived(int value) {
    setState(() {
      received = value;
      controller.text = value.toString();
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.total;
    final change = computeChange(received, total);
    final amounts = quickCashAmounts(total);
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
          // Drag handle 30x4 (FigCraft frame 11).
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
            'Uang diterima',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
          const SizedBox(height: 4),
          Text(
            widget.subtitle ?? 'Total belanja ${formatRupiah(total)}',
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
                setState(() => received = value);
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
                      : SukaTeaColors.emerald,
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
          TapFeedback(
            enabled: received >= total,
            child: FilledButton(
              // Pop aman (popSheetSafely): TextField nominal manual
              // masih fokus saat tombol ditekan — pop langsung =
              // layar merah '_dependents.isEmpty', sama seperti
              // discount_sheet (23 Nov 2026). Lepas fokus + tunggu
              // satu frame dulu baru pop.
              onPressed: received < total
                  ? null
                  : () => popSheetSafely(context, received),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 56),
              ),
              child: Text(
                'Konfirmasi • ${formatRupiah(received)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
