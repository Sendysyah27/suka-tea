import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'local/app_database.dart';

/// Satu gerai (outlet) SUKA TEA.
class Outlet {
  const Outlet({
    required this.id,
    required this.name,
    this.address = '',
    this.isOpen = true,
    this.sortOrder = 0,
  });

  /// UUID Supabase gerai ini (...0001–...0004 untuk 4 gerai awal;
  /// gerai baru dari app memakai 'local-<microseconds>').
  final String id;
  final String name;
  final String address;
  final bool isOpen;
  final int sortOrder;

  Outlet copyWith({String? name, String? address, bool? isOpen}) => Outlet(
        id: id,
        name: name ?? this.name,
        address: address ?? this.address,
        isOpen: isOpen ?? this.isOpen,
        sortOrder: sortOrder,
      );
}

/// UUID outlet default (migrasi Supabase 003) = Gerai 1.
const String defaultOutletId = '00000000-0000-0000-0000-000000000001';

/// 4 gerai awal (placeholder — Owner isi nama + alamat asli dari
/// menu Gerai di app; JANGAN minta ke Sendy). ID SAMA dengan yang
/// dibuat migrasi Supabase 006, supaya sinkronisasi nanti tinggal
/// cocokkan id.
List<Outlet> seedOutlets() => const [
      Outlet(
        id: '00000000-0000-0000-0000-000000000001',
        name: 'Gerai 1 — Stand Utama',
        address: 'Alamat gerai (isi dari Pengaturan)',
        sortOrder: 0,
      ),
      Outlet(
        id: '00000000-0000-0000-0000-000000000002',
        name: 'Gerai 2',
        address: 'Alamat gerai (isi dari Pengaturan)',
        sortOrder: 1,
      ),
      Outlet(
        id: '00000000-0000-0000-0000-000000000003',
        name: 'Gerai 3',
        address: 'Alamat gerai (isi dari Pengaturan)',
        sortOrder: 2,
      ),
      Outlet(
        id: '00000000-0000-0000-0000-000000000004',
        name: 'Gerai 4',
        address: 'Alamat gerai (isi dari Pengaturan)',
        sortOrder: 3,
      ),
    ];

/// Daftar gerai + gerai aktif sesi ini (Batch C4 multi-gerai).
///
/// SUMBER DATA: tabel Drift lokal `Outlets` — BUKAN Supabase langsung.
/// Alasannya jujur: tabel Supabase `outlets` punya RLS member-only
/// (baca hanya bila `auth.uid()` ada di outlet_members), dan app
/// belum pernah sign-in (Auth = M0, belum dibangun), jadi anon TIDAK
/// BISA membacanya. Migrasi 006 membuat 4 gerai yang sama di Supabase
/// (id sama) supaya saat Auth/sinkronisasi ada, tinggal cocokkan id.
/// Nama/alamat yang diubah Owner tersimpan di HP ini; sinkronisasi
/// ke Supabase ikut saat Auth aktif (di luar C4).
///
/// Gerai aktif = pilihan di halaman Login, berlaku SATU sesi (tutup
/// app = login lagi). KasirPage / Keuangan / Laporan / Riwayat
/// memakai gerai ini lewat SaleHistoryService + HeldOrderService.
class OutletService extends ChangeNotifier {
  OutletService._();

  static final OutletService instance = OutletService._();

  AppDatabase? _db;
  AppDatabase get _database => _db ??= AppDatabase();

  List<Outlet> _outlets = [];
  bool _initialized = false;

  /// Gerai aktif sesi ini (dipilih di Login). Default = Gerai 1.
  String _currentOutletId = defaultOutletId;

  /// Semua gerai, urut sortOrder (salinan).
  List<Outlet> get outlets => List.unmodifiable(_outlets);

  bool get isInitialized => _initialized;

  String get currentOutletId => _currentOutletId;

  Outlet get currentOutlet => _outlets.firstWhere(
        (o) => o.id == _currentOutletId,
        orElse: () => _outlets.isNotEmpty
            ? _outlets.first
            : seedOutlets().first,
      );

  Outlet? outletById(String id) {
    for (final o in _outlets) {
      if (o.id == id) return o;
    }
    return null;
  }

