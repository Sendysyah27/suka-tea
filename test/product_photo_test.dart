import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/features/katalog/product_photo_service.dart';

void main() {
  group('photoStoragePath', () {
    test('format products/<outlet>/<produk>.jpg', () {
      expect(
        photoStoragePath(
          '00000000-0000-0000-0000-000000000001',
          'es-teh-jumbo',
        ),
        'products/00000000-0000-0000-0000-000000000001/es-teh-jumbo.jpg',
      );
    });

    test('id produk slug + angka tetap utuh', () {
      expect(
        photoStoragePath('abc-123', 'teh-manis-1234567890123456'),
        'products/abc-123/teh-manis-1234567890123456.jpg',
      );
    });
  });

  group('parseUploadResponse', () {
    test('ok + public_url -> URL', () {
      expect(
        parseUploadResponse({
          'ok': true,
          'public_url': 'https://x.supabase.co/storage/v1/object/public/product-photos/products/o1/p1.jpg',
          'path': 'products/o1/p1.jpg',
        }),
        'https://x.supabase.co/storage/v1/object/public/product-photos/products/o1/p1.jpg',
      );
    });

    test('ok:false -> null', () {
      expect(parseUploadResponse({'ok': false, 'reason': 'wrong'}), isNull);
      expect(parseUploadResponse({'ok': false, 'error': 'boom'}), isNull);
    });

    test('bukan Map -> null', () {
      expect(parseUploadResponse(null), isNull);
      expect(parseUploadResponse('ok'), isNull);
      expect(parseUploadResponse(42), isNull);
    });

    test('ok:true tapi URL kosong / bukan string -> null', () {
      expect(parseUploadResponse({'ok': true, 'public_url': ''}), isNull);
      expect(parseUploadResponse({'ok': true}), isNull);
      expect(parseUploadResponse({'ok': true, 'public_url': 123}), isNull);
    });
  });
}
