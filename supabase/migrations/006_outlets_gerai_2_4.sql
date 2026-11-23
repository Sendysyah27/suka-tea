-- SUKA TEA — migrasi 006 (Batch C4 multi-gerai)
-- Terapkan via dashboard Supabase > SQL Editor (seperti 003-005):
-- copy-paste seluruh file ini, Run. TIDAK perlu GRANT baru: Edge
-- Function kasir-pin yang baru memakai app_settings + pin_attempts,
-- yang GRANT-nya sudah ada dari migrasi 005.
--
-- 1) Kolom alamat di outlets (001 tidak punya kolom ini).
-- 2) Buat gerai 2-4 dengan ID yang SAMA dengan seed lokal di
--    lib/data/outlet_service.dart (seedOutlets) supaya data lokal
--    dan Supabase bisa disatukan saat sinkronisasi dibuat nanti.
--    Nama/alamat masih placeholder — Owner yang isi dari app
--    (Ubah Gerai), bukan dari SQL ini.

alter table public.outlets
  add column if not exists address text;

insert into public.outlets (id, name, owner_id, address)
values
  (
    '00000000-0000-0000-0000-000000000002',
    'Gerai 2',
    null,
    'Alamat gerai (isi dari Pengaturan)'
  ),
  (
    '00000000-0000-0000-0000-000000000003',
    'Gerai 3',
    null,
    'Alamat gerai (isi dari Pengaturan)'
  ),
  (
    '00000000-0000-0000-0000-000000000004',
    'Gerai 4',
    null,
    'Alamat gerai (isi dari Pengaturan)'
  )
on conflict (id) do nothing;

-- Gerai 1 (default, dibuat migrasi 003) dapat alamat placeholder yang
-- sama supaya konsisten dengan seed lokal.
update public.outlets
set address = 'Alamat gerai (isi dari Pengaturan)'
where id = '00000000-0000-0000-0000-000000000001'
  and (address is null or address = '');
