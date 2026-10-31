import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema


package `create-dmg`:
  provisioning:
    nixPackage "nixpkgs#create-dmg", executablePath = "bin/create-dmg",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash,
      packageId = "create-dmg@1.2.2"

  executable `create-dmg`:
    cli:
      call:
        flag volname is string
        flag background is string
        flag windowPos is seq[string], alias = "--window-pos"
        flag windowSize is seq[string], alias = "--window-size"
        flag iconSize is string, alias = "--icon-size"
        flag icon is seq[string], alias = "--icon"
        flag appDropLink is seq[string], alias = "--app-drop-link"
        boolFlag sandboxSafe is bool, alias = "--sandbox-safe"
        # The image is the edge's OUTPUT (`role = output`): the engine checks
        # it after the run and caches it, and only an output may be removed
        # before the run (below).
        pos dmg is string, role = output
        pos src is string
        outputs dmg
        # create-dmg 1.2.2 ends with `hdiutil convert ... -o <dmg>`, which
        # refuses an existing file (`hdiutil: convert failed - File exists`),
        # so without this every re-run after an input change failed because
        # the previous run had succeeded. The engine removes the image before
        # the edge runs, without following a link -- the `rm -f` a shell
        # script calling create-dmg has to open with.
        removeBeforeRun dmg
