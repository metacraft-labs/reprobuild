# The Rust 1.94.0 toolchain, realized through the NIX provisioning channel
# from rust-lang's own release archive by ``../rust-release.nix``, which
# says why it is not ``nixpkgs#rustc`` and how the archive is adapted.
#
# The digests are upstream's ``rust-1.94.0-<triple>.tar.xz.sha256``
# and equal those of the ``tarball`` arms in ``packages/rustc.nim`` and
# ``packages/cargo.nim``; ``rust_toolchain_pins`` holds the same rows.
#
# ``pkgs`` defaults to the stdlib's nixpkgs pin, which is what the engine
# evaluates (``nix build --file`` calls the function with its defaults). It
# is a parameter only so that a check can evaluate THIS expression for
# another platform, for example the same pin with ``crossSystem`` aarch64
# (decision 35: a realisation and build on aarch64-linux).
{ pkgs ? import ../nixpkgs.nix }:
import ../rust-release.nix {
  inherit pkgs;
  version = "1.94.0";
  archives = {
    x86_64-linux = {
      triple = "x86_64-unknown-linux-gnu";
      sha256 = "e8fa4185f3ef6ae32725ff638b1ecdbff28f5d651dc0b3111e2539350d03b15a";
    };
    aarch64-linux = {
      triple = "aarch64-unknown-linux-gnu";
      sha256 = "c6fd6d1c925ed986df3b2c0b89bbc90ce15afb62e4d522a054e7d50c856b3c1a";
    };
    aarch64-darwin = {
      triple = "aarch64-apple-darwin";
      sha256 = "9e55893e014e6aa76924b4cc244a289ad56de4d89d3721fbd5c7f497b31ea33c";
    };
    x86_64-darwin = {
      triple = "x86_64-apple-darwin";
      sha256 = "63fe27931d4b8da0b0069f13d4d2c04792203a5cabb4df17ff15495aaaab0ef7";
    };
  };
}
