import repro/profile

profile "grace":
  activity default:
    neovim
    tmux

  activity photography:
    exiftool

  hosts:
    "dev-laptop": [photography]
    "other-machine": []
