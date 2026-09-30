#!/usr/bin/env bash
# Rotate through §6.2 tag-movement patterns. Ground-truth ledger lines are
# staged without performed_at — the workflow stamps that after git push returns
# so we time detection against the push, not GitHub Actions queue delay.
#
# On any failure: do not advance .canary-state, and clear .canary-pending.jsonl
# so a partial ledger row cannot be finalized.
set -euo pipefail
cd "$(dirname "$0")/.."

LEDGER=canary/ledger.jsonl
PENDING=.canary-pending.jsonl
STATE=.canary-state
# delete_recreate waits so the poller can observe a missing tag. Tests set 0.
DELETE_SLEEP="${CANARY_DELETE_SLEEP:-5}"

mkdir -p canary
touch "$LEDGER"
: >"$PENDING"
[[ -f "$STATE" ]] || echo 0 >"$STATE"

PATTERNS=(
  floating_major_forward
  exact_content_change
  commit_metadata_only
  lightweight_annotated_roundtrip
  delete_recreate
  batch_exact_to_one
)

STATE_AT_START="$(cat "$STATE")"

rollback() {
  local ec=$?
  trap - ERR
  echo "$STATE_AT_START" >"$STATE"
  : >"$PENDING"
  echo "canary rotate failed (exit ${ec}); state restored to ${STATE_AT_START}, pending cleared" >&2
  exit "$ec"
}
trap rollback ERR

stage_action() {
  local pattern="$1" tag="$2" from="$3" to="$4"
  printf '{"pattern":"%s","tag":"%s","from":"%s","to":"%s"}\n' \
    "$pattern" "$tag" "$from" "$to" >>"$PENDING"
}

ensure_blob() {
  local content="$1" path="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" >"$path"
  git add "$path"
  # First materialization may be a no-op if the blob already matches.
  git commit -m "canary: material $path" >/dev/null 2>&1 || true
}

make_commit() {
  local msg="$1" content="$2"
  ensure_blob "$content" "payload.txt"
  printf '%s\n' "$content" >payload.txt
  git add payload.txt
  git commit -m "$msg" >/dev/null
  git rev-parse HEAD
}

# Delete a tag if present. Never combine -d with -f (git rejects that).
delete_tag() {
  local tag="$1"
  if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
    git tag -d "$tag" >/dev/null
  fi
}

# True when refs/tags/<tag> is an annotated tag object.
is_annotated_tag() {
  local tag="$1" obj type
  obj="$(git rev-parse "refs/tags/${tag}")"
  type="$(git cat-file -t "$obj")"
  [[ "$type" == "tag" ]]
}

current() {
  local idx
  idx="$(cat "$STATE")"
  if [[ -n "${FORCE_PATTERN:-}" ]]; then
    local i
    for i in "${!PATTERNS[@]}"; do
      if [[ "${PATTERNS[$i]}" == "$FORCE_PATTERN" ]]; then
        echo "$i"
        return
      fi
    done
    echo "unknown FORCE_PATTERN=${FORCE_PATTERN}" >&2
    exit 1
  fi
  echo "$idx"
}

idx="$(current)"
pattern="${PATTERNS[$idx]}"
echo "pattern=${pattern} idx=${idx}"

case "$pattern" in
  floating_major_forward)
    tree_a="$(make_commit "canary tree A" "tree-a-${RANDOM}")"
    git tag -f v1 "$tree_a"
    from=$tree_a
    tree_b="$(make_commit "canary tree B ahead" "tree-b-${RANDOM}")"
    git tag -f v1 "$tree_b"
    stage_action "$pattern" "v1" "$from" "$tree_b"
    ;;
  exact_content_change)
    c1="$(make_commit "exact before" "exact-before-${RANDOM}")"
    git tag -f v1.0.0 "$c1"
    c2="$(make_commit "exact after" "exact-after-${RANDOM}")"
    git tag -f v1.0.0 "$c2"
    stage_action "$pattern" "v1.0.0" "$c1" "$c2"
    ;;
  commit_metadata_only)
    base="$(make_commit "meta base" "same-tree-content")"
    tree="$(git rev-parse 'HEAD^{tree}')"
    new="$(git commit-tree "$tree" -m "meta amended $(date -u +%s)" -p HEAD)"
    git tag -f v1.0.1 "$base"
    from=$base
    git tag -f v1.0.1 "$new"
    stage_action "$pattern" "v1.0.1" "$from" "$new"
    ;;
  lightweight_annotated_roundtrip)
    # Lightweight → annotated → lightweight again. Two ledger rows.
    c="$(make_commit "lw/ann" "lw-ann-${RANDOM}")"
    delete_tag v2
    git tag v2 "$c"
    if is_annotated_tag v2; then
      echo "expected lightweight tag v2" >&2
      exit 1
    fi
    from="$(git rev-parse refs/tags/v2)"
    delete_tag v2
    git tag -a v2 -m "annotated canary" "$c"
    if ! is_annotated_tag v2; then
      echo "expected annotated tag v2" >&2
      exit 1
    fi
    to="$(git rev-parse refs/tags/v2)"
    stage_action "$pattern" "v2" "$from" "$to"
    # Test hook: fail after the first staged row so rollback can be asserted.
    if [[ "${CANARY_FAIL_AFTER_FIRST_STAGE:-}" == "1" ]]; then
      echo "injected failure after first stage_action" >&2
      false
    fi
    delete_tag v2
    git tag v2 "$c"
    if is_annotated_tag v2; then
      echo "expected lightweight tag v2 after roundtrip" >&2
      exit 1
    fi
    stage_action "$pattern" "v2" "$to" "$(git rev-parse refs/tags/v2)"
    ;;
  delete_recreate)
    c1="$(make_commit "delete before" "del-${RANDOM}")"
    git tag -f v3.0.0 "$c1"
    stage_action "$pattern" "v3.0.0" "$c1" ""
    delete_tag v3.0.0
    if git rev-parse -q --verify refs/tags/v3.0.0 >/dev/null 2>&1; then
      echo "v3.0.0 should be deleted" >&2
      exit 1
    fi
    sleep "$DELETE_SLEEP"
    c2="$(make_commit "recreate after" "rec-${RANDOM}")"
    git tag v3.0.0 "$c2"
    stage_action "$pattern" "v3.0.0" "" "$c2"
    ;;
  batch_exact_to_one)
    t="$(make_commit "batch target" "batch-${RANDOM}")"
    local_tag=""
    for local_tag in v9.0.0 v9.0.1 v9.0.2; do
      old="$(make_commit "batch ${local_tag} old" "old-${local_tag}-${RANDOM}")"
      git tag -f "$local_tag" "$old"
      from=$old
      git tag -f "$local_tag" "$t"
      stage_action "$pattern" "$local_tag" "$from" "$t"
    done
    ;;
  *)
    echo "unhandled pattern=${pattern}" >&2
    exit 1
    ;;
esac

# Success path: disable rollback, then advance the index.
trap - ERR
next=$(((idx + 1) % ${#PATTERNS[@]}))
echo "$next" >"$STATE"
git add "$STATE" "$PENDING"
git commit -m "canary: advance state to ${next}" >/dev/null
echo "advanced state to ${next}"
