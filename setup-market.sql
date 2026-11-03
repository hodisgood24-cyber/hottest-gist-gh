-- Hottest Gist GH: Market (buy and sell) with seller plans: Standard, Premium, Star.
-- Run AFTER setup-gigs.sql and setup-paystack.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

-- ===== Listings =====
create table if not exists market_items (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  title text not null,
  body text not null default '',
  category text not null,
  condition text not null default 'used' check (condition in ('new', 'used')),
  price numeric(12, 2),
  location text not null default '',
  images jsonb not null default '[]'::jsonb,
  contact text not null,
  sold boolean not null default false,
  hidden boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists market_items_time on market_items (created_at desc);
create index if not exists market_items_user on market_items (user_id);
alter table market_items enable row level security;
revoke all on market_items from anon, authenticated;

-- ===== Seller plans =====
create table if not exists seller_plans (
  user_id uuid primary key,
  plan text not null check (plan in ('standard', 'premium', 'star')),
  until timestamptz not null
);
alter table seller_plans enable row level security;
revoke all on seller_plans from anon, authenticated;

-- Everyone logged in can see which sellers have which active plan (for badges)
create or replace view seller_tiers as
select user_id, plan, until from seller_plans where until > now();
grant select on seller_tiers to authenticated;

create or replace function tier_rank(p text) returns int language sql immutable as $$
  select case p when 'star' then 3 when 'premium' then 2 when 'standard' then 1 else 0 end
$$;
create or replace function tier_limit(p text) returns int language sql immutable as $$
  select case p when 'star' then 200 when 'premium' then 50 when 'standard' then 15 else 3 end
$$;
create or replace function my_plan() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select plan from seller_plans where user_id = auth.uid() and until > now()), 'free')
$$;
revoke execute on function my_plan() from public, anon;
grant execute on function my_plan() to authenticated;

-- ===== Browse: paid plans rank higher, then newest first =====
create or replace function market_list(p_cat text default null, p_q text default null, p_mine boolean default false, p_limit int default 40, p_offset int default 0)
returns table (id bigint, user_id uuid, title text, body text, category text, condition text, price numeric, location text, images jsonb, contact text, sold boolean, created_at timestamptz, plan text)
language sql stable security definer set search_path = public as $$
  select i.id, i.user_id, i.title, i.body, i.category, i.condition, i.price, i.location, i.images, i.contact, i.sold, i.created_at,
         coalesce(t.plan, 'free')
  from market_items i
  left join seller_tiers t on t.user_id = i.user_id
  where auth.uid() is not null
    and (i.hidden = false or i.user_id = auth.uid() or is_admin())
    and (not p_mine or i.user_id = auth.uid())
    and (p_cat is null or p_cat = '' or i.category = p_cat)
    and (p_q is null or p_q = '' or i.title ilike '%' || replace(replace(p_q, '%', ''), '_', '') || '%' or i.location ilike '%' || replace(replace(p_q, '%', ''), '_', '') || '%')
  order by i.sold asc, tier_rank(coalesce(t.plan, 'free')) desc, i.created_at desc
  limit least(coalesce(p_limit, 40), 60) offset greatest(coalesce(p_offset, 0), 0)
$$;
revoke execute on function market_list(text, text, boolean, int, int) from public, anon;
grant execute on function market_list(text, text, boolean, int, int) to authenticated;

