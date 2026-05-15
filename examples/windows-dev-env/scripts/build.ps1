$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path build | Out-Null
cl /nologo src\hello_windows.c /Fe:build\hello-windows.exe
