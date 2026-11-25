import 'package:drift/drift.dart';
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

/// Izin kasir sesi ini dari server (verify saat login / blok
/// `cashier` di jawaban pull). Didefinisikan di sini (bukan di
/// cashier_service.dart) supaya tidak ada import melingkar:
/// cashier_service.dart sudah mengimpor file ini.
/// Field hilang = default perilaku lama (semua boleh, tidak
/// dibatasi — server lama belum mengirimnya, brief v40 §2.1 poin 4).
typedef CashierPermissions = ({
  bool canVoid,
  bool canDiscount,
  bool canCloseShift,
  bool forcePinChange,
  List<String> allowedOutletIds,
});

/// Default izin = perilaku lama (semua boleh, tidak dibatasi).
const CashierPermissions kDefaultCashierPermissions = (
  canVoid: true,
  canDiscount: true,
  canCloseShift: true,
  forcePinChange: false,
  allowedOutletIds: <String>[],
);

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
  String? _cashierId;
  String? _cashierName;
  DateTime _lastActive = DateTime.now();

  String? get outletId => _outletId;

  /// UUID kasir dari server (tabel `cashiers`) — identitas pencatat
  /// penjualan (Batch C8.2). Null = sesi lama (sebelum C8.2) / Owner.
  String? get cashierId => _cashierId;
  String? get cashierName => _cashierName;
  bool get hasSession => _outletId != null;
  DateTime get lastActive => _lastActive;

  // ---- Bukti PIN sesi (SEC-1 R-02) ----
  // HANYA di memori proses ini — TIDAK PERNAH ditulis ke Drift /
  // SharedPreferences / file. Dipakai SyncService untuk melampirkan
  // `owner_pin` / `cashier_pin` ke setiap panggilan sync-sales.
  // Dihapus saat logout, lock, ganti peran, atau app ditutup.
  String? _ownerPin;
  String? _cashierPin;

  // ---- Izin kasir sesi ini (v40) ----
  // Dari server: verify saat login + blok `cashier` di jawaban pull
  // tiap 10 detik. HANYA memori (sama seperti PIN bukti) — TIDAK
  // PERNAH ditulis ke Drift: sumber kebenaran izin adalah server,
  // dan sesi restore tanpa PIN memang tidak boleh jualan sampai
  // PIN dimasukkan ulang (saat itu izin dimuat segar dari verify).
  // null = BELUM DIKETAHUI (sesi restore) → semua gate fail closed
  // (tidak diizinkan) sampai login ulang.
  bool? _canVoid;
  bool? _canDiscount;
  bool? _canCloseShift;
  List<String>? _allowedOutletIds;
  bool _forcePinChange = false;

  /// Pesan paksa keluar (v40): diisi `markKicked()`, dibaca SEKALI
  /// oleh LoginPage sesudah sesi hilang (lalu null). null = tidak
  /// ada kick.
  String? _kickNotice;

  /// Izin kasir dari server (verify login / pull segar).
  void applyPermissions(CashierPermissions permissions) {
    _canVoid = permissions.canVoid;
    _canDiscount = permissions.canDiscount;
    _canCloseShift = permissions.canCloseShift;
    _allowedOutletIds = List.unmodifiable(permissions.allowedOutletIds);
    _forcePinChange = permissions.forcePinChange;
    notifyListeners();
  }

  /// true = izin sudah dimuat dari server (login segar / pull segar).
  bool get permissionsKnown => _canVoid != null;

  /// Fail closed: belum diketahui = tidak diizinkan.
  bool get canVoid => _canVoid ?? false;
  bool get canDiscount => _canDiscount ?? false;
  bool get canCloseShift => _canCloseShift ?? false;
  bool get forcePinChange => _forcePinChange;

  /// true bila kasir boleh login di gerai ini. Izin belum diketahui
  /// (null) = true — gate sebenarnya ada di SERVER (sync proof
  /// menolak gerai yang tidak diizinkan), jadi fail-open di sini
  /// tidak membuka jalan masuk; sesi restore tanpa PIN tidak bisa
  /// jualan anyway (sync ditahan sampai PIN masuk lagi).
  bool isOutletAllowed(String outletId) {
    final allowed = _allowedOutletIds;
    if (allowed == null || allowed.isEmpty) return true;
    return allowed.contains(outletId);
  }

  /// Paksa keluar sesi ini (v40 — Owner kick / gerai dicabut):
  /// baris sesi Drift ikut dihapus (supaya sesi tidak bangkit lagi
  /// saat app dibuka ulang) + bukti PIN + izin dihapus + pesan
  /// sekali untuk LoginPage.
  Future<void> markKicked() async {
    _kickNotice =
        'Anda dipaksa keluar oleh Owner. Login ulang dengan PIN.';
    await clear();
  }

  /// Baca pesan kick sekali (sesudah dibaca, null).
  String? consumeKickNotice() {
    final notice = _kickNotice;
    _kickNotice = null;
    return notice;
  }

  void _resetPermissions() {
    _canVoid = null;
    _canDiscount = null;
    _canCloseShift = null;
    _allowedOutletIds = null;
    _forcePinChange = false;
  }

  /// Ingat PIN Owner sesudah unlock berhasil (memori saja).
  void rememberOwnerPin(String pin) {
    _ownerPin = pin;
    _cashierPin = null;
  }

  /// Ingat PIN kasir sesudah login berhasil (memori saja).
  void rememberCashierPin(String pin) {
    _cashierPin = pin;
    _ownerPin = null;
  }

  /// Hapus bukti PIN Owner (mis. kembali ke peran Kasir / lock).
  void clearOwnerPin() {
    _ownerPin = null;
  }

  /// Bukti PIN untuk body sync-sales: {owner_pin} atau {cashier_pin};
  /// kosong = belum ada bukti (sync WAJIB ditahan — R-02).
  Map<String, dynamic> get sessionProof {
    final owner = _ownerPin;
    if (owner != null && owner.isNotEmpty) return {'owner_pin': owner};
    final cashier = _cashierPin;
    if (cashier != null && cashier.isNotEmpty) {
      return {'cashier_pin': cashier};
    }
    return const <String, dynamic>{};
  }

  bool get hasSessionProof => sessionProof.isNotEmpty;

  Future<void> init() async {
    _db ??= AppDatabase();
    final row = await (_db!.select(_db!.cashierSessions)
          ..where((t) => t.id.equals('current')))
        .getSingleOrNull();
    _outletId = row?.outletId;
    _cashierId = row?.cashierId;
    _cashierName = row?.cashierName;
    _lastActive = DateTime.now();
    notifyListeners();
  }

  Future<void> save({
    required String outletId,
    String? cashierId,
    required String cashierName,
  }) async {
    // Isi field in-memory DULU sebelum tulis DB: _handleSuccess
    // memanggil save() tanpa await lalu langsung onSuccess — gate
    // yang membaca hasSession sesudah itu harus sudah melihat sesi,
    // dan sesi tetap ada di memori walau tulis DB gagal (review C5 W2).
    _outletId = outletId;
    _cashierId = cashierId;
    _cashierName = cashierName;
    _lastActive = DateTime.now();
    _db ??= AppDatabase();
    await _db!.into(_db!.cashierSessions).insertOnConflictUpdate(
          CashierSessionsCompanion.insert(
            id: 'current',
            outletId: outletId,
            cashierId: Value(cashierId),
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
    _cashierId = null;
    _cashierName = null;
    // Bukti PIN ikut dihapus (SEC-1 R-02 — PIN hanya di memori).
    _ownerPin = null;
    _cashierPin = null;
    // v40: izin ikut dihapus (sesi baru = izin belum diketahui).
    _resetPermissions();
    _lastActive = DateTime.now();
    notifyListeners();
  }

  /// Catat interaksi (tap) — dipanggil dari Listener PointerDown
  /// di root shell dan saat transaksi selesai.
  void touch() {
    _lastActive = DateTime.now();
  }
}
