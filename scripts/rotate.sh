#!/usr/bin/env bash
# Rotate through §6.2 tag-movement patterns. Ground-truth ledger lines are
# staged without performed_at — the workflow stamps that after git push returns
# so we time detection against the push, not GitHub Actions queue delay.
#
# Patterns act only on PRE-EXISTING tags (created once by bootstrap_tags).
# Patterns 3 and 4 are split across rotations so each intermediate state
# survives at least one poll interval.
#
# On any failure: do not advance .canary-state, and clear .canary-pending.jsonl
# so a partial ledger row cannot be finalized.
set -euo pipefail
cd "$(dirname "$0")/.."

LEDGER=canary/ledger.jsonl
PENDING=.canary-pending.jsonl
STATE=.canary-state

mkdir -p canary
touch "$LEDGER"
: >"$PENDING"
[[ -f "$STATE" ]] || echo 0 >"$STATE"

PATTERNS=(
  floating_major_forward
  exact_content_change
  commit_metadata_only
  lightweight_to_annotated
  annotated_to_lightweight
  delete
  recreate
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

require_tag() {
  local tag="$1"
  if ! git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
    echo "missing pre-existing tag ${tag}; run scripts/bootstrap-tags.sh first" >&2
    exit 1
  fi
}

# Create any missing tags from the stable canary set. Idempotent: existing tags
# are left alone. v3.0.0 is excluded from per-rotation healing so a deliberate
# delete half stays deleted until recreate. Each newly created tag is staged as
# a creation ledger row so canary-score does not treat it as a miss.
bootstrap_tags() {
  local c="" tag created=0
  local heal=(v1 v1.0.0 v1.0.1 v2 v9.0.0 v9.0.1 v9.0.2)
  # True first materialization: also create v3.0.0 once.
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

bootstrap_tags

idx="$(current)"
pattern="${PATTERNS[$idx]}"
echo "pattern=${pattern} idx=${idx}"

case "$pattern" in
  floating_major_forward)
    require_tag v1
    from="$(git rev-parse refs/tags/v1)"
    tree_b="$(make_commit "canary tree B ahead" "tree-b-${RANDOM}")"
    git tag -f v1 "$tree_b"
    stage_action "$pattern" "v1" "$from" "$tree_b"
    ;;
  exact_content_change)
    require_tag v1.0.0
    from="$(git rev-parse refs/tags/v1.0.0)"
    c2="$(make_commit "exact after" "exact-after-${RANDOM}")"
    git tag -f v1.0.0 "$c2"
    stage_action "$pattern" "v1.0.0" "$from" "$c2"
    ;;
  commit_metadata_only)
    require_tag v1.0.1
    from="$(git rev-parse 'refs/tags/v1.0.1^{}')"
    tree="$(git rev-parse "${from}^{tree}")"
    new="$(git commit-tree "$tree" -m "meta amended $(date -u +%s)" -p "$from")"
    git tag -f v1.0.1 "$new"
    stage_action "$pattern" "v1.0.1" "$from" "$new"
    ;;
  lightweight_to_annotated)
    # Half of former pattern 3: leave annotated until the next rotation.
    require_tag v2
    if is_annotated_tag v2; then
      echo "expected lightweight tag v2 before lightweight_to_annotated" >&2
      exit 1
    fi
    from="$(git rev-parse refs/tags/v2)"
    c="$(git rev-parse 'refs/tags/v2^{}')"
    delete_tag v2
    git tag -a v2 -m "annotated canary" "$c"
    if ! is_annotated_tag v2; then
      echo "expected annotated tag v2" >&2
      exit 1
    fi
    to="$(git rev-parse refs/tags/v2)"
    stage_action "$pattern" "v2" "$from" "$to"
    if [[ "${CANARY_FAIL_AFTER_FIRST_STAGE:-}" == "1" ]]; then
      echo "injected failure after first stage_action" >&2
      false
    fi
    ;;
  annotated_to_lightweight)
    require_tag v2
    if ! is_annotated_tag v2; then
      echo "expected annotated tag v2 before annotated_to_lightweight" >&2
      exit 1
    fi
    from="$(git rev-parse refs/tags/v2)"
    c="$(git rev-parse 'refs/tags/v2^{}')"
    delete_tag v2
    git tag v2 "$c"
    if is_annotated_tag v2; then
      echo "expected lightweight tag v2 after annotated_to_lightweight" >&2
      exit 1
    fi
    stage_action "$pattern" "v2" "$from" "$(git rev-parse refs/tags/v2)"
    ;;
  delete)
    # Half of former pattern 4: leave missing until the next rotation.
    require_tag v3.0.0
    from="$(git rev-parse 'refs/tags/v3.0.0^{}')"
    stage_action "$pattern" "v3.0.0" "$from" ""
    delete_tag v3.0.0
    if git rev-parse -q --verify refs/tags/v3.0.0 >/dev/null 2>&1; then
      echo "v3.0.0 should be deleted" >&2
      exit 1
    fi
    ;;
  recreate)
    if git rev-parse -q --verify refs/tags/v3.0.0 >/dev/null 2>&1; then
      echo "expected v3.0.0 absent before recreate" >&2
      exit 1
    fi
    c2="$(make_commit "recreate after" "rec-${RANDOM}")"
    git tag v3.0.0 "$c2"
    stage_action "$pattern" "v3.0.0" "" "$c2"
    ;;
  batch_exact_to_one)
    require_tag v9.0.0
    require_tag v9.0.1
    require_tag v9.0.2
    t="$(make_commit "batch target" "batch-${RANDOM}")"
    local_tag=""
    for local_tag in v9.0.0 v9.0.1 v9.0.2; do
      from="$(git rev-parse "refs/tags/${local_tag}^{}")"
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
