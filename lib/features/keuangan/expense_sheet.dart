import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/sheet_pop.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/expense_service.dart';

/// Input sheet tambah pengeluaran — dikembalikan ke pemanggil
/// (KeuanganPage) yang memanggil ExpenseService.addExpense.
/// Sheet ini TIDAK menyentuh database / Supabase langsung, jadi
/// bisa di-test tanpa backend.
typedef ExpenseInput = ({
  String category,
  String description,
  int amount,
  bool isCash,
});

/// Sheet "Tambah Pengeluaran": chips kategori, nominal Rp,
/// deskripsi opsional, toggle Tunai / Non-tunai (default Tunai).
/// Mengembalikan [ExpenseInput] atau null bila batal. Tombol
/// konfirmasi nonaktif bila nominal 0 / kosong.
///
/// Tombol konfirmasi TIDAK pop langsung: pop jalan lewat
/// [popSheetSafely] — unfocus TextField + tunggu satu frame dulu.
/// Pop langsung saat TextField masih fokus = layar merah debug
/// (assertion '_dependents.isEmpty', 23 Nov 2026 16:01).
Future<ExpenseInput?> showExpenseSheet(BuildContext context) async {
  return showModalBottomSheet<ExpenseInput>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _ExpenseSheetContent(),
  );
}

/// Isi sheet sebagai StatefulWidget sendiri supaya TextEditingController
/// hidup PERSIS selama subtree sheet (initState -> dispose).
/// Pola ini wajib (CI v25.2): controller yang dibuat di luar builder
/// + dispose sesudah await showModalBottomSheet = "used after being
/// disposed" saat animasi keluar masih jalan.
class _ExpenseSheetContent extends StatefulWidget {
  const _ExpenseSheetContent();

  @override
  State<_ExpenseSheetContent> createState() => _ExpenseSheetContentState();
}

class _ExpenseSheetContentState extends State<_ExpenseSheetContent> {
  String category = expenseCategories.first;
  bool isCash = true;
  int amount = 0;
  late final TextEditingController amountController;
  late final TextEditingController descController;

  @override
  void initState() {
    super.initState();
    amountController = TextEditingController();
    descController = TextEditingController();
  }

  @override
  void dispose() {
    amountController.dispose();
    descController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = amount > 0;
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
            'Tambah Pengeluaran',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
          const SizedBox(height: 4),
          const Text(
            'Dicatat ke hari ini, gerai aktif.',
            style: TextStyle(color: SukaTeaColors.muted),
          ),
          const SizedBox(height: 16),
          const Text(
            'Kategori',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in expenseCategories)
                ChoiceChip(
                  label: Text(c),
                  selected: category == c,
                  onSelected: (_) => setState(() => category = c),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: amountController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Nominal (Rp)',
              hintText: 'mis. 25000',
            ),
            onChanged: (text) {
              final value = int.tryParse(text);
              if (value == null) return;
              setState(() => amount = value);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: descController,
            decoration: const InputDecoration(
              labelText: 'Deskripsi (opsional)',
              hintText: 'mis. beli es batu 2 bal',
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment<bool>(
                value: true,
                label: Text('Tunai'),
              ),
              ButtonSegment<bool>(
                value: false,
                label: Text('Non-tunai'),
              ),
            ],
            selected: {isCash},
            onSelectionChanged: (selected) =>
                setState(() => isCash = selected.first),
          ),
          const SizedBox(height: 4),
          const Text(
            'Tunai = keluar dari laci, mengurangi expected tutup kas.',
            style: TextStyle(color: SukaTeaColors.muted),
          ),
          const SizedBox(height: 16),
          TapFeedback(
            enabled: valid,
            child: FilledButton(
              onPressed: valid
                  ? () => popSheetSafely(
                        context,
                        (
                          category: category,
                          description: descController.text.trim(),
                          amount: amount,
                          isCash: isCash,
                        ),
                      )
                  : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 56),
              ),
              child: Text(
                valid
                    ? 'Simpan • -${formatRupiah(amount)}'
                    : 'Simpan pengeluaran',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
