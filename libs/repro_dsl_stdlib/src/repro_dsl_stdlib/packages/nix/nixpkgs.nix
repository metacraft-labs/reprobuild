# Pinned nixpkgs for reprobuild's stdlib tool-provisioning packages.
#
# These sibling ``default.nix`` files are evaluated via ``nix build --file`` by
# the engine's tool-resolution path (repro_tool_profiles.resolveNixTool), which
# runs in whatever shell invoked ``repro`` — including a *consumer's* dev shell
# (e.g. codetracer's, reached through ``direnv exec``) where ``<nixpkgs>`` is not
# on ``NIX_PATH``. Relying on ambient ``<nixpkgs>`` therefore both breaks in
# pure/flake environments and makes tool provisioning non-reproducible.
#
# Pinning here keeps provisioning self-contained and reproducible regardless of
# the invoking shell. ``fetchTarball`` with a fixed ``sha256`` is pure-eval safe.
# Kept in sync with flake.lock's ``nixpkgs`` node (rev + unpacked tarball hash;
# refresh with ``nix-prefetch-url --unpack`` when bumping the flake input).
import (builtins.fetchTarball {
  url = "https://github.com/NixOS/nixpkgs/archive/addf7cf5f383a3101ecfba091b98d0a1263dc9b8.tar.gz";
  sha256 = "1zv083l3n5n4s7x2hcqki29s5gyspn7f1y6xyl6avmd94sxv9kc4";
}) {}
