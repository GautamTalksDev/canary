#!/usr/bin/env bash
# Run all canary patterns against a throwaway local repo + bare remote.
# Asserts tag state, push success, and ledger rows after each pattern.
# Simulates a poll between split halves (3a/3b, 4a/4b).
# Also asserts that a forced mid-pattern failure does not advance state or
# leave a finalize-able pending row.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/canary-patterns.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "scratch=${TMP}"

BARE="${TMP}/remote.git"
WORK="${TMP}/work"

git init --bare -b main "$BARE" >/dev/null

git clone "$BARE" "$WORK" >/dev/null 2>&1
cd "$WORK"
git config user.name "canary-test"
git config user.email "canary-test@refledger.invalid"
printf 'seed\n' >README.md
git add README.md
git commit -m "seed" >/dev/null
git push -u origin main >/dev/null

mkdir -p canary scripts
cp "$ROOT/scripts/rotate.sh" "$ROOT/scripts/finalize-ledger.sh" scripts/
chmod +x scripts/*.sh

echo 0 >.canary-state
: >.canary-pending.jsonl
: >canary/ledger.jsonl
git add .canary-state .canary-pending.jsonl canary/ledger.jsonl
git commit -m "canary: test genesis" >/dev/null
git push origin main >/dev/null

# Simulated poll between pattern halves (wall-clock stand-in for one slot).
simulate_poll() {
  echo "== simulated poll =="
  sleep 0
}

ledger_lines() {
  if [[ -f canary/ledger.jsonl ]]; then
    grep -c . canary/ledger.jsonl || true
  else
    echo 0
  fi
}

tag_commit() {
  git rev-parse "$1^{}"
}

tag_object() {
  git rev-parse "refs/tags/$1"
}

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: ${msg} (got=${got} want=${want})" >&2
    exit 1
  fi
}

assert_lightweight() {
  local tag="$1" obj type
  obj="$(tag_object "$tag")"
  type="$(git cat-file -t "$obj")"
  assert_eq "$type" "commit" "tag ${tag} should be lightweight"
}

assert_annotated() {
  local tag="$1" obj type
  obj="$(tag_object "$tag")"
  type="$(git cat-file -t "$obj")"
  assert_eq "$type" "tag" "tag ${tag} should be annotated"
}

run_one() {
  local expect_rows="$1"
  local before after pending_rows pattern_rows
  before="$(ledger_lines)"
  bash scripts/rotate.sh
  git push origin HEAD:main
  git push origin --tags --force
  # Mirror workflow: propagate local tag deletions to the bare remote.
  for t in v1 v1.0.0 v1.0.1 v2 v3.0.0 v9.0.0 v9.0.1 v9.0.2; do
    if ! git rev-parse -q --verify "refs/tags/${t}" >/dev/null 2>&1; then
      git push origin ":refs/tags/${t}" || true
    fi
  done
  bash scripts/finalize-ledger.sh
  after="$(ledger_lines)"
  pending_rows="$(grep -c . .canary-pending.jsonl 2>/dev/null || true)"
  assert_eq "${pending_rows:-0}" "0" "pending must be empty after finalize"
  pattern_rows="$(python3 - "$before" "$after" "$expect_rows" <<'PY'
import json
import sys

start, end, expect = map(int, sys.argv[1:4])
with open("canary/ledger.jsonl", encoding="utf-8") as f:
    rows = [json.loads(ln) for ln in f if ln.strip()]
new = rows[start:end]
assert len(new) == end - start, (len(new), end - start)
for row in new:
    assert row.get("performed_at", "").endswith("Z"), row
    assert "pattern" in row and "tag" in row, row
pattern_rows = [r for r in new if r.get("pattern") != "creation"]
assert len(pattern_rows) == expect, (
    f"pattern rows got={len(pattern_rows)} want={expect}; all={new}"
)
creations = len(new) - len(pattern_rows)
print(f"ok: {len(pattern_rows)} pattern row(s) stamped (+{creations} creation)")
print(len(pattern_rows))
PY
)"
  # python prints the count on the last line; ignore for assert_eq of exit
  :
}

echo "== pattern 0 floating_major_forward =="
run_one 1
assert_eq "$(cat .canary-state)" "1" "state after pattern 0"
assert_lightweight v1

echo "== pattern 1 exact_content_change =="
run_one 1
assert_eq "$(cat .canary-state)" "2" "state after pattern 1"
assert_lightweight v1.0.0

echo "== pattern 2 commit_metadata_only =="
run_one 1
assert_eq "$(cat .canary-state)" "3" "state after pattern 2"
assert_lightweight v1.0.1

echo "== pattern 3a lightweight_to_annotated =="
run_one 1
assert_eq "$(cat .canary-state)" "4" "state after pattern 3a"
assert_annotated v2
simulate_poll

echo "== pattern 3b annotated_to_lightweight =="
run_one 1
assert_eq "$(cat .canary-state)" "5" "state after pattern 3b"
assert_lightweight v2

echo "== pattern 4a delete =="
run_one 1
assert_eq "$(cat .canary-state)" "6" "state after pattern 4a"
if git rev-parse -q --verify refs/tags/v3.0.0 >/dev/null 2>&1; then
  echo "FAIL: v3.0.0 should be absent after delete" >&2
  exit 1
fi
simulate_poll

echo "== pattern 4b recreate =="
run_one 1
assert_eq "$(cat .canary-state)" "7" "state after pattern 4b"
assert_lightweight v3.0.0

echo "== pattern 5 batch_exact_to_one =="
run_one 3
assert_eq "$(cat .canary-state)" "0" "state wraps to 0 after batch"
batch_tip="$(tag_commit v9.0.0)"
assert_eq "$(tag_commit v9.0.1)" "$batch_tip" "batch tags share tip"
assert_eq "$(tag_commit v9.0.2)" "$batch_tip" "batch tags share tip"

cd "$BARE"
for t in v1 v1.0.0 v1.0.1 v2 v3.0.0 v9.0.0 v9.0.1 v9.0.2; do
  git rev-parse -q --verify "refs/tags/${t}" >/dev/null
done
cd "$WORK"
echo "ok: all tags present on bare remote"

echo "== failure must not advance state or leave pending =="
STATE_BEFORE="$(cat .canary-state)"
LEDGER_BEFORE="$(ledger_lines)"
: >.canary-pending.jsonl

set +e
CANARY_FAIL_AFTER_FIRST_STAGE=1 FORCE_PATTERN=lightweight_to_annotated \
  bash scripts/rotate.sh
ec=$?
set -e
assert_eq "$ec" "1" "injected failure exit code"

assert_eq "$(cat .canary-state)" "$STATE_BEFORE" "state must not advance on failure"
pending_rows="$(grep -c . .canary-pending.jsonl 2>/dev/null || true)"
assert_eq "${pending_rows:-0}" "0" "pending must be cleared on failure"
assert_eq "$(ledger_lines)" "$LEDGER_BEFORE" "ledger must be unchanged on failure"

bash scripts/finalize-ledger.sh
assert_eq "$(ledger_lines)" "$LEDGER_BEFORE" "finalize must not invent rows"

echo "ALL PATTERNS OK"
