import 'package:flutter/material.dart';

/// Token desain Opsi B — Fresh Minimal (DIKUNCI 22 Nov 2026, revisi dari
/// Opsi A (pop oranye/toska)). Emerald sebagai warna aksi tunggal, lime aksen.
class SukaTeaColors {
  SukaTeaColors._();

  static const Color emerald = Color(0xFF0A9B6C);
  static const Color emeraldDark = Color(0xFF0A7A55);
  static const Color emeraldSoft = Color(0xFFE3F5EE);
  static const Color lime = Color(0xFFA3E635);
  static const Color leafBg = Color(0xFFF4F9F2);
  static const Color card = Colors.white;
  static const Color ink = Color(0xFF12261B);
  static const Color muted = Color(0xFF5B6B60);
  static const Color border = Color(0xFFE2EAE3);
  static const Color danger = Color(0xFFD64545);
  static const Color cash = Color(0xFF0A9B6C);
  static const Color cashless = Color(0xFF2563EB);
}

/// Breakpoint responsif (PRD §12):
/// <600dp HP satu kolom, 600–840dp dua panel, >840dp tiga zona.
class SukaTeaBreakpoints {
  SukaTeaBreakpoints._();

  static const double tablet = 600;
  static const double wide = 840;

  static bool isWide(double width) => width >= wide;
  static bool isTablet(double width) => width >= tablet && width < wide;
}

class SukaTeaTheme {
  SukaTeaTheme._();

  static ThemeData get light {
    const base = ColorScheme.light(
      primary: SukaTeaColors.emerald,
      onPrimary: Colors.white,
      secondary: SukaTeaColors.lime,
      surface: SukaTeaColors.card,
      error: SukaTeaColors.danger,
    );
    return ThemeData(
      colorScheme: base,
      scaffoldBackgroundColor: SukaTeaColors.leafBg,
      // PlusJakartaSans: tambahkan file TTF ke assets/fonts/ lalu daftarkan
      // di pubspec.yaml. Sampai saat itu Flutter memakai font default.
      fontFamily: 'PlusJakartaSans',
      useMaterial3: true,
      appBarTheme: const AppBarTheme(
        backgroundColor: SukaTeaColors.card,
        foregroundColor: SukaTeaColors.ink,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: SukaTeaColors.card,
        elevation: 2,
        shadowColor: SukaTeaColors.ink.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: SukaTeaColors.emerald,
          foregroundColor: Colors.white,
          minimumSize: const Size(48, 48), // target sentuh min 48dp
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: SukaTeaColors.emeraldSoft,
        selectedColor: SukaTeaColors.emerald,
        labelStyle: const TextStyle(color: SukaTeaColors.ink),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
      ),
      dividerColor: SukaTeaColors.border,
    );
  }
}
