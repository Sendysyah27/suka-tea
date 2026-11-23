import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/discount.dart';
import '../../core/utils/money.dart';
import '../../core/utils/sheet_pop.dart';
import '../../core/widgets/tap_feedback.dart';

/// Hasil sheet diskon: nominal rupiah yang diterapkan + persennya
/// (0 = mode rupiah / tanpa diskon). Persen hanya untuk TAMPILAN
/// "(N%)" di keranjang + struk — yang disimpan di riwayat tetap
/// nominal rupiah (SaleHistory.discount, tanpa perubahan skema DB).
typedef DiscountResult = ({int amount, int percent});

enum _DiscountMode { rupiah, percent }

/// Sheet "Diskon manual" di keranjang Kasir: dua mode — Rupiah (Rp)
/// dan Persen (%). Mode persen: input bilangan bulat 0..100; nominal
/// = subtotal * persen ~/ 100 (pembulatan ke bawah — lihat
/// percentToAmount di lib/core/utils/discount.dart); tetap cap di
/// subtotal (100% = tepat subtotal). Mengembalikan [DiscountResult]
/// atau null bila batal. Diskon boleh dipakai Kasir maupun Owner —
/// tercatat di riwayat (SaleHistory.discount) supaya bisa diaudit.
///
/// Tombol konfirmasi TIDAK pop langsung: pop jalan lewat
/// [popSheetSafely] — unfocus TextField + tunggu satu frame dulu.
/// Pop langsung saat TextField masih fokus = layar merah debug
/// (assertion '_dependents.isEmpty', 23 Nov 2026 16:01).
Future<DiscountResult?> showDiscountSheet(
  BuildContext context, {
  required int subtotal,
  required int currentDiscount,
  int currentPercent = 0,
}) async {
  return showModalBottomSheet<DiscountResult>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _DiscountSheetContent(
      subtotal: subtotal,
      currentDiscount: currentDiscount,
      currentPercent: currentPercent,
    ),
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
class _DiscountSheetContent extends StatefulWidget {
  const _DiscountSheetContent({
    required this.subtotal,
    required this.currentDiscount,
    this.currentPercent = 0,
  });

  final int subtotal;
  final int currentDiscount;
  final int currentPercent;

  @override
  State<_DiscountSheetContent> createState() => _DiscountSheetContentState();
}

class _DiscountSheetContentState extends State<_DiscountSheetContent> {
  late _DiscountMode mode;
  late int amount;
  late int percent;
  late final TextEditingController controller;

  @override
  void initState() {
    super.initState();
    mode = widget.currentPercent > 0
        ? _DiscountMode.percent
        : _DiscountMode.rupiah;
    amount = clampDiscount(widget.currentDiscount, widget.subtotal);
    percent = clampPercent(widget.currentPercent);
    controller = TextEditingController(
      text: mode == _DiscountMode.percent
          ? percent.toString()
          : amount.toString(),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void switchMode(_DiscountMode next) {
    if (next == mode) return;
    setState(() {
      mode = next;
      if (mode == _DiscountMode.percent) {
        // Rp -> %: persen dibulatkan ke bawah dari nominal lama.
        percent = widget.subtotal == 0
            ? 0
            : amount * 100 ~/ widget.subtotal;
        controller.text = percent.toString();
      } else {
        // % -> Rp: nominal dari persen saat ini.
        amount = percentToAmount(widget.subtotal, percent);
        controller.text = amount.toString();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final subtotal = widget.subtotal;
    // Nominal efektif: mode persen dihitung dari subtotal
    // (percentToAmount sudah menjepit 0..100 + membulatkan ke bawah).
    final effectiveAmount = mode == _DiscountMode.percent
        ? percentToAmount(subtotal, percent)
        : amount;
    final shownPercent = clampPercent(percent);
    final overLimit = effectiveAmount > subtotal;
    final payable = payableAfterDiscount(subtotal, effectiveAmount);

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
          SegmentedButton<_DiscountMode>(
            segments: const [
              ButtonSegment<_DiscountMode>(
                value: _DiscountMode.rupiah,
                label: Text('Rupiah (Rp)'),
              ),
              ButtonSegment<_DiscountMode>(
                value: _DiscountMode.percent,
                label: Text('Persen (%)'),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (selected) =>
                switchMode(selected.first),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: mode == _DiscountMode.percent
                  ? 'Persen diskon (%)'
                  : 'Nominal diskon (Rp)',
              hintText:
                  mode == _DiscountMode.percent ? '0–100' : null,
            ),
            onChanged: (text) {
              final value = int.tryParse(text);
              if (value == null) return;
              setState(() {
                if (mode == _DiscountMode.percent) {
                  percent = value;
                } else {
                  amount = value;
                }
              });
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
          if (mode == _DiscountMode.percent && percent > 0) ...[
            const SizedBox(height: 4),
            Text(
              percent > 100
                  ? 'Maksimal 100% — diskon dihitung 100% '
                      '(${formatRupiah(effectiveAmount)}).'
                  : '$shownPercent% dari subtotal = '
                      '-${formatRupiah(effectiveAmount)}.',
              style: const TextStyle(color: SukaTeaColors.muted),
            ),
          ],
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
                  : () => popSheetSafely(
                        context,
                        (
                          amount: clampDiscount(
                            effectiveAmount,
                            subtotal,
                          ),
                          percent: mode == _DiscountMode.percent
                              ? shownPercent
                              : 0,
                        ),
                      ),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 56),
              ),
              child: Text(
                effectiveAmount > 0
                    ? 'Terapkan diskon • -${formatRupiah(effectiveAmount)}'
                        '${mode == _DiscountMode.percent ? ' ($shownPercent%)' : ''}'
                    : 'Hapus diskon',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
