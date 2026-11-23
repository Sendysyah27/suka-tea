import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/data/sheets_export.dart';

void main() {
  group('shiftIdForToday', () {
    test('format YYYY-MM-DD dari tanggal tetap', () {
      expect(shiftIdForToday(DateTime(2026, 11, 23)), '2026-11-23');
    });

    test('bulan + tanggal 1 digit di-pad 0', () {
      expect(shiftIdForToday(DateTime(2026, 1, 5)), '2026-01-05');
    });

    test('tanpa argumen = hari ini (format tanggal valid)', () {
      final id = shiftIdForToday();
      expect(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(id), isTrue);
    });
  });

  group('parseExportResponse', () {
    test('ok + counts -> pesan jumlah transaksi', () {
      final r = parseExportResponse({
        'ok': true,
        'counts': {'transactions': 12, 'stock_items': 8, 'expenses': 2},
      });
      expect(r.ok, isTrue);
      expect(r.message, contains('12 transaksi'));
    });

    test('ok + note -> pesan bawa catatan', () {
      final r = parseExportResponse({
        'ok': true,
        'counts': {'transactions': 0},
        'note': 'Belum ada data di Supabase.',
      });
      expect(r.ok, isTrue);
      expect(r.message, contains('0 transaksi'));
      expect(r.message, contains('Belum ada data di Supabase.'));
    });

    test('ok:false + error string -> pesan error itu', () {
      final r = parseExportResponse({
        'ok': false,
        'error': 'Google Sheets belum dikonfigurasi — isi secret X.',
      });
      expect(r.ok, isFalse);
      expect(r.message, contains('Google Sheets belum dikonfigurasi'));
    });

    test('ok:false tanpa error -> pesan generik', () {
      final r = parseExportResponse({'ok': false});
      expect(r.ok, isFalse);
      expect(r.message, contains('gagal'));
    });

    test('bukan Map -> gagal generik', () {
      expect(parseExportResponse(null).ok, isFalse);
      expect(parseExportResponse('ok').ok, isFalse);
    });
  });
}
