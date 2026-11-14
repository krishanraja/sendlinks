#!/usr/bin/env bash
# What must never be committed to this public repository: a key, a JWT, a SendLinks bearer,
# or the Mindmaker OS database address. The pattern is krish-raja's public-script guard
# (scripts/public-script-guard.ts there), run here over every tracked file. A hit fails CI.
# Docs name the address as $SUPABASE_URL / $SUPABASE_PROJECT_REF instead.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

labels=(
  "a JWT"
  "a Supabase key (sb_secret_ or sb_publishable_)"
  "a SendLinks bearer (sl_...)"
  "a Supabase project address (<ref>.supabase.co)"
  "a project ref passed to the CLI or API"
  "a Postgres connection string to a Supabase host"
)
patterns=(
  'eyJhbGciOi[A-Za-z0-9_-]{10,}'
  'sb_(secret|publishable)_[A-Za-z0-9_-]{8,}'
  '\bsl_[A-Za-z0-9_-]{30,}'
  '\b[a-z0-9]{20}\.supabase\.(co|in)\b'
  '(--project-ref[ =]+|/v1/projects/)[a-z0-9]{20}\b'
  'postgres(ql)?://[^@[:space:]]*@[^/[:space:]]*supabase\.'
)

fail=0
for i in "${!patterns[@]}"; do
  hits=$(git ls-files -z | grep -zv '^scripts/check-no-secrets.sh$' \
    | xargs -0 grep -nIE "${patterns[$i]}" -- 2>/dev/null | cut -d: -f1,2 || true)
  if [ -n "$hits" ]; then
    echo "Found ${labels[$i]} in:"; echo "$hits" | sed 's/^/  /'
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "No keys, JWTs, bearers or database addresses in tracked files."
exit "$fail"