  /// Baca Drift; kosong = seed 4 gerai awal. Dipanggil di main()
  /// sebelum runApp.
  Future<void> init() async {
    if (_initialized) return;
    try {
      final rows = await _database.select(_database.outlets).get();
      final list = rows
          .map(
            (r) => Outlet(
              id: r.id,
              name: r.name,
              address: r.address,
              isOpen: r.isOpen,
              sortOrder: r.sortOrder,
            ),
          )
          .toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      if (list.isEmpty) {
        _outlets = seedOutlets();
        for (final o in _outlets) {
          try {
            await _database.into(_database.outlets).insert(
                  OutletsCompanion.insert(
                    id: o.id,
                    name: o.name,
                    address: Value(o.address),
                    isOpen: Value(o.isOpen),
                    sortOrder: Value(o.sortOrder),
                  ),
                );
          } catch (e) {
            debugPrint('Outlet seed gagal simpan (memori tetap ada): $e');
          }
        }
      } else {
        _outlets = list;
      }
    } catch (e) {
      debugPrint('Outlet init gagal, pakai seed di memori: $e');
      _outlets = seedOutlets();
    }
    _initialized = true;
    notifyListeners();
  }

  /// Pilih gerai aktif sesi ini (dari halaman Login). false = id
  /// tidak dikenal.
  bool selectOutlet(String id) {
    if (outletById(id) == null) return false;
    if (_currentOutletId == id) return true;
    _currentOutletId = id;
    notifyListeners();
    return true;
  }

  /// Ubah nama / alamat / status gerai (Owner, dari Ubah Gerai).
  /// false = id tidak ada / simpan gagal.
  Future<bool> updateOutlet(
    String id, {
    String? name,
    String? address,
    bool? isOpen,
  }) async {
    final i = _outlets.indexWhere((o) => o.id == id);
    if (i < 0) return false;
    final updated = _outlets[i].copyWith(
      name: name,
      address: address,
      isOpen: isOpen,
    );
    _outlets = List<Outlet>.of(_outlets)..[i] = updated;
    notifyListeners();
    try {
      await (_database.update(_database.outlets)
            ..where((t) => t.id.equals(id)))
          .write(
        OutletsCompanion(
          name: name == null ? const Value.absent() : Value(name),
          address:
              address == null ? const Value.absent() : Value(address),
          isOpen: isOpen == null ? const Value.absent() : Value(isOpen),
        ),
      );
    } catch (e) {
      debugPrint('Outlet ubah gagal simpan (memori tetap berubah): $e');
      return false;
    }
    return true;
  }

  /// Tambah gerai baru (Owner, dari Daftar Gerai). ID lokal
  /// 'local-<microseconds>' — belum ada di Supabase sampai ada
  /// sinkronisasi; saat itu dibuatkan UUID Supabase baru.
  Future<Outlet> addOutlet({required String name, String address = ''}) async {
    final id = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final order = _outlets.isEmpty
        ? 0
        : _outlets.map((o) => o.sortOrder).reduce((a, b) => a > b ? a : b) +
            1;
    final outlet = Outlet(
      id: id,
      name: name,
      address: address,
      sortOrder: order,
    );
    _outlets = [..._outlets, outlet];
    notifyListeners();
    try {
      await _database.into(_database.outlets).insert(
            OutletsCompanion.insert(
              id: outlet.id,
              name: outlet.name,
              address: Value(outlet.address),
              isOpen: const Value(true),
              sortOrder: Value(outlet.sortOrder),
            ),
          );
    } catch (e) {
      debugPrint('Outlet tambah gagal simpan (memori tetap ada): $e');
    }
    return outlet;
  }

  /// Hapus gerai (Owner, dari Ubah Gerai). Gerai utama (...0001)
  /// dan gerai yang sedang aktif TIDAK bisa dihapus — false.
  /// Transaksi / order Pending gerai yang dihapus tetap ada di
  /// riwayat (tidak ikut terhapus), hanya tidak bisa dipilih lagi.
  Future<bool> removeOutlet(String id) async {
    if (id == defaultOutletId || id == _currentOutletId) return false;
    if (outletById(id) == null) return false;
    _outlets = _outlets.where((o) => o.id != id).toList();
    notifyListeners();
    try {
      await (_database.delete(_database.outlets)
            ..where((t) => t.id.equals(id)))
          .go();
    } catch (e) {
      debugPrint('Outlet hapus gagal simpan (memori tetap terhapus): $e');
      return false;
    }
    return true;
  }
}
