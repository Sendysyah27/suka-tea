/// Format rupiah tanpa desimal: 12500 -> "Rp12.500".
String formatRupiah(int amount) {
  final negative = amount < 0;
  final digits = amount.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final fromEnd = digits.length - i;
    buf.write(digits[i]);
    if (fromEnd > 1 && fromEnd % 3 == 1) buf.write('.');
  }
  return '${negative ? '-' : ''}Rp${buf.toString()}';
}
