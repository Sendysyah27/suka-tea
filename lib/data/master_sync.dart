import 'sync_payload.dart';

/// Sinkronisasi master-data (Batch C10 WS0, MURNI).
///
/// Master-data = konfigurasi yang Owner ubah dan HARUS sama di semua
/// HP: bahan (nama/satuan/harga/ambang/shelfLife), resep, topping,
/// produk, paket, paket default per gerai, target omzet.
/// SEMUA perubahan master-data diantrekan ke outbox kind 'master'
/// (satu kind, field `entity` di payload) + syncNow — jadi perubahan
/// di HP Owner sampai ke HP kasir dalam hitungan detik (timer 10 dtk
/// C9), dan perubahan offline tersinkron saat online tanpa dobel.
///
/// ATURAN KONFLIK (dikunci brief §3): last-write-wins by updated_at
/// (UTC); seri -> id (client_uuid) yang lebih besar menang. Pull
/// TIDAK PERNAH menimpa perubahan lokal yang masih punya event
/// 'master' pending untuk kunci yang sama (perubahan lokal yang
/// belum terkirim selalu menang sampai server mengonfirmasinya).

/// Entitas master-data (nilai field `entity` di event outbox).
class MasterEntity {
  static const String package = 'package';
  static const String packageItem = 'package_item';
  static const String packageDefault = 'package_default';
  static const String recipe = 'recipe';
  static const String topping = 'topping';
  static const String product = 'product';
  static const String target = 'target';
  static const String stockItemConfig = 'stock_item_config';
}

/// Satu perubahan master-data (satu entitas, satu kunci merge).
class MasterChange {
  const MasterChange({
    required this.entity,
    required this.id,
    required this.updatedAt,
    required this.data,
    this.isDeleted = false,
  });

  /// Entitas (lihat [MasterEntity]).
  final String entity;

  /// Kunci merge — id entitas, atau kunci gabung:
  /// - recipe: '$variantId|$stockName'
  /// - stock_item_config: '$outletId|$stockName'
  /// - package_default / target: outletId
  /// - lainnya: id entitas (UUID v4 / id lokal).
  final String id;

  /// UTC — penentu last-write-wins.
  final DateTime updatedAt;

  /// Payload lengkap entitas (Map — bentuk bebas per entitas,
  /// dibaca pemanggil).
  final Map<String, dynamic> data;

  /// true = entitas dihapus (nonaktif + is_deleted di server —
  /// baris lokal ikut dihapus/dinonaktifkan saat merge).
  final bool isDeleted;

  /// Payload outbox kind 'master' untuk perubahan ini.
  /// client_uuid = [id] (stabil — server menormalkannya bila bukan
  /// UUID, dan upsert memakai (entity, id) sebagai kunci).
  Map<String, Object?> toEventPayload() => {
        'client_uuid': id,
        'entity': entity,
        'entity_id': id,
        'updated_at': toUtcIsoString(updatedAt),
        'is_deleted': isDeleted,
        'data': data,
      };

  /// Rekonstruksi dari baris pull server (Map mentah EF).
  factory MasterChange.fromServer(Map<String, dynamic> row) {
    final entity = row['entity'] as String? ?? '';
    final id = row['id'] as String? ?? '';
    final updatedRaw = row['updated_at'];
    final updatedAt = updatedRaw is String
        ? DateTime.tryParse(updatedRaw)?.toUtc() ?? DateTime.now().toUtc()
        : DateTime.now().toUtc();
    final dataRaw = row['data'];
    final data = dataRaw is Map<String, dynamic>
        ? dataRaw
        : dataRaw is Map
            ? Map<String, dynamic>.from(dataRaw)
            : <String, dynamic>{};
    return MasterChange(
      entity: entity,
      id: id,
      updatedAt: updatedAt,
      data: data,
      isDeleted: row['is_deleted'] == true,
    );
  }
}

/// Rencana merge master-data server -> lokal (Batch C10 WS0, MURNI).
/// [serverChanges] = semua perubahan master dari pull (server
/// mengembalikan SEMUA baris master — tanpa jendela waktu).
/// [localUpdatedAt] = updatedAt lokal per kunci ('$entity|$id');
/// null = kunci belum ada lokal (server menang).
/// [pendingKeys] = kunci ('$entity|$id') yang masih punya event
/// 'master' pending di outbox HP ini — pull TIDAK PERNAH menimpa
/// kunci ini (perubahan lokal belum terkirim selalu menang).
/// Kembalikan perubahan server yang HARUS diterapkan pemanggil
/// (upsert bila !isDeleted, hapus/nonaktifkan bila isDeleted).
/// Perubahan server yang kalah (lebih lama / sama dengan lokal,
/// atau pending) dilewati diam-diam — bukan error.
/// CATATAN SERI: kunci merge yang sama = entitas yang sama = id
/// yang sama, jadi tidak ada "client_uuid lebih besar" untuk
/// dibandingkan di sini (aturan tie-break brief §3 tidak bisa
/// diterapkan antar kunci yang sama — edit berikutnya menang
/// lewat timestamp yang lebih baru). Seri = pertahankan lokal.
List<MasterChange> planMasterMerge({
  required List<MasterChange> serverChanges,
  required Map<String, DateTime> localUpdatedAt,
  required Set<String> pendingKeys,
}) {
  final out = <MasterChange>[];
  for (final change in serverChanges) {
    final key = '${change.entity}|${change.id}';
    if (pendingKeys.contains(key)) continue;
    final local = localUpdatedAt[key];
    if (local == null) {
      out.add(change);
      continue;
    }
    if (change.updatedAt.isAfter(local)) out.add(change);
  }
  return out;
}

/// Kunci pending outbox untuk satu perubahan master
/// ('$entity|$id' — bentuk yang sama dengan [planMasterMerge]).
String masterPendingKey(String entity, String id) => '$entity|$id';

/// Kunci merge satu baris resep: '$variantId|$stockName'.
String recipeMergeKey(String variantId, String stockName) =>
    '$variantId|$stockName';

/// Kunci merge satu konfigurasi bahan: '$outletId|$stockName'.
String stockConfigMergeKey(String outletId, String stockName) =>
    '$outletId|$stockName';
