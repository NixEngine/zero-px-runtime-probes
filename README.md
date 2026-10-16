# Independent Windows / WSL2 / Linux Compose feasibility probe

This is new public-safe infrastructure-only source. It contains no application
code, corpus, credentials, personal identifiers, local user paths, or claims of
application delivery. Static validation is not runtime proof.

The generated `windows-wsl2-compose.yml` is a manual-only `workflow_dispatch`
workflow for the standard `windows-2025` GitHub-hosted runner. It has
`permissions: {}`, no checkout or third-party actions, no secrets, no deployment,
and a 20-minute job timeout. It refuses private repositories so the standard
public-repository runner path, not paid larger runners or private overages, is
used. Repository creation, publication and dispatch require separate authority.

## Safety and evidence contract

- WSL must already respond and VirtualMachinePlatform must already be enabled.
  No Windows feature enablement, WSL update, version conversion, default-setting,
  global WSL shutdown, reboot, host Docker installation or fallback is allowed.
- Import an official Ubuntu 24.04 x64 rootfs as a unique fresh distro with explicit
  `--version 2`. Match the downloaded rootfs against official HTTPS SHA256SUMS;
  this is not represented as detached-GPG verification. Observe actual
  `wsl --list --verbose` VERSION 2, Linux `uname` and `/etc/os-release`.
- Install Docker Engine and Compose in that disposable distro using the official
  Signed-By apt repository. The entire apt/repository phase is bounded below five
  minutes, noninteractive and with network timeouts. No downloaded shell installer.
- Start an owned Linux dockerd child with a private local Unix socket and data
  root, no TCP listener, bridge or daemon firewall manipulation. Never use a
  Windows Docker server or remote context. Record Linux server, Compose and
  resource versions only, not environment or credential dumps.
- Pull official `hello-world`, resolve its observed RepoDigest, then pin that
  digest in an actual Compose service. Require exit zero, expected hello output,
  actual exited-container state, no network, read-only root, all capabilities
  dropped and no-new-privileges. The smoke command is bounded to 120 seconds
  including its forced-kill grace.
- Clean only the owned Compose project/daemon and the fresh distro whose random
  name was absent before and whose registration BasePath matches the owned import
  directory. Do not unregister any existing distro, prune Docker, or delete other
  data. Keep raw stdout/stderr bytes and actual command exit codes in runner temp,
  and emit them in workflow log groups before unregistering the fresh distro.

Job logs are the retained remote evidence, subject to GitHub log retention. The
temporary byte-for-byte files are ephemeral; there is deliberately no artifact
upload action. Forced job cancellation or GitHub's hard timeout can interrupt
cleanup/log flushing; no receipt means no success proof. Failure is informative:
standard runner nested virtualization may be unavailable even with WSL installed.
The probe never repairs this by changing global features or selecting paid runners.

## Reproducible source binding and static checks

`probe-wsl.ps1` and `probe-linux.sh` are the two source files. The pure local
generator `build-workflow.ps1` normalizes LF/final newline, hashes and base64-embeds
both into one self-contained workflow. Both hashes are verified at execution.
No repository checkout is required; repository changes cannot silently select a
different source. Source and workflow revision still require normal review.

Run only the generator and static checks locally, not either runtime probe:

```powershell
pwsh -NoProfile -File ./build-workflow.ps1 -Check
# Without -Check the generator emits YAML to stdout only; it does not write files.
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PWD 'probe-wsl.ps1'), [ref]$tokens, [ref]$errors) > $null
if ($errors.Count) { throw ($errors | Out-String) }
# Use an already-installed Git Bash executable, not the Windows WSL bash shim.
& 'C:/Program Files/Git/bin/bash.exe' -n ./probe-linux.sh
# If PyYAML is already available; -B prevents bytecode writes. Never install it here.
py -3.14 -B ./test-static.py
```

Official references checked for the design:

- [GitHub standard/public runner and billing distinction](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [Windows 2025 runner image manifest](https://github.com/actions/runner-images/blob/main/images/windows/Windows2025-Readme.md)
- [Microsoft WSL import, list, version and unregister commands](https://learn.microsoft.com/en-us/windows/wsl/basic-commands)
- [Canonical Ubuntu 24.04 WSL rootfs and SHA256SUMS](https://cloud-images.ubuntu.com/wsl/releases/24.04/current/)
- [Official Docker signed apt repository installation](https://docs.docker.com/engine/install/ubuntu/)
- [Docker Compose service hardening options](https://docs.docker.com/reference/compose-file/services/)
