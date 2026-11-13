systemd.systemUnit {
  name = "plain.service"
  content = "[Unit]
Description=x

[Service]
User=a
ExecStart=/repro/store/prefixes/svc/1.0/bin/svc --serve

[Install]
WantedBy=multi-user.target
"
  hardening = "serviceFloor"
}

systemd.systemUnit {
  name = "dyn.service"
  content = "[Unit]
Description=x

[Service]
RuntimeDirectory=svc-rt
StateDirectory=svc-st
ExecStart=/repro/store/prefixes/svc/1.0/bin/svc

[Install]
WantedBy=multi-user.target
"
  hardening = "serviceFloor"
}

systemd.systemUnit {
  name = "jit.service"
  content = "[Unit]
Description=x

[Service]
User=a
ExecStart=/repro/store/prefixes/svc/1.0/bin/svc

[Install]
WantedBy=multi-user.target
"
  hardening = "serviceFloor"
  floorExceptions = [
    "MemoryDenyWriteExecute: a JIT"
  ]
}

systemd.systemUnit {
  name = "cont.service"
  content = "[Unit]
Description=x

[Service]
User=a
ExecStart=/repro/store/prefixes/svc/1.0/bin/svc \\
  --flag
Environment=A=1 \\

[Install]
WantedBy=multi-user.target
"
  hardening = "serviceFloor"
}

systemd.systemUnit {
  name = "root.service"
  content = "[Unit]
Description=x

[Service]
User=root
ExecStart=/repro/store/prefixes/svc/1.0/bin/svc

[Install]
WantedBy=multi-user.target
"
  hardening = "serviceFloor"
}
