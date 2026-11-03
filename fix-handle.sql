-- Hottest Gist GH: let the site owner claim reserved page names like @hottestgistgh.
-- Paste into Supabase > SQL Editor > Run. Safe to run again.

-- Claim or change my page name
create or replace function set_handle(p_handle text) returns text
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); h text := lower(trim(coalesce(p_handle, '')));
begin
  if u is null then raise exception 'login required'; end if;
  h := regexp_replace(h, '^@', '');
  if h !~ '^[a-z0-9_.]{3,24}$' or h ~ '^[._]' or h ~ '[._]$' then
    raise exception 'Use 3 to 24 letters, numbers, dots or underscores';
  end if;
  if not coalesce(is_admin(), false) and h in ('admin','hottestgist','hottestgistgh','hottest','official','support','help','stories','about','privacy','terms','api','login','settings','s','images','brand','tools','supabase','null','undefined') then
    raise exception 'That name is reserved. Try another one';
  end if;
  if exists (select 1 from profiles where lower(handle) = h and user_id <> u) then raise exception 'That name is taken. Try another one'; end if;
  if exists (select 1 from blocked_words w where h ~* w.word) then raise exception 'That name is not allowed'; end if;
  update profiles set handle = h where user_id = u;
  if not found then raise exception 'Set up your profile first'; end if;
  return h;
end $$;

revoke execute on function set_handle(text) from public, anon;
grant execute on function set_handle(text) to authenticated;
notify pgrst, 'reload schema';
