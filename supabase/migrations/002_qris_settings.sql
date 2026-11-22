-- SUKA TEA — 002_qris_settings.sql
-- QRIS dinamis pindah dari Fase 2 ke scope aktif (22 Nov 2026).
-- 1) Tabel app_settings untuk kode QRIS statis merchant (Owner-only).
-- 2) Cara bayar 'qris' (dinamis) ditambahkan ke transactions.
-- 3) View ringkasan harian ikut merekap QRIS dinamis.

create table if not exists app_settings (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references outlets(id) on delete cascade,
  key text not null,
  value text not null, -- nilai sensitif dienkripsi di aplikasi (M5)
  updated_at timestamptz not null default now(),
  unique (outlet_id, key)
);

alter table app_settings enable row level security;

create policy "owner kelola pengaturan" on app_settings
  for all using (is_outlet_owner(outlet_id));

-- Tambah 'qris' ke daftar cara bayar (nilai lama tetap berlaku).
alter table transactions drop constraint if exists transactions_payment_method_check;
alter table transactions add constraint transactions_payment_method_check
  check (payment_method in ('tunai', 'transfer', 'qris', 'qris_manual', 'ewallet'));

create or replace view v_daily_summary as
select
  t.outlet_id,
  date_trunc('day', t.created_at)::date as hari,
  count(*) as jumlah_transaksi,
  sum(case when t.payment_method = 'tunai' then t.total else 0 end) as tunai,
  sum(case when t.payment_method = 'transfer' then t.total else 0 end) as transfer,
  sum(case when t.payment_method = 'qris' then t.total else 0 end) as qris,
  sum(case when t.payment_method = 'qris_manual' then t.total else 0 end) as qris_manual,
  sum(case when t.payment_method = 'ewallet' then t.total else 0 end) as ewallet,
  sum(t.total) as omzet
from transactions t
where t.status = 'completed'
group by t.outlet_id, date_trunc('day', t.created_at)::date;
