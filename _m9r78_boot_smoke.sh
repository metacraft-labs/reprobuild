#!/usr/bin/env bash
# M9.R.78 boot smoke — reuses _m9r68d_boot_smoke.sh with M9.R.78 output dir.
# Bumps BOOT_TIMEOUT to 300s to give sway extra time to render its wallpaper
# through the newly-valid Mesa 24.0.9 GBM/DRI_IMAGE_DRIVER v1 path.
set -euo pipefail
export OUTDIR="${OUTDIR:-/opt/repro/reprobuild/_m9r78_boot_out}"
export BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
export SCREENDUMP_INTERVAL="${SCREENDUMP_INTERVAL:-30}"
exec /opt/repro/reprobuild/_m9r68d_boot_smoke.sh
