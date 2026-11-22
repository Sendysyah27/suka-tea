import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/product_photo.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../data/local/outbox_service.dart';
import '../../data/models.dart';
import '../../data/seed_menu.dart';
import '../qris/qris_pay_page.dart';
import 'receipt.dart';

/// Layar Kasir — layar utama. Desain v2 "SUKA TEA Minimal Stylish":
/// kartu putih radius 20, foto produk blok mint, tombol Bayar 56px dengan
/// status "Memproses…" + anti double-tap. Responsif:
/// <600dp satu kolom + bar bawah, 600–840dp dua panel,
/// >840dp tiga zona (kategori | grid menu | keranjang permanen).
class KasirPage extends StatefulWidget {
  const KasirPage({super.key, required this.role});

  final AppRole role;

  @override
  State<KasirPage> createState() => _KasirPageState();
}

class _KasirPageState extends State<KasirPage> {
  final List<CartItem> _cart = [];
  PaymentMethod _method = PaymentMethod.tunai;
  String _category = 'Semua';
  String _query = '';
  bool _isProcessing = false;
  late final List<Product> _menu;

  @override
  void initState() {
    super.initState();
    _menu = seedMenu();
  }

  List<Product> get _visible {
    final byCategory = _category == 'Semua'
        ? _menu
        : _menu.where((p) => p.category == _category).toList();
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return byCategory;
    return byCategory.where((p) => p.name.toLowerCase().contains(q)).toList();
  }

  int get _total => _cart.fold(0, (sum, item) => sum + item.total);

  int get _count => _cart.fold(0, (sum, item) => sum + item.qty);

  void _add(Product product, ProductVariant variant) {
    setState(() {
      final index = _cart.indexWhere(
        (i) => i.product.id == product.id && i.variant.id == variant.id,
      );
      if (index >= 0) {
        _cart[index].qty++;
      } else {
        _cart.add(CartItem(
          product: product,
          variant: variant,
          modifiers: const [
            Modifier(name: 'Normal', kind: 'gula'),
            Modifier(name: 'Es Normal', kind: 'es'),
          ],
        ));
      }
    });
  }

  void _changeQty(int index, int delta) {
    setState(() {
      _cart[index].qty += delta;
      if (_cart[index].qty <= 0) _cart.removeAt(index);
    });
  }

