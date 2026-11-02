-- Hottest Gist GH: let visitors READ the site without an account.
-- Liking, commenting, voting, posting and following still need a login.
-- Paste all into Supabase > SQL Editor > Run. Safe to run again.

-- Stories from the admin page
drop policy if exists "read posts guest" on site_posts;
create policy "read posts guest" on site_posts for select to anon using (status = 'live');
grant select on site_posts to anon;

-- Site settings (trending card, sponsor slot, etc.)
drop policy if exists "read settings guest" on site_settings;
create policy "read settings guest" on site_settings for select to anon using (true);
grant select on site_settings to anon;

-- Comments and counts
drop policy if exists "read visible comments" on comments;
create policy "read visible comments" on comments for select to anon using (hidden = false);
grant select on comments to anon;
grant select on like_counts, comment_counts, reaction_counts, poll_counts to anon;

-- Fan posts and the names/photos shown on them
drop policy if exists "read fan posts guest" on fan_posts;
create policy "read fan posts guest" on fan_posts for select to anon using (hidden = false);
grant select on fan_posts to anon;
drop policy if exists "read profiles guest" on profiles;
create policy "read profiles guest" on profiles for select to anon using (true);
grant select on profiles to anon;
grant select on creator_stats, user_stats, leaderboard to anon;

-- Fan wall
drop policy if exists "read wall guest" on wall;
create policy "read wall guest" on wall for select to anon using (hidden = false);
grant select on wall to anon;
