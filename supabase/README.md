# Busters database

Supabase project `busters`. Migrations here mirror what is applied to the live project.

Member data is never stored in this repo. The LAGB roster was seeded straight into the database, so migration 006 (`006_roster_rookies`, the roster seed) is deliberately not here. Everything else from 001 on is, so the schema can be rebuilt; seed the roster separately.

Some early files were merged or renamed when they were applied (for example 025 to 030 went live under their topic names), so file numbers and the live migration names don't always match one to one.
