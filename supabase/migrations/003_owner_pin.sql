-- SUKA TEA — 003_owner_pin.sql
-- PIN Owner (RedMuse F1, 22 Nov 2026): satu PIN per outlet, hash bcrypt
-- di app_settings (key owner_pin_hash). Nilai PIN TIDAK PERNAH disimpan
-- di repo / app / HP — hanya hash di Supabase, ditulis + dibaca lewat
-- Edge Function (service_role). RLS tetap Owner-only untuk akses
-- langsung; anon tidak bisa baca hash. outlet_members.pin_hash (001)
-- tetap untuk desain M0 (PIN per operator sesudah Supabase Auth ada).

-- Outlet default stand (satu stand = satu outlet). UUID tetap supaya
-- app bisa memakainya tanpa pemilihan outlet (M0).
insert into outlets (id, name) values
  ('00000000-0000-0000-0000-000000000001', 'SUKA TEA — Stand Utama')
on conflict (id) do nothing;

-- Log percobaan PIN (rate limit server): hanya service_role yang
-- menulis/membaca — sengaja TIDAK ADA policy untuk anon/authenticated.
create table if not exists pin_attempts (
  id uuid primary key default gen_random_uuid(),
  outlet_id uuid not null references outlets(id) on delete cascade,
  created_at timestamptz not null default now(),
  success boolean not null default false
);

alter table pin_attempts enable row level security;

create index if not exists pin_attempts_outlet_time
  on pin_attempts (outlet_id, created_at desc);
