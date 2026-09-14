# backend.tf — Remote state backend (AWS S3 + DynamoDB locking).
#
# Same shape as `infra/terraform/cloudflare/codetracer-prod/backend.tf`:
# a PARTIAL backend block, with the concrete bucket/key/table injected at
# init time so the values live with the other backend configs rather than
# being duplicated here.
#
#   tofu init -backend-config=../../../backends/cloudflare-reprobuild-prod.hcl
#
# That file does not exist yet; it is part of the PR that lands this root
# in the infra repository, and must read (mirroring
# `backends/cloudflare-codetracer-prod.hcl`):
#
#   bucket         = "metacraft-infra-tofu-state-reprobuild-prod"
#   key            = "cloudflare/reprobuild-prod/terraform.tfstate"
#   region         = "us-east-1"
#   encrypt        = true
#   dynamodb_table = "metacraft-infra-tofu-state-lock"
#
# The bucket must exist before the first init; the codetracer root
# bootstraps its equivalent with
# `scripts/bootstrap-cloudflare-state-backend.sh`. The DynamoDB lock table
# is SHARED with the other roots, so it does not need creating again.
#
# State is NOT kept in R2, even though this root creates R2 buckets: the
# state would then be stored in the thing whose existence it records, and
# a corrupted or deleted bucket would take the only record of it with it.

terraform {
  backend "s3" {}
}
