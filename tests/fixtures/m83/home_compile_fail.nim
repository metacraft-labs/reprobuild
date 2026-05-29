## M83 Phase C1 fixture: a deliberately-broken profile that fails to
## compile. The `nope_undefined_predicate` identifier is not declared
## anywhere in `repro_profile` or stdlib, so `nim c` emits a clean
## "undeclared identifier" error. Drives the compile-failure path of
## `repro profile build`.

import repro_profile

profile "homeCompileFail":
  activity default:
    neovim
    when nope_undefined_predicate():
      tmux
