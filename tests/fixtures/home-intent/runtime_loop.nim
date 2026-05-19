import repro/profile

profile "eve":
  activity default:
    for pkg in @["neovim", "tmux"]:
      pkg
