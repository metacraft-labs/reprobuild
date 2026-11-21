## Shared-Development-Services F1 fixture: a `devEnv:` activity that
## renders its service's configuration AS A BUILD OUTPUT, and a control
## that renders one NOBODY CONSUMES.
##
## WHAT F1 MEASURED. L9's F1 clause ("its rendered configuration and
## steps are build outputs") is NOT MET, and the measurement is quoted
## in the milestone: three `renderConfigFile` calls were written in the
## activity body with `cfg.path` on the service's argv -- "which is
## exactly what `Package-Model.md` §Collections and §9.1 write" -- and
## then "`DevEnvResult`, the record a dev-env entry point returns, has
## NO actions field ..., so an action registered while the `devEnv:`
## body runs reaches nothing. Observed end to end: `repro up --activity
## sso` reported the session up, the daemon reported `Materialise ok`,
## and `etc/sso/` did not exist -- the path reached argv and the file
## never did."
##
## So this fixture writes exactly the recipe F1 said could not be
## written, and the test beside it reads whether the action now reaches
## the caller.
##
## In a separate module from the test main for the reason L5's, L8's and
## D-SS11's fixtures give: under `-d:reproProviderMode` the `package`
## macro emits a `runPackageProvider` shim guarded on `isMainModule`,
## which would take over the test binary. Not named `t_*` / `test_*`, so
## `scripts/generate_test_edges.nim` does not register it as a test
## binary of its own.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## Real `package` blocks, a real `devEnv:` body, the real
## `renderConfigFile` (which registers a real `fs.writeText` edge
## through the real `ReproFs`), and a real `service` consuming the
## returned handle's path on argv. Nothing stubs the action registry.

import repro_project_dsl

const
  Dssf1ConsumedPath* = "etc/dssf1/consumed.yaml"
    ## The rendered file a service NAMES on its argv.
  Dssf1OrphanPath* = "etc/dssf1/orphan.yaml"
    ## The rendered file NOTHING names. The control for the
    ## produced-and-never-consumed diagnostic: without it, "no error
    ## diagnostic was reported" could not be told from "the check never
    ## ran".
  Dssf1ConsumedActionId* = "fs-writeText-etc-2fdssf1-2fconsumed.yaml"
    ## `renderConfigFile`'s documented default id, "a function of the
    ## path alone -- so the id is stable across runs", with the path's
    ## separators percent-escaped by the id sanitiser (`/` -> `-2f`).
    ##
    ## SPELLED OUT RATHER THAN DERIVED, and the first version of this
    ## constant was WRONG -- it guessed `fs-writeText-etc-dssf1-...`,
    ## without the escapes -- which is the argument for spelling it:
    ## the case failed and named both texts instead of asserting
    ## whatever the implementation happened to produce.
  Dssf1OrphanActionId* = "fs-writeText-etc-2fdssf1-2forphan.yaml"
  Dssf1ConsumerName* = "dssf1Consumer"
  Dssf1OrphanName* = "dssf1Orphan"
  Dssf1QuietName* = "dssf1Quiet"
  Dssf1ServiceName* = "api"

package dssf1Consumer:
  ## THE RECIPE F1 SAID COULD NOT BE WRITTEN: the configuration is a
  ## build output and the service consumes it by reference on argv.
  devEnv:
    activity api():
      service api:
        executable executableAtPath("/bin/sh")
        args "-c", "true"
        args renderConfigFile("etc/dssf1/consumed.yaml",
          "listen: 127.0.0.1:19443\n").path
        identity stable "com.example.dssf1.consumed"
        scope project

    enable api

package dssf1Orphan:
  ## THE CONTROL: the same render, consumed by nothing.
  devEnv:
    activity api():
      service api:
        executable executableAtPath("/bin/sh")
        args "-c", "true"
        identity stable "com.example.dssf1.orphan"
        scope project

      ## Rendered AFTER the service, and deliberately not referenced.
      ## This is the shape the campaign's dominant defect takes: a
      ## construct declared, apparently wired, and reaching nothing.
      discard renderConfigFile("etc/dssf1/orphan.yaml",
        "listen: 127.0.0.1:19444\n")

    enable api

package dssf1Quiet:
  ## A dev-env that renders NOTHING, so "no actions" is a property of
  ## not writing one rather than of the channel being inert.
  devEnv:
    activity api():
      service api:
        executable executableAtPath("/bin/sh")
        args "-c", "true"
        identity stable "com.example.dssf1.quiet"
        scope project

    enable api
