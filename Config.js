// Supabase деректері. Project Settings → API бөлімінен ал.
// Мұнда тек Project URL және publishable (anon) кілті тұрады.
// secret / service_role кілтін бұл файлға ешқашан жазба.
export const CONFIG = {
  SUPABASE_URL: 'YOUR_SUPABASE_URL',           // https://xxxx.supabase.co (соңында /rest/v1 болмасын)
  SUPABASE_ANON_KEY: 'YOUR_SUPABASE_ANON_KEY'  // sb_publishable_... немесе eyJ... деп басталады
};
