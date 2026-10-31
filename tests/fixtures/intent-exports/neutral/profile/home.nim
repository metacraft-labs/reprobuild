## GM5 fixture: a platform-neutral profile (runtime predicates only), so one
## export describes every target. Exercised by `reprobuild.lib.readIntent`
## (flake check `lib-tests`, `lib-intent-ifd`), the Home Manager module
## (`lib-home-manager`) and `t_e2e_nix_reads_intent_like_export`, which keeps
## `export.json` and `evaluations.json` current. See ../README.md.
import repro_profile

profile "gm5Neutral":
  data:
    "data/apps.toml"

  activity default:
    bash
    package("cmake", "3.0.0-gm5-pin", binaries = @["cmake"])
    when linux():
      patchelf
      # Nested guards conjoin: x86_64 Linux only (reprobuild-pm issue
      # 2026-10-18-home-planner-drops-packages-under-nested-activity-guards).
      when x86_64():
        `gm5-linux-x86-tool`
    when macos() and arm64():
      `gm5-mac-arm-tool`

  activity desktop:
    busybox
    when host() == "home-pc":
      `gm5-home-pc-only`

  activity cli:
    ripgrep
    # GM9: resources that belong to the activity: planned (and exported in
    # the evaluation) only for a host that selects `cli` -- home-pc, not m1.
    resources:
      fsUserFile(hostFile = "~/.config/gm9/cli.conf", content = "cli = 1\n")

  activity laptop:
    resources:
      fsUserFile(hostFile = "~/.config/gm9/laptop.conf",
        content = "laptop = 1\n")

  config:
    git:
      when macos():
        credentialHelper = "osxkeychain"
      else:
        credentialHelper = "libsecret"

  hosts:
    # GM10: m1's system scope is managed elsewhere; the export carries
    # it (`intent.hostSystems`, `evaluation.system`).
    "m1":
      activities: [desktop, laptop]
      system: managedElsewhere("example-org/infra")
    "home-pc": [desktop, cli]
    # ReproOS add-on mode: rpi's system belongs to its distribution and
    # Reprobuild manages the system profile's `default` activity on top of
    # it; validator's block form selects two more system activities (they
    # name the SYSTEM profile's activities, not this profile's).
    "rpi":
      activities: [cli]
      system: addOn
    "validator":
      activities: [cli]
      system:
        mode: addOn
        activities: [web, backup]
    # A fully managed host selecting a system activity (the `full` block
    # form, decision 17): managed here, mode `full`, activities default+web.
    "pc-full":
      activities: [cli]
      system: {mode: full, activities: [web]}

  resources:
    when linux():
      fsUserFile(hostFile = "~/.config/gm5/linux.conf", content = "linux = 1\n")
    elif macos():
      fsUserFile(hostFile = "~/Library/Preferences/gm5.conf",
        content = "mac = 1\n")
    fsUserFile(hostFile = "~/.local/bin/gm5-hello",
      content = "#!/bin/sh\necho hello\n", mode = "0755", executable = true)
    fsUserFile(hostFile = "~/.ssh/gm5-secret", content = "s\n", mode = "0600")
    envUserVariable(name = "GM5_EDITOR", value = "nvim")
    envUserPath(entries = "~/.local/bin, ~/gm5/bin")
    when macos():
      homebrewCask(name = "gm5-cask")
    fsManagedBlock(hostFile = "~/.bashrc", blockId = "gm5",
      content = "export GM5=1")
