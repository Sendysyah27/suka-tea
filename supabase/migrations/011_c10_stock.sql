-- SUKA TEA — Migrasi 011 (Batch C10: Stok Gudang, Paket Kiriman,
-- Jatah Gerai, Dashboard Owner)
-- Dijalankan via SQL Editor Supabase Dashboard (bukan CLI).
-- FILE SAJA — belum di-deploy (builder C10 tidak deploy).
--
-- RINGKASAN:
-- - GUDANG = pseudo-outlet '00000000-0000-0000-0000-000000000000'
--   (bukan gerai nyata — JANGAN muncul di daftar gerai / Pantau
--   Gerai / laporan per-gerai). Stok gudang = baris stock_items
--   dengan outlet_id = GUDANG_ID (tidak perlu tabel baru).
-- - 'Teh' (kg) diganti nama jadi 'Teh Kering' (UPDATE di bawah);
--   'Teh Masak' (liter) dibuat sebagai bahan baru per gerai.
-- - stock_items + shelf_life_days (0 = tidak pernah kedaluwarsa;
--   'Teh Masak' = 1 hari).
-- - Tabel master-data baru: app_products, app_toppings, packages,
--   package_items, outlet_package_defaults, gerai_targets.
-- - Tabel operasional baru: stock_sends, send_items, stock_ins,
--   brews, stock_opnames.
-- - product_recipes + updated_at + is_deleted (master sync WS0 —
--   resep = master-data, last-write-wins by updated_at).
-- - RLS diaktifkan TANPA policy di semua tabel baru (anon /
--   authenticated ditolak; service_role bypass) — sama seperti
--   tabel lain sebelum Auth M0; semua akses lewat Edge Function
--   service_role (sync-sales).
-- - service_role GRANTs supaya Edge Function sync-sales bisa
--   baca/tulis — pola yang sama dengan 005/008/009/010.

-- ============ GUDANG (pseudo-outlet) ============
-- TIDAK ADA baris di tabel outlets untuk gudang — gudang bukan
-- gerai. stock_items.outlet_id boleh berisi GUDANG_ID tanpa FK
-- ke outlets (stock_items TIDAK punya FK ke outlets — lihat 001).
-- Nilai ini harus sama dengan gudangOutletId di lib/data/c10_models.dart.

-- ============ stock_items: shelf_life_days + rename Teh ============
alter table public.stock_items
  add column if not exists shelf_life_days integer not null default 0;

-- updated_at (LWW konfigurasi bahan — WS0): HANYA ditulis oleh
-- pushMaster (stock_item_config). pushStockMovement TIDAK
-- menyentuhnya (mutasi penjualan membawa meta lama — bila ikut
-- menulis updated_at, konfigurasi baru bisa tertimpa meta lama).
alter table public.stock_items
  add column if not exists updated_at timestamptz not null default now();

-- 'Teh' -> 'Teh Kering' di SEMUA gerai (nama adalah kunci resep +
-- tampilan; qty + cost + threshold ikut barisnya — tidak berubah).
-- Aman diulang (bila sudah diganti, UPDATE tidak menemukan baris).
update public.stock_items
  set name = 'Teh Kering'
  where name = 'Teh';

-- 'Teh Masak' (liter, 1 hari) untuk tiap gerai yang punya
-- 'Teh Kering' (gerai yang sudah ada). Gerai baru (bila suatu hari
-- ditambah) dibuatkan app saat pertama buka halaman Stok (seed
-- lokal) — server TIDAK men-seed gerai baru di sini.
-- cost awal 0 ("belum diatur" dihitung dari masakan
-- pertama — lihat BrewService.brew); low_threshold 0.
-- CATATAN: kolom DB-nya bernama `cost` (migrasi 001) — app dan EF
-- menyebutnya cost_per_unit, EF yang menerjemahkan (lihat sync-sales).
insert into public.stock_items
  (outlet_id, name, unit, qty, low_threshold, cost, shelf_life_days)
select distinct outlet_id, 'Teh Masak', 'liter', 0, 0, 0, 1
from public.stock_items
where name = 'Teh Kering'
  and not exists (
    select 1 from public.stock_items s2
    where s2.outlet_id = stock_items.outlet_id
      and s2.name = 'Teh Masak'
  );

-- ============ product_recipes: master sync (WS0) ============
alter table public.product_recipes
  add column if not exists updated_at timestamptz not null default now();

