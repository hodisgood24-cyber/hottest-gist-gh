-- Hottest Gist GH: paid "Featured" slot for Services listings.
-- Run AFTER setup-gigs.sql and setup-paystack.sql. Safe to run again.

alter table gigs add column if not exists featured_until timestamptz;

-- Only the server (service role) can call this. Safe to run twice for the same payment.
create or replace function grant_feature(p_gig bigint, p_ref text, p_amount int, p_currency text, p_days int default 7) returns boolean
language plpgsql security definer set search_path = public as $$
declare uid uuid; added int;
begin
  select user_id into uid from gigs where id = p_gig;
  if uid is null then return false; end if;
  insert into payments (reference, user_id, amount, currency, months) values (p_ref, uid, p_amount, p_currency, 0)
  on conflict (reference) do nothing;
  get diagnostics added = row_count;
  if added = 0 then return false; end if;
  update gigs set featured_until = greatest(coalesce(featured_until, now()), now()) + (p_days * interval '1 day') where id = p_gig;
  return true;
end $$;
revoke execute on function grant_feature(bigint, text, int, text, int) from public, anon, authenticated;
grant execute on function grant_feature(bigint, text, int, text, int) to service_role;

-- Admin can feature or un-feature a listing by hand (days = 0 removes it)
create or replace function admin_feature_gig(p_id bigint, p_days int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  if p_days <= 0 then update gigs set featured_until = null where id = p_id;
  else update gigs set featured_until = now() + (p_days * interval '1 day') where id = p_id; end if;
end $$;
revoke execute on function admin_feature_gig(bigint, int) from public, anon;
grant execute on function admin_feature_gig(bigint, int) to authenticated;

notify pgrst, 'reload schema';
