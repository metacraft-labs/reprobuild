import repro_project_dsl

package libfoo:
  config:
    ## Enable TLS support.
    enableTls: variant bool = true
    ## Which optimisation profile the library is built with.
    profile: variant string = "release"

  build:
    discard
