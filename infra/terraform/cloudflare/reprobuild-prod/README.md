# `cloudflare/reprobuild-prod` — the reprobuild.com zone, R2 buckets and custom domains

This is the hosting half of **M3 HOSTING+REPOS+INSTALLER**: the Cloudflare
zone for `reprobuild.com`, one R2 bucket per published surface, and the R2
custom domains that bind each bucket to its hostname.

## NO `terraform plan` HAS BEEN RUN AGAINST REAL CREDENTIALS

Stated plainly, because it is the single most important caveat here.

* **`terraform validate` — RUN, passes.** Against the real, downloaded
  `cloudflare/cloudflare v5.25.0` provider with `terraform 1.9.8`:
  `Success! The configuration is valid.` `terraform fmt -check` reports no
  diff. Neither needs credentials, so both are real results.
* **`terraform plan` — NOT RUN.** It requires a Cloudflare API token, and
  it would also fail on its own terms today: `reprobuild.com`'s DNS
  delegation was still in flight when this was written, so the zone cannot
  be created or imported yet.
* **`terraform apply` — NOT RUN, and must not be until the delegation
  lands and a reviewer has read a plan.**

So what `validate` buys is narrow but real: every resource type and every
attribute in this configuration exists in the pinned provider, and the
expressions type-check. What it does not and cannot tell you is whether
the plan is *clean* — whether these resources already exist, whether the
account id is right, or whether `get-reprobuild` is the Pages project's
real name. Those need a plan.

`validate` already earned its keep once: this root was first written
against `~> 4.52` to match `codetracer-prod`, and validate rejected it
because **`cloudflare_r2_custom_domain` does not exist in the Cloudflare
provider v4**. See `versions.tf`.

## What this root manages

| Resource | Purpose |
| --- | --- |
| `cloudflare_zone.reprobuild_com` | the zone |
| `cloudflare_r2_bucket.deb` | apt repository (`pool/`, `dists/`) |
| `cloudflare_r2_bucket.rpm` | dnf repository (`*.rpm`, `repodata/`) |
| `cloudflare_r2_bucket.arch` | pacman repository (packages + signed `.db`) |
| `cloudflare_r2_bucket.downloads` | release archives, `SHA256SUMS{,.asc}`, per-artifact `.asc` |
| `cloudflare_r2_bucket.keys` | the trust anchor, and nothing else |
| `cloudflare_r2_custom_domain.*` | `deb.` `rpm.` `arch.` `downloads.` `keys.` → their buckets |
| `cloudflare_pages_domain.get` | `get.reprobuild.com` → the existing `get-reprobuild` Pages project |
| `cloudflare_pages_domain.install` | `install.reprobuild.com` → the same project (see below) |

The bucket names and hostnames are emitted as outputs, because they are
exactly the values the release pipeline and the installer need:
`repro-publish-repos.sh --target r2:<bucket>` and the installer's
`REPRO_*_URL` defaults.

## Two things the milestone asked for that are NOT here, and why

**A Scoop bucket and a Homebrew tap are git repositories, not object
stores.** `scoop bucket add` and `brew tap` *clone* a repo; R2 serves
objects and cannot serve git. They belong in
`metacraft-labs/scoop-reprobuild` and
`metacraft-labs/homebrew-reprobuild` (neither exists yet). This is why
the installer takes its bucket URL as a plain variable rather than
assuming a hostname in this zone. The gap is also emitted as the
`git_backed_surfaces` output so it shows up in `terraform output` and not
only in a comment.

**`install.` vs `get.`** — the milestone names `install.reprobuild.com`.
The repository already has `get.reprobuild.com`, chosen to follow the
internal `product-install-domains.md` policy (`get.<product>.<tld>`, with
`/sh` and `/pwsh` as the canonical endpoints), already built by
`get/build-get.sh` and already deployed by
`.github/workflows/deploy-get.yml`. Both names can point at the same Pages
project, so this root attaches both and `var.manage_install_hostname`
controls the second. **Somebody still has to decide which is canonical**;
this configuration does not decide it, it just stops the milestone's name
from being unreachable.

## `metacraft-prod` does not exist

The milestone says the Terraform PR goes to `cloudflare/metacraft-prod`.
There is no such root anywhere in the workspace. The only real Cloudflare
Terraform root is `infra/terraform/cloudflare/codetracer-prod`, and that
is what this mirrors: same directory shape (`main.tf`, `variables.tf`,
`outputs.tf`, `versions.tf`, `backend.tf`, `README.md`), same partial-S3
backend injected from `backends/*.hcl`, same `prevent_destroy` discipline,
same refusal to commit fictitious DNS records.

Likewise, **there is no existing `deb.codetracer.com` / `rpm.codetracer.com`
configuration to mirror.** The milestone says to mirror it; a search of
the whole workspace for those hostnames, and for `reprepro`, `createrepo`,
`aptly`, and any `wrangler r2` invocation, finds nothing. CodeTracer's
Cloudflare root has exactly two buckets (`codetracer-traces-prod`,
`codetracer-artifacts-prod`) and no package-repository hosting at all. So
the per-ecosystem bucket layout here is **new work**, not a copy, and the
only thing inherited from CodeTracer is the root's *structure*.

## Where this file should live

In the `infra` repository, at `terraform/cloudflare/reprobuild-prod/`,
beside `codetracer-prod`. It is committed here in `reprobuild` because
`infra` was out of scope for edits in this milestone. Landing it is a
move plus:

1. `backends/cloudflare-reprobuild-prod.hcl` (contents in `backend.tf`).
2. A state bucket, via `scripts/bootstrap-cloudflare-state-backend.sh`.
   The DynamoDB lock table is shared and already exists.
3. A zone-scoped API token, per
   `docs/runbooks/Cloudflare-Resource-Lifecycle.runbook.md`, with the
   plan/apply pair agenix-encrypted under
   `machines/ci/secrets/cloudflare/`.
4. A leg in `.github/workflows/terraform-cloudflare-ci.yml`.

## Running the checks that do not need credentials

```sh
terraform init -backend=false      # -backend=false: no state, no creds
terraform validate
terraform fmt -check -diff
```

`-backend=false` is what makes this safe to run anywhere: it skips the S3
backend entirely, so no AWS credentials are consulted and no remote state
is touched or created.
