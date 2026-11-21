# A narrow wrapper-boundary fixture: the executable payload only forwards argv.
# Canonical package postFixup and makeWrapper are unchanged. The host-side
# checker passes the real owned-daemon test binary through these wrappers, so
# daemon selection, spawning and lifetime still use production code.
{ reprobuild, runquotaTools, bash, coreutils }:
assert (builtins.functionArgs (import ./pkgs/by-name/re/reprobuild/package.nix)).runquotaTools == false;
reprobuild.overrideAttrs (old: {
  pname = "reprobuild-runquota-runtime-wrapper-fixture";
  buildPhase = ''
    mkdir -p build/bin build/lib
    for name in repro reprobuild; do
      cat > "build/bin/$name" <<'SCRIPT'
#!${bash}/bin/bash
exec "$@"
SCRIPT
      chmod +x "build/bin/$name"
    done
  '';
  # Execute the generated wrappers, so the Nix check enforces real default
  # and override behavior even without the Linux /proc selector audit.
  postFixup = old.postFixup + ''
    ${coreutils}/bin/env -u RUNQUOTAD_BIN -u RUNQUOTA_BIN \
      "$out/bin/repro" ${bash}/bin/bash -e -c '
        test "$RUNQUOTAD_BIN" = "$1"
        test "$RUNQUOTA_BIN" = "$2"
        test -x "$RUNQUOTAD_BIN"
        test -x "$RUNQUOTA_BIN"
      ' wrapper-defaults ${runquotaTools}/bin/runquotad ${runquotaTools}/bin/runquota
    RUNQUOTAD_BIN=${bash}/bin/bash RUNQUOTA_BIN=${coreutils}/bin/true \
      "$out/bin/repro" ${bash}/bin/bash -e -c '
        test "$RUNQUOTAD_BIN" = "$1"
        test "$RUNQUOTA_BIN" = "$2"
      ' wrapper-overrides ${bash}/bin/bash ${coreutils}/bin/true
  '';
})
