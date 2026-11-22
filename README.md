# Sruput POS

POS kasir + pencatatan keuangan untuk stand es teh.

> **Nama sementara:** Sruput POS. Penggantian nama paling murah sebelum rilis
> publik — bundle ID yang sudah terbit di store sulit diubah.

## Status

Scaffold awal (v0.1.0). MVP yang dikunci di PRD v0.3:

- **Framework:** Flutter + Dart, Android + iOS dulu dari satu codebase.
  Web = Fase 2 di atas backend/skema yang sama (`apps/web/` masih penanda).
- **Backend:** Supabase penuh (Auth, Postgres, Storage, Realtime, Edge
  Functions). Offline-first: Drift/SQLite + outbox idempoten.
- **Desain:** Opsi B — Fresh Minimal. Emerald `#0A9B6C` sebagai warna aksi,
  lime sebagai aksen, latar putih daun, kartu putih soft-shadow,
  tipografi Plus Jakarta Sans. Semua ikon berupa SVG (style Gen Z),
  tanpa emoji sebagai ikon UI.
- **Pembayaran MVP:** tunai + transfer/QRIS manual. QRIS dinamis = Fase 2.
  Laporan wajib memisahkan cash sampai cashless (tunai, transfer, QRIS,
  e-wallet) + rekonsiliasi kas tunai di tutup kasir.
- **Printer:** tanpa printer dulu — struk digital (tampil di app, share
  WhatsApp, simpan PDF, lihat ulang dari riwayat). Printer Bluetooth
  thermal 58mm = backlog Fase 2.
- **Google Sheets:** HANYA untuk laporan/export, BUKAN database utama.
  Export otomatis tiap tutup kasir + tombol manual via Edge Function.

## Peran

- **Owner:** semua fitur, termasuk baca laba/HPP, kelola menu/harga/foto,
  dan export Sheets.
- **Kasir:** jualan saja (read-only untuk menu). Tidak bisa baca laba/HPP —
  ditegakkan oleh RLS di Supabase, bukan hanya oleh tampilan.

## Menjalankan

```bash
cp .env.example .env   # isi SUPABASE_URL + SUPABASE_ANON_KEY (jangan commit .env)
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

Untuk pengembangan tanpa Supabase, app tetap jalan offline dengan menu
seed (berlabel SEED/CONTOH di kode) dan outbox lokal.

## Struktur

```text
lib/
  app/        SruputApp + navigasi + shell responsif
  core/       theme (token Fresh Minimal), utils
  data/       model, seed menu, Supabase client, Drift/outbox, export Sheets
  features/   kasir, katalog, stok, keuangan, laporan
supabase/
  migrations/ skema + RLS (001_init.sql)
  functions/  export-sheets (Edge Function, skeleton)
apps/web/     penanda Fase 2
```

## CI

`.github/workflows/flutter-ci.yml` — Flutter 3.47.8 (pin, terbukti hijau
di SSR-SPACE), `flutter analyze`, `flutter test`, build APK debug.
Status CI pertama belum tentu hijau — lihat badge/Actions di GitHub.

## Keputusan terbuka

- Menu/harga awal (seed di `lib/data/seed_menu.dart` hanya usulan).
- Detail printer Fase 2 (ESC/POS 58mm) dan QRIS dinamis Fase 2.
