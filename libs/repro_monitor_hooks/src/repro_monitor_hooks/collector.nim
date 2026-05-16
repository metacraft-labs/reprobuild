import repro_monitor_shim

proc finalizeMonitorFragments*(fragmentDir, outputPath: string): MonitorDepFile =
  mergeFragments(fragmentDir, outputPath)
