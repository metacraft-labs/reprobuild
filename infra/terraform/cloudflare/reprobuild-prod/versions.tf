# versions.tf — terraform + provider version pinning.
#
# This root is pinned to provider v5, and the existing Cloudflare root
# `infra/terraform/cloudflare/codetracer-prod` is pinned to `~> 4.52`.
# That divergence is deliberate, and it is forced:
#
#   `cloudflare_r2_custom_domain` DOES NOT EXIST in the v4 provider.
#
# That is not a guess. This root was first written against `~> 4.52` to
# match codetracer-prod, and `terraform validate` rejected it:
#
#   Error: Invalid resource type
#     on main.tf line 152, in resource "cloudflare_r2_custom_domain" "deb":
#     The provider cloudflare/cloudflare does not support resource type
#     "cloudflare_r2_custom_domain".
#
# Binding deb./rpm./arch./downloads./keys. to their buckets IS this
# milestone's hosting deliverable, so v4 cannot express it. The
# alternative — creating the custom domains by hand at the dashboard —
# would leave the part most likely to be mis-set unmanaged and undiffable.
#
# Why this does not destabilise the other root: v5's breaking changes
# matter when MIGRATING existing state (v4's `cloudflare_record` becomes
# `cloudflare_dns_record`, `cloudflare_zone.zone` becomes `.name`, and
# `plan` becomes computed). This root has no existing state to migrate —
# nothing in it has ever been applied — so it pays none of that cost,
# while codetracer-prod keeps its v4 pin until its own import pass is
# finished. The two roots have separate state and separate providers.
#
# The consequence to carry forward: when codetracer-prod moves to v5,
# these two pins converge; until then, anyone copying between the roots
# must translate the schema. The shared import tooling in
# `nixos-modules/terraform/cloudflare` already understands both spellings.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}
