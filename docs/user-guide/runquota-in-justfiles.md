# Sharing a host's CPU and memory from a Justfile

A project that still builds and tests through a `Justfile` can take part in the
host's RunQuota budget without moving to a Reprobuild graph first. Two RunQuota
commands do it, and this page is the idiom for putting them in front of the
commands that do the heavy work.

Why bother: several checkouts, agent sessions or CI jobs on one machine each
assume every core is theirs, so together they oversubscribe it. A command run
under a lease takes its slots from one shared budget, waits its turn when the
budget is taken, and runs at the width it was granted.

## The two bridges

| Command | For | What the command gets |
|---|---|---|
| `runquota run -- CMD` | tools that take a width as a flag: `nim c` (`--parallelBuild`), `nix build` (`--max-jobs 1 --cores`), `cargo nextest` (`-j`), Playwright (`--workers`), `go`, `pnpm`/`yarn` workspaces | the grant, written into the command line by an adapter, and `RUNQUOTA_RUN_WIDTH` in its environment |
| `runquota jobserver -- CMD` | tools that follow a GNU make jobserver: `cargo` and the `rustc` it starts, `make`, `ninja` | a jobserver whose tokens are the lease's slots, so at most N jobs run for an N-slot grant |

`runquota run --adapter list` prints the adapters. A command no adapter
recognises still runs under the lease, with `RUNQUOTA_RUN_WIDTH` set for a
script to use. Add `--width N` for a fixed width or `--width MIN:PREF` for a
range (the default is `1:` up to the machine's CPU count, at most 8).

Both are transparent to the shell around them: the command's output is not
captured or reprinted, so `x=$(runquota run -- nix build ... --print-out-paths)`
still captures only what the command printed, and the exit status is the
command's.

## The idiom: one variable per repository

Define the prefix once, and put it in front of the heavy command in each recipe:

```just
# `{{rq}}` takes a lease before the command and passes it the grant. Empty
# where RunQuota is not available, so the recipe runs the command as before.
#
#   RQ unset   `runquota run --` when a `runquota` that has the `run` verb
#              is on PATH, otherwise empty
#   RQ=        an empty value turns the bridge off
#   RQ="runquota run --width 4 --"   any other value is the prefix
rq := env_var_or_default("RQ", if `command -v runquota >/dev/null 2>&1 && runquota run --adapter list 2>/dev/null | grep -q '^adapters' && echo yes || true` == "yes" { "runquota run --" } else { "" })

test:
    {{rq}} nim c -r tests/tsuite.nim
```

A repository with several Justfiles keeps the definition in one file and
imports it (`import 'runquota.just'`, or `import '../runquota.just'` from a
subdirectory), so there is still one variable per repository.

### Decisions the idiom makes

- **The fallback is an empty prefix, so no recipe needs one.** Where RunQuota is
  not installed, `{{rq}} cmd` is ` cmd`. Where it is installed but no daemon
  answers, `runquota run` runs the command unchanged, as it does for any
  command.
- **Probe for the verb, not for the binary.** A `runquota` that predates `run`
  (or `jobserver`) does not reject the word: it prints its usage and exits 0,
  so a bridged recipe would pass without running anything. The probe above asks
  for the adapter table, which only a build that has the verb prints. For
  `jobserver`, run it with no command and look for `runquota jobserver: missing
  command`; it takes no lease.
- **An escape hatch for the person running it.** `RQ=` runs one recipe
  unbridged; `RQ="runquota run --width 2 --"` pins a width.
- **Put the prefix after any `VAR=value` words and in front of the program.**
  `VAR=1 {{rq}} cargo build`, never `{{rq}} VAR=1 cargo build`: the prefix runs
  the next word as a program.
- **Prefix the command that does the work, not the recipe's shell.** A lease is
  held for the command's whole life, so wrapping a long script that spends most
  of its time elsewhere reserves slots it does not use. Wrap each compile, test
  run or `nix build`.
- **Nest `jobserver` inside `run`, not the other way round.** A `jobserver`
  started inside another `jobserver` joins it and takes no lease of its own. A
  `jobserver` started inside a `run` takes a sub-lease of the outer lease, so it
  cannot wait on the host behind its own parent. A `run` started inside a
  `jobserver` bridge asks the host's budget itself, and with the budget spent it
  queues behind the command that started it: give a command chain one bridge at
  the top.

### When the Justfile's shell is expensive

`just` evaluates every variable before it runs any recipe, and a backtick runs
under the Justfile's `shell` setting. A Justfile whose shell enters a dev
environment pays that on every invocation, even `just --list`. Put the probe in
a small script instead and make the variable a plain string:

```just
rq := '"' + justfile_directory() + '/scripts/runquota-bridge.sh" run --'
rqj := '"' + justfile_directory() + '/scripts/runquota-bridge.sh" jobserver --'
```

The script takes the verb and the flags, runs the same probe, and `exec`s either
`runquota VERB FLAGS -- CMD` or `CMD`.

## Memory

A lease reserves memory as well as CPU, and a bridge that wraps a memory-heavy
command should say how much: `runquota jobserver --mem 8GiB -- cargo build`
(the default is 512 MiB per slot, raised by what earlier runs of the same stats
key measured). A reservation is what the daemon admits other leases against. It
does not stop a process that exceeds it; if a command needs a hard ceiling, keep
a cgroup or `ulimit` for that, as a separate decision.

## Check that it holds

A recipe that lost its prefix still passes, so the only thing that notices is a
test of the bound itself. The shape that works:

1. start a private `runquotad` on a socket in a scratch directory with a small
   budget (`runquotad --socket PATH --cpu-milli 2000 ...`), and give the recipe's
   environment `RUNQUOTA_SOCKET=PATH RUNQUOTA_ENDPOINT_SCOPE=private`;
2. run the real recipe, several at once if the claim is about sharing;
3. sample `/proc` every few milliseconds for the processes that matter and take
   the peak, rather than reading anyone's log;
4. assert the peak is within the budget, and that it is more than one, so the
   bound is not met by running nothing;
5. delete the prefix from the recipe and see the test fail.

Two things to know when you write it: a Unix socket path is limited to about
100 bytes, so create the scratch directory under a short parent; and a stand-in
tool that holds a slot for a fraction of a second is a fair substitute for a
compiler when the thing under test is which commands reach the bridge, provided
it does not fork (a forked child is a second process in the sampler).
