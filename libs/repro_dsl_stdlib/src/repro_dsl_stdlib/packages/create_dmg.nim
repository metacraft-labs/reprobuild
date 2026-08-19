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
        pos dmg is string
        pos src is string
        outputs dmg


let create_dmgCatalog* = seq[VersionedProvisioning].default


