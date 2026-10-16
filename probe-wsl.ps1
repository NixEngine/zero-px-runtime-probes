#requires -Version 7.0
# Public, independent probe. Execute only on the workflow's ephemeral standard VM.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LinuxSourceBase64,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$LinuxSourceSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:probeClock = [Diagnostics.Stopwatch]::StartNew()
$script:probeCommands = [Collections.Generic.List[object]]::new()
$script:probeRoot = $null
$script:probeName = $null
$script:probeInstall = $null
$script:probeInitialNames = @()
$script:probeImportAttempted = $false
$probePassed = $false
$probeCleanupPassed = $true
$probeCleanupStatus = 'NOT_REQUIRED'
$probeFailure = $null

function Read-ProbeText([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt 1 -and ($bytes | Where-Object { $_ -eq 0 } | Measure-Object).Count -gt ($bytes.Length / 5)) {
        return [Text.Encoding]::Unicode.GetString($bytes).TrimStart([char]0xfeff)
    }
    return [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff)
}

function Invoke-ProbeCommand {
    param([string]$Label, [string]$File, [string[]]$Arguments,
        [int]$TimeoutSeconds = 30, [string]$InputText, [switch]$AllowFailure, [switch]$Cleanup)
    if (-not $Cleanup) {
        $remaining = 1050 - [int]$script:probeClock.Elapsed.TotalSeconds
        if ($remaining -lt 1) { throw 'Probe wall-clock budget exhausted; cleanup is reserved.' }
        $TimeoutSeconds = [Math]::Min($TimeoutSeconds, $remaining)
    }
    $stdoutPath = Join-Path $script:probeRoot "logs/$Label.stdout"
    $stderrPath = Join-Path $script:probeRoot "logs/$Label.stderr"
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $File
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $stdoutFile = [IO.File]::Create($stdoutPath)
    $stderrFile = [IO.File]::Create($stderrPath)
    $timedOut = $false
    $started = $false
    $exitCode = $null
    try {
        $started = $process.Start()
        if (-not $started) { throw "Could not start stage $Label" }
        $copyOut = $process.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
        $copyErr = $process.StandardError.BaseStream.CopyToAsync($stderrFile)
        if ($InputText) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            $process.Kill($true)
            if (-not $process.WaitForExit(10000)) { throw "Cannot reap timed-out stage $Label" }
        }
        $exitCode = $process.ExitCode
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($copyOut, $copyErr), 10000)) {
            throw "Raw output capture did not finish for $Label"
        }
    } finally {
        $stdoutFile.Dispose()
        $stderrFile.Dispose()
        $process.Dispose()
        $record = [ordered]@{ stage=$Label; started=$started; exit_code=$exitCode; timed_out=$timedOut; timeout_seconds=$TimeoutSeconds }
        $script:probeCommands.Add($record)
        [IO.File]::WriteAllText((Join-Path $script:probeRoot "logs/$Label.result.json"), ($record | ConvertTo-Json -Compress))
        # Raw bytes remain in files; decoded streams and real exit codes survive in job logs.
        # Untrusted native output must not be interpreted as workflow commands.
        # Generate this delimiter after capture so native children never know it.
        $rawLogDelimiter = [Guid]::NewGuid().ToString('N')
        Write-Host "::group::RAW $Label stdout"
        Write-Host "::stop-commands::$rawLogDelimiter"
        Write-Host (Read-ProbeText $stdoutPath)
        Write-Host "::${rawLogDelimiter}::"
        Write-Host '::endgroup::'
        Write-Host "::group::RAW $Label stderr"
        Write-Host "::stop-commands::$rawLogDelimiter"
        Write-Host (Read-ProbeText $stderrPath)
        Write-Host "::${rawLogDelimiter}::"
        Write-Host '::endgroup::'
        Write-Host ($record | ConvertTo-Json -Compress)
    }
    if (($timedOut -or $exitCode -ne 0) -and -not $AllowFailure) { throw "Stage $Label failed; see captured raw streams and exit code." }
    return [pscustomobject]@{ Stdout=(Read-ProbeText $stdoutPath); Stderr=(Read-ProbeText $stderrPath); ExitCode=$exitCode; TimedOut=$timedOut }
}

