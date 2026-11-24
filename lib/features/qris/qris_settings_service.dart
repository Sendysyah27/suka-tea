import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/supabase_client.dart';
import 'qris_service.dart';

/// Hasil mentah Edge Function `get-qris-payload` ->
/// (ok, value, legacy).
/// [ok] = false bila bukan peta / ok != true / value bukan null atau
/// String yang dikenal — fail closed.
/// [value] = plaintext QRIS statis (diawali "000201") bila sudah
/// diatur, null bila belum.
/// [legacy] = true bila nilai tersimpan masih ciphertext lama
/// `enc:v1:` (Batch C8) — app menganggapnya BELUM diatur; Owner
/// wajib simpan ulang sekali (lihat [QrisSettingsService.needsReSave]).
({bool ok, String? value, bool legacy}) parseGetQrisResponse(dynamic data) {
  if (data is! Map) return (ok: false, value: null, legacy: false);
  if (data['ok'] != true) return (ok: false, value: null, legacy: false);
  final value = data['value'];
  if (value == null) return (ok: true, value: null, legacy: false);
  if (value is! String) return (ok: false, value: null, legacy: false);
  if (value.startsWith('enc:v1:')) {
    return (ok: true, value: null, legacy: true);
  }
  if (value.startsWith('000201')) {
    return (ok: true, value: value, legacy: false);
  }
  return (ok: false, value: null, legacy: false);
}

/// Hasil mentah Edge Function `set-qris-payload` -> true bila ok.
/// Dipakai save() + clear(): 2xx dengan {ok:true} = berhasil.
bool parseSetQrisResponse(dynamic data) {
  if (data is! Map) return false;
  return data['ok'] == true;
}

/// Penyimpanan kode QRIS statis merchant (Owner saja).
///
/// Batch C8.2 — QRIS GLOBAL: SATU payload untuk SEMUA gerai + SEMUA
/// device yang login. Nilai disimpan PLAINTEXT di Supabase
/// (`app_settings`, key `qris_static_payload`, baris outlet global
/// ...0001) dan dibaca apa adanya lewat Edge Function
/// `get-qris-payload` — tanpa enkripsi per-perangkat (itu yang bikin
/// payload POVA tidak bisa dipakai POCO, 24 Nov 2026).
///
/// Trade-off yang jujur (disetujui Sendy 24 Nov 13:54): siapa pun yang
/// memegang anon key dari APK bisa membaca payload ini lewat EF.
/// Praktis risikonya rendah — payload QRIS statis hanya bisa membuat
/// QR yang membayar KE rekening merchant, tidak bisa mengalihkan uang.
/// Tanpa Supabase Auth (M0) tidak ada cara lain supaya semua device
/// bisa baca tapi orang luar tidak.
///
/// Nilai asli TIDAK PERNAH di-hardcode di repo: Owner menempelkannya di
/// layar Pengaturan QRIS, lalu disimpan ke Supabase bila outlet +
/// Supabase sudah dikonfigurasi. Sebelum itu, nilai hanya hidup di
/// memori aplikasi.
///
/// Batch C8: simpan/baca LEWAT Edge Function (`set-qris-payload` /
/// `get-qris-payload`), BUKAN upsert/select langsung dari app.
/// `app_settings` (migrasi 002) RLS-nya nyala dengan SATU policy
/// "owner kelola pengaturan" (is_outlet_owner via auth.uid()) —
/// sedangkan app TIDAK PERNAH login Supabase Auth, jadi baca/tulis
/// langsung pakai anon key SELALU ditolak server. EF memakai
/// service_role (melewati RLS); bukti Owner adalah PIN Owner yang
/// diverifikasi server-side di `set-qris-payload` (pola
/// upload-product-photo). `get-qris-payload` tanpa cek PIN — kasir
/// butuh payload ini tiap generate QR.
class QrisSettingsService {
  QrisSettingsService._();

  static final QrisSettingsService instance = QrisSettingsService._();

  /// Diisi app saat outlet aktif dipilih (sesudah login — gerai aktif
  /// baru diketahui di halaman Login, bukan di main()). Null = belum
  /// ada outlet. Payload itu GLOBAL (satu untuk semua gerai), jadi
  /// ganti outlet tidak me-reset status load.
  String? currentOutletId;

  String? _staticPayload;
  bool _loaded = false;

  /// true = server masih menyimpan ciphertext lama `enc:v1:` (Batch
  /// C8) — payload dianggap BELUM diatur; Owner wajib simpan ulang
  /// sekali. Halaman Pengaturan menampilkan status ini.
  bool _needsReSave = false;
  bool get needsReSave => _needsReSave;

  String? get staticPayload => _staticPayload;

  bool get isConfigured =>
      _staticPayload != null && _staticPayload!.isNotEmpty;

  String? get merchantName =>
      _staticPayload == null ? null : QrisService.merchantName(_staticPayload!);

