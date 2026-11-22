## GM6 fixture: the Reprobuild half of the equivalence pair the flake check
## `lib-home-equivalence` compares with a Home Manager configuration written
## to say the same thing (nix/tests/home-equivalence.nix). See ../README.md.
import repro_profile

profile "gm6Equivalence":
  activity default:
    bash
    cmake

  activity cli:
    when linux():
      patchelf

  hosts:
    "gm6-host": [cli]

  resources:
    fsUserFile(hostFile = "~/.config/gm6/app.conf", content = "answer = 42\n")
    envUserVariable(name = "GM6_EDITOR", value = "nvim")
    # The host's home spelled by its absolute path: `repro home facts
    # --home-dir` (the configuration's `home.homeDirectory`) names it
    # `~/.local/bin`, as Home Manager names its `$HOME/.local/bin`.
    when linux():
      envUserPath(entries = "/home/gm6/.local/bin")
    when macos():
      envUserPath(entries = "/Users/gm6/.local/bin")
