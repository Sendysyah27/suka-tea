import 'dart:math';

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
  final createdAt = (createdRaw is String && createdRaw.isNotEmpty)
      ? createdRaw
      : entryCreatedAt.toIso8601String();
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
/// outlet_id SELALU gerai utama (stok itu SATU shared, bukan
/// per-gerai — lihat laporan C6); payload lama tanpa outlet_id
/// jatuh ke [fallbackOutletId].
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
    items.add({
      'name': _asString(raw['name'], 'item.name'),
      'unit': raw['unit'] is String ? raw['unit'] as String : 'pcs',
      'qty_after': _asNumber(raw['qty_after'], 'item.qty_after'),
      'low_threshold': raw.containsKey('low_threshold')
          ? _asNumber(raw['low_threshold'], 'item.low_threshold')
          : 0.0,
      'cost_per_unit': raw.containsKey('cost_per_unit')
          ? _asNonNegInt(raw['cost_per_unit'], 'item.cost_per_unit')
          : 0,
      'delta': _asNumber(raw['delta'], 'item.delta'),
    });
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
  final createdAt = (createdRaw is String && createdRaw.isNotEmpty)
      ? createdRaw
      : entryCreatedAt.toIso8601String();
  final reasonRaw = rawPayload['reason'];
  final reason = reasonRaw is String &&
          (reasonRaw == 'penjualan' || reasonRaw == 'void')
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
  final createdAt = (createdRaw is String && createdRaw.isNotEmpty)
      ? createdRaw
      : entryCreatedAt.toIso8601String();
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
  final closedAt =
      closedRaw is String && closedRaw.isNotEmpty ? closedRaw : null;
  if (status == 'closed' && closedAt == null) {
    throw const FormatException('shift closed tanpa closed_at');
  }
  final cashierName = rawPayload['cashier_name'];
  final note = rawPayload['note'];
  return {
    'outbox_id': outboxId,
    'kind': 'shift',
    'client_uuid': clientUuid,
    'outlet_id': outletId,
    'created_at': openedRaw,
    'payload': {
      'cashier_name': cashierName is String ? cashierName : '',
      'opened_at': openedRaw,
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

/// Hasil pull yang sudah divalidasi: daftar transaksi mentah (Map)
/// + item dikelompokkan per client_uuid transaksi.
typedef PullData = ({
  List<Map<String, dynamic>> transactions,
  Map<String, List<Map<String, dynamic>>> itemsByClientUuid,
});

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
  return (transactions: transactions, itemsByClientUuid: byUuid);
}

/// Terjemahkan jawaban push EF ke id outbox yang boleh ditandai
/// terkirim. `events` = event yang dikirim (bawa outbox_id).
/// `alreadyFailed` = id yang sudah gagal di tahap normalisasi.
/// Jawaban rusak / bukan Map / ok != true = SEMUA event dianggap
/// gagal (jangan tandai terkirim tanpa konfirmasi server).
typedef PushOutcome = ({List<String> sentIds, List<String> failedIds});

PushOutcome applyPushResults(
  List<Map<String, dynamic>> events,
  dynamic data, [
  List<String> alreadyFailed = const <String>[],
]) {
  final allIds = events.map((e) => e['outbox_id'] as String).toList();
  final failed = <String>[...alreadyFailed];
  if (data is! Map || data['ok'] != true) {
    failed.addAll(allIds);
    return (sentIds: const <String>[], failedIds: failed);
  }
  final results = data['results'];
  if (results is! List) {
    failed.addAll(allIds);
    return (sentIds: const <String>[], failedIds: failed);
  }
  final okIds = <String>{};
  for (final r in results) {
    if (r is Map && r['ok'] == true) {
      final id = r['outbox_id'];
      if (id is String) okIds.add(id);
    }
  }
  final sent = allIds.where(okIds.contains).toList();
  failed.addAll(allIds.where((id) => !okIds.contains(id)));
  return (sentIds: sent, failedIds: failed);
}
