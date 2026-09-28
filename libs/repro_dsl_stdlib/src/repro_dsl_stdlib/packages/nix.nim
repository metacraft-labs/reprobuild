import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

## PROVISIONING ONLY -- there is no `executable nix:` / `cli:` block here, so
## `nix` names no build edge and carries no dependency policy, no
## non-determinism policy and no DA-6 capture-breadth declaration. This matters
## because DA-6 names `nix build` as a per-tool case and the instinct is to
## write the declaration in this file: it would have nowhere to attach and would
## reach no edge, exactly as `packages/bash.nim` records for the entropy
## blessing.
##
## WHERE A `nix build` EDGE'S DECLARATION ACTUALLY LIVES. Every `nix build` in a
## reprobuild recipe is a `shell()` edge -- the tool identity is `sh`, via
## `packages/sh.nim` -- so the declaration that governs it is `sh`'s, and it is
## FULL CAPTURE. The `nixPackage` selector below is a different thing entirely:
## it is passed to `nix build` by the PROVISIONER, which realises a tool prefix
## rather than executing a monitored build action, so no `DependencyGathering`
## policy is consulted for it at all.
##
## AND FULL CAPTURE IS THE RIGHT ANSWER FOR IT, which is the part worth writing
## down here rather than leaving to be rediscovered. A `nix build` edge is
## hermetic BY CONSTRUCTION, so monitoring it is near-pure overhead -- and it is
## simultaneously the ONLY CHECK THAT THE HERMETICITY HELD. The records a
## narrowing would remove are precisely the ones that witness a breach:
## `ecEnvReads` for `NIX_PATH` / `NIX_CONFIG` / `TMPDIR` read by the outer
## client, `ecFileReads` for `/etc/nix/nix.conf` and for an `--impure`
## evaluation reaching outside the flake, `ecAmbientReads` for a clock read in
## the outer process, `ecProcessTree` for the daemon hand-off. "Hermetic,
## therefore do not look" is the argument that makes the hermeticity
## unfalsifiable; the full argument is at `packages/sh.nim`'s
## `dependencyPolicy`.

package nix:
  provisioning:
    # The default `nix`/`stable` attributes at this pinned nixpkgs revision
    # build locally on aarch64-darwin. 2.28.5 has upstream cache.nixos.org
    # substitutes and is sufficient for Reprobuild's own Nix invocations.
    nixPackage "nixpkgs#nixVersions.nix_2_28", executablePath = "bin/nix",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash,
      packageId = "nix@2.28.5"
