import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:suka_tea/core/utils/roles.dart';
import 'package:suka_tea/features/qris/qris_pay_page.dart';

/// Kunci nominal QRIS (Sendy 24 Nov 2026):
/// - Mode FULL: nominal QRIS = total keranjang, TIDAK BISA diubah —
///   tidak ada field custom / preset / bulatkan di layar.
/// - Mode SPLIT: bagian QRIS BOLEH custom, tapi HARUS < total dan
///   >= Rp1.000 — preset/ketik yang melanggar ditolak dengan pesan
///   error + tombol Generate nonaktif (dan _generate menjaga juga).
///
/// Halaman dipompa lewat tombol "buka" supaya hasil pop (nominal yang
/// dibayar) bisa ditangkap. Merchant payload belum diatur di test env,
/// jadi masuk mode demo lewat "Lihat contoh tampilan (CONTOH)" — QR
/// demo tetap digenerate dari payload contoh.
///
/// Perhatian: JANGAN pakai pumpAndSettle sesudah Generate QR — timer
/// 1 detik halaman memanggil setState berkala, pumpAndSettle tidak
/// akan selesai. Pakai pump() biasa; timer dibatalkan saat halaman
/// di-pop/di-dispose.
Future<int?> _openAndPay(
  WidgetTester tester, {
  required int total,
  bool splitMode = false,
  required Future<void> Function(WidgetTester tester) actions,
}) async {
  int? result;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await Navigator.of(context).push<int>(
                MaterialPageRoute(
                  builder: (_) => QrisPayPage(
                    total: total,
                    role: AppRole.kasir,
                    splitMode: splitMode,
                  ),
                ),
              );
            },
            child: const Text('buka'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('buka'));
  await tester.pumpAndSettle();
  // Masuk mode demo (payload contoh) supaya kontrol nominal tampil.
  await tester.tap(find.text('Lihat contoh tampilan (CONTOH)'));
  await tester.pump();
  await actions(tester);
  await tester.pump();
  return result;
}

void main() {
  group('Mode FULL — nominal dikunci = total', () {
    testWidgets('tidak ada field custom / preset / bulatkan',
        (tester) async {
      await _openAndPay(
        tester,
        total: 11000,
        actions: (tester) async {
          expect(find.text('Nominal custom (Rp)'), findsNothing);
          expect(find.text('Rp5.000'), findsNothing);
          expect(find.text('Rp10.000'), findsNothing);
          expect(find.text('Rp20.000'), findsNothing);
          expect(find.text('Rp50.000'), findsNothing);
          expect(find.text('Rp100.000'), findsNothing);
          expect(find.text('Total Rp11.000'), findsNothing);
          expect(find.text('Bulatkan Rp11.500'), findsNothing);
          expect(
            find.text(
              'Nominal QRIS = total keranjang — tidak bisa diubah.',
            ),
            findsOneWidget,
          );
          expect(find.text('Rp11.000'), findsOneWidget);
          expect(find.text('Generate QR'), findsOneWidget);
          expect(find.text('Sudah Dibayar'), findsOneWidget);
          expect(find.text('Batal'), findsOneWidget);
        },
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Generate QR lalu Sudah Dibayar mengembalikan total',
        (tester) async {
      final result = await _openAndPay(
        tester,
        total: 11000,
        actions: (tester) async {
          await tester.tap(find.text('Generate QR'));
          await tester.pump();
          expect(find.byType(QrImageView), findsOneWidget);
          // QR menambah ~300px tinggi halaman — tombol konfirmasi di
          // bawah ListView terdorong keluar viewport, dan child
          // ListView di luar viewport BELUM dibangun sliver (finder
          // menemukannya 0). Scroll dulu seperti pengguna asli.
          await tester.drag(find.byType(ListView), const Offset(0, -600));
          await tester.pump();
          await tester.tap(find.text('Sudah Dibayar'));
        },
      );
      expect(result, 11000);
      expect(tester.takeException(), isNull);
    });
  });

  group('Mode SPLIT — bagian QRIS boleh custom tapi < total', () {
    testWidgets('kontrol custom + preset tetap tampil',
        (tester) async {
      await _openAndPay(
        tester,
        total: 11000,
        splitMode: true,
        actions: (tester) async {
          expect(find.text('Nominal custom (Rp)'), findsOneWidget);
          // 'Rp10.000' tidak diassert: nominal awal split total 11000
          // = Rp10.000, jadi teks itu muncul 2x (total besar + chip).
          expect(find.text('Rp5.000'), findsOneWidget);
          expect(
            find.text('Bagian QRIS — sisanya dibayar tunai.'),
            findsOneWidget,
          );
          expect(find.text('Lanjut ke Tunai'), findsOneWidget);
        },
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('preset >= total ditolak: error + Generate tidak jalan',
        (tester) async {
      await _openAndPay(
        tester,
        total: 11000,
        splitMode: true,
        actions: (tester) async {
          // Preset Rp20.000 >= total Rp11.000.
          await tester.tap(find.text('Rp20.000'));
          await tester.pump();
          expect(
            find.text(
              'Bagian QRIS harus kurang dari total — sisanya dibayar tunai.',
            ),
            findsOneWidget,
          );
          // Tombol Generate nonaktif — tap tidak menghasilkan QR.
          await tester.tap(find.text('Generate QR'));
          await tester.pump();
          expect(find.byType(QrImageView), findsNothing);
        },
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('ketik nominal >= total ditolak dengan pesan yang sama',
        (tester) async {
      await _openAndPay(
        tester,
        total: 11000,
        splitMode: true,
        actions: (tester) async {
          await tester.enterText(
            find.byType(TextField),
            '11000',
          );
          await tester.pump();
          expect(
            find.text(
              'Bagian QRIS harus kurang dari total — sisanya dibayar tunai.',
            ),
            findsOneWidget,
          );
          await tester.tap(find.text('Generate QR'));
          await tester.pump();
          expect(find.byType(QrImageView), findsNothing);
        },
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('preset valid (< total) generate + kembali bagian QRIS',
        (tester) async {
      final result = await _openAndPay(
        tester,
        total: 11000,
        splitMode: true,
        actions: (tester) async {
          await tester.tap(find.text('Rp5.000'));
          await tester.pump();
          expect(find.text('Sisa tunai: Rp6.000'), findsOneWidget);
          await tester.tap(find.text('Generate QR'));
          await tester.pump();
          expect(find.byType(QrImageView), findsOneWidget);
          // QR menambah ~300px tinggi halaman — tombol konfirmasi di
          // bawah ListView terdorong keluar viewport, dan child
          // ListView di luar viewport BELUM dibangun sliver (finder
          // menemukannya 0). Scroll dulu seperti pengguna asli.
          await tester.drag(find.byType(ListView), const Offset(0, -600));
          await tester.pump();
          await tester.tap(find.text('Lanjut ke Tunai'));
        },
      );
      expect(result, 5000);
      expect(tester.takeException(), isNull);
    });
  });
}
