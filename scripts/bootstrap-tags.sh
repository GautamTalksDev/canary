#!/usr/bin/env bash
# Idempotent bootstrap of the canary tag set. Creates only missing healable
# tags (not v3.0.0 after a deliberate delete) and stages creation ledger rows.
# Called at the start of every rotation via scripts/rotate.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

PENDING=.canary-pending.jsonl
mkdir -p canary
touch "$PENDING"

stage_action() {
  local pattern="$1" tag="$2" from="$3" to="$4"
  printf '{"pattern":"%s","tag":"%s","from":"%s","to":"%s"}\n' \
    "$pattern" "$tag" "$from" "$to" >>"$PENDING"
}

make_commit() {
  local msg="$1" content="$2"
  printf '%s\n' "$content" >payload.txt
  git add payload.txt
  git commit -m "$msg" >/dev/null
  git rev-parse HEAD
}

c=""
created=0
heal=(v1 v1.0.0 v1.0.1 v2 v9.0.0 v9.0.1 v9.0.2)
if ! git rev-parse -q --verify refs/tags/v1 >/dev/null 2>&1 \
  && ! git rev-parse -q --verify refs/tags/v3.0.0 >/dev/null 2>&1; then
  heal+=(v3.0.0)
fi
for tag in "${heal[@]}"; do
  if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
    continue
  fi
  if [[ -z "$c" ]]; then
    c="$(make_commit "canary bootstrap" "bootstrap-${RANDOM}")"
  fi
  git tag "$tag" "$c"
  stage_action "creation" "$tag" "" "$c"
  created=$((created + 1))
  echo "bootstrapped missing tag ${tag} at ${c}"
done
if [[ "$created" -eq 0 ]]; then
  echo "bootstrap: all healable canary tags already present"
fi
