-- Run after add-user-profiles.sql. Public profile pictures are readable by
-- anyone, but only a signed-in user can upload into their own UUID folder.
begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'profile-pictures', 'profile-pictures', true, 2097152,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do nothing;

drop policy if exists "users upload own profile pictures" on storage.objects;
create policy "users upload own profile pictures"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'profile-pictures'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
  and array_length(storage.foldername(name), 1) = 1
  and lower(storage.extension(name)) in ('jpg', 'jpeg', 'png', 'webp')
);

commit;
