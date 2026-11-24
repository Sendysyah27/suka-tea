import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Pembentuk + penafsir payload sinkronisasi Supabase (Batch C6).
/// MURNI (tanpa Supabase / Drift) supaya bisa di-unit-test.
///
/// Bentuk event yang dikirim ke Edge Function `sync-sales`:
///   { outbox_id, kind, client_uuid, outlet_id, created_at, payload }
/// - kind 'transaction': payload penjualan (lihat [normalizeSaleEvent]).
/// - kind 'stock_movement': payload mutasi stok (lihat
///   [normalizeStockEvent]).
/// - kind 'expense' (Batch C7): payload pengeluaran (lihat
///   [normalizeExpenseEvent]); hapus = is_deleted true.
/// - kind 'shift' (Batch C7): payload shift kas (lihat
///   [normalizeShiftEvent]); upsert last-write-wins by client_uuid.
/// Kunci idempotency = client_uuid (kolom unique di `transactions`
/// dan `stock_movements`). Entri outbox LAMA (sebelum C6) memakai
/// client_uuid string angka mikROdetik (bukan UUID) — server
/// menormalkannya secara deterministik, jadi tetap idempotent.
///
/// Batch C8.2: penjualan membawa cashier_id + cashier_name (WS4);
/// mutasi stok membawa outlet pengirim + DELTA (WS5 — bukan level
/// absolut lagi); shift membawa cashier pembuka + penutup (WS6) dan
/// pull mengembalikan stok + shift terbuka gerai itu (WS5/WS6) —
/// dedupe shift antar device diputuskan fungsi pure di bawah
/// ([resolveShiftWinner] / [pickAdoptedShift]).
///
/// Batch C9 (sinkronisasi database):
/// - SEMUA timestamp ke server lewat [toUtcIsoString] /
///   [normalizeCreatedAtToUtc] (...Z) — perbaikan bug jam +7 jam.
/// - Pull-merge: [planSaleMerge] ada di sale_history.dart,
///   [planExpenseMerge] di expense_service.dart, [planStockMerge]
///   di stock_service.dart (fungsi murni, dekat tipenya — supaya
///   tidak ada import melingkar dengan file ini).
/// - Mutasi stok reason 'koreksi' + 'tambah' (harga / koreksi
///   jumlah / bahan baru) ikut tersinkron sebagai event
///   'stock_movement' (lihat [normalizeStockEvent]).

/// Cara bayar yang dikenal server (migrasi 001 + 002 + 008).
const Set<String> serverPaymentMethods = {
  'tunai',
  'transfer',
  'qris',
  'qris_manual',
  'ewallet',
  'split',
};

/// Tanggal 'YYYY-MM-DD' (zona lokal) — dipakai rentang pull.
String dateOnly(DateTime d) {
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '${d.year}-$m-$day';
}

/// Jam ke string ISO UTC (`...Z`) — PERBAIKAN JAM Batch C9.
///
/// BUG LAMA: app mengirim `DateTime.toIso8601String()` untuk waktu
/// lokal — string itu TANPA offset, server menyimpannya sebagai
/// +00 (UTC), jadi jam WIB tampil +7 jam di mana-mana (mis.
/// penjualan 15:40 WIB tampil 22:40). SEMUA timestamp yang dikirim
/// ke server WAJIB lewat helper ini (atau [normalizeCreatedAtToUtc]
/// untuk string mentah): `.toUtc()` dulu, baru `toIso8601String()`
/// — hasilnya selalu berakhiran `Z`. Penyimpanan Drift lokal TIDAK
/// disentuh (tetap waktu lokal).
String toUtcIsoString(DateTime d) => d.toUtc().toIso8601String();

/// Normalisasi string ISO mentah ke UTC (`...Z`). String TANPA
/// offset diparse sebagai waktu LOKAL (perilaku DateTime.tryParse)
/// lalu diubah ke UTC — jadi string lama '2026-11-24T15:40:00.000'
/// (yang ditulis app sebelum C9) menjadi '2026-11-24T08:40:00.000Z'
/// (benar: 15:40 WIB = 08:40 UTC). String ber-offset / berakhiran
/// Z diparse apa adanya lalu diubah ke UTC (hasil sama). String
/// kosong / tidak bisa diparse -> [fallback] (juga ke UTC).
String normalizeCreatedAtToUtc(String? raw, DateTime fallback) {
  final parsed = raw != null && raw.isNotEmpty
      ? DateTime.tryParse(raw)
      : null;
  return (parsed ?? fallback).toUtc().toIso8601String();
}

