# When cert-manager's Ready Condition Runs Past Expiry Until a Reconcile — reproduction

When It Runs — Run Report #RR10 · Testing what infrastructure actually does.

Run Report: https://whenitruns.substack.com/p/when-cert-managers-ready-condition

This repository holds the reproduction from the report above: the step-1 objects printed in its §4 (Reproduction), byte for byte, and the commands its §4 prints, run one step at a time. Nothing here adds versions, configurations, or findings beyond the report.

## Setup pinned in the report

- cert-manager v1.21.2, installed from the official Helm chart `cert-manager-v1.21.2.tgz` from charts.jetstack.io with two non-default values — `crds.enabled=true`, so the chart installs the CRDs (chart default `false`), and `global.logLevel=4`, the controller log level used for the log observations in §3 (chart default `2`).
- A single-node `kind` cluster on a Linux test VM (GNU coreutils), node image `kindest/node:v1.33.4` (digest-pinned); `kubectl` within ±1 minor of the node.
- A SelfSigned `Issuer`; a `Certificate` with `duration: 1h`, `renewBefore: 55m`, RSA-2048, issued by that Issuer. Renewal is blocked by deleting the Issuer after the certificate is issued. Polling every 30 seconds; the observation window runs for at least 30 minutes past `notAfter`; then the controller is restarted.
- Verified on: 2026-09-28 (lab measurement on cert-manager v1.21.2; desk sources re-confirmed 2026-09-14; PR #8529 and the latest release re-checked 2026-09-28) — re-verification against the then-current release happens at publication.

## Not scripted here

The report describes these without printing a command for them, so they are not scripted:

- the timing of step 3 — the Issuer is deleted within the margin before the renewal fires (`renewalTime` is issuance + ~5m), and from there to the end of the window nothing writes to the Certificate, its Secret, its CertificateRequest, or the Issuer;
- the parts of a poll that step 5 names without printing a command for them there: `Ready` reason and `lastTransitionTime` and the `Issuing` condition (the commands printed in steps 2 and 4 show `status.notAfter` and the CertificateRequest state);

## Files

| File | From the report |
|---|---|
| `step1-manifest.yaml` | §4 — the objects for step 1, byte for byte |
| `reproduce.sh` | §4 — every line of its block, with the commands it prints, one step per run |

## Run order

In a disposable test cluster set up as pinned above (all times UTC):

1. `./reproduce.sh 0` — create the `kind` cluster `rr10`, install cert-manager v1.21.2 with the CRDs and controller log level 4, and confirm the rollout.
2. `./reproduce.sh 1` — apply `step1-manifest.yaml` (the SelfSigned `Issuer` and the `Certificate` `cert-a`), then wait (at most 3 minutes) until `cert-a` is `Ready=True`.
3. `./reproduce.sh 2` — the T1 baseline.
4. `./reproduce.sh 3` — delete the Issuer `selfsigned`, before `renewalTime`.
5. `./reproduce.sh 4` — wait until `renewalTime` has passed (checking every 30 seconds), then T2.
6. `./reproduce.sh 5` — wait until `notAfter` has passed (checking every 30 seconds), then the window: a poll every 30 seconds until there are at least 62 polls and 30.5 minutes, each with the three `resourceVersion`s and the `generation` (`rv`); after the window, the count of controller log lines since its start that name `cert-a`, its Secret or its requests, and the Events.
7. `./reproduce.sh 6` — note the controller pod, restart the controller and wait for the rollout, find the new controller pod (with `jq`), and wait for it to acquire the leader lease (a poll right after the restart may hit the old pod), with a poll every 5 seconds (36 polls) running meanwhile from when the new pod is found; then a poll every 30 seconds (6 polls).
8. `./reproduce.sh 7` — tear down the test cluster `rr10`.

## Expected observation

From the report (§3), for the window past `notAfter`:

> In every one of those polls: `Ready=True`, reason `Ready`, message "Certificate is up to date and has not expired", `lastTransitionTime` still 01:30:23Z, with `Issuing=True` (`Renewing`) and `status.notAfter` 02:30:23Z. In the same polls, `openssl x509 -checkend 0` on the Secret's `tls.crt` exited 1 ("Certificate will expire" — the certificate was already past its NotAfter of 02:30:23).

And after the controller restart:

> At 03:04:23Z the new pod logged the `Ready` condition changing from `True` to `False`, and from the next poll (03:04:24Z) on: `Ready=False`, reason `Expired`, message "Certificate expired on Mon, 28 Sep 2026 02:30:23 UTC", `lastTransitionTime` 03:04:23Z — about 34 minutes after `notAfter`.

The report's own limits (§6):

> **The opposite has also been reported.** A cert-manager maintainer (erikgb) recorded that *"in our case, the `Certificate` was marked as unready only when it expired"* — the certificate did flip to unready at expiry in their environment. We do not explain the difference from our no-event condition; the lab pre-registers the no-event condition and reports only what it observes there.

> **We do not measure a general window length.** Only the window we observed. The 10-hour informer resync is read from source (`context.go` L72) and is not reached within our window; we do not measure it.

---

The team behind When It Runs maintains its own test environments and re-verifies findings when new releases change things; that is what the "Verified on" date means.

Licensed under the Apache License 2.0 — see `LICENSE`.
