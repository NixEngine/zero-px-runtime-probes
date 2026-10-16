# Provenance and observed infrastructure run

This is new, isolated diagnostic source prepared with AI assistance in OpenAI Codex, under Junior's authorization. AI agents contributed design, implementation, tests and review. Junior supplied conceptual direction, resources and authorization; no human software-engineering qualification is asserted. This repository does not represent OpenAI.

## Observed run

- Executed source commit: 1306302102de183af05ed6fea1e8803ebadefc8b.
- Run: https://github.com/NixEngine/zero-px-runtime-probes/actions/runs/38888691040
- Job: 116932665507; all four native job steps completed successfully.
- Requested standard label: windows-2025. Actual image reported: windows-2025-vs2026, version 20261007.264.1.
- A fresh owned Ubuntu 24.04 distribution was actually listed as WSL VERSION 2.
- Docker server 29.9.1 reported Linux/amd64; Compose version was 5.6.0.
- The digest-pinned hello-world container actually ran, exited zero and produced its expected output. Inspection showed network none, read-only root, all capabilities dropped and no-new-privileges.
- Compose cleanup exited zero, the owned daemon shut down, the fresh distro was unregistered and the final distro list was empty.
- The probe's final receipt reported 76.031 seconds, passed=true and cleanup_passed=true.
- The service timestamps are literal 2026-10-16T10:39:52Z to 10:41:10Z; no inference about a separate local host clock is made.

Seven repository paths were read back at the executed commit and matched the selected local Git blob identities. The generated root YAML is retained as the source-binding fixture; its byte-identical .github/workflows entrypoint lets Actions discover the manual workflow.

## Exact limits

This is evidence of one functional hosted WSL2 + Linux Docker + Compose route, not a universal availability guarantee or a local Gram runtime test. Observed Linux resources were four CPUs and 8327020544 bytes of memory.

No target application's full stack, owner setup, secrets, hot reload, CLI/OpenCode behavior, application CI, customer acceptance, production deployment, bounty award, invoice or payment is demonstrated. Future work must retain those requirements rather than treating this infrastructure smoke as their substitute.

The available evidence is the provider-decoded job log, including provider prefixes and redactions. Temporary binary files from the disposable runner were not preserved. No repeated run is claimed as a second independent replication.
