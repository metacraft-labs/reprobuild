# main.tf — Cloudflare zone + R2 buckets + custom domains for reprobuild.com.
#
# What this root is for: the hosting half of M3. The installer, the apt /
# dnf / pacman repositories and the release archives all have to be
# fetchable from stable hostnames, and each hostname has to be bound to
# the bucket that holds it.
#
# ## The one-bucket-per-hostname shape, and why it is not one bucket
#
# An R2 custom domain binds ONE bucket to ONE hostname, and serves that
# bucket at the root of it. So `deb.reprobuild.com/dists/stable/InRelease`
# requires a bucket whose key `dists/stable/InRelease` is at its root.
# Putting every ecosystem in one bucket under prefixes would mean one
# hostname serving `.../deb/dists/...`, and apt's `URIs:` would have to
# carry the prefix -- workable, but it makes every repository share one
# access-control and lifecycle boundary, so a token that can publish debs
# can also rewrite the release archives and the trust anchor.
#
# Separate buckets let the release pipeline hold a token per surface, and
# in particular let `keys` be writable by almost nothing: it holds the
# trust anchor the installer pins, and it is the one bucket where a
# silent overwrite would be worth the most to an attacker.
#
# ## What is deliberately NOT here
#
#   * No DNS A/AAAA/CNAME records. Following codetracer-prod, which
#     refuses to commit fictitious records: the R2 custom domains below
#     create the DNS they need themselves, and anything else (MX, apex)
#     must come from the inventory of the real zone, which does not exist
#     yet because the delegation is still in flight.
#
#   * No Scoop or Homebrew bucket. Both are GIT REPOSITORIES, not static
#     file trees -- `scoop bucket add` and `brew tap` clone them -- and R2
#     serves objects, not git. They belong in GitHub repositories
#     (metacraft-labs/scoop-reprobuild, metacraft-labs/homebrew-reprobuild),
#     which is why the M3 installer's bucket URL is a plain variable
#     rather than a hostname in this zone. Adding `scoop.reprobuild.com`
#     as a CNAME to GitHub would only alias a git remote and is not worth
#     the confusion of looking like the other repo subdomains.
#
#   * No Pages PROJECT. `get-reprobuild` already exists and is deployed by
#     .github/workflows/deploy-get.yml; importing it is a separate change.

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

#
# === Zone: reprobuild.com ===
#

resource "cloudflare_zone" "reprobuild_com" {
  # v5 schema: `name` (v4 called it `zone`) and an `account` object (v4
  # took a flat `account_id`). `plan` is COMPUTED in v5 and cannot be set
  # here — the zone's plan is changed at the dashboard or via billing, and
  # v4's `plan = "free"` would be rejected.
  name = "reprobuild.com"

  account = {
    id = var.cloudflare_account_id
  }

  type = "full"

  lifecycle {
    # `type` drift force-replaces a zone, which would take every record
    # with it — including the ones the R2 custom domains below create.
    prevent_destroy = true
  }
}

#
# === R2 buckets: one per published surface ===
#
# Names carry the `-prod` suffix the codetracer buckets use, so a staging
# set can exist later without renaming these.

# The apt repository: pool/ + dists/ as produced by
# scripts/release/repro-publish-repos.sh --ecosystem deb.
resource "cloudflare_r2_bucket" "deb" {
  account_id = var.cloudflare_account_id
  name       = "reprobuild-deb-prod"
  location   = var.r2_location

  lifecycle {
    # Deleting this bucket breaks `apt update` for every installed user,
    # and the pool cannot be reconstructed from a release page alone --
    # the signed indices are generated at publish time.
    prevent_destroy = true
  }
}

# The dnf/yum repository: the .rpm set plus repodata/.
resource "cloudflare_r2_bucket" "rpm" {
  account_id = var.cloudflare_account_id
  name       = "reprobuild-rpm-prod"
  location   = var.r2_location

  lifecycle {
    prevent_destroy = true
  }
}

