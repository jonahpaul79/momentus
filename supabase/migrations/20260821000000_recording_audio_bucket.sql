-- Private, short-lived staging area for recordings sent to the transcription provider.
-- Objects are scoped to the authenticated user's UUID folder and removed by the app
-- after AssemblyAI finishes ingesting/transcribing them.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('recording-audio', 'recording-audio', false, 524288000, array['audio/mp4'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create policy "Users upload their own recording audio"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'recording-audio'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);

create policy "Users replace their own recording audio"
on storage.objects for update to authenticated
using (
  bucket_id = 'recording-audio'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
)
with check (
  bucket_id = 'recording-audio'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);

create policy "Users read their own recording audio"
on storage.objects for select to authenticated
using (
  bucket_id = 'recording-audio'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);

create policy "Users delete their own recording audio"
on storage.objects for delete to authenticated
using (
  bucket_id = 'recording-audio'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);
