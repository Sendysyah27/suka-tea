import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/screen_title.dart';
import '../../data/outlet_service.dart';
import '../pin/pin_dialog.dart';
import 'cashier_service.dart';
import 'kasir_management_page.dart';

/// Riwayat Login (v40, frame 30) — audit login kasir.
/// Owner PIN diminta sekali saat buka (pola Kelola Kasir), lalu
/// daftar kasir + event login dimuat SEKALI (paralel).
/// LIVE = kasir itu masih sync (≤ 5 menit, dari list-cashiers).
class LoginHistoryPage extends StatefulWidget {
  const LoginHistoryPage({super.key});

  @override
  State<LoginHistoryPage> createState() => _LoginHistoryPageState();
}

class _LoginHistoryPageState extends State<LoginHistoryPage> {
  List<Cashier>? _cashiers;
  List<LoginEvent>? _events;
  bool _loading = true;
  String? _error;
  String? _ownerPin;
  String _filter = 'Semua';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _askOwnerPin());
  }

  Future<void> _askOwnerPin() async {
    String? ownerPin;
    final pinOk = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PinEntryDialog(
        onPinVerified: (pin) => ownerPin = pin,
      ),
    );
    if (pinOk != true || ownerPin == null || !mounted) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    _ownerPin = ownerPin!;
    await _reload();
  }

  Future<void> _reload() async {
    if (_ownerPin == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final results = await Future.wait([
      CashierService.instance.listCashiers(ownerPin: _ownerPin!),
      CashierService.instance.listLoginEvents(ownerPin: _ownerPin!),
    ]);
    if (!mounted) return;
    final cashiers = results[0] as ({bool ok, List<Cashier> cashiers});
    final events = results[1] as ({bool ok, List<LoginEvent> events});
    setState(() {
      _loading = false;
      if (cashiers.ok && events.ok) {
        _cashiers = cashiers.cashiers;
        _events = events.events;
      } else {
        _error = 'Riwayat login tidak bisa dimuat — periksa koneksi / '
            'Edge Function belum di-deploy.';
      }
    });
  }

  String _outletName(String outletId) {
    for (final o in OutletService.instance.outlets) {
      if (o.id == outletId) return o.name;
    }
    return 'Gerai';
  }

  Cashier? _cashierFor(String cashierId) {
    final list = _cashiers;
    if (list == null) return null;
    for (final c in list) {
      if (c.id == cashierId) return c;
    }
    return null;
  }

  /// Pill baris event: LIVE / NONAKTIF / RESIGN / tidak ada.
  Widget? _pillFor(LoginEvent event, DateTime now) {
    final cashier = _cashierFor(event.cashierId);
    if (cashier != null && isCashierLive(cashier.lastSeenAt, now)) {
      return _pill('LIVE', SukaTeaColors.emerald, Colors.white);
    }
    if (cashier != null && isCashierResigned(cashier)) {
      return _pill('RESIGN', SukaTeaColors.danger, Colors.white);
    }
    if (cashier != null && !cashier.active) {
      return _pill(
        'NONAKTIF',
        SukaTeaColors.border,
        SukaTeaColors.muted,
      );
    }
    return null;
  }

  Widget _pill(String label, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }

  /// Baris bawah event: LIVE → "Masih login — terakhir sync ...",
  /// selain itu → "Terakhir aktif <tanggal>" dari kasir itu.
  String _lastActiveText(LoginEvent event, DateTime now) {
    final cashier = _cashierFor(event.cashierId);
    final seen = cashier?.lastSeenAt;
    if (cashier != null && isCashierLive(seen, now)) {
      final minutes = now.difference(seen!).inMinutes;
      if (minutes <= 0) return 'Masih login — terakhir sync baru saja';
      if (minutes == 1) return 'Masih login — terakhir sync 1 mnt lalu';
      return 'Masih login — terakhir sync $minutes mnt lalu';
    }
    if (seen == null) return 'Terakhir aktif —';
    return 'Terakhir aktif ${formatShortDateTime(seen)}';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final events = _events;
    final cashiers = _cashiers;
    final filtered = events == null
        ? null
        : _filter == 'Semua'
            ? events
            : events.where((e) => e.cashierName == _filter).toList();
    return Scaffold(
      appBar: AppBar(title: const ScreenTitle('Riwayat Login')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _error!,
                      style: const TextStyle(color: SukaTeaColors.danger),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _reload,
                      child: const Text('Coba lagi'),
                    ),
                  ],
                ),
              ),
            )
          else if (filtered == null || filtered.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Belum ada login tercatat.',
                  style: TextStyle(color: SukaTeaColors.muted),
                ),
              ),
            )
          else ...[
            if (cashiers != null && cashiers.isNotEmpty) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _filterChip('Semua'),
                    for (final c in cashiers) _filterChip(c.name),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            for (final event in filtered) _eventRow(event, now),
            const SizedBox(height: 12),
            const Text(
              'Login tercatat tiap kasir masuk dengan PIN. '
              'LIVE = HP-nya masih sync (≤ 5 menit).',
              style: TextStyle(color: SukaTeaColors.muted),
            ),
          ],
        ],
      ),
    );
  }

  Widget _filterChip(String label) {
    final selected = _filter == label;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _filter = label),
      ),
    );
  }

  Widget _eventRow(LoginEvent event, DateTime now) {
    final pill = _pillFor(event, now);
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
                    event.cashierName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
                if (pill != null) pill,
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Login ${formatShortDateTime(event.loginAt)} · '
              '${_outletName(event.outletId)}',
              style: const TextStyle(color: SukaTeaColors.muted),
            ),
            const SizedBox(height: 2),
            Text(
              _lastActiveText(event, now),
              style: const TextStyle(color: SukaTeaColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}
