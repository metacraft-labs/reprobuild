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
##
## ## M7 (reprobuild Windows migration) note: NO Windows tarball entry
##
## Upstream astral-sh/maturin ships a standalone Windows binary
## (``maturin-x86_64-pc-windows-msvc.zip``) which COULD be wired here
## as a sibling tarball provisioning slice. Per the Windows-migration
## M7 deliberation we chose NOT to add it. Rationale:
##
##   1. ``maturin`` is a Python package whose CLI shim depends on a
##      compatible Python interpreter — the standalone binary still
##      shells out to ``python`` for PEP 517 hooks, so a tarball
##      install in isolation is only half the story.
##   2. The recorder recipe already provisions ``uv`` (which carries
##      its own pinned interpreter resolution) and ``python-dev``;
##      adding a per-tool tarball pin to ``maturin`` duplicates the
##      version-pinning surface (an upstream maturin bump now requires
##      bumping BOTH this catalog AND the workspace-local install).
##   3. The cleaner shape: a recipe-level build edge that calls
##      ``uv tool install --python <python-dev> maturin pytest``
##      against a workspace-local ``<repro-store>/uv-tools/bin`` and
##      exposes that bin dir on PATH for downstream edges. ``uv tool
##      install`` reads the maturin version from the project's
##      ``pyproject.toml`` build-system requirement, keeping the pin
##      in one place.
##
## See ``codetracer-python-recorder/repro.nim`` for the
## ``uv tool install`` build edge that consumes this convention.

import repro_project_dsl

package maturin:
  provisioning:
    nixPackage "nixpkgs#maturin", executablePath = "bin/maturin",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
