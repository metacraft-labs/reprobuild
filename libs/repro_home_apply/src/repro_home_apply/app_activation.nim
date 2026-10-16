## GM4c — activating realized macOS application bundles.
##
## A package whose selected realization has the ``app-bundle`` install shape
## realizes a verified ``<Name>.app`` at the root of its store prefix
## (``builtin_adapter``). The apply places a COPY of it in the user's
## Applications directory through the home resource lifecycle, so the
## placement is planned, drift-checked, recorded in the generation and
## reversed by rollback like every other home-scope object. This module
## turns the realized records into those ``macos.appBundle`` resources; the
## driver that places them is ``repro_home_resources/drivers/app_bundle``.
## Store-And-Installation-Layout.md § macOS Application Bundles.
##
## Address convention (stable across applies, so a re-apply of the same
## bundle is a lifecycle no-op): ``home.package.<package>.app``. Like the
## ``home.package.<id>.bin`` PATH resources of ``env_binding``, the
## ``home.package.`` namespace is reserved for synthesized resources.


import repro_home_resources

import ./realize

# The address helpers (`appBundleAddress`, `packageIdOfAppBundleAddress`)
# live in `repro_home_resources/concerns`, beside the concern classification
# that reads the same namespace.

proc appBundleActivationResource*(record: RealizedRecord;
                                  applicationsDir: string): Resource =
  ## The ``macos.appBundle`` resource that places ``record``'s bundle in
  ## ``applicationsDir``. ``record`` must carry an app-bundle realization.
  doAssert record.appBundle.storeBundlePath.len > 0,
    "appBundleActivationResource needs a realized app bundle"
  Resource(
    kind: rkMacosAppBundle,
    address: appBundleAddress(record.packageId),
    lifecyclePolicy: lpDefault,
    appBundleSource: record.appBundle.storeBundlePath,
    appBundleTargetDir: applicationsDir,
    appBundleName: record.appBundle.bundleName,
    appBundleMainPath: record.appBundle.mainBundlePath,
    appBundleExpectation: record.appBundle.expectation,
    appBundleTrust: record.appBundle.trust,
    appBundleIdentity: record.appBundle.identity)

proc planAppBundleActivations*(realized: seq[RealizedRecord];
                               homeDir: string): seq[Resource] =
  ## One home-scope placement per realized application bundle, in
  ## ``~/Applications`` (spec P3: unelevated, so home scope). Order follows
  ## ``realized``, which is the profile's package order.
  let target = applicationsDir(apsHome, homeDir)
  for record in realized:
    if record.appBundle.storeBundlePath.len > 0:
      result.add(appBundleActivationResource(record, target))
