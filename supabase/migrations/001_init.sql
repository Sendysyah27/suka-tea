-- SUKA TEA — 001_init.sql
-- Skema awal. Uang disimpan sebagai integer rupiah (bukan sen).
-- Semua tabel membawa outlet_id. RLS aktif di semua tabel.
-- Aturan peran: Owner bisa semua; Kasir jualan saja dan TIDAK bisa baca
-- laba/HPP (expenses + view ringkasan laba hanya Owner).

create extension if not exists "pgcrypto";

-- ============ Outlet & anggota ============
create table if not exists outlets (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_id uuid,
  created_at timestamptz not null default now()
);

create table if not exists outlet_members (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references outlets(id) on delete cascade,
  user_id uuid not null,
  role text not null check (role in ('owner', 'kasir')),
  pin_hash text, -- PIN operator (ter-hash) untuk ganti kasir cepat di perangkat bersama
  created_at timestamptz not null default now(),
  unique (outlet_id, user_id)
);

-- ============ Katalog (bisa di-custom Owner di dalam app) ============
create table if not exists products (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references outlets(id) on delete cascade,
  name text not null,
  category text not null default 'Teh Klasik',
  photo_url text, -- Supabase Storage, per outlet_id
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references products(id) on delete cascade,
  name text not null, -- contoh: Reguler, Jumbo
  size_oz integer,
  price integer not null check (price >= 0),
  cost integer not null default 0 check (cost >= 0), -- HPP, hanya Owner
  unique (product_id, name)
);

create table if not exists modifiers (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references outlets(id) on delete cascade,
  name text not null,
  kind text not null check (kind in ('gula', 'es', 'topping')),
  price_delta integer not null default 0,
  is_active boolean not null default true
);

-- ============ Transaksi ============
create table if not exists shifts (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references outlets(id) on delete cascade,
  operator_id uuid,
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  opening_cash integer not null default 0,
  closing_cash integer,
  counted_cash integer, -- hasil hitung laci saat tutup (rekonsiliasi)
  status text not null default 'open' check (status in ('open', 'closed'))
);

create table if not exists transactions (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references outlets(id) on delete cascade,
  operator_id uuid,
  shift_id uuid references shifts(id),
  payment_method text not null
    check (payment_method in ('tunai', 'transfer', 'qris_manual', 'ewallet')),
  subtotal integer not null default 0,
  total integer not null default 0,
  paid integer not null default 0,
  change_amount integer not null default 0,
  status text not null default 'completed' check (status in ('completed', 'void')),
  client_uuid uuid not null unique, -- idempotency: dibuat di perangkat (outbox)
  created_at timestamptz not null default now()
);

create table if not exists transaction_items (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references transactions(id) on delete cascade,
  product_id uuid references products(id),
  variant_id uuid references product_variants(id),
  name_snapshot text not null,
  qty integer not null default 1 check (qty > 0),
  unit_price integer not null default 0,
  modifiers_json jsonb not null default '[]'::jsonb
);

-- ============ Stok & pengeluaran ============
create table if not exists stock_items (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references outlets(id) on delete cascade,
  name text not null, -- contoh: teh, gula, cup, es batu
  unit text not null default 'pcs',
  qty numeric not null default 0,
  low_threshold numeric not null default 0,
  cost integer not null default 0
);

create table if not exists stock_movements (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references outlets(id) on delete cascade,
  stock_item_id uuid not null references stock_items(id) on delete cascade,
  qty_delta numeric not null,
  reason text not null default 'penjualan',
  transaction_id uuid references transactions(id),
  created_at timestamptz not null default now()
);

create table if not exists expenses (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references outlets(id) on delete cascade,
  category text not null,
  description text,
  amount integer not null check (amount > 0),
  created_by uuid,
  created_at timestamptz not null default now()
);

-- ============ RLS ============
alter table outlets enable row level security;
alter table outlet_members enable row level security;
alter table products enable row level security;
alter table product_variants enable row level security;
alter table modifiers enable row level security;
alter table shifts enable row level security;
alter table transactions enable row level security;
alter table transaction_items enable row level security;
alter table stock_items enable row level security;
alter table stock_movements enable row level security;
alter table expenses enable row level security;

