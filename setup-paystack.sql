-- Hottest Gist GH: automatic gold tick payments with Paystack.
-- Run AFTER setup-verify.sql. Paste all into Supabase > SQL Editor > Run. Safe to run again.

create table if not exists payments (
  reference text primary key,
  user_id uuid not null,
  amount int not null,
  currency text not null default 'GHS',
  months int not null default 1,
  created_at timestamptz not null default now()
);
alter table payments enable row level security;
revoke all on payments from anon, authenticated;

-- Only the server (service role) can call this. It is safe to run twice for the same payment.
create or replace function grant_verification(p_user uuid, p_ref text, p_amount int, p_currency text, p_months int default 1) returns boolean
language plpgsql security definer set search_path = public, auth as $$
declare n text; added int;
begin
  insert into payments (reference, user_id, amount, currency, months) values (p_ref, p_user, p_amount, p_currency, p_months)
  on conflict (reference) do nothing;
  get diagnostics added = row_count;
  if added = 0 then return false; end if;
  if not exists (select 1 from profiles where user_id = p_user) then
    select left(coalesce(nullif(trim(raw_user_meta_data->>'name'), ''), 'Fan'), 40) into n from auth.users where id = p_user;
    insert into profiles (user_id, name) values (p_user, coalesce(n, 'Fan'));
  end if;
  update profiles set
    verified_until = case when verified and verified_until is null then null
                          else greatest(coalesce(verified_until, now()), now()) + (p_months * interval '30 days') end,
    verified = true
  where user_id = p_user;
  return true;
end $$;
revoke execute on function grant_verification(uuid, text, int, text, int) from public, anon, authenticated;
grant execute on function grant_verification(uuid, text, int, text, int) to service_role;

-- Admin can see recent payments
create or replace function admin_payments() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not allowed'; end if;
  return coalesce((select jsonb_agg(x) from (
    select y.reference, p.name, y.amount, y.currency, y.created_at
    from payments y left join profiles p on p.user_id = y.user_id order by y.created_at desc limit 30) x), '[]'::jsonb);
end $$;
revoke execute on function admin_payments() from public, anon;
grant execute on function admin_payments() to authenticated;

notify pgrst, 'reload schema';