-- ===== Post, mark sold, delete =====
create or replace function add_market_item(p_title text, p_body text, p_category text, p_condition text, p_price numeric, p_location text, p_images jsonb, p_contact text) returns bigint
language plpgsql security definer set search_path = public, auth as $$
declare u uuid := auth.uid(); pre text; i jsonb; nid bigint; n text; allt text; plan text; active int;
begin
  if u is null then raise exception 'login required'; end if;
  pre := 'https://zcejqihsmyxplerihser.supabase.co/storage/v1/object/public/fan-media/' || u::text || '/';
  p_title := trim(coalesce(p_title, '')); p_body := trim(coalesce(p_body, '')); p_location := trim(coalesce(p_location, '')); p_contact := trim(coalesce(p_contact, ''));
  p_images := coalesce(p_images, '[]'::jsonb);
  if p_category not in ('Phones and tablets', 'Fashion and shoes', 'Music and studio gear', 'Cameras and video', 'Computers and gadgets', 'Home and furniture', 'Beauty and care', 'Food and drinks', 'Vehicles', 'Services', 'Other') then raise exception 'bad category'; end if;
  if coalesce(p_condition, '') not in ('new', 'used') then raise exception 'bad condition'; end if;
  if length(p_title) < 4 or length(p_title) > 80 or length(p_body) > 800 or length(p_location) > 60 or length(p_contact) < 5 or length(p_contact) > 80 then raise exception 'bad input'; end if;
  if p_price is not null and (p_price < 0 or p_price > 100000000) then raise exception 'bad price'; end if;
  if p_contact !~ '^(\+?[0-9][0-9 ()-]{6,19}|[^@ ]+@[^@ ]+\.[^@ ]+)$' then raise exception 'bad contact'; end if;
  if jsonb_typeof(p_images) <> 'array' or jsonb_array_length(p_images) > 5 or jsonb_array_length(p_images) < 1 then raise exception 'photos needed'; end if;
  for i in select * from jsonb_array_elements(p_images) loop
    if jsonb_typeof(i) <> 'string' or left(i #>> '{}', length(pre)) <> pre then raise exception 'bad image'; end if;
  end loop;
  allt := p_title || ' ' || p_body || ' ' || p_location;
  if allt ~* '(https?://|www\.)' or exists (select 1 from blocked_words w where allt ~* ('\m' || w.word || '\M')) then raise exception 'not allowed'; end if;
  if (select count(*) from market_items where user_id = u and created_at > now() - interval '1 day') >= 15 then raise exception 'slow down'; end if;
  plan := my_plan();
  select count(*) into active from market_items where user_id = u and not sold and not hidden;
  if active >= tier_limit(plan) then raise exception 'plan limit % %', plan, tier_limit(plan); end if;
  if not exists (select 1 from profiles where user_id = u) then
    select left(coalesce(nullif(trim(raw_user_meta_data->>'name'), ''), 'Fan'), 40) into n from auth.users where id = u;
    insert into profiles (user_id, name) values (u, coalesce(n, 'Fan'));
  end if;
  insert into market_items (user_id, title, body, category, condition, price, location, images, contact)
  values (u, p_title, p_body, p_category, p_condition, p_price, p_location, p_images, p_contact) returning id into nid;
  return nid;
end $$;
revoke execute on function add_market_item(text, text, text, text, numeric, text, jsonb, text) from public, anon;
grant execute on function add_market_item(text, text, text, text, numeric, text, jsonb, text) to authenticated;

create or replace function set_market_sold(p_id bigint, p_sold boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  update market_items set sold = p_sold where id = p_id and user_id = auth.uid();
end $$;
revoke execute on function set_market_sold(bigint, boolean) from public, anon;
grant execute on function set_market_sold(bigint, boolean) to authenticated;

create or replace function delete_market_item(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  delete from market_items where id = p_id and (user_id = auth.uid() or is_admin());
end $$;
revoke execute on function delete_market_item(bigint) from public, anon;
grant execute on function delete_market_item(bigint) to authenticated;

-- ===== Plan payments (server only) and manual grants (admin) =====
create or replace function grant_plan(p_user uuid, p_ref text, p_amount int, p_currency text, p_plan text, p_days int default 30) returns boolean
language plpgsql security definer set search_path = public as $$
declare added int; cur record;
begin
  if p_plan not in ('standard', 'premium', 'star') then return false; end if;
  insert into payments (reference, user_id, amount, currency, months) values (p_ref, p_user, p_amount, p_currency, 0)
  on conflict (reference) do nothing;
  get diagnostics added = row_count;
  if added = 0 then return false; end if;
  select * into cur from seller_plans where user_id = p_user;
  if cur.user_id is not null and cur.plan = p_plan and cur.until > now() then
    update seller_plans set until = cur.until + (p_days * interval '1 day') where user_id = p_user;
  else
    insert into seller_plans (user_id, plan, until) values (p_user, p_plan, now() + (p_days * interval '1 day'))
    on conflict (user_id) do update set plan = excluded.plan, until = excluded.until;
  end if;
  return true;
end $$;
revoke execute on function grant_plan(uuid, text, int, text, text, int) from public, anon, authenticated;
grant execute on function grant_plan(uuid, text, int, text, text, int) to service_role;

create or replace function admin_grant_plan(p_user uuid, p_plan text, p_days int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_days <= 0 or p_plan = 'free' then delete from seller_plans where user_id = p_user; return; end if;
  if p_plan not in ('standard', 'premium', 'star') then raise exception 'bad plan'; end if;
  insert into seller_plans (user_id, plan, until) values (p_user, p_plan, now() + (p_days * interval '1 day'))
  on conflict (user_id) do update set plan = excluded.plan, until = excluded.until;
end $$;
revoke execute on function admin_grant_plan(uuid, text, int) from public, anon;
grant execute on function admin_grant_plan(uuid, text, int) to authenticated;

-- ===== Reports and admin tools cover market items =====
create or replace function report_auth(p_kind text, p_id bigint, p_reason text default '') returns void
language plpgsql security definer set search_path = public as $$
declare u text := auth.uid()::text;
begin
  if u is null then raise exception 'login required'; end if;
  if p_kind not in ('comment', 'wall', 'fan', 'gig', 'item') then raise exception 'bad input'; end if;
  insert into reports (kind, item_id, client_id, reason) values (p_kind, p_id, u, left(coalesce(p_reason, ''), 200)) on conflict do nothing;
  if (select count(*) from reports where kind = p_kind and item_id = p_id) >= 3 then
    if p_kind = 'comment' then update comments set hidden = true where id = p_id;
    elsif p_kind = 'wall' then update wall set hidden = true where id = p_id;
    elsif p_kind = 'gig' then update gigs set hidden = true where id = p_id;
    elsif p_kind = 'item' then update market_items set hidden = true where id = p_id;
    else update fan_posts set hidden = true where id = p_id; end if;
  end if;
end $$;

create or replace function admin_set_hidden(p_kind text, p_id bigint, p_hidden boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_kind = 'comment' then update comments set hidden = p_hidden where id = p_id;
  elsif p_kind = 'wall' then update wall set hidden = p_hidden where id = p_id;
  elsif p_kind = 'fan' then update fan_posts set hidden = p_hidden where id = p_id;
  elsif p_kind = 'gig' then update gigs set hidden = p_hidden where id = p_id;
  elsif p_kind = 'item' then update market_items set hidden = p_hidden where id = p_id;
  else raise exception 'bad input'; end if;
end $$;

create or replace function admin_market() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(x) from (
      select i.id, i.title, i.category, i.price, i.hidden, i.sold, i.created_at, p.name,
             (select count(*) from reports r where r.kind = 'item' and r.item_id = i.id) as reports
      from market_items i left join profiles p on p.user_id = i.user_id order by i.created_at desc limit 40) x), '[]'::jsonb),
    'sellers', coalesce((select jsonb_agg(y) from (
      select s.user_id, p.name, s.plan, s.until from seller_plans s left join profiles p on p.user_id = s.user_id where s.until > now() order by s.until desc limit 40) y), '[]'::jsonb)
  );
end $$;
revoke execute on function admin_market() from public, anon;
grant execute on function admin_market() to authenticated;

notify pgrst, 'reload schema';