create or replace function public.is_outlet_member(p_outlet uuid)
returns boolean language sql stable as $$
  select exists (
    select 1 from outlet_members
    where outlet_id = p_outlet and user_id = auth.uid()
  );
$$;

create or replace function public.is_outlet_owner(p_outlet uuid)
returns boolean language sql stable as $$
  select exists (
    select 1 from outlet_members
    where outlet_id = p_outlet and user_id = auth.uid() and role = 'owner'
  );
$$;

-- Outlets: anggota bisa baca; Owner yang mengubah.
create policy "member baca outlet" on outlets
  for select using (is_outlet_member(id));
create policy "owner ubah outlet" on outlets
  for all using (is_outlet_owner(id));

-- Anggota: hanya Owner.
create policy "owner kelola anggota" on outlet_members
  for all using (is_outlet_owner(outlet_id));

-- Katalog & stok: anggota baca; tulis hanya Owner (Kasir read-only).
create policy "member baca produk" on products
  for select using (is_outlet_member(outlet_id));
create policy "owner tulis produk" on products
  for all using (is_outlet_owner(outlet_id));
create policy "member baca varian" on product_variants
  for select using (is_outlet_member(
    (select outlet_id from products where id = product_variants.product_id)));
create policy "owner tulis varian" on product_variants
  for all using (is_outlet_owner(
    (select outlet_id from products where id = product_variants.product_id)));
create policy "member baca modifier" on modifiers
  for select using (is_outlet_member(outlet_id));
create policy "owner tulis modifier" on modifiers
  for all using (is_outlet_owner(outlet_id));
create policy "member baca stok" on stock_items
  for select using (is_outlet_member(outlet_id));
create policy "owner tulis stok" on stock_items
  for all using (is_outlet_owner(outlet_id));
create policy "member baca mutasi stok" on stock_movements
  for select using (is_outlet_member(outlet_id));
create policy "member tulis mutasi stok" on stock_movements
  for insert with check (is_outlet_member(outlet_id));

-- Transaksi: anggota bisa catat & baca transaksinya sendiri; Owner baca semua.
create policy "member catat transaksi" on transactions
  for insert with check (is_outlet_member(outlet_id));
create policy "baca transaksi sendiri atau owner" on transactions
  for select using (is_outlet_owner(outlet_id) or operator_id = auth.uid());
create policy "baca item transaksi" on transaction_items
  for select using (exists (
    select 1 from transactions t
    where t.id = transaction_items.transaction_id
      and (is_outlet_owner(t.outlet_id) or t.operator_id = auth.uid())
  ));
create policy "catat item transaksi" on transaction_items
  for insert with check (exists (
    select 1 from transactions t
    where t.id = transaction_items.transaction_id
      and is_outlet_member(t.outlet_id)
  ));

-- Shift: anggota buka/baca shift sendiri; Owner semua + tutup.
create policy "member baca shift" on shifts
  for select using (is_outlet_owner(outlet_id) or operator_id = auth.uid());
create policy "member buka shift" on shifts
  for insert with check (is_outlet_member(outlet_id));
create policy "owner tutup shift" on shifts
  for update using (is_outlet_owner(outlet_id));

-- Pengeluaran & laba: HANYA Owner (inilah yang membuat Kasir tidak bisa
-- baca laba/HPP — bukan sekadar disembunyikan di tampilan).
create policy "owner baca pengeluaran" on expenses
  for select using (is_outlet_owner(outlet_id));
create policy "owner tulis pengeluaran" on expenses
  for all using (is_outlet_owner(outlet_id));

-- Ringkasan harian (omzet, HPP, laba): view Owner-only.
create or replace view v_daily_summary as
select
  t.outlet_id,
  date_trunc('day', t.created_at)::date as hari,
  count(*) as jumlah_transaksi,
  sum(case when t.payment_method = 'tunai' then t.total else 0 end) as tunai,
  sum(case when t.payment_method = 'transfer' then t.total else 0 end) as transfer,
  sum(case when t.payment_method = 'qris_manual' then t.total else 0 end) as qris_manual,
  sum(case when t.payment_method = 'ewallet' then t.total else 0 end) as ewallet,
  sum(t.total) as omzet
from transactions t
where t.status = 'completed'
group by t.outlet_id, date_trunc('day', t.created_at)::date;
