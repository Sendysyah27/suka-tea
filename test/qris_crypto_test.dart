import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/features/qris/qris_crypto.dart';
import 'package:suka_tea/features/qris/qris_service.dart';

/// Enkripsi payload QRIS (Batch C2, RedMuse F2) — level fungsi saja.
/// Plaintext test HANYA memakai payload CONTOH fiktif "TOKO CONTOH"
/// (QrisService.sampleStaticPayload) — bukan QRIS asli.
/// Kunci test dibuat acak di dalam test (bukan secret nyata).
void main() {
  group('QrisCrypto', () {
    test('round-trip: enkripsi lalu dekripsi = payload asli', () {
      final key = QrisCrypto.generateKey();
      final sample = QrisService.sampleStaticPayload();
      final encrypted = QrisCrypto.encrypt(sample, key);
      expect(encrypted, startsWith(QrisCrypto.prefix));
      expect(QrisCrypto.decrypt(encrypted, key), sample);
    });

    test('dua enkripsi nilai sama menghasilkan string berbeda (nonce acak)',
        () {
      final key = QrisCrypto.generateKey();
      final sample = QrisService.sampleStaticPayload();
      final a = QrisCrypto.encrypt(sample, key);
      final b = QrisCrypto.encrypt(sample, key);
      expect(a, isNot(b));
      expect(QrisCrypto.decrypt(a, key), sample);
      expect(QrisCrypto.decrypt(b, key), sample);
    });

    test('kunci salah -> dekripsi null (tag GCM tidak cocok)', () {
      final key = QrisCrypto.generateKey();
      final otherKey = QrisCrypto.generateKey();
      final sample = QrisService.sampleStaticPayload();
      final encrypted = QrisCrypto.encrypt(sample, key);
      expect(QrisCrypto.decrypt(encrypted, otherKey), isNull);
    });

    test('ciphertext dirusak -> dekripsi null', () {
      final key = QrisCrypto.generateKey();
      final sample = QrisService.sampleStaticPayload();
      final encrypted = QrisCrypto.encrypt(sample, key);
      // Rusak 1 karakter base64 di tengah badan (bukan prefix).
      final body = encrypted.substring(QrisCrypto.prefix.length);
      final tamperedBody = body.replaceRange(
        10,
        11,
        body[10] == 'A' ? 'B' : 'A',
      );
      expect(
        QrisCrypto.decrypt('${QrisCrypto.prefix}$tamperedBody', key),
        isNull,
      );
    });

    test('dekripsi plaintext (tanpa prefix) -> null', () {
      final key = QrisCrypto.generateKey();
      final sample = QrisService.sampleStaticPayload();
      expect(QrisCrypto.decrypt(sample, key), isNull);
    });

    test('dekripsi string kosong / base64 rusak -> null', () {
      final key = QrisCrypto.generateKey();
      expect(QrisCrypto.decrypt('', key), isNull);
      expect(QrisCrypto.decrypt('${QrisCrypto.prefix}!!!', key), isNull);
      expect(
        QrisCrypto.decrypt('${QrisCrypto.prefix}AA==', key),
        isNull,
      );
    });

    test('isEncrypted: prefix terdeteksi, plaintext tidak', () {
      final key = QrisCrypto.generateKey();
      final sample = QrisService.sampleStaticPayload();
      expect(QrisCrypto.isEncrypted(sample), isFalse);
      expect(
        QrisCrypto.isEncrypted(QrisCrypto.encrypt(sample, key)),
        isTrue,
      );
      expect(QrisCrypto.isEncrypted(''), isFalse);
    });

    test('generateKey menghasilkan 32 byte', () {
      expect(QrisCrypto.generateKey().length, 32);
    });

    test('enkripsi dengan kunci panjang salah -> ArgumentError', () {
      final sample = QrisService.sampleStaticPayload();
      expect(
        () => QrisCrypto.encrypt(sample, Uint8List(16)),
        throwsArgumentError,
      );
    });

    test('dekripsi dengan kunci panjang salah -> null', () {
      final key = QrisCrypto.generateKey();
      final sample = QrisService.sampleStaticPayload();
      final encrypted = QrisCrypto.encrypt(sample, key);
      expect(QrisCrypto.decrypt(encrypted, Uint8List(16)), isNull);
    });

    test('kunci acak bisa disimpan sebagai base64 dan dibaca kembali', () {
      final key = QrisCrypto.generateKey();
      final restored = base64Decode(base64Encode(key));
      expect(restored, key);
    });
  });
}
