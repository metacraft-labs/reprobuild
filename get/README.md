# `get/` — source for https://get.reprobuild.com

This directory is the source tree for Reprobuild's install/onboarding host,
`get.reprobuild.com`. The naming and layout follow Metacraft Labs' internal
`product-install-domains.md` policy: each product serves its install surfaces
from `get.<product>.<tld>`, with `/sh` and `/pwsh` as the two canonical
one-liner endpoints.

It exposes four surfaces:

| URL | Served file | Purpose |
| --- | --- | --- |
| `https://get.reprobuild.com/` | `index.html` | Onboarding / install landing page |
| `https://get.reprobuild.com/sh` | `scripts/install/repro-install.sh` (re-served) | `curl -fsSL https://get.reprobuild.com/sh \| sh` |
| `https://get.reprobuild.com/repo-sh` | `scripts/install/repro-install.sh` (alias of `/sh`) | `curl -fsSL https://get.reprobuild.com/repo-sh \| sh` |
| `https://get.reprobuild.com/pwsh` | `scripts/install/repro-install.ps1` | `irm https://get.reprobuild.com/pwsh \| iex` |

## How it is built and served

`build-get.sh` assembles `dist/`:

- `index.html`, `_headers` — copied verbatim.
- `sh` and `repo-sh` — `scripts/install/repro-install.sh`, the native-repository
  installer, with a provenance header injected after the shebang
  (single-sourced, never a divergent copy). `REPRO_GET_SH_SOURCE=legacy` serves
  `install-on-distributions.sh` at `/sh` instead, as a rollback.
- `pwsh` — a top-level `install.ps1` if one exists, otherwise
  `scripts/install/repro-install.ps1`; `pwsh.stub.ps1` (a "coming soon" stub)
  only if neither does.

`_headers` forces `Content-Type: text/plain; charset=utf-8` + a short cache TTL on
`/sh` and `/pwsh`, so `curl … | less` shows the source and a fixed URL always
yields the current bootstrapper.

The artifact **store** remains GitHub Releases / `downloads.reprobuild.com`;
`get.reprobuild.com` is only the advertised UX.

## Deploy

`.github/workflows/deploy-get.yml` runs `build-get.sh` and
`wrangler pages deploy get/dist --project-name=get-reprobuild --branch=master`
on push to `dev` when `get/**`, either installer under `scripts/install/`,
`install-on-distributions.sh`, `install.ps1`, the flake or the workflow
itself changes.
The `get-reprobuild` Pages project's production branch is `master`, so the
`--branch master` deploy publishes production (served on the custom domain).

Requires repo secrets `CLOUDFLARE_API_TOKEN` (Pages:Edit) and
`CLOUDFLARE_ACCOUNT_ID` (`803741d99690718276ea30950f690c46`).

Build locally: `bash get/build-get.sh && ls get/dist`.