  /// Muat payload dari Supabase lewat Edge Function `get-qris-payload`
  /// (service_role). Nilai dipakai langsung (plaintext global).
  /// Ciphertext lama `enc:v1:` TIDAK dibuka — ditandai [needsReSave]
  /// supaya Owner simpan ulang.
  Future<void> load() async {
    if (_loaded) return;
    // _loaded HANYA diset sesudah percobaan baca yang sesungguhnya —
    // kalau outlet/Supabase belum siap, load() berikutnya harus
    // mencoba lagi (bukan mengira sudah dimuat).
    if (!SupabaseService.instance.isConfigured || currentOutletId == null) {
      return;
    }
    _loaded = true;
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'get-qris-payload',
        body: {'outlet_id': currentOutletId},
      );
      final parsed = parseGetQrisResponse(res.data);
      if (!parsed.ok) {
        debugPrint(
          'Muat pengaturan QRIS gagal: jawaban get-qris-payload tidak dikenal.',
        );
        return;
      }
      if (parsed.legacy) {
        _needsReSave = true;
        debugPrint(
          'Payload QRIS masih format lama (enc:v1:) — minta Owner '
          'simpan ulang QRIS merchant.',
        );
        return;
      }
      final value = parsed.value;
      if (value == null) return;
      if (QrisService.isValidStaticPayload(value)) {
        _staticPayload = value;
        _needsReSave = false;
      } else {
        debugPrint('Payload QRIS dari server tidak valid — diabaikan.');
      }
    } on FunctionException catch (e) {
      // Edge Function mengembalikan 4xx/5xx dengan body JSON {ok, error}:
      // details membawa body itu. NAMA KELAS: `FunctionException`
      // (tunggal) — supabase_flutter 2.x. JANGAN "diperbaiki" ke
      // `FunctionsException` (itu 3.x — ketangkep CI v28).
      debugPrint(
        'Muat pengaturan QRIS gagal (${e.status}): ${e.details} (pakai memori).',
      );
    } catch (e) {
      debugPrint('Muat pengaturan QRIS gagal (pakai memori): $e');
    }
  }

  /// Simpan payload statis (sudah divalidasi pemanggil) lewat Edge
  /// Function `set-qris-payload` — PLAINTEXT tervalidasi, disimpan
  /// sebagai SATU baris global (semua gerai + semua device).
  /// [ownerPin] = PIN Owner yang sudah diverifikasi halaman lewat
  /// PinEntryDialog — diteruskan sekali ke server, TIDAK PERNAH
  /// disimpan di sini.
  /// [ok] = false bila payload tidak valid (fail closed).
  /// [synced] = true bila nilai sudah sampai ke Supabase; false =
  /// nilai hanya di memori sesi ini (Supabase belum aktif, PIN
  /// ditolak server, atau EF belum di-deploy) — hilang saat restart,
  /// jadi halaman wajib membedakan pesannya, jangan bilang
  /// "tersimpan" tanpa syarat.
  Future<({bool ok, bool synced})> save(
    String payload, {
    required String ownerPin,
  }) async {
    if (!QrisService.isValidStaticPayload(payload)) {
      return (ok: false, synced: false);
    }
    _staticPayload = payload;
    _needsReSave = false;
    if (!SupabaseService.instance.isConfigured || currentOutletId == null) {
      return (ok: true, synced: false);
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'set-qris-payload',
        body: {
          'outlet_id': currentOutletId,
          'pin': ownerPin,
          'value': payload,
        },
      );
      final synced = parseSetQrisResponse(res.data);
      if (!synced) {
        debugPrint(
          'Simpan pengaturan QRIS ditolak server: ${res.data}.',
        );
      }
      return (ok: true, synced: synced);
    } on FunctionException catch (e) {
      // NAMA KELAS: `FunctionException` (tunggal) — supabase_flutter
      // 2.x. JANGAN "diperbaiki" ke `FunctionsException` (itu 3.x —
      // ketangkep CI v28).
      debugPrint(
        'Simpan pengaturan QRIS ke Supabase gagal (${e.status}): ${e.details}.',
      );
      return (ok: true, synced: false);
    } catch (e) {
      debugPrint('Simpan pengaturan QRIS ke Supabase gagal: $e');
      return (ok: true, synced: false);
    }
  }

  /// Hapus payload QRIS: memori dibersihkan dulu, lalu baris di
  /// Supabase dihapus lewat Edge Function `set-qris-payload`
  /// (delete:true) dengan bukti PIN Owner. Mengembalikan true bila
  /// baris server terhapus; false bila server tidak bisa dihubungi /
  /// PIN ditolak / Supabase belum dikonfigurasi — baris server (bila
  /// ada) akan dimuat lagi saat load() berikutnya.
  Future<bool> clear({required String ownerPin}) async {
    _staticPayload = null;
    _needsReSave = false;
    if (!SupabaseService.instance.isConfigured || currentOutletId == null) {
      return false;
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'set-qris-payload',
        body: {
          'outlet_id': currentOutletId,
          'pin': ownerPin,
          'delete': true,
        },
      );
      return parseSetQrisResponse(res.data);
    } on FunctionException catch (e) {
      // NAMA KELAS: `FunctionException` (tunggal) — supabase_flutter
      // 2.x. JANGAN "diperbaiki" ke `FunctionsException` (itu 3.x —
      // ketangkep CI v28).
      debugPrint(
        'Hapus pengaturan QRIS di Supabase gagal (${e.status}): ${e.details}.',
      );
      return false;
    } catch (e) {
      debugPrint('Hapus pengaturan QRIS di Supabase gagal: $e');
      return false;
    }
  }
}
