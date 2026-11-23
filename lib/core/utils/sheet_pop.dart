import 'package:flutter/widgets.dart';

/// Pop sebuah modal bottom sheet dengan AMAN bila di dalamnya ada
/// TextField yang masih fokus + keyboard masih terbuka.
///
/// AKAR BUG (layar merah debug, 23 Nov 2026 16:01 — ketahuan Sendy
/// sesudah ketik nominal diskon lalu tap "Terapkan diskon"):
/// `Navigator.pop` langsung dari onPressed saat TextField masih fokus
/// melempar assertion di framework.dart:
/// `'package:flutter/src/widgets/framework.dart': Failed assertion:
/// line 6281 pos 12: '_dependents.isEmpty': is not true.`
/// Assertion itu ada di `InheritedElement.unmount()`: route sheet
/// di-unmount sementara mesin fokus/keyboard TextField (EditableText)
/// masih terdaftar sebagai dependent MediaQuery internal sheet.
/// Bukti di kode: discount_sheet + cash_sheet dua-duanya pop langsung
/// dari onPressed tanpa unfocus — dan dua-duanya punya TextField.
/// product_options_sheet TIDAK punya TextField dan TIDAK PERNAH crash.
///
/// Perbaikan (pola standar Flutter untuk sheet + keyboard):
/// 1. Lepas fokus dulu (`FocusScope.unfocus`) — keyboard mulai turun,
///    EditableText menutup koneksi input + overlay seleksi.
/// 2. Tunggu satu frame selesai (`endOfFrame`) supaya teardown
///    fokus/keyboard itu benar-benar jalan sebelum route di-pop.
/// 3. Guard `mounted` — sheet bisa saja sudah ditutup (mis. back)
///    selama menunggu frame; jangan pop context yang sudah mati.
/// JANGAN menelan error / try-catch buta — pop yang tidak aman
/// memang harus diperbaiki di urutan aksinya, bukan disembunyikan.
Future<void> popSheetSafely<T>(BuildContext context, [T? result]) async {
  FocusScope.of(context).unfocus();
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted) return;
  Navigator.of(context).pop<T>(result);
}
