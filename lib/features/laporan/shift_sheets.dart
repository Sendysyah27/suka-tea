import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/sheet_pop.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/cash_shift_service.dart';
import '../kasir/cashier_service.dart';

/// Jam "HH:mm" tanpa intl (repo belum memakai DateFormat di lib/).
String formatShiftTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Tanggal + jam "d MMM, HH:mm" (bulan Inggris — intl belum dipakai
/// di repo, jadi tidak ada locale id yang di-init).
String formatShiftDayTime(DateTime d) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'Mei',
    'Jun',
    'Jul',
    'Agu',
    'Sep',
    'Okt',
    'Nov',
    'Des',
  ];
  return '${d.day} ${months[d.month - 1]}, ${formatShiftTime(d)}';
}

/// Hasil sheet tutup kas: uang hasil hitungan + catatan.
typedef CloseShiftInput = ({int countedCash, String note});

/// Nama pembuka shift yang JUJUR (Batch C10.2 W5) — resolusi berurut:
/// (a) nama sesi kasir bila tidak kosong; (b) nama kasir terdaftar
/// dari registry yang sudah dimuat di memori ([CashierService]);
/// (c) peran Owner -> 'Owner'; (d) selain itu string KOSONG — UI
/// menampilkan '—'. Literal 'Kasir' TIDAK PERNAH disimpan sebagai
/// nama pembuka (itu identitas generik, bukan orang).
String resolveShiftOpenerName({
  required String cashierId,
  required String cashierName,
  required bool isOwner,
}) {
  final direct = cashierName.trim();
  if (direct.isNotEmpty) return direct;
  final id = cashierId.trim();
  if (id.isNotEmpty) {
    final known = CashierService.instance.knownNameFor(id)?.trim() ?? '';
    if (known.isNotEmpty) return known;
  }
  if (isOwner) return 'Owner';
  return '';
}

/// Label tampilan "Dibuka oleh": nama kosong -> '—' (bukan 'Kasir').
String shiftOpenerLabel(String name) {
  final trimmed = name.trim();
  return trimmed.isEmpty ? '—' : trimmed;
}

/// Alur buka shift lengkap (Batch C8.2 WS6 — dipakai gate POS
/// KasirPage + tombol "Buka Shift" LaporanPage): sheet modal awal ->
/// openNewShift (aturan C7: tolak bila sudah ada shift open di gerai
/// itu) -> shift yang dibuka, atau null bila batal / ditolak.
/// [cashierId]/[cashierName] = pembuka (Owner = '' / 'Owner').
/// [isOwner] (Batch C10.2 W5): true = sesi Owner tanpa nama kasir —
/// nama pembuka 'Owner'. Resolusi nama dilakukan DI SINI supaya
/// kedua call site ikut (lihat [resolveShiftOpenerName]).
Future<CashShift?> openShiftFlow(
  BuildContext context, {
  required String cashierId,
  required String cashierName,
  bool isOwner = false,
  String? outletId,
}) async {
  // v39: shift kemarin yang masih terbuka ditutup otomatis dulu,
  // supaya gate C7 tidak menolak buka shift hari ini.
  await CashShiftService.instance.autoCloseStaleShifts();
  if (!context.mounted) return null;
  final openerName = resolveShiftOpenerName(
    cashierId: cashierId,
    cashierName: cashierName,
    isOwner: isOwner,
  );
  final openingFloat = await showOpenShiftSheet(context);
  if (openingFloat == null) return null;
  if (!context.mounted) return null;
  final shift = await CashShiftService.instance.openNewShift(
    openingFloat: openingFloat,
    outletId: outletId,
    cashierId: cashierId,
    cashierName: openerName,
  );
  if (shift == null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Shift sudah dibuka — tutup dulu shift yang ada.'),
      ),
    );
  }
  return shift;
}

/// Sheet "Buka Shift": input modal awal laci (default Rp0).
/// Mengembalikan modal awal (int) atau null bila batal.
/// null dari pemanggil TIDAK sama dengan 0 — batal berarti shift
/// tidak dibuka sama sekali.
Future<int?> showOpenShiftSheet(BuildContext context) async {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _OpenShiftSheetContent(),
  );
}

/// Isi sheet sebagai StatefulWidget sendiri supaya TextEditingController
/// hidup PERSIS selama subtree sheet (initState -> dispose).
/// Pola ini wajib (CI v25.2): controller yang dibuat di luar builder
/// + dispose sesudah await showModalBottomSheet = "used after being
/// disposed" saat animasi keluar masih jalan.
class _OpenShiftSheetContent extends StatefulWidget {
  const _OpenShiftSheetContent();

  @override
  State<_OpenShiftSheetContent> createState() =>
      _OpenShiftSheetContentState();
}

