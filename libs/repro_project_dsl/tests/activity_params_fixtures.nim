## Shared-Development-Services L2 test fixture for
## ``t_activity_params_reach_the_services_they_declare``.
##
## A package whose ``devEnv:`` block carries BOTH surfaces: the bare
## ``activity "default"`` string form that ``proc activity(name: string)``
## has always handled and L2's constructor form with typed parameters, an
## inner ``config:`` block, services in the body and ``enable`` call sites.
##
## Lives in a separate module from the test main for the same reason
## ``service_fragment_fixtures.nim`` does: under
## ``-d:reproProviderMode`` the ``package`` macro emits a
## ``runPackageProvider`` shim guarded on ``isMainModule``, which would
## take over the test binary. Not named ``t_*`` / ``test_*``, so
## ``scripts/generate_test_edges.nim`` does not register it as a test
## binary of its own.

import repro_project_dsl

type
  DemoDb* = object
    ## A capability type in the shape ``Package-Model.md`` §"Capability
    ## types and platform modules" specifies: "Capability types are plain
    ## Nim object types". Declared here rather than imported so the test
    ## owns both halves of the typing claim — the type's members and the
    ## activity's use of them.
    connectionString*: string
    host*: string
    port*: int

const
  DemoDbValue* = DemoDb(connectionString: "postgres://localhost/demo",
                        host: "127.0.0.1", port: 5432)
  ApiConfigPath* = "etc/api/config.toml"
  WorkerConfigPath* = "etc/worker/config.toml"
  ApiRenderActionId* = "render-api-config"
  WorkerRenderActionId* = "render-worker-config"
  ApiIssuer* = "https://login.example.test"

package activityParamsPkg:
  executable apiBin:
    build:
      output("bin/api")

  executable workerBin:
    build:
      output("bin/worker")

  devEnv:
    ## The pre-L2 surface, untouched. L2's gate requires it to keep
    ## working, and ten real activities across
    ## ``isonim-platform/repro.nim`` and ``codetracer/repro.nim`` are
    ## spelled exactly this way.
    activity "default"

    ## The pre-L1 service surface, also untouched, so this fixture shows
    ## all three generations of the surface coexisting.
    servicePlaceholder "legacy-stack",
      metadata = """{"schemaId": "reprobuild.dev-session.service.v1"}""",
      activities = ["default"]

    activity api(db: DemoDb):
      ## Long-running typed API server. Consumes a database handle and
      ## renders its configuration from the ``config:`` values below.
      config:
        ## TCP port the API server binds.
        port: int = 8080
        ## The externally visible issuer. Declared with NO default, so
        ## the ``enable`` site must supply it — the ``externalDomain:
        ## string`` shape of ``Shared-Development-Services.md`` §9.1.
        issuer: string

      let cfg = renderConfigFile(ApiConfigPath,
        "port = " & $port & "\nissuer = \"" & issuer & "\"\n" &
          "url = \"" & db.connectionString & "\"\n",
        actionId = ApiRenderActionId,
        packageName = "activityParamsPkg")

      service api:
        executable apiBin
        args "--config", cfg.path, "--host", db.host, "--port", $port
        on change cfg:
          sendSignal "SIGHUP"

    activity worker(db: DemoDb):
      ## THE CONTROL's activity. Same shape as ``api`` in every respect
      ## that matters, enabled below with NO overrides, so its rendered
      ## configuration must hold the ``config:`` DEFAULT. Without it, an
      ## implementation that ignored the defaults and always wrote the
      ## override would pass every positive assertion in the test.
      config:
        port: int = 7000

      let cfg = renderConfigFile(WorkerConfigPath,
        "port = " & $port & "\nhost = \"" & db.host & "\"\n",
        actionId = WorkerRenderActionId,
        packageName = "activityParamsPkg")

      service worker:
        executable workerBin
        args "--config", cfg.path, "--port", $port

    ## The parameterless form ``Package-Model.md`` spells as "``activity
    ## <name>: <body>``" — an ident head rather than a string, so it is
    ## the macro surface and not the proc's.
    activity solo:
      service solo:
        executable workerBin
        args "--solo"

    enable api(db = DemoDbValue):
      port 9090
      issuer ApiIssuer

    enable worker(db = DemoDbValue)

    enable solo

export buildActivityParamsPkgPackage
export devEnvActivityParamsPkgPackage
