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
///
/// [compact]: keypad kecil untuk layar PIN Kasir (tombol 72px, lebar
/// total 232px, di tengah layar) — keypad besar lama (~110px di HP
/// 360dp, hampir selebar layar) terlalu dominan di halaman login.
/// Default false = ukuran lama, dipakai dialog PIN lama (R-09:
/// KasirPinDialog sudah dihapus — keypad tetap dipakai KasirPinPage).
class PinKeypad extends StatelessWidget {
  const PinKeypad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    this.enabled = true,
    this.compact = false,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final bool enabled;

  /// true = tombol kecil 72px (layar PIN Kasir). false = tombol
  /// selebar kolom (dialog PIN Kasir, seperti sebelumnya).
  final bool compact;

  /// Diameter tombol mode compact — masih jauh di atas target sentuh
  /// minimum 48dp, tapi tidak lagi mendominasi layar (3 x 72 + 2 x 8
  /// = 232px, muat lega di HP 360dp dengan margin kiri-kanan).
  static const double compactKeySize = 72;

  static const double _gap = 8;

  @override
  Widget build(BuildContext context) {
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _keyRow(['1', '2', '3']),
        const SizedBox(height: _gap),
        _keyRow(['4', '5', '6']),
        const SizedBox(height: _gap),
        _keyRow(['7', '8', '9']),
        const SizedBox(height: _gap),
        Row(
          mainAxisAlignment:
              compact ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            // Lingkaran kosong kiri-bawah (FigCraft) — placeholder
            // visual, tanpa aksi.
            _slot(_emptyCircle()),
            const SizedBox(width: _gap),
            _slot(
              _keyButton(
                label: '0',
                labelSize: compact ? 20 : 22,
                onTap: enabled ? () => onDigit('0') : null,
              ),
            ),
            const SizedBox(width: _gap),
            // Tombol hapus bertuliskan "Hapus" (FigCraft) — bukan
            // ikon backspace.
            _slot(
              _keyButton(
                label: 'Hapus',
                labelSize: compact ? 13 : 14,
                onTap: enabled ? onBackspace : null,
              ),
            ),
          ],
        ),
      ],
    );
    if (!compact) return column;
    return Center(
      child: SizedBox(
        width: compactKeySize * 3 + _gap * 2,
        child: column,
      ),
    );
  }

  /// Bungkus tombol: mode compact ukuran tetap, mode normal mengisi
  /// lebar kolom (Expanded + AspectRatio, seperti sebelumnya).
  Widget _slot(Widget child) => compact ? child : Expanded(child: child);

  Widget _keyRow(List<String> digits) {
    return Row(
      mainAxisAlignment:
          compact ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        for (int i = 0; i < digits.length; i++) ...[
          if (i > 0) const SizedBox(width: _gap),
          _slot(
            _keyButton(
              label: digits[i],
              labelSize: compact ? 20 : 22,
              onTap: enabled ? () => onDigit(digits[i]) : null,
            ),
          ),
        ],
      ],
    );
  }

  Widget _emptyCircle() {
    final circle = Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: SukaTeaColors.leafBg,
        border: Border.all(color: SukaTeaColors.border),
      ),
    );
    if (compact) {
      return SizedBox(
        width: compactKeySize,
        height: compactKeySize,
        child: circle,
      );
    }
    return AspectRatio(aspectRatio: 1, child: circle);
  }

  Widget _keyButton({
    String? label,
    double labelSize = 22,
    VoidCallback? onTap,
  }) {
    final button = InkWell(
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
    );
    if (compact) {
      return SizedBox(
        width: compactKeySize,
        height: compactKeySize,
        child: button,
      );
    }
    return AspectRatio(aspectRatio: 1, child: button);
  }
}
