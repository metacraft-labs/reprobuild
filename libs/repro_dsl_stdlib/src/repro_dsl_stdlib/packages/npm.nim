## ``npm`` — Node Package Manager, ships in the ``nodejs`` Nix package
## alongside ``node`` and ``npx``.
##
## Dispatched by the JS/TS convention (M16/M21) for:
##   * ``npm ci`` — M21 A1 deterministic dependency install when the
##     project ships ``package-lock.json``.
##   * ``npm install`` — M24 Mode B crude fallback when a bundler config
##     (vite / webpack / rollup / parcel / next / nuxt) drives the
##     build script.
##   * ``npm run build`` — M24 Mode B build dispatch.
##
## Listed in M29 (Provisioning catalog cleanup) so the JS/TS dispatch
## path has a closed-set catalog footprint matching the existing
## ``node`` + ``npx`` entries.

import repro_project_dsl

package npm:
  provisioning:
    nixPackage "nixpkgs#nodejs", executablePath = "bin/npm",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
