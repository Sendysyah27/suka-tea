import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/sync_payload.dart';

/// Logika shift antar device (Batch C8.2 WS6) — MURNI, tanpa
/// Supabase/Drift: dedupe shift (yang opened_at paling awal menang),
/// adopsi shift server, parse jawaban pull + expected server.
/// Dipakai CashShiftService.applyPulledShifts + adoptServerShift +
/// SyncService.fetchShiftExpected.
void main() {
  ShiftSummary shift({
    required String uuid,
    required String openedAt,
    String cashierName = 'Budi',
    String cashierId = '',
    int openingFloat = 50000,
  }) =>
      (
        clientUuid: uuid,
        outletId: '00000000-0000-0000-0000-000000000001',
        cashierId: cashierId,
        cashierName: cashierName,
        openedAt: DateTime.parse(openedAt),
        openingFloat: openingFloat,
        status: 'open',
        closedAt: null,
        closedByCashierId: '',
        closedByCashierName: '',
        countedCash: null,
        expectedCash: null,
        difference: null,
      );

  group('parseShiftSummaries', () {
    test('daftar valid -> ringkasan lengkap', () {
      final list = parseShiftSummaries([
        {
          'client_uuid': 'aaaaaaaa-0000-4000-8000-000000000001',
          'outlet_id': '00000000-0000-0000-0000-000000000001',
          'cashier_id': 'bbbbbbbb-0000-4000-8000-000000000002',
          'cashier_name': 'Budi',
          'opened_at': '2026-11-24T07:00:00.000Z',
          'opening_float': 50000,
          'status': 'open',
        },
      ]);
      expect(list.length, 1);
      expect(list.first.cashierName, 'Budi');
      expect(list.first.cashierId, 'bbbbbbbb-0000-4000-8000-000000000002');
      expect(list.first.openingFloat, 50000);
      expect(list.first.status, 'open');
    });

    test('entri rusak dilewati, yang bagus tetap masuk', () {
      final list = parseShiftSummaries([
        {'client_uuid': '', 'opened_at': '2026-11-24T07:00:00.000Z'},
        {'client_uuid': 'aaaaaaaa-0000-4000-8000-000000000001', 'opened_at': 'bukan-tanggal'},
        {
          'client_uuid': 'cccccccc-0000-4000-8000-000000000003',
          'opened_at': '2026-11-24T07:00:00.000Z',
          'cashier_name': 'Siti',
        },
        'bukan-map',
      ]);
      expect(list.length, 1);
      expect(list.first.cashierName, 'Siti');
    });

    test('bukan list -> kosong', () {
      expect(parseShiftSummaries(null), isEmpty);
      expect(parseShiftSummaries('x'), isEmpty);
      expect(parseShiftSummaries([]), isEmpty);
    });
  });

  group('resolveShiftWinner', () {
    test('opened_at paling awal menang', () {
      final early = shift(
        uuid: 'aaaaaaaa-0000-4000-8000-000000000001',
        openedAt: '2026-11-24T07:00:00.000Z',
      );
      final late = shift(
        uuid: 'bbbbbbbb-0000-4000-8000-000000000002',
        openedAt: '2026-11-24T07:05:00.000Z',
      );
      expect(resolveShiftWinner(early, late), early);
      expect(resolveShiftWinner(late, early), early);
    });

    test('seri opened_at -> client_uuid paling kecil menang', () {
      final a = shift(
        uuid: 'aaaaaaaa-0000-4000-8000-000000000001',
        openedAt: '2026-11-24T07:00:00.000Z',
      );
      final b = shift(
        uuid: 'bbbbbbbb-0000-4000-8000-000000000002',
        openedAt: '2026-11-24T07:00:00.000Z',
      );
      expect(resolveShiftWinner(a, b), a);
      expect(resolveShiftWinner(b, a), a);
    });
  });

  group('pickAdoptedShift', () {
    final serverEarly = shift(
      uuid: 'aaaaaaaa-0000-4000-8000-000000000001',
      openedAt: '2026-11-24T07:00:00.000Z',
      cashierName: 'Budi',
    );
    final serverLate = shift(
      uuid: 'bbbbbbbb-0000-4000-8000-000000000002',
      openedAt: '2026-11-24T07:05:00.000Z',
      cashierName: 'Siti',
    );

    test('tidak ada shift server -> null', () {
      expect(
        pickAdoptedShift(serverOpens: []),
        isNull,
      );
    });

    test('tidak ada shift lokal -> adopsi pemenang server (paling awal)', () {
      expect(
        pickAdoptedShift(serverOpens: [serverLate, serverEarly]),
        serverEarly,
      );
    });

    test('shift lokal == shift server -> null (tidak perlu adopsi)', () {
      expect(
        pickAdoptedShift(
          localOpen: serverEarly,
          serverOpens: [serverEarly],
        ),
        isNull,
      );
    });

    test('event buka lokal masih pending -> null (jangan buang dulu)', () {
      final localLate = shift(
        uuid: 'cccccccc-0000-4000-8000-000000000003',
        openedAt: '2026-11-24T07:05:00.000Z',
      );
      expect(
        pickAdoptedShift(
          localOpen: localLate,
          localPending: true,
          serverOpens: [serverEarly],
        ),
        isNull,
      );
    });

    test('lokal sudah terkirim + server lebih awal -> adopsi server', () {
      final localLate = shift(
        uuid: 'cccccccc-0000-4000-8000-000000000003',
        openedAt: '2026-11-24T07:05:00.000Z',
      );
      expect(
        pickAdoptedShift(
          localOpen: localLate,
          localPending: false,
          serverOpens: [serverEarly],
        ),
        serverEarly,
      );
    });

    test('lokal sudah terkirim + lokal lebih awal -> null', () {
      final localEarly = shift(
        uuid: 'cccccccc-0000-4000-8000-000000000003',
        openedAt: '2026-11-24T06:55:00.000Z',
      );
      expect(
        pickAdoptedShift(
          localOpen: localEarly,
          localPending: false,
          serverOpens: [serverEarly],
        ),
        isNull,
      );
    });
  });

  group('parseShiftExpectedResponse', () {
    test('valid -> (cashIn, cashOut)', () {
      final result = parseShiftExpectedResponse({
        'ok': true,
        'cash_in': 125000,
        'cash_out': 20000,
      });
      expect(result, isNotNull);
      expect(result!.cashIn, 125000);
      expect(result.cashOut, 20000);
    });

    test('ok:false / angka hilang -> null', () {
      expect(
        parseShiftExpectedResponse({'ok': false, 'error': 'x'}),
        isNull,
      );
      expect(
        parseShiftExpectedResponse({'ok': true, 'cash_in': 100}),
        isNull,
      );
      expect(parseShiftExpectedResponse(null), isNull);
    });
  });

  group('applyPushResults + shift_adoptions', () {
    test('event shift kena dedupe -> tetap terkirim + adopsi terparse', () {
      final events = [
        {'outbox_id': 'ob-shift', 'client_uuid': 'u-shift'},
      ];
      final r = applyPushResults(events, {
        'ok': true,
        'results': [
          {'outbox_id': 'ob-shift', 'ok': true},
        ],
        'shift_adoptions': [
          {
            'outbox_id': 'ob-shift',
            'existing_client_uuid': 'aaaaaaaa-0000-4000-8000-000000000001',
            'existing_opened_at': '2026-11-24T07:00:00.000Z',
            'existing_cashier_name': 'Budi',
            'existing_cashier_id': 'bbbbbbbb-0000-4000-8000-000000000002',
            'existing_opening_float': 50000,
          },
        ],
      });
      expect(r.sentIds, ['ob-shift']);
      expect(r.failedIds, isEmpty);
      expect(r.shiftAdoptions.length, 1);
      expect(
        r.shiftAdoptions.first.existingClientUuid,
        'aaaaaaaa-0000-4000-8000-000000000001',
      );
      expect(r.shiftAdoptions.first.existingCashierName, 'Budi');
      expect(r.shiftAdoptions.first.existingOpeningFloat, 50000);
    });

    test('tanpa shift_adoptions -> list kosong', () {
      final events = [
        {'outbox_id': 'ob-1', 'client_uuid': 'u1'},
      ];
      final r = applyPushResults(events, {
        'ok': true,
        'results': [
          {'outbox_id': 'ob-1', 'ok': true},
        ],
      });
      expect(r.shiftAdoptions, isEmpty);
    });
  });

  group('parsePullResponse + stok/shift', () {
    test('pull lengkap -> stok + shift ikut terparse', () {
      final parsed = parsePullResponse({
        'ok': true,
        'transactions': [],
        'items': [],
        'stock': [
          {
            'name': 'Teh',
            'unit': 'gram',
            'qty': 800,
            'low_threshold': 100,
            'cost_per_unit': 50,
          },
        ],
        'shifts': [
          {
            'client_uuid': 'aaaaaaaa-0000-4000-8000-000000000001',
            'outlet_id': '00000000-0000-0000-0000-000000000001',
            'cashier_name': 'Budi',
            'opened_at': '2026-11-24T07:00:00.000Z',
            'opening_float': 50000,
            'status': 'open',
          },
        ],
      });
      expect(parsed.stock.length, 1);
      expect(parsed.stock.first['name'], 'Teh');
      expect(parsed.shifts.length, 1);
      expect(parsed.shifts.first.cashierName, 'Budi');
    });

    test('pull lama tanpa stock/shifts -> list kosong, bukan error', () {
      final parsed = parsePullResponse({
        'ok': true,
        'transactions': [],
        'items': [],
      });
      expect(parsed.stock, isEmpty);
      expect(parsed.shifts, isEmpty);
    });
  });

  group('normalizer kasir (WS4/WS6)', () {
    test('normalizeSaleEvent membawa cashier_id + cashier_name', () {
      final event = normalizeSaleEvent(
        outboxId: 'ob-1',
        rawPayload: {
          'client_uuid': 'aaaaaaaa-0000-4000-8000-000000000001',
          'payment_method': 'tunai',
          'total': 5000,
          'items': [
            {'name': 'Es Teh Susu', 'qty': 1, 'price': 5000},
          ],
          'cashier_id': 'bbbbbbbb-0000-4000-8000-000000000002',
          'cashier_name': 'Budi',
        },
        entryCreatedAt: DateTime.parse('2026-11-24T07:00:00.000Z'),
        fallbackOutletId: '00000000-0000-0000-0000-000000000001',
      );
      final payload = event['payload'] as Map<String, dynamic>;
      expect(payload['cashier_id'], 'bbbbbbbb-0000-4000-8000-000000000002');
      expect(payload['cashier_name'], 'Budi');
    });

    test('normalizeSaleEvent tanpa kasir -> string kosong', () {
      final event = normalizeSaleEvent(
        outboxId: 'ob-1',
        rawPayload: {
          'client_uuid': 'aaaaaaaa-0000-4000-8000-000000000001',
          'payment_method': 'tunai',
          'total': 5000,
          'items': [
            {'name': 'Es Teh Susu', 'qty': 1, 'price': 5000},
          ],
        },
        entryCreatedAt: DateTime.parse('2026-11-24T07:00:00.000Z'),
        fallbackOutletId: '00000000-0000-0000-0000-000000000001',
      );
      final payload = event['payload'] as Map<String, dynamic>;
      expect(payload['cashier_id'], '');
      expect(payload['cashier_name'], '');
    });

    test('normalizeShiftEvent membawa pembuka + penutup', () {
      final event = normalizeShiftEvent(
        outboxId: 'ob-1',
        rawPayload: {
          'client_uuid': 'aaaaaaaa-0000-4000-8000-000000000001',
          'outlet_id': '00000000-0000-0000-0000-000000000001',
          'cashier_id': 'bbbbbbbb-0000-4000-8000-000000000002',
          'cashier_name': 'Budi',
          'closed_by_cashier_id': 'cccccccc-0000-4000-8000-000000000003',
          'closed_by_cashier_name': 'Siti',
          'opened_at': '2026-11-24T07:00:00.000Z',
          'opening_float': 50000,
          'closed_at': '2026-11-24T12:00:00.000Z',
          'counted_cash': 150000,
          'expected_cash': 150000,
          'difference': 0,
          'status': 'closed',
        },
        entryCreatedAt: DateTime.parse('2026-11-24T07:00:00.000Z'),
        fallbackOutletId: '00000000-0000-0000-0000-000000000001',
      );
      final payload = event['payload'] as Map<String, dynamic>;
      expect(payload['cashier_id'], 'bbbbbbbb-0000-4000-8000-000000000002');
      expect(payload['cashier_name'], 'Budi');
      expect(
        payload['closed_by_cashier_id'],
        'cccccccc-0000-4000-8000-000000000003',
      );
      expect(payload['closed_by_cashier_name'], 'Siti');
    });
  });
}
