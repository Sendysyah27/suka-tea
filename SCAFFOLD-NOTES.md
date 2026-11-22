# SUKA TEA — Scaffold Notes (v0.1.0, 22 Nov 2026)

Repo: https://github.com/Sendysyah27/sruput-pos (publik, baru dibuat 22 Nov 2026)
Nama produk: SUKA TEA.
PRD: v0.3 (22 hal A4) — semua keputusan MVP terkunci.

## QRIS dinamis (22 Nov 2026 — GAS QRIS, scope aktif)

- QRIS dinamis pindah dari Fase 2 ke scope aktif (PRD diupdate terpisah).
- Modul baru `lib/features/qris/`:
  - `qris_service.dart` — Dart murni, tanpa secret: parse TLV EMVCo,
    sisip/ganti tag 54 (nominal), tag 01 11→12, hitung ulang CRC16-CCITT
    tag 63. Validasi dasar sebelum simpan/generate.
  - `qris_pay_page.dart` — nominal default = total keranjang, bisa diedit
    manual + preset Total/Bulatkan, Generate QR (qr_flutter), timer 5 menit,
    Batal / Sudah Dibayar. Konfirmasi bayar MANUAL (cek mutasi dulu).
    Transaksi dicatat `payment_method=qris`.
  - `qris_settings_page.dart` + `qris_settings_service.dart` — Owner
    tempel/simpan kode QRIS statis (validasi format dulu). Nilai asli
    TIDAK PERNAH di-hardcode di repo; disimpan ke Supabase `app_settings`
    (Owner-only) bila outlet + Supabase aktif, jika tidak hanya di memori.
    Kasir tidak bisa ubah. Scan QR = M5.
  - `test/qris_service_test.dart` — CRC vektor baku 29B1, parse tag,
    ganti nominal, CRC valid, nominal 0/negatif/lebih batas ditolak,
    payload rusak ditolak.
- Migrasi `002_qris_settings.sql`: tabel `app_settings` (Owner-only),
  tambah `qris` ke check `payment_method`, view ringkasan ikut merekap QRIS.
- TIDAK ADA nilai mentah payload QRIS asli di repo ini — hanya payload
  CONTOH (merchant fiktif "TOKO CONTOH") di kode/test.

## Folder platform (22 Nov 2026)

- `android/` — template Flutter 3.47 (Gradle 8.11.1, AGP 8.7.3, Kotlin
  2.1.0), applicationId + namespace `id.sukatea`, MainActivity Kotlin,
  ikon launcher PNG (emerald + cincin putih) per densitas.
  Dibutuhkan CI untuk `flutter build apk --debug` (sebelumnya gagal karena
  folder ini belum ada).
- `ios/` — AppDelegate.swift, Info.plist (izin kamera/galeri untuk scan
  QRIS + foto produk), Main/LaunchScreen storyboard, Podfile, dan
  `Runner.xcodeproj/project.pbxproj` (ID terverifikasi konsisten,
  XML/JSON valid). **Build iOS BELUM terverifikasi** — CI hanya build APK;
  butuh macOS + `flutter build ios` untuk membuktikan.

## Rename 22 Nov 2026 (urgent, sebelum push final)

- Nama produk diganti menjadi **SUKA TEA** (display name, pubspec, judul app,
  struk digital, komentar). Package Dart: `sruput_pos` → `suka_tea`.
- Repo GitHub TETAP `Sendysyah27/sruput-pos` (sudah dibuat + sudah ada
  commit); rename repo ke `suka-tea` adalah follow-up yang butuh
  keputusan user. Jangan buat dua repo.
- CI run 1 (45000687422) & run 2 (45000727182) completed failure —
  penyebab: `flutter analyze` error `CardTheme` vs `CardThemeData`
  di `app_theme.dart` (+ 1 warning import, 4 info). Semua sudah
  diperbaiki di push ini (CardThemeData, hapus import tak terpakai,
  publishableKey, const, checkout@v5).

## Yang sudah ada di scaffold ini

- Flutter + Dart, Android + iOS satu codebase; web Fase 2 (penanda di `apps/web/`).
- Tema Fresh Minimal (Opsi B): emerald `#0A9B6C`, lime, latar putih daun,
  Plus Jakarta Sans (font TTF belum dibundel — tambah ke `assets/fonts/`
  + daftarkan di pubspec bila sudah ada file-nya).
