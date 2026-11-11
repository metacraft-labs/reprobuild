# The Rust 1.97.1 toolchain, realized through the NIX provisioning channel
# from rust-lang's own release archive by ``../rust-release.nix``, which
# says why it is not ``nixpkgs#rustc`` and how the archive is adapted.
#
# The digests are upstream's ``rust-1.97.1-<triple>.tar.xz.sha256``
# (read 2026-11-11; equal to channel-rust-1.97.toml's ``xz_hash`` rows),
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
  version = "1.97.1";
  archives = {
    x86_64-linux = {
      triple = "x86_64-unknown-linux-gnu";
      sha256 = "88f28fa9af20594179f85d6df67078dfd6fa93e2f6da5e1e9b0ac4997988ca4f";
    };
    aarch64-linux = {
      triple = "aarch64-unknown-linux-gnu";
      sha256 = "9a7a2c336b4787f1b72f6bab7c35d5b7af2fd03cbd39b4fc721466a70d402a7d";
    };
    aarch64-darwin = {
      triple = "aarch64-apple-darwin";
      sha256 = "c9748cc86107734a2a024069908a895de7caa2d37062fb641eef9f756938ace2";
    };
    x86_64-darwin = {
      triple = "x86_64-apple-darwin";
      sha256 = "891c32ea77b750dccc7fb0ea98e3feb9db3d29fe0cfea5907d002f270c59cf58";
    };
  };
}
