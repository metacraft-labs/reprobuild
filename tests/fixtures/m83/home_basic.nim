## M83 Phase A fixture: a minimal home profile with one activity, two
## packages, and a `when windows:` guarded body. Compiled + run by
## `tests/e2e/m83/t_e2e_repro_profile_compile.nim` via `nim c -r`.

import repro_profile

profile "homeBasic":
  activity default:
    neovim
    tmux
    when windows():
      `windows-terminal`