- 11 ikon SVG Gen Z di `assets/icons/` (stroke emerald 3px, tanpa emoji).
- Layar Kasir nyata: menu seed 8 produk + keranjang + total + pilih cara
  bayar (tunai/transfer/QRIS manual/e-wallet) + struk digital (dialog).
  Responsif: <600dp satu kolom + bar bawah, 600–840dp dua panel,
  >840dp tiga zona (kategori | grid | keranjang permanen).
- Kelola Menu (Owner): ubah harga Reguler/Jumbo per produk (state lokal,
  sinkron Supabase di M1); Kasir read-only.
- Stok (seed + badge menipis), Keuangan (Owner-only, contoh cash s.d.
  cashless + HPP + laba), Laporan/Tutup Kasir (rekonsiliasi kas tunai +
  tombol Export Sheets).
- Data: model + seed menu (SEED/CONTOH, bukan final), Supabase client
  placeholder (tanpa kredensial — jalan offline), Drift database +
  outbox idempoten (butuh `build_runner` untuk `app_database.g.dart`),
  export Sheets via Edge Function (skeleton, 501 sampai secret diisi).
- Supabase: migrasi `001_init.sql` (11 tabel + RLS Owner/Kasir) dan
  Edge Function `export-sheets` (skeleton).
- CI: Flutter 3.47.8 pin, `pub get` → `build_runner` → `analyze` →
  `test` → `build apk --debug`.

## Yang BELUM diverifikasi / belum ada

- CI: `flutter analyze` + `flutter test` (13 test) LOLOS di run
  45002502658 (commit `91e6be69`). `flutter build apk --debug` di run itu
  gagal karena folder `android/` belum ada di repo — sudah ditambah di
  push ini; run CI terbaru belum selesai saat catatan ini ditulis.
- Build iOS BELUM terverifikasi (butuh macOS + `flutter build ios`).
- `flutter analyze`/`flutter test` lokal belum dijalankan (tidak ada
  Flutter di VM ini). Verifikasi resmi dari CI.
- Proyek Supabase nyata (dev/prod) BELUM dibuat; `.env` belum diisi.
  Jangan tulis URL/key asli di repo — pakai `.env` lokal + dart-define.
- Menu/harga final, upload foto ke Storage, sync outbox nyata (M3),
  struk PDF/WhatsApp penuh (M2), printer ESC/POS 58mm (Fase 2),
  scan QR merchant (M5), enkripsi nilai QRIS sebelum simpan (M5).

## Commit pertama

`feat: scaffold awal SUKA TEA (Flutter + Supabase, Fresh Minimal)` (main)
- SHA: `9e5cbb8cac002a74dc6ad28f17d2d2dc9f5571c6`
- Commit awal (workaround repo kosong GitHub menolak git/blobs 409):
  `605329946cb2e1cbf7b7e6513befdcd35f2693ee` (`chore: initial commit`, README saja)
- CI run pertama: https://github.com/Sendysyah27/sruput-pos/actions/runs/45000687422
  — completed failure (flutter analyze: CardTheme, diperbaiki di push rename).
- CI run rename (45001131257): analyze LOLOS, `flutter test` gagal 1 test —
  `Es Teh Boba` tidak ketemu karena GridView malas membangun item di luar
  layar. Diperbaiki dengan `scrollUntilVisible` di widget test.
- Push final QRIS: `c20c5c85345df2ae7d2cb07b4e03228c42ba5921`
  (`feat: QRIS dinamis dalam app (generate QR nominal custom, konfirmasi manual)`).
- Push perbaikan test: `c025c985a9b6a6668c9ee20f08724ac8b2e4af89`
  (`fix: widget test scroll ke item terakhir grid (Es Teh Boba)`).
  Run 45001588419 untuk commit ini completed failure — penyebabnya
  ternyata BUKAN test, tapi `flutter analyze` gagal di file QRIS baru
  (`SruputColors` nyangkut di `qris_pay_page.dart`, 2 tempat).
- Push fix analyze: `0226f53abfa796e4d26c52e9af1d9b962d9d710b`
  (`fix: SukaTeaColors di layar QRIS + rapikan lint`). Run 45002054074:
  analyze LOLOS, `flutter test` gagal 1 test — `scrollUntilVisible`
  melempar "Bad state: Too many elements" (ada 2 Scrollable di layar).
- Push fix test: `91e6be69c456b9905f9d9f1c088913da84b82aa6`
  (`fix: widget test pakai viewport tinggi`). Run 45002502658: analyze
  LOLOS, `flutter test` LOLOS (13 test), `flutter build apk --debug`
  GAGAL — `android/app/build.gradle` tidak ditemukan (folder `android/`
  belum pernah dibuat). Diperbaiki dengan menambah folder `android/`
  + `ios/` di push ini.