alter table public.product_recipes
  add column if not exists is_deleted boolean not null default false;

-- Resep 'Teh' 0,015 kg -> 'Teh Masak' 0,4 L per cup (default,
-- Owner bisa ubah di editor resep). HANYA baris _22oz (satu-satunya
-- varian sejak C8.2); baris _r/_j lama DIBIARKAN (aturan C8.2 —
-- data lama tidak dihapus diam-diam).
-- CATATAN SKEMA (koreksi 24 Nov 18:51): product_recipes TIDAK punya
-- kolom stock_name — resep menunjuk bahan lewat stock_item_id (FK ke
-- stock_items, migrasi 004). Jadi UPDATE ini memindahkan
-- stock_item_id dari baris 'Teh Kering' ke baris 'Teh Masak' di gerai
-- yang sama (baris 'Teh Masak' sudah dibuat INSERT di atas). Guard
-- NOT EXISTS mencegah bentrok unique (variant_id, stock_item_id)
-- bila resep Teh Masak untuk varian itu sudah ada.
-- Syarat: gerai...0001 adalah outlet kanonik resep (lihat EF
-- sync-sales pushMaster — resep disimpan global di ...0001).
update public.product_recipes r
  set stock_item_id = m.id, qty = 0.4, updated_at = now()
  from public.stock_items t, public.stock_items m
  where r.variant_id like '%_22oz'
    and r.stock_item_id = t.id
    and t.name = 'Teh Kering'
    and m.outlet_id = r.outlet_id
    and m.name = 'Teh Masak'
    and not exists (
      select 1 from public.product_recipes r2
      where r2.variant_id = r.variant_id
        and r2.stock_item_id = m.id
    );

-- ============ app_products: produk (master WS0) ============
-- Produk = master-data (nama/kategori/harga/foto/aktif). id = id
-- produk lokal (text, mis. 'p01'). Hapus = is_deleted true
-- (produk tetap ada di Riwayat + void-restore).
create table if not exists public.app_products (
  id text primary key,
  name text not null,
  category text not null default 'Mixtea',
  price integer not null default 0,
  photo_url text,
  is_active boolean not null default true,
  updated_at timestamptz not null default now(),
  is_deleted boolean not null default false
);

alter table public.app_products enable row level security;

grant select, insert, update, delete
  on table public.app_products to service_role;

-- ============ app_toppings: topping (master WS0) ============
create table if not exists public.app_toppings (
  id text primary key,
  name text not null,
  price_delta integer not null default 0,
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  is_deleted boolean not null default false
);

alter table public.app_toppings enable row level security;

grant select, insert, update, delete
  on table public.app_toppings to service_role;

-- ============ packages + package_items (master WS2) ============
create table if not exists public.packages (
  id text primary key,
  name text not null,
  note text not null default '',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  is_deleted boolean not null default false
);

alter table public.packages enable row level security;

grant select, insert, update, delete
  on table public.packages to service_role;

create table if not exists public.package_items (
  id text primary key,
  package_id text not null references public.packages (id),
  stock_name text not null,
  qty numeric not null default 0,
  unit text not null default 'pcs',
  updated_at timestamptz not null default now(),
  is_deleted boolean not null default false
);

alter table public.package_items enable row level security;

grant select, insert, update, delete
  on table public.package_items to service_role;

create index if not exists package_items_package_id_idx
  on public.package_items (package_id);

-- ============ outlet_package_defaults (master WS2) ============
-- Satu paket default per gerai (nullable = belum diatur).
create table if not exists public.outlet_package_defaults (
  outlet_id uuid primary key,
  package_id text references public.packages (id),
  updated_at timestamptz not null default now()
);

alter table public.outlet_package_defaults enable row level security;

grant select, insert, update, delete
  on table public.outlet_package_defaults to service_role;

