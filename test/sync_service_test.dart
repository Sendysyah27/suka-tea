import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/local/app_database.dart';
import 'package:suka_tea/data/sync_service.dart';

OutboxEntry _saleEntry(String id, {String method = 'tunai'}) =>
    OutboxEntry(
      id: id,
      kind: 'transaction',
      payload: jsonEncode({
        'client_uuid': '11111111-2222-4333-8444-55555555555${id.substring(id.length - 1)}',
        'outlet_id': '00000000-0000-0000-0000-000000000001',
        'payment_method': method,
        'total': 8000,
        'discount': 0,
        'paid': 8000,
        'change': 0,
        'qris_amount': 0,
        'cash_amount': 0,
        'is_void': false,
        'created_at': '2026-11-24T10:00:00.000',
        'items': [
          {'name': 'Es Teh Jumbo Reguler', 'qty': 1, 'price': 3000},
        ],
      }),
      attempts: 0,
      status: 'pending',
      createdAt: DateTime(2026, 11, 24, 10, 0),
    );

OutboxEntry _stockEntry(String id) => OutboxEntry(
      id: id,
      kind: 'stock_movement',
      payload: jsonEncode({
        'client_uuid': '22222222-3333-4444-8555-666666666666',
        'outlet_id': '00000000-0000-0000-0000-000000000001',
        'reason': 'penjualan',
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
      }),
      attempts: 0,
      status: 'pending',
      createdAt: DateTime(2026, 11, 24, 10, 1),
    );

/// Transport palsu: semua event ok.
Future<Map<String, dynamic>> _okTransport(
  Map<String, dynamic> body,
) async {
  final events = (body['events'] as List).cast<Map<String, dynamic>>();
  return {
    'ok': true,
    'results': events
        .map((e) => {
              'outbox_id': e['outbox_id'],
              'client_uuid': e['client_uuid'],
              'ok': true,
            })
        .toList(),
  };
}

void main() {
  group('flushOutboxEntries', () {
    test('sukses: semua terkirim, tidak ada gagal', () async {
      final r = await flushOutboxEntries(
        [_saleEntry('ob-1'), _stockEntry('ob-2')],
        _okTransport,
      );
      expect(r.sentIds, ['ob-1', 'ob-2']);
      expect(r.failedIds, isEmpty);
    });

    test('kosong: tidak memanggil transport', () async {
      var called = false;
      final r = await flushOutboxEntries([], (_) async {
        called = true;
        return {'ok': true};
      });
      expect(called, isFalse);
      expect(r.sentIds, isEmpty);
      expect(r.failedIds, isEmpty);
    });

    test('parsial: hanya yang ok terkirim', () async {
      Future<Map<String, dynamic>> partial(
        Map<String, dynamic> body,
      ) async {
        final events = (body['events'] as List).cast<Map<String, dynamic>>();
        return {
          'ok': true,
          'results': events
              .map((e) => {
                    'outbox_id': e['outbox_id'],
                    'ok': e['outbox_id'] == 'ob-1',
                    if (e['outbox_id'] != 'ob-1') 'error': 'gagal',
                  })
              .toList(),
        };
      }

      final r = await flushOutboxEntries(
        [_saleEntry('ob-1'), _saleEntry('ob-2', method: 'split')],
        partial,
      );
      expect(r.sentIds, ['ob-1']);
      expect(r.failedIds, ['ob-2']);
    });

    test('transport throw -> semua gagal (tidak ada yang terkirim)', () async {
      final r = await flushOutboxEntries(
        [_saleEntry('ob-1'), _stockEntry('ob-2')],
        (_) async => throw StateError('offline'),
      );
      expect(r.sentIds, isEmpty);
      expect(r.failedIds, ['ob-1', 'ob-2']);
    });

    test('jawaban rusak -> semua gagal', () async {
      final r = await flushOutboxEntries(
        [_saleEntry('ob-1')],
        (_) async => {'ok': true},
      );
      expect(r.sentIds, isEmpty);
      expect(r.failedIds, ['ob-1']);
    });

    test('entri payload rusak dilewati, entri lain tetap terkirim', () async {
      final bad = OutboxEntry(
        id: 'ob-bad',
        kind: 'transaction',
        payload: jsonEncode({
          'client_uuid': 'x',
          'payment_method': 'ngaco',
          'total': 100,
          'items': [
            {'name': 'X', 'qty': 1, 'price': 100},
          ],
        }),
        attempts: 0,
        status: 'pending',
        createdAt: DateTime(2026, 11, 24, 10, 2),
      );
      final r = await flushOutboxEntries([bad, _saleEntry('ob-1')], _okTransport);
      expect(r.sentIds, ['ob-1']);
      expect(r.failedIds, ['ob-bad']);
    });

    test('payload bukan JSON dilewati', () async {
      final bad = OutboxEntry(
        id: 'ob-bad2',
        kind: 'transaction',
        payload: 'bukan-json{{{',
        attempts: 0,
        status: 'pending',
        createdAt: DateTime(2026, 11, 24, 10, 3),
      );
      final r = await flushOutboxEntries([bad, _saleEntry('ob-1')], _okTransport);
      expect(r.sentIds, ['ob-1']);
      expect(r.failedIds, ['ob-bad2']);
    });

    test('mutasi stok LAMA (pra-C6) dilewati, bukan gagal', () async {
      final legacy = OutboxEntry(
        id: 'ob-legacy',
        kind: 'stock_movement',
        payload: jsonEncode({
          'client_uuid': '1700000000000000',
          'reason': 'penjualan',
          'deductions': {'Teh': 20.0, 'Gula': 5.0},
        }),
        attempts: 0,
        status: 'pending',
        createdAt: DateTime(2026, 11, 23, 21, 0),
      );
      var called = false;
      final r = await flushOutboxEntries([legacy, _saleEntry('ob-1')],
          (body) async {
        called = true;
        return _okTransport(body);
      });
      expect(called, isTrue);
      expect(r.sentIds, ['ob-1']);
      expect(r.skippedIds, ['ob-legacy']);
      expect(r.failedIds, isEmpty);
    });

    test('event void (is_void) ikut terkirim seperti penjualan biasa',
        () async {
      final voidEntry = OutboxEntry(
        id: 'ob-void',
        kind: 'transaction',
        payload: jsonEncode({
          'client_uuid': '11111111-2222-4333-8444-555555555551',
          'outlet_id': '00000000-0000-0000-0000-000000000001',
          'payment_method': 'tunai',
          'total': 8000,
          'discount': 0,
          'paid': 8000,
          'change': 0,
          'qris_amount': 0,
          'cash_amount': 0,
          'is_void': true,
          'created_at': '2026-11-24T10:05:00.000',
          'items': [
            {'name': 'Es Teh Jumbo Reguler', 'qty': 1, 'price': 3000},
          ],
        }),
        attempts: 0,
        status: 'pending',
        createdAt: DateTime(2026, 11, 24, 10, 5),
      );
      Map<String, dynamic>? sentBody;
      final r = await flushOutboxEntries([voidEntry], (body) async {
        sentBody = body;
        return _okTransport(body);
      });
      expect(r.sentIds, ['ob-void']);
      final events = (sentBody!['events'] as List).cast<Map<String, dynamic>>();
      expect((events.first['payload'] as Map)['is_void'], isTrue);
    });
  });
}
