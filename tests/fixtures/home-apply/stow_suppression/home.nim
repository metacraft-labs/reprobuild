import repro/profile

profile "stow-suppression-gate":
  activity default:
    git-config

  config:
    git-config:
      userEmail = "config-block@example.com"
