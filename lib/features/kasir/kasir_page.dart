import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/discount.dart';
import '../../core/utils/money.dart';
import '../../core/utils/roles.dart';
import '../../core/utils/split_payment.dart';
import '../../core/widgets/product_photo.dart';
import '../../core/widgets/screen_title.dart';
import '../../core/widgets/tap_feedback.dart';
import '../../data/held_order_service.dart';
import '../../data/local/outbox_service.dart';
import '../../data/menu_service.dart';
import '../../data/models.dart';
import '../../data/recipe_logic.dart';
import '../../data/sale_history.dart';
import '../../data/seed_menu.dart';
import '../../data/stock_service.dart';
import '../qris/qris_pay_page.dart';
import 'cash_sheet.dart';
import 'discount_sheet.dart';
import 'product_options_sheet.dart';
import 'receipt.dart';

/// Layar Kasir — desain v2 "SUKA TEA Minimal Stylish" + mockup frame 01:
/// kartu produk 186px (foto 80 + tombol "+" lingkaran 36 emerald),
/// bottom bar satu baris, keranjang kartu radius 20 + stepper bulat 28.
/// Responsif: <600dp satu kolom + bar bawah, 600–840dp dua panel,
/// >840dp tiga zona (kategori | grid menu | keranjang permanen).
///
/// Menu dibaca dari MenuService (SATU sumber dengan Kelola Menu).
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

  /// Diskon manual keranjang aktif (nominal Rp, 0..subtotal).
  /// TIDAK ikut disimpan sebagai Pending bersama order (diskon itu per keranjang
  /// aktif; saat pulih dari Pending, diskon mulai dari 0).
  int _discount = 0;

  /// Persen diskon aktif (0 = mode rupiah / tanpa diskon). Hanya
  /// untuk tampilan "(N%)" di keranjang + struk — yang disimpan di
  /// riwayat tetap nominal rupiah (SaleHistory.discount).
  int _discountPercent = 0;

  List<Product> get _menu => MenuService.instance.products;

  List<Product> get _visible {
    final byCategory = _category == 'Semua'
        ? _menu
        : _menu.where((p) => p.category == _category).toList();
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return byCategory;
    return byCategory.where((p) => p.name.toLowerCase().contains(q)).toList();
  }

  /// Subtotal sebelum diskon.
  int get _subtotal => _cart.fold(0, (sum, item) => sum + item.total);

  /// Total yang dibayar = subtotal - diskon (tidak pernah negatif).
  int get _total => payableAfterDiscount(_subtotal, _discount);

  int get _count => _cart.fold(0, (sum, item) => sum + item.qty);

  bool _sameModifiers(List<Modifier> a, List<Modifier> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].kind != b[i].kind ||
          a[i].name != b[i].name ||
          a[i].priceDelta != b[i].priceDelta) {
        return false;
      }
    }
    return true;
  }

  void _add(
    Product product,
    ProductVariant variant,
    List<Modifier> modifiers,
  ) {
    setState(() {
      final index = _cart.indexWhere(
        (i) =>
            i.product.id == product.id &&
            i.variant.id == variant.id &&
            _sameModifiers(i.modifiers, modifiers),
      );
      if (index >= 0) {
        _cart[index].qty++;
      } else {
        _cart.add(
          CartItem(product: product, variant: variant, modifiers: modifiers),
        );
      }
    });
  }

  /// Tap "+": tambah cepat varian Reguler, gula Normal, es Normal,
  /// tanpa topping (perilaku default mockup).
  void _quickAdd(Product product) {
    _add(product, product.variants.first, [gulaOptions.first, esOptions.first]);
  }

  /// Tap kartu: sheet pilihan varian + gula + es + topping.
  Future<void> _openOptions(Product product) async {
    if (!product.isActive) return;
    final selection = await showProductOptionsSheet(context, product);
    if (selection == null || !mounted) return;
    _add(product, selection.variant, selection.modifiers);
  }

  void _changeQty(int index, int delta) {
    setState(() {
      _cart[index].qty += delta;
      if (_cart[index].qty <= 0) _cart.removeAt(index);
    });
  }

  void _removeItem(int index) {
    setState(() => _cart.removeAt(index));
  }

  /// Jumlah bahan gaya Indonesia: pcs bulat, kg max 3 desimal koma.
  String _fmtQty(double v, String unit) {
    if (unit == 'pcs') return v.toStringAsFixed(0);
    var s = v.toStringAsFixed(3);
    s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    return s.replaceAll('.', ',');
  }

  /// Dialog konfirmasi saat ada bahan yang tidak cukup. true = tetap jual
  /// (stok dipotong sampai 0), false = batal (cart utuh).
  Future<bool> _confirmShortage(List<Shortage> shortages) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stok bahan kurang'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Bahan berikut tidak cukup untuk pesanan ini:'),
            const SizedBox(height: 8),
            for (final s in shortages)
              Text(
                '• ${s.stockName}: butuh ${_fmtQty(s.needed, s.unit)} '
                '${s.unit}, sisa ${_fmtQty(s.available, s.unit)} ${s.unit}',
              ),
            const SizedBox(height: 8),
            const Text('Tetap jual akan memotong stok sampai 0.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Tetap jual'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _bayar() async {
    // Anti double-tap: tanpa guard ini, dua ketukan cepat meng-enqueue
    // dua transaksi yang sama (laporan Sendy: "tombol bayar kurang
    // responsif" — tidak ada feedback bahwa ketukan pertama diproses).
    if (_cart.isEmpty || _isProcessing) return;
    setState(() => _isProcessing = true);
    try {
      // Cek stok bahan dulu — SEBELUM layar QRIS / uang diterima dibuka.
      // Kalau ada yang kurang, kasir memilih: batal (cart utuh,
      // _isProcessing direset oleh finally) atau tetap jual.
      // checkCart memakai computeDeductions — topping ikut dicek
      // (1 porsi per topping per cup, Batch C1).
      final shortages = StockService.instance.checkCart(_cart);
      if (shortages.isNotEmpty) {
        final lanjut = await _confirmShortage(shortages);
        if (!lanjut || !mounted) return;
      }
      if (_method == PaymentMethod.split) {
        // Split (Batch C2): sebagian QRIS + sebagian tunai.
        // 1) Layar QRIS mode split: nominal = bagian QRIS saja
        //    (min Rp1.000, harus kurang dari total).
        // 2) Sheet tunai untuk sisanya (total - bagian QRIS).
        // paid = bagian QRIS + tunai diterima; kembalian HANYA dari
        // tunai (cashReceived - sisa tunai).
        final items = List<CartItem>.from(_cart);
        final total = _total;
        final discount = _discount;
        final discountPercent = _discountPercent;
        final qrisAmount = await Navigator.of(context).push<int>(
          MaterialPageRoute(
            builder: (_) => QrisPayPage(
              total: total,
              role: widget.role,
              splitMode: true,
            ),
          ),
        );
        if (qrisAmount == null || !mounted) return;
        final remainder =
            splitCashRemainder(total: total, qrisAmount: qrisAmount);
        // Kaki QRIS sudah dibayar saat sampai di sini — sheet tunai
        // TIDAK BOLEH batal diam-diam (uang QRIS masuk, penjualan
        // tidak tercatat). Batal = dialog dulu: lanjut bayar tunai
        // atau batalkan split dengan sadar.
        int? cashReceived;
        while (cashReceived == null) {
          // Guard mounted di tiap putaran: context dipakai sesudah
          // await (push QRIS / showDialog putaran sebelumnya) — tanpa
          // ini analyzer menandai use_build_context_synchronously
          // (CI v27.1).
          if (!mounted) return;
          cashReceived = await showCashReceivedSheet(
            context,
            remainder,
            subtitle:
                'Sisa tunai setelah QRIS ${formatRupiah(qrisAmount)}',
          );
          if (cashReceived == null) {
            if (!mounted) return;
            final lanjutTunai = await showDialog<bool>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('Sisa tunai belum dibayar'),
                content: Text(
                  'Pembayaran QRIS ${formatRupiah(qrisAmount)} sudah '
                  'diterima. Selesaikan sisa tunai '
                  '${formatRupiah(remainder)}, atau batalkan split '
                  '(keranjang tetap, tapi uang QRIS sudah masuk).',
                ),
                actions: [
                  TextButton(
                    onPressed: () =>
                        Navigator.of(dialogContext).pop(false),
                    child: const Text('Batalkan'),
                  ),
                  FilledButton(
                    onPressed: () =>
                        Navigator.of(dialogContext).pop(true),
                    child: const Text('Bayar tunai'),
                  ),
                ],
              ),
            );
            if (lanjutTunai != true) return;
          }
        }
        if (!mounted) return;
        await _selesaikanBayar(
          items: items,
          total: total,
          discount: discount,
          discountPercent: discountPercent,
          method: PaymentMethod.split,
          paid: qrisAmount + cashReceived,
          qrisAmount: qrisAmount,
          cashAmount: cashReceived,
        );
        return;
      }
      if (_method == PaymentMethod.qris) {
        // QRIS dinamis: nominal bisa di-custom di layar QRIS, konfirmasi
        // bayar manual oleh kasir (cek mutasi dulu).
        // Total penjualan = total keranjang SESUDAH diskon; paid =
        // nominal QRIS yang dibayar (bisa beda karena custom/bulatkan)
        // — selisihnya tercatat sebagai kembalian, omzet tidak ikut
        // membengkak.
        final items = List<CartItem>.from(_cart);
        final total = _total;
        final discount = _discount;
        final discountPercent = _discountPercent;
        final paidNominal = await Navigator.of(context).push<int>(
          MaterialPageRoute(
            builder: (_) => QrisPayPage(total: total, role: widget.role),
          ),
        );
        if (paidNominal == null || !mounted) return;
        await _selesaikanBayar(
          items: items,
          total: total,
          discount: discount,
          discountPercent: discountPercent,
          method: PaymentMethod.qris,
          paid: paidNominal,
        );
        return;
      }
      final items = List<CartItem>.from(_cart);
      final total = _total;
      final discount = _discount;
      final discountPercent = _discountPercent;
      var paid = total;
      if (_method == PaymentMethod.tunai) {
        // Tunai: tanya uang diterima dulu (nominal cepat + manual),
        // kembalian dihitung live di sheet.
        final received = await showCashReceivedSheet(context, total);
        if (received == null || !mounted) return;
        paid = received;
      }
      // Transfer / QRIS manual / E-Wallet: bayar pas.
      await _selesaikanBayar(
        items: items,
        total: total,
        discount: discount,
        discountPercent: discountPercent,
        method: _method,
        paid: paid,
      );
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  /// Buka sheet diskon manual. Nilai kembali = diskon baru (0 =
  /// hapus diskon) + persennya (0 = mode rupiah). Dipanggil dari
  /// panel keranjang.
  Future<void> _editDiscount() async {
    if (_cart.isEmpty) return;
    final result = await showDiscountSheet(
      context,
      subtotal: _subtotal,
      currentDiscount: _discount,
      currentPercent: _discountPercent,
    );
    if (result == null || !mounted) return;
    setState(() {
      _discount = result.amount;
      _discountPercent = result.percent;
    });
  }

  /// Simpan keranjang saat ini sebagai order Pending (label otomatis
  /// "Pending N • HH:mm"), lalu kosongkan keranjang + diskon.
  Future<void> _holdCart() async {
    if (_cart.isEmpty || _isProcessing) return;
    final held =
        await HeldOrderService.instance.hold(List<CartItem>.from(_cart));
    if (!mounted) return;
    setState(() {
      _cart.clear();
      _discount = 0;
      _discountPercent = 0;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Keranjang disimpan sebagai Pending ${held.label}.'),
      ),
    );
  }

  /// Daftar order Pending (bottom sheet). Tap satu order = pulihkan
  /// ke keranjang. Pulih hanya bila keranjang kosong; bila berisi,
  /// kasir memilih "Pending & Buka" (keranjang saat ini ikut disimpan)
  /// atau "Batal".
  Future<void> _showHeldOrders() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: HeldOrderService.instance,
        builder: (context, _) {
          final held = HeldOrderService.instance.orders;
          // Pola sheet yang sudah ada (kasir): SingleChildScrollView +
          // daftar shrinkWrap (tanpa Flexible — flex di dalam sheet
          // yang tingginya mengikuti konten bisa overflow).
          return SingleChildScrollView(
            child: Padding(
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
                    'Order Pending',
                    style:
                        TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Ketuk satu order untuk memulihkannya ke keranjang.',
                    style: TextStyle(color: SukaTeaColors.muted),
                  ),
                  const SizedBox(height: 12),
                  if (held.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'Belum ada order Pending.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: SukaTeaColors.muted),
                      ),
                    )
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: held.length,
                      itemBuilder: (context, i) {
                        final order = held[i];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: InkWell(
                            onTap: () =>
                                _restoreHeld(order, sheetContext),
                            borderRadius: BorderRadius.circular(20),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          order.label,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 15,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          order.summary,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: SukaTeaColors.muted,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${order.count} cup • '
                                          '${formatRupiah(order.subtotal)}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: SukaTeaColors.emerald,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Hapus order Pending',
                                    icon: const Icon(Icons.close),
                                    onPressed: () =>
                                        _deleteHeld(order, sheetContext),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
              ],
            ),
          ),
        );
        },
      ),
    );
  }

  /// Pulihkan satu order Pending ke keranjang.
  Future<void> _restoreHeld(HeldOrder order, BuildContext sheetContext) async {
    if (_cart.isNotEmpty) {
      final holdFirst = await showDialog<bool>(
        context: sheetContext,
        builder: (context) => AlertDialog(
          title: const Text('Keranjang berisi'),
          content: const Text(
            'Keranjang saat ini berisi item. Simpan dulu keranjang ini '
            'sebagai Pending sebelum membuka order Pending?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Pending & Buka'),
            ),
          ],
        ),
      );
      if (holdFirst != true || !mounted) return;
      await HeldOrderService.instance.hold(List<CartItem>.from(_cart));
      if (!mounted) return;
      setState(() {
        _cart.clear();
        _discount = 0;
        _discountPercent = 0;
      });
    }
    final items = await HeldOrderService.instance.restore(order.id);
    if (items == null || !mounted || !sheetContext.mounted) return;
    Navigator.of(sheetContext).pop();
    setState(() {
      _cart.addAll(items);
      _discount = 0;
      _discountPercent = 0;
    });
  }

  /// Hapus order Pending tanpa memulihkan (konfirmasi dulu).
  Future<void> _deleteHeld(HeldOrder order, BuildContext sheetContext) async {
    final ok = await showDialog<bool>(
      context: sheetContext,
      builder: (context) => AlertDialog(
        title: Text('Hapus ${order.label}?'),
        content: const Text(
          'Order Pending ini hilang. Item di dalamnya ikut terhapus.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: SukaTeaColors.danger,
            ),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await HeldOrderService.instance.remove(order.id);
  }

  /// Catat transaksi ke outbox + riwayat, potong stok, tampilkan struk.
  /// [discountPercent] hanya untuk tampilan "(N%)" di struk — yang
  /// disimpan di riwayat tetap nominal rupiah [discount].
  /// [qrisAmount]/[cashAmount] = bagian split (Batch C2); non-split = 0.
  Future<void> _selesaikanBayar({
    required List<CartItem> items,
    required int total,
    required int discount,
    required PaymentMethod method,
    required int paid,
    int discountPercent = 0,
    int qrisAmount = 0,
    int cashAmount = 0,
  }) async {
    await OutboxService.instance.enqueueSale({
      'client_uuid': DateTime.now().microsecondsSinceEpoch.toString(),
      'payment_method': method.name,
      'total': total,
      'discount': discount,
      'qris_amount': qrisAmount,
      'cash_amount': cashAmount,
      'items': items
          .map((i) => {'name': i.label, 'qty': i.qty, 'price': i.unitPrice})
          .toList(),
    });
    // Potong stok bahan sesuai resep item yang terjual (clamp di 0).
    final newlyLow = await StockService.instance.deductForSale(items);
    // Catat ke riwayat SESUDAH potong stok (untuk Keuangan/Laporan).
    await SaleHistoryService.instance.recordSale(
      items: items,
      total: total,
      method: method,
      paid: paid,
      discount: discount,
      qrisAmount: qrisAmount,
      cashAmount: cashAmount,
    );
    if (!mounted) return;
    setState(() {
      _cart.clear();
      _discount = 0;
      _discountPercent = 0;
    });
    final lines = items.map(ReceiptLine.fromCartItem).toList();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DigitalReceiptPage(
          lines: lines,
          method: method,
          total: total,
          paid: paid,
          discount: discount,
          discountPercent: discountPercent,
          qrisAmount: qrisAmount,
          cashAmount: cashAmount,
          cashier: widget.role == AppRole.owner ? 'Owner' : 'Kasir',
        ),
      ),
    );
    // Peringatan menipis tampil SESUDAH struk ditutup (SnackBar di bawah
    // halaman struk tidak kelihatan).
    if (newlyLow.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Stok menipis: ${newlyLow.join(', ')} — cek tab Stok',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // MenuService = sumber menu; rebuild bila Kelola Menu mengubahnya.
    return ListenableBuilder(
      listenable: MenuService.instance,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final menu = _MenuSection(
              visible: _visible,
              category: _category,
              query: _query,
              onQuery: (q) => setState(() => _query = q),
              onCategory: (c) => setState(() => _category = c),
              onQuickAdd: _quickAdd,
              onOptions: _openOptions,
            );
            // Panel keranjang mendengarkan HeldOrderService supaya
            // angka "Pending (N)" ikut berubah saat order di-Pending /
            // dipulihkan / dihapus (tanpa menunggu setState Kasir).
            final cart = ListenableBuilder(
              listenable: HeldOrderService.instance,
              builder: (context, _) => _CartPanel(
                cart: _cart,
                subtotal: _subtotal,
                discount: _discount,
                discountPercent: _discountPercent,
                total: _total,
                method: _method,
                isProcessing: _isProcessing,
                heldCount: HeldOrderService.instance.orders.length,
                onMethod: (m) => setState(() => _method = m),
                onQty: _changeQty,
                onRemove: _removeItem,
                onBayar: _bayar,
                onHold: _holdCart,
                onShowHeld: _showHeldOrders,
                onDiscount: _editDiscount,
              ),
            );

            if (SukaTeaBreakpoints.isWide(width)) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 160,
                    child: _CategoryRail(
                      category: _category,
                      onCategory: (c) => setState(() => _category = c),
                    ),
                  ),
                  Expanded(child: menu),
                  SizedBox(width: 340, child: cart),
                ],
              );
            }
            if (SukaTeaBreakpoints.isTablet(width)) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: menu),
                  SizedBox(width: 320, child: cart),
                ],
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
                  // Sheet mengecil mengikuti konten (shrink: tidak ada ruang
                  // mati 75% saat keranjang kosong).
                  onCart: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (sheetContext) => StatefulBuilder(
                      builder: (context, setSheetState) {
                        void refreshSheet() => setSheetState(() {});
                        return SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Drag handle 30x4 (FigCraft frame 02).
                              const SizedBox(height: 12),
                              Container(
                                width: 30,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFC9D6CE),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              _CartPanel(
                                shrink: true,
                                cart: _cart,
                                subtotal: _subtotal,
                                discount: _discount,
                                discountPercent: _discountPercent,
                                total: _total,
                                method: _method,
                                isProcessing: _isProcessing,
                                heldCount:
                                    HeldOrderService.instance.orders.length,
                                onMethod: (m) {
                                  setState(() => _method = m);
                                  refreshSheet();
                                },
                                onQty: (i, d) {
                                  _changeQty(i, d);
                                  refreshSheet();
                                },
                                onRemove: (i) {
                                  _removeItem(i);
                                  refreshSheet();
                                },
                                // Tutup sheet dulu baru proses bayar, supaya struk
                                // tidak ketumpuk di atas sheet berisi item lama.
                                onBayar: () {
                                  Navigator.of(sheetContext).pop();
                                  _bayar();
                                },
                                onHold: () async {
                                  await _holdCart();
                                  refreshSheet();
                                },
                                onShowHeld: () async {
                                  await _showHeldOrders();
                                  refreshSheet();
                                },
                                onDiscount: () async {
                                  await _editDiscount();
                                  refreshSheet();
                                },
                              ),
                            ],
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
    required this.onQuickAdd,
    required this.onOptions,
  });

  final List<Product> visible;
  final String category;
  final String query;
  final ValueChanged<String> onQuery;
  final ValueChanged<String> onCategory;
  final ValueChanged<Product> onQuickAdd;
  final ValueChanged<Product> onOptions;

  /// Rentang harga kartu (FigCraft frame 01): "Rp8.000 – Rp10.000".
  /// Produk 1 varian / harga sama = harga tunggal.
  static String _priceRange(Product p) {
    final first = p.variants.first.price;
    final last = p.variants.last.price;
    if (p.variants.length < 2 || first == last) {
      return formatRupiah(first);
    }
    return '${formatRupiah(first)} – ${formatRupiah(last)}';
  }

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
              prefixIcon: Padding(
                padding: const EdgeInsets.all(12),
                child: SvgPicture.asset(
                  AppIcons.cari,
                  width: 20,
                  height: 20,
                  colorFilter: const ColorFilter.mode(
                    SukaTeaColors.muted,
                    BlendMode.srcIn,
                  ),
                ),
              ),
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
                    // Tinggi sel tetap (bukan rasio): port presisi dari
                    // FigCraft frame 01 (kartu 171x164) — foto 72 + 8 +
                    // nama 15 + kategori 12 + 4 + harga 14 + padding 20
                    // ≈ 161dp isi + margin Card 4+4; sel 172 kasih
                    // slack ~5dp. (186 pernah overflow 8px — ketangkep
                    // flutter test 23 Nov 00:44; 196 kebanyakan ruang
                    // kosong di bawah harga — keluhan screenshot v16.)
                    mainAxisExtent: 172,
                  ),
                  itemCount: visible.length,
                  itemBuilder: (context, i) {
                    final p = visible[i];
                    return InkWell(
                      onTap: p.isActive ? () => onOptions(p) : null,
                      borderRadius: BorderRadius.circular(20),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Foto produk 72px blok mint radius 12
                              // (FigCraft frame 01) + tombol "+" yang
                              // mengambang di pojok kanan-bawah foto:
                              // Positioned bottom -12 (12px menjorok ke
                              // bawah foto, sama seperti FigCraft) —
                              // Stack pakai Clip.none supaya tidak
                              // terpotong; ujung bawah tombol hanya
                              // menyentuh 4px atas baris nama (sama
                              // seperti geometri FigCraft) dan nama
                              // pendek tidak pernah mencapai tombol.
                              // Produk habis: label "Habis" di foto +
                              // tombol "+" nonaktif.
                              Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  ProductPhoto(
                                    photoUrl: p.photoUrl,
                                    width: double.infinity,
                                    height: 72,
                                    borderRadius: 12,
                                    iconSize: 28,
                                  ),
                                  if (!p.isActive)
                                    Positioned(
                                      right: 6,
                                      top: 6,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: SukaTeaColors.danger,
                                          borderRadius:
                                              BorderRadius.circular(999),
                                        ),
                                        child: const Text(
                                          'Habis',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  Positioned(
                                    right: 0,
                                    bottom: -12,
                                    child: TapFeedback(
                                      enabled: p.isActive,
                                      child: InkWell(
                                        onTap: p.isActive
                                            ? () => onQuickAdd(p)
                                            : null,
                                        borderRadius:
                                            BorderRadius.circular(10),
                                        child: Container(
                                          width: 36,
                                          height: 36,
                                          decoration: BoxDecoration(
                                            color: p.isActive
                                                ? SukaTeaColors.emerald
                                                : SukaTeaColors.border,
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          child: const Icon(
                                            Icons.add,
                                            size: 20,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                p.name,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                p.category,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: SukaTeaColors.muted,
                                ),
                              ),
                              const SizedBox(height: 4),
                              // Harga RENTANG satu baris penuh (FigCraft
                              // frame 01: "Rp8.000 – Rp10.000", 14 Bold
                              // emerald) — tombol "+" sudah pindah ke
                              // foto, jadi harga tidak lagi berebut
                              // lebar dengan tombol. Produk 1 varian =
                              // harga tunggal.
                              Text(
                                _priceRange(p),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: SukaTeaColors.emerald,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
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
    required this.subtotal,
    required this.discount,
    required this.discountPercent,
    required this.total,
    required this.method,
    required this.isProcessing,
    required this.heldCount,
    required this.onMethod,
    required this.onQty,
    required this.onRemove,
    required this.onBayar,
    required this.onHold,
    required this.onShowHeld,
    required this.onDiscount,
    this.shrink = false,
  });

  final List<CartItem> cart;

  /// Subtotal sebelum diskon (untuk baris Subtotal saat diskon > 0).
  final int subtotal;

  /// Diskon manual keranjang aktif (0 = tanpa diskon).
  final int discount;

  /// Persen diskon aktif (0 = mode rupiah). Hanya untuk tampilan
  /// "(N%)" di baris Diskon — nominal yang disimpan tetap [discount].
  final int discountPercent;

  /// Total yang dibayar = subtotal - diskon.
  final int total;
  final PaymentMethod method;
  final bool isProcessing;

  /// Jumlah order yang sedang di-Pending (untuk chip "Pending (N)").
  final int heldCount;
  final ValueChanged<PaymentMethod> onMethod;
  final void Function(int, int) onQty;
  final void Function(int) onRemove;
  final VoidCallback onBayar;

  /// Simpan keranjang saat ini sebagai order Pending.
  final VoidCallback onHold;

  /// Buka daftar order Pending.
  final VoidCallback onShowHeld;

  /// Buka sheet diskon manual.
  final VoidCallback onDiscount;

  /// true = di bottom sheet HP: kolom mengecil mengikuti konten
  /// (bukan Expanded + tinggi tetap 75%).
  final bool shrink;

  /// Tombol stepper −/+ 28x28 radius 8 (FigCraft frame 02, v22):
  /// bukan lingkaran lagi. "+" emerald terisi, "−" outline.
  Widget _stepButton({
    required bool filled,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return TapFeedback(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: filled ? SukaTeaColors.emerald : SukaTeaColors.card,
            borderRadius: BorderRadius.circular(8),
            border: filled
                ? null
                : Border.all(color: SukaTeaColors.border, width: 1.5),
          ),
          child: Icon(
            icon,
            size: 16,
            color: filled ? Colors.white : SukaTeaColors.ink,
          ),
        ),
      ),
    );
  }

  /// Tombol × hapus langsung 28x28 radius 8 (FigCraft frame 02, v24):
  /// glyph × merah #D64545 di #FCECEC, di kiri tombol "−" — baris
  /// stepper jadi [×][−][angka][+].
  Widget _deleteButton({required VoidCallback onTap}) {
    return TapFeedback(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: SukaTeaColors.deleteBg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Center(
            child: Text(
              '×',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: SukaTeaColors.danger,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Ikon + sublabel tiap cara bayar (FigCraft frame 02). Label
  /// memakai method.label dari model (logika tidak diubah); sublabel
  /// + ikon hanya presentasi, jadi peta ini tinggal di sini, bukan
  /// di lib/data.
  static const Map<PaymentMethod, (String, String)> _methodMeta = {
    PaymentMethod.tunai: ('Bayar di kasir', AppIcons.payTunai),
    PaymentMethod.transfer: ('BCA / Mandiri', AppIcons.payTransfer),
    PaymentMethod.qris: ('Scan kode QR', AppIcons.payQris),
    PaymentMethod.qrisManual:
        ('Masukkan kode manual', AppIcons.payQrisManual),
    PaymentMethod.ewallet: ('GoPay / OVO / DANA', AppIcons.payEwallet),
    PaymentMethod.split: ('QRIS + Tunai', AppIcons.paySplit),
  };

  /// Payment sheet ala FigCraft frame 02 (Stripe pattern): satu kartu
  /// putih berisi 6 baris metode (Batch C2 menambah Split) — tile ikon
  /// mint 36x36 r10 + nama 14 SemiBold + sublabel 12 muted + radio 22
  /// di kanan; baris terpilih tint #EAF6EF + centang emerald; divider
  /// inset antar baris.
  /// Mode pendek (<430dp) TIDAK pakai kartu ini (230px tidak muat) —
  /// tetap chip 1 baris scroll (perbaikan overflow 22 Nov 22:19).
  Widget _methodCard() {
    return Container(
      decoration: BoxDecoration(
        color: SukaTeaColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SukaTeaColors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < PaymentMethod.values.length; i++) ...[
            if (i > 0)
              const Divider(
                height: 1,
                indent: 60,
                color: SukaTeaColors.border,
              ),
            _methodRow(PaymentMethod.values[i]),
          ],
        ],
      ),
    );
  }

  Widget _methodRow(PaymentMethod m) {
    final selected = method == m;
    final (sub, iconAsset) = _methodMeta[m]!;
    return InkWell(
      onTap: () => onMethod(m),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: selected ? SukaTeaColors.tint : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: SukaTeaColors.mint,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: SvgPicture.asset(
                  iconAsset,
                  width: 24,
                  height: 24,
                  colorFilter: const ColorFilter.mode(
                    SukaTeaColors.emerald,
                    BlendMode.srcIn,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.label,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    sub,
                    style: const TextStyle(
                      fontSize: 12,
                      color: SukaTeaColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? SukaTeaColors.emerald
                    : Colors.transparent,
                border: selected
                    ? null
                    : Border.all(
                        color: SukaTeaColors.border,
                        width: 1.5,
                      ),
              ),
              child: selected
                  ? const Icon(Icons.check, size: 14, color: Colors.white)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _bayarButton() {
    return TapFeedback(
      enabled: cart.isNotEmpty && !isProcessing,
      child: FilledButton(
        onPressed: (cart.isEmpty || isProcessing) ? null : onBayar,
        style: FilledButton.styleFrom(
        minimumSize: const Size(0, 56),
        // Padding horizontal M3 default (24) + ikon + label panjang
        // ("Bayar • Rp8.000") overflow 0,5px di panel 320dp (test 23 Nov
        // 01:31 — font test Ahem lebih lebar dari Plus Jakarta Sans).
        // Padding 16 + label Flexible/ellipsis: total besar tetap muat.
        padding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (isProcessing) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Memproses…',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ] else ...[
            SvgPicture.asset(
              AppIcons.bayar,
              width: 20,
              height: 20,
              colorFilter: const ColorFilter.mode(
                Colors.white,
                BlendMode.srcIn,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: child,
                ),
                child: Text(
                  'Bayar • ${formatRupiah(total)}',
                  key: ValueKey<int>(total),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ],
      ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = cart.isEmpty
        ? const Center(
            child: Text(
              'Belum ada item.\nTap + di menu untuk menambah.',
              textAlign: TextAlign.center,
              style: TextStyle(color: SukaTeaColors.muted),
            ),
          )
        : ListView.builder(
            shrinkWrap: shrink,
            physics:
                shrink ? const NeverScrollableScrollPhysics() : null,
            itemCount: cart.length,
            itemBuilder: (context, i) {
              final item = cart[i];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.nameText,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (item.modifierText.isNotEmpty)
                              Text(
                                item.modifierText,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: SukaTeaColors.muted,
                                ),
                              ),
                            const SizedBox(height: 4),
                            Text(
                              formatRupiah(item.unitPrice),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: SukaTeaColors.emerald,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _deleteButton(onTap: () => onRemove(i)),
                          const SizedBox(width: 8),
                          _stepButton(
                            filled: false,
                            icon: Icons.remove,
                            onTap: () => onQty(i, -1),
                          ),
                          SizedBox(
                            width: 24,
                            child: Center(
                              child: Text(
                                '${item.qty}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          _stepButton(
                            filled: true,
                            icon: Icons.add,
                            onTap: () => onQty(i, 1),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
    return Container(
      decoration: const BoxDecoration(
        color: SukaTeaColors.card,
        border: Border(left: BorderSide(color: SukaTeaColors.border)),
      ),
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Layar pendek (landscape POVA, tinggi konten < 430dp): kolom
          // panel tanpa scroll overflow 61px (ketangkep 22 Nov 22:19).
          // Mode pendek: chip 1 baris scroll horizontal + teks kosong
          // 1 baris, supaya Total + Bayar tetap muat.
          final short = constraints.maxHeight < 430;
          return Column(
            mainAxisSize: shrink ? MainAxisSize.min : MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Judul + chip "Pending (N)" (Batch C1): ketuk untuk
              // membuka daftar order Pending. Nonaktif bila tidak ada
              // order yang di-Pending.
              Row(
                children: [
                  const Expanded(child: ScreenTitle('Keranjang')),
                  const SizedBox(width: 8),
                  TapFeedback(
                    enabled: heldCount > 0,
                    child: OutlinedButton(
                      onPressed: heldCount == 0 ? null : onShowHeld,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      // Angka chip ikut beranimasi (fade) saat berubah.
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeIn,
                        transitionBuilder: (child, animation) =>
                            FadeTransition(
                          opacity: animation,
                          child: child,
                        ),
                        child: Text(
                          'Pending ($heldCount)',
                          key: ValueKey<int>(heldCount),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (shrink) list else Expanded(child: list),
              const Divider(height: 1),
              const SizedBox(height: 8),
              short
                  ? SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final m in PaymentMethod.values)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(m.label),
                                selected: method == m,
                                onSelected: (_) => onMethod(m),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                        ],
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Cara bayar',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _methodCard(),
                      ],
                    ),
              const SizedBox(height: 8),
              // Diskon manual (Batch C1): subtotal + baris diskon hanya
              // tampil bila diskon > 0. Tombol Diskon digabung ke baris
              // Total (bukan baris sendiri) — panel overflow 45px di
              // viewport tes 800x600 dan 30px di landscape 1000x300
              // (ketangkep CI v23): satu baris penuh hilang, tombol +
              // Total tetap kelihatan tanpa scroll.
              if (discount > 0) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Subtotal',
                      style: TextStyle(color: SukaTeaColors.muted),
                    ),
                    Text(
                      formatRupiah(subtotal),
                      style: const TextStyle(color: SukaTeaColors.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      discountPercent > 0
                          ? 'Diskon ($discountPercent%)'
                          : 'Diskon',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: SukaTeaColors.danger,
                      ),
                    ),
                    // Nominal diskon ikut beranimasi (fade) saat berubah.
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, animation) =>
                          FadeTransition(
                        opacity: animation,
                        child: child,
                      ),
                      child: Text(
                        '-${formatRupiah(discount)}',
                        key: ValueKey<int>(discount),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: SukaTeaColors.danger,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
              Row(
                children: [
                  TapFeedback(
                    enabled: cart.isNotEmpty,
                    child: TextButton.icon(
                      onPressed: cart.isEmpty ? null : onDiscount,
                      icon: const Icon(Icons.percent, size: 18),
                      label: const Text(
                        'Diskon',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                  ),
                  const Spacer(),
                  const Text(
                    'Total',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Angka Total ikut beranimasi (fade + geser naik
                  // halus) tiap berubah — diskon / tambah item tidak
                  // lagi "lompat" kasar.
                  Flexible(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, animation) =>
                          FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.3),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: Text(
                        formatRupiah(total),
                        key: ValueKey<int>(total),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 22,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Pending + Bayar berdampingan (Batch C1): Pending outline
              // flex 1, Bayar flex 2. Label Bayar tetap "Bayar • RpX"
              // dengan X = total sesudah diskon.
              Row(
                children: [
                  Expanded(
                    child: TapFeedback(
                      enabled: cart.isNotEmpty && !isProcessing,
                      child: OutlinedButton(
                        onPressed:
                            (cart.isEmpty || isProcessing) ? null : onHold,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 56),
                        ),
                        child: const Text(
                          'Pending',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: _bayarButton()),
                ],
              ),
              if (!short) ...[
                const SizedBox(height: 8),
                const Text(
                  'Tombol terkunci saat memproses • anti double-tap',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: SukaTeaColors.muted,
                  ),
                ),
              ],
            ],
          );
        },
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
              child: TapFeedback(
                child: TextButton(
                  onPressed: onCart,
                  style: TextButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: EdgeInsets.zero,
                  ),
                  child: Row(
                    children: [
                      SvgPicture.asset(
                        AppIcons.keranjang,
                        width: 20,
                        height: 20,
                        colorFilter: const ColorFilter.mode(
                          SukaTeaColors.muted,
                          BlendMode.srcIn,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Keranjang ($count) • ${formatRupiah(total)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: SukaTeaColors.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            TapFeedback(
              enabled: count != 0 && !isProcessing,
              child: FilledButton(
                onPressed: (count == 0 || isProcessing) ? null : onBayar,
                style:
                    FilledButton.styleFrom(minimumSize: const Size(0, 56)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isProcessing) ...[
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Memproses…',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ] else ...[
                      SvgPicture.asset(
                        AppIcons.bayar,
                        width: 20,
                        height: 20,
                        colorFilter: const ColorFilter.mode(
                          Colors.white,
                          BlendMode.srcIn,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Bayar',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
