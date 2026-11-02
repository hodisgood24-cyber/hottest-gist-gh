-- Hottest Gist GH: paid monthly gold tick (manual approval).
-- Run AFTER setup-creators.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

alter table profiles add column if not exists verified_until timestamptz;

-- A tick counts only while it has not expired (no date = permanent, e.g. yours).
create or replace view creator_stats as
select p.user_id, p.name, p.bio, p.avatar,
  (p.verified and (p.verified_until is null or p.verified_until > now())) as verified,
  (select count(*) from follows f where f.followee = p.user_id)::int as followers,
  (select count(*) from fan_posts x where x.user_id = p.user_id and not x.hidden)::int as posts,
  (select count(*) from likes l join fan_posts x on l.post_id = 'fp-' || x.id::text where x.user_id = p.user_id and not x.hidden)::int as likes,
  p.verified_until
from profiles p;
grant select on creator_stats to authenticated;

create table if not exists verification_requests (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  reference text not null,
  note text not null default '',
  status text not null default 'pending',
  created_at timestamptz not null default now()
);
alter table verification_requests enable row level security;
drop policy if exists "own requests" on verification_requests;
create policy "own requests" on verification_requests for select to authenticated using (user_id = auth.uid());
revoke all on verification_requests from anon, authenticated;
grant select on verification_requests to authenticated;

create or replace function request_verification(p_ref text, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'login required'; end if;
  if length(trim(coalesce(p_ref, ''))) < 3 or length(p_ref) > 80 or length(coalesce(p_note, '')) > 200 then raise exception 'bad input'; end if;
  if not exists (select 1 from profiles where user_id = u) then raise exception 'no profile'; end if;
  if (select count(*) from verification_requests where user_id = u and status = 'pending') >= 2 then raise exception 'already pending'; end if;
  insert into verification_requests (user_id, reference, note) values (u, trim(p_ref), trim(coalesce(p_note, '')));
end $$;
revoke execute on function request_verification(text, text) from public, anon;
grant execute on function request_verification(text, text) to authenticated;

create or replace function admin_verifications() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return coalesce((select jsonb_agg(x) from (
    select r.id, r.user_id, p.name, r.reference, r.note, r.created_at, p.verified_until
    from verification_requests r left join profiles p on p.user_id = r.user_id
    where r.status = 'pending' order by r.created_at limit 100) x), '[]'::jsonb);
end $$;
revoke execute on function admin_verifications() from public, anon;
grant execute on function admin_verifications() to authenticated;

create or replace function admin_approve_verification(p_request bigint, p_months int default 1) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_months < 1 or p_months > 24 then raise exception 'bad input'; end if;
  select user_id into u from verification_requests where id = p_request and status = 'pending';
  if u is null then raise exception 'not found'; end if;
  update profiles set verified = true,
    verified_until = greatest(coalesce(verified_until, now()), now()) + (p_months * interval '30 days')
  where user_id = u;
  update verification_requests set status = 'approved' where id = p_request;
end $$;
revoke execute on function admin_approve_verification(bigint, int) from public, anon;
grant execute on function admin_approve_verification(bigint, int) to authenticated;

create or replace function admin_reject_verification(p_request bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  update verification_requests set status = 'rejected' where id = p_request and status = 'pending';
end $$;
revoke execute on function admin_reject_verification(bigint) from public, anon;
grant execute on function admin_reject_verification(bigint) to authenticated;

-- Giving or removing a tick by hand clears any expiry date.
create or replace function admin_set_verified(p_user uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  update profiles set verified = p_on, verified_until = null where user_id = p_user;
end $$;

notify pgrst, 'reload schema';
