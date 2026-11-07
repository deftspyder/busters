# Busters

Events, sign-ups and crew tools for official Ghostbusters franchise crews. The Los Angeles Ghostbusters (LAGB) are the beta crew.

- `index.html`: the whole app (installable web app), served by GitHub Pages.
- `sw.js`, `manifest.webmanifest`, `icons/`, `img/`: app install and alerts.
- `supabase/migrations/`: the database schema, functions and access rules (Supabase project `busters`).

Sign-in, members, events and RSVPs live in Supabase. Every write goes through a database function that checks the person's abilities and records it in the action log. Row level security keeps each crew's data to its own members, and contact details to the person, Personnel and the crew admin.

**No member data goes in this repo.** It is public. The roster lives only in the database.

Ghostbusters and the No-Ghost logo are trademarks of Columbia Pictures. LAGB logos are used by the Los Angeles Ghostbusters.
