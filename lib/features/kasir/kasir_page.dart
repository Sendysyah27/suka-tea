import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../data/local/outbox_service.dart';
import '../../data/models.dart';
import '../../data/seed_menu.dart';
import 'receipt.dart';

/// Layar Kasir — layar utama. Responsif:
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
  late final List<Product> _menu;

  @override
  void initState() {
    super.initState();
    _menu = seedMenu();
  }

  List<Product> get _visible => _category == 'Semua'
      ? _menu
      : _menu.where((p) => p.category == _category).toList();

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
    if (_cart.isEmpty) return;
    final items = List<CartItem>.from(_cart);
    final total = _total;
    final method = _method;
    // MVP: bayar pas (input nominal dibayar di M2).
    final paid = total;
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
          onCategory: (c) => setState(() => _category = c),
          onAdd: _add,
        );
        final cart = _CartPanel(
          cart: _cart,
          total: _total,
          method: _method,
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
              onCart: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => SizedBox(
                  height: MediaQuery.of(context).size.height * 0.75,
                  child: cart,
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

const _categories = ['Semua', 'Teh Klasik', 'Teh Buah', 'Teh Susu'];

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
    required this.onCategory,
    required this.onAdd,
  });

  final List<Product> visible;
  final String category;
  final ValueChanged<String> onCategory;
  final void Function(Product, ProductVariant) onAdd;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
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
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 230,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.78,
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
                      Text(p.name,
                          style: Theme.of(context).textTheme.titleMedium),
                      Text(p.category,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: SukaTeaColors.muted)),
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
                                  ),
                                  onPressed: () => onAdd(p, v),
                                  child: Text(v.name, overflow: TextOverflow.ellipsis),
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
    required this.onMethod,
    required this.onQty,
    required this.onBayar,
  });

  final List<CartItem> cart;
  final int total;
  final PaymentMethod method;
  final ValueChanged<PaymentMethod> onMethod;
  final void Function(int, int) onQty;
  final VoidCallback onBayar;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: SukaTeaColors.card,
        border: Border(left: BorderSide(color: SukaTeaColors.border)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Keranjang', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Expanded(
            child: cart.isEmpty
                ? const Center(child: Text('Belum ada item.\nTap ukuran di menu.'))
                : ListView.builder(
                    itemCount: cart.length,
                    itemBuilder: (context, i) {
                      final item = cart[i];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(item.label),
                        subtitle: Text(formatRupiah(item.unitPrice)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove),
                              onPressed: () => onQty(i, -1),
                            ),
                            Text('${item.qty}'),
                            IconButton(
                              icon: const Icon(Icons.add),
                              onPressed: () => onQty(i, 1),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final m in PaymentMethod.values)
                ChoiceChip(
                  label: Text(m.label),
                  selected: method == m,
                  onSelected: (_) => onMethod(m),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Total', style: TextStyle(fontWeight: FontWeight.bold)),
              Text(formatRupiah(total),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: cart.isEmpty ? null : onBayar,
            child: const Text('Bayar'),
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
    required this.onCart,
    required this.onBayar,
  });

  final int total;
  final int count;
  final VoidCallback onCart;
  final VoidCallback onBayar;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: SukaTeaColors.card,
        border: Border(top: BorderSide(color: SukaTeaColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: onCart,
              child: Text('Keranjang ($count) • ${formatRupiah(total)}'),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: count == 0 ? null : onBayar, child: const Text('Bayar')),
        ],
      ),
    );
  }
}