/// Pola UUID (dipakai [normalizeLegacyClientUuid] + normalizer
/// lain — sekali saja, bukan dibuat ulang tiap panggilan).
final _uuidRegExp = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Normalisasi client_uuid legacy — CERMINAN PERSIS fungsi
/// `normalizeClientUuid` di Edge Function sync-sales (Batch C9).
/// UUID valid dipakai apa adanya (huruf kecil); string lain (mis.
/// angka mikROdetik dari outbox lama sebelum C6) dipetakan secara
/// deterministik ke UUID v5-style dari SHA-256 string itu — string
/// yang sama selalu menghasilkan UUID yang sama. Dipakai merge
/// pull (dedupe): record lokal lama (id mikROdetik) + baris server
/// (client_uuid yang sudah dinormalkan server) dikenali sebagai
/// SATU transaksi yang sama, bukan dobel.
String normalizeLegacyClientUuid(String raw) {
  final s = raw.trim().toLowerCase();
  if (_uuidRegExp.hasMatch(s)) return s;
  final hash = sha256.convert(utf8.encode(s)).bytes;
  final bytes = hash.sublist(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50; // version 5
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant RFC 4122
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// UUID v4 acak (tanpa dep `uuid` — Random.secure + format manual).
/// Dipakai sebagai client_uuid penjualan baru + mutasi stok.
String newClientUuid() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant RFC 4122
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

int _asNonNegInt(dynamic value, String field) {
  if (value is num) {
    final v = value.toInt();
    if (v < 0) throw ArgumentError('$field negatif: $v');
    return v;
  }
  throw ArgumentError('$field bukan angka: $value');
}

double _asNumber(dynamic value, String field) {
  if (value is num) {
    final v = value.toDouble();
    if (v.isNaN || v.isInfinite) {
      throw ArgumentError('$field bukan angka berhingga: $value');
    }
    return v;
  }
  throw ArgumentError('$field bukan angka: $value');
}

String _asString(dynamic value, String field) {
  if (value is String && value.isNotEmpty) return value;
  throw ArgumentError('$field kosong / bukan string: $value');
}

/// Normalisasi satu item penjualan dari payload outbox mentah.
/// Nama + qty + harga wajib; modifiers opsional (list nama string).
Map<String, dynamic> _normalizeSaleItem(dynamic raw) {
  if (raw is! Map) throw const FormatException('item penjualan bukan Map');
  final name = _asString(raw['name'], 'item.name');
  final qty = _asNonNegInt(raw['qty'], 'item.qty');
  if (qty == 0) throw const FormatException('item.qty 0');
  final price = _asNonNegInt(raw['price'], 'item.price');
  final modifiers = raw['modifiers'];
  final mods = <String>[];
  if (modifiers is List) {
    for (final m in modifiers) {
      mods.add(m.toString());
    }
  }
  return {'name': name, 'qty': qty, 'price': price, 'modifiers': mods};
}

/// Normalisasi event penjualan ('transaction') dari satu baris outbox.
/// Mengisi default untuk payload LAMA (sebelum C6) yang belum punya
/// outlet_id / paid / change / created_at / is_void:
/// outlet -> [fallbackOutletId] (gerai utama), paid -> total,
/// change -> 0, is_void -> false, created_at -> [entryCreatedAt].
/// Throw [ArgumentError]/[FormatException] bila payload tidak bisa
/// diperbaiki (cara bayar tak dikenal, items kosong, angka negatif) —
/// pemanggil (flush) harus melewati entri itu, bukan memblokir antrean.
Map<String, dynamic> normalizeSaleEvent({
  required String outboxId,
  required Map<String, dynamic> rawPayload,
  required DateTime entryCreatedAt,
  required String fallbackOutletId,
}) {
  final method = rawPayload['payment_method'];
  if (method is! String || !serverPaymentMethods.contains(method)) {
    throw ArgumentError('payment_method tidak dikenal: $method');
  }
  final total = _asNonNegInt(rawPayload['total'], 'total');
  final discount = rawPayload.containsKey('discount')
      ? _asNonNegInt(rawPayload['discount'], 'discount')
      : 0;
  final paid = rawPayload.containsKey('paid')
      ? _asNonNegInt(rawPayload['paid'], 'paid')
      : total;
  final change = rawPayload.containsKey('change')
      ? _asNonNegInt(rawPayload['change'], 'change')
      : 0;
  final qrisAmount = rawPayload.containsKey('qris_amount')
      ? _asNonNegInt(rawPayload['qris_amount'], 'qris_amount')
      : 0;
  final cashAmount = rawPayload.containsKey('cash_amount')
      ? _asNonNegInt(rawPayload['cash_amount'], 'cash_amount')
      : 0;
  final itemsRaw = rawPayload['items'];
  if (itemsRaw is! List || itemsRaw.isEmpty) {
    throw const FormatException('items penjualan kosong / bukan list');
  }
  final items = itemsRaw.map(_normalizeSaleItem).toList();
  final clientUuid = rawPayload['client_uuid'];
  if (clientUuid is! String || clientUuid.isEmpty) {
    throw const FormatException('client_uuid kosong');
  }
  final outletRaw = rawPayload['outlet_id'];
  final outletId = (outletRaw is String && outletRaw.isNotEmpty)
      ? outletRaw
      : fallbackOutletId;
  final createdRaw = rawPayload['created_at'];
  // Batch C9: kirim UTC (...Z) — string lama tanpa offset diparse
  // sebagai waktu lokal lalu diubah ke UTC (lihat
  // [normalizeCreatedAtToUtc]).
  final createdAt = normalizeCreatedAtToUtc(
    createdRaw is String ? createdRaw : null,
    entryCreatedAt,
  );
  // Batch C8.2 WS4: kasir pencatat ikut tersinkron (struk + Pantau
  // Gerai + expected tutup kas tahu siapa yang jual). Payload lama
  // tanpa kasir -> '' (server menyimpan default '').
  final cashierId = rawPayload['cashier_id'];
  final cashierName = rawPayload['cashier_name'];
  return {
    'outbox_id': outboxId,
    'kind': 'transaction',
    'client_uuid': clientUuid,
    'outlet_id': outletId,
    'created_at': createdAt,
    'payload': {
      'payment_method': method,
      'total': total,
      'discount': discount,
      'paid': paid,
      'change': change,
      'qris_amount': qrisAmount,
      'cash_amount': cashAmount,
      'cashier_id': cashierId is String ? cashierId : '',
      'cashier_name': cashierName is String ? cashierName : '',
      'is_void': rawPayload['is_void'] == true,
      'items': items,
    },
  };
}

/// true = payload mutasi stok LAMA (sebelum C6): hanya membawa
/// `deductions`/`additions` (map nama -> jumlah) tanpa level
/// absolut per bahan. Bentuk ini TIDAK BISA direkonstruksi jadi
/// event stok baru (qty_after saat itu sudah tidak diketahui) —
/// flush melewatinya dengan sengaja (lihat flushOutboxEntries).
/// Level stok Supabase pulih sendiri dari mutasi baru pertama
/// per bahan (membawa qty_after absolut).
bool isLegacyStockPayload(Map<String, dynamic> rawPayload) {
  if (rawPayload.containsKey('items')) return false;
  return rawPayload.containsKey('deductions') ||
      rawPayload.containsKey('additions');
}

/// Normalisasi event mutasi stok ('stock_movement').
/// Payload per item: {name, unit, qty_after, low_threshold,
/// cost_per_unit, delta} — delta negatif = penjualan, positif = void.
/// [qty_after] = level lokal sesudah mutasi (info tampilan — server
/// Batch C8.2 WS5 TIDAK lagi memakai level absolut, melainkan DELTA:
/// hanya terapkan bila movement benar-benar baru, clamp >= 0).
/// outlet_id = outlet PENGIRIM (Batch C8.2 WS5 — stok per gerai);
/// payload lama tanpa outlet_id jatuh ke [fallbackOutletId].
Map<String, dynamic> normalizeStockEvent({
  required String outboxId,
  required Map<String, dynamic> rawPayload,
  required DateTime entryCreatedAt,
  required String fallbackOutletId,
}) {
  final itemsRaw = rawPayload['items'];
  if (itemsRaw is! List || itemsRaw.isEmpty) {
    throw const FormatException('items mutasi stok kosong / bukan list');
  }
  final items = <Map<String, dynamic>>[];
  for (final raw in itemsRaw) {
    if (raw is! Map) throw const FormatException('item stok bukan Map');
    // Batch C10.1 Bug 2b: cost_per_unit yang TIDAK ADA atau 0 =
    // biaya belum diatur — JANGAN diisi 0 (server akan menimpa
    // harga dengan 0 dan sentinel -1 hancur). Biaya 0 yang asli
    // (gratis, diatur Owner) tetap sampai server lewat event master
    // 'stock_item_config' (lihat _enqueueStockConfig), bukan lewat
    // mutasi stok — jadi mutasi hanya membawa biaya bila > 0.
    final item = <String, dynamic>{
      'name': _asString(raw['name'], 'item.name'),
      'unit': raw['unit'] is String ? raw['unit'] as String : 'pcs',
      'qty_after': _asNumber(raw['qty_after'], 'item.qty_after'),
      'low_threshold': raw.containsKey('low_threshold')
          ? _asNumber(raw['low_threshold'], 'item.low_threshold')
          : 0.0,
      'delta': _asNumber(raw['delta'], 'item.delta'),
    };
    if (raw.containsKey('cost_per_unit')) {
      final cost = _asNonNegInt(raw['cost_per_unit'], 'item.cost_per_unit');
      if (cost > 0) item['cost_per_unit'] = cost;
    }
    items.add(item);
  }
  final clientUuid = rawPayload['client_uuid'];
  if (clientUuid is! String || clientUuid.isEmpty) {
    throw const FormatException('client_uuid kosong');
  }
  final outletRaw = rawPayload['outlet_id'];
  final outletId = (outletRaw is String && outletRaw.isNotEmpty)
      ? outletRaw
      : fallbackOutletId;
  final createdRaw = rawPayload['created_at'];
  // Batch C9: kirim UTC (...Z) — lihat [normalizeCreatedAtToUtc].
  final createdAt = normalizeCreatedAtToUtc(
    createdRaw is String ? createdRaw : null,
    entryCreatedAt,
  );
  // Batch C9: 'koreksi' (ubah harga / koreksi jumlah manual) +
  // 'tambah' (bahan baru) ikut tersinkron sebagai mutasi stok —
  // server meneruskannya ke kolom reason (tanpa CHECK constraint).
  final reasonRaw = rawPayload['reason'];
  final reason = reasonRaw is String &&
          (reasonRaw == 'penjualan' ||
              reasonRaw == 'void' ||
              reasonRaw == 'koreksi' ||
              reasonRaw == 'tambah')
      ? reasonRaw
      : 'penjualan';
  final txnRaw = rawPayload['transaction_client_uuid'];
  return {
    'outbox_id': outboxId,
    'kind': 'stock_movement',
    'client_uuid': clientUuid,
    'outlet_id': outletId,
    'created_at': createdAt,
    'payload': {
      'reason': reason,
      'transaction_client_uuid':
          txnRaw is String && txnRaw.isNotEmpty ? txnRaw : null,
      'items': items,
    },
  };
}

/// Angka nullable (null = tidak ada) — [allowNegative] true untuk
/// selisih tutup kas (boleh kurang = negatif).
int? _asNullableInt(
  dynamic value,
  String field, {
  bool allowNegative = false,
}) {
  if (value == null) return null;
  if (value is! num) throw ArgumentError('$field bukan angka: $value');
  final v = value.toInt();
  if (!allowNegative && v < 0) {
    throw ArgumentError('$field negatif: $v');
  }
  return v;
}

/// Normalisasi event pengeluaran ('expense') dari satu baris outbox.
/// Hapus = is_deleted true: hanya client_uuid (+ outlet_id) yang
/// dibaca server — field lain boleh tidak ada. Selain itu amount
/// wajib > 0 (CHECK Supabase expenses.amount > 0).
Map<String, dynamic> normalizeExpenseEvent({
  required String outboxId,
  required Map<String, dynamic> rawPayload,
  required DateTime entryCreatedAt,
  required String fallbackOutletId,
}) {
  final clientUuid = rawPayload['client_uuid'];
  if (clientUuid is! String || clientUuid.isEmpty) {
    throw const FormatException('client_uuid kosong');
  }
  final outletRaw = rawPayload['outlet_id'];
  final outletId = (outletRaw is String && outletRaw.isNotEmpty)
      ? outletRaw
      : fallbackOutletId;
  final createdRaw = rawPayload['created_at'];
  // Batch C9: kirim UTC (...Z) — lihat [normalizeCreatedAtToUtc].
  final createdAt = normalizeCreatedAtToUtc(
    createdRaw is String ? createdRaw : null,
    entryCreatedAt,
  );
  if (rawPayload['is_deleted'] == true) {
    return {
      'outbox_id': outboxId,
      'kind': 'expense',
      'client_uuid': clientUuid,
      'outlet_id': outletId,
      'created_at': createdAt,
      'payload': {'is_deleted': true},
    };
  }
  final category = _asString(rawPayload['category'], 'category');
  final amount = _asNonNegInt(rawPayload['amount'], 'amount');
  if (amount == 0) throw ArgumentError('amount harus > 0: 0');
  final description = rawPayload['description'];
  final cashierName = rawPayload['cashier_name'];
  return {
    'outbox_id': outboxId,
    'kind': 'expense',
    'client_uuid': clientUuid,
    'outlet_id': outletId,
    'created_at': createdAt,
    'payload': {
      'category': category,
      'description': description is String ? description : '',
      'amount': amount,
      'is_cash': rawPayload['is_cash'] != false,
      'cashier_name': cashierName is String ? cashierName : '',
      'is_deleted': false,
    },
  };
}

/// Normalisasi event shift kas ('shift'). Upsert last-write-wins
/// by client_uuid: event buka (closed_* null, status 'open') lalu
/// event tutup (closed_* terisi, status 'closed') menimpa baris
/// yang sama. [difference] boleh negatif (kurang).
Map<String, dynamic> normalizeShiftEvent({
  required String outboxId,
  required Map<String, dynamic> rawPayload,
  required DateTime entryCreatedAt,
  required String fallbackOutletId,
}) {
  final clientUuid = rawPayload['client_uuid'];
  if (clientUuid is! String || clientUuid.isEmpty) {
    throw const FormatException('client_uuid kosong');
  }
  final outletRaw = rawPayload['outlet_id'];
  final outletId = (outletRaw is String && outletRaw.isNotEmpty)
      ? outletRaw
      : fallbackOutletId;
  final openedRaw = rawPayload['opened_at'];
  if (openedRaw is! String || openedRaw.isEmpty) {
    throw const FormatException('opened_at kosong');
  }
  final openingFloat =
      _asNonNegInt(rawPayload['opening_float'], 'opening_float');
  final statusRaw = rawPayload['status'];
  final status = statusRaw == 'closed' ? 'closed' : 'open';
  final closedRaw = rawPayload['closed_at'];
  // Batch C9: opened_at / closed_at / created_at dikirim UTC (...Z)
  // — lihat [normalizeCreatedAtToUtc]. closed_at kosong = null.
  final closedAt = closedRaw is String && closedRaw.isNotEmpty
      ? normalizeCreatedAtToUtc(closedRaw, entryCreatedAt)
      : null;
  if (status == 'closed' && closedAt == null) {
    throw const FormatException('shift closed tanpa closed_at');
  }
  final cashierName = rawPayload['cashier_name'];
  final cashierId = rawPayload['cashier_id'];
  final closedById = rawPayload['closed_by_cashier_id'];
  final closedByName = rawPayload['closed_by_cashier_name'];
  final note = rawPayload['note'];
  return {
    'outbox_id': outboxId,
    'kind': 'shift',
    'client_uuid': clientUuid,
    'outlet_id': outletId,
    'created_at': normalizeCreatedAtToUtc(openedRaw, entryCreatedAt),
    'payload': {
      'cashier_id': cashierId is String ? cashierId : '',
      'cashier_name': cashierName is String ? cashierName : '',
      'closed_by_cashier_id':
          closedById is String ? closedById : '',
      'closed_by_cashier_name':
          closedByName is String ? closedByName : '',
      'opened_at': normalizeCreatedAtToUtc(openedRaw, entryCreatedAt),
      'opening_float': openingFloat,
      'closed_at': closedAt,
      'counted_cash':
          _asNullableInt(rawPayload['counted_cash'], 'counted_cash'),
      'expected_cash':
          _asNullableInt(rawPayload['expected_cash'], 'expected_cash'),
      'difference': _asNullableInt(
        rawPayload['difference'],
        'difference',
        allowNegative: true,
      ),
      'status': status,
      'note': note is String ? note : '',
    },
  };
}

// ===================== Batch C10 — normalizer event baru =====================
// Bentuk event yang dikirim ke Edge Function `sync-sales`:
// - kind 'master': payload perubahan master-data (lihat
//   master_sync.dart — entity/id/updated_at/data/is_deleted).
// - kind 'stock_in': payload stok masuk gudang (WS1).
// - kind 'brew': payload masak teh (WS4).
// - kind 'stock_send': payload kirim ke gerai (WS3).
// - kind 'opname': payload baris opname (WS6).
// SEMUA timestamp ke server lewat [normalizeCreatedAtToUtc] (...Z)
// — aturan C9. Bentuk di bawah HARUS cocok dengan handler EF
// (supabase/functions/sync-sales/index.ts) — bila salah satu
// berubah, ubah keduanya.

Map<String, dynamic> _c10BaseEvent({
  required String outboxId,
  required String kind,
  required Map<String, dynamic> rawPayload,
  required DateTime entryCreatedAt,
}) {
  final clientUuid = rawPayload['client_uuid'];
  if (clientUuid is! String || clientUuid.isEmpty) {
    throw const FormatException('client_uuid kosong');
  }
  return {
    'outbox_id': outboxId,
    'kind': kind,
    'client_uuid': clientUuid,
    'outlet_id': rawPayload['outlet_id'] is String
        ? rawPayload['outlet_id'] as String
        : '',
    'created_at': normalizeCreatedAtToUtc(
      rawPayload['created_at'] as String?,
      entryCreatedAt,
    ),
    'payload': <String, dynamic>{},
  };
}

/// Normalizer event 'master' (Batch C10 WS0): perubahan master-data
/// (bahan/resep/topping/produk/paket/item paket/default/target).
/// Payload mentah = MasterChange.toEventPayload().
Map<String, dynamic> normalizeMasterEvent({
  required String outboxId,
  required Map<String, dynamic> rawPayload,
  required DateTime entryCreatedAt,
}) {
  final event = _c10BaseEvent(
    outboxId: outboxId,
    kind: 'master',
    rawPayload: rawPayload,
    entryCreatedAt: entryCreatedAt,
  );
  final entity = rawPayload['entity'];
  final entityId = rawPayload['entity_id'];
  final updatedRaw = rawPayload['updated_at'];
  if (entity is! String || entity.isEmpty) {
    throw const FormatException('master: entity kosong');
  }
  if (entityId is! String || entityId.isEmpty) {
    throw const FormatException('master: entity_id kosong');
  }
  if (updatedRaw is! String || updatedRaw.isEmpty) {
    throw const FormatException('master: updated_at kosong');
  }
  final data = rawPayload['data'];
  if (data is! Map) throw const FormatException('master: data bukan Map');
  (event['payload'] as Map<String, dynamic>)
    ..['entity'] = entity
    ..['entity_id'] = entityId
    ..['updated_at'] = normalizeCreatedAtToUtc(updatedRaw, entryCreatedAt)
    ..['is_deleted'] = rawPayload['is_deleted'] == true
    ..['data'] = Map<String, dynamic>.from(data);
  return event;
}

/// Normalizer event 'stock_in' (Batch C10 WS1): stok masuk gudang.
Map<String, dynamic> normalizeStockInEvent({
  required String outboxId,
  required Map<String, dynamic> rawPayload,
  required DateTime entryCreatedAt,
}) {
  final event = _c10BaseEvent(
    outboxId: outboxId,
    kind: 'stock_in',
    rawPayload: rawPayload,
    entryCreatedAt: entryCreatedAt,
  );
  final name = rawPayload['stock_name'];
  final qty = rawPayload['qty'];
  if (name is! String || name.isEmpty) {
    throw const FormatException('stock_in: stock_name kosong');
  }
  if (qty is! num || qty <= 0) {
    throw const FormatException('stock_in: qty tidak valid');
  }
  final unit = rawPayload['unit'];
  final totalPrice = rawPayload['total_price'];
  final supplier = rawPayload['supplier'];
  final note = rawPayload['note'];
  final dateRaw = rawPayload['date'];
  (event['payload'] as Map<String, dynamic>)
    ..['stock_name'] = name
    ..['unit'] = unit is String && unit.isNotEmpty ? unit : 'pcs'
    ..['qty'] = qty.toDouble()
    ..['total_price'] = totalPrice is num ? totalPrice.toInt() : 0
    ..['supplier'] = supplier is String ? supplier : ''
    ..['date'] = dateRaw is String && dateRaw.isNotEmpty
        ? normalizeCreatedAtToUtc(dateRaw, entryCreatedAt)
        : event['created_at']
    ..['note'] = note is String ? note : '';
  return event;
}

/// Normalizer event 'brew' (Batch C10 WS4): masak teh.
Map<String, dynamic> normalizeBrewEvent({
  required String outboxId,
  required Map<String, dynamic> rawPayload,
  required DateTime entryCreatedAt,
}) {
  final event = _c10BaseEvent(
    outboxId: outboxId,
    kind: 'brew',
    rawPayload: rawPayload,
    entryCreatedAt: entryCreatedAt,
  );
  final kg = rawPayload['kg_used'];
  final liters = rawPayload['liters_made'];
  if (kg is! num || kg <= 0) {
    throw const FormatException('brew: kg_used tidak valid');
  }
  if (liters is! num || liters <= 0) {
    throw const FormatException('brew: liters_made tidak valid');
  }
  final outletRaw = rawPayload['outlet_id'];
  if (outletRaw is! String || outletRaw.isEmpty) {
    throw const FormatException('brew: outlet_id kosong');
  }
  event['outlet_id'] = outletRaw;
  final brewedBy = rawPayload['brewed_by'];
  final expired = rawPayload['expired_liters'];
  (event['payload'] as Map<String, dynamic>)
    ..['kg_used'] = kg.toDouble()
    ..['liters_made'] = liters.toDouble()
    ..['brewed_at'] = normalizeCreatedAtToUtc(
      rawPayload['brewed_at'] as String?,
      entryCreatedAt,
    )
    ..['brewed_by'] = brewedBy is String ? brewedBy : 'Kasir'
    ..['expired_liters'] = expired is num ? expired.toDouble() : 0.0;
  return event;
}

/// Normalizer event 'stock_send' (Batch C10 WS3): kirim ke gerai.
Map<String, dynamic> normalizeStockSendEvent({
  required String outboxId,
  required Map<String, dynamic> rawPayload,
  required DateTime entryCreatedAt,
}) {
  final event = _c10BaseEvent(
    outboxId: outboxId,
    kind: 'stock_send',
    rawPayload: rawPayload,
    entryCreatedAt: entryCreatedAt,
  );
  final outletRaw = rawPayload['outlet_id'];
  if (outletRaw is! String || outletRaw.isEmpty) {
    throw const FormatException('stock_send: outlet_id kosong');
  }
  event['outlet_id'] = outletRaw;
  final itemsRaw = rawPayload['items'];
  if (itemsRaw is! List || itemsRaw.isEmpty) {
    throw const FormatException('stock_send: items kosong');
  }
  final items = <Map<String, dynamic>>[];
  for (final it in itemsRaw) {
    if (it is! Map) throw const FormatException('stock_send: item bukan Map');
    final name = it['stock_name'];
    final qty = it['qty'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('stock_send: item tanpa nama');
    }
    if (qty is! num || qty <= 0) {
      throw const FormatException('stock_send: item qty tidak valid');
    }
    final unit = it['unit'];
    items.add({
      'stock_name': name,
      'qty': qty.toDouble(),
      'unit': unit is String && unit.isNotEmpty ? unit : 'pcs',
    });
  }
  final packageId = rawPayload['package_id'];
  final packageName = rawPayload['package_name'];
  final sentBy = rawPayload['sent_by'];
  final note = rawPayload['note'];
  (event['payload'] as Map<String, dynamic>)
    ..['package_id'] = packageId is String ? packageId : null
    ..['package_name'] = packageName is String ? packageName : ''
    ..['sent_at'] = normalizeCreatedAtToUtc(
      rawPayload['sent_at'] as String?,
      entryCreatedAt,
    )
    ..['sent_by'] = sentBy is String ? sentBy : 'Owner'
    ..['note'] = note is String ? note : ''
    ..['items'] = items;
  return event;
}

/// Normalizer event 'opname' (Batch C10 WS6): satu baris opname.
Map<String, dynamic> normalizeOpnameEvent({
  required String outboxId,
  required Map<String, dynamic> rawPayload,
  required DateTime entryCreatedAt,
}) {
  final event = _c10BaseEvent(
    outboxId: outboxId,
    kind: 'opname',
    rawPayload: rawPayload,
    entryCreatedAt: entryCreatedAt,
  );
  final outletRaw = rawPayload['outlet_id'];
  if (outletRaw is! String || outletRaw.isEmpty) {
    throw const FormatException('opname: outlet_id kosong');
  }
  event['outlet_id'] = outletRaw;
  final name = rawPayload['stock_name'];
  final systemQty = rawPayload['system_qty'];
  final physicalQty = rawPayload['physical_qty'];
  if (name is! String || name.isEmpty) {
    throw const FormatException('opname: stock_name kosong');
  }
  if (systemQty is! num || systemQty < 0) {
    throw const FormatException('opname: system_qty tidak valid');
  }
  if (physicalQty is! num || physicalQty < 0) {
    throw const FormatException('opname: physical_qty tidak valid');
  }
  final countedBy = rawPayload['counted_by'];
  final note = rawPayload['note'];
  (event['payload'] as Map<String, dynamic>)
    ..['stock_name'] = name
    ..['system_qty'] = systemQty.toDouble()
    ..['physical_qty'] = physicalQty.toDouble()
    ..['difference'] = physicalQty.toDouble() - systemQty.toDouble()
    ..['counted_at'] = normalizeCreatedAtToUtc(
      rawPayload['counted_at'] as String?,
      entryCreatedAt,
    )
    ..['counted_by'] = countedBy is String ? countedBy : 'Owner'
    ..['note'] = note is String ? note : ''
    ..['adjusted'] = rawPayload['adjusted'] == true;
  return event;
}

/// Satu shift dari server (pull) — ringkasan untuk gate POS +
/// kartu "Kas & Shift" (Batch C8.2 WS6). [cashierName] = PEMBUKA
/// shift; [closedByCashierName] = PENUTUP (terisi bila closed).
/// [countedCash]/[expectedCash]/[difference] = hitungan laci saat
/// tutup (Batch C9 — null selama open; dipakai riwayat shift tutup
/// antar device supaya tidak tampil Rp0).
typedef ShiftSummary = ({
  String clientUuid,
  String outletId,
  String cashierId,
  String cashierName,
  DateTime openedAt,
  int openingFloat,
  String status,
  DateTime? closedAt,
  String closedByCashierId,
  String closedByCashierName,
  int? countedCash,
  int? expectedCash,
  int? difference,
});

/// Parse daftar shift mentah dari jawaban pull EF — entri rusak
/// (tanpa client_uuid / opened_at tidak bisa diparse) dilewati,
/// bukan gagal total. Bukan list / kosong -> list kosong.
List<ShiftSummary> parseShiftSummaries(dynamic raw) {
  if (raw is! List) return const <ShiftSummary>[];
  final list = <ShiftSummary>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final clientUuid = entry['client_uuid'];
    final openedRaw = entry['opened_at'];
    if (clientUuid is! String || clientUuid.isEmpty) continue;
    final openedAt =
        openedRaw is String ? DateTime.tryParse(openedRaw) : null;
    if (openedAt == null) continue;
    final outletId = entry['outlet_id'];
    final cashierId = entry['cashier_id'];
    final cashierName = entry['cashier_name'];
    final openingFloat = entry['opening_float'];
    final status = entry['status'];
    final closedRaw = entry['closed_at'];
    final closedById = entry['closed_by_cashier_id'];
    final closedByName = entry['closed_by_cashier_name'];
    final countedCash = entry['counted_cash'];
    final expectedCash = entry['expected_cash'];
    final difference = entry['difference'];
    list.add((
      clientUuid: clientUuid,
      outletId: outletId is String ? outletId : '',
      cashierId: cashierId is String ? cashierId : '',
      cashierName: cashierName is String ? cashierName : '',
      openedAt: openedAt,
      openingFloat: openingFloat is num ? openingFloat.toInt() : 0,
      status: status is String ? status : 'open',
      closedAt: closedRaw is String ? DateTime.tryParse(closedRaw) : null,
      closedByCashierId: closedById is String ? closedById : '',
      closedByCashierName: closedByName is String ? closedByName : '',
      countedCash: countedCash is num ? countedCash.toInt() : null,
      expectedCash: expectedCash is num ? expectedCash.toInt() : null,
      difference: difference is num ? difference.toInt() : null,
    ));
  }
  return list;
}

/// Pemenang dedupe shift (Batch C8.2 WS6): bila 2 device membuka
/// shift offline di gerai yang sama, yang dipertahankan server =
/// yang opened_at PALING AWAL; seri -> client_uuid paling kecil
/// (deterministik, sama di semua device).
ShiftSummary resolveShiftWinner(ShiftSummary a, ShiftSummary b) {
  if (a.openedAt.isBefore(b.openedAt)) return a;
  if (b.openedAt.isBefore(a.openedAt)) return b;
  return a.clientUuid.compareTo(b.clientUuid) <= 0 ? a : b;
}

/// Shift server mana (bila ada) yang harus diadopsi app sesudah pull
/// (Batch C8.2 WS6). Aturan:
/// - tidak ada shift server -> null (tidak ada yang diadopsi).
/// - tidak ada shift lokal terbuka -> adopsi pemenang server.
/// - shift lokal == shift server (client_uuid sama) -> null.
/// - event buka lokal masih PENDING (belum terkirim) -> null:
///   server belum tahu shift lokal, jadi jangan buang dulu — dedupe
///   diputuskan server saat event itu terkirim.
/// - event buka lokal sudah terkirim + pemenang server lebih awal
///   dari lokal -> adopsi pemenang server (lokal kalah dedupe).
/// - lokal lebih awal -> null (server akan mengadopsi lokal saat
///   event terkirim / sudah mengadopsi).
ShiftSummary? pickAdoptedShift({
  ShiftSummary? localOpen,
  bool localPending = false,
  required List<ShiftSummary> serverOpens,
}) {
  if (serverOpens.isEmpty) return null;
  final serverWinner = serverOpens.reduce(resolveShiftWinner);
  if (localOpen == null) return serverWinner;
  if (localOpen.clientUuid == serverWinner.clientUuid) return null;
  if (localPending) return null;
  final winner = resolveShiftWinner(localOpen, serverWinner);
  return winner == serverWinner ? serverWinner : null;
}

/// Hasil push shift yang kena dedupe server (Batch C8.2 WS6):
/// event buka lokal ditolak karena shift lain lebih awal — app harus
/// mengadopsi shift [existingClientUuid] itu dan membuang duplikat
/// lokalnya (lihat CashShiftService.adoptServerShift).
/// [localClientUuid] = id shift lokal yang ditolak — TIDAK dikirim
/// server, diisi pemanggil (flushOutboxEntries) dari event yang
/// dikirim; '' bila tidak diketahui (adopsi dilewati).
typedef ShiftAdoption = ({
  String outboxId,
  String existingClientUuid,
  DateTime existingOpenedAt,
  String existingCashierName,
  String existingCashierId,
  int existingOpeningFloat,
  String localClientUuid,
});

/// Parse jawaban aksi 'shift_expected' EF: expected kas server =
/// cash_in (semua transaksi tunai gerai itu di jendela) dikurangi
/// cash_out (pengeluaran tunai gerai itu di jendela). null = jawaban
/// rusak / gagal — pemanggil memakai hitungan lokal berlabel
/// "perkiraan (offline)".
({int cashIn, int cashOut})? parseShiftExpectedResponse(dynamic data) {
  if (data is! Map) return null;
  if (data['ok'] != true) return null;
  final cashIn = data['cash_in'];
  final cashOut = data['cash_out'];
  if (cashIn is! num || cashOut is! num) return null;
  return (cashIn: cashIn.toInt(), cashOut: cashOut.toInt());
}

/// Satu mutasi stok dari server (pull) — riwayat keluar-masuk
/// barang per gerai (Batch C9 WS6). [clientUuid] = client_uuid event
/// asal (satu event bisa punya beberapa item — kunci dedupe =
/// clientUuid + nama, lihat SyncService.refreshSales).
/// [pending] = mutasi lokal yang masih antre di outbox (belum
/// terkirim) — tampil dengan label 'menunggu kirim'.
typedef StockMovement = ({
  String clientUuid,
  String outletId,
  String name,
  double qtyDelta,
  String reason,
  DateTime createdAt,
  bool pending,
});

/// Parse daftar mutasi mentah dari jawaban pull EF — entri rusak
/// (tanpa client_uuid / nama / qty_delta) dilewati, bukan gagal
/// total. Bukan list / kosong -> list kosong. Nama diambil dari
/// `name` atau relasi `stock_items.name` (bentuk join Supabase).
/// created_at diparse ke waktu LOKAL (server mengirim UTC).
List<StockMovement> parseStockMovements(dynamic raw, String outletId) {
  if (raw is! List) return const <StockMovement>[];
  final list = <StockMovement>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final clientUuid = entry['client_uuid'];
    if (clientUuid is! String || clientUuid.isEmpty) continue;
    var name = entry['name'];
    if (name is! String || name.isEmpty) {
      final joined = entry['stock_items'];
      if (joined is Map) name = joined['name'];
    }
    if (name is! String || name.isEmpty) continue;
    final delta = entry['qty_delta'];
    if (delta is! num) continue;
    final createdRaw = entry['created_at'];
    final createdAt = createdRaw is String
        ? DateTime.tryParse(createdRaw)?.toLocal()
        : null;
    if (createdAt == null) continue;
    final reason = entry['reason'];
    list.add((
      clientUuid: clientUuid,
      outletId: outletId,
      name: name,
      qtyDelta: delta.toDouble(),
      reason: reason is String && reason.isNotEmpty ? reason : 'penjualan',
      createdAt: createdAt,
      pending: false,
    ));
  }
  return list;
}

