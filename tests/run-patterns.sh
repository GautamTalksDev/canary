#!/usr/bin/env bash
# Run all six canary patterns against a throwaway local repo + bare remote.
# Asserts tag state, push success, and ledger rows after each pattern.
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

export CANARY_DELETE_SLEEP=0

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

run_one() {
  local expect_rows="$1"
  local before after pending_rows
  before="$(ledger_lines)"
  bash scripts/rotate.sh
  git push origin HEAD:main
  git push origin --tags --force
  bash scripts/finalize-ledger.sh
  after="$(ledger_lines)"
  assert_eq "$((after - before))" "$expect_rows" "ledger rows appended"
  pending_rows="$(grep -c . .canary-pending.jsonl 2>/dev/null || true)"
  assert_eq "${pending_rows:-0}" "0" "pending must be empty after finalize"
  python3 - "$before" "$after" <<'PY'
import json
import sys

start, end = map(int, sys.argv[1:3])
with open("canary/ledger.jsonl", encoding="utf-8") as f:
    rows = [json.loads(ln) for ln in f if ln.strip()]
new = rows[start:end]
assert len(new) == end - start, (len(new), end - start)
for row in new:
    assert row.get("performed_at", "").endswith("Z"), row
    assert "pattern" in row and "tag" in row, row
print(f"ok: {len(new)} ledger row(s) stamped")
PY
}

echo "== pattern 0 floating_major_forward =="
run_one 1
assert_eq "$(cat .canary-state)" "1" "state after pattern 0"
assert_lightweight v1
python3 - <<'PY'
import json
import subprocess

row = json.loads(open("canary/ledger.jsonl", encoding="utf-8").read().splitlines()[-1])
tip = subprocess.check_output(["git", "rev-parse", "v1"], text=True).strip()
assert row["pattern"] == "floating_major_forward"
assert row["tag"] == "v1"
assert row["to"] == tip
assert row["from"] != row["to"]
print("ok: floating_major_forward ledger")
PY

echo "== pattern 1 exact_content_change =="
run_one 1
assert_eq "$(cat .canary-state)" "2" "state after pattern 1"
assert_lightweight v1.0.0
python3 - <<'PY'
import json
import subprocess

row = json.loads(open("canary/ledger.jsonl", encoding="utf-8").read().splitlines()[-1])
tip = subprocess.check_output(["git", "rev-parse", "v1.0.0"], text=True).strip()
assert row["pattern"] == "exact_content_change"
assert row["tag"] == "v1.0.0"
assert row["to"] == tip
assert row["from"] != row["to"]
print("ok: exact_content_change ledger")
PY

echo "== pattern 2 commit_metadata_only =="
run_one 1
assert_eq "$(cat .canary-state)" "3" "state after pattern 2"
assert_lightweight v1.0.1
python3 - <<'PY'
import json
import subprocess

row = json.loads(open("canary/ledger.jsonl", encoding="utf-8").read().splitlines()[-1])
tip = subprocess.check_output(["git", "rev-parse", "v1.0.1"], text=True).strip()
tree_from = subprocess.check_output(
    ["git", "rev-parse", f"{row['from']}^{{tree}}"], text=True
).strip()
tree_to = subprocess.check_output(
    ["git", "rev-parse", f"{row['to']}^{{tree}}"], text=True
).strip()
assert row["pattern"] == "commit_metadata_only"
assert row["tag"] == "v1.0.1"
assert row["to"] == tip
assert row["from"] != row["to"]
assert tree_from == tree_to, "metadata-only must keep the same tree"
print("ok: commit_metadata_only ledger")
PY

echo "== pattern 3 lightweight_annotated_roundtrip =="
run_one 2
assert_eq "$(cat .canary-state)" "4" "state after pattern 3"
assert_lightweight v2
python3 - <<'PY'
import json
import subprocess

rows = [
    json.loads(ln)
    for ln in open("canary/ledger.jsonl", encoding="utf-8")
    if ln.strip()
]
a, b = rows[-2], rows[-1]
assert a["pattern"] == b["pattern"] == "lightweight_annotated_roundtrip"
assert a["tag"] == b["tag"] == "v2"
assert a["from"] != a["to"]
assert b["from"] == a["to"]
tip = subprocess.check_output(["git", "rev-parse", "refs/tags/v2"], text=True).strip()
assert b["to"] == tip
typ = subprocess.check_output(["git", "cat-file", "-t", tip], text=True).strip()
assert typ == "commit", typ
print("ok: lightweight_annotated_roundtrip ledger")
PY

echo "== pattern 4 delete_recreate =="
run_one 2
assert_eq "$(cat .canary-state)" "5" "state after pattern 4"
assert_lightweight v3.0.0
python3 - <<'PY'
import json
import subprocess

rows = [
    json.loads(ln)
    for ln in open("canary/ledger.jsonl", encoding="utf-8")
    if ln.strip()
]
a, b = rows[-2], rows[-1]
assert a["pattern"] == b["pattern"] == "delete_recreate"
assert a["tag"] == b["tag"] == "v3.0.0"
assert a["to"] == ""
assert b["from"] == ""
tip = subprocess.check_output(["git", "rev-parse", "v3.0.0"], text=True).strip()
assert b["to"] == tip
print("ok: delete_recreate ledger")
PY

echo "== pattern 5 batch_exact_to_one =="
run_one 3
assert_eq "$(cat .canary-state)" "0" "state wraps to 0 after pattern 5"
batch_tip="$(tag_commit v9.0.0)"
assert_eq "$(tag_commit v9.0.1)" "$batch_tip" "batch tags share tip"
assert_eq "$(tag_commit v9.0.2)" "$batch_tip" "batch tags share tip"
python3 - <<'PY'
import json
import subprocess

rows = [
    json.loads(ln)
    for ln in open("canary/ledger.jsonl", encoding="utf-8")
    if ln.strip()
]
batch = rows[-3:]
assert [r["tag"] for r in batch] == ["v9.0.0", "v9.0.1", "v9.0.2"]
tips = {r["to"] for r in batch}
assert len(tips) == 1
tip = tips.pop()
for tag in ("v9.0.0", "v9.0.1", "v9.0.2"):
    got = subprocess.check_output(["git", "rev-parse", tag], text=True).strip()
    assert got == tip
print("ok: batch_exact_to_one ledger")
PY

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
CANARY_FAIL_AFTER_FIRST_STAGE=1 FORCE_PATTERN=lightweight_annotated_roundtrip \
  bash scripts/rotate.sh
ec=$?
set -e
# ERR trap exits with the failing command's status (1 from false).
assert_eq "$ec" "1" "injected failure exit code"

assert_eq "$(cat .canary-state)" "$STATE_BEFORE" "state must not advance on failure"
pending_rows="$(grep -c . .canary-pending.jsonl 2>/dev/null || true)"
assert_eq "${pending_rows:-0}" "0" "pending must be cleared on failure"
assert_eq "$(ledger_lines)" "$LEDGER_BEFORE" "ledger must be unchanged on failure"

bash scripts/finalize-ledger.sh
assert_eq "$(ledger_lines)" "$LEDGER_BEFORE" "finalize must not invent rows"

echo "ALL PATTERNS OK"
