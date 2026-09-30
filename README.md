# Canary — deliberately moved tags for detection measurement

Public repository: **[`GautamTalksDev/canary`](https://github.com/GautamTalksDev/canary)**.

This is a standalone repository. It is not nested inside
[GautamTalksDev/refledger](https://github.com/GautamTalksDev/refledger).

## Purpose

Without a canary, seven days of silence on 35 official actions proves nothing
about detection. This repo moves tags on a schedule through every §6.2 pattern
and appends ground truth to `canary/ledger.jsonl`. Score the ledger from the
main Refledger repo:

```bash
cargo run --manifest-path tools/canary-score/Cargo.toml -- \
  --ledger https://raw.githubusercontent.com/GautamTalksDev/canary/main/canary/ledger.jsonl \
  --log-dir data/log
```

(`--ledger` also accepts a local path.) That writes `docs/DETECTION.md` in the
Refledger checkout.

Canary events are tagged `note: "canary"` in Refledger's
`population/watched.jsonl` and must never be counted as ecosystem movement on
the public site.

## Trigger

Rotations are driven by the external Cloudflare Worker `refledger-clock` in
the Refledger repo (`clock/`). That Worker fires `workflow_dispatch` for
`.github/workflows/canary.yml` on `main` on cron `17 */4 * * *` (minute 17
of every fourth hour). There is no Actions `schedule:` trigger on this
workflow: GitHub's scheduler was unreliable for this repo, and keeping both
would double or stagger rotations.

Manual runs remain available via Actions → canary-rotate → Run workflow.

## Patterns (rotated by the clock-driven workflow)

1. FloatingMajor forward (`v1` → newer commit, ahead)
2. Exact ContentChange (`v1.0.0` → different tree)
3. CommitMetadataOnly (same tree, amended commit)
4. lightweight → annotated and back
5. delete, then recreate at a different commit after ~15 min
6. batch: 3 Exact tags moved to one commit

Each action appends `{pattern, tag, from, to, performed_at}` to
`canary/ledger.jsonl` in this repository.
