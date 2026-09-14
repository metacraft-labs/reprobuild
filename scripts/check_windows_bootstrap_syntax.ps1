#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'This gate must run under Windows PowerShell 5.1, not pwsh.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$files = @((Get-Item -LiteralPath (Join-Path $repoRoot 'env.ps1')))
$files += @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'windows') -Filter '*.ps1' -File | Sort-Object FullName)
$failures = 0
foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    # ParseFile exercises 5.1's on-disk decoding too; parsing a UTF-8 string
    # supplied by a newer host would miss the compatibility failure.
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($parseError in $parseErrors) {
        [Console]::Error.WriteLine(('{0}:{1}: {2}' -f
            $file.FullName, $parseError.Extent.StartLineNumber, $parseError.Message))
        $failures++
    }
}
if ($failures -ne 0) {
    throw "Windows bootstrap syntax check failed with $failures parser errors."
}
Write-Output "Windows PowerShell 5.1 parsed all $($files.Count) bootstrap scripts."
