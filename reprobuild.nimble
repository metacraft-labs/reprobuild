version = "0.1.0"
author = "Metacraft Labs"
description = "Reprobuild build system"
license = "MIT"
requires "nim >= 2.2.0"

task build, "Build all M0 application entry points":
  exec "just build"

task test, "Run the M0 test suite":
  exec "just test"
