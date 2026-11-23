import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/app/splash_screen.dart';

/// Splash screen SUKA TEA — tampil pertama saat app dibuka (main
/// menampilkan ini sebelum init service selesai).
void main() {
  testWidgets('tampil foto + wordmark + tagline + loading',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SplashScreen()),
    );
    await tester.pump();
    expect(find.text('SUKA TEA'), findsOneWidget);
    expect(find.text('Es Teh Kekinian'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('background = asset splash yang didaftarkan di pubspec',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SplashScreen()),
    );
    await tester.pump();
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<AssetImage>());
    expect(
      (image.image as AssetImage).assetName,
      SplashScreen.backgroundAsset,
    );
    expect(SplashScreen.backgroundAsset,
        'assets/splash/suka-tea-splash-bg.jpg');
    expect(tester.takeException(), isNull);
  });
}
