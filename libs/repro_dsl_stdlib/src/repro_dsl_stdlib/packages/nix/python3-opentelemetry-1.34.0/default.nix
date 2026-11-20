# python3 with the OpenTelemetry Python SDK, for the `python3-opentelemetry`
# stdlib package (packages/python3_opentelemetry.nim).
#
# nixpkgs' `python3.withPackages` produces a thin wrapper whose `bin/python3`
# has the SDK and its dependency closure on `sys.path`, so a consumer runs it
# with no PYTHONPATH. At the pinned nixpkgs (../nixpkgs.nix) the SDK is
# 1.34.0, the version the package's Windows arms pin.
let
  pkgs = import ../nixpkgs.nix;
in
pkgs.python3.withPackages (ps: [ ps.opentelemetry-sdk ])
