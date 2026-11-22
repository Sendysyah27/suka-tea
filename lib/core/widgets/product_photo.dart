import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Foto produk di item Kasir / Kelola Menu / keranjang.
///
/// `photoUrl` bisa berisi:
/// - path asset bawaan, mis. `assets/products/01-manggo-milktea.jpg`
///   (foto default dari poster) → [Image.asset]
/// - URL Supabase Storage (M1, upload Owner sendiri) → [Image.network]
/// - null / kosong → ikon gelas placeholder blok mint.
class ProductPhoto extends StatelessWidget {
  const ProductPhoto({
    super.key,
    required this.photoUrl,
    this.width,
    this.height,
    this.borderRadius = 14,
    this.iconSize = 28,
  });

  final String? photoUrl;
  final double? width;
  final double? height;
  final double borderRadius;
  final double iconSize;

  bool get _isAsset => (photoUrl ?? '').startsWith('assets/');

  @override
  Widget build(BuildContext context) {
    final url = photoUrl;
    if (url == null || url.isEmpty) return _placeholder();
    final Widget image = _isAsset
        ? Image.asset(
            url,
            width: width,
            height: height,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => _placeholder(),
          )
        : Image.network(
            url,
            width: width,
            height: height,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => _placeholder(),
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: image,
    );
  }

  Widget _placeholder() {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: SukaTeaColors.emeraldSoft,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Icon(
        Icons.local_drink,
        size: iconSize,
        color: SukaTeaColors.emerald,
      ),
    );
  }
}
