---
title: Coming from Bazel and Buck2
description: How BUILD files, targets, rules, actions and caches map onto reprobuild, what works differently, and when Bazel or Buck2 is the better choice.
kind: explanation
persona: build-maintainer
order: 20
verifies:
  commands: [build, test, run, graph, cache]
  tests:
    - tests/integration/t_monitored_zero_output_edge_input_completeness.nim
unverified:
  - claim: "reprobuild reads no BUILD, BUCK or Starlark files."
    reason: "No reader for them exists in libs/ at the commit this draft was written against; a check against the CLI model and the convention list is needed."
    owner: unassigned
---

# Coming from Bazel and Buck2

This page maps what you know from Bazel and Buck2 onto reprobuild, explains
where they differ, and says when Bazel or Buck2 remains the better tool.

## What carries over

- A build is a graph of actions, and an action whose inputs have not changed is not run again.
- Targets have names, and you build, test or run one by naming it.
- Correct reuse depends on knowing every input, and the tool, not the person writing the build, is responsible for that.

## Concept map

| Bazel or Buck2 | reprobuild |
|---|---|
| `BUILD` / `BUCK` files in Starlark | one [project file](../reference/glossary.md#project-file), `repro.nim`, in Nim |
| target label | [target](../reference/glossary.md#target) |
| rule (`rust_binary`, `cc_library`) | [convention](../reference/glossary.md#convention), or a typed tool call in a `build:` block |
| action | [action](../reference/glossary.md#action) |
| action cache, disk cache | [action cache](../reference/glossary.md#action-cache) |
| remote cache | binary cache (`repro cache`) |
| sandboxing | [dependency evidence](../reference/glossary.md#dependency-evidence) |
| `MODULE.bazel` and its lock file | `uses:` ranges and [`repro.lock`](../reference/glossary.md#lock-file) |
| `bazel query`, `aquery` | `repro graph` |
| `bazel build`, `test`, `run` | `repro build`, `repro test`, `repro run` |

## What works differently

No build file per directory. A project that follows its ecosystem's layout
needs no rule per target. reprobuild reads the layout, or the project's
`Cargo.toml`, `go.mod` or `CMakeLists.txt`, through
[conventions](../concepts/conventions-and-modes.md). Moving a project to
reprobuild does not start with rewriting its build in a new language.

Inputs are discovered as well as declared. Bazel and Buck2 require every
input to be declared, and a sandbox hides the rest, so an undeclared input is a
build error. reprobuild records what each action read, looked for and listed,
including what nobody declared, and makes it part of the action's fingerprint.
[How caching stays correct](../concepts/how-caching-stays-correct.md) explains
the rules, and what happens when the record is incomplete.

The build description is typed and compiled. `repro.nim` is Nim, so a
misspelt attribute or a wrong type is a compile error in the project file.
Starlark is interpreted, and such mistakes surface when the file is evaluated.

One file describes more than the build. The project file also declares the
development environment, named tasks and local services. There is no separate
tool for a developer shell or a task runner.

## What reprobuild does not do

- It does not read `BUILD`, `BUCK` or Starlark files.
- It has no query language. `repro graph` prints fixed views of the graph, such as an action's inputs, its dependents or what a change reaches.
- It does not provide a coverage command.

## When Bazel or Buck2 remains the better choice

- Your repository is already fully described in Bazel or Buck2, with remote execution that you rely on at scale.
- You depend on their rule ecosystems, such as rules for Java, Android or iOS that reprobuild's conventions do not cover.
- You need queries over the configured graph (`cquery`, `aquery`) to drive other tools.
- Your policy requires undeclared reads to be impossible, enforced by isolation, rather than recorded.

## Next steps

- [Build an existing project](../guides/building/build-an-existing-project.md)
- [Conventions and the three modes](../concepts/conventions-and-modes.md)
- [Command equivalents](../reference/command-equivalents.md#bazel-and-buck2)
