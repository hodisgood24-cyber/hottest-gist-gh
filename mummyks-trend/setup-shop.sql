-- MummyK's Trend shop: products, orders, VIP list and settings.
-- Paste all into Supabase > SQL Editor > Run (same Supabase project as Hottest Gist). Safe to run again.
-- Then run the small "add shop admin" snippet you were sent, with your sister's email.

-- ===== Who can manage the shop =====
create table if not exists shop_admins (email text primary key);
alter table shop_admins enable row level security;
revoke all on shop_admins from anon, authenticated;

create or replace function is_shop_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from shop_admins where lower(email) = lower(coalesce(auth.jwt()->>'email', '')))
$$;
revoke execute on function is_shop_admin() from public, anon;
grant execute on function is_shop_admin() to authenticated;

-- ===== Products =====
create table if not exists shop_products (
  id bigint generated always as identity primary key,
  name text not null,
  category text not null default 'Women',
  price numeric(12,2),
  old_price numeric(12,2),
  sizes text not null default '',
  colors text not null default '',
  description text not null default '',
  images jsonb not null default '[]'::jsonb,
  in_stock boolean not null default true,
  featured boolean not null default false,
  sort int not null default 0,
  created_at timestamptz not null default now()
);
alter table shop_products enable row level security;
drop policy if exists "read products" on shop_products;
create policy "read products" on shop_products for select to anon, authenticated using (true);
revoke all on shop_products from anon, authenticated;
grant select on shop_products to anon, authenticated;

