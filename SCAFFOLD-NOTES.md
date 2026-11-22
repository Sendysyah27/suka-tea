# Sruput POS — Scaffold Notes (v0.1.0, 22 Nov 2026)

Repo: https://github.com/Sendysyah27/sruput-pos (publik, baru dibuat 22 Nov 2026)
PRD: v0.3 (22 hal A4) — semua keputusan MVP terkunci.

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

- CI belum jalan / belum hijau — cek tab Actions di GitHub setelah push.
- `flutter analyze`/`flutter test` lokal belum dijalankan (tidak ada
  Flutter di VM ini). Kode ditulis hati-hati, tapi verifikasi resminya
  dari CI.
- Proyek Supabase nyata (dev/prod) BELUM dibuat; `.env` belum diisi.
  Jangan tulis URL/key asli di repo — pakai `.env` lokal + dart-define.
- Menu/harga final, upload foto ke Storage, sync outbox nyata (M3),
  struk PDF/WhatsApp penuh (M2), printer ESC/POS 58mm (Fase 2),
  QRIS dinamis (Fase 2).

## Commit pertama

`feat: scaffold awal Sruput POS (Flutter + Supabase, Fresh Minimal)` (main)
- SHA: `9e5cbb8cac002a74dc6ad28f17d2d2dc9f5571c6`
- Commit awal (workaround repo kosong GitHub menolak git/blobs 409):
  `605329946cb2e1cbf7b7e6513befdcd35f2693ee` (`chore: initial commit`, README saja)
- CI run pertama: https://github.com/Sendysyah27/sruput-pos/actions/runs/45000687422
  — status saat push: `in_progress` (belum hijau, masih jalan).
