-- Hottest Gist GH: login accounts. Paste all of this into Supabase > SQL Editor > Run.
-- (Run it AFTER setup.sql.)

create or replace function toggle_like_auth(p_post text, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare u text := auth.uid()::text;
begin
  if u is null then raise exception 'login required'; end if;
  if length(p_post) > 100 then raise exception 'bad input'; end if;
  if p_on then
    insert into likes (post_id, client_id) values (p_post, u) on conflict do nothing;
  else
    delete from likes where post_id = p_post and client_id = u;
  end if;
end $$;

create or replace function add_comment_auth(p_post text, p_text text)
returns void language plpgsql security definer set search_path = public, auth as $$
declare u text := auth.uid()::text; n text;
begin
  if u is null then raise exception 'login required'; end if;
  if length(trim(p_text)) < 1 or length(p_text) > 500 or length(p_post) > 100 then raise exception 'bad comment'; end if;
  if (select count(*) from comments where client_id = u and created_at > now() - interval '1 minute') >= 3 then
    raise exception 'slow down';
  end if;
  select left(coalesce(nullif(trim(raw_user_meta_data->>'name'), ''), 'Fan'), 40) into n from auth.users where id = auth.uid();
  insert into comments (post_id, client_id, name, text) values (p_post, u, coalesce(n, 'Fan'), trim(p_text));
end $$;

-- Only logged-in people can like or comment now.
revoke execute on function toggle_like_auth(text, boolean) from public, anon;
revoke execute on function add_comment_auth(text, text) from public, anon;
grant execute on function toggle_like_auth(text, boolean) to authenticated;
grant execute on function add_comment_auth(text, text) to authenticated;
revoke execute on function toggle_like(text, text, boolean) from public, anon;
revoke execute on function add_comment(text, text, text, text) from public, anon;

-- Logged-in people can read comments and counts.
drop policy if exists "read visible comments auth" on comments;
create policy "read visible comments auth" on comments for select to authenticated using (hidden = false);
grant select on comments to authenticated;
grant select on like_counts, comment_counts to authenticated;
