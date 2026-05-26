import repro_project_dsl

package gcc:
  provisioning:
    nixPackage "nixpkgs#gcc", executablePath = "bin/gcc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

  executable gcc:
    cli:
      dependencyPolicy automaticMonitor

      call:
        boolFlag pic is bool, alias = "-fPIC"
        boolFlag debug3 is bool, alias = "-g3"
        boolFlag compileOnly is bool, alias = "-c"
        flag includes is seq[string],
          alias = "-include",
          role = input,
          repeated = true
        flag output is string,
          alias = "-o",
          role = output,
          required = true
        pos source is string,
          role = input,
          position = 0