# The pacman repository: packages plus the signed .db.
resource "cloudflare_r2_bucket" "arch" {
  account_id = var.cloudflare_account_id
  name       = "reprobuild-arch-prod"
  location   = var.r2_location

  lifecycle {
    prevent_destroy = true
  }
}

# Release archives + SHA256SUMS{,.asc} + per-artifact .asc. This is what
# the installer's repo-less fallback fetches, and what the Scoop manifest
# points its `url` at.
resource "cloudflare_r2_bucket" "downloads" {
  account_id = var.cloudflare_account_id
  name       = "reprobuild-downloads-prod"
  location   = var.r2_location

  lifecycle {
    prevent_destroy = true
  }
}

# The trust anchor, and NOTHING else.
#
# This bucket exists separately for one reason: verifying a release
# against a key published beside it is circular. docs/release-signing.md
# makes that a rule and release.yml already holds to it by exporting the
# public key to $RUNNER_TEMP rather than into the uploaded staging tree.
# A separate bucket is what lets that rule be enforced by access control
# instead of by remembering.
resource "cloudflare_r2_bucket" "keys" {
  account_id = var.cloudflare_account_id
  name       = "reprobuild-keys-prod"
  location   = var.r2_location

  lifecycle {
    prevent_destroy = true
  }
}

#
# === R2 custom domains ===
#
# These are the milestone's deliverable, and unlike codetracer-prod's
# commented-out template they are declared for real here. The difference
# is that they need no invented data: a custom domain is (bucket,
# hostname, zone), and all three are known. codetracer-prod's DNS records
# are commented out because their VALUES would have to be made up.
#
# Creating one of these also creates the DNS record that fronts it, which
# is why there are no separate `cloudflare_record` resources for these
# five names. Declaring both would fight over the same record.

resource "cloudflare_r2_custom_domain" "deb" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.deb.name
  domain      = "deb.reprobuild.com"
  zone_id     = cloudflare_zone.reprobuild_com.id
  enabled     = true
}

resource "cloudflare_r2_custom_domain" "rpm" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.rpm.name
  domain      = "rpm.reprobuild.com"
  zone_id     = cloudflare_zone.reprobuild_com.id
  enabled     = true
}

resource "cloudflare_r2_custom_domain" "arch" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.arch.name
  domain      = "arch.reprobuild.com"
  zone_id     = cloudflare_zone.reprobuild_com.id
  enabled     = true
}

resource "cloudflare_r2_custom_domain" "downloads" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.downloads.name
  domain      = "downloads.reprobuild.com"
  zone_id     = cloudflare_zone.reprobuild_com.id
  enabled     = true
}

resource "cloudflare_r2_custom_domain" "keys" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.keys.name
  domain      = "keys.reprobuild.com"
  zone_id     = cloudflare_zone.reprobuild_com.id
  enabled     = true
}

#
# === The install one-liner's hostname(s) ===
#
# Attached to the EXISTING `get-reprobuild` Pages project rather than to a
# bucket, because that project is already built and deployed by
# .github/workflows/deploy-get.yml and already serves /sh and /pwsh as
# text/plain with the short TTL that get/_headers sets. Pointing a second
# hostname at it is additive; re-hosting the installer on R2 would
# duplicate a working surface and lose those headers.

resource "cloudflare_pages_domain" "get" {
  account_id   = var.cloudflare_account_id
  project_name = var.pages_project_get
  # v5 spells the hostname `name`; v4 called it `domain`.
  name = "get.reprobuild.com"

  depends_on = [cloudflare_zone.reprobuild_com]
}

# The milestone's name for the same surface. See
# var.manage_install_hostname for why both exist.
resource "cloudflare_pages_domain" "install" {
  count = var.manage_install_hostname ? 1 : 0

  account_id   = var.cloudflare_account_id
  project_name = var.pages_project_get
  name         = "install.reprobuild.com"

  depends_on = [cloudflare_zone.reprobuild_com]
}
