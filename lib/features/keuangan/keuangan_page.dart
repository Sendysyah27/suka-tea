import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';

/// Keuangan — HANYA Owner. Desain v2: hero card emerald gelap untuk
/// omzet + laba, lalu rincian per cara bayar. Angka di bawah adalah
/// CONTOH tampilan; data nyata berasal dari v_daily_summary (RLS
/// Owner-only) di M3/M4.
class KeuanganPage extends StatelessWidget {
  const KeuanganPage({super.key, required this.role});

  final AppRole role;

  static const int tunai = 125000;
  static const int transfer = 45000;
  static const int qris = 15000;
  static const int qrisManual = 30000;
  static const int ewallet = 20000;
  static const int hpp = 70000;
  static const int pengeluaran = 60000;

  @override
  Widget build(BuildContext context) {
    if (!role.canViewProfit) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Hanya Owner yang bisa melihat laba/HPP.\n'
            'Pembatasan ini ditegakkan oleh RLS Supabase, bukan hanya tampilan.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    const omzet = tunai + transfer + qris + qrisManual + ewallet;
    const laba = omzet - hpp - pengeluaran;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: SukaTeaColors.emeraldDark,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Omzet hari ini (contoh)',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 6),
              Text(
                formatRupiah(omzet),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 32,
                ),
              ),
              const SizedBox(height: 12),
              const Divider(color: Colors.white24, height: 1),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Laba bersih (contoh)',
                    style: TextStyle(color: Colors.white70),
                  ),
                  Text(
                    formatRupiah(laba),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Per cara bayar',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        const SizedBox(height: 8),
        _row('Tunai', tunai, SukaTeaColors.cash),
        _row('Transfer', transfer, SukaTeaColors.cashless),
        _row('QRIS', qris, SukaTeaColors.cashless),
        _row('QRIS (manual)', qrisManual, SukaTeaColors.cashless),
        _row('E-Wallet', ewallet, SukaTeaColors.cashless),
        const SizedBox(height: 16),
        const Text(
          'Biaya',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        const SizedBox(height: 8),
        _row('HPP (contoh)', -hpp, SukaTeaColors.danger),
        _row('Pengeluaran (contoh)', -pengeluaran, SukaTeaColors.danger),
      ],
    );
  }

  Widget _row(String label, int amount, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(label)),
            Text(
              formatRupiah(amount),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
