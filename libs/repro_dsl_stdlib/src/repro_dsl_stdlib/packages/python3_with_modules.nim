## DSL-port M9.R.15d.2 — stdlib provisioning stub for
## ``python3-with-modules``.
##
## gobject-introspection's build-time scanner (``g-ir-scanner``,
## ``g-ir-doc-tool``) invokes ``python3`` with the modules
## ``setuptools``, ``mako`` and ``markdown`` imported at startup. The
## bare ``python3`` stdlib stub (``packages/python3.nim``) points at
## ``nixpkgs#python3`` which exposes the interpreter alone — none of
## the three modules ride along.
##
## ## Provisioning channel — Nix expression file
##
## Following the M48 ``stylus`` precedent (``packages/nix/stylus-
## 0.64.0/default.nix``) the wrapper is expressed as a custom Nix
## expression that invokes ``python3.withPackages``. nixpkgs'
## ``withPackages`` helper produces a thin derivation whose
## ``bin/python3`` (and ``bin/python``) launcher has its
## ``sys.path`` pre-populated with the declared module set — no
## ``PYTHONPATH`` gymnastics needed at the consumer site.
##
## Verified locally:
##   $ nix-build /opt/.../python3-with-modules-1.0.0/default.nix
##   /nix/store/...-python3-3.12.12-env
##   $ bin/python3 -c 'import setuptools, mako, markdown'
##   (succeeds)
##
## ## TODO(M9.R.15e+)
##
## Widen the channel set with a tarball channel for non-Nix hosts
## (probably the same astral-sh/python-build-standalone tarball the
## bare ``python3`` stub uses, plus a ``pip install`` of the three
## modules into a workspace-local venv).

import repro_project_dsl

package `python3-with-modules`:
  provisioning:
    nixPackage "reprobuild-stdlib-python3-with-modules-1.0.0",
      executablePath = "bin/python3",
      expressionFile = "nix/python3-with-modules-1.0.0/default.nix",
      lockIdentity = "nix:python3-with-modules@1.0.0:setuptools+mako+markdown"
