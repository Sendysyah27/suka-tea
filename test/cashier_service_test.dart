import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/features/kasir/cashier_service.dart';
import 'package:suka_tea/features/pin/pin_service.dart';

/// Parser jawaban Edge Function kasir (Batch C8.2) — level fungsi saja.
/// Jaringan asli TIDAK BISA di-test di CI (butuh Supabase + PIN Owner),
/// jadi yang di-test di sini: bentuk jawaban yang diterima / ditolak
/// parser + validasi nama kasir. Tidak ada PIN/nama asli di tes.
void main() {
  group('parseCashierListResponse', () {
    test('ok + 2 kasir -> daftar lengkap', () {
      final result = parseCashierListResponse({
        'ok': true,
        'cashiers': [
          {'id': 'aaaaaaaa-1111-4111-8111-111111111111', 'name': 'Budi', 'active': true},
          {'id': 'bbbbbbbb-2222-4222-8222-222222222222', 'name': 'Siti', 'active': false},
        ],
      });
      expect(result.ok, isTrue);
      expect(result.cashiers.length, 2);
      expect(result.cashiers[0].name, 'Budi');
      expect(result.cashiers[0].active, isTrue);
      expect(result.cashiers[1].name, 'Siti');
      expect(result.cashiers[1].active, isFalse);
    });

    test('ok + daftar kosong -> (ok:true, kosong)', () {
      final result = parseCashierListResponse({'ok': true, 'cashiers': []});
      expect(result.ok, isTrue);
      expect(result.cashiers, isEmpty);
    });

    test('ok:false -> (ok:false, kosong)', () {
      final result = parseCashierListResponse({
        'ok': false,
        'reason': 'wrong',
      });
      expect(result.ok, isFalse);
      expect(result.cashiers, isEmpty);
    });

    test('bukan Map / cashiers bukan list -> ok:false', () {
      expect(parseCashierListResponse(null).ok, isFalse);
      expect(parseCashierListResponse({'ok': true}).ok, isFalse);
      expect(parseCashierListResponse({'ok': true, 'cashiers': 'Budi'}).ok, isFalse);
    });

    test('entri rusak dilewati, entri bagus tetap masuk', () {
      final result = parseCashierListResponse({
        'ok': true,
        'cashiers': [
          {'id': '', 'name': 'TanpaId'},
          {'id': 'cccccccc-3333-4333-8333-333333333333', 'name': ''},
          {'id': 'dddddddd-4444-4444-8444-444444444444', 'name': 'Bagus', 'active': true},
          'bukan-map',
        ],
      });
      expect(result.ok, isTrue);
      expect(result.cashiers.length, 1);
      expect(result.cashiers.first.name, 'Bagus');
    });
  });

  group('parseVerifyCashierResponse', () {
    test('ok:true + id + nama -> ok', () {
      final result = parseVerifyCashierResponse({
        'ok': true,
        'cashier_id': 'aaaaaaaa-1111-4111-8111-111111111111',
        'name': 'Budi',
      });
      expect(result.result, CashierVerifyResult.ok);
      expect(result.cashierId, 'aaaaaaaa-1111-4111-8111-111111111111');
      expect(result.name, 'Budi');
    });

    test("reason 'wrong' -> wrong", () {
      final result = parseVerifyCashierResponse({
        'ok': false,
        'reason': 'wrong',
      });
      expect(result.result, CashierVerifyResult.wrong);
      expect(result.cashierId, isNull);
    });

    test("reason 'locked' -> locked", () {
      final result = parseVerifyCashierResponse({
        'ok': false,
        'reason': 'locked',
      });
      expect(result.result, CashierVerifyResult.locked);
    });

    test("reason 'not_found' -> notFound", () {
      final result = parseVerifyCashierResponse({
        'ok': false,
        'reason': 'not_found',
      });
      expect(result.result, CashierVerifyResult.notFound);
    });

    test('ok:true tapi id/nama kosong -> unavailable', () {
      final result = parseVerifyCashierResponse({
        'ok': true,
        'cashier_id': '',
        'name': 'Budi',
      });
      expect(result.result, CashierVerifyResult.unavailable);
    });

    test('bukan Map / reason tak dikenal -> unavailable', () {
      expect(
        parseVerifyCashierResponse(null).result,
        CashierVerifyResult.unavailable,
      );
      expect(
        parseVerifyCashierResponse({'ok': false, 'reason': 'aneh'}).result,
        CashierVerifyResult.unavailable,
      );
    });
  });

  group('parseCashierError', () {
    test('error string -> kode itu', () {
      expect(parseCashierError({'ok': false, 'error': 'pin_taken'}), 'pin_taken');
      expect(parseCashierError({'ok': false, 'error': 'name_taken'}), 'name_taken');
    });

    test('tanpa error / bukan string -> null', () {
      expect(parseCashierError({'ok': true}), isNull);
      expect(parseCashierError({'ok': false, 'error': 42}), isNull);
      expect(parseCashierError(null), isNull);
    });
  });

  group('isValidCashierName', () {
    test('nama biasa valid, kosong / terlalu panjang tidak', () {
      expect(isValidCashierName('Budi'), isTrue);
      expect(isValidCashierName('  Budi  '), isTrue);
      expect(isValidCashierName(''), isFalse);
      expect(isValidCashierName('   '), isFalse);
      expect(isValidCashierName('a' * 51), isFalse);
      expect(isValidCashierName('a' * 50), isTrue);
    });
  });

  group('cashierOwnerBody (Batch C10.1 Bug 1 — PIN Owner GLOBAL)', () {
    test('outlet_id SELALU baris global ...0001', () {
      final body = cashierOwnerBody(ownerPin: '123456');
      expect(body['outlet_id'], '00000000-0000-0000-0000-000000000001');
      expect(body['owner_pin'], '123456');
    });

    test('extra digabung, outlet_id tetap global (tidak bisa ditimpa)', () {
      // Keempat metode Owner (list/register/set-pin/set-active)
      // membangun body lewat fungsi ini — gerai yang dipilih
      // (Gerai 2/3/4) TIDAK PERNAH masuk body: builder ini sengaja
      // tidak menerima outlet_id, jadi tidak ada jalan untuk
      // mengirim outlet_id gerai lain (itu akar bug 24 Nov 20:10:
      // EF menjawab not_set di gerai selain Gerai 1).
      final body = cashierOwnerBody(
        ownerPin: '123456',
        extra: {'name': 'Budi', 'pin': '654321'},
      );
      expect(body['outlet_id'], '00000000-0000-0000-0000-000000000001');
      expect(body['name'], 'Budi');
      expect(body['pin'], '654321');
      expect(
        body['outlet_id'],
        PinService.defaultOutletId,
        reason: 'sama dengan konstanta global PinService',
      );
    });
  });
}
