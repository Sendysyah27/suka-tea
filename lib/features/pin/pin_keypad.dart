import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Keypad angka PIN 6 digit (desain v2 / FigCraft frame 09 + 13):
/// titik + tombol bulat, layout Column + Row.
///
/// BUKAN GridView: GridView adalah viewport shrink-wrapping yang
/// tidak bisa diukur dimensi intrinsiknya oleh AlertDialog — dialog
/// crash saat dibuka (CI run 45021550871, flutter test).
/// Dipakai halaman Login + dialog PIN Kasir. (PinEntryDialog masih
/// memakai keypadnya sendiri yang sudah terbukti — jangan diubah.)
class PinKeypad extends StatelessWidget {
  const PinKeypad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    this.enabled = true,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _keyRow(['1', '2', '3']),
        const SizedBox(height: 8),
        _keyRow(['4', '5', '6']),
        const SizedBox(height: 8),
        _keyRow(['7', '8', '9']),
        const SizedBox(height: 8),
        Row(
          children: [
            // Lingkaran kosong kiri-bawah (FigCraft) — placeholder
            // visual, tanpa aksi.
            Expanded(child: _emptyCircle()),
            const SizedBox(width: 8),
            Expanded(
              child: _keyButton(
                label: '0',
                onTap: enabled ? () => onDigit('0') : null,
              ),
            ),
            const SizedBox(width: 8),
            // Tombol hapus bertuliskan "Hapus" (FigCraft) — bukan
            // ikon backspace.
            Expanded(
              child: _keyButton(
                label: 'Hapus',
                labelSize: 14,
                onTap: enabled ? onBackspace : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _keyRow(List<String> digits) {
    return Row(
      children: [
        for (int i = 0; i < digits.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _keyButton(
              label: digits[i],
              onTap: enabled ? () => onDigit(digits[i]) : null,
            ),
          ),
        ],
      ],
    );
  }

  Widget _emptyCircle() {
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: SukaTeaColors.leafBg,
          border: Border.all(color: SukaTeaColors.border),
        ),
      ),
    );
  }

  Widget _keyButton({
    String? label,
    double labelSize = 22,
    VoidCallback? onTap,
  }) {
    return AspectRatio(
      aspectRatio: 1,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: SukaTeaColors.leafBg,
            border: Border.all(color: SukaTeaColors.border),
          ),
          child: Center(
            child: Text(
              label ?? '',
              style: TextStyle(
                fontSize: labelSize,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