  Future<void> _bayar() async {
    // Anti double-tap: tanpa guard ini, dua ketukan cepat meng-enqueue
    // dua transaksi yang sama (laporan Sendy: "tombol bayar kurang
    // responsif" — tidak ada feedback bahwa ketukan pertama diproses).
    if (_cart.isEmpty || _isProcessing) return;
    setState(() => _isProcessing = true);
    try {
      if (_method == PaymentMethod.qris) {
        // QRIS dinamis: nominal bisa di-custom di layar QRIS, konfirmasi
        // bayar manual oleh kasir (cek mutasi dulu).
        final items = List<CartItem>.from(_cart);
        final paidNominal = await Navigator.of(context).push<int>(
          MaterialPageRoute(
            builder: (_) => QrisPayPage(total: _total, role: widget.role),
          ),
        );
        if (paidNominal == null || !mounted) return;
        await _selesaikanBayar(
          items: items,
          total: paidNominal,
          method: PaymentMethod.qris,
          paid: paidNominal,
        );
        return;
      }
      final items = List<CartItem>.from(_cart);
      final total = _total;
      // Tunai/transfer/QRIS manual/e-wallet: bayar pas.
      await _selesaikanBayar(
        items: items,
        total: total,
        method: _method,
        paid: total,
      );
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  /// Catat transaksi ke outbox + tampilkan struk digital.
  Future<void> _selesaikanBayar({
    required List<CartItem> items,
    required int total,
    required PaymentMethod method,
    required int paid,
  }) async {
    await OutboxService.instance.enqueueSale({
      'client_uuid': DateTime.now().microsecondsSinceEpoch.toString(),
      'payment_method': method.name,
      'total': total,
      'items': items
          .map((i) => {'name': i.label, 'qty': i.qty, 'price': i.unitPrice})
          .toList(),
    });
    if (!mounted) return;
    setState(_cart.clear);
    await showDialog<void>(
      context: context,
      builder: (_) => DigitalReceiptDialog(
        items: items,
        method: method,
        total: total,
        paid: paid,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final menu = _MenuSection(
          visible: _visible,
          category: _category,
          query: _query,
          onQuery: (q) => setState(() => _query = q),
          onCategory: (c) => setState(() => _category = c),
          onAdd: _add,
        );
        final cart = _CartPanel(
          cart: _cart,
          total: _total,
          method: _method,
          isProcessing: _isProcessing,
          onMethod: (m) => setState(() => _method = m),
          onQty: _changeQty,
          onBayar: _bayar,
        );

        if (SukaTeaBreakpoints.isWide(width)) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 160, child: _CategoryRail(
                category: _category,
                onCategory: (c) => setState(() => _category = c),
              )),
              Expanded(child: menu),
              SizedBox(width: 340, child: cart),
            ],
          );
        }
        if (SukaTeaBreakpoints.isTablet(width)) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [Expanded(child: menu), SizedBox(width: 320, child: cart)],
          );
        }
        return Column(
          children: [
            Expanded(child: menu),
            _BottomBar(
              total: _total,
              count: _count,
              isProcessing: _isProcessing,
              // Sheet keranjang harus ikut ke-refresh tiap ada perubahan:
              // showModalBottomSheet itu route terpisah, jadi setState di
              // halaman Kasir TIDAK me-rebuild isi sheet (qty +/-, pilihan
              // cara bayar, dan isi setelah bayar jadi basi). StatefulBuilder
              // bikin sheet me-rebuild bareng setiap perubahan state.
              onCart: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (sheetContext) => StatefulBuilder(
                  builder: (context, setSheetState) {
                    void refreshSheet() => setSheetState(() {});
                    return SizedBox(
                      height: MediaQuery.of(context).size.height * 0.75,
                      child: _CartPanel(
                        cart: _cart,
                        total: _total,
                        method: _method,
                        isProcessing: _isProcessing,
                        onMethod: (m) {
                          setState(() => _method = m);
                          refreshSheet();
                        },
                        onQty: (i, d) {
                          _changeQty(i, d);
                          refreshSheet();
                        },
                        // Tutup sheet dulu baru proses bayar, supaya struk
                        // tidak ketumpuk di atas sheet berisi item lama.
                        onBayar: () {
                          Navigator.of(sheetContext).pop();
                          _bayar();
                        },
                      ),
                    );
                  },
                ),
              ),
              onBayar: _bayar,
            ),
          ],
        );
      },
    );
  }
}

const _categories = ['Semua', 'Best Seller', 'Milktea', 'Mixtea'];

class _CategoryRail extends StatelessWidget {
  const _CategoryRail({required this.category, required this.onCategory});

  final String category;
  final ValueChanged<String> onCategory;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final c in _categories)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ChoiceChip(
              label: Text(c),
              selected: category == c,
              onSelected: (_) => onCategory(c),
            ),
          ),
      ],
    );
  }
}

class _MenuSection extends StatelessWidget {
  const _MenuSection({
    required this.visible,
    required this.category,
    required this.query,
    required this.onQuery,
    required this.onCategory,
    required this.onAdd,
  });

