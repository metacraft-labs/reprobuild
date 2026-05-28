## ``maturin`` — Rust-to-Python PyO3 extension build tool / PEP 517
## backend.
##
## Required by the Python convention's M24 Mode B crude fallback when a
## project's ``pyproject.toml`` declares ``build-backend = "maturin"``.
## The fallback action calls ``python -m build --wheel --no-isolation``,
## which ultimately resolves the ``maturin`` backend; without
## ``maturin`` importable from the bundled Python (and its ``maturin``
## CLI binary on PATH) the build fails with
## ``ModuleNotFoundError: No module named 'maturin'`` or
## ``maturin: command not found``.
##
## Listed in M29 (Provisioning catalog cleanup) alongside
## ``pyproject_hooks`` so the Mode B maturin path has a closed-set
## catalog footprint when the M9 harness exercises
## ``python/pep517-maturin``.

import repro_project_dsl

package maturin:
  provisioning:
    nixPackage "nixpkgs#maturin", executablePath = "bin/maturin",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
