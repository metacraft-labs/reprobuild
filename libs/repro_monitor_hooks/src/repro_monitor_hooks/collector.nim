import repro_monitor_depfile

proc finalizeMonitorFragments*(fragmentDir, outputPath: string): MonitorDepFile =
  mergeFragments(fragmentDir, outputPath)
