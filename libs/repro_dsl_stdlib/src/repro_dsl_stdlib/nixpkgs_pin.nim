## The catalog's canonical nixpkgs pin, named once.
##
## Every stdlib catalog entry provisioned through a ``nixpkgs#`` selector
## resolves against one coherent nixpkgs snapshot, so the Nix CI gate can probe
## the whole catalog against a single flake input. Until the DSL accepted an
## expression in a provisioning setter, "one snapshot" could only be expressed
## by pasting the same two strings into every entry — 274 copies of each — and
## policing the duplication with a test that grepped for the literal text.
##
## That test (``t_smoke_catalog_audit_m29``) was doing real work: a hand-edited
## file that forgot to bump in lockstep is exactly the failure it caught. But it
## could only ever detect divergence after the fact. Referencing a const makes
## the divergence unrepresentable for every entry that uses it, which is the
## stronger guarantee — and it turns the audit's job from "are these 274 strings
## still equal" into the much smaller "does every entry use the const".
##
## ## Bumping the snapshot
##
## Change both values here, together. They are a pair: the rev names the commit
## and the narHash pins its content, and a mismatched pair fails at realization
## with a hash error rather than at compile time.
##
## ## Per-package divergence
##
## An entry that must pin elsewhere writes its own literals instead of importing
## this module — see ``accountsservice``, which is held at release-24.11 for an
## ABI reason documented both in that file and in the audit's exemption list.
## Diverging is meant to be possible; it is meant to be *deliberate and
## visible*, which a literal in the entry alongside a comment achieves and a
## silently stale copy of a shared string does not.

const
  CanonicalNixpkgsRev* = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8"
    ## The nixpkgs commit every ``nixpkgs#`` catalog entry resolves against,
    ## unless it is a documented exemption.

  CanonicalNixpkgsNarHash* = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    ## The NAR hash of the tree at ``CanonicalNixpkgsRev``. Bump with the rev.
