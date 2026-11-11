# Reprobuild user documentation — working on the site

This directory is reprobuild's **user documentation site**. It is a consumer of
the [isonim-docs](https://github.com/metacraft-labs/isonim-docs) static-site
framework, laid out like `isonim/docs/users` and `codetracer/docs/book-isonim`,
and themed by the shared Metacraft docs theme.

How to write a page — the kinds, the readers, the front matter, the style, and
the Markdown the framework renders — is in
[`docs/contributors/user-documentation.md`](../contributors/user-documentation.md).

## Where things live

| Path | What |
|---|---|
| `content/` | The pages. A directory is a sidebar section; `index.md` is the section's own page |
| `src/docs_config.nim` | Site configuration: title, header and sidebar links, section order, footer |
| `src/build.nim` | The static build: fills `{{ name }}` placeholders, then runs the framework's SSG into `public/` |
| `src/check_links.nim` | The reference gate: an internal link to no page, an anchor to no heading, two pages on one route |
| `src/main.nim` | The client bundle every page loads (search, theme toggle, sidebar collapse) |
| `src/dev.nim`, `src/ssr.nim` | The live-reloading server and a one-shot server-side render |
| `src/config.nims` | The compiler paths to the framework's checkouts |
| `static/` | Fonts and images, copied into `public/assets/` |
| `scenarios/` | Tutorial scenarios, and the values the pages interpolate |
| `data/` | Sources of generated pages (`command-equivalents.toml`) |
| `_meta/front-matter.toml` | The front-matter schema |

## Prerequisites

The framework and its dependencies are separate repositories checked out next
to this one: `isonim-docs`, `isonim`, `nim-everywhere`, `nim-faststreams`,
`nim-stew` and `codetracer-design-system`. Fetch them, at the revisions the
framework's own `repro.lock` names, with:

```bash
bash scripts/build_user_docs.sh fetch
```

They go into the parent directory of this checkout, or into
`REPRO_DOCS_SIBLING_ROOT` when that is set. You also need a Nim 2.2 compiler and
Python 3: isonim's development shell provides both.

```bash
nix develop path:../isonim
```

## Build, check, preview

From the repository root:

```bash
bash scripts/build_user_docs.sh build
```

That runs the reference gate, the command-equivalents check and the static
build, in that order, and writes the site to `docs/users/public/`. From this
directory the same steps are `just check` and `just build`; `just dev-docs`
serves the site at <http://127.0.0.1:8000> and reloads every open tab when a page
changes.

Every compile passes `--skipParentCfg`, so the reprobuild engine's own
`config.nims` at the repository root does not apply to the site. The client
bundle is compiled by the framework without that flag; the engine
configuration's warnings about sibling paths in that step are expected and do
not affect the bundle.

## Publishing

`.github/workflows/deploy-docs.yml` builds and publishes the site on every push
to the `live-docs` branch. Land a change on `agents` first, then fast-forward
the publication branch:

```bash
git push origin agents:live-docs
```

The workflow publishes to the `reprobuild-docs` Cloudflare Pages project
(`scripts/deploy_user_docs.sh`).

## The preview footer

The site is published as a preview while its pages still carry claims no check
verifies. Each such claim is listed in its page's `unverified:` front matter,
and the footer of every page states how many there are, counted from the
content at build time.
