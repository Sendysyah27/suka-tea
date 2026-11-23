import 'package:flutter_test/flutter_test.dart';
import 'package:suka_tea/features/login/cashier_session.dart';

/// Auto-lock kasir 15 menit (Batch C5): murni, tanpa Drift —
/// service-nya sendiri hanya menyimpan lastActive di memori.
void main() {
  group('shouldAutoLock', () {
    test('14 menit 59 detik = belum kunci', () {
      final last = DateTime(2026, 11, 23, 21, 0);
      expect(
        shouldAutoLock(
          lastActive: last,
          now: last.add(const Duration(minutes: 14, seconds: 59)),
        ),
        isFalse,
      );
    });

    test('tepat 15 menit = kunci', () {
      final last = DateTime(2026, 11, 23, 21, 0);
      expect(
        shouldAutoLock(
          lastActive: last,
          now: last.add(const Duration(minutes: 15)),
        ),
        isTrue,
      );
    });

    test('lebih dari 15 menit = kunci', () {
      final last = DateTime(2026, 11, 23, 21, 0);
      expect(
        shouldAutoLock(
          lastActive: last,
          now: last.add(const Duration(minutes: 15, seconds: 1)),
        ),
        isTrue,
      );
    });

    test('batas idle custom dihormati', () {
      final last = DateTime(2026, 11, 23, 21, 0);
      expect(
        shouldAutoLock(
          lastActive: last,
          now: last.add(const Duration(minutes: 5)),
          idle: const Duration(minutes: 10),
        ),
        isFalse,
      );
      expect(
        shouldAutoLock(
          lastActive: last,
          now: last.add(const Duration(minutes: 10)),
          idle: const Duration(minutes: 10),
        ),
        isTrue,
      );
    });

    test('batas default = 15 menit', () {
      expect(kCashierIdleLimit, const Duration(minutes: 15));
    });
  });
}