/// Hasil pull yang sudah divalidasi: daftar transaksi mentah (Map)
/// + item dikelompokkan per client_uuid transaksi + level stok
/// gerai yang diminta (Batch C8.2 WS5 — mentah, dipetakan pemanggil)
/// + shift terbuka gerai itu (Batch C8.2 WS6).
/// Batch C10: + [masterChanges] (perubahan master-data mentah,
/// WS0 — dipetakan pemanggil ke MasterChange), + [sends] (kiriman
/// ke gerai itu, WS3), + [opnames] (baris opname gerai itu, WS6),
/// + [stockIns] (stok masuk gudang — hanya bila pull gudang, WS1),
/// + [brews] (riwayat masak gerai itu, WS4). Yang hilang (EF lama
/// / jawaban lama) = list kosong, BUKAN error — pull lama tetap
/// jalan.
typedef PullData = ({
  List<Map<String, dynamic>> transactions,
  Map<String, List<Map<String, dynamic>>> itemsByClientUuid,
  List<Map<String, dynamic>> stock,
  List<ShiftSummary> shifts,
  List<Map<String, dynamic>> expenses,
  List<ShiftSummary> closedShifts,
  List<StockMovement> movements,
  List<Map<String, dynamic>> masterChanges,
  List<Map<String, dynamic>> sends,
  List<Map<String, dynamic>> opnames,
  List<Map<String, dynamic>> stockIns,
  List<Map<String, dynamic>> brews,
});

