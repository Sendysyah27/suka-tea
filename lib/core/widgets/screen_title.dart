import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Judul layar 22 Bold + underline emerald 28x4 r2 — port dari
/// FigCraft title_block (v23): dipakai sebagai judul AppBar (shell +
/// halaman dorong) dan judul panel Keranjang. AppBar title memakai
/// titleLarge (22 w800) dari tema.
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 2),
        Container(
          width: 28,
          height: 4,
          decoration: BoxDecoration(
            color: SukaTeaColors.emerald,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ],
    );
  }
}
