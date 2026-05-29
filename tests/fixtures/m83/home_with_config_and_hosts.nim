## M83 Phase A fixture: exercises `config:` and `hosts:` sub-blocks
## in addition to multiple activities. Validates that the macro
## collects all four section types into a single ProfileIntent.

import repro_profile

profile "homeFull":
  activity default:
    neovim
    tmux

  activity develop_software:
    git
    gh

  config:
    git:
      userName = "Zahary"
      userEmail = "z@example.com"
    tmux:
      mouse = true

  hosts:
    "dev-laptop": [default, develop_software]
    "ci": [default]