-- ============ gerai_targets (master WS7 §4) ============
-- Target omzet harian per gerai (Rp/hari, >= 0).
create table if not exists public.gerai_targets (
  outlet_id uuid primary key,
  target_omzet integer not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.gerai_targets enable row level security;

grant select, insert, update, delete
  on table public.gerai_targets to service_role;

-- ============ stock_sends + send_items (WS3) ============
-- Kiriman stok gudang -> gerai. status: 'ok' (terkirim) /
-- 'gagal' (ditolak server 'gudang_kurang' — sudah dibalik lokal).
-- client_uuid = id kiriman (idempotency — kirim ulang request yang
-- sama tidak dobel kirim).
create table if not exists public.stock_sends (
  id text primary key,
  client_uuid text not null unique,
  outlet_id uuid not null,
  package_id text references public.packages (id),
  package_name text not null default '',
  sent_at timestamptz not null default now(),
  sent_by text not null default 'Owner',
  note text not null default '',
  status text not null default 'ok',
  created_at timestamptz not null default now()
);

alter table public.stock_sends enable row level security;

grant select, insert, update, delete
  on table public.stock_sends to service_role;

create table if not exists public.send_items (
  id text primary key,
  send_id text not null references public.stock_sends (id),
  stock_name text not null,
  qty numeric not null default 0,
  unit text not null default 'pcs'
);

alter table public.send_items enable row level security;

grant select, insert, update, delete
  on table public.send_items to service_role;

create index if not exists send_items_send_id_idx
  on public.send_items (send_id);

create index if not exists stock_sends_outlet_id_idx
  on public.stock_sends (outlet_id, sent_at desc);

-- ============ stock_ins (WS1 — stok masuk gudang) ============
create table if not exists public.stock_ins (
  id text primary key,
  client_uuid text not null unique,
  stock_name text not null,
  unit text not null default 'pcs',
  qty numeric not null default 0,
  total_price integer not null default 0,
  supplier text not null default '',
  date date not null default current_date,
  note text not null default '',
  created_at timestamptz not null default now()
);

alter table public.stock_ins enable row level security;

grant select, insert, update, delete
  on table public.stock_ins to service_role;

-- ============ brews (WS4 — masak teh) ============
-- expired_liters = sisa Teh Masak kemarin yang dihanguskan saat
-- masak hari baru (movement 'kedaluwarsa' juga tercatat di
-- stock_movements oleh EF — lihat pushBrew).
create table if not exists public.brews (
  id text primary key,
  client_uuid text not null unique,
  outlet_id uuid not null,
  kg_used numeric not null default 0,
  liters_made numeric not null default 0,
  brewed_at timestamptz not null default now(),
  brewed_by text not null default 'Kasir',
  expired_liters numeric not null default 0,
  created_at timestamptz not null default now()
);

alter table public.brews enable row level security;

grant select, insert, update, delete
  on table public.brews to service_role;

create index if not exists brews_outlet_id_idx
  on public.brews (outlet_id, brewed_at desc);

-- ============ stock_opnames (WS6) ============
-- Satu baris = satu bahan yang dihitung dalam satu sesi opname.
-- adjusted = true berarti Owner sudah menekan "Sesuaikan stok"
-- untuk baris itu (stok sistem sudah diubah sebesar selisih).
create table if not exists public.stock_opnames (
  id text primary key,
  client_uuid text not null unique,
  outlet_id uuid not null,
  stock_name text not null,
  system_qty numeric not null default 0,
  physical_qty numeric not null default 0,
  difference numeric not null default 0,
  counted_at timestamptz not null default now(),
  counted_by text not null default 'Owner',
  note text not null default '',
  adjusted boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table public.stock_opnames enable row level security;

grant select, insert, update, delete
  on table public.stock_opnames to service_role;

create index if not exists stock_opnames_outlet_id_idx
  on public.stock_opnames (outlet_id, counted_at desc);

-- ============ stock_movements: alasan baru (WS4/WS6/WS3) ============
-- Kolom reason di 008 tidak punya CHECK (alasan bebas) — tidak ada
-- yang diubah di sini. Alasan baru yang dipakai C10:
-- 'brew' (masak teh — Teh Kering −, Teh Masak +),
-- 'kedaluwarsa' (sisa Teh Masak kemarin hangus),
-- 'opname' (penyesuaian stok sesudah "Sesuaikan stok"),
-- 'kirim' (stok pindah gudang <-> gerai — dicatat sebagai mutasi
--   di kedua sisi supaya ledger keluar-masuk menutup).
-- Server menulis mutasi ini sendiri di pushStockSend/pushBrew/
-- pushOpname — app TIDAK mengirim mutasi 'kirim'/'brew'/
-- 'kedaluwarsa'/'opname' sebagai event 'stock_movement' (hindari
-- dobel hitung; lihat PackageService/BrewService).
