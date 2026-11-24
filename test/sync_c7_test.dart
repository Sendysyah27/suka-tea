import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/sync_payload.dart';

const _outlet = '00000000-0000-0000-0000-000000000001';
final _at = DateTime(2026, 11, 24, 8, 0);

void main() {
  group('normalizeExpenseEvent', () {
    test('valid: field lengkap', () {
      final event = normalizeExpenseEvent(
        outboxId: 'ob-1',
        rawPayload: {
          'client_uuid': '11111111-1111-4111-8111-111111111111',
          'outlet_id': _outlet,
          'category': 'Bahan Baku',
          'description': 'es batu',
          'amount': 25000,
          'is_cash': true,
          'cashier_name': 'Budi',
          'created_at': '2026-11-24T08:00:00.000',
          'is_deleted': false,
        },
        entryCreatedAt: _at,
        fallbackOutletId: _outlet,
      );
      expect(event['kind'], 'expense');
      expect(event['client_uuid'], '11111111-1111-4111-8111-111111111111');
      final payload = event['payload'] as Map<String, dynamic>;
      expect(payload['category'], 'Bahan Baku');
      expect(payload['amount'], 25000);
      expect(payload['is_cash'], true);
      expect(payload['is_deleted'], false);
    });

    test('is_deleted: hanya client_uuid + outlet_id yang dibaca', () {
      final event = normalizeExpenseEvent(
        outboxId: 'ob-2',
        rawPayload: {
          'client_uuid': '22222222-2222-4222-8222-222222222222',
          'outlet_id': _outlet,
          'is_deleted': true,
        },
        entryCreatedAt: _at,
        fallbackOutletId: _outlet,
      );
      expect(event['kind'], 'expense');
      expect(
        (event['payload'] as Map<String, dynamic>)['is_deleted'],
        true,
      );
    });

    test('amount 0 ditolak (CHECK Supabase > 0)', () {
      expect(
        () => normalizeExpenseEvent(
          outboxId: 'ob-3',
          rawPayload: {
            'client_uuid': '33333333-3333-4333-8333-333333333333',
            'outlet_id': _outlet,
            'category': 'Gaji',
            'amount': 0,
          },
          entryCreatedAt: _at,
          fallbackOutletId: _outlet,
        ),
        throwsArgumentError,
      );
    });

    test('tanpa client_uuid ditolak', () {
      expect(
        () => normalizeExpenseEvent(
          outboxId: 'ob-4',
          rawPayload: {
            'outlet_id': _outlet,
            'category': 'Gaji',
            'amount': 10000,
          },
          entryCreatedAt: _at,
          fallbackOutletId: _outlet,
        ),
        throwsFormatException,
      );
    });
  });

  group('normalizeShiftEvent', () {
    test('buka: closed_* null, status open', () {
      final event = normalizeShiftEvent(
        outboxId: 'ob-5',
        rawPayload: {
          'client_uuid': '55555555-5555-4555-8555-555555555555',
          'outlet_id': _outlet,
          'cashier_name': 'Budi',
          'opened_at': '2026-11-24T08:00:00.000',
          'opening_float': 50000,
          'closed_at': null,
          'counted_cash': null,
          'expected_cash': null,
          'difference': null,
          'status': 'open',
          'note': '',
        },
        entryCreatedAt: _at,
        fallbackOutletId: _outlet,
      );
      expect(event['kind'], 'shift');
      final payload = event['payload'] as Map<String, dynamic>;
      expect(payload['status'], 'open');
      expect(payload['closed_at'], isNull);
      expect(payload['opening_float'], 50000);
    });

    test('tutup: difference negatif diizinkan', () {
      final event = normalizeShiftEvent(
        outboxId: 'ob-6',
        rawPayload: {
          'client_uuid': '66666666-6666-4666-8666-666666666666',
          'outlet_id': _outlet,
          'cashier_name': 'Budi',
          'opened_at': '2026-11-24T08:00:00.000',
          'opening_float': 50000,
          'closed_at': '2026-11-24T16:00:00.000',
          'counted_cash': 150000,
          'expected_cash': 155000,
          'difference': -5000,
          'status': 'closed',
          'note': '',
        },
        entryCreatedAt: _at,
        fallbackOutletId: _outlet,
      );
      final payload = event['payload'] as Map<String, dynamic>;
      expect(payload['status'], 'closed');
      expect(payload['difference'], -5000);
      expect(payload['counted_cash'], 150000);
    });

    test('closed tanpa closed_at ditolak', () {
      expect(
        () => normalizeShiftEvent(
          outboxId: 'ob-7',
          rawPayload: {
            'client_uuid': '77777777-7777-4777-8777-777777777777',
            'outlet_id': _outlet,
            'opened_at': '2026-11-24T08:00:00.000',
            'opening_float': 0,
            'status': 'closed',
          },
          entryCreatedAt: _at,
          fallbackOutletId: _outlet,
        ),
        throwsFormatException,
      );
    });

    test('tanpa opened_at ditolak', () {
      expect(
        () => normalizeShiftEvent(
          outboxId: 'ob-8',
          rawPayload: {
            'client_uuid': '88888888-8888-4888-8888-888888888888',
            'outlet_id': _outlet,
            'opening_float': 0,
            'status': 'open',
          },
          entryCreatedAt: _at,
          fallbackOutletId: _outlet,
        ),
        throwsFormatException,
      );
    });
  });
}
