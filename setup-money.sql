-- Hottest Gist GH: ways to earn. Ads and sponsor slots, creator tips, paid event tickets, creator earnings and payouts.
-- Run AFTER setup-paystack.sql and setup-creators.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.
-- Money is stored in pesewas (GHS x 100).

-- ===== Earnings ledger (tips and ticket sales) and payout requests =====
create table if not exists creator_earnings (
  id bigint generated always as identity primary key,
  user_id uuid not null,               -- who earned it
  source text not null check (source in ('tip', 'ticket')),
  gross int not null,
  fee int not null default 0,          -- the site's cut
  net int not null,                    -- what the creator gets
  ref text not null,
  from_user uuid,
  note text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists creator_earnings_user on creator_earnings (user_id, created_at desc);
alter table creator_earnings enable row level security;
revoke all on creator_earnings from anon, authenticated;

create table if not exists payout_requests (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  amount int not null check (amount > 0),
  momo text not null,
  network text not null default '',
  status text not null default 'requested' check (status in ('requested', 'paid', 'rejected')),
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
create index if not exists payout_requests_user on payout_requests (user_id, created_at desc);
alter table payout_requests enable row level security;
revoke all on payout_requests from anon, authenticated;

create or replace function my_earnings() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); earned int; tips int; tix int; reserved int; paid int;
begin
  if me is null then raise exception 'login required'; end if;
  select coalesce(sum(net), 0), coalesce(sum(net) filter (where source = 'tip'), 0), coalesce(sum(net) filter (where source = 'ticket'), 0)
    into earned, tips, tix from creator_earnings where user_id = me;
  select coalesce(sum(amount) filter (where status in ('requested', 'paid')), 0), coalesce(sum(amount) filter (where status = 'paid'), 0)
    into reserved, paid from payout_requests where user_id = me;
  return jsonb_build_object(
    'earned', earned, 'tips', tips, 'tickets', tix, 'paid_out', paid, 'pending', reserved - paid, 'available', earned - reserved,
    'recent', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select e.source, e.net, e.note, e.created_at, (select name from profiles where user_id = e.from_user) as from_name
        from creator_earnings e where e.user_id = me order by e.created_at desc limit 20) x), '[]'::jsonb),
    'payouts', coalesce((select jsonb_agg(y order by y.created_at desc) from (
        select p.amount, p.status, p.momo, p.created_at from payout_requests p where p.user_id = me order by p.created_at desc limit 10) y), '[]'::jsonb));
end $$;

create or replace function payout_request(p_amount_ghs numeric, p_momo text, p_network text default '') returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); amt int := round(p_amount_ghs * 100); avail int;
begin
  if me is null then raise exception 'login required'; end if;
  if amt < 2000 then raise exception 'The smallest payout is GHS 20'; end if;
  if length(trim(coalesce(p_momo, ''))) < 9 then raise exception 'Enter your Mobile Money number'; end if;
  if exists (select 1 from payout_requests where user_id = me and status = 'requested') then raise exception 'You already have a payout waiting'; end if;
  select coalesce(sum(net), 0) - coalesce((select sum(amount) from payout_requests where user_id = me and status in ('requested', 'paid')), 0)
    into avail from creator_earnings where user_id = me;
  if amt > avail then raise exception 'That is more than your available balance'; end if;
  insert into payout_requests (user_id, amount, momo, network) values (me, amt, left(trim(p_momo), 20), left(coalesce(p_network, ''), 20));
end $$;

