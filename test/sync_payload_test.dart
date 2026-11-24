import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/sync_payload.dart';

const _uuidRe = r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';

Map<String, dynamic> _salePayload({
  String method = 'tunai',
  int total = 21000,
  int discount = 2000,
  int paid = 25000,
  int change = 4000,
  List<Map<String, dynamic>>? items,
}) =>
    {
      'client_uuid': '11111111-2222-4333-8444-555555555555',
      'outlet_id': '00000000-0000-0000-0000-000000000002',
      'payment_method': method,
      'total': total,
      'discount': discount,
      'paid': paid,
      'change': change,
      'qris_amount': 0,
      'cash_amount': 0,
      'is_void': false,
      'created_at': '2026-11-24T10:00:00.000',
      'items': items ??
          [
            {
              'name': 'Es Teh Jumbo Reguler',
              'qty': 2,
              'price': 3000,
              'modifiers': ['Normal', 'Es Normal'],
            },
            {
              'name': 'Taro Milktea Jumbo',
              'qty': 1,
              'price': 10000,
              'modifiers': ['Normal', 'Es Normal', 'Boba'],
            },
          ],
    };

void main() {
  group('newClientUuid', () {
    test('format UUID v4', () {
      expect(RegExp(_uuidRe).hasMatch(newClientUuid()), isTrue);
    });

    test('unik tiap panggil', () {
      expect(newClientUuid() == newClientUuid(), isFalse);
    });
  });

  group('dateOnly', () {
    test('format YYYY-MM-DD + pad 0', () {
      expect(dateOnly(DateTime(2026, 1, 5)), '2026-01-05');
      expect(dateOnly(DateTime(2026, 11, 24)), '2026-11-24');
    });
  });

  group('normalizeSaleEvent', () {
    test('payload lengkap diteruskan utuh', () {
      final e = normalizeSaleEvent(
        outboxId: 'ob-1',
        rawPayload: _salePayload(),
        entryCreatedAt: DateTime(2026, 11, 24, 10, 0),
        fallbackOutletId: '00000000-0000-0000-0000-000000000001',
      );
      expect(e['outbox_id'], 'ob-1');
      expect(e['kind'], 'transaction');
      expect(e['client_uuid'], '11111111-2222-4333-8444-555555555555');
      expect(e['outlet_id'], '00000000-0000-0000-0000-000000000002');
      final p = e['payload'] as Map<String, dynamic>;
      expect(p['payment_method'], 'tunai');
      expect(p['total'], 21000);
      expect(p['discount'], 2000);
      expect(p['paid'], 25000);
      expect(p['change'], 4000);
      expect(p['is_void'], isFalse);
      final items = p['items'] as List;
      expect(items.length, 2);
      expect((items[1] as Map)['modifiers'], ['Normal', 'Es Normal', 'Boba']);
    });

    test('payload LAMA (sebelum C6) dapat default yang benar', () {
      // Bentuk persis yang ditulis _selesaikanBayar sebelum C6:
      // tanpa outlet_id / paid / change / created_at / is_void.
      final e = normalizeSaleEvent(
        outboxId: 'ob-lama',
        rawPayload: {
          'client_uuid': '1700000000000000',
          'payment_method': 'split',
          'total': 14000,
          'discount': 0,
          'qris_amount': 10000,
          'cash_amount': 4000,
          'items': [
            {'name': 'Es Teh Susu Reguler', 'qty': 2, 'price': 5000},
          ],
        },
        entryCreatedAt: DateTime(2026, 11, 23, 21, 0),
        fallbackOutletId: '00000000-0000-0000-0000-000000000001',
      );
      expect(e['outlet_id'], '00000000-0000-0000-0000-000000000001');
      // Batch C9: created_at fallback (entryCreatedAt, waktu lokal)
      // kini dikirim UTC (...Z) — sebelumnya tanpa offset sehingga
      // server menyimpan jam WIB sebagai +00 (tampil +7 jam).
      expect(
        e['created_at'],
        DateTime(2026, 11, 23, 21, 0).toUtc().toIso8601String(),
      );
      final p = e['payload'] as Map<String, dynamic>;
      expect(p['paid'], 14000);
      expect(p['change'], 0);
      expect(p['is_void'], isFalse);
      expect(p['qris_amount'], 10000);
      expect(p['cash_amount'], 4000);
    });

    test('split + qris lolos allowlist', () {
      for (final m in ['qris', 'split', 'qris_manual', 'transfer', 'ewallet']) {
        final e = normalizeSaleEvent(
          outboxId: 'ob-$m',
          rawPayload: _salePayload(method: m),
          entryCreatedAt: DateTime(2026, 11, 24),
          fallbackOutletId: '00000000-0000-0000-0000-000000000001',
        );
        expect((e['payload'] as Map)['payment_method'], m);
      }
    });

    test('cara bayar tak dikenal -> throw', () {
      expect(
        () => normalizeSaleEvent(
          outboxId: 'ob-x',
          rawPayload: _salePayload(method: 'ngaco'),
          entryCreatedAt: DateTime(2026, 11, 24),
          fallbackOutletId: '00000000-0000-0000-0000-000000000001',
        ),
        throwsArgumentError,
      );
    });

    test('items kosong -> throw', () {
      expect(
        () => normalizeSaleEvent(
          outboxId: 'ob-x',
          rawPayload: _salePayload(items: []),
          entryCreatedAt: DateTime(2026, 11, 24),
          fallbackOutletId: '00000000-0000-0000-0000-000000000001',
        ),
        throwsFormatException,
      );
    });

    test('total negatif -> throw', () {
      expect(
        () => normalizeSaleEvent(
          outboxId: 'ob-x',
          rawPayload: _salePayload(total: -100),
          entryCreatedAt: DateTime(2026, 11, 24),
          fallbackOutletId: '00000000-0000-0000-0000-000000000001',
        ),
        throwsArgumentError,
      );
    });

    test('qty 0 -> throw', () {
      expect(
        () => normalizeSaleEvent(
          outboxId: 'ob-x',
          rawPayload: _salePayload(
            items: [
              {'name': 'Es Teh Jumbo Reguler', 'qty': 0, 'price': 3000},
            ],
          ),
          entryCreatedAt: DateTime(2026, 11, 24),
          fallbackOutletId: '00000000-0000-0000-0000-000000000001',
        ),
        throwsFormatException,
      );
    });

    test('client_uuid kosong -> throw', () {
      final bad = _salePayload()..['client_uuid'] = '';
      expect(
        () => normalizeSaleEvent(
          outboxId: 'ob-x',
          rawPayload: bad,
          entryCreatedAt: DateTime(2026, 11, 24),
          fallbackOutletId: '00000000-0000-0000-0000-000000000001',
        ),
        throwsFormatException,
      );
    });
  });

  group('isLegacyStockPayload', () {
    test('deductions lama -> true', () {
      expect(
        isLegacyStockPayload({
          'client_uuid': 'x',
          'reason': 'penjualan',
          'deductions': {'Teh': 20.0},
        }),
        isTrue,
      );
    });

    test('additions lama -> true', () {
      expect(
        isLegacyStockPayload({
          'client_uuid': 'x',
          'reason': 'void',
          'additions': {'Teh': 20.0},
        }),
        isTrue,
      );
    });

    test('bentuk baru (ada items) -> false', () {
      expect(
        isLegacyStockPayload({
          'client_uuid': 'x',
          'reason': 'penjualan',
          'items': [
            {'name': 'Teh', 'qty_after': 480.0, 'delta': -20.0},
          ],
        }),
        isFalse,
      );
    });
  });

  group('normalizeStockEvent', () {
    Map<String, dynamic> stockPayload() => {
          'client_uuid': '22222222-3333-4444-8555-666666666666',
          'outlet_id': '00000000-0000-0000-0000-000000000001',
          'reason': 'penjualan',
          'transaction_client_uuid': '11111111-2222-4333-8444-555555555555',
          'items': [
            {
              'name': 'Teh',
              'unit': 'gram',
              'qty_after': 480.0,
              'low_threshold': 100.0,
              'cost_per_unit': 50,
              'delta': -20.0,
            },
          ],
        };

    test('payload lengkap diteruskan utuh', () {
      final e = normalizeStockEvent(
        outboxId: 'ob-s1',
        rawPayload: stockPayload(),
        entryCreatedAt: DateTime(2026, 11, 24, 10, 0),
        fallbackOutletId: '00000000-0000-0000-0000-000000000001',
      );
      expect(e['kind'], 'stock_movement');
      final p = e['payload'] as Map<String, dynamic>;
      expect(p['reason'], 'penjualan');
      expect(p['transaction_client_uuid'],
          '11111111-2222-4333-8444-555555555555');
      final item = (p['items'] as List).first as Map<String, dynamic>;
      expect(item['name'], 'Teh');
      expect(item['qty_after'], 480.0);
      expect(item['delta'], -20.0);
    });

    test('payload LAMA (deductions/additions) tidak cocok -> throw', () {
      // Bentuk lama sebelum C6 (hanya deductions map) tidak punya
      // 'items' — flush harus melewatinya, bukan crash.
      expect(
        () => normalizeStockEvent(
          outboxId: 'ob-lama',
          rawPayload: {
            'client_uuid': '1700000000000000',
            'reason': 'penjualan',
            'deductions': {'Teh': 20.0},
          },
          entryCreatedAt: DateTime(2026, 11, 23),
          fallbackOutletId: '00000000-0000-0000-0000-000000000001',
        ),
        throwsFormatException,
      );
    });

    test('reason selain penjualan/void -> penjualan', () {
      final raw = stockPayload()..['reason'] = 'ngaco';
      final e = normalizeStockEvent(
        outboxId: 'ob-s2',
        rawPayload: raw,
        entryCreatedAt: DateTime(2026, 11, 24),
        fallbackOutletId: '00000000-0000-0000-0000-000000000001',
      );
      expect((e['payload'] as Map)['reason'], 'penjualan');
    });

    test('items kosong -> throw', () {
      final raw = stockPayload()..['items'] = [];
      expect(
        () => normalizeStockEvent(
          outboxId: 'ob-s3',
          rawPayload: raw,
          entryCreatedAt: DateTime(2026, 11, 24),
          fallbackOutletId: '00000000-0000-0000-0000-000000000001',
        ),
        throwsFormatException,
      );
    });
  });

  group('parsePullResponse', () {
    test('valid: transaksi + item dikelompokkan per client_uuid', () {
      final parsed = parsePullResponse({
        'ok': true,
        'outlet_id': '00000000-0000-0000-0000-000000000001',
        'from': '2026-11-24',
        'to': '2026-11-24',
        'transactions': [
          {
            'client_uuid': 'aaaaaaaa-0000-4000-8000-000000000001',
            'created_at': '2026-11-24T03:00:00+00:00',
            'payment_method': 'split',
            'total': 14000,
            'status': 'completed',
          },
        ],
        'items': [
          {
            'transaction_client_uuid': 'aaaaaaaa-0000-4000-8000-000000000001',
            'name_snapshot': 'Es Teh Susu Reguler',
            'qty': 2,
            'unit_price': 5000,
            'modifiers_json': ['Normal'],
          },
          {
            'transaction_client_uuid': 'aaaaaaaa-0000-4000-8000-000000000001',
            'name_snapshot': 'Es Teh Jumbo Reguler',
            'qty': 1,
            'unit_price': 3000,
            'modifiers_json': [],
          },
        ],
      });
      expect(parsed.transactions.length, 1);
      final items = parsed
          .itemsByClientUuid['aaaaaaaa-0000-4000-8000-000000000001'];
      expect(items?.length, 2);
      expect(items?[0]['name_snapshot'], 'Es Teh Susu Reguler');
    });

    test('ok:false + error -> throw dengan pesan error', () {
      expect(
        () => parsePullResponse(
            {'ok': false, 'error': 'outlet_id tidak dikenal'}),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('tidak dikenal')),
        ),
      );
    });

    test('bukan Map -> throw', () {
      expect(() => parsePullResponse(null), throwsFormatException);
      expect(() => parsePullResponse('ok'), throwsFormatException);
    });

    test('transactions bukan list -> throw', () {
      expect(
        () => parsePullResponse({'ok': true, 'transactions': {}, 'items': []}),
        throwsFormatException,
      );
    });

    test('item tanpa client_uuid dilewati (tidak crash)', () {
      final parsed = parsePullResponse({
        'ok': true,
        'transactions': [],
        'items': [
          {'name_snapshot': 'X', 'qty': 1},
        ],
      });
      expect(parsed.itemsByClientUuid.isEmpty, isTrue);
    });
  });

  group('applyPushResults', () {
    final events = [
      {'outbox_id': 'ob-1', 'client_uuid': 'u1'},
      {'outbox_id': 'ob-2', 'client_uuid': 'u2'},
    ];

    test('semua ok -> semua terkirim', () {
      final r = applyPushResults(events, {
        'ok': true,
        'results': [
          {'outbox_id': 'ob-1', 'ok': true},
          {'outbox_id': 'ob-2', 'ok': true},
        ],
      });
      expect(r.sentIds, ['ob-1', 'ob-2']);
      expect(r.failedIds, isEmpty);
    });

    test('parsial: hanya yang ok terkirim', () {
      final r = applyPushResults(events, {
        'ok': true,
        'results': [
          {'outbox_id': 'ob-1', 'ok': true},
          {'outbox_id': 'ob-2', 'ok': false, 'error': 'outlet tidak dikenal'},
        ],
      });
      expect(r.sentIds, ['ob-1']);
      expect(r.failedIds, ['ob-2']);
    });

    test('jawaban rusak -> semua gagal (jangan tandai terkirim)', () {
      expect(applyPushResults(events, null).failedIds, ['ob-1', 'ob-2']);
      expect(applyPushResults(events, {'ok': true}).failedIds, ['ob-1', 'ob-2']);
      expect(
        applyPushResults(events, {'ok': false, 'error': 'x'}).sentIds,
        isEmpty,
      );
    });

    test('alreadyFailed dipertahankan', () {
      final r = applyPushResults(
        events,
        {
          'ok': true,
          'results': [
            {'outbox_id': 'ob-1', 'ok': true},
            {'outbox_id': 'ob-2', 'ok': true},
          ],
        },
        ['ob-lama'],
      );
      expect(r.sentIds, ['ob-1', 'ob-2']);
      expect(r.failedIds, ['ob-lama']);
    });
  });
}
