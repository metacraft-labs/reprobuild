# Shared fixture of the realization-source rules (reprobuild-pm spec
# Gradual-Nix-To-Reprobuild-Migration.md; nix/lib/realization-sources.nix).
#
# One definition of the cases, read by the library tests (nix/tests/lib.nix,
# stub derivations) and the Home Manager module and host-facts tests
# (nix/tests/home-manager.nix, nix/tests/host-facts.nix, real derivations):
# each takes `mkDrv name version` and gets the same sets and sources. The
# expectations are stated once, in `expected`; the tests do not restate them.
#
# The profile is the neutral export (tests/fixtures/intent-exports/neutral)
# for host `home-pc`, whose packages are bash, busybox, cmake, gm5-home-pc-only,
# llvm, ripgrep (and per-platform ones). `gm5-home-pc-only` and `ripgrep` have
# no Nix record in the catalog, so without a mapping they are unmapped; `bash`
# and `llvm` have one.
{ mkDrv }:
rec {
  # A nixpkgs-like set that is not the consumer's own (nixpkgs-unstable): the
  # attribute is the catalog's (`bash`).
  unstableSet = {
    bash = mkDrv "bash" "99.0-unstable";
  };

  # A flake's `packages.<system>`: no catalog record, the attribute is the
  # canonical name, or the one the consumer names.
  flakePackages = {
    gm5-home-pc-only = mkDrv "gm5-home-pc-only" "1.0-flake";
    tools.rg = mkDrv "ripgrep" "14.0-flake";
  };

  # A flake output that is part of no package set.
  llvmDerivation = mkDrv "llvm" "0-flake-output";

  # What a consumer maps. Every name is selected by the profile on some host,
  # and canonical.
  sources = {
    bash.nixpkgs = unstableSet;
    gm5-home-pc-only.packages = flakePackages;
    ripgrep = {
      packages = flakePackages;
      attribute = "tools.rg";
    };
    llvm.derivation = llvmDerivation;
  };

  # Each refusal: the mapping, and the text the error must contain.
  refusals = {
    # Neither a catalog contribution nor a host's selection names it.
    notCanonical = {
      sources.not-a-package.derivation = llvmDerivation;
      mentions = [
        "not-a-package"
        "not a canonical package"
      ];
    };
    # Canonical (the Nix catalog targets `age`), selected by no host of the
    # neutral profile: a stale mapping.
    staleMapping = {
      sources.age.derivation = llvmDerivation;
      mentions = [
        "age"
        "selects `age` on no host"
      ];
    };
    # Both `nixpkgs` and `derivation`.
    malformed = {
      sources.bash = {
        nixpkgs = unstableSet;
        derivation = llvmDerivation;
      };
      mentions = [
        "bash"
        "exactly one of"
      ];
    };
    # A set without the attribute the mapping names is not a refusal of the
    # mapping, it is that package unmapped: see `unresolved`.
  };

  # A well-formed mapping whose set has no such attribute: the package is
  # `unmapped` with the reason, and nothing else is lost.
  unresolved = {
    sources.bash = {
      packages = flakePackages;
    };
    mentions = [
      "bash"
      "no derivation at `bash`"
    ];
  };

  # Who is who, by canonical name: what the facts and the module name each
  # package realized through `sources`.
  expected = {
    bash = unstableSet.bash;
    gm5-home-pc-only = flakePackages.gm5-home-pc-only;
    ripgrep = flakePackages.tools.rg;
    llvm = llvmDerivation;
  };
}
