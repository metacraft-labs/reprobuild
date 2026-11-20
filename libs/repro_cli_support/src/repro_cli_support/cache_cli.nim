## ``repro cache <subcommand>``: the single-entry binary-cache client, from
## the configuration repro's generated parser reads.
##
## Its own module so that the binary-cache integration tests' driver
## (``libs/repro_binary_cache_client/tests/repro_binary_cache_client_cli``)
## runs ``repro cache`` itself, the declared command line and the same
## handlers, without linking the engine. Each subcommand calls the SAME
## shared ``substituteInProcess`` + HTTP-publish machinery ``repro build``
## uses (including default-untrusted trust).

import repro_binary_cache_client/cli_dispatch as bcCliDispatch

import ./cli_program

proc cacheIdentityValuesOf*[T](c: T): bcCliDispatch.CacheIdentityValues =
  ## The identity flags of `repro cache publish|derive-key|gen-key`.
  bcCliDispatch.CacheIdentityValues(packageName: c.packageName,
    packageVersion: c.packageVersion, platformCpu: c.platformCpu,
    platformOs: c.platformOs, platformAbi: c.platformAbi,
    platformLibc: c.platformLibc, toolchainName: c.toolchainName,
    toolchainVersion: c.toolchainVersion,
    toolchainHostLdSo: c.toolchainHostLdso,
    toolchainExtra: c.toolchainExtra, providerRevision: c.providerRevision,
    deps: c.dep, options: c.option)

proc runCacheCommand*(conf: ReproCommandLineCache): int =
  ## ``repro cache <subcommand>`` from its configuration. A malformed
  ## `--option` is a usage error (exit 2); another malformed value (an
  ## entry key, a CPU family) is reported as an error (exit 1).
  try:
    case conf.command
    of ReproCommandLineCacheCommand.call:
      # `repro cache` alone prints its help.
      printReproHelp(["cache"])
      return 0
    of ReproCommandLineCacheCommand.help:
      printReproNamespaceHelp("cache", conf.help.topic)
      return 0
    of ReproCommandLineCacheCommand.lookup:
      return bcCliDispatch.cacheLookup(conf.lookup.entryKey)
    of ReproCommandLineCacheCommand.substitute:
      return bcCliDispatch.cacheSubstitute(conf.substitute.entryKey,
        conf.substitute.outDir)
    of ReproCommandLineCacheCommand.publish:
      let c = conf.publish
      return bcCliDispatch.cachePublish(c.entryKey, c.prefixDir,
        cacheIdentityValuesOf(c))
    of ReproCommandLineCacheCommand.deriveKey:
      return bcCliDispatch.cacheDeriveKey(cacheIdentityValuesOf(
        conf.deriveKey))
    of ReproCommandLineCacheCommand.genKey:
      return bcCliDispatch.cacheGenKey()
  except bcCliDispatch.CacheUsageError as err:
    stderr.writeLine(err.msg)
    return 2
  except CatchableError as err:
    stderr.writeLine("repro cache: error: " & err.msg)
    return 1

proc runReproCacheArgs*(args: openArray[string]): int =
  ## ``repro cache <args>``: ``args`` (the words after ``cache``) parsed by
  ## the generated parser with the ``cache`` command in front, and run.
  runReproArgs(@["cache"] & @args, proc (conf: ReproCommandLine): int =
    runCacheCommand(conf.cache))

proc cacheIdentityOfFlags*(flags: openArray[string]):
    bcCliDispatch.CacheIdentityValues {.raises: [CatchableError].} =
  ## The identity values `repro cache derive-key <flags>` reads from its
  ## identity flags, through the generated parser: what a producer that
  ## renders those flags (`repro infra cache-keys`) checks they round-trip
  ## to. Raises ``CliUsageError`` for flags the command line refuses.
  let conf = ReproCommandLine.load(@["cache", "derive-key"] & @flags)
  cacheIdentityValuesOf(conf.cache.deriveKey)
