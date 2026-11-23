import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/types/executable

package `tree-sitter`:
  provisioning:
    nixPackage "nixpkgs#tree-sitter", executablePath = "bin/tree-sitter",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

  executable treeSitter:
    name: "tree-sitter"
    cli:
      dependencyPolicy automaticMonitor
      # JavaScript grammars use node by default; JSON grammars do not.
      # As with other package sub-tools, recipes declare node in uses to
      # place its resolved executable on this edge's PATH.
      subTools "node"

      # https://tree-sitter.github.io/tree-sitter/cli/generate.html
      # Explicit paths avoid the CLI's implicit working-directory defaults.
      subcmd "generate":
        flag outputDir is string,
          alias = "--output",
          format = separate,
          role = output,
          required = true
        flag abi is int,
          alias = "--abi",
          format = separate
        pos grammar is string,
          position = 0,
          role = input,
          required = true
        outputs outputDir
