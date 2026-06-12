# R1 vendored-blob fetcher.
#
# Pulls the upstream Debian bookworm rootfs tarball used by the R1 boot
# test, verifies its sha256 against the upstream registry-published
# blob digest, and records SHA256SUMS once verification passes.
# Idempotent: re-running with the file present + matching digest is a
# no-op.
#
# Source: Docker Hub `library/debian:bookworm-slim` (amd64 variant),
# which is the canonical debuerreotype-built Debian rootfs published
# from https://github.com/debuerreotype/docker-debian-artifacts. The
# layer blob digest IS the upstream-published sha256 of the
# gzip-compressed rootfs tarball; we pin against that.
#
# Run from anywhere; paths are computed from $PSScriptRoot:
#   pwsh recipes/reproos-ref-iso/vendor/fetch.ps1
#
# LF line endings per the R0 boot-harness scripts convention.

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Definition }

# Blob = the single rootfs layer of debian:bookworm-slim (amd64).
# Pin = its registry sha256 digest; the digest IS the content hash.
#
# Source-of-truth manifest (the `bookworm-slim` multi-arch index):
#   https://hub.docker.com/_/debian
#   curl -H "Authorization: Bearer <token>" \
#     https://registry-1.docker.io/v2/library/debian/manifests/bookworm-slim
#
# The amd64 manifest's single layer (sha256:b9136609...) is the
# gzip-compressed flat rootfs.tar.gz expected by `wsl --import`.
$blobs = @(
    [pscustomobject]@{
        Name        = 'debian-bookworm-slim-amd64-rootfs.tar.gz'
        Repository  = 'library/debian'
        # Manifest digest pin: the multi-arch index lookup proceeds via
        # this digest, ensuring we pull *exactly* the rootfs that
        # `bookworm-slim` resolved to on 2026-06-12.
        ManifestDigest = 'sha256:35ae959f6e83ffb465e7614d27b4fddd28288caa551fbca2798367567cce80d3'
        # Layer digest pin: the sha256 of the rootfs.tar.gz itself.
        LayerSha256 = 'b9136609bef0128191aa157637b98dd7b98e52154ca60c18258d65957a01c6d0'
        ExpectedBytes = 28237624
        Upstream    = 'https://hub.docker.com/_/debian/tags?name=bookworm-slim'
        BuilderRef  = 'https://github.com/debuerreotype/docker-debian-artifacts'
    }
)

# Path B (Hyper-V Gen-2 UEFI) -- vendored Debian cloud qcow2.
# Pin = sha512 published by https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS.
# We don't pin SHA256 upstream-side (the index only publishes SHA512), so the
# script verifies SHA512 against the upstream pin AND records both SHA512+SHA256
# in SHA256SUMS so downstream consumers can use either.
$cloudBlobs = @(
    [pscustomobject]@{
        Name        = 'debian-12-genericcloud-amd64.qcow2'
        # Snapshot of https://cloud.debian.org/images/cloud/bookworm/latest/
        # taken 2026-06-12; the 'latest' symlink advanced to 2026-06-01's
        # build of bookworm 12.10 (we pin against the binary's sha512,
        # not the 'latest' label).
        UpstreamUrl = 'https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2'
        ExpectedSha512 = 'ff1c5b86c680bf29fb65a485296f45da744c9f636cb3c3ecc573b7c51ff88797ef207119e40f07ae9428b9bb539d57b490cdb2beecdfbac25dc95163e1418936'
        Upstream    = 'https://cloud.debian.org/images/cloud/bookworm/'
    }
)

function Fetch-HttpsBlob {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutPath
    )
    # Prefer curl.exe -- Invoke-WebRequest times out on slow https mirrors,
    # and our debian image is 334 MB which can take >2 min on residential
    # links. curl.exe ships in System32 on Win10+.
    $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
    if ($curl) {
        & $curl -fsSL --retry 3 --max-time 1800 -o $OutPath $Url
        if ($LASTEXITCODE -ne 0) {
            throw "curl.exe failed (rc=$LASTEXITCODE) fetching $Url"
        }
        return
    }
    $oldPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutPath -UseBasicParsing -TimeoutSec 1800
    } finally {
        $ProgressPreference = $oldPref
    }
}

