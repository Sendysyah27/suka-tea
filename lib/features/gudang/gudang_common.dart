import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../data/outlet_service.dart';

/// Helper bersama halaman gudang (Batch C10 WS1–WS8).
/// Pola tampilan mengikuti halaman Stok/Laporan yang sudah ada:
/// kartu 20px, tombol utama 56px, angka besar + satuan jelas.

/// Format jumlah: 120 -> "120", 2,5 -> "2,5" (koma Indonesia).
String qtyText(double v) {
  if (v == v.truncateToDouble()) return v.toStringAsFixed(0);
  var s = v.toStringAsFixed(3);
  s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  return s.replaceAll('.', ',');
}

/// Parse angka yang diketik user (koma/titik desimal). null = tidak valid.
double? parseQty(String raw) {
  final v = double.tryParse(raw.trim().replaceAll(',', '.'));
  if (v == null || v < 0) return null;
  return v;
}

/// Nama gerai dari id (fallback: id pendek).
String outletName(String outletId) {
  for (final o in OutletService.instance.outlets) {
    if (o.id == outletId) return o.name;
  }
  return outletId.length > 8 ? outletId.substring(0, 8) : outletId;
}

/// Judul seksi Dashboard/halaman gudang (14px, sesuai FigCraft v32).
class GudangSectionTitle extends StatelessWidget {
  const GudangSectionTitle(this.title, {super.key, this.onTap});

  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      title,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w800,
        color: SukaTeaColors.ink,
      ),
    );
    if (onTap == null) return text;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Row(
        children: [
          Expanded(child: text),
          const Icon(
            Icons.chevron_right,
            size: 18,
            color: SukaTeaColors.muted,
          ),
        ],
      ),
    );
  }
}

/// Tombol utama 56px (FigCraft v32 — semua aksi utama gudang 56px).
class GudangPrimaryButton extends StatelessWidget {
  const GudangPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: icon != null ? Icon(icon) : const SizedBox.shrink(),
        label: Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// Kartu kosong (empty state): pesan + aksi yang benar.
class GudangEmptyState extends StatelessWidget {
  const GudangEmptyState({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: SukaTeaColors.muted),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Baris "label — nilai" untuk kartu ringkas.
class GudangRow extends StatelessWidget {
  const GudangRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: SukaTeaColors.muted),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: valueColor ?? SukaTeaColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

String formatRp(int amount) => formatRupiah(amount);
