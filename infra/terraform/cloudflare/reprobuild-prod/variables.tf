# variables.tf — Cloudflare credentials + account scoping.
#
# Mirrors `infra/terraform/cloudflare/codetracer-prod/variables.tf`:
# the API token is sensitive and comes from the agenix-encrypted files
# under `machines/ci/secrets/cloudflare/` in CI, or from
# `TF_VAR_cloudflare_api_token` for a local operator. The account id and
# zone id are not secret and are pinned after the first import.

variable "cloudflare_api_token" {
  description = <<-EOT
    Cloudflake API token. Must be scoped to the reprobuild.com zone plus
    the reprobuild-* R2 buckets, per the Cloudflare-Resource-Lifecycle
    runbook. A token scoped to the whole account would let a compromised
    CI job touch codetracer.com as well, which is the reason the
    codetracer root scopes its own token per zone.
  EOT
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID owning the reprobuild.com zone and the R2 buckets. The existing Pages project get-reprobuild lives under account 803741d99690718276ea30950f690c46 (see get/README.md), so that is the expected value."
  type        = string
}

variable "zone_id" {
  description = "Cloudflare zone ID for reprobuild.com. Empty until the zone exists; discovered with cloudflare-inventory.sh and pinned here after the first import."
  type        = string
  default     = ""
}

variable "r2_location" {
  description = <<-EOT
    R2 location hint for every bucket in this root. WNAM matches the
    codetracer buckets. It is a HINT, not a guarantee, and changing it
    after creation does not move an existing bucket -- which is why it is
    one variable for all buckets rather than per-bucket knobs that could
    drift apart.
  EOT
  type        = string
  default     = "WNAM"
}

variable "pages_project_get" {
  description = <<-EOT
    Name of the existing Cloudflare Pages project that serves the install
    one-liner. get/README.md records it as `get-reprobuild`, with
    production branch `master`, deployed by
    .github/workflows/deploy-get.yml via wrangler.

    This root does NOT create that project: it already exists and is
    deployed by CI, so declaring it here would mean importing it and
    moving its lifecycle into Terraform -- a separate, reviewed change.
    What this root does is attach the hostname(s) to it.
  EOT
  type        = string
  default     = "get-reprobuild"
}

variable "manage_install_hostname" {
  description = <<-EOT
    Whether to attach install.reprobuild.com to the Pages project in
    addition to get.reprobuild.com.

    This exists because the M3 milestone names `install.reprobuild.com`
    while the repository's existing, already-deployed surface is
    `get.reprobuild.com` -- chosen to follow the internal
    product-install-domains policy (`get.<product>.<tld>`, with /sh and
    /pwsh as the canonical endpoints). Both can point at the same Pages
    project, so this is a flag rather than a fork; someone has to decide
    which name is canonical and whether the other is a permanent alias.
    Defaulting to true adds the milestone's name without removing the
    policy's.
  EOT
  type        = bool
  default     = true
}
