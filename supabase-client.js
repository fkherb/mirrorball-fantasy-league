import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// The publishable key is intentionally safe to expose in this static site.
// Database row-level security remains the authority for every read and write.
export const db = createClient(
  'https://mdrrnanxqazecqviaass.supabase.co',
  'sb_publishable_ylMIgpLXA0NBoeb3aPI8qQ_m0wrG7It',
);