function Get-DockerAuthToken {
    param([Parameter(Mandatory)][string]$Repository)
    $tokenUrl = "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$Repository`:pull"
    $oldPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $resp = Invoke-RestMethod -Uri $tokenUrl -Method Get
    } finally {
        $ProgressPreference = $oldPref
    }
    if (-not $resp.token) {
        throw "anonymous token fetch failed for $Repository"
    }
    return $resp.token
}

function Fetch-RegistryBlob {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Digest,
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][string]$Token
    )
    $blobUrl = "https://registry-1.docker.io/v2/$Repository/blobs/$Digest"
    $headers = @{ Authorization = "Bearer $Token" }
    $oldPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $blobUrl -Headers $headers -OutFile $OutPath -UseBasicParsing
    } finally {
        $ProgressPreference = $oldPref
    }
}

$sha256Lines = @()

foreach ($blob in $blobs) {
    $target = Join-Path $here $blob.Name
    Write-Host "[fetch] $($blob.Name) -> $target"

    if (Test-Path -LiteralPath $target) {
        $existing = (Get-Item -LiteralPath $target).Length
        if ($existing -ne $blob.ExpectedBytes) {
            Write-Host "  size mismatch ($existing != $($blob.ExpectedBytes)); re-downloading"
            Remove-Item -LiteralPath $target -Force
        }
    }

    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host "  fetching from Docker Hub registry..."
        $token = Get-DockerAuthToken -Repository $blob.Repository
        Fetch-RegistryBlob -Repository $blob.Repository `
            -Digest "sha256:$($blob.LayerSha256)" `
            -OutPath $target -Token $token
    }

    $actualBytes = (Get-Item -LiteralPath $target).Length
    if ($actualBytes -ne $blob.ExpectedBytes) {
        throw "size mismatch for $($blob.Name): got $actualBytes, expected $($blob.ExpectedBytes)"
    }

    $sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha256 -ne $blob.LayerSha256.ToLowerInvariant()) {
        throw "sha256 mismatch for $($blob.Name): got $sha256, expected $($blob.LayerSha256)"
    }
    Write-Host "  sha256 OK ($sha256)"

    $sha256Lines += "$sha256  $($blob.Name)"
}

# Cloud-image blobs use sha512 (the upstream pin) + sha256 (recorded for
# downstream tooling). We verify sha512 against the upstream pin first.
foreach ($blob in $cloudBlobs) {
    $target = Join-Path $here $blob.Name
    Write-Host "[fetch] $($blob.Name) -> $target"

    $needFetch = -not (Test-Path -LiteralPath $target)
    if (-not $needFetch) {
        $sha512Existing = (Get-FileHash -LiteralPath $target -Algorithm SHA512).Hash.ToLowerInvariant()
        if ($sha512Existing -ne $blob.ExpectedSha512.ToLowerInvariant()) {
            Write-Host "  sha512 mismatch on cached copy; re-downloading"
            Remove-Item -LiteralPath $target -Force
            $needFetch = $true
        } else {
            Write-Host "  cached sha512 OK"
        }
    }

    if ($needFetch) {
        Write-Host "  fetching $($blob.UpstreamUrl) ..."
        Fetch-HttpsBlob -Url $blob.UpstreamUrl -OutPath $target
    }

    $sha512 = (Get-FileHash -LiteralPath $target -Algorithm SHA512).Hash.ToLowerInvariant()
    if ($sha512 -ne $blob.ExpectedSha512.ToLowerInvariant()) {
        throw "sha512 mismatch for $($blob.Name): got $sha512, expected $($blob.ExpectedSha512)"
    }
    Write-Host "  sha512 OK ($sha512)"

    $sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "  sha256 (recorded): $sha256"
    $sha256Lines += "$sha256  $($blob.Name)"
}

$sumsPath = Join-Path $here 'SHA256SUMS'
$sumsContent = ($sha256Lines -join "`n") + "`n"
[IO.File]::WriteAllText($sumsPath, $sumsContent, [Text.UTF8Encoding]::new($false))
Write-Host "[fetch] wrote $sumsPath"
Write-Host "[fetch] OK"