List<Map<String, dynamic>> _asMapList(dynamic raw) {
  final list = <Map<String, dynamic>>[];
  if (raw is! List) return list;
  for (final e in raw) {
    if (e is Map<String, dynamic>) {
      list.add(e);
    } else if (e is Map) {
      list.add(Map<String, dynamic>.from(e));
    }
  }
  return list;
}

/// Validasi jawaban pull EF. Throw [FormatException] bila jawaban
/// tidak sesuai bentuk (bukan Map / ok != true / list hilang).
PullData parsePullResponse(dynamic data) {
  if (data is! Map) throw const FormatException('jawaban pull bukan Map');
  if (data['ok'] != true) {
    final err = data['error'];
    throw FormatException(
      err is String && err.isNotEmpty ? err : 'pull gagal (ok != true)',
    );
  }
  final txnsRaw = data['transactions'];
  if (txnsRaw is! List) {
    throw const FormatException('pull: transactions bukan list');
  }
  final transactions = <Map<String, dynamic>>[];
  for (final t in txnsRaw) {
    if (t is Map<String, dynamic>) {
      transactions.add(t);
    } else if (t is Map) {
      transactions.add(Map<String, dynamic>.from(t));
    } else {
      throw const FormatException('pull: satu transaksi bukan Map');
    }
  }
  final itemsRaw = data['items'];
  if (itemsRaw is! List) {
    throw const FormatException('pull: items bukan list');
  }
  final byUuid = <String, List<Map<String, dynamic>>>{};
  for (final it in itemsRaw) {
    if (it is! Map) {
      throw const FormatException('pull: satu item bukan Map');
    }
    final item =
        it is Map<String, dynamic> ? it : Map<String, dynamic>.from(it);
    final key = item['transaction_client_uuid'] as String? ?? '';
    if (key.isEmpty) continue;
    (byUuid[key] ??= <Map<String, dynamic>>[]).add(item);
  }
  final stockRaw = data['stock'];
  final stock = <Map<String, dynamic>>[];
  if (stockRaw is List) {
    for (final s in stockRaw) {
      if (s is Map<String, dynamic>) {
        stock.add(s);
      } else if (s is Map) {
        stock.add(Map<String, dynamic>.from(s));
      }
    }
  }
  final shifts = parseShiftSummaries(data['shifts']);
  final expensesRaw = data['expenses'];
  final expenses = <Map<String, dynamic>>[];
  if (expensesRaw is List) {
    for (final e in expensesRaw) {
      if (e is Map<String, dynamic>) {
        expenses.add(e);
      } else if (e is Map) {
        expenses.add(Map<String, dynamic>.from(e));
      }
    }
  }
  final closedShifts = parseShiftSummaries(data['closed_shifts']);
  final outletId = data['outlet_id'];
  final movements = parseStockMovements(
    data['movements'],
    outletId is String ? outletId : '',
  );
  return (
    transactions: transactions,
    itemsByClientUuid: byUuid,
    stock: stock,
    shifts: shifts,
    expenses: expenses,
    closedShifts: closedShifts,
    movements: movements,
    masterChanges: _asMapList(data['master_changes']),
    sends: _asMapList(data['sends']),
    opnames: _asMapList(data['opnames']),
    stockIns: _asMapList(data['stock_ins']),
    brews: _asMapList(data['brews']),
  );
}

