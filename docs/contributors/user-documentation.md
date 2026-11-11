# Writing the user documentation

This guide explains how the pages under [`docs/users/`](../users/index.md) are
organised, what each kind of page may contain, and how a page proves what it
says. Read it before you add or change a user page.

The rules here follow Metacraft Labs' documentation policy for every product
it publishes. Where that policy leaves a choice to the project (who the
readers are, which words mean what), this guide records reprobuild's choice.

> **Status:** draft. The layout, the front-matter schema and the first pages
> exist on this branch. The checks described in
> [What checks a page](#what-checks-a-page) are not built yet; until they are,
> a reviewer applies them by hand, and every page stays `draft: true`.

## Where pages live

```text
docs/users/
├── index.md              # the documentation home
├── install.md            # every installation channel
├── tutorials/            # one guided path each
├── how-to/<domain>/      # one goal per page
├── concepts/             # explanation
├── coming-from/          # one page per family of tools reprobuild replaces
├── reference/            # generated wherever a source of truth exists
├── scenarios/            # the scripts that run each tutorial
├── data/                 # the sources generated pages are built from
└── _meta/front-matter.toml
```

The site is built with [isonim-docs](https://github.com/metacraft-labs/isonim-docs).
It takes a page's section from its directory and its URL slug from its file
name, so a page does not repeat either in its front matter.

These pages are for people who use reprobuild. How to build, test and change
reprobuild itself belongs in `docs/contributors/`.

## The four kinds of page

Every page is exactly one kind, declared as `kind:` in its front matter.

| Kind | Answers | Shape | Rules |
|---|---|---|---|
| `tutorial` | "Teach me by doing" | One path, start to finish | Every step runs, in order, from a clean machine, and a scenario proves it. No alternatives and no "you could also". |
| `how-to` | "How do I do X?" | Steps to one outcome | The title names the goal. Assumes competence. May branch with tabs; does not teach. |
| `reference` | "What exactly is Y?" | Complete, structured | Generated from the source of truth wherever one exists. No narrative and no worked examples. |
| `explanation` | "Why is it like this?" | Discussion | Reasons and trade-offs. Any fact on the page (a flag, a default, a behaviour) links to reference or names its source. |

A page that is several kinds at once serves none of its readers, and nothing
can check it, because it does not make one claim. Split it.

Templates per kind:

- **Tutorial.** A sentence saying what the reader will have built. "What you
  need". Numbered steps, each ending in a result the reader can see. "What you
  learned", with no new facts. "Next".
- **How-to.** A sentence naming the goal. "Before you start", linking the
  preconditions. Numbered steps. "Check that it worked". "Related".
- **Explanation.** A sentence saying what the page explains. Sections of
  prose, no step lists. "Related".
- **Reference.** An introductory sentence and a generated region.
- **Coming from a tool** (`coming-from/`, kind `explanation`). What transfers;
  a concept map; what works differently and why; what reprobuild does not do;
  **when the other tool is the better choice** (always present); the how-tos
  for moving over. Command equivalents are not repeated on these pages: they
  link [`reference/command-equivalents.md`](../users/reference/command-equivalents.md),
  which is generated and checked against the CLI.

## Readers

Every page declares exactly one `persona:`. Write for that reader: assume what
they know, explain what they do not.

| `persona` | Who | Assume they know | Explain |
|---|---|---|---|
| `evaluator` | Deciding whether to try reprobuild; usually fluent in a tool it replaces | That tool, git, a shell | What reprobuild is, what it does today, what it costs to try, where it differs |
| `developer` | Works in a codebase that already uses reprobuild | git, a shell, their language's toolchain | Nim, the project file, the build graph |
| `build-maintainer` | Owns a project's build and CI; writes `repro.nim` | Make, CMake, Ninja, Bazel or Cargo; CI; caching | The Nim the project file uses; dependency evidence; how caching stays correct |
| `workspace-maintainer` | Maintains a multi-repository workspace | git in depth; `repo`, submodules or monorepo tooling | Manifest files, branch roles, lock tiers, the pre-push check |
| `machine-owner` | Configures their own machines with reprobuild | Home Manager or NixOS, a dotfiles manager | Home and system profiles, activities, generations |

AI coding agents read the same material through `llms.txt`, `llms-full.txt`
and `repro --help`, which are generated from the same sources as the pages.
They are not a separate persona.

## Front matter

[`_meta/front-matter.toml`](../users/_meta/front-matter.toml) is the schema: it
lists every key and every allowed value. A page looks like this:

```yaml
---
title: Keep an existing Nix flake as the environment
description: Activate a repository's existing flake dev shell through reprobuild without changing the flake.
kind: how-to
persona: build-maintainer
domain: environments
order: 30
platforms: [linux, macos]
verifies:
  commands: [allow, shell hook, flake override-args]
  tests:
    - tests/integration/t_own_flake_ref_survives_an_uninitialised_submodule.nim
unverified:
  - claim: "Direnv is not required."
    reason: "No test activates the flake with direnv absent from PATH."
    owner: unassigned
draft: true
---
```

- `kind`, `persona`, `domain` and `platforms` take only the values in the
  schema.
- `verifies` names what keeps the page true: the `scenario` that runs a
  tutorial, the `commands` the page shows, the `tests` behind its behavioural
  claims, the `benchmarks` behind its numbers.
- `unverified` lists each claim that nothing checks yet, with the reason and
  an owner. It is a debt register, not a loophole: the count is published, and
  a page whose owner is `unassigned` is not ready to publish.
- `draft: true` keeps a page out of the published site.

## Admonitions

isonim-docs renders six admonitions. Each has one meaning here, and no other
use is allowed:

| Admonition | Means |
|---|---|
| `:::note` | Background that the next step depends on |
| `:::tip` | An optional shortcut |
| `:::important` | A precondition: if it is not met, the step fails |
| `:::warning` | The step can discard work or data |
| `:::caution` | Experimental: the feature exists and can change incompatibly |
| `:::danger` | Security: trust, credentials or exposure |

## Proving what a page says

A page may not assert anything that nothing can check. The question to ask of
a sentence is not "is this true?" but "what keeps this true?".

| The page shows | What keeps it true |
|---|---|
| Command output | A capture from the page's scenario, never a transcription |
| A version number | Interpolated at build time, never typed |
| A code sample | Compiled in CI from the fence (`nim runnable`) or the file the page includes |
| A file or path | The scenario asserts it exists, or a step on the page creates it |
| A command, flag or default | The generated CLI reference |
| A behaviour | A passing test named in `verifies.tests` |
| A number | A benchmark result, with its conditions |
| A screenshot or recording | A named scenario, captured deterministically |

**Generated regions** sit between two markers, and the check fails if anyone
edits inside them:

```markdown
<!-- generated:begin cli-reference build -->
…
<!-- generated:end -->
```

**Tutorial scenarios** live in `docs/users/scenarios/<tutorial>.toml`. Each step
lists the command, the directory it runs in and what must hold afterwards. A
tutorial whose scenario fails is a failing test, not a stale page.

## Language and style

- Address the reader as "you". Use "we" only in explanation, and only for the
  people who make reprobuild.
- Write steps in the imperative ("Run", not "You can run"). Describe behaviour
  in the present tense ("`repro build` writes", not "will write").
- Use the active voice and name the actor.
- Open every page with one sentence saying what the reader will be able to do,
  or what the page describes.
- One idea per paragraph. Number the steps when order matters; use bullets only
  when it does not.
- Give every code block a language.
- Split a sentence that runs past about 30 words.
- Write British English (behaviour, organise, licence as a noun). Code,
  commands, flags, file names and environment variables keep their exact
  spelling: `--color`, `repro allow`.
- Use the words in the [glossary](../users/reference/glossary.md), and never
  their "Do not use" synonyms. Where the CLI's own label differs from the
  natural word, the CLI's label wins.
- Do not use: "simply", "just", "easy", "obvious", "of course", "note that",
  "it is worth mentioning", "powerful", "seamless", "blazing", "robust",
  "please", "etc." and "and so on", "should" for what reprobuild does,
  exclamation marks, or the future tense for reprobuild's behaviour. Avoid
  filler such as "leverage", "utilise", "empower", "unlock", "cutting-edge",
  "revolutionary", "delve", "landscape".
- Avoid the shapes of generated filler: "It's not just X, it's Y"; three
  adjectives in a row; "serves as" or "boasts" for "is" or "has"; a trailing
  "…, ensuring seamless …" clause; an opening "In today's world of …".
- Name no internal plan, milestone or design document. A user page explains
  the concept itself.

## What checks a page

| Check | What it rejects | Built? |
|---|---|---|
| Front-matter validator | An unknown key, a missing required key, a value outside the schema | No |
| Provenance gate | A `verifies` entry that does not resolve; a `repro` command shown on the page but missing from `verifies.commands` | No |
| Generated-region check | A hand edit inside a generated region | No |
| Style checker | The words and patterns in [Language and style](#language-and-style), glossary synonyms, American spellings outside code | No |
| Scenario runner | A tutorial step that fails or whose result differs | No |
| Link check | A link or anchor that does not resolve | Partly: the repository's markdown link check |

The CLI reference, the command-equivalents table and the `commands` check all
depend on a machine-readable description of the CLI, which `repro` does not
emit yet.

## Reviewing a page

- The page has exactly one `kind` and one `persona`, and its content matches
  both.
- It opens with one sentence saying what the reader will be able to do.
- Every claim maps to a row of [Proving what a page says](#proving-what-a-page-says),
  or is listed under `unverified`.
- No version, path, flag, default or output is typed into prose.
- The voice, tense, terms and spelling follow [Language and style](#language-and-style).
- Nothing on the page explains reprobuild's internals unless its kind and
  persona both call for it, and nothing addresses the people who make it.
- You read the page rendered, in both themes and at phone width, and every
  link resolves.
