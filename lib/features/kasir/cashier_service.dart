import 'package:flutter/foundation.dart';

import '../../data/outlet_service.dart';
import '../login/cashier_session.dart';
import '../../data/supabase_client.dart';
import '../pin/pin_service.dart';

/// Satu kasir terdaftar (Batch C8.2 — registri kasir Owner).
/// Batch v40: + izin (void/diskon/tutup-shift) + paksa ganti PIN +
/// presence (terakhir sync + gerai terakhir) + arsip resign +
/// gerai yang diizinkan.
///
/// DEFAULT FIELD BARU = PERILAKU LAMA (sebelum v40 tidak ada gate):
/// canVoid/canDiscount/canCloseShift = true, forcePinChange = false,
/// allowedOutletIds kosong = tidak dibatasi. Ini yang membuat app
/// v40 tetap jalan terhadap server LAMA (belum migrasi 014) selama
/// jendela deploy app-dulu-server-belakangan.
class Cashier {
  const Cashier({
    required this.id,
    required this.name,
    this.active = true,
    this.canVoid = true,
    this.canDiscount = true,
    this.canCloseShift = true,
    this.forcePinChange = false,
    this.lastSeenAt,
    this.lastOutletId,
    this.resignedAt,
    this.allowedOutletIds = const <String>[],
  });

  /// UUID Supabase (tabel `cashiers`).
  final String id;

  /// Nama yang didaftarkan Owner — identitas kasir di struk,
  /// riwayat, dan Pantau Gerai.
  final String name;

  /// false = dinonaktifkan Owner (PIN tidak bisa dipakai login).
  final bool active;

  /// Boleh void penjualan (v40 — default true = perilaku lama).
  final bool canVoid;

  /// Boleh beri diskon di Kasir (v40 — default true = perilaku lama).
  final bool canDiscount;

  /// Boleh tutup shift (v40 — default true = perilaku lama).
  final bool canCloseShift;

  /// Wajib ganti PIN saat login berikut (v40).
  final bool forcePinChange;

  /// Terakhir sync dari HP kasir (heartbeat 10 dtk, v40).
  /// null = belum pernah sync (tidak ada badge LIVE).
  final DateTime? lastSeenAt;

  /// Gerai terakhir tempat kasir sync (v40).
  final String? lastOutletId;

  /// Jam resign (v40) — null = bukan arsip resign.
  final DateTime? resignedAt;

  /// Gerai yang boleh dimasuki kasir (v40). Kosong = tidak dibatasi
  /// (perilaku lama — PIN berlaku semua gerai).
  final List<String> allowedOutletIds;

  factory Cashier.fromJson(Map<String, dynamic> json) => Cashier(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        active: json['active'] != false,
        canVoid: json['can_void'] != false,
        canDiscount: json['can_discount'] != false,
        canCloseShift: json['can_close_shift'] != false,
        forcePinChange: json['force_pin_change'] == true,
        lastSeenAt: _parseDate(json['last_seen_at']),
        lastOutletId: json['last_outlet_id'] as String?,
        resignedAt: _parseDate(json['resigned_at']),
        allowedOutletIds: _parseOutletIds(json['allowed_outlets']),
      );
}

/// Parse tanggal ISO dari server — gagal / bukan string = null
/// (JANGAN throw; field baru boleh hilang di jawaban lama).
DateTime? _parseDate(dynamic raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toLocal();
}

/// Parse daftar outlet_id — bukan list = kosong (tidak dibatasi).
List<String> _parseOutletIds(dynamic raw) {
  if (raw is! List) return const <String>[];
  final list = <String>[];
  for (final e in raw) {
    if (e is String && e.isNotEmpty) list.add(e);
  }
  return list;
}

/// LIVE (v40, desain frame 30): HP kasir masih sync bila terakhir
/// sync ≤ 5 menit lalu. null = tidak live. Fungsi murni, di-test.
bool isCashierLive(DateTime? lastSeenAt, DateTime now) {
  if (lastSeenAt == null) return false;
  return now.difference(lastSeenAt) <= const Duration(minutes: 5);
}

/// true = kasir ada di arsip Resign (nonaktif + punya resigned_at).
/// Nonaktifkan biasa (resigned_at null) BUKAN resign.
bool isCashierResigned(Cashier c) => !c.active && c.resignedAt != null;

