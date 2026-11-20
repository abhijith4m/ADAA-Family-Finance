# ADAA Supabase setup

1. Create a Supabase project.
2. Open SQL Editor and run `schema.sql`.
3. In Authentication settings, enable Email provider. For production, keep email confirmation enabled.
4. Copy Project URL and the public anon/publishable key into `supabase-config.js`. Do not use a service-role/secret key.
5. Commit `index.html`, `supabase-config.js`, and `supabase/` to the GitHub Pages repository.
6. Open the published site, create an Auth account, then create the household. The current browser data is backed up and uploaded during household creation.
7. Invite additional people from Supabase Dashboard > Authentication > Users. Copy each Auth user UUID and add them to `public.household_members` with the SQL example at the bottom of `schema.sql`.

## Roles
- `admin`: can update the full household finance dataset.
- `entry`: can add new transactions only. The database rejects changes/deletions of existing transactions and changes to household settings.

## Sync behaviour
- Local edits continue to save in the browser and are queued for cloud sync after about one second.
- Each write uses an optimistic version check. If another device has saved since this browser loaded, ADAA pauses cloud writes and asks you to load the latest cloud data. The local browser copy remains intact.
- Download a JSON backup before initial upload, loading cloud data, or making major changes.
- PINs and inactivity-lock settings stay local and are not uploaded. Supabase Auth email/password is the cloud sign-in.
- The browser uses one public client key only. Row Level Security and RPC checks protect records. Never put a service-role key in GitHub Pages.

## Architecture note
ADAA stores one versioned JSON document per household to preserve the existing static app data model. This gives straightforward migration and household isolation, but it is not a substitute for a normalized ledger if you later need advanced concurrent editing, per-record audit trails, or bank integrations. Do not edit the same household from multiple devices at the same time; if a version conflict occurs, load the latest cloud copy before continuing.
