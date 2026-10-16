#requires -Version 7.0
# Pure local generator: stdout only; -Check compares without writing or executing.
[CmdletBinding()]
param([switch]$Check)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
function Read-Normalized([string]$Name) {
    $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $Name),$utf8).Replace("`r`n","`n")
    return $text.TrimEnd("`n") + "`n"
}
function Get-SourceHash([string]$Text) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($Text))).ToLowerInvariant()
}
$windows = Read-Normalized 'probe-wsl.ps1'
$linux = Read-Normalized 'probe-linux.sh'
$windowsHash = Get-SourceHash $windows
$linuxHash = Get-SourceHash $linux
$windows64 = [Convert]::ToBase64String($utf8.GetBytes($windows))
$linux64 = [Convert]::ToBase64String($utf8.GetBytes($linux))
$template = @'
# Generated from the two independent probe sources; do not edit generated content.
# probe-wsl.ps1 sha256: __WINDOWS_HASH__
# probe-linux.sh sha256: __LINUX_HASH__
name: Windows WSL2 Linux Compose feasibility
'on':
  workflow_dispatch: {}
permissions: {}
jobs:
  probe:
    if: github.event.repository.private == false
    runs-on: windows-2025
    timeout-minutes: 20
    steps:
      - name: Materialize reviewed PowerShell source
        shell: pwsh
        run: |
          $ErrorActionPreference = 'Stop'
          $windows64 = '__WINDOWS_BASE64__'
          $source = [Convert]::FromBase64String($windows64)
          $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($source)).ToLowerInvariant()
          if ($actual -ne '__WINDOWS_HASH__') { throw 'Embedded PowerShell source binding mismatch.' }
          $sourcePath = Join-Path $env:RUNNER_TEMP 'wsl2-compose-reviewed.ps1'
          if (Test-Path -LiteralPath $sourcePath) { throw 'Refusing to replace a pre-existing staged source.' }
          [IO.File]::WriteAllBytes($sourcePath,$source)
      - name: Independent WSL2 plus Linux Docker Compose smoke
        shell: pwsh
        run: |
          $ErrorActionPreference = 'Stop'
          $linux64 = '__LINUX_BASE64__'
          $sourcePath = Join-Path $env:RUNNER_TEMP 'wsl2-compose-reviewed.ps1'
          $actual = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
          if ($actual -ne '__WINDOWS_HASH__') { throw 'Staged PowerShell source binding mismatch.' }
          & $sourcePath -LinuxSourceBase64 $linux64 -LinuxSourceSha256 '__LINUX_HASH__'
'@
$workflow = $template.Replace('__WINDOWS_HASH__',$windowsHash).Replace('__LINUX_HASH__',$linuxHash).
    Replace('__WINDOWS_BASE64__',$windows64).Replace('__LINUX_BASE64__',$linux64).TrimEnd("`n") + "`n"
if ($workflow.Contains('${{')) { throw 'Unexpected GitHub expression inside generated source.' }
if ($Check) {
    $actual = Read-Normalized 'windows-wsl2-compose.yml'
    if ($actual -cne $workflow) { throw 'Generated workflow does not match normalized source bytes.' }
    Write-Output "SOURCE_BINDING=PASS windows=$windowsHash linux=$linuxHash"
} else {
    [Console]::Out.Write($workflow)
}
