# Security policy

This repository is a detection canary for Refledger. It moves its own
tags on a schedule, on purpose. One person maintains it. There is no
on-call rotation.

## How to report

If you believe you have found a vulnerability in the canary action, the
rotation scripts, or this repository's workflows, report it privately:

[github.com/GautamTalksDev/canary/security/advisories/new](https://github.com/GautamTalksDev/canary/security/advisories/new).

Vulnerabilities in the ledger or the public website belong on those
repositories, not here:

- [refledger](https://github.com/GautamTalksDev/refledger/security/advisories/new)
- [refledger-site](https://github.com/GautamTalksDev/refledger-site/security/advisories/new)

Do not open a public issue for an unfixed vulnerability.

## What is in scope

- `action.yml` and the composite action
- `scripts/` and `.github/workflows/`
- The ground-truth ledger at `canary/ledger.jsonl`, if a bug would let
  someone other than the scheduled workflow rewrite it

## What is out of scope

- Tag movement itself. The tags in this repository are supposed to move.
  A moved canary tag is not a vulnerability.
- Using this action in a production workflow. It is not a security tool
  and it is not safe to pin as a dependency.
- Refledger's poller, log, or website, except where this repo's scripts
  are the defect

## What to expect

- **Acknowledgement:** we aim to acknowledge a private report within
  72 hours. One maintainer, no SLA.
- **A fix:** may take longer than that acknowledgement.
- **Safe harbour:** we will not pursue or support legal action against
  researchers who follow this process, avoid privacy violations, avoid
  destruction of data, and give us a reasonable chance to respond before
  public disclosure.
