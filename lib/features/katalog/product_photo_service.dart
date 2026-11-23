import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../data/supabase_client.dart';

/// Path foto produk di bucket Storage `product-photos` (migrasi 007).
/// Satu file per produk per gerai — ganti foto menimpa file lama
/// (upsert di Edge Function), URL publik tetap sama.
/// Format ini HARUS sama dengan `storagePath()` di Edge Function
/// `upload-product-photo` (bila salah satu berubah, samakan keduanya).
String photoStoragePath(String outletId, String productId) =>
    'products/$outletId/$productId.jpg';

/// Hasil mentah Edge Function `upload-product-photo` -> URL publik,
/// atau null bila gagal / bukan peta / URL kosong.
String? parseUploadResponse(dynamic data) {
  if (data is! Map) return null;
  if (data['ok'] != true) return null;
  final url = data['public_url'];
  if (url is! String || url.isEmpty) return null;
  return url;
}

/// Upload foto produk custom Owner ke Supabase Storage — SELALU lewat
/// Edge Function `upload-product-photo` (service_role + bukti PIN
/// Owner), BUKAN upload langsung dari app: anon key bisa diekstrak
/// dari APK, jadi upload langsung tidak bisa dibatasi hanya Owner.
/// PIN Owner tidak disimpan di sini — pemanggil (Katalog) memintanya
/// lewat PinEntryDialog dan meneruskannya sekali (onPinVerified).
/// Foto sudah diperkecil pemanggil (image_picker max 1024px, quality
/// 85) sebelum sampai ke sini; batas keras 2 MB tetap dicek.
class ProductPhotoService {
  ProductPhotoService._();

  static final ProductPhotoService instance = ProductPhotoService._();

  static const int maxImageBytes = 2 * 1024 * 1024;

  /// Kirim [bytes] JPEG ke Edge Function. Mengembalikan URL publik
  /// foto, atau null bila gagal (offline / EF belum di-deploy / PIN
  /// salah / file terlalu besar). Tidak pernah throw.
  Future<String?> uploadPhoto({
    required String outletId,
    required String productId,
    required List<int> bytes,
    required String ownerPin,
  }) async {
    if (!SupabaseService.instance.isConfigured) {
      debugPrint('Upload foto dilewati: Supabase belum dikonfigurasi.');
      return null;
    }
    if (bytes.isEmpty || bytes.length > maxImageBytes) {
      debugPrint(
        'Upload foto ditolak: ukuran ${bytes.length} byte (batas $maxImageBytes).',
      );
      return null;
    }
    try {
      final res = await SupabaseService.instance.client.functions.invoke(
        'upload-product-photo',
        body: {
          'outlet_id': outletId,
          'product_id': productId,
          'owner_pin': ownerPin,
          'image_base64': base64Encode(bytes),
        },
      );
      final url = parseUploadResponse(res.data);
      if (url == null) {
        final data = res.data;
        debugPrint(
          'Upload foto gagal: ${data is Map ? (data['error'] ?? data['reason'] ?? 'unknown') : 'unknown'}',
        );
      }
      return url;
    } catch (e) {
      debugPrint('Upload foto gagal: $e');
      return null;
    }
  }
}
