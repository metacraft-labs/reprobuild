---
title: How reprobuild works
description: The path from a project file to a reused build result, one stage at a time, with a link to the page that explains each stage in depth.
kind: explanation
persona: evaluator
order: 1
verifies:
  commands: [build, graph, why, shell, exec, run, up, develop, workspace]
  tests:
    - tests/integration/t_monitored_zero_output_edge_input_completeness.nim
unverified:
  - claim: "Paths below a provisioned tool's root are left out of an action's observed inputs because the tool's identity already covers them."
    reason: "Stated in docs/dependency-collection.md; no test is cited yet."
    owner: unassigned
draft: true
---

# How reprobuild works

This page follows a project from its project file to a build result that
reprobuild reuses, and then to the environment, tasks and workspace built on the
same description. Each stage links to the page that covers it in depth.

## 1. A project file describes the project

A project is described by its project file, `repro.nim`. It names the project's
packages, the tools each package uses and the dependencies between packages. It
is Nim code, so a misspelt option or a wrong type is a compile error in the
project file rather than a surprise during the build.

A project file can be short because most of what a build needs is implied by the
language's standard layout. Depending on how much a project already says about
itself, reprobuild reads it in one of three modes: from its directory layout
alone, through its ecosystem's own manifest (`Cargo.toml`, `CMakeLists.txt`,
`package.json`), or from a short project file.
[Conventions and the three modes](conventions-and-modes.md) explains the choice.

## 2. Conventions turn packages into actions

reprobuild derives the build graph from the packages: one action per compiler
invocation, archive, link or generated file, with an edge wherever one action
uses another's output. `repro graph` prints the graph, and
`repro show-conventions` prints what a convention inferred.

## 3. Tools come from one declared place

Each package says which tools it uses, with a version range such as
`"nim >=2.2 <3.0"`. Tool provisioning decides where they come from: your `PATH`,
Nix, a release tarball, Scoop, or a build from source. The lock file,
`repro.lock`, records what was resolved, so the next build on another machine
asks for the same thing.

## 4. Each action runs under a monitor

When an action runs, reprobuild records what its processes read, wrote, looked
for and listed. This record, the action's dependency evidence, catches the inputs
nobody declared: a header found on an include path, a configuration file read
from the home directory, a file that appeared in a directory the action listed.

## 5. A fingerprint decides whether to run an action again

An action's fingerprint covers its command, the tools it ran and the contents of
everything its evidence shows it depended on. Before running an action, reprobuild
compares its fingerprint with the recorded one; when they match, it reuses the
recorded outputs. When an action's evidence is incomplete, reprobuild records no
result for it, so it runs again next time instead of being reused on a guess.
[How caching stays correct](how-caching-stays-correct.md) explains the rules and
their limits.

## 6. The same file describes how you work on the project

The project file also declares the project's development environment (the tools
and variables you work with), its named tasks and its services, such as a
database. `repro shell` and `repro exec` enter the environment, `repro run` runs a
task and `repro up` starts the services. Because they come from the same file as
the build, the tools in your shell are the tools the build uses.
[Enter a project's environment](../how-to/environments/enter-a-project-environment.md)
shows how.

## 7. Workspaces put repositories side by side

A workspace holds several repositories next to each other, with a workspace root
that declares which belong together. Develop mode builds a dependency from its
checkout in the workspace instead of from its locked revision, so a change in a
library reaches the program that uses it at the next build, without publishing
the library first. Each repository commits its own lock file, which records the
revisions it was built against.
[Work on a dependency's source](../how-to/workspaces/develop-a-dependency.md)
shows the workflow.

## Related

- [Glossary](../reference/glossary.md)
- [Coming from another tool](../coming-from/index.md)
