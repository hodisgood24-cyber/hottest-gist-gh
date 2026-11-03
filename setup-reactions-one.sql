-- Hottest Gist GH: one reaction per person per post (picking a new emoji replaces the old one).
-- Paste into Supabase > SQL Editor > Run. Safe to run again.

-- 1. Tidy up: keep a single reaction for anyone who currently has several on the same post
delete from reactions r
using reactions k
where r.post_id = k.post_id and r.client_id = k.client_id and r.emoji > k.emoji;

-- 2. New rule for future reactions
create or replace function toggle_reaction_auth(p_post text, p_emoji text, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare u text := auth.uid()::text;
begin
  if u is null then raise exception 'login required'; end if;
  if p_emoji not in ('fire','lol','love','clap') or length(p_post) > 100 then raise exception 'bad input'; end if;
  if p_on then
    delete from reactions where post_id = p_post and client_id = u and emoji <> p_emoji;
    insert into reactions (post_id, client_id, emoji) values (p_post, u, p_emoji) on conflict do nothing;
  else
    delete from reactions where post_id = p_post and client_id = u and emoji = p_emoji;
  end if;
end $$;
revoke execute on function toggle_reaction_auth(text, text, boolean) from public, anon;
grant execute on function toggle_reaction_auth(text, text, boolean) to authenticated;

notify pgrst, 'reload schema';
