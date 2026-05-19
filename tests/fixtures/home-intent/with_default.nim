import repro/profile

profile "alice":
  activity default:
    neovim
    tmux
    starship

  activity develop_software:
    git
    gh
    delta

  hosts:
    "dev-laptop": [develop_software]
