# The Go 1.25.4 toolchain, realized through the NIX provisioning channel
# from go.dev's own release archive (ReproOS Add-On Mode §13 decision 36).
#
# ## Why not ``nixpkgs#go``
#
# nixpkgs patches Go's standard library to read system data from fixed
# store paths: ``time`` its zoneinfo from the tzdata package, ``net`` its
# ``services`` and ``protocols`` from iana-etc, ``mime`` its
# ``mime.types`` from mailcap. Every binary that package compiles embeds
# those ``/nix/store/...`` paths, so a Go program the catalog builds and
# ships to a Debian host looks up its time zones, services and MIME types in
# a store that host does not have. Measured 2026-11-01: geth built with the
# pinned nixpkgs' Go 1.25.4 embedded four such paths; built with go.dev's
# 1.25.4 from the same command and module cache, none, and different bytes.
#
# ## What this is
#
# go.dev's archive for the platform, unpacked as-is: the archive's ``go/``
# directory is GOROOT, and its ``bin/go`` locates GOROOT relative to its
# own path. The same archive and digest as the catalog's ``tarball`` arm for
# that platform, so the Nix and the tarball modes run one compiler and
# build byte-identical binaries. Go's distributed toolchain binaries are
# statically linked on Linux, so nothing is patched; stripping or patching
# them would make this a different compiler from the tarball arm's.
#
# ``pkgs`` defaults to the stdlib's nixpkgs pin (used only for ``fetchurl``
# and ``stdenv``); it is a parameter so a check can evaluate this
# expression for another platform.
{ pkgs ? import ../nixpkgs.nix }:
let
  inherit (pkgs) lib stdenv;
  version = "1.25.4";
  # One archive and SHA-256 per platform, from
  # https://go.dev/dl/?mode=json&include=all (read 2026-11-01). Keep equal to
  # ``go_toolchain_pins.nim`` and the ``tarball`` arms in ``go.nim``.
  archives = {
    x86_64-linux = {
      name = "linux-amd64";
      sha256 = "9fa5ffeda4170de60f67f3aa0f824e426421ba724c21e133c1e35d6159ca1bec";
    };
    aarch64-linux = {
      name = "linux-arm64";
      sha256 = "a68e86d4b72c2c2fecf7dfed667680b6c2a071221bbdb6913cf83ce3f80d9ff0";
    };
    x86_64-darwin = {
      name = "darwin-amd64";
      sha256 = "33ba03ff9973f5bd26d516eea35328832a9525ecc4d169b15937ffe2ce66a7d8";
    };
    aarch64-darwin = {
      name = "darwin-arm64";
      sha256 = "c1b04e74251fe1dfbc5382e73d0c6d96f49642d8aebb7ee10a7ecd4cae36ebd2";
    };
  };
  system = stdenv.hostPlatform.system;
  archive = archives.${system} or (throw
    "reprobuild-go-${version}: go.dev publishes no archive pinned here for ${system}");
in
stdenv.mkDerivation {
  pname = "reprobuild-go";
  inherit version;
  src = pkgs.fetchurl {
    url = "https://go.dev/dl/go${version}.${archive.name}.tar.gz";
    inherit (archive) sha256;
  };
  sourceRoot = "go";
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;
  dontFixup = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a . "$out/"
    runHook postInstall
  '';
}
