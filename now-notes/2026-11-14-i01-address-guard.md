# 2026-11-14: the database address out of the docs, and a guard in CI

- Status: README, DEPLOY and STATE name the project as `$SUPABASE_URL` / `$SUPABASE_PROJECT_REF`.
  `scripts/check-no-secrets.sh` (run by `.github/workflows/no-secrets.yml`) fails on a JWT, a
  Supabase key, a SendLinks bearer, a project address or ref, or a Postgres URL to a Supabase
  host; each pattern was seen to fail on a probe. Earlier commits still hold the address; history
  is the security sweep's (#800).
- Next: the sendlinks halves of I-06 and I-07, once Control Center lane B sends the contract.
- North Star check (2026-11-14): this repository has no North Star file; none was added.
