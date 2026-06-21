# DSL-port M9.R.15d.2 — python3 wrapper carrying the
# setuptools + mako + markdown modules consumed by
# gobject-introspection's build-time scanner.
#
# M9.R.15m.3 — pyyaml added for the mesa meson build (mesa
# src/meson.build:967 hard-requires the ``yaml`` Python module).
#
# nixpkgs' ``python3.withPackages`` produces a thin wrapper derivation
# whose ``bin/python3`` (and ``bin/python``) launcher has its sys.path
# pre-populated with the declared module set; no PYTHONPATH gymnastics
# needed at the consumer site.
let
  pkgs = import <nixpkgs> {};
in
  pkgs.python3.withPackages (ps: [
    ps.setuptools
    ps.mako
    ps.markdown
    ps.pyyaml
  ])
