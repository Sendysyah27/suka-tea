import 'package:flutter/material.dart';

/// Token desain Opsi B — Fresh Minimal (DIKUNCI 22 Nov 2026, revisi dari
/// Opsi A (pop oranye/toska)). Emerald sebagai warna aksi tunggal, lime aksen.
class SukaTeaColors {
  SukaTeaColors._();

  static const Color emerald = Color(0xFF0A9B6C);
  static const Color emeraldDark = Color(0xFF067A55);
  static const Color emeraldSoft = Color(0xFFE3F5EE);
  static const Color lime = Color(0xFFA3E635);
  static const Color leafBg = Color(0xFFF2F7F2);
  static const Color card = Colors.white;
  static const Color ink = Color(0xFF1A2E25);
  static const Color muted = Color(0xFF6B7F74);
  static const Color border = Color(0xFFE3EDE7);
  static const Color danger = Color(0xFFD64545);
  static const Color amber = Color(0xFFE8A13A);
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
      fontFamily: 'PlusJakartaSans',
      useMaterial3: true,
      textTheme: const TextTheme(
        titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        bodyMedium: TextStyle(fontSize: 14),
        bodySmall: TextStyle(fontSize: 12),
        labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: SukaTeaColors.card,
        foregroundColor: SukaTeaColors.ink,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: SukaTeaColors.card,
        elevation: 0,
        shadowColor: SukaTeaColors.ink.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: SukaTeaColors.border),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: SukaTeaColors.emerald,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: SukaTeaColors.emeraldSoft,
        selectedColor: SukaTeaColors.emerald,
        labelStyle: const TextStyle(color: SukaTeaColors.ink, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: SukaTeaColors.card,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SukaTeaColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SukaTeaColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(
            color: SukaTeaColors.emerald,
            width: 1.5,
          ),
        ),
      ),
      dividerColor: SukaTeaColors.border,
    );
  }
}