create or replace function shop_save_product(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare pid bigint := nullif(p->>'id', '')::bigint;
begin
  if not is_shop_admin() then raise exception 'not allowed'; end if;
  if pid is null then
    insert into shop_products (name, category, price, old_price, sizes, colors, description, images, in_stock, featured, sort)
    values (p->>'name', coalesce(p->>'category','Women'), nullif(p->>'price','')::numeric, nullif(p->>'old_price','')::numeric,
            coalesce(p->>'sizes',''), coalesce(p->>'colors',''), coalesce(p->>'description',''), coalesce(p->'images','[]'::jsonb),
            coalesce((p->>'in_stock')::boolean, true), coalesce((p->>'featured')::boolean, false), coalesce((p->>'sort')::int, 0))
    returning id into pid;
  else
    update shop_products set name = p->>'name', category = coalesce(p->>'category','Women'),
      price = nullif(p->>'price','')::numeric, old_price = nullif(p->>'old_price','')::numeric,
      sizes = coalesce(p->>'sizes',''), colors = coalesce(p->>'colors',''), description = coalesce(p->>'description',''),
      images = coalesce(p->'images','[]'::jsonb), in_stock = coalesce((p->>'in_stock')::boolean, true),
      featured = coalesce((p->>'featured')::boolean, false), sort = coalesce((p->>'sort')::int, 0)
    where id = pid;
  end if;
  return pid;
end $$;
create or replace function shop_delete_product(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_shop_admin() then raise exception 'not allowed'; end if;
  delete from shop_products where id = p_id;
end $$;

-- ===== Settings (WhatsApp number, currency, payment details, contact, banner) =====
create table if not exists shop_settings (key text primary key, value jsonb not null default '{}'::jsonb);
alter table shop_settings enable row level security;
drop policy if exists "read shop settings" on shop_settings;
create policy "read shop settings" on shop_settings for select to anon, authenticated using (true);
revoke all on shop_settings from anon, authenticated;
grant select on shop_settings to anon, authenticated;
create or replace function shop_set_setting(p_key text, p_value jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_shop_admin() then raise exception 'not allowed'; end if;
  insert into shop_settings (key, value) values (p_key, p_value) on conflict (key) do update set value = excluded.value;
end $$;

-- ===== Orders (customers place them without an account) =====
create table if not exists shop_orders (
  id bigint generated always as identity primary key,
  name text not null,
  phone text not null,
  delivery text not null default 'pickup',
  address text not null default '',
  note text not null default '',
  items jsonb not null default '[]'::jsonb,
  total numeric(12,2),
  status text not null default 'new' check (status in ('new','confirmed','paid','sent','done','cancelled')),
  created_at timestamptz not null default now()
);
alter table shop_orders enable row level security;
revoke all on shop_orders from anon, authenticated;

create or replace function shop_place_order(p_name text, p_phone text, p_delivery text, p_address text, p_note text, p_items jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare oid bigint; t numeric := 0; it jsonb; pr numeric; cleaned jsonb := '[]'::jsonb; q int;
begin
  if length(trim(coalesce(p_name,''))) < 2 or length(regexp_replace(coalesce(p_phone,''), '\D', '', 'g')) < 7 then raise exception 'name and phone needed'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 30 then raise exception 'cart is empty'; end if;
  if (select count(*) from shop_orders where phone = p_phone and created_at > now() - interval '10 minutes') >= 3 then raise exception 'Please wait a few minutes before ordering again'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    q := greatest(1, least(20, coalesce((it->>'qty')::int, 1)));
    select price into pr from shop_products where id = (it->>'id')::bigint;
    cleaned := cleaned || jsonb_build_array(jsonb_build_object('id', (it->>'id')::bigint, 'name', left(coalesce(it->>'name',''), 80),
      'size', left(coalesce(it->>'size',''), 30), 'color', left(coalesce(it->>'color',''), 30), 'qty', q, 'price', pr));
    t := t + coalesce(pr, 0) * q;
  end loop;
  insert into shop_orders (name, phone, delivery, address, note, items, total)
  values (left(trim(p_name), 60), left(trim(p_phone), 30), case when p_delivery = 'delivery' then 'delivery' else 'pickup' end,
          left(coalesce(p_address,''), 200), left(coalesce(p_note,''), 300), cleaned, t)
  returning id into oid;
  return oid;
end $$;

create or replace function shop_list_orders() returns setof shop_orders
language plpgsql security definer set search_path = public as $$
begin
  if not is_shop_admin() then raise exception 'not allowed'; end if;
  return query select * from shop_orders order by created_at desc limit 200;
end $$;
create or replace function shop_set_order_status(p_id bigint, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_shop_admin() then raise exception 'not allowed'; end if;
  update shop_orders set status = p_status where id = p_id;
end $$;

-- ===== VIP list =====
create table if not exists shop_vip (
  phone text primary key,
  name text not null,
  likes text not null default '',
  created_at timestamptz not null default now()
);
alter table shop_vip enable row level security;
revoke all on shop_vip from anon, authenticated;
create or replace function shop_join_vip(p_name text, p_phone text, p_likes text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if length(trim(coalesce(p_name,''))) < 2 or length(regexp_replace(coalesce(p_phone,''), '\D', '', 'g')) < 7 then raise exception 'name and phone needed'; end if;
  insert into shop_vip (phone, name, likes) values (left(trim(p_phone),30), left(trim(p_name),60), left(coalesce(p_likes,''),100))
  on conflict (phone) do update set name = excluded.name, likes = excluded.likes;
end $$;
create or replace function shop_list_vip() returns setof shop_vip
language plpgsql security definer set search_path = public as $$
begin
  if not is_shop_admin() then raise exception 'not allowed'; end if;
  return query select * from shop_vip order by created_at desc;
end $$;

-- ===== Permissions =====
revoke execute on function shop_save_product(jsonb), shop_delete_product(bigint), shop_set_setting(text, jsonb),
  shop_list_orders(), shop_set_order_status(bigint, text), shop_list_vip() from public, anon;
grant execute on function shop_save_product(jsonb), shop_delete_product(bigint), shop_set_setting(text, jsonb),
  shop_list_orders(), shop_set_order_status(bigint, text), shop_list_vip() to authenticated;
revoke execute on function shop_place_order(text, text, text, text, text, jsonb), shop_join_vip(text, text, text) from public;
grant execute on function shop_place_order(text, text, text, text, text, jsonb), shop_join_vip(text, text, text) to anon, authenticated;

-- ===== Product photos =====
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('shop-images', 'shop-images', true, 8388608, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
drop policy if exists "shop admin upload" on storage.objects;
create policy "shop admin upload" on storage.objects for insert to authenticated with check (bucket_id = 'shop-images' and is_shop_admin());
drop policy if exists "shop admin delete" on storage.objects;
create policy "shop admin delete" on storage.objects for delete to authenticated using (bucket_id = 'shop-images' and is_shop_admin());

-- ===== Starter settings and products (only added the first time) =====
insert into shop_settings (key, value) values
  ('shop', '{"whatsapp":"905538944237","currency":"GH₵","announcement":"New styles arriving soon. Join the VIP list to be the first to know.","payment":"","phone":"+90 553 894 42 37","email":"","instagram":"","tiktok":"","address":"","hours":"","delivery":"Message us your location to check delivery options and cost."}')
on conflict (key) do nothing;
insert into shop_products (name, category, sizes, images, featured, sort)
select * from (values
  ('Burgundy co-ord set', 'Men', 'S, M, L, XL', '["img/p1.jpg"]'::jsonb, true, 1),
  ('White shirt & brown trousers', 'Men', 'S, M, L, XL', '["img/p2.jpg"]'::jsonb, true, 2),
  ('Black knit polo & white trousers', 'Men', 'S, M, L, XL', '["img/p3.jpg"]'::jsonb, true, 3)
) v where not exists (select 1 from shop_products);