create or replace function admin_payouts() returns table (id bigint, user_id uuid, name text, amount int, momo text, network text, status text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return query select r.id, r.user_id, p.name, r.amount, r.momo, r.network, r.status, r.created_at
    from payout_requests r left join profiles p on p.user_id = r.user_id
    order by (r.status = 'requested') desc, r.created_at desc limit 100;
end $$;

create or replace function admin_payout_set(p_id bigint, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_status not in ('paid', 'rejected') then raise exception 'bad status'; end if;
  update payout_requests set status = p_status, paid_at = case when p_status = 'paid' then now() else null end where id = p_id and status = 'requested';
end $$;

-- ===== Tips =====
-- Called by the payment webhook (service role only). Safe to run twice for the same payment.
create or replace function record_tip(p_from uuid, p_to uuid, p_ref text, p_amount int, p_currency text, p_msg text, p_cut int) returns boolean
language plpgsql security definer set search_path = public as $$
declare added int; f int;
begin
  insert into payments (reference, user_id, amount, currency, months) values (p_ref, p_from, p_amount, p_currency, 0) on conflict (reference) do nothing;
  get diagnostics added = row_count;
  if added = 0 then return false; end if;
  f := round(p_amount * least(greatest(coalesce(p_cut, 10), 0), 50) / 100.0);
  insert into creator_earnings (user_id, source, gross, fee, net, ref, from_user, note) values (p_to, 'tip', p_amount, f, p_amount - f, p_ref, p_from, left(coalesce(p_msg, ''), 140));
  return true;
end $$;
revoke execute on function record_tip(uuid, uuid, text, int, text, text, int) from public, anon, authenticated;
grant execute on function record_tip(uuid, uuid, text, int, text, text, int) to service_role;

-- ===== Ads and sponsor slots =====
create table if not exists ads (
  id bigint generated always as identity primary key,
  owner uuid not null,
  kind text not null check (kind in ('banner', 'post')),
  title text not null,
  body text not null default '',
  image text,
  link text not null,
  status text not null default 'draft' check (status in ('draft', 'review', 'live', 'rejected', 'expired')),
  days int not null default 7,
  ref text,
  starts_at timestamptz,
  ends_at timestamptz,
  views int not null default 0,
  clicks int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists ads_live on ads (status, ends_at);
alter table ads enable row level security;
revoke all on ads from anon, authenticated;

create or replace function ad_create(p_kind text, p_title text, p_body text, p_image text, p_link text) returns bigint
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pre text; nid bigint;
begin
  if me is null then raise exception 'login required'; end if;
  if p_kind not in ('banner', 'post') then raise exception 'bad kind'; end if;
  if length(trim(coalesce(p_title, ''))) < 3 or length(p_title) > 80 then raise exception 'Give your ad a short title'; end if;
  if length(coalesce(p_body, '')) > 300 then raise exception 'The text is too long'; end if;
  if coalesce(p_link, '') !~* '^https?://[^ ]+$' then raise exception 'Add the link people should open (starting with https://)'; end if;
  if coalesce(p_image, '') <> '' then
    pre := 'https://zcejqihsmyxplerihser.supabase.co/storage/v1/object/public/fan-media/' || me::text || '/';
    if left(p_image, length(pre)) <> pre then raise exception 'bad image'; end if;
  end if;
  if (select count(*) from ads where owner = me and created_at > now() - interval '1 day') >= 10 then raise exception 'Slow down a little'; end if;
  insert into ads (owner, kind, title, body, image, link) values (me, p_kind, trim(p_title), trim(coalesce(p_body, '')), nullif(p_image, ''), trim(p_link)) returning id into nid;
  return nid;
end $$;

create or replace function ad_mine() returns table (id bigint, kind text, title text, status text, days int, starts_at timestamptz, ends_at timestamptz, views int, clicks int, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select a.id, a.kind, a.title, a.status, a.days, a.starts_at, a.ends_at, a.views, a.clicks, a.created_at
  from ads a where a.owner = auth.uid() order by a.created_at desc limit 50;
$$;

create or replace function ad_active() returns table (id bigint, kind text, title text, body text, image text, link text)
language sql stable security definer set search_path = public as $$
  select a.id, a.kind, a.title, a.body, a.image, a.link from ads a
  where a.status = 'live' and a.ends_at > now() order by a.starts_at desc limit 20;
$$;

create or replace function ad_view(p_id bigint) returns void language sql security definer set search_path = public as $$
  update ads set views = views + 1 where id = p_id and status = 'live';
$$;
create or replace function ad_click(p_id bigint) returns void language sql security definer set search_path = public as $$
  update ads set clicks = clicks + 1 where id = p_id and status = 'live';
$$;

-- Called by the payment webhook: the ad goes to review (an admin approves it before it shows)
create or replace function grant_ad(p_ad bigint, p_ref text, p_amount int, p_currency text, p_days int) returns boolean
language plpgsql security definer set search_path = public as $$
declare uid uuid; added int;
begin
  select owner into uid from ads where id = p_ad and status = 'draft';
  if uid is null then return false; end if;
  insert into payments (reference, user_id, amount, currency, months) values (p_ref, uid, p_amount, p_currency, 0) on conflict (reference) do nothing;
  get diagnostics added = row_count;
  if added = 0 then return false; end if;
  update ads set status = 'review', ref = p_ref, days = p_days where id = p_ad;
  return true;
end $$;
revoke execute on function grant_ad(bigint, text, int, text, int) from public, anon, authenticated;
grant execute on function grant_ad(bigint, text, int, text, int) to service_role;

create or replace function admin_ads() returns table (id bigint, kind text, title text, link text, status text, days int, views int, clicks int, owner_name text, ends_at timestamptz, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return query select a.id, a.kind, a.title, a.link, a.status, a.days, a.views, a.clicks, p.name, a.ends_at, a.created_at
    from ads a left join profiles p on p.user_id = a.owner
    order by (a.status = 'review') desc, a.created_at desc limit 100;
end $$;

create or replace function admin_ad_set(p_id bigint, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_status not in ('live', 'rejected', 'expired') then raise exception 'bad status'; end if;
  if p_status = 'live' then
    update ads set status = 'live', starts_at = now(), ends_at = now() + (days * interval '1 day') where id = p_id and status in ('review', 'rejected', 'expired');
  else update ads set status = p_status where id = p_id; end if;
end $$;

-- ===== Paid event tickets =====
create table if not exists ticket_events (
  id bigint generated always as identity primary key,
  organizer uuid not null,
  title text not null,
  venue text not null,
  starts_at timestamptz not null,
  description text not null default '',
  image text,
  price int not null check (price >= 100),   -- pesewas per ticket
  capacity int not null check (capacity between 1 and 20000),
  sold int not null default 0,
  status text not null default 'review' check (status in ('review', 'live', 'closed', 'rejected')),
  created_at timestamptz not null default now()
);
create index if not exists ticket_events_live on ticket_events (status, starts_at);
alter table ticket_events enable row level security;
revoke all on ticket_events from anon, authenticated;

create table if not exists tickets (
  id bigint generated always as identity primary key,
  event_id bigint not null references ticket_events (id) on delete cascade,
  buyer uuid not null,
  code text not null unique,
  ref text not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists tickets_buyer on tickets (buyer);
alter table tickets enable row level security;
revoke all on tickets from anon, authenticated;

create or replace function event_create(p_title text, p_venue text, p_when timestamptz, p_desc text, p_image text, p_price_ghs numeric, p_capacity int) returns bigint
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pre text; nid bigint;
begin
  if me is null then raise exception 'login required'; end if;
  if length(trim(coalesce(p_title, ''))) < 3 or length(p_title) > 100 then raise exception 'Give the event a title'; end if;
  if length(trim(coalesce(p_venue, ''))) < 2 or length(p_venue) > 100 then raise exception 'Add the venue'; end if;
  if p_when is null or p_when < now() then raise exception 'Pick a date in the future'; end if;
  if p_price_ghs is null or p_price_ghs < 1 or p_price_ghs > 5000 then raise exception 'Ticket price must be between GHS 1 and 5000'; end if;
  if p_capacity is null or p_capacity < 1 or p_capacity > 20000 then raise exception 'How many tickets are for sale?'; end if;
  if length(coalesce(p_desc, '')) > 800 then raise exception 'The description is too long'; end if;
  if coalesce(p_image, '') <> '' then
    pre := 'https://zcejqihsmyxplerihser.supabase.co/storage/v1/object/public/fan-media/' || me::text || '/';
    if left(p_image, length(pre)) <> pre then raise exception 'bad image'; end if;
  end if;
  if (select count(*) from ticket_events where organizer = me and created_at > now() - interval '1 day') >= 5 then raise exception 'Slow down a little'; end if;
  insert into ticket_events (organizer, title, venue, starts_at, description, image, price, capacity)
  values (me, trim(p_title), trim(p_venue), p_when, trim(coalesce(p_desc, '')), nullif(p_image, ''), round(p_price_ghs * 100), p_capacity) returning id into nid;
  return nid;
end $$;

create or replace function event_list() returns table (id bigint, title text, venue text, starts_at timestamptz, description text, image text, price int, remaining int, organizer_name text)
language sql stable security definer set search_path = public as $$
  select e.id, e.title, e.venue, e.starts_at, e.description, e.image, e.price, greatest(e.capacity - e.sold, 0), p.name
  from ticket_events e left join profiles p on p.user_id = e.organizer
  where e.status = 'live' and e.starts_at > now() - interval '6 hours' order by e.starts_at asc limit 100;
$$;

create or replace function event_mine() returns table (id bigint, title text, starts_at timestamptz, price int, capacity int, sold int, status text, checked_in int)
language sql stable security definer set search_path = public as $$
  select e.id, e.title, e.starts_at, e.price, e.capacity, e.sold, e.status, (select count(*)::int from tickets t where t.event_id = e.id and t.used_at is not null)
  from ticket_events e where e.organizer = auth.uid() order by e.starts_at desc limit 50;
$$;

create or replace function my_tickets() returns table (id bigint, code text, used boolean, title text, venue text, starts_at timestamptz)
language sql stable security definer set search_path = public as $$
  select t.id, t.code, t.used_at is not null, e.title, e.venue, e.starts_at
  from tickets t join ticket_events e on e.id = t.event_id where t.buyer = auth.uid() order by e.starts_at desc, t.id desc limit 100;
$$;

-- At the door: the organizer (or an admin) checks a ticket code. A valid ticket is marked as used.
create or replace function ticket_check(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); t tickets; e ticket_events; c text := upper(trim(coalesce(p_code, '')));
begin
  if me is null then raise exception 'login required'; end if;
  select * into t from tickets where code = c;
  if t.id is null then return jsonb_build_object('result', 'invalid'); end if;
  select * into e from ticket_events where id = t.event_id;
  if e.organizer <> me and not is_admin() then return jsonb_build_object('result', 'invalid'); end if;
  if t.used_at is not null then return jsonb_build_object('result', 'used', 'event', e.title, 'at', t.used_at); end if;
  update tickets set used_at = now() where id = t.id;
  return jsonb_build_object('result', 'ok', 'event', e.title, 'holder', (select name from profiles where user_id = t.buyer));
end $$;

-- Called by the payment webhook (service role only). Safe to run twice for the same payment.
create or replace function issue_tickets(p_event bigint, p_buyer uuid, p_qty int, p_ref text, p_amount int, p_currency text, p_fee_pct int) returns int
language plpgsql security definer set search_path = public as $$
declare e ticket_events; added int; n int := 0; f int;
begin
  select * into e from ticket_events where id = p_event for update;
  if e.id is null then return 0; end if;
  insert into payments (reference, user_id, amount, currency, months) values (p_ref, p_buyer, p_amount, p_currency, 0) on conflict (reference) do nothing;
  get diagnostics added = row_count;
  if added = 0 then return 0; end if;
  while n < p_qty loop
    insert into tickets (event_id, buyer, code, ref) values (p_event, p_buyer, upper(substr(md5(random()::text || clock_timestamp()::text || n::text), 1, 10)), p_ref);
    n := n + 1;
  end loop;
  update ticket_events set sold = sold + p_qty where id = p_event;
  f := round(p_amount * least(greatest(coalesce(p_fee_pct, 5), 0), 50) / 100.0);
  insert into creator_earnings (user_id, source, gross, fee, net, ref, from_user, note) values (e.organizer, 'ticket', p_amount, f, p_amount - f, p_ref, p_buyer, left(e.title || ' x' || p_qty, 140));
  return n;
end $$;
revoke execute on function issue_tickets(bigint, uuid, int, text, int, text, int) from public, anon, authenticated;
grant execute on function issue_tickets(bigint, uuid, int, text, int, text, int) to service_role;

create or replace function admin_events() returns table (id bigint, title text, venue text, starts_at timestamptz, price int, capacity int, sold int, status text, organizer_name text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return query select e.id, e.title, e.venue, e.starts_at, e.price, e.capacity, e.sold, e.status, p.name
    from ticket_events e left join profiles p on p.user_id = e.organizer
    order by (e.status = 'review') desc, e.starts_at desc limit 100;
end $$;

create or replace function admin_event_set(p_id bigint, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_status not in ('live', 'closed', 'rejected') then raise exception 'bad status'; end if;
  update ticket_events set status = p_status where id = p_id;
end $$;

-- ===== Grants =====
revoke execute on function my_earnings(), payout_request(numeric, text, text), admin_payouts(), admin_payout_set(bigint, text),
  ad_create(text, text, text, text, text), ad_mine(), ad_active(), ad_view(bigint), ad_click(bigint), admin_ads(), admin_ad_set(bigint, text),
  event_create(text, text, timestamptz, text, text, numeric, int), event_list(), event_mine(), my_tickets(), ticket_check(text), admin_events(), admin_event_set(bigint, text) from public;
grant execute on function ad_active(), ad_view(bigint), ad_click(bigint), event_list() to anon, authenticated;
grant execute on function my_earnings(), payout_request(numeric, text, text), admin_payouts(), admin_payout_set(bigint, text),
  ad_create(text, text, text, text, text), ad_mine(), admin_ads(), admin_ad_set(bigint, text),
  event_create(text, text, timestamptz, text, text, numeric, int), event_mine(), my_tickets(), ticket_check(text), admin_events(), admin_event_set(bigint, text) to authenticated;
notify pgrst, 'reload schema';
