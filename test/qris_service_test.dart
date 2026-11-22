import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/features/qris/qris_service.dart';

/// Semua payload di file ini adalah CONTOH (merchant fiktif "TOKO CONTOH").
/// Tidak ada nilai QRIS asli di sini.
String buildSampleStatic() => QrisService.sampleStaticPayload();

void main() {
  group('CRC16-CCITT', () {
    test('vektor baku: CRC("123456789") == 29B1', () {
      expect(QrisService.crc16('123456789'), '29B1');
    });
  });

  group('parse tag', () {
    test('tag 59, 53, 00 terbaca dari payload contoh', () {
      final payload = buildSampleStatic();
      expect(QrisService.tagValue(payload, '59'), 'TOKO CONTOH');
      expect(QrisService.tagValue(payload, '53'), '360');
      expect(QrisService.tagValue(payload, '00'), '01');
      expect(QrisService.merchantName(payload), 'TOKO CONTOH');
    });

    test('payload terpotong ditolak', () {
      final payload = buildSampleStatic();
      expect(
        () => QrisService.parse(payload.substring(0, payload.length - 5)),
        throwsFormatException,
      );
    });
  });

  group('validasi payload statis', () {
    test('payload contoh valid', () {
      expect(QrisService.isValidStaticPayload(buildSampleStatic()), isTrue);
      expect(QrisService.validationError(buildSampleStatic()), isNull);
    });

    test('CRC yang dirusak ditolak', () {
      final payload = buildSampleStatic();
      final tampered =
          '${payload.substring(0, payload.length - 1)}0'; // ubah 1 char CRC
      expect(QrisService.isValidStaticPayload(tampered), isFalse);
      expect(QrisService.validationError(tampered), contains('CRC'));
    });

    test('format indicator salah ditolak', () {
      final payload = buildSampleStatic().replaceFirst('000201', '000202');
      expect(QrisService.isValidStaticPayload(payload), isFalse);
    });
  });

  group('generateDynamic', () {
    test('sisipkan tag 54 + ubah tag 01 ke 12 + CRC valid', () {
      final generated = QrisService.generateDynamic(
        staticPayload: buildSampleStatic(),
        amount: 15000,
      );
      expect(generated.contains('540515000'), isTrue);
      expect(QrisService.tagValue(generated, '01'), '12');
      expect(QrisService.tagValue(generated, '54'), '15000');
      expect(QrisService.isValidStaticPayload(generated), isTrue);
      expect(QrisService.merchantName(generated), 'TOKO CONTOH');
    });

    test('ganti nominal: tag 54 lama diganti, bukan dobel', () {
      final withAmount = QrisService.generateDynamic(
        staticPayload: buildSampleStatic(),
        amount: 1000,
      );
      final again = QrisService.generateDynamic(
        staticPayload: withAmount,
        amount: 25000,
      );
      expect(QrisService.tagValue(again, '54'), '25000');
      expect(
        QrisService.parse(again).where((t) => t.id == '54').length,
        1,
      );
      expect(QrisService.isValidStaticPayload(again), isTrue);
    });

    test('nominal 0, negatif, dan di atas batas ditolak', () {
      final payload = buildSampleStatic();
      expect(
        () => QrisService.generateDynamic(staticPayload: payload, amount: 0),
        throwsArgumentError,
      );
      expect(
        () => QrisService.generateDynamic(staticPayload: payload, amount: -5000),
        throwsArgumentError,
      );
      expect(
        () => QrisService.generateDynamic(
          staticPayload: payload,
          amount: QrisService.maxAmount + 1,
        ),
        throwsArgumentError,
      );
    });

    test('payload statis tidak valid ditolak', () {
      expect(
        () => QrisService.generateDynamic(
          staticPayload: 'tidak-valid',
          amount: 10000,
        ),
        throwsFormatException,
      );
    });
  });
}
