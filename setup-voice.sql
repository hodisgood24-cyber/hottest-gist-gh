-- Hottest Gist GH: allow voice notes in fan posts (adds audio types to the fan media storage).
-- Run AFTER setup-creators.sql. Paste into Supabase > SQL Editor > Run. Safe to run again.
update storage.buckets
set allowed_mime_types = array['image/jpeg','image/png','image/webp','video/mp4','video/webm','video/quicktime',
                               'audio/webm','audio/mp4','audio/mpeg','audio/ogg','audio/aac','audio/x-m4a'],
    file_size_limit = 52428800
where id = 'fan-media';
