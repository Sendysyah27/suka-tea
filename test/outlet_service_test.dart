import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/outlet_service.dart';

/// Outlet (Batch C4) — test pure saja: seed 4 gerai + copyWith.
/// Drift (init / simpan) TIDAK di-test di sini — butuh database lokal,
/// diverifikasi manual di HP.
void main() {
  group('seedOutlets', () {
    test('seed = 4 gerai placeholder, urut 1-4', () {
      final outlets = seedOutlets();
      expect(outlets.length, 4);
      expect(outlets[0].id, '00000000-0000-0000-0000-000000000001');
      expect(outlets[0].name, 'Gerai 1 — Stand Utama');
      expect(outlets[1].id, '00000000-0000-0000-0000-000000000002');
      expect(outlets[1].name, 'Gerai 2');
      expect(outlets[2].id, '00000000-0000-0000-0000-000000000003');
      expect(outlets[3].id, '00000000-0000-0000-0000-000000000004');
      expect(outlets[3].name, 'Gerai 4');
    });

    test('seed: semua buka, alamat placeholder, sortOrder urut', () {
      final outlets = seedOutlets();
      for (var i = 0; i < outlets.length; i++) {
        expect(outlets[i].isOpen, isTrue);
        expect(
          outlets[i].address,
          'Alamat gerai (isi dari Pengaturan)',
        );
        expect(outlets[i].sortOrder, i);
      }
    });

    test('defaultOutletId = Gerai 1', () {
      expect(
        defaultOutletId,
        '00000000-0000-0000-0000-000000000001',
      );
      expect(seedOutlets().first.id, defaultOutletId);
    });
  });

  group('Outlet.copyWith', () {
    test('ubah nama + alamat, sisanya tetap', () {
      const outlet = Outlet(
        id: '00000000-0000-0000-0000-000000000002',
        name: 'Gerai 2',
        address: 'Alamat gerai (isi dari Pengaturan)',
        isOpen: true,
        sortOrder: 1,
      );
      final edited = outlet.copyWith(
        name: 'Gerai 2 — Pasar',
        address: 'Jl. Merdeka No. 10',
      );
      expect(edited.id, outlet.id);
      expect(edited.name, 'Gerai 2 — Pasar');
      expect(edited.address, 'Jl. Merdeka No. 10');
      expect(edited.isOpen, isTrue);
      expect(edited.sortOrder, 1);
    });

    test('tutup gerai via copyWith', () {
      const outlet = Outlet(
        id: 'x',
        name: 'Gerai X',
        address: '',
        isOpen: true,
        sortOrder: 0,
      );
      expect(outlet.copyWith(isOpen: false).isOpen, isFalse);
    });
  });
}