/// Pisah daftar kasir jadi (daftar utama, arsip resign).
/// Daftar utama = aktif + nonaktif biasa; arsip = resigned saja.
({List<Cashier> main, List<Cashier> resigned}) splitCashierArchive(
  List<Cashier> all,
) {
  final main = <Cashier>[];
  final resigned = <Cashier>[];
  for (final c in all) {
    if (isCashierResigned(c)) {
      resigned.add(c);
    } else {
      main.add(c);
    }
  }
  return (main: main, resigned: resigned);
}

/// Baca izin dari Map jawaban server (verify / pull) — null / bukan
/// Map / field hilang = default perilaku lama.
CashierPermissions parseCashierPermissions(dynamic data) {
  if (data is! Map) return kDefaultCashierPermissions;
  return (
    canVoid: data['can_void'] != false,
    canDiscount: data['can_discount'] != false,
    canCloseShift: data['can_close_shift'] != false,
    forcePinChange: data['force_pin_change'] == true,
    allowedOutletIds: _parseOutletIds(data['allowed_outlets']),
  );
}

/// Satu baris riwayat login (v40 — tabel `cashier_login_events`).
class LoginEvent {
  const LoginEvent({
    required this.id,
    required this.cashierId,
    required this.cashierName,
    required this.outletId,
    required this.loginAt,
  });

  final String id;
  final String cashierId;
  final String cashierName;
  final String outletId;
  final DateTime loginAt;

  factory LoginEvent.fromJson(Map<String, dynamic> json) {
    final loginAt = _parseDate(json['login_at']);
    if (loginAt == null) throw const FormatException('login_at hilang');
    return LoginEvent(
      id: json['id'] as String? ?? '',
      cashierId: json['cashier_id'] as String? ?? '',
      cashierName: json['cashier_name'] as String? ?? '',
      outletId: json['outlet_id'] as String? ?? '',
      loginAt: loginAt,
    );
  }
}

/// Hasil mentah Edge Function `list-login-events` -> (ok, events).
/// Baris rusak dilewati, bukan gagal total (pola list-cashiers).
({bool ok, List<LoginEvent> events}) parseLoginEventsResponse(
  dynamic data,
) {
  if (data is! Map) return (ok: false, events: const <LoginEvent>[]);
  if (data['ok'] != true) return (ok: false, events: const <LoginEvent>[]);
  final raw = data['events'];
  if (raw is! List) return (ok: false, events: const <LoginEvent>[]);
  final list = <LoginEvent>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    try {
      list.add(
        LoginEvent.fromJson(Map<String, dynamic>.from(entry)),
      );
    } catch (_) {
      continue;
    }
  }
  return (ok: true, events: list);
}

/// Hasil verifikasi PIN kasir (Batch C8.2 — login kasir baru).
/// v40: + `outletNotAllowed` (gerai tidak dicentang untuk kasir ini).
enum CashierVerifyResult {
  ok,
  wrong,
  locked,
  notFound,
  unavailable,
  outletNotAllowed,
}

/// Hasil mentah Edge Function `list-cashiers` -> (ok, daftar kasir).
/// [ok] = false bila bukan peta / ok != true / cashiers bukan list.
/// Entri yang rusak (tanpa id/nama) dilewati, bukan gagal total.
({bool ok, List<Cashier> cashiers}) parseCashierListResponse(dynamic data) {
  if (data is! Map) return (ok: false, cashiers: const <Cashier>[]);
  if (data['ok'] != true) return (ok: false, cashiers: const <Cashier>[]);
  final raw = data['cashiers'];
  if (raw is! List) return (ok: false, cashiers: const <Cashier>[]);
  final list = <Cashier>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final id = entry['id'];
    final name = entry['name'];
    if (id is! String || id.isEmpty) continue;
    if (name is! String || name.isEmpty) continue;
    list.add(
      Cashier.fromJson(Map<String, dynamic>.from(entry)),
    );
  }
  return (ok: true, cashiers: list);
}

