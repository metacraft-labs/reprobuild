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
> exactly like a healthy result.
>
> **`runquota stats` closes this trap, which is why you should use it.**
> Every verb reports a `status`, and the exit code separates the kinds:
> **0** rows, **3** no answer, **4** no working instrument.

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
| `major_page_faults` | is it slow, or is it thrashing? |
| `capture_completeness` | `complete` / `sampled` / `degraded` |

> **`cpu_user_millis`, `cpu_sys_millis`, `io_read_bytes` and
> `io_write_bytes` exist in the schema but nothing ever writes them.**
> Both of the daemon's insert paths pass `none(int64)` unconditionally
> and no code anywhere computes a value, so they are NULL on every row
> ever recorded. **"Is it slow because of CPU, I/O, or waiting?" is not
> answerable from this store at any layer**, and no flag changes that.
> Do not plan a measurement around them.

Rows are **immutable after write** — a trigger aborts any `update`. Note
that the trigger guards `update` ONLY: `delete` succeeds, so retention
can prune.

## Two rules for reading it honestly

1. **`capture_completeness` is not decoration.** A `duration_millis`
   from a `degraded` capture is not comparable with one from a
   `complete` capture. Filter, or say which you included.
2. **Rankings are scoped to a host profile and never cross one.**
   `queryRanking` groups by `host_profile_id` on purpose: the same test
   on hosts with different CPU counts or memory is not the same
   measurement. Do not aggregate across profiles to get a bigger sample.

## Asking: `runquota stats`

Three verbs. All take `--json`.

| Verb | Question |
|---|---|
| `runquota stats capture` | is capture on, which store, what the daemon counted |
| `runquota stats top [KEY]` | which is costliest — total, count, max, ranked within a profile |
| `runquota stats export [KEY]` | **one JSON object per execution, every recorded column** |

Flags: `--limit N`, `--all-users`, `--all-profiles`, `--json`.

**`export` is the interface; everything else is `jq`.** A row carries
every column above plus the `runs` and `host_profiles` context that makes
it readable alone — tool, workspace, git commit, CPU model, core count.
So percentiles, before-and-after, grade filtering and whatever you need
next are `jq` over NDJSON, not a query language anyone has to learn:

```sh
# costliest keys
runquota stats export | jq -s 'group_by(.command_stats_id)
  | map({k:.[0].command_stats_id, n:length, total:(map(.duration_millis)|add)})
  | sort_by(-.total)'
# p50/p90 for one key — the shape a total hides
runquota stats export KEY | jq -s '[.[].duration_millis] | sort
  | {n:length, min:.[0], p50:.[(length*0.5|floor)], p90:.[(length*0.9|floor)], max:.[-1]}'
# OOM vs timeout vs real failure — never inferred from exit status
runquota stats export | jq -s 'group_by(.termination)
  | map({(.[0].termination): length}) | add'
```

`export` writes NDJSON to **stdout** and its status to **stderr**, so the
pipe above is safe: nothing but JSON objects ever reaches stdout, on any
path including refusals and errors.

**Read the `status`, not the row count.** `ok` · `no-data` ·
`unknown-key` · `no-rows-in-scope` · `capture-off` ·
`daemon-unreachable` · `denied`, with exit codes 0 / 3 / 4 as above.
`no-rows-in-scope` means the rows exist but your scope or profile
filtered them out — widen with `--all-users` / `--all-profiles`; it is
*not* `unknown-key`.

A row is ~1.4 KB and a response must fit one 1 MiB frame, so `--limit`
defaults to 250 and is **refused** above 600 rather than clamped. There
is no time cursor: `export` gives the newest N.

**Do not open the database file.** `runquotad` is the only sanctioned
reader, and an inspection gate
(`runquota/tests/unit/t_observation_store_reader_boundary.nim`) fails any
client that does. This is not bureaucracy: a direct read *works*, is
faster, and returns real rows — while silently skipping everything the
daemon applies on the way out, namely uid scoping from peer credentials,
hardware qualification, and the unknown-versus-zero distinction. The gate
discovers its source set by walking `libs/` and `apps/`, so it catches a
violation in a module that does not exist yet.

The typed reads in `runquota_observation_store/query.nim` are what the
daemon itself uses — relevant when changing RunQuota, not when asking it
questions.

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
