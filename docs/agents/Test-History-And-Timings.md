# Test History and Timings (the RunQuota observation store)

Read this when you need **how long something took, how much memory it
used, or how it died** — slow-test triage, flake hunting, OOM diagnosis,
before/after performance claims. It is the only durable record of those;
runner stdout is not kept.

## Before you trust an empty result

The store is **host-wide and provisioned by an install step, not created
on demand**. On Linux it is `/var/lib/runquota/observations.sqlite3`
(macOS `/var/db/runquota`, Windows `C:\ProgramData\runquota`). The path
reads *no* environment variables, deliberately — an env override would
reintroduce the per-user divergence the fixed path exists to remove.

If that directory is absent, `runquotad` **refuses capture** and runs
normally otherwise. Nothing fails. Builds and tests pass. No rows are
written.

> **The trap:** the query API returns an **empty sequence** when capture
> is off — it does not raise. So a query against an unprovisioned host
> answers "no slow tests" rather than "no data", and that answer looks
> exactly like a healthy result. *Check capture is on before concluding
> anything from an empty or thin result set.*

Two more things that produce a silently empty store:

- **The daemon decides at startup.** A `runquotad` already running when
  the directory was created still has capture off. It must be restarted.
- `.nimtest/history.db` is the **retired** per-runner backend. Data does
  not go there any more; finding one tells you nothing about today.

## What is recorded

One `runs` row per **runner invocation** (not per worker — the runner
opens a single session for the whole run), and one `executions` row per
executed process, carrying:

| Column | Why it matters |
|---|---|
| `duration_millis`, `started_at_unix_millis` | the timing question |
| `termination` | `exited` / `signalled` / `timeout` / `oom_killed` / `refused` — **the daemon knows**, so never infer OOM or timeout from an exit status |
| `exit_status`, `attempt`, `retry_of` | retries are linked, not conflated |
| `peak_rss_bytes`, `max_processes` | memory pressure and fan-out |
| `cpu_user_millis`, `cpu_sys_millis` | CPU time vs wall time — the gap is contention or I/O wait |
| `io_read_bytes`, `io_write_bytes`, `major_page_faults` | is it slow, or is it thrashing? |
| `capture_completeness` | `complete` / `sampled` / `degraded` |

Rows are **immutable after write** — a trigger aborts any `update`.

## Two rules for reading it honestly

1. **`capture_completeness` is not decoration.** A `duration_millis`
   from a `degraded` capture is not comparable with one from a
   `complete` capture. Filter, or say which you included.
2. **Rankings are scoped to a host profile and never cross one.**
   `queryRanking` groups by `host_profile_id` on purpose: the same test
   on hosts with different CPU counts or memory is not the same
   measurement. Do not aggregate across profiles to get a bigger sample.

## Query surface

In `runquota_observation_store/query.nim`:

- `queryRanking` — costliest stats keys, ranked within a profile. This
  is the slow-test question.
- `queryExecutions` — individual executions matching a row query.
- `estimateFor` / `estimateForAt` — the expected cost of a stats key,
  which is what adaptive timeouts consume.

The DB is ordinary SQLite; ad-hoc `select` is fine for investigation.
Prefer the typed API for anything that lands in a test or a report.

## Provisioning (needs root, once per host)

`runquotad` prints the exact command when it refuses. It is:

```
sudo mkdir -p /var/lib/runquota && sudo chown <daemon-uid> /var/lib/runquota && sudo chmod 0755 /var/lib/runquota
```

Ownership is the **daemon's user**, not root — the daemon writes the
machine's `host_id` file inside it on first start, and a root-owned
directory reproduces the defect the provisioning step exists to prevent.
`0755` because the directory is host-wide by design. The canonical
source is `runquota`'s `nix/host-state.nix`, which
`tests/integration/t_host_identity_refusal.nim` asserts agrees with the
paths compiled into the daemon.

If several users run daemons on one host, they contend for one
directory; only the owner can write `host_id`. That is a host decision,
not something to fix per session.
