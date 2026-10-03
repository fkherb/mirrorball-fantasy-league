import { createClient } from 'npm:@supabase/supabase-js@2';

const url = Deno.env.get('SUPABASE_URL');
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const publishableKey = Deno.env.get('SUPABASE_ANON_KEY');

function response(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'access-control-allow-origin': '*',
      'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
      'access-control-allow-methods': 'POST, OPTIONS',
    },
  });
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return response({ ok: true });
  if (request.method !== 'POST') return response({ error: 'Method not allowed.' }, 405);
  if (!url || !serviceKey || !publishableKey) return response({ error: 'Account deletion is not configured.' }, 503);

  const token = request.headers.get('authorization')?.replace(/^Bearer\s+/i, '');
  if (!token) return response({ error: 'Sign in first.' }, 401);
  const caller = createClient(url, publishableKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user }, error: userError } = await caller.auth.getUser(token);
  if (userError || !user) return response({ error: 'Your sign-in has expired. Sign in again.' }, 401);

  let body: { confirmation?: string };
  try { body = await request.json(); }
  catch { return response({ error: 'Invalid request.' }, 400); }
  if (body.confirmation !== 'DELETE') return response({ error: 'Type DELETE to confirm.' }, 400);

  const { data: blockers, error: preflightError } = await caller.rpc('account_deletion_blockers');
  if (preflightError) return response({ error: 'Could not check your leagues. Please try again.' }, 500);
  if (blockers?.length) return response({ error: blockers.join(' ') }, 409);

  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  // Supabase Auth refuses to delete an owner of Storage objects. Only this
  // app's profile-picture bucket accepts user uploads; list the entire folder
  // in pages so old profile pictures are removed too.
  const folder = user.id;
  for (let page = 0; page < 100; page++) {
    const { data: files, error: listError } = await admin.storage.from('profile-pictures')
      .list(folder, { limit: 100 });
    if (listError) return response({ error: 'Could not check your profile pictures. Please try again.' }, 500);
    if (!files?.length) {
      const { error: deletionError } = await admin.auth.admin.deleteUser(user.id);
      if (deletionError) {
        console.error('Auth account deletion failed', { userId: user.id, message: deletionError.message });
        return response({ error: 'Your account was not deleted. Uploaded profile pictures may have been removed; please contact support.' }, 500);
      }
      return response({ deleted: true });
    }
    const paths = files.map((file) => `${folder}/${file.name}`);
    const { error: removeError } = await admin.storage.from('profile-pictures').remove(paths);
    if (removeError) return response({ error: 'Could not remove your profile pictures. Please try again.' }, 500);
  }

  return response({ error: 'Too many profile pictures to remove automatically. Please contact support.' }, 500);
});