/// Hasil mentah Edge Function `verify-cashier-pin` ->
/// (result, id, nama, izin). ok:true + cashier_id + name terisi = ok;
/// ok:false + reason = 'wrong'/'locked'/'not_found'/
/// 'outlet_not_allowed' = hasil itu; selainnya = unavailable.
/// Izin dibaca dari jawaban ok (field hilang = default perilaku
/// lama — server lama belum mengirimnya).
({
  CashierVerifyResult result,
  String? cashierId,
  String? name,
  CashierPermissions permissions,
}) parseVerifyCashierResponse(dynamic data) {
  const unavailable = (
    result: CashierVerifyResult.unavailable,
    cashierId: null,
    name: null,
    permissions: kDefaultCashierPermissions,
  );
  if (data is! Map) return unavailable;
  if (data['ok'] == true) {
    final id = data['cashier_id'];
    final name = data['name'];
    if (id is String && id.isNotEmpty && name is String && name.isNotEmpty) {
      return (
        result: CashierVerifyResult.ok,
        cashierId: id,
        name: name,
        permissions: parseCashierPermissions(data),
      );
    }
    return unavailable;
  }
  switch (data['reason']) {
    case 'wrong':
      return (
        result: CashierVerifyResult.wrong,
        cashierId: null,
        name: null,
        permissions: kDefaultCashierPermissions,
      );
    case 'locked':
      return (
        result: CashierVerifyResult.locked,
        cashierId: null,
        name: null,
        permissions: kDefaultCashierPermissions,
      );
    case 'not_found':
      return (
        result: CashierVerifyResult.notFound,
        cashierId: null,
        name: null,
        permissions: kDefaultCashierPermissions,
      );
    case 'outlet_not_allowed':
      return (
        result: CashierVerifyResult.outletNotAllowed,
        cashierId: null,
        name: null,
        permissions: kDefaultCashierPermissions,
      );
    default:
      return unavailable;
  }
}

/// Pesan error server dari jawaban EF kasir (mis. 'pin_taken',
/// 'name_taken', 'cashier_not_found') — null bila tidak ada / bukan
/// string. Dipakai halaman Kelola Kasir untuk pesan yang jelas.
String? parseCashierError(dynamic data) {
  if (data is! Map) return null;
  final error = data['error'];
  return error is String && error.isNotEmpty ? error : null;
}

/// Nama kasir yang sah untuk didaftarkan Owner: tidak kosong,
/// maks 50 karakter (batas yang sama dengan EF register-cashier).
bool isValidCashierName(String name) {
  final trimmed = name.trim();
  return trimmed.isNotEmpty && trimmed.length <= 50;
}

/// Body dasar panggilan Edge Function kasir yang butuh bukti Owner
/// (list/register/set-pin/set-active).
///
/// PIN Owner GLOBAL (koreksi Sendy 24 Nov 2026, Batch C10.1): SATU
/// PIN untuk semua gerai — hash-nya hanya ada di baris outlet global
/// (...0001). Jadi [outlet_id] yang dikirim SELALU baris global,
/// BUKAN gerai yang sedang dipilih (gerai lain akan dijawab EF
/// `not_set` bila mengirim outlet_id-nya sendiri). Fungsi ini sengaja
/// TIDAK menerima outlet_id — tidak ada jalan untuk mengirim yang
/// salah. Dipakai keempat metode Owner di [CashierService]; tes
/// menegaskan body-nya selalu global (test/cashier_service_test.dart).
Map<String, dynamic> cashierOwnerBody({
  required String ownerPin,
  Map<String, dynamic> extra = const {},
}) {
  return {
    'outlet_id': PinService.defaultOutletId,
    'owner_pin': ownerPin,
    ...extra,
  };
}

/// Registri kasir (Batch C8.2): Owner mendaftarkan kasir (nama + PIN
/// 6 digit, berlaku di semua gerai); kasir login HANYA dengan PIN —
/// identitas (id + nama) datang dari server, bukan ketikan kasir.
/// Semua operasi lewat Edge Function (service_role); PIN tidak pernah
/// disimpan lokal — bahkan hash-nya tidak di-cache.
///
/// PIN Owner diverifikasi server di tiap panggilan (bukti Owner);
/// PIN Owner itu sendiri tidak disimpan di sini — pemanggil
/// meneruskannya sekali dari PinEntryDialog.onPinVerified.
class CashierService {
  CashierService._();

  static final CashierService instance = CashierService._();

  /// Batas percobaan di sisi app (server punya batas sendiri di
  /// pin_attempts, sama seperti PIN Owner).
  static const int maxAttempts = 5;
  static const Duration lockoutDuration = Duration(minutes: 5);

  int _failedAttempts = 0;
  DateTime? _lockedUntil;

  /// Nama kasir terdaftar yang SUDAH dimuat dari server (memori saja,
  /// Batch C10.2 W5). Dipakai resolusi nama pembuka shift saat sesi
  /// tidak menyimpan nama (mis. sesi lama) — TIDAK PERNAH disimpan
  /// ke storage; PIN pun tidak pernah disimpan.
  final Map<String, String> _knownCashierNames = {};

