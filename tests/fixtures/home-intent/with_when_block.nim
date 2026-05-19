import repro/profile

profile "carol":
  activity default:
    neovim
    when arm64 and windows:
      raspi-tools
