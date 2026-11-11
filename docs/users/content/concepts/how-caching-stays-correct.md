---
title: How caching stays correct
description: What reprobuild checks before it reuses an action's result, why an input nobody declared still counts, and what happens when that check cannot be made.
kind: explanation
persona: build-maintainer
domain: build
order: 20
verifies:
  commands: [build, why, graph]
  tests:
    - tests/integration/t_monitored_zero_output_edge_input_completeness.nim
    - libs/repro_build_engine/tests/t_builtin_kinds_with_undeclared_reads_do_not_publish.nim
unverified:
  - claim: "The fingerprint covers the command and its environment, each tool's identity, and the contents and lookup outcomes in the action's evidence."
    reason: "Summarised from the caching design; no test is cited for the composition as a whole."
    owner: unassigned
  - claim: "Dry-run and report reasons include input changed, cache-miss, missing-output and not-cacheable."
    reason: "Taken from docs/build-introspection.md; the reason vocabulary belongs in a generated reference."
    owner: unassigned
  - claim: "An action whose evidence is incomplete publishes no cache entry and runs again on the next build."
    reason: "Stated in docs/dependency-collection.md for IPC peers; a test named for the general rule is needed."
    owner: unassigned
  - claim: "--evidence=reads-only misses an added file that shadows one later in a search path, and a file that becomes readable; a build needing full evidence refuses such a record for the whole session."
    reason: "Stated in the repro build usage text and docs/dependency-collection.md; no test is cited yet."
    owner: unassigned
---

# How caching stays correct

This page explains what reprobuild checks before it reuses an action's result,
and why that check does not depend on your build description being complete.

## The problem with declared inputs

A build tool that reuses results has to know when a result is stale. Most tools
answer with the inputs the build description declares, or with what the compiler
reports in a dependency file. Both miss things. A compiler finds headers through
search paths nobody listed. A code generator reads a configuration file from the
home directory. A test runner lists a directory and runs whatever it finds. When
an undeclared input changes, the tool reuses a stale result, and the remedy
people learn is to delete everything and build from scratch.

## What reprobuild records instead

reprobuild runs each action under a monitor that records what its processes did
to the file system:

- the files they read;
- the files they wrote;
- the paths they looked for, including those that did not exist;
- the directories they listed.

That record is the action's [dependency evidence](../reference/glossary.md#dependency-evidence).
The declared inputs still matter, because they let reprobuild order the actions
and start them early, but they are not the list reprobuild trusts when it decides
whether a result is still valid. The evidence is.

The failed lookups matter as much as the successful ones. If a compiler looked
for `config.h` in `include/` and did not find it, then later found it in
`/usr/include`, a new `include/config.h` changes the result even though no file
the compiler read has changed. Because the failed lookup is recorded, its
appearance makes the action run again.

## The fingerprint

Before running an action, reprobuild computes its
[fingerprint](../reference/glossary.md#fingerprint) from:

- the command and its environment;
- the identity of each tool it runs;
- the contents of every file in its evidence, and the outcome of every lookup and directory listing.

If the fingerprint matches the one recorded the last time the action ran,
reprobuild reuses the recorded outputs and does not run the action. Otherwise it
runs the action, records new evidence and stores the new result.

The files that belong to a tool itself, such as a compiler's own headers and
libraries, are covered by the tool's identity rather than file by file.

## When the evidence is incomplete

Sometimes the monitor cannot see everything an action depended on. The commonest
case is an action that talks to a process outside its own process tree, such as a
daemon, whose reads the monitor does not see.

reprobuild does not guess in that case. It records no reusable result for the
action, so the action runs again on the next build. A result that is never
reused costs time; a result that is reused wrongly costs a wrong build, which is
far more expensive to find. reprobuild chooses the first.

## Recording less, on purpose

`repro build --evidence=reads-only` records only the lookups that succeeded. It
exists so that a build can be compared like for like with tools that rely on
dependency files, and its results are correct when they are built. What it
weakens is the staleness check: a file added where an earlier lookup found
nothing, or a file that becomes readable, no longer makes the action run again.

A build that needs full evidence does not reuse a record made with
`--evidence=reads-only`. The record cannot say which lookups it left out, so the
refusal applies for the rest of that build: the build stays correct and stops
being incremental. The default is `--evidence=full`.

## Seeing why an action ran

Each action that runs, or would run, carries a reason, such as
`input changed: <path>`, `cache-miss`, `missing-output` or `not-cacheable`:

- `repro build --dry-run --log=actions` lists the actions a build would run and the reason for each, without running them.
- `repro build --write-report` writes the same reasons for a real build into a JSON report.
- `repro graph --view=inputs --focus=<action>` shows an action's inputs; `--view=dependents` and `--view=blast-radius` show what a change to it reaches.
- `repro why <package-or-action>` explains why a package or action is part of the build at all.

## What this does not cover

- Inputs outside the file system. Network responses, the clock and random numbers are not files. An action that depends on them needs to be made deterministic, or declared not cacheable.
- Tools that bypass the monitor. An action whose tools the monitor cannot observe on your platform has incomplete evidence, and so is not reused.
- Other machines. This page describes reuse on one machine. Sharing results between machines adds rules about who produced a result and who may trust it.

## Related

- [How reprobuild works](how-reprobuild-works.md)
- [Coming from Bazel and Buck2](../coming-from/bazel-and-buck2.md)
- [Glossary](../reference/glossary.md)