  /// Nama kasir untuk [cashierId] yang pernah dimuat, null bila belum
  /// ada di memori. Tidak memanggil server (resolusi shift sinkron).
  String? knownNameFor(String cashierId) {
    final name = _knownCashierNames[cashierId];
    return name == null || name.isEmpty ? null : name;
  }

  /// Simpan pasangan id -> nama ke registry memori (dipakai setelah
  /// list/verify kasir, dan untuk resolusi nama pembuka shift W5).
  void rememberCashier({required String id, required String name}) {
    if (id.isNotEmpty && name.isNotEmpty) _knownCashierNames[id] = name;
  }

  bool get isLocked =>
      _lockedUntil != null && DateTime.now().isBefore(_lockedUntil!);

  int get remainingAttempts => maxAttempts - _failedAttempts;

  String get _outletId => OutletService.instance.currentOutletId;

  /// Verifikasi PIN akses kasir (login + layar kunci). Fail closed:
  /// salah / terkunci / belum ada kasir / offline / gerai tidak
  /// diizinkan = tidak masuk.
  ///
  /// v40: hasil ok ikut menyimpan IZIN kasir ke sesi (memori) —
  /// dipakai gate void/diskon/tutup-shift sampai pull berikutnya
  /// menyegarkan. `outletNotAllowed` TIDAK menambah hitungan gagal
  /// lokal (PIN-nya benar, gerainya yang tidak dicentang).
  Future<({
    CashierVerifyResult result,
    String? cashierId,
    String? name,
    CashierPermissions permissions,
  })> verifyPin(String pin, {String? outletId}) async {
    if (isLocked) {
      return (
        result: CashierVerifyResult.locked,
        cashierId: null,
        name: null,
        permissions: kDefaultCashierPermissions,
      );
    }
    if (!PinService.isValidPin(pin)) {
      return (
        result: CashierVerifyResult.wrong,
        cashierId: null,
        name: null,
        permissions: kDefaultCashierPermissions,
      );
    }
    if (!SupabaseService.instance.isConfigured) {
      return (
        result: CashierVerifyResult.unavailable,
        cashierId: null,
        name: null,
        permissions: kDefaultCashierPermissions,
      );
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'verify-cashier-pin',
        body: {'pin': pin, 'outlet_id': outletId ?? _outletId},
      );
      final parsed = parseVerifyCashierResponse(res.data);
      if (parsed.result == CashierVerifyResult.ok) {
        _failedAttempts = 0;
        _lockedUntil = null;
        // SEC-1 R-02: PIN kasir sesi di MEMORI (bukan storage).
        CashierSessionService.instance.rememberCashierPin(pin);
        // v40: izin + gerai + flag dari server masuk sesi.
        CashierSessionService.instance.applyPermissions(
          parsed.permissions,
        );
        final id = parsed.cashierId;
        final name = parsed.name;
        if (id != null && name != null) {
          rememberCashier(id: id, name: name);
        }
      } else if (parsed.result == CashierVerifyResult.wrong) {
        _failedAttempts++;
        if (_failedAttempts >= maxAttempts) {
          _lockedUntil = DateTime.now().add(lockoutDuration);
        }
      }
      return parsed;
    } catch (e) {
      debugPrint('Verifikasi PIN kasir gagal: $e');
      return (
        result: CashierVerifyResult.unavailable,
        cashierId: null,
        name: null,
        permissions: kDefaultCashierPermissions,
      );
    }
  }

  /// Daftarkan kasir baru (Owner). [error] = kode server
  /// ('pin_taken' / 'name_taken' / pesan lain) bila gagal.
  Future<({bool ok, String? cashierId, String? error})> registerCashier({
    required String ownerPin,
    required String name,
    required String pin,
  }) async {
    if (!isValidCashierName(name)) {
      return (ok: false, cashierId: null, error: 'name_invalid');
    }
    if (!PinService.isValidPin(pin)) {
      return (ok: false, cashierId: null, error: 'pin_invalid');
    }
    if (!SupabaseService.instance.isConfigured) {
      return (ok: false, cashierId: null, error: 'offline');
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'register-cashier',
        body: cashierOwnerBody(
          ownerPin: ownerPin,
          extra: {'name': name.trim(), 'pin': pin},
        ),
      );
      final data = res.data;
      if (data is Map && data['ok'] == true) {
        final id = data['cashier_id'];
        return (
          ok: true,
          cashierId: id is String ? id : null,
          error: null,
        );
      }
      return (
        ok: false,
        cashierId: null,
        error: parseCashierError(data) ?? 'unknown',
      );
    } catch (e) {
      debugPrint('Daftar kasir gagal: $e');
      return (ok: false, cashierId: null, error: 'offline');
    }
  }

  /// Daftar semua kasir terdaftar (Owner). [ok] = false bila gagal
  /// dimuat (offline / PIN ditolak / EF belum di-deploy).
  Future<({bool ok, List<Cashier> cashiers})> listCashiers({
    required String ownerPin,
  }) async {
    if (!SupabaseService.instance.isConfigured) {
      return (ok: false, cashiers: const <Cashier>[]);
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'list-cashiers',
        body: cashierOwnerBody(ownerPin: ownerPin),
      );
      final parsed = parseCashierListResponse(res.data);
      if (parsed.ok) {
        for (final c in parsed.cashiers) {
          rememberCashier(id: c.id, name: c.name);
        }
      }
      return parsed;
    } catch (e) {
      debugPrint('Muat daftar kasir gagal: $e');
      return (ok: false, cashiers: const <Cashier>[]);
    }
  }

  /// Ubah PIN akses satu kasir (Owner). [error] = kode server
  /// ('pin_taken' / 'cashier_not_found' / pesan lain) bila gagal.
  ///
  /// v40: [name] opsional — dialog Ubah (frame 33) mengubah nama +
  /// PIN dalam SATU panggilan. Nama dicek unik antar kasir aktif
  /// (server kembalikan 'name_taken' bila bentrok).
  Future<({bool ok, String? error})> setCashierPin({
    required String ownerPin,
    required String cashierId,
    String? pin,
    String? name,
  }) async {
    final newName = name?.trim();
    if (pin != null && !PinService.isValidPin(pin)) {
      return (ok: false, error: 'pin_invalid');
    }
    if (newName != null && !isValidCashierName(newName)) {
      return (ok: false, error: 'name_invalid');
    }
    if (pin == null && (newName == null || newName.isEmpty)) {
      return (ok: false, error: 'nothing_to_update');
    }
    if (!SupabaseService.instance.isConfigured) {
      return (ok: false, error: 'offline');
    }
    try {
      final extra = <String, dynamic>{'cashier_id': cashierId};
      if (pin != null) extra['pin'] = pin;
      if (newName != null && newName.isNotEmpty) extra['name'] = newName;
      final res = await SupabaseService.instance.client.functions.invoke(
        'set-cashier-pin',
        body: cashierOwnerBody(ownerPin: ownerPin, extra: extra),
      );
      final data = res.data;
      if (data is Map && data['ok'] == true) {
        return (ok: true, error: null);
      }
      return (ok: false, error: parseCashierError(data) ?? 'unknown');
    } catch (e) {
      debugPrint('Ubah PIN kasir gagal: $e');
      return (ok: false, error: 'offline');
    }
  }

  /// Ubah nama + PIN kasir sekaligus (dialog Ubah, frame 33).
  /// Setidaknya satu dari [name]/[pin] harus terisi; PIN kosong =
  /// tidak diubah. Teruskan error server apa adanya.
  Future<({bool ok, String? error})> updateCashierNamePin({
    required String ownerPin,
    required String cashierId,
    String? name,
    String? pin,
  }) {
    return setCashierPin(
      ownerPin: ownerPin,
      cashierId: cashierId,
      pin: pin,
      name: name,
    );
  }

  /// Nonaktifkan / aktifkan lagi satu kasir (Owner).
  ///
  /// v40: [resigned] = true berarti RESIGN (arsip): active=false +
  /// resigned_at=now di server. Aktifkan lagi (active=true) selalu
  /// membersihkan resigned_at. Nonaktifkan biasa (resigned null /
  /// false) tidak menyentuh resigned_at.
  Future<bool> setCashierActive({
    required String ownerPin,
    required String cashierId,
    required bool active,
    bool? resigned,
  }) async {
    if (!SupabaseService.instance.isConfigured) return false;
    try {
      final extra = <String, dynamic>{
        'cashier_id': cashierId,
        'active': active,
      };
      if (resigned != null) extra['resigned'] = resigned;
      final res = await SupabaseService.instance.client.functions.invoke(
        'set-cashier-active',
        body: cashierOwnerBody(ownerPin: ownerPin, extra: extra),
      );
      final data = res.data;
      return data is Map && data['ok'] == true;
    } catch (e) {
      debugPrint('Ubah status kasir gagal: $e');
      return false;
    }
  }

  /// Resignkan kasir (Owner) — masuk arsip Kasir Resign (F1).
  Future<bool> resignCashier({
    required String ownerPin,
    required String cashierId,
  }) {
    return setCashierActive(
      ownerPin: ownerPin,
      cashierId: cashierId,
      active: false,
      resigned: true,
    );
  }

  /// Ubah pengaturan kasir (Detail, frame 28): izin void/diskon/
  /// tutup-shift, paksa ganti PIN, gerai yang diizinkan, kick.
  /// Hanya field yang TIDAK null yang dikirim (partial update).
  /// [kicked] = true → server SET kicked_at=now (paksa keluar);
  /// false → batalkan kick (kicked_at=NULL).
  Future<({bool ok, String? error})> setCashierSettings({
    required String ownerPin,
    required String cashierId,
    bool? canVoid,
    bool? canDiscount,
    bool? canCloseShift,
    bool? forcePinChange,
    List<String>? outletIds,
    bool? kicked,
  }) async {
    if (!SupabaseService.instance.isConfigured) {
      return (ok: false, error: 'offline');
    }
    final extra = <String, dynamic>{'cashier_id': cashierId};
    if (canVoid != null) extra['can_void'] = canVoid;
    if (canDiscount != null) extra['can_discount'] = canDiscount;
    if (canCloseShift != null) extra['can_close_shift'] = canCloseShift;
    if (forcePinChange != null) extra['force_pin_change'] = forcePinChange;
    if (outletIds != null) extra['outlet_ids'] = outletIds;
    if (kicked != null) extra['kicked'] = kicked;
    if (extra.length == 1) {
      return (ok: false, error: 'nothing_to_update');
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'set-cashier-settings',
        body: cashierOwnerBody(ownerPin: ownerPin, extra: extra),
      );
      final data = res.data;
      if (data is Map && data['ok'] == true) {
        return (ok: true, error: null);
      }
      return (ok: false, error: parseCashierError(data) ?? 'unknown');
    } catch (e) {
      debugPrint('Ubah pengaturan kasir gagal: $e');
      return (ok: false, error: 'offline');
    }
  }

  /// Paksa keluar kasir (F3) — HP-nya terkunci di sync berikutnya
  /// (≤ 10 detik). Kasir TIDAK dinonaktifkan (PIN tetap berlaku
  /// untuk login ulang).
  Future<({bool ok, String? error})> kickCashier({
    required String ownerPin,
    required String cashierId,
  }) {
    return setCashierSettings(
      ownerPin: ownerPin,
      cashierId: cashierId,
      kicked: true,
    );
  }

  /// Kasir ganti PIN sendiri (F7 — alur paksa ganti PIN).
  /// [oldPin] = PIN lama yang sudah terbukti (dimasukkan saat login);
  /// [newPin] = PIN baru 2x di UI. Sukses → PIN sesi di memori
  /// diganti ke PIN baru (kasir tetap login, tidak dipaksa keluar).
  Future<({bool ok, String? error})> changeOwnPin({
    required String oldPin,
    required String newPin,
  }) async {
    if (!PinService.isValidPin(oldPin) ||
        !PinService.isValidPin(newPin)) {
      return (ok: false, error: 'pin_invalid');
    }
    if (!SupabaseService.instance.isConfigured) {
      return (ok: false, error: 'offline');
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'change-own-cashier-pin',
        body: {'cashier_pin': oldPin, 'new_pin': newPin},
      );
      final data = res.data;
      if (data is Map && data['ok'] == true) {
        CashierSessionService.instance.rememberCashierPin(newPin);
        return (ok: true, error: null);
      }
      if (data is Map && data['reason'] == 'wrong') {
        return (ok: false, error: 'wrong');
      }
      return (ok: false, error: parseCashierError(data) ?? 'unknown');
    } catch (e) {
      debugPrint('Ganti PIN sendiri gagal: $e');
      return (ok: false, error: 'offline');
    }
  }

  /// Riwayat login kasir (Owner, frame 30) — 100 event terbaru.
  Future<({bool ok, List<LoginEvent> events})> listLoginEvents({
    required String ownerPin,
  }) async {
    if (!SupabaseService.instance.isConfigured) {
      return (ok: false, events: const <LoginEvent>[]);
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'list-login-events',
        body: cashierOwnerBody(ownerPin: ownerPin),
      );
      return parseLoginEventsResponse(res.data);
    } catch (e) {
      debugPrint('Muat riwayat login gagal: $e');
      return (ok: false, events: const <LoginEvent>[]);
    }
  }
}
