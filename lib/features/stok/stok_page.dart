import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models.dart';
import '../../data/seed_menu.dart';

/// Stok bahan (seed). Desain v2: progress bar vs ambang + pill status.
/// Bar penuh = 3x ambang menipis (skala tampilan, bukan data baru).
class StokPage extends StatelessWidget {
  const StokPage({super.key});

  @override
  Widget build(BuildContext context) {
    final items = seedStock();
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final StockItem item = items[i];
        final fraction =
            (item.qty / (item.lowThreshold * 3)).clamp(0.0, 1.0);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Chip(
                      label: Text(item.isLow ? 'Menipis' : 'Aman'),
                      backgroundColor: item.isLow
                          ? const Color(0xFFFDF3E0)
                          : SukaTeaColors.emeraldSoft,
                      labelStyle: TextStyle(
                        color: item.isLow
                            ? SukaTeaColors.amber
                            : SukaTeaColors.emeraldDark,
                        fontWeight: FontWeight.w600,
                      ),
                      side: BorderSide.none,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${item.qty} ${item.unit} • ambang ${item.lowThreshold} ${item.unit}',
                  style: const TextStyle(color: SukaTeaColors.muted),
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 8,
                    backgroundColor: SukaTeaColors.leafBg,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      item.isLow
                          ? SukaTeaColors.amber
                          : SukaTeaColors.emerald,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
