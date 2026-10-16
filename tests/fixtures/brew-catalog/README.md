# Homebrew contribution-records fixture

A published contribution-records document (the format
`repro_interface_artifacts/contribution_records` renders and
`reprobuild-brew-packages` commits) with two Homebrew bridge records over
packages of the neutral intent export (`../intent-exports/neutral`):

- `ripgrep` -> cask `gm5b-ripgrep` (claimed on darwin systems only);
- `gm5-home-pc-only` -> formula `gm5b-only` from tap `example/tap` (claimed on
  darwin and Linux).

The flake check `lib-home-manager` builds the Home Manager intent module over
the pinned Nix catalog plus this document, so the module's DEFAULT
`homebrew.realizationOf` hook (`reprobuild.lib.brewRealizationOf`) is what
moves those packages into the token lists. Synthetic because the real
catalog maps application tokens, none of which the neutral fixture names;
the real catalog's records are checked by `lib-tests` and by the catalog's
own tests.
