import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models.dart';
import '../../data/seed_menu.dart';

/// Stok bahan (seed). Ambang menipis memunculkan badge peringatan.
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
        return Card(
          child: ListTile(
            title: Text(item.name),
            subtitle: Text('${item.qty} ${item.unit}'),
            trailing: item.isLow
                ? const Chip(
                    label: Text('Menipis'),
                    backgroundColor: Color(0xFFFDECEC),
                  )
                : const Chip(
                    label: Text('Aman'),
                    backgroundColor: SukaTeaColors.emeraldSoft,
                  ),
          ),
        );
      },
    );
  }
}
