## M83 Phase C fixture: a system profile that declares one
## `windows.scheduledTask` per `ScheduleKind` variant. The e2e gate
## proves all five schedule shapes survive the ProfileIntent -> JSON
## -> parse round-trip without a Windows host.

import repro_profile

profile "systemWindowsScheduledTask":
  resources:
    # 1. sskOnBoot — fires at system boot with a configurable delay.
    windowsScheduledTask(
      taskName = "\\Reprobuild\\OnBootTask",
      executable = "C:\\actions-runner\\bin\\Runner.Listener.exe",
      arguments = @["--unattended"],
      workingDirectory = "C:\\actions-runner",
      schedule = scheduleOnBoot(delaySeconds = 30),
      address = "onBootTask")

    # 2. sskOnLogon — fires when a specific user logs on. `runAsUser`
    # is a non-SYSTEM principal, so the principal-dependent default of
    # `runWithHighestPrivileges = false` applies automatically — no
    # explicit setting needed at the template surface.
    windowsScheduledTask(
      taskName = "\\Reprobuild\\OnLogonTask",
      executable = "C:\\bin\\hook.exe",
      schedule = scheduleOnLogon(forUser = "DOMAIN\\runner"),
      runAsUser = "DOMAIN\\runner",
      address = "onLogonTask")

    # 3. sskOnce — fires once at the given ISO-8601 timestamp.
    windowsScheduledTask(
      taskName = "\\Reprobuild\\OnceTask",
      executable = "C:\\bin\\once.exe",
      schedule = scheduleOnce(runAt = "2030-01-01T08:00:00Z"),
      address = "onceTask")

    # 4. sskDaily — fires daily at HH:MM.
    windowsScheduledTask(
      taskName = "\\Reprobuild\\DailyTask",
      executable = "C:\\bin\\daily.exe",
      schedule = scheduleDaily(timeOfDay = "08:30"),
      address = "dailyTask")

    # 5. sskInterval — fires every N minutes (optional start).
    windowsScheduledTask(
      taskName = "\\Reprobuild\\IntervalTask",
      executable = "C:\\bin\\hb.exe",
      schedule = scheduleInterval(everyMinutes = 15,
        startAt = "2030-01-01T00:00:00Z"),
      enabled = false,
      address = "intervalTask")