class _OpenShiftSheetContentState extends State<_OpenShiftSheetContent> {
  int openingFloat = 0;
  late final TextEditingController controller;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: '0');
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle 30x4 (pola cash_sheet / discount_sheet).
          Center(
            child: Container(
              width: 30,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFC9D6CE),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Buka Shift',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
          const SizedBox(height: 4),
          const Text(
            'Modal awal laci untuk shift ini. Boleh Rp0.',
            style: TextStyle(color: SukaTeaColors.muted),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Modal awal (Rp)',
            ),
            onChanged: (text) {
              final value = int.tryParse(text);
              if (value == null) return;
              setState(() => openingFloat = value);
            },
          ),
          const SizedBox(height: 16),
          TapFeedback(
            child: FilledButton(
              onPressed: () =>
                  popSheetSafely(context, openingFloat),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 56),
              ),
              child: Text(
                'Buka Shift • ${formatRupiah(openingFloat)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sheet "Tutup Kas": input uang hasil hitungan + catatan opsional.
/// Preview live: rincian expected (modal + tunai masuk − pengeluaran
/// tunai) + selisih (dihitung − expected; hijau bila pas, merah bila
/// ada selisih — teks menjelaskan lebih/kurang).
/// Mengembalikan [CloseShiftInput] atau null bila batal.
///
/// [expectedLabel] (Batch C8.2 WS6): keterangan angka expected —
/// null = angka server (semua kasir + semua device); 'perkiraan
/// (offline)' = hitungan lokal HP ini saja (hanya penjualan device
/// ini yang terlihat). Label ini WAJIB tampil bila expected dari
/// hitungan lokal.
///
/// Tombol konfirmasi TIDAK pop langsung: pop jalan lewat
/// [popSheetSafely] — unfocus TextField + tunggu satu frame dulu.
/// Pop langsung saat TextField masih fokus = layar merah debug
/// (assertion '_dependents.isEmpty', 23 Nov 2026 16:01).
Future<CloseShiftInput?> showCloseShiftSheet(
  BuildContext context, {
  required CashShift shift,
  required int expected,
  required int cashIn,
  required int cashExpenses,
  String? expectedLabel,
}) async {
  return showModalBottomSheet<CloseShiftInput>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _CloseShiftSheetContent(
      shift: shift,
      expected: expected,
      cashIn: cashIn,
      cashExpenses: cashExpenses,
      expectedLabel: expectedLabel,
    ),
  );
}

class _CloseShiftSheetContent extends StatefulWidget {
  const _CloseShiftSheetContent({
    required this.shift,
    required this.expected,
    required this.cashIn,
    required this.cashExpenses,
    this.expectedLabel,
  });

  final CashShift shift;
  final int expected;
  final int cashIn;
  final int cashExpenses;
  final String? expectedLabel;

  @override
  State<_CloseShiftSheetContent> createState() =>
      _CloseShiftSheetContentState();
}

class _CloseShiftSheetContentState extends State<_CloseShiftSheetContent> {
  int counted = 0;
  late final TextEditingController countedController;
  late final TextEditingController noteController;

  @override
  void initState() {
    super.initState();
    countedController = TextEditingController();
    noteController = TextEditingController();
  }

  @override
  void dispose() {
    countedController.dispose();
    noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shift = widget.shift;
    final difference = counted - widget.expected;
    final differenceLabel = difference == 0
        ? 'Pas — tidak ada selisih.'
        : difference > 0
            ? 'Lebih ${formatRupiah(difference)} dari expected.'
            : 'Kurang ${formatRupiah(-difference)} dari expected.';
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 30,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFC9D6CE),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Tutup Kas',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
          const SizedBox(height: 4),
          Text(
            'Dibuka ${formatShiftTime(shift.openedAt)} • '
            '${shiftOpenerLabel(shift.cashierName)}',
            style: const TextStyle(color: SukaTeaColors.muted),
          ),
          const SizedBox(height: 16),
          _previewRow('Modal awal', shift.openingFloat),
          _previewRow('Tunai masuk', widget.cashIn),
          _previewRow('Pengeluaran tunai', -widget.cashExpenses),
          const Divider(height: 24),
          _previewRow('Expected di laci', widget.expected, bold: true),
          if (widget.expectedLabel != null) ...[
            const SizedBox(height: 4),
            Text(
              widget.expectedLabel!,
              style: const TextStyle(
                color: SukaTeaColors.muted,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Selisih',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                formatRupiah(difference),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: difference == 0
                      ? SukaTeaColors.emeraldDark
                      : SukaTeaColors.danger,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            differenceLabel,
            style: const TextStyle(color: SukaTeaColors.muted),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: countedController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Uang dihitung di laci (Rp)',
              hintText: 'Masukkan hasil hitungan…',
            ),
            onChanged: (text) {
              final value = int.tryParse(text);
              if (value == null) return;
              setState(() => counted = value);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: noteController,
            decoration: const InputDecoration(
              labelText: 'Catatan (opsional)',
              hintText: 'mis. uang 100rb di bawah laci',
            ),
          ),
          const SizedBox(height: 16),
          TapFeedback(
            child: FilledButton(
              onPressed: () => popSheetSafely(
                context,
                (
                  countedCash: counted,
                  note: noteController.text.trim(),
                ),
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 56),
              ),
              child: Text(
                'Tutup Kas • ${formatRupiah(counted)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewRow(String label, int amount, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          Text(
            formatRupiah(amount),
            style: TextStyle(
              fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
