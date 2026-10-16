#!/usr/bin/env bash
# Public, independent feasibility probe; no application sources or user data.
set -Eeuo pipefail
umask 077

project=${1:?a unique probe project is required}
[[ "$project" =~ ^wsl2-compose-[a-f0-9]{32}$ ]] || exit 64
[[ $(id -u) == 0 ]] || exit 65
work=$(mktemp -d /var/tmp/wsl2-compose-probe.XXXXXXXX)
logs="$work/logs"
mkdir -p "$logs" "$work/docker-config" "$work/exec"
export DOCKER_HOST="unix://$work/docker.sock"
export DOCKER_CONFIG="$work/docker-config"
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
daemon_pid=''
compose_created=0
outcome=FAIL

run() {
  local label=$1 code
  shift
  printf 'STAGE=%s\n' "$label"
  if "$@" >"$logs/$label.stdout" 2>"$logs/$label.stderr"; then code=0; else code=$?; fi
  printf '%s\n' "$code" >"$logs/$label.exit"
  printf 'EXIT[%s]=%s\n' "$label" "$code"
  return "$code"
}

cleanup() {
  local original=$? cleanup_code=0 file
  trap - EXIT INT TERM
  set +e
  if [[ $compose_created == 1 && -S "$work/docker.sock" ]]; then
    run cleanup-compose timeout --kill-after=5s 20s docker compose \
      --project-name "$project" --project-directory "$work" --file "$work/compose.yml" \
      down --remove-orphans --timeout 5
    cleanup_code=$?
  fi
  if [[ -n "$daemon_pid" ]]; then
    # This PID is our still-unreaped child, not a name-based or global daemon kill.
    kill -TERM "$daemon_pid" 2>/dev/null
    for ((i=0; i<50; i++)); do kill -0 "$daemon_pid" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$daemon_pid" 2>/dev/null
    wait "$daemon_pid" 2>/dev/null
  fi
  printf 'CLEANUP_COMPOSE_EXIT=%s\n' "$cleanup_code"
  # Preserve all logs before the Windows owner unregisters only this fresh distro.
  for file in "$logs"/*; do
    printf '\n--- RAW_LOG %s ---\n' "${file##*/}"
    cat -- "$file"
  done
  if [[ $original != 0 || $cleanup_code != 0 ]]; then outcome=FAIL; fi
  printf '\nLINUX_PROBE_OUTCOME=%s\n' "$outcome"
  if [[ $original != 0 ]]; then exit "$original"; fi
  [[ $cleanup_code == 0 && $outcome == PASS ]]
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run kernel uname -a
run os-release cat /etc/os-release
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 && "$VERSION_CODENAME" == noble ]]
[[ $(uname -m) == x86_64 ]]
run resources bash -c 'nproc; free -b; df -B1 /'

install_docker() {
  set -Eeuo pipefail
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  local -a apt_options=(-o Acquire::Retries=0 -o Acquire::http::Timeout=20
    -o Acquire::https::Timeout=20 -o DPkg::Lock::Timeout=20
    -o APT::Update::Error-Mode=any
    -o Dpkg::Options::=--force-confold)
  # This is an isolated, newly imported distro. Suppress service autostart so
  # only the explicit private-socket daemon below will serve this probe.
  printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
  chmod 0755 /usr/sbin/policy-rc.d
  apt-get "${apt_options[@]}" update
  apt-get "${apt_options[@]}" install -y --no-install-recommends ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 40 --retry 0 \
    https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf '%s\n' 'Types: deb' 'URIs: https://download.docker.com/linux/ubuntu' \
    'Suites: noble' 'Components: stable' 'Architectures: amd64' \
    'Signed-By: /etc/apt/keyrings/docker.asc' >/etc/apt/sources.list.d/docker.sources
  apt-get "${apt_options[@]}" update
  apt-get "${apt_options[@]}" install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}
export -f install_docker
# The complete apt/key/repository/install phase, not merely each apt call, is <5m.
run install-docker timeout --signal=TERM --kill-after=5s 290s bash -c install_docker
run installed-packages dpkg-query -W -f='${Package}\t${Version}\n' \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Never use Windows Docker, a remote context, or the distro's default socket.
dockerd --host "$DOCKER_HOST" --data-root "$work/docker-data" \
  --exec-root "$work/exec" --pidfile "$work/dockerd.pid" \
  --bridge none --iptables=false --ip6tables=false --ip-forward=false \
  --ip-masq=false --userland-proxy=false \
  >"$logs/dockerd.stdout" 2>"$logs/dockerd.stderr" &
daemon_pid=$!
printf '%s\n' "$daemon_pid" >"$logs/dockerd.pid"
run daemon-ready timeout --kill-after=3s 45s bash -c \
  'until docker info --format "{{.OSType}}"; do sleep 1; done'
run docker-server docker version --format \
  'Client={{.Client.Version}} Server={{.Server.Version}} OS={{.Server.Os}} Arch={{.Server.Arch}}'
run docker-resources docker info --format \
  'OSType={{.OSType}} Architecture={{.Architecture}} NCPU={{.NCPU}} MemTotal={{.MemTotal}} Driver={{.Driver}} CgroupVersion={{.CgroupVersion}}'
[[ $(docker info --format '{{.OSType}}') == linux ]]
run compose-version docker compose version

run hello-pull timeout --kill-after=5s 90s docker pull --platform linux/amd64 hello-world:latest
run hello-digest docker image inspect --format '{{index .RepoDigests 0}}' hello-world:latest
IFS= read -r image <"$logs/hello-digest.stdout"
[[ "$image" =~ ^hello-world@sha256:[a-f0-9]{64}$ ]]
printf 'PINNED_IMAGE=%s\n' "$image"
cat >"$work/compose.yml" <<EOF
services:
  hello:
    image: "$image"
    platform: linux/amd64
    pull_policy: never
    network_mode: none
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    pids_limit: 32
    mem_limit: 64m
    cpus: 1.0
    restart: "no"
EOF
compose=(docker compose --project-name "$project" --project-directory "$work" --file "$work/compose.yml")
run compose-config "${compose[@]}" config
compose_created=1
run compose-smoke timeout --signal=TERM --kill-after=5s 115s "${compose[@]}" \
  up --abort-on-container-exit --exit-code-from hello --no-build --pull never
run compose-logs "${compose[@]}" logs --no-color hello
grep -Fq 'Hello from Docker!' "$logs/compose-logs.stdout"
run container-id "${compose[@]}" ps --all --quiet hello
IFS= read -r container_id <"$logs/container-id.stdout"
[[ "$container_id" =~ ^[a-f0-9]{64}$ ]]
run container-proof docker inspect --format \
  'Exit={{.State.ExitCode}} Status={{.State.Status}} Network={{.HostConfig.NetworkMode}} ReadOnly={{.HostConfig.ReadonlyRootfs}} CapDrop={{json .HostConfig.CapDrop}} SecurityOpt={{json .HostConfig.SecurityOpt}} Image={{.Config.Image}}' \
  "$container_id"
proof=$(<"$logs/container-proof.stdout")
[[ "$proof" == 'Exit=0 Status=exited Network=none ReadOnly=true '* ]]
[[ "$proof" == *'CapDrop=["ALL"]'* && "$proof" == *'no-new-privileges:true'* ]]
[[ "$proof" == *"Image=$image" ]]
outcome=PASS
