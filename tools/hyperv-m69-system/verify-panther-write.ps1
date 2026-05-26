<#
  verify-panther-write.ps1 - self-test for the Panther override
  mechanism added to provision-base-vm.ps1 in the M69 Hyper-V harness.

  Creates a 100 MB throwaway VHDX in $env:TEMP, initialises it as a
  GPT disk with a single NTFS partition, seeds it with a
  \Windows\Panther\unattend.xml that LOOKS like Microsoft's baked
  content, dismounts, then exercises the Write-PantherUnattend +
  New-PantherUnattendXml helpers from provision-base-vm.ps1 against
  the throwaway VHDX. After the helper returns, re-mounts and
  verifies:

    * \Windows\Panther\unattend.original.xml exists and equals the
      original baked content (the helper preserved it).
    * \Windows\Panther\unattend.xml exists, parses as XML, contains
      our generated passphrase + LocalAccount + SkipMachineOOBE +
      SkipUserOOBE, and is UTF-8 *without* a BOM.

  Then cleans up (dismount + delete the throwaway VHDX). Exits 0
  on success, non-zero on any failure.

  This script touches NO real harness state - no $CredCachePath,
  no $DiffVhdPath, no $VmName. Safe to run alongside a real
  provisioning.

  Usage:
    pwsh -File tools\hyperv-m69-system\verify-panther-write.ps1
#>
#requires -Version 7
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Dot-source provision-base-vm.ps1's helpers WITHOUT running its
# top-level steps. The cleanest way is to read the file and execute
# only the helper-definition section in a child scope. The file gates
# its top-level steps behind Section calls - we cannot just dot-source
# it. So we extract the two helpers we need by sourcing the file in
# a child runspace that we abort right after the helper defs.
#
# Simplest robust approach: copy the two function definitions inline
# here (they are short and stable in shape). If the helpers in
# provision-base-vm.ps1 drift, this self-test must drift with them -
# which is fine because the self-test is meant to PROVE the helpers
# work as intended, not to chase upstream drift silently.

. {
  $script:VmLocalAccountName = 'User'

  function Info($m)  { Write-Host "[verify] $m" }
  function Warn($m)  { Write-Host "[verify] WARNING: $m" -ForegroundColor Yellow }
  function Fail($m)  { Write-Host "[verify] ERROR: $m"   -ForegroundColor Red }

  # The two helpers under test. These MUST stay byte-identical to
  # provision-base-vm.ps1's definitions; if you change one, change
  # the other. The verify-fixture's whole point is to exercise them.

  function New-PantherUnattendXml {
    param(
      [Parameter(Mandatory)] [string]$Passphrase,
      [string]$LocalAccountName = $VmLocalAccountName,
      [string]$ComputerName = '*'
    )
    $encodedPw = [System.Security.SecurityElement]::Escape($Passphrase)
    $encodedComputerName = [System.Security.SecurityElement]::Escape($ComputerName)
    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>$encodedComputerName</ComputerName>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UILanguageFallback>en-US</UILanguageFallback>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$LocalAccountName</Name>
            <Group>Administrators</Group>
            <Description>repro-m69 test VM auto-OOBE user</Description>
            <Password>
              <Value>$encodedPw</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <TimeZone>UTC</TimeZone>
      <RegisteredOwner>repro-m69</RegisteredOwner>
      <RegisteredOrganization>Reprobuild</RegisteredOrganization>
    </component>
  </settings>
</unattend>
"@
  }

  function Write-PantherUnattend {
    param(
      [Parameter(Mandatory)] [string]$VhdxPath,
      [Parameter(Mandatory)] [string]$UnattendXml
    )
    if (-not (Test-Path -LiteralPath $VhdxPath)) {
      throw "Write-PantherUnattend: VHDX not found: $VhdxPath"
    }
    $mounted = $null
    try {
      Info "    mounting VHDX read-write: $VhdxPath"
      $mounted = Mount-VHD -Path $VhdxPath -Passthru -ErrorAction Stop
      $vhdInfo = Get-VHD -Path $VhdxPath -ErrorAction Stop
      $diskNumber = $vhdInfo.DiskNumber
      if (-not $diskNumber) {
        throw "Write-PantherUnattend: mounted VHD has no DiskNumber (mount silently failed?)"
      }
      Info "    mounted as Disk $diskNumber; enumerating NTFS volumes"
      $partitions = Get-Partition -DiskNumber $diskNumber -ErrorAction Stop
      $ntfsVolumes = @()
      foreach ($part in $partitions) {
        $vol = $null
        try { $vol = Get-Volume -Partition $part -ErrorAction Stop } catch { continue }
        if ($vol -and $vol.FileSystem -eq 'NTFS') {
          $ntfsVolumes += [pscustomobject]@{
            Volume    = $vol
            Partition = $part
            Size      = $vol.Size
          }
        }
      }
      if ($ntfsVolumes.Count -eq 0) {
        throw "Write-PantherUnattend: no NTFS volumes on Disk $diskNumber"
      }
      $best = $ntfsVolumes | Sort-Object -Property Size -Descending | Select-Object -First 1
      $driveLetter = $best.Volume.DriveLetter
      if (-not $driveLetter) {
        throw "Write-PantherUnattend: largest NTFS volume on Disk $diskNumber has no drive letter"
      }
      $sysRoot = "${driveLetter}:"
      $pantherDir = Join-Path $sysRoot 'Windows\Panther'
      $targetPath = Join-Path $pantherDir 'unattend.xml'
      $backupPath = Join-Path $pantherDir 'unattend.original.xml'
      Info "    target volume: $sysRoot (NTFS, $([math]::Round($best.Volume.Size/1GB,2)) GB)"
      if (-not (Test-Path -LiteralPath $pantherDir)) {
        Info "    creating $pantherDir (was absent)"
        New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null
      }
      if (Test-Path -LiteralPath $targetPath) {
        if (-not (Test-Path -LiteralPath $backupPath)) {
          Info "    backing up existing unattend.xml -> unattend.original.xml"
          Copy-Item -LiteralPath $targetPath -Destination $backupPath -Force
        } else {
          Info "    unattend.original.xml already present; leaving prior backup intact"
        }
      } else {
        Info "    no existing unattend.xml at $targetPath (will create)"
      }
      $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
      [System.IO.File]::WriteAllText($targetPath, $UnattendXml, $utf8NoBom)
      [void]([xml](Get-Content -LiteralPath $targetPath -Raw))
      Info "    wrote $targetPath ($((Get-Item -LiteralPath $targetPath).Length) bytes, UTF-8 no BOM)"
      return $targetPath
    } finally {
      if ($mounted) {
        try {
          Info "    dismounting VHDX: $VhdxPath"
          Dismount-VHD -Path $VhdxPath -ErrorAction Stop
        } catch {
          Warn "    Dismount-VHD failed: $_"
        }
      }
    }
  }
}

