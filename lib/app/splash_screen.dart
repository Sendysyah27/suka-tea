import 'package:flutter/material.dart';

/// Splash screen SUKA TEA — frame pertama saat app dibuka.
///
/// main() menampilkan ini DULU (runApp pertama), menjalankan semua
/// init service di belakangnya, lalu runApp kedua mengganti splash
/// dengan SukaTeaApp begitu init selesai — jadi tidak ada layar
/// putih / kedip di antara splash dan halaman Login.
///
/// Background foto gerai (emerald, gelas es teh + lime + daun teh,
/// TANPA teks — wordmark + tagline digambar di sini supaya tajam di
/// segala ukuran layar). Scrim gelap tipis di atas foto supaya teks
/// putih selalu terbaca.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  static const String backgroundAsset =
      'assets/splash/suka-tea-splash-bg.jpg';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            backgroundAsset,
            fit: BoxFit.cover,
          ),
          Container(color: Colors.black.withValues(alpha: 0.35)),
          SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'SUKA TEA',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 44,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Es Teh Kekinian',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 56),
                const CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 3,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
