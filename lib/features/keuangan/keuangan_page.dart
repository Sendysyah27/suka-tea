import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';

/// Keuangan — HANYA Owner. Angka di bawah adalah CONTOH tampilan;
/// data nyata berasal dari v_daily_summary (RLS Owner-only) di M3/M4.
class KeuanganPage extends StatelessWidget {
  const KeuanganPage({super.key, required this.role});

  final AppRole role;

  static const int tunai = 125000;
  static const int transfer = 45000;
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
    const omzet = tunai + transfer + qrisManual + ewallet;
    const laba = omzet - hpp - pengeluaran;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: ListTile(
            title: const Text('Omzet hari ini (contoh)'),
            trailing: Text(
              formatRupiah(omzet),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Text('Cash s.d. cashless', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        _row('Tunai', tunai, SukaTeaColors.cash),
        _row('Transfer', transfer, SukaTeaColors.cashless),
        _row('QRIS (manual)', qrisManual, SukaTeaColors.cashless),
        _row('E-Wallet', ewallet, SukaTeaColors.cashless),
        const SizedBox(height: 8),
        _row('HPP (contoh)', -hpp, SukaTeaColors.danger),
        _row('Pengeluaran (contoh)', -pengeluaran, SukaTeaColors.danger),
        const Divider(),
        ListTile(
          title: const Text('Laba bersih (contoh)',
              style: TextStyle(fontWeight: FontWeight.bold)),
          trailing: Text(
            formatRupiah(laba),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
              color: SukaTeaColors.emeraldDark,
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(String label, int amount, Color color) {
    return Card(
      child: ListTile(
        leading: Icon(Icons.circle, size: 12, color: color),
        title: Text(label),
        trailing: Text(formatRupiah(amount)),
      ),
    );
  }
}
