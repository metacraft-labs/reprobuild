## GM7 fixture: a profile whose `hosts:` entries declare the concerns
## Reprobuild applies there (Gradual-Nix-To-Reprobuild-Migration.md
## §Concern-scoped apply): `m1` gives Reprobuild the applications (and the
## environment) and Nix the packages; `server` gives Reprobuild the packages
## and Nix the applications; `home-pc` declares nothing. Platform neutral
## (runtime predicates only), so one export describes every target.
##
## `gm7app` is defined by the fixture catalog beside this directory
## (`../reprobuild-packages`, passed as `$REPROBUILD_PACKAGES_ROOT`) as a
## macOS disk image, so the export classifies it `applications` for the
## darwin targets (`concerns.packages`) and the Home Manager module routes it
## by that classification.
##
## Exercised by `reprobuild.lib.readIntent` (flake check `lib-tests`: the
## evaluations carry `applies` and each package's `concern` for the declaring
## hosts only), the Home Manager module (`lib-home-manager`: category
## switches default to the complement of the declaration; packages are
## routed by their concern), `lib-intent-ifd` (the sandboxed export with
## `packagesCatalog` classifies like the snapshot) and
## `t_e2e_nix_reads_intent_like_export`, which keeps `export.json` and
## `evaluations.json` current. See ../README.md.
import repro_profile

profile "gm7Concerns":
  activity default:
    bash
    when linux():
      patchelf
    when macos():
      gm7app

  activity desktop:
    busybox

  config:
    git:
      credentialHelper = "store"

  hosts:
    "m1":
      activities: [desktop]
      applies: [applications, environment]
    "server":
      applies: [packages]
    "home-pc": [desktop]

  resources:
    fsUserFile(hostFile = "~/.config/gm7/app.conf", content = "gm7 = 1\n")
    envUserVariable(name = "GM7_EDITOR", value = "nvim")
    fsManagedBlock(hostFile = "~/.bashrc", blockId = "gm7",
      content = "export GM7=1")
