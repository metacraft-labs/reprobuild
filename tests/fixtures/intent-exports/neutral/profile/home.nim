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
    when macos() and arm64():
      `gm5-mac-arm-tool`

  activity desktop:
    busybox
    when host() == "home-pc":
      `gm5-home-pc-only`

  activity cli:
    ripgrep

  config:
    git:
      when macos():
        credentialHelper = "osxkeychain"
      else:
        credentialHelper = "libsecret"

  hosts:
    "m1": [desktop]
    "home-pc": [desktop, cli]

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