  final List<Product> visible;
  final String category;
  final String query;
  final ValueChanged<String> onQuery;
  final ValueChanged<String> onCategory;
  final void Function(Product, ProductVariant) onAdd;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            onChanged: onQuery,
            decoration: InputDecoration(
              hintText: 'Cari es teh…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => onQuery(''),
                    ),
            ),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              for (final c in _categories)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(c),
                    selected: category == c,
                    onSelected: (_) => onCategory(c),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? const Center(
                  child: Text('Tidak ada menu yang cocok.\nCoba kata lain.'),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 230,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    // Tinggi sel tetap (bukan rasio): isi kartu butuh ~281dp
                    // di POVA 5 (foto 110 + nama + kategori + harga + tombol
                    // 48). Rasio 0.72 dulu bikin sel cuma ~247dp -> tombol
                    // Reguler/Jumbo overflow 34px (ketangkep screenshot
                    // 22 Nov 21:49).
                    mainAxisExtent: 300,
                  ),
                  itemCount: visible.length,
                  itemBuilder: (context, i) {
                    final p = visible[i];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Foto produk — default crop poster, Owner
                            // bisa ganti di Kelola Menu.
                            ProductPhoto(
                              photoUrl: p.photoUrl,
                              width: double.infinity,
                              height: 110,
                              iconSize: 32,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              p.name,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              p.category,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: SukaTeaColors.muted),
                            ),
                            const Spacer(),
                            Text(
                              '${formatRupiah(p.variants.first.price)} – '
                              '${formatRupiah(p.variants.last.price)}',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                for (final v in p.variants)
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 6),
                                      child: OutlinedButton(
                                        style: OutlinedButton.styleFrom(
                                          minimumSize: const Size(0, 48),
                                          padding: const EdgeInsets.symmetric(horizontal: 6),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                        ),
                                        onPressed: () => onAdd(p, v),
                                        child: Text(
                                          v.name,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _CartPanel extends StatelessWidget {
  const _CartPanel({
    required this.cart,
    required this.total,
    required this.method,
    required this.isProcessing,
    required this.onMethod,
    required this.onQty,
    required this.onBayar,
  });

  final List<CartItem> cart;
  final int total;
  final PaymentMethod method;
  final bool isProcessing;
  final ValueChanged<PaymentMethod> onMethod;
  final void Function(int, int) onQty;
  final VoidCallback onBayar;

  Widget _stepperButton(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: SukaTeaColors.leafBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: SukaTeaColors.border),
        ),
        child: Icon(icon, size: 18, color: SukaTeaColors.ink),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: SukaTeaColors.card,
        border: Border(left: BorderSide(color: SukaTeaColors.border)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Keranjang',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: cart.isEmpty
                ? const Center(
                    child: Text(
                      'Belum ada item.\nTap ukuran di menu.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: SukaTeaColors.muted),
                    ),
                  )
                : ListView.builder(
                    itemCount: cart.length,
                    itemBuilder: (context, i) {
                      final item = cart[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ProductPhoto(
                              photoUrl: item.product.photoUrl,
                              width: 40,
                              height: 40,
                              borderRadius: 10,
                              iconSize: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.label,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    formatRupiah(item.unitPrice),
                                    style: const TextStyle(
                                      color: SukaTeaColors.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _stepperButton(
                                  Icons.remove,
                                  () => onQty(i, -1),
                                ),
                                SizedBox(
                                  width: 32,
                                  child: Center(
                                    child: Text(
                                      '${item.qty}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                                _stepperButton(
                                  Icons.add,
                                  () => onQty(i, 1),
                                ),
                              ],
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 64,
                              child: Text(
                                formatRupiah(item.total),
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in PaymentMethod.values)
                ChoiceChip(
                  label: Text(m.label),
                  selected: method == m,
                  onSelected: (_) => onMethod(m),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              Text(
                formatRupiah(total),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: (cart.isEmpty || isProcessing) ? null : onBayar,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
            child: Text(
              isProcessing
                  ? 'Memproses…'
                  : 'Bayar • ${formatRupiah(total)}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.total,
    required this.count,
    required this.isProcessing,
    required this.onCart,
    required this.onBayar,
  });

  final int total;
  final int count;
  final bool isProcessing;
  final VoidCallback onCart;
  final VoidCallback onBayar;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        color: SukaTeaColors.card,
        border: Border(top: BorderSide(color: SukaTeaColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: onCart,
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: EdgeInsets.zero,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Keranjang ($count item)',
                      style: const TextStyle(
                        color: SukaTeaColors.muted,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      formatRupiah(total),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: SukaTeaColors.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: (count == 0 || isProcessing) ? null : onBayar,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
              child: Text(
                isProcessing ? 'Memproses…' : 'Bayar',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
