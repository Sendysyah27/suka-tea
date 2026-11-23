import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/core/utils/roles.dart';
import 'package:suka_tea/data/outlet_service.dart';
import 'package:suka_tea/features/login/kasir_pin_page.dart';
import 'package:suka_tea/features/login/login_page.dart';
import 'package:suka_tea/features/login/login_result.dart';

/// Login 2 langkah (redesain 23 Nov 2026 — perintah Sendy: keypad
/// PIN Kasir lama terlalu besar di layar depan).
///
/// Catatan test env: Supabase TIDAK terkonfigurasi di test (init
/// tidak dipanggil, isConfigured false), jadi KasirPinService.isPinSet
/// mengembalikan null -> jalur fail-open teruji. Jalur PIN sudah
/// diatur (isPinSet == true -> layar PIN) butuh Supabase + Edge
/// Function — diverifikasi manual di HP, bukan di sini.
/// OutletService.init() di test jatuh ke seed di memori (Drift gagal
/// dibuka di test env, ditangkap try/catch di init()).
void main() {
  setUpAll(() async {
    await OutletService.instance.init();
  });

  group('Langkah 1 — pilih gerai', () {
    testWidgets('tampil 4 gerai + 2 tombol, TANPA keypad', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: LoginPage(onSuccess: (_) {})),
      );
      await tester.pump();
      expect(find.text('Pilih Gerai'), findsOneWidget);
      expect(find.text('Gerai 1 — Stand Utama'), findsOneWidget);
      expect(find.text('Gerai 2'), findsOneWidget);
      expect(find.text('Gerai 3'), findsOneWidget);
      expect(find.text('Gerai 4'), findsOneWidget);
      expect(find.text('Masuk sebagai Kasir'), findsOneWidget);
      expect(find.text('Masuk sebagai Owner'), findsOneWidget);
      // Keypad TIDAK ada di layar ini: tidak ada tombol Hapus,
      // tidak ada label PIN Kasir.
      expect(find.text('Hapus'), findsNothing);
      expect(find.text('PIN Kasir'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'tap Masuk sebagai Kasir tanpa Supabase = langsung masuk (fail-open)',
        (tester) async {
      LoginResult? got;
      await tester.pumpWidget(
        MaterialApp(home: LoginPage(onSuccess: (r) => got = r)),
      );
      await tester.pump();
      await tester.tap(find.text('Masuk sebagai Kasir'));
      await tester.pumpAndSettle();
      expect(got, isNotNull);
      expect(got!.role, AppRole.kasir);
      expect(got!.outletId, defaultOutletId);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pilih Gerai 3 lalu masuk = outlet Gerai 3', (tester) async {
      LoginResult? got;
      await tester.pumpWidget(
        MaterialApp(home: LoginPage(onSuccess: (r) => got = r)),
      );
      await tester.pump();
      await tester.tap(find.text('Gerai 3'));
      await tester.pump();
      await tester.tap(find.text('Masuk sebagai Kasir'));
      await tester.pumpAndSettle();
      expect(got, isNotNull);
      expect(got!.outletId, '00000000-0000-0000-0000-000000000003');
      expect(got!.role, AppRole.kasir);
      expect(tester.takeException(), isNull);
    });
  });

  group('Langkah 2 — layar PIN Kasir', () {
    const outlet = Outlet(
      id: '00000000-0000-0000-0000-000000000002',
      name: 'Gerai 2',
      address: 'Alamat gerai (isi dari Pengaturan)',
      sortOrder: 1,
    );

    testWidgets('tampil nama gerai + dot + keypad + tombol kembali',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KasirPinPage(
              outlet: outlet,
              onBack: () {},
              onSuccess: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Gerai 2'), findsOneWidget);
      expect(find.text('PIN Kasir'), findsOneWidget);
      expect(find.text('Hapus'), findsOneWidget);
      expect(find.text('Pilih gerai'), findsOneWidget);
      expect(find.text('Masuk sebagai Kasir'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tombol masuk nonaktif sebelum 6 digit', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KasirPinPage(
              outlet: outlet,
              onBack: () {},
              onSuccess: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Masuk sebagai Kasir'),
      );
      expect(button.onPressed, isNull);
      // Ketik 3 digit — tombol tetap nonaktif.
      for (final d in ['1', '2', '3']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      final stillDisabled = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Masuk sebagai Kasir'),
      );
      expect(stillDisabled.onPressed, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'ketik 6 digit lalu masuk = sukses (unavailable -> fail-open)',
        (tester) async {
      LoginResult? got;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KasirPinPage(
              outlet: outlet,
              onBack: () {},
              onSuccess: (r) => got = r,
            ),
          ),
        ),
      );
      await tester.pump();
      for (final d in ['1', '2', '3', '4', '5', '6']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Masuk sebagai Kasir'),
      );
      expect(button.onPressed, isNotNull);
      await tester.tap(find.text('Masuk sebagai Kasir'));
      await tester.pumpAndSettle();
      expect(got, isNotNull);
      expect(got!.role, AppRole.kasir);
      expect(got!.outletId, '00000000-0000-0000-0000-000000000002');
      expect(tester.takeException(), isNull);
    });

    testWidgets('tombol kembali memanggil onBack', (tester) async {
      var backCalled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KasirPinPage(
              outlet: outlet,
              onBack: () => backCalled = true,
              onSuccess: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Pilih gerai'));
      await tester.pump();
      expect(backCalled, isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}
