-- SUKA TEA — 007_storage_product_photos.sql
-- Bucket Storage untuk foto produk custom Owner (Batch C3).
--
-- Foto diunggah HANYA lewat Edge Function `upload-product-photo`
-- (service_role, dengan bukti PIN Owner) — BUKAN langsung dari app
-- dengan anon key: anon key bisa diekstrak dari APK, jadi policy
-- "anon boleh tulis" sama saja dengan "siapa pun boleh tulis".
-- service_role melewati RLS, jadi tidak ada policy tulis untuk
-- anon/authenticated di sini; baca dibuat publik supaya Kasir bisa
-- menampilkan foto dari URL tanpa login (Auth M0 belum ada).
-- Idempotent: bisa dijalankan ulang dengan aman.

insert into storage.buckets (id, name, public)
values ('product-photos', 'product-photos', true)
on conflict (id) do nothing;

drop policy if exists "public baca foto produk" on storage.objects;
create policy "public baca foto produk"
  on storage.objects for select
  using (bucket_id = 'product-photos');

-- Sengaja TIDAK ada policy insert/update/delete untuk anon /
-- authenticated di bucket ini: upload hanya lewat Edge Function
-- (service_role). Bila suatu hari Auth M0 aktif, tambah policy
-- insert with check (bucket_id = 'product-photos' and
-- is_outlet_owner(...)) di sini.
