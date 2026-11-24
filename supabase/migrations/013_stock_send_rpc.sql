-- SUKA TEA — Migrasi 013 (SEC-1 R-06: kirim stok ATOMIK via RPC)
-- Dijalankan via SQL Editor Supabase Dashboard (bukan CLI).
-- FILE SAJA — belum di-apply (Jhon yang deploy + apply).
--
-- MASALAH (audit RedMuse R-06, LOW/MEDIUM): pushStockSend di EF
-- sync-sales memakai pola cek-lalu-bertindak (TOCTOU): baca qty
-- gudang -> kalau cukup -> applyStockDelta per item dengan
-- Math.max(0, ...). Dua kiriman bersamaan yang masing-masing lolos
-- guard bisa menarik stok yang sama; selisihnya hilang diam-diam
-- karena qty di-clamp 0.
--
-- PERBAIKAN: satu fungsi Postgres SECURITY DEFINER yang mengunci
-- baris gudang (FOR UPDATE), memeriksa SEMUA item, lalu mengurangi
-- gudang + menambah gerai dalam SATU transaksi. Kurang satu saja =
-- RAISE EXCEPTION 'gudang_kurang' -> seluruh RPC rollback (tidak ada
-- item yang setengah pindah).
--
-- IDEMPOTENSI: tiap item membawa `out_uuid` + `in_uuid` (UUID turunan
-- deterministik dari client_uuid kiriman + nama bahan, dihitung EF).
-- Mutasi disisipkan dengan ON CONFLICT (client_uuid) DO NOTHING; level
-- stok HANYA diubah bila mutasi benar-benar baru -> retry event yang
-- sama tidak memotong stok dua kali.
--
-- Kolom mengikuti skema nyata (migrasi 001/004/008/011):
--   stock_items.outlet_id, name, unit, qty, low_threshold, cost,
--   shelf_life_days, updated_at
--   stock_movements.client_uuid uuid UNIQUE (migrasi 008).
-- GUDANG = pseudo-outlet '00000000-0000-0000-0000-000000000000'
-- (tanpa FK ke outlets — migrasi 011).
--
-- Dipanggil HANYA oleh EF sync-sales (service_role). EXECUTE tidak
-- diberikan ke anon/authenticated.

create or replace function public.apply_stock_send(
  p_outlet uuid,
  p_items jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gudang_id constant uuid := '00000000-0000-0000-0000-000000000000';
  it jsonb;
  v_name text;
  v_qty numeric;
  v_unit text;
  v_gudang stock_items%rowtype;
  v_gerai_id uuid;
  v_out_uuid uuid;
  v_in_uuid uuid;
  v_inserted uuid;
begin
  if p_outlet is null or p_items is null
     or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'items_invalid';
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    v_name := nullif(it->>'name', '');
    v_qty := (it->>'qty')::numeric;
    v_unit := coalesce(nullif(it->>'unit', ''), 'pcs');
    if v_name is null or v_qty is null or v_qty <= 0 then
      raise exception 'items_invalid';
    end if;

    -- Kunci baris gudang. Baris dibuat bila belum ada (qty 0) —
    -- kiriman untuk bahan yang belum pernah masuk gudang otomatis
    -- ditolak oleh cek qty di bawah.
    select * into v_gudang
      from stock_items
      where outlet_id = v_gudang_id and name = v_name
      for update;
    if not found then
      insert into stock_items
        (outlet_id, name, unit, qty, low_threshold, cost)
      values
        (v_gudang_id, v_name, v_unit, 0, 0, 0)
      returning * into v_gudang;
    end if;

    if v_gudang.qty < v_qty then
      raise exception 'gudang_kurang';
    end if;

    -- UUID mutasi dari EF (deterministik) — fallback acak supaya
    -- fungsi tetap aman bila dipanggil manual tanpa uuid.
    v_out_uuid := coalesce((it->>'out_uuid')::uuid, gen_random_uuid());
    v_in_uuid := coalesce((it->>'in_uuid')::uuid, gen_random_uuid());

    -- 1) Gudang − (hanya bila mutasi baru).
    v_inserted := null;
    insert into stock_movements
      (outlet_id, stock_item_id, qty_delta, reason, client_uuid)
    values
      (v_gudang_id, v_gudang.id, -v_qty, 'kirim', v_out_uuid)
    on conflict (client_uuid) do nothing
    returning id into v_inserted;
    if v_inserted is not null then
      update stock_items
        set qty = qty - v_qty
        where id = v_gudang.id;
    end if;

    -- 2) Gerai + (baris gerai dibuat bila belum ada).
    select id into v_gerai_id
      from stock_items
      where outlet_id = p_outlet and name = v_name
      for update;
    if v_gerai_id is null then
      insert into stock_items
        (outlet_id, name, unit, qty, low_threshold, cost)
      values
        (p_outlet, v_name, v_unit, 0, 0, 0)
      returning id into v_gerai_id;
    end if;

    v_inserted := null;
    insert into stock_movements
      (outlet_id, stock_item_id, qty_delta, reason, client_uuid)
    values
      (p_outlet, v_gerai_id, v_qty, 'kirim', v_in_uuid)
    on conflict (client_uuid) do nothing
    returning id into v_inserted;
    if v_inserted is not null then
      update stock_items
        set qty = qty + v_qty
        where id = v_gerai_id;
    end if;
  end loop;
end;
$$;

revoke all on function public.apply_stock_send(uuid, jsonb) from public;
revoke all on function public.apply_stock_send(uuid, jsonb)
  from anon, authenticated;
grant execute on function public.apply_stock_send(uuid, jsonb)
  to service_role;