/// Terjemahkan jawaban push EF ke id outbox yang boleh ditandai
/// terkirim. `events` = event yang dikirim (bawa outbox_id).
/// `alreadyFailed` = id yang sudah gagal di tahap normalisasi.
/// Jawaban rusak / bukan Map / ok != true = SEMUA event dianggap
/// gagal (jangan tandai terkirim tanpa konfirmasi server).
/// [shiftAdoptions] = event shift yang kena dedupe server (Batch
/// C8.2 WS6) — event-nya tetap terhitung terkirim (sudah diproses),
/// tapi app harus mengadopsi shift server itu (lihat
/// CashShiftService.adoptServerShift).
/// [failedErrors] (Batch C10 WS3) = outbox_id -> error server
/// (mis. 'gudang_kurang') — dipakai SyncService untuk membalik
/// kiriman yang ditolak server + memberi tahu Owner.
typedef PushOutcome = ({
  List<String> sentIds,
  List<String> failedIds,
  List<ShiftAdoption> shiftAdoptions,
  Map<String, String> failedErrors,
});

PushOutcome applyPushResults(
  List<Map<String, dynamic>> events,
  dynamic data, [
  List<String> alreadyFailed = const <String>[],
]) {
  final allIds = events.map((e) => e['outbox_id'] as String).toList();
  final failed = <String>[...alreadyFailed];
  const noAdoptions = <ShiftAdoption>[];
  const noErrors = <String, String>{};
  if (data is! Map || data['ok'] != true) {
    failed.addAll(allIds);
    return (
      sentIds: const <String>[],
      failedIds: failed,
      shiftAdoptions: noAdoptions,
      failedErrors: noErrors,
    );
  }
  final results = data['results'];
  if (results is! List) {
    failed.addAll(allIds);
    return (
      sentIds: const <String>[],
      failedIds: failed,
      shiftAdoptions: noAdoptions,
      failedErrors: noErrors,
    );
  }
  final okIds = <String>{};
  final failedErrors = <String, String>{};
  for (final r in results) {
    if (r is! Map) continue;
    final id = r['outbox_id'];
    if (id is! String) continue;
    if (r['ok'] == true) {
      okIds.add(id);
    } else {
      final err = r['error'];
      if (err is String && err.isNotEmpty) failedErrors[id] = err;
    }
  }
  final sent = allIds.where(okIds.contains).toList();
  failed.addAll(allIds.where((id) => !okIds.contains(id)));
  final adoptions = <ShiftAdoption>[];
  final adoptionsRaw = data['shift_adoptions'];
  if (adoptionsRaw is List) {
    for (final a in adoptionsRaw) {
      if (a is! Map) continue;
      final outboxId = a['outbox_id'];
      final existingUuid = a['existing_client_uuid'];
      final existingOpened = a['existing_opened_at'];
      if (outboxId is! String ||
          existingUuid is! String ||
          existingUuid.isEmpty) {
        continue;
      }
      final openedAt = existingOpened is String
          ? DateTime.tryParse(existingOpened)
          : null;
      if (openedAt == null) continue;
      final existingName = a['existing_cashier_name'];
      final existingId = a['existing_cashier_id'];
      final existingFloat = a['existing_opening_float'];
      adoptions.add((
        outboxId: outboxId,
        existingClientUuid: existingUuid,
        existingOpenedAt: openedAt,
        existingCashierName: existingName is String ? existingName : '',
        existingCashierId: existingId is String ? existingId : '',
        existingOpeningFloat:
            existingFloat is num ? existingFloat.toInt() : 0,
        localClientUuid: '',
      ));
    }
  }
  return (
    sentIds: sent,
    failedIds: failed,
    shiftAdoptions: adoptions,
    failedErrors: failedErrors,
  );
}
