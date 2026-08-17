## ``pyproject-hooks`` — PyPA's PEP 517 frontend used by ``python -m build``.
##
## The Python convention's M24 Mode B crude fallback dispatches
## ``python3 -m build --wheel --no-isolation`` for backends whose action
## graph doesn't reduce cleanly to the four PEP 517 hooks Mode A uses
## (maturin / scikit-build-core / poetry-core / pdm-backend / uv_build).
## ``python -m build`` in turn shells through to ``pyproject_hooks`` to
## drive ``build_wheel``, ``get_requires_for_build_wheel``, etc. Without
## this package importable from the bundled Python the build command
## fails with ``ModuleNotFoundError: No module named 'pyproject_hooks'``.
##
## Nix attribute: ``nixpkgs#python3Packages.pyproject-hooks`` mirrors the
## existing ``python3Packages.{pytest,flake8,installer}`` shape. The same
## nixpkgs pin used by the rest of the Python toolchain. ``executablePath``
## is intentionally empty because the consumer is ``python3 -m
## pyproject_hooks`` (or transitively ``python -m build``) — a Python
## module entry-point rather than a standalone binary; reprobuild's
## provisioning layer treats this catalog entry as "make the module
## importable from PYTHONPATH".

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package pyproject_hooks:
  provisioning:
    nixPackage "nixpkgs#python3Packages.pyproject-hooks",
      executablePath = "bin/pyproject-hooks",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
