# outputs.tf — surface the ids and names the RELEASE PIPELINE needs.
#
# These are not decoration. scripts/release/repro-publish-repos.sh takes
# its upload destination as a `--target r2:<bucket>` argument, and
# scripts/install/repro-install.sh takes its base URL as one variable, so
# the bucket names and hostnames below are exactly the values CI has to be
# configured with. Emitting them from the state that created them is what
# keeps the two from drifting apart by hand-copying.

output "zone_id" {
  description = "Cloudflare zone ID for reprobuild.com."
  value       = cloudflare_zone.reprobuild_com.id
}

output "zone_name" {
  description = "Cloudflare zone name (reprobuild.com)."
  value       = cloudflare_zone.reprobuild_com.name
}

output "r2_buckets" {
  description = "Every published R2 bucket, by surface. These are the values for repro-publish-repos.sh --target r2:<bucket>."
  value = {
    deb       = cloudflare_r2_bucket.deb.name
    rpm       = cloudflare_r2_bucket.rpm.name
    arch      = cloudflare_r2_bucket.arch.name
    downloads = cloudflare_r2_bucket.downloads.name
    keys      = cloudflare_r2_bucket.keys.name
  }
}

output "repo_urls" {
  description = "The per-ecosystem hostnames, as the installer's REPRO_DEB_URL / REPRO_RPM_URL / REPRO_ARCH_URL / REPRO_DOWNLOADS_URL / REPRO_KEYS_URL defaults."
  value = {
    deb       = "https://${cloudflare_r2_custom_domain.deb.domain}"
    rpm       = "https://${cloudflare_r2_custom_domain.rpm.domain}"
    arch      = "https://${cloudflare_r2_custom_domain.arch.domain}"
    downloads = "https://${cloudflare_r2_custom_domain.downloads.domain}"
    keys      = "https://${cloudflare_r2_custom_domain.keys.domain}"
  }
}

output "install_hostnames" {
  description = "Hostnames serving the install one-liner from the get-reprobuild Pages project."
  value = compact([
    cloudflare_pages_domain.get.name,
    var.manage_install_hostname ? cloudflare_pages_domain.install[0].name : "",
  ])
}

output "git_backed_surfaces" {
  description = <<-EOT
    Surfaces that are NOT in this root because they are git repositories
    rather than object stores: a Scoop bucket and a Homebrew tap are
    cloned, not fetched, so R2 cannot serve them. Emitted as an output so
    the gap is visible in `terraform output` rather than only in a comment.
  EOT
  value = {
    scoop    = "https://github.com/metacraft-labs/scoop-reprobuild (does not exist yet)"
    homebrew = "https://github.com/metacraft-labs/homebrew-reprobuild (does not exist yet)"
  }
}
