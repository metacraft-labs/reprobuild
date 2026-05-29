## M83 Phase A fixture: exercises the predicate combinators
## (`and`/`or`/`not`/`host == ...`) inside activity-body `when`
## guards. Validates that the apply-time canonical-string predicate
## emitted into the ProfileIntent matches the canonicalize rules in
## `repro_home_intent/predicate.nim`.

import repro_profile

profile "homePreds":
  activity default:
    neovim

    when windows() and arm64():
      arm_specific_pkg

    when linux() or macos():
      cross_unix_pkg

    when not windows():
      non_windows_pkg

    when host() == "dev-laptop":
      laptop_only_pkg