function Get-OwnedRegistration {
    if (-not $script:probeImportAttempted -or -not $script:probeName -or $script:probeInitialNames -contains $script:probeName) { return @() }
    $keyRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $keyRoot)) { return @() }
    $owned = @(Get-ChildItem -LiteralPath $keyRoot | ForEach-Object {
        $item = Get-ItemProperty -LiteralPath $_.PSPath
        if ($item.DistributionName -eq $script:probeName) {
            $registered = [IO.Path]::GetFullPath(($item.BasePath -replace '^\\\\\?\\', '')).TrimEnd('\')
            $expected = [IO.Path]::GetFullPath($script:probeInstall).TrimEnd('\')
            if ($registered -eq $expected) { $item }
        }
    })
    return $owned
}

try {
    if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows') {
        throw 'Only the designated ephemeral GitHub-hosted Windows workflow may run this probe.'
    }
    if (-not $env:RUNNER_TEMP) { throw 'Missing runner-owned temporary root.' }
    $event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
    if ($event.repository.private -ne $false -or $env:GITHUB_EVENT_NAME -ne 'workflow_dispatch') {
        throw 'Public repository and manual workflow_dispatch are required; private billing is not authorized.'
    }
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.Caption -notmatch 'Windows Server 2025' -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
        throw 'Expected the standard windows-2025 x64 image.'
    }
    $probeId = [Guid]::NewGuid().ToString('N')
    $script:probeName = "wsl2-compose-$probeId"
    $script:probeRoot = Join-Path ([IO.Path]::GetFullPath($env:RUNNER_TEMP)) $script:probeName
    if (Test-Path -LiteralPath $script:probeRoot) { throw 'Owned probe directory already exists.' }
    [void][IO.Directory]::CreateDirectory((Join-Path $script:probeRoot 'logs'))
    $script:probeInstall = Join-Path $script:probeRoot 'distro'
    $linuxBytes = [Convert]::FromBase64String($LinuxSourceBase64)
    $actualHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($linuxBytes)).ToLowerInvariant()
    if ($actualHash -ne $LinuxSourceSha256) { throw 'Embedded Linux source binding mismatch.' }
    $linuxText = [Text.Encoding]::UTF8.GetString($linuxBytes)
    $feature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
    Write-Output ($feature | Select-Object FeatureName,State | ConvertTo-Json -Compress)
    if ($feature.State -ne 'Enabled') { throw 'VirtualMachinePlatform is not already enabled; no enabling or reboot is allowed.' }
    $wsl = (Get-Command wsl.exe -ErrorAction Stop).Source
    $curl = (Get-Command curl.exe -ErrorAction Stop).Source
    $null = Invoke-ProbeCommand wsl-version $wsl @('--version')
    $null = Invoke-ProbeCommand wsl-status $wsl @('--status')
    $before = Invoke-ProbeCommand distro-before $wsl @('--list', '--quiet')
    $script:probeInitialNames = @($before.Stdout -split '\r?\n' | ForEach-Object { $_.Trim([char]0).Trim() } | Where-Object { $_ })
    if ($script:probeInitialNames -contains $script:probeName) { throw 'Refusing to use an existing distro.' }

    $rootfsName = 'ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz'
    $baseUri = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current'
    $sumsPath = Join-Path $script:probeRoot 'SHA256SUMS'
    $rootfsPath = Join-Path $script:probeRoot $rootfsName
    $downloadOptions = @('--fail', '--show-error', '--silent', '--location', '--proto', '=https', '--tlsv1.2', '--connect-timeout', '15', '--retry', '0')
    $null = Invoke-ProbeCommand rootfs-manifest $curl ($downloadOptions + @('--max-time','30',"$baseUri/SHA256SUMS",'--output',$sumsPath)) -TimeoutSeconds 40
    $null = Invoke-ProbeCommand rootfs-download $curl ($downloadOptions + @('--max-time','230',"$baseUri/$rootfsName",'--output',$rootfsPath)) -TimeoutSeconds 240
    $sumLines = @(Get-Content -LiteralPath $sumsPath | Where-Object { $_ -match ('^[a-fA-F0-9]{64}\s+\*?' + [regex]::Escape($rootfsName) + '$') })
    if ($sumLines.Count -ne 1) { throw 'Official HTTPS SHA256SUMS does not uniquely bind the selected rootfs.' }
    $expectedRootfsHash = ($sumLines[0] -split '\s+')[0].ToLowerInvariant()
    $observedRootfsHash = (Get-FileHash -LiteralPath $rootfsPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Output "ROOTFS_SHA256=$observedRootfsHash"
    if ($observedRootfsHash -ne $expectedRootfsHash) { throw 'Ubuntu rootfs digest mismatch.' }
    # Manifest/hash matching is integrity over official HTTPS, not a claim of GPG verification.
    $script:probeImportAttempted = $true
    $null = Invoke-ProbeCommand distro-import $wsl @('--import',$script:probeName,$script:probeInstall,$rootfsPath,'--version','2') -TimeoutSeconds 90
    if (@(Get-OwnedRegistration).Count -ne 1) { throw 'Imported distro registration does not bind to the unique owned installation path.' }
    $listed = Invoke-ProbeCommand distro-version-proof $wsl @('--list','--verbose')
    $matching = @($listed.Stdout -split '\r?\n' | Where-Object { $_ -match ('^\s*\*?\s*' + [regex]::Escape($script:probeName) + '\s+.+\s+2\s*$') })
    if ($matching.Count -ne 1) { throw 'Actual wsl --list --verbose does not report VERSION 2 for this distro.' }
    $linuxResult = Invoke-ProbeCommand linux-probe $wsl @('--distribution',$script:probeName,'--user','root','--exec','timeout','--signal=TERM','--kill-after=10s','650s','bash','-s','--',$script:probeName) -TimeoutSeconds 680 -InputText $linuxText
    if ($linuxResult.Stdout -notmatch '(?m)^LINUX_PROBE_OUTCOME=PASS\r?$') { throw 'Linux exit zero lacks its required success receipt.' }
    $probePassed = $true
} catch {
    $probeFailure = $_.Exception.Message
    Write-Output "PROBE_FAILURE=$probeFailure"
} finally {
    if ($script:probeImportAttempted) {
        $probeCleanupStatus = 'PENDING'
        try {
            if (@(Get-OwnedRegistration).Count -eq 1) {
                $null = Invoke-ProbeCommand cleanup-owned-distro $wsl @('--unregister',$script:probeName) -TimeoutSeconds 30 -Cleanup
                if (@(Get-OwnedRegistration).Count -ne 0) { throw 'Owned distro remains registered after cleanup.' }
                $after = Invoke-ProbeCommand distro-after $wsl @('--list','--quiet') -TimeoutSeconds 20 -Cleanup
                $afterNames = @($after.Stdout -split '\r?\n' | ForEach-Object { $_.Trim([char]0).Trim() } | Where-Object { $_ })
                foreach ($existingName in $script:probeInitialNames) {
                    if ($afterNames -notcontains $existingName) { throw 'A pre-existing distro is missing from the final observed list.' }
                }
                $probeCleanupStatus = 'OWNED_DISTRO_UNREGISTERED'
                Write-Output 'OWNED_DISTRO_CLEANUP=UNREGISTERED'
            } else {
                # Never fall back to unregistering a name without both ownership checks.
                # Absent/ambiguous ownership is unknown cleanup, never positive proof,
                # including when the body had already reported its own smoke success.
                $probeCleanupPassed = $false
                $probeCleanupStatus = 'OWNERSHIP_UNPROVEN'
                Write-Output 'OWNED_DISTRO_CLEANUP=UNKNOWN_OWNERSHIP_UNPROVEN'
            }
        } catch {
            $probeCleanupPassed = $false
            $probeCleanupStatus = 'FAILED'
            Write-Output "CLEANUP_FAILURE=$($_.Exception.Message)"
        }
    }
    $result = [ordered]@{
        schema='wsl2-compose-feasibility-v1'; passed=($probePassed -and $probeCleanupPassed)
        failure=$probeFailure; cleanup_passed=$probeCleanupPassed; cleanup_status=$probeCleanupStatus
        elapsed_seconds=[Math]::Round($script:probeClock.Elapsed.TotalSeconds,3)
        linux_source_sha256=$LinuxSourceSha256; commands=@($script:probeCommands.ToArray())
        scope='independent infrastructure smoke only; no application delivery or production proof'
    }
    $json = $result | ConvertTo-Json -Depth 8
    if ($script:probeRoot) { [IO.File]::WriteAllText((Join-Path $script:probeRoot 'result.json'),$json) }
    Write-Output '::group::FINAL_PROBE_RECEIPT'
    Write-Output $json
    Write-Output '::endgroup::'
    if ($env:GITHUB_STEP_SUMMARY) {
        $summary = "WSL2 + Linux Docker Compose independent feasibility: $($result.passed)`n`nRaw per-stage stdout/stderr and exit-code records are in the job log groups. No application capability is asserted.`n"
        [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,$summary)
    }
}
if (-not ($probePassed -and $probeCleanupPassed)) { exit 1 }
