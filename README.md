# ADAA Family Finance — Supabase Cloud Migration Package

This build adds optional Supabase cloud storage and authentication while retaining GitHub Pages as the static website host and localStorage as the browser cache.

## Included
- `index.html` — ADAA application with Supabase sign-in, household onboarding, cloud loading/upload and automatic version-checked sync.
- `supabase-config.js` — empty client configuration template. Add your Supabase Project URL and public anon/publishable key.
- `supabase/schema.sql` — household tables, RLS policies, and secure RPC functions.
- `supabase/README.md` — detailed setup and family member onboarding instructions.

## Important security notes
- Never put a Supabase `service_role` or secret key in this repository or in browser JavaScript.
- The public anon/publishable key is intended for browser use only when RLS and database grants are correctly configured.
- Cloud users sign in using Supabase Auth. Household membership and roles are enforced by PostgreSQL policies and RPC logic.
- `admin` can manage all ADAA data. `entry` can append transactions only; server-side checks reject replacing existing transactions or changing admin settings.
- Existing local PINs and auto-lock settings are not uploaded to Supabase.
- Download a JSON backup before the first upload or import.

## First-time setup
See `supabase/README.md`. The database cannot be connected until you create your own Supabase project and fill in `supabase-config.js`.
