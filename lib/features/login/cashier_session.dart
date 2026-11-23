import 'package:flutter/foundation.dart';

import '../../data/local/app_database.dart';

/// Batas idle untuk auto-lock kasir (Batch C5): 15 menit tanpa
/// interaksi apa pun di app → layar PIN Kasir gerai aktif.
const Duration kCashierIdleLimit = Duration(minutes: 15);

/// Murni + bisa di-test: true bila sudah waktunya auto-lock, yaitu
/// selisih [now] − [lastActive] sudah mencapai [idle].
bool shouldAutoLock({
  required DateTime lastActive,
  required DateTime now,
  Duration idle = kCashierIdleLimit,
}) =>
    now.difference(lastActive) >= idle;

/// Sesi kasir persisten (Batch C5).
///
/// Sesudah kasir login berhasil, outlet + nama kasir disimpan lokal
/// di tabel Drift `CashierSessions` (satu baris, id 'current').
/// Buka app lagi → _LoginGate membaca sesi ini dan langsung masuk
/// menu utama gerai itu TANPA login ulang.
///
/// Sesi Owner TIDAK PERNAH disimpan — Owner selalu minta PIN tiap
/// kali masuk Owner. Keluar gerai (tombol di Laporan / auto-lock
/// yang dibatalkan) menghapus baris ini.
///
/// `lastActive` (in-memory) = waktu interaksi terakhir; dipakai
/// auto-lock 15 menit. Reset di tiap interaksi (Listener PointerDown
/// di shell) + saat transaksi selesai. Nilainya TIDAK disimpan ke
/// database — sesudah app dibuka lagi, sesi langsung dianggap aktif
/// (jam idle mulai dari saat restore).
class CashierSessionService extends ChangeNotifier {
  CashierSessionService._();
  static final CashierSessionService instance = CashierSessionService._();

  AppDatabase? _db;
  String? _outletId;
  String? _cashierName;
  DateTime _lastActive = DateTime.now();

  String? get outletId => _outletId;
  String? get cashierName => _cashierName;
  bool get hasSession => _outletId != null;
  DateTime get lastActive => _lastActive;

  Future<void> init() async {
    _db ??= AppDatabase();
    final row = await (_db!.select(_db!.cashierSessions)
          ..where((t) => t.id.equals('current')))
        .getSingleOrNull();
    _outletId = row?.outletId;
    _cashierName = row?.cashierName;
    _lastActive = DateTime.now();
    notifyListeners();
  }

  Future<void> save({
    required String outletId,
    required String cashierName,
  }) async {
    // Isi field in-memory DULU sebelum tulis DB: _handleSuccess
    // memanggil save() tanpa await lalu langsung onSuccess — gate
    // yang membaca hasSession sesudah itu harus sudah melihat sesi,
    // dan sesi tetap ada di memori walau tulis DB gagal (review C5 W2).
    _outletId = outletId;
    _cashierName = cashierName;
    _lastActive = DateTime.now();
    _db ??= AppDatabase();
    await _db!.into(_db!.cashierSessions).insertOnConflictUpdate(
          CashierSessionsCompanion.insert(
            id: 'current',
            outletId: outletId,
            cashierName: cashierName,
          ),
        );
    notifyListeners();
  }

  Future<void> clear() async {
    _db ??= AppDatabase();
    await (_db!.delete(_db!.cashierSessions)
          ..where((t) => t.id.equals('current')))
        .go();
    _outletId = null;
    _cashierName = null;
    _lastActive = DateTime.now();
    notifyListeners();
  }

  /// Catat interaksi (tap) — dipanggil dari Listener PointerDown
  /// di root shell dan saat transaksi selesai.
  void touch() {
    _lastActive = DateTime.now();
  }
}
