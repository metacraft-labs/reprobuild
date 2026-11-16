---
title: Reference
description: Where to look up a command, a file format, an environment variable, a language convention or a term.
kind: reference
persona: developer
order: 0
---

# Reference

This section holds the facts you look up: every command and option, every file
reprobuild reads or writes, and the words the documentation uses. Each page is
generated from the source reprobuild itself uses, wherever such a source exists.

| Page | Lists | Generated from |
|---|---|---|
| [Commands](commands/index.md) | Every `repro` command, its options, defaults, exit status and what it changes | The CLI's own description of itself |
| [Project file and profile syntax](dsl.md) | The syntax of `repro.nim`, `home.nim` and `system.nim`: imports, packages, dependencies, artifacts, build actions, configuration, tasks, services, typed tool interfaces, activities, hosts, resources and resource types | The language itself: a test compiles every example on the page |
| Files | `repro.lock`, the workspace manifests, `home.nim` and the `.repro/` directory | The schemas the parsers accept |
| Environment variables | Every variable `repro` reads, with its default | The CLI's description of itself |
| Reports | The JSON reports commands write with `--json` and `--write-report` | The report schemas |
| Errors | Each error message, what causes it and what fixes it | The messages `repro` prints |
| Languages | What each language convention recognises, and which modes it supports | `repro show-conventions --json` |
| Platforms | What works on Linux, macOS and Windows | The test inventory |
| [Command equivalents](command-equivalents.md) | The closest `repro` command to each command of the tools it replaces | [`data/command-equivalents.toml`](https://github.com/metacraft-labs/reprobuild/blob/agents/docs/users/data/command-equivalents.toml), checked against the CLI |
| [Glossary](glossary.md) | The one name used for each concept | Itself |

The pages without links are not written yet: each waits for its source to
exist in a form a generator can read.
