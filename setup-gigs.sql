-- Hottest Gist GH: Services board (creators offer services, brands post gigs).
-- Run AFTER setup-creators.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

create table if not exists gigs (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  kind text not null check (kind in ('offer', 'request')),
  category text not null,
  title text not null,
  body text not null default '',
  price text not null default '',
  contact text not null,
  link text,
  image text,
  hidden boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists gigs_time on gigs (created_at desc);
alter table gigs enable row level security;
drop policy if exists "read gigs" on gigs;
create policy "read gigs" on gigs for select to authenticated using (hidden = false or user_id = auth.uid() or is_admin());
revoke all on gigs from anon, authenticated;
grant select on gigs to authenticated;

create or replace function add_gig(p_kind text, p_category text, p_title text, p_body text, p_price text, p_contact text, p_link text default null, p_image text default null) returns bigint
language plpgsql security definer set search_path = public, auth as $$
declare u uuid := auth.uid(); pre text; nid bigint; n text; allt text;
begin
  if u is null then raise exception 'login required'; end if;
  pre := 'https://zcejqihsmyxplerihser.supabase.co/storage/v1/object/public/fan-media/' || u::text || '/';
  p_title := trim(coalesce(p_title, '')); p_body := trim(coalesce(p_body, ''));
  p_price := trim(coalesce(p_price, '')); p_contact := trim(coalesce(p_contact, ''));
  if p_kind not in ('offer', 'request') then raise exception 'bad kind'; end if;
  if p_category not in ('CapCut and video editing', 'Promo and shoutouts', 'Music promotion', 'Design and cover art', 'Photography and video', 'Content creation', 'Other') then raise exception 'bad category'; end if;
  if length(p_title) < 5 or length(p_title) > 80 or length(p_body) > 600 or length(p_price) > 40 or length(p_contact) < 5 or length(p_contact) > 80 then raise exception 'bad input'; end if;
  if p_contact !~ '^(\+?[0-9][0-9 ()-]{6,19}|[^@ ]+@[^@ ]+\.[^@ ]+)$' then raise exception 'bad contact'; end if;
  allt := p_title || ' ' || p_body || ' ' || p_price;
  if allt ~* '(https?://|www\.)' or exists (select 1 from blocked_words w where allt ~* ('\m' || w.word || '\M')) then raise exception 'not allowed'; end if;
  if coalesce(p_link, '') <> '' and (length(p_link) > 300 or p_link !~* '^https://([a-z0-9-]+\.)*(youtube\.com|youtu\.be|tiktok\.com|facebook\.com|fb\.watch|instagram\.com|soundcloud\.com|audiomack\.com|spotify\.com|behance\.net|drive\.google\.com)/') then
    raise exception 'link not allowed';
  end if;
  if coalesce(p_image, '') <> '' and left(p_image, length(pre)) <> pre then raise exception 'bad image'; end if;
  if (select count(*) from gigs where user_id = u and created_at > now() - interval '1 day') >= 3 then raise exception 'slow down'; end if;
  if not exists (select 1 from profiles where user_id = u) then
    select left(coalesce(nullif(trim(raw_user_meta_data->>'name'), ''), 'Fan'), 40) into n from auth.users where id = u;
    insert into profiles (user_id, name) values (u, coalesce(n, 'Fan'));
  end if;
  insert into gigs (user_id, kind, category, title, body, price, contact, link, image)
  values (u, p_kind, p_category, p_title, p_body, p_price, p_contact, nullif(p_link, ''), nullif(p_image, '')) returning id into nid;
  return nid;
end $$;
revoke execute on function add_gig(text, text, text, text, text, text, text, text) from public, anon;
grant execute on function add_gig(text, text, text, text, text, text, text, text) to authenticated;

create or replace function delete_gig(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  delete from gigs where id = p_id and (user_id = auth.uid() or is_admin());
end $$;
revoke execute on function delete_gig(bigint) from public, anon;
grant execute on function delete_gig(bigint) to authenticated;

-- Reports and admin tools now cover gigs
create or replace function report_auth(p_kind text, p_id bigint, p_reason text default '') returns void
language plpgsql security definer set search_path = public as $$
declare u text := auth.uid()::text;
begin
  if u is null then raise exception 'login required'; end if;
  if p_kind not in ('comment', 'wall', 'fan', 'gig') then raise exception 'bad input'; end if;
  insert into reports (kind, item_id, client_id, reason) values (p_kind, p_id, u, left(coalesce(p_reason, ''), 200)) on conflict do nothing;
  if (select count(*) from reports where kind = p_kind and item_id = p_id) >= 3 then
    if p_kind = 'comment' then update comments set hidden = true where id = p_id;
    elsif p_kind = 'wall' then update wall set hidden = true where id = p_id;
    elsif p_kind = 'gig' then update gigs set hidden = true where id = p_id;
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
  else raise exception 'bad input'; end if;
end $$;

create or replace function admin_gigs() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return coalesce((select jsonb_agg(x) from (
    select g.id, g.kind, g.title, g.category, g.hidden, g.created_at, p.name,
           (select count(*) from reports r where r.kind = 'gig' and r.item_id = g.id) as reports
    from gigs g left join profiles p on p.user_id = g.user_id order by g.created_at desc limit 40) x), '[]'::jsonb);
end $$;
revoke execute on function admin_gigs() from public, anon;
grant execute on function admin_gigs() to authenticated;

notify pgrst, 'reload schema';
