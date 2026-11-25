import 'package:flutter/material.dart';

import '../pin/pin_dialog.dart';

/// Minta izin aksi kasir (v40 — SATU pola untuk ketiga gate:
/// void di Riwayat, diskon di Kasir, tutup shift di Laporan).
///
/// [allowed] = izin kasir dari sesi (Owner memanggil dengan true —
/// Owner tidak kena gate). true = diizinkan (langsung / via PIN
/// Owner yang baru diverifikasi); false = ditolak / batal.
///
/// PIN Owner di tempat mengizinkan SATU KALI ini saja — TIDAK
/// mengubah toggle kasir di server.
Future<bool> ensureCashierPermission(
  BuildContext context, {
  required bool allowed,
  required String actionLabel,
}) async {
  if (allowed) return true;
  final ask = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Butuh izin Owner'),
      content: Text(
        'Kasir ini tidak diizinkan $actionLabel. Minta Owner '
        'masukkan PIN untuk mengizinkan sekali ini.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Masukkan PIN Owner'),
        ),
      ],
    ),
  );
  if (ask != true || !context.mounted) return false;
  final pinOk = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PinEntryDialog(),
  );
  return pinOk == true;
}