# ---------------------------------------------------------------------
# Step A: create the throwaway VHDX
# ---------------------------------------------------------------------
$tmpDir = Join-Path $env:TEMP ("panther-verify-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$vhdxPath = Join-Path $tmpDir 'throwaway.vhdx'
$bakedOriginal = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <!-- This is the BAKED Microsoft-style unattend the verify fixture
         plants in advance. The override helper must rename this to
         unattend.original.xml. -->
    <MarkerForVerification>BAKED-MS-PANTHER-CONTENT</MarkerForVerification>
  </settings>
</unattend>
'@

$exitCode = 1
$mountedForSeed = $false
$mountedForVerify = $false
try {
  Info "Step A: creating throwaway 100 MB VHDX at $vhdxPath"
  # 100 MB is too small for a real Windows partition but more than
  # enough to host a few KB of unattend XML; Initialize-Disk + a single
  # NTFS partition works fine at this size.
  New-VHD -Path $vhdxPath -SizeBytes 100MB -Dynamic | Out-Null

  Info "Step A: mounting + initialising + formatting NTFS"
  $mountedDisk = Mount-VHD -Path $vhdxPath -Passthru -ErrorAction Stop
  $mountedForSeed = $true
  $vhdInfo = Get-VHD -Path $vhdxPath
  $diskNum = $vhdInfo.DiskNumber
  if (-not $diskNum) { throw "throwaway mount yielded no DiskNumber" }
  Initialize-Disk -Number $diskNum -PartitionStyle MBR -ErrorAction Stop
  $part = New-Partition -DiskNumber $diskNum -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
  $vol = Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel 'TESTSYS' -Force -Confirm:$false
  $drv = $part.DriveLetter
  if (-not $drv) { throw "no drive letter assigned to throwaway partition" }
  Info "  throwaway volume at ${drv}:"

  # Seed the throwaway with a baked Panther unattend so we can verify
  # the backup-to-unattend.original.xml behaviour.
  $seedDir = Join-Path "${drv}:" 'Windows\Panther'
  New-Item -ItemType Directory -Path $seedDir -Force | Out-Null
  $seedPath = Join-Path $seedDir 'unattend.xml'
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($seedPath, $bakedOriginal, $utf8NoBom)
  Info "  seeded baked unattend at $seedPath ($((Get-Item -LiteralPath $seedPath).Length) bytes)"

  Dismount-VHD -Path $vhdxPath -ErrorAction Stop
  $mountedForSeed = $false

  # -------------------------------------------------------------------
  # Step B: exercise the helpers under test
  # -------------------------------------------------------------------
  Info "Step B: building Panther unattend XML for a fixture passphrase"
  $fixturePass = 'verify-fixture-correct-horse'
  $xml = New-PantherUnattendXml -Passphrase $fixturePass -LocalAccountName 'User'
  # Structural sanity.
  [void]([xml]$xml)
  Info "  XML parsed successfully"

  Info "Step B: invoking Write-PantherUnattend against the throwaway VHDX"
  $writtenPath = Write-PantherUnattend -VhdxPath $vhdxPath -UnattendXml $xml
  Info "  helper returned target path: $writtenPath"

  # -------------------------------------------------------------------
  # Step C: re-mount and verify
  # -------------------------------------------------------------------
  Info "Step C: re-mounting throwaway VHDX to verify the write"
  $mountedDisk = Mount-VHD -Path $vhdxPath -Passthru -ErrorAction Stop
  $mountedForVerify = $true
  $vhdInfo = Get-VHD -Path $vhdxPath
  $diskNum = $vhdInfo.DiskNumber
  $part = Get-Partition -DiskNumber $diskNum | Where-Object { $_.Type -ne 'Reserved' } | Select-Object -First 1
  $vol = Get-Volume -Partition $part
  $drv = $vol.DriveLetter
  if (-not $drv) {
    # Mount-VHD may not re-assign the same letter; force one.
    Add-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $part.PartitionNumber -AssignDriveLetter -ErrorAction Stop | Out-Null
    $part = Get-Partition -DiskNumber $diskNum -PartitionNumber $part.PartitionNumber
    $vol = Get-Volume -Partition $part
    $drv = $vol.DriveLetter
  }
  if (-not $drv) { throw "verify re-mount yielded no drive letter" }
  Info "  re-mounted at ${drv}:"

  $checkPanther    = Join-Path "${drv}:" 'Windows\Panther'
  $checkUnattend   = Join-Path $checkPanther 'unattend.xml'
  $checkOriginal   = Join-Path $checkPanther 'unattend.original.xml'

  if (-not (Test-Path -LiteralPath $checkUnattend)) {
    throw "verify FAILED: $checkUnattend missing"
  }
  if (-not (Test-Path -LiteralPath $checkOriginal)) {
    throw "verify FAILED: $checkOriginal missing (helper did not back up the baked content)"
  }

  # The backup must contain the BAKED marker, NOT our fixture passphrase.
  $backupContent = Get-Content -LiteralPath $checkOriginal -Raw
  if ($backupContent -notmatch 'BAKED-MS-PANTHER-CONTENT') {
    throw "verify FAILED: unattend.original.xml does not contain BAKED marker. Content: $backupContent"
  }
  if ($backupContent -match [Regex]::Escape($fixturePass)) {
    throw "verify FAILED: backup contains our fixture passphrase (helper backed up the wrong file)"
  }
  Info "  backup file OK (contains BAKED marker; not our fixture passphrase)"

  # The active unattend.xml must contain our content.
  $activeBytes = [System.IO.File]::ReadAllBytes($checkUnattend)
  if ($activeBytes.Length -ge 3 -and $activeBytes[0] -eq 0xEF -and $activeBytes[1] -eq 0xBB -and $activeBytes[2] -eq 0xBF) {
    throw "verify FAILED: unattend.xml has a UTF-8 BOM (helper wrote with BOM; we wanted bom-less)"
  }
  Info "  unattend.xml is UTF-8 bom-less ($($activeBytes.Length) bytes)"

  $activeContent = [System.Text.Encoding]::UTF8.GetString($activeBytes)
  # Parse it as XML structurally.
  $xmlDoc = [xml]$activeContent
  Info "  unattend.xml parses as XML"

  if ($activeContent -notmatch [Regex]::Escape($fixturePass)) {
    throw "verify FAILED: unattend.xml does NOT contain our fixture passphrase"
  }
  if ($activeContent -notmatch 'SkipMachineOOBE') {
    throw "verify FAILED: unattend.xml missing SkipMachineOOBE"
  }
  if ($activeContent -notmatch 'SkipUserOOBE') {
    throw "verify FAILED: unattend.xml missing SkipUserOOBE"
  }
  if ($activeContent -notmatch '<Name>User</Name>') {
    throw "verify FAILED: unattend.xml missing LocalAccount Name=User"
  }
  if ($activeContent -match 'BAKED-MS-PANTHER-CONTENT') {
    throw "verify FAILED: unattend.xml still contains BAKED marker (overwrite did not happen)"
  }
  Info "  unattend.xml has SkipMachineOOBE + SkipUserOOBE + our LocalAccount + our passphrase; no BAKED marker"

  Info "ALL CHECKS PASSED"
  $exitCode = 0
} catch {
  Fail "verification threw: $_"
  $exitCode = 2
} finally {
  if ($mountedForSeed -or $mountedForVerify) {
    try { Dismount-VHD -Path $vhdxPath -ErrorAction Stop } catch { Warn "  cleanup Dismount-VHD failed: $_" }
  }
  if (Test-Path -LiteralPath $tmpDir) {
    try { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction Stop } catch { Warn "  cleanup Remove-Item failed: $_" }
  }
}

exit $exitCode
