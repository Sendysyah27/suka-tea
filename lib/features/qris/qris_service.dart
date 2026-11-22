/// QrisService — QRIS dinamis dari QRIS statis merchant (format EMVCo).
///
/// Dart murni, tanpa secret, tanpa network. Tugasnya:
/// 1. Parse payload QRIS statis (TLV: tag 2 digit + panjang 2 digit + isi).
/// 2. Sisipkan/ganti tag 54 (Transaction Amount) dengan nominal custom.
/// 3. Ubah tag 01 dari "11" (statis) menjadi "12" (dinamis).
/// 4. Hitung ulang CRC16-CCITT (tag 63) dan hasilkan payload dinamis.
///
/// JANGAN tulis nilai mentah payload QRIS asli di repo mana pun — hanya
/// payload CONTOH (merchant fiktif) yang boleh ada di kode/test.
class QrTag {
  const QrTag(this.id, this.value);

  final String id; // 2 digit, contoh: '00', '54', '63'
  final String value;

  String toTlv() => '$id${value.length.toString().padLeft(2, '0')}$value';
}

class QrisService {
  QrisService._();

  /// Batas nominal per transaksi QRIS (Rp10.000.000).
  static const int maxAmount = 10000000;

  /// CRC16-CCITT-FALSE (poly 0x1021, init 0xFFFF). Nilai uji baku:
  /// CRC("123456789") == "29B1".
  static String crc16(String data) {
    var crc = 0xFFFF;
    for (final unit in data.codeUnits) {
      crc ^= unit << 8;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 0x8000) != 0
            ? ((crc << 1) ^ 0x1021) & 0xFFFF
            : (crc << 1) & 0xFFFF;
      }
    }
    return crc.toRadixString(16).toUpperCase().padLeft(4, '0');
  }

  /// Parse payload menjadi daftar tag (urutan dipertahankan).
  /// Throws [FormatException] bila struktur TLV tidak valid.
  static List<QrTag> parse(String payload) {
    final tags = <QrTag>[];
    var i = 0;
    while (i < payload.length) {
      if (i + 4 > payload.length) {
        throw const FormatException('Payload QRIS terpotong.');
      }
      final id = payload.substring(i, i + 2);
      final len = int.tryParse(payload.substring(i + 2, i + 4));
      if (!RegExp(r'^\d{2}$').hasMatch(id) || len == null) {
        throw FormatException('Tag tidak valid di posisi $i: "$id".');
      }
      if (i + 4 + len > payload.length) {
        throw FormatException('Panjang tag $id melebihi payload.');
      }
      tags.add(QrTag(id, payload.substring(i + 4, i + 4 + len)));
      i += 4 + len;
    }
    if (tags.isEmpty) throw const FormatException('Payload QRIS kosong.');
    return tags;
  }

  /// Ambil nilai satu tag (null bila tidak ada).
  static String? tagValue(String payload, String id) {
    try {
      for (final tag in parse(payload)) {
        if (tag.id == id) return tag.value;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Nama merchant (tag 59), null bila tidak ada / payload rusak.
  static String? merchantName(String payload) => tagValue(payload, '59');

  /// Validasi dasar payload QRIS statis. Null = valid.
  static String? validationError(String payload) {
    if (payload.isEmpty) return 'Payload QRIS kosong.';
    late final List<QrTag> tags;
    try {
      tags = parse(payload);
    } on FormatException catch (e) {
      return e.message;
    }
    final format = tags.where((t) => t.id == '00').firstOrNull;
    if (format == null || format.value != '01') {
      return 'Payload Format Indicator (tag 00) harus "01".';
    }
    final initiation = tags.where((t) => t.id == '01').firstOrNull;
    if (initiation == null ||
        (initiation.value != '11' && initiation.value != '12')) {
      return 'Point of Initiation (tag 01) harus "11" (statis) atau "12".';
    }
    final currency = tags.where((t) => t.id == '53').firstOrNull;
    if (currency != null && currency.value != '360') {
      return 'Mata uang (tag 53) harus "360" (IDR).';
    }
    if (!RegExp(r'63\d{2}[0-9A-Fa-f]{4}$').hasMatch(payload)) {
      return 'CRC (tag 63) tidak ditemukan di akhir payload.';
    }
    final crcTag = tags.where((t) => t.id == '63').firstOrNull;
    if (crcTag == null || crcTag.value.length != 4) {
      return 'CRC (tag 63) tidak ditemukan di akhir payload.';
    }
    final withoutCrc = '${payload.substring(0, payload.length - 8)}6304';
    if (crc16(withoutCrc).toUpperCase() != crcTag.value.toUpperCase()) {
      return 'CRC tidak valid — kode QRIS mungkin rusak atau salah salin.';
    }
    return null;
  }

  static bool isValidStaticPayload(String payload) =>
      validationError(payload) == null;

  /// Buat payload QRIS dinamis dari payload statis + nominal custom.
  /// Throws [ArgumentError] bila nominal tidak valid,
  /// [FormatException] bila payload statis tidak valid.
  static String generateDynamic({
    required String staticPayload,
    required int amount,
  }) {
    if (amount <= 0) {
      throw ArgumentError('Nominal harus lebih dari 0.');
    }
    if (amount > maxAmount) {
      throw ArgumentError(
        'Nominal maksimal Rp10.000.000 per transaksi QRIS.',
      );
    }
    final error = validationError(staticPayload);
    if (error != null) throw FormatException(error);

    final tags = parse(staticPayload)
        .where((t) => t.id != '63') // buang CRC lama
        .toList();

    // Sisipkan/ganti tag 54 (Transaction Amount) pada posisi urutannya.
    final amountStr = amount.toString();
    final idx54 = tags.indexWhere((t) => t.id == '54');
    if (idx54 >= 0) {
      tags[idx54] = QrTag('54', amountStr);
    } else {
      final insertAt = tags.indexWhere((t) => t.id.compareTo('54') > 0);
      if (insertAt >= 0) {
        tags.insert(insertAt, QrTag('54', amountStr));
      } else {
        tags.add(QrTag('54', amountStr));
      }
    }

    // Statis (11) -> dinamis (12).
    final idx01 = tags.indexWhere((t) => t.id == '01');
    if (idx01 >= 0 && tags[idx01].value == '11') {
      tags[idx01] = const QrTag('01', '12');
    }

    final buf = StringBuffer();
    for (final tag in tags) {
      buf.write(tag.toTlv());
    }
    buf.write('6304');
    buf.write(crc16(buf.toString()));
    return buf.toString();
  }

  /// Payload statis CONTOH (merchant fiktif "TOKO CONTOH") — hanya untuk
  /// demo tampilan dan unit test. BUKAN QRIS asli; jangan dipakai untuk
  /// pembayaran nyata.
  static String sampleStaticPayload() {
    final parts = <String>[
      const QrTag('00', '01').toTlv(),
      const QrTag('01', '11').toTlv(),
      const QrTag('52', '0000').toTlv(),
      const QrTag('53', '360').toTlv(),
      const QrTag('58', 'ID').toTlv(),
      const QrTag('59', 'TOKO CONTOH').toTlv(),
      const QrTag('60', 'JAKARTA').toTlv(),
    ];
    final body = '${parts.join()}6304';
    return body + crc16(body);
  }
}
