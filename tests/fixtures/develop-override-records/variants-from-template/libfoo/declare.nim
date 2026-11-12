import repro_project_dsl

template declareTlsPackage*(name: untyped) =
  package name:
    config:
      ## Enable TLS support.
      enableTls: variant bool = true
