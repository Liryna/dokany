#!/usr/bin/env bash
# Boots a baked Windows Server Core image under QEMU/KVM, installs Dokan with Driver Verifier armed,
# runs one test shard, and collects logs, fstest scorecards and crash dumps.
#
# Usage: run_vm_tests.sh <image_dir> <payload_dir> <results_dir> [shard] [simulate]
#   shard:    all | shard1 | shard2                           (default: all)
#   simulate: none | bugcheck | hang                          (default: none; crash-capture self-test)
#
# <payload_dir> must contain DokanSetup.exe, fsx.exe and fstest/ (dokan_fstest.exe, baselines/).
# The guest boots before the build finishes: if the payload is missing and PAYLOAD_RUN_ID is set,
# the payload artifacts of that workflow run are downloaded once the guest is up.
#
# Environment:
#   PAYLOAD_RUN_ID, GITHUB_REPOSITORY, GH_TOKEN  Where to download the payload artifacts from.
#   PAYLOAD_ARTIFACTS   Space-separated artifact names (default: "dokan-test-payload dokan-test-tools").
#                       Waiting stops early if a job whose name starts with "Build" fails.
#   GUEST_TEST_TIMEOUT  Seconds before a running shard is declared hung (default: 2700).
#   QEMU_CPU            Override the QEMU -cpu model (for investigations).
#
# Guest network: user-mode NAT with restrict=on (no outbound access); only SSH is forwarded to localhost.
# A hung guest gets an NMI (the image sets CrashControl\NMICrashDump=1), turning the hang into MEMORY.DMP.
set -euo pipefail

usage='usage: run_vm_tests.sh <image_dir> <payload_dir> <results_dir> [all|shard1|shard2] [none|bugcheck|hang]'
IMAGE_DIR="${1:?$usage}"
PAYLOAD_DIR="${2:?$usage}"
RESULTS_DIR="${3:?$usage}"
SHARD="${4:-all}"
SIMULATE="${5:-none}"
case "$SHARD" in all|shard1|shard2) ;; *) echo "ERROR: invalid shard '$SHARD'. $usage" >&2; exit 2 ;; esac
case "$SIMULATE" in none|bugcheck|hang) ;; *) echo "ERROR: invalid simulate mode '$SIMULATE'. $usage" >&2; exit 2 ;; esac

GUEST_TEST_TIMEOUT="${GUEST_TEST_TIMEOUT:-2700}"
if [[ "$SIMULATE" == "hang" ]]; then
  GUEST_TEST_TIMEOUT=120
fi
QEMU_CPU="${QEMU_CPU:-host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK_DIR="${RUNNER_TEMP:-/tmp}/vm-test"
mkdir -p "$WORK_DIR" "$RESULTS_DIR"

BASE_IMG="$IMAGE_DIR/base.qcow2"
SSH_KEY="$IMAGE_DIR/id_ed25519"
OVERLAY_IMG="$WORK_DIR/overlay.qcow2"
MON_SOCK="$WORK_DIR/monitor.sock"
SERIAL_LOG="$RESULTS_DIR/serial.log"
chmod 600 "$SSH_KEY"
: > "$SERIAL_LOG"

log() { echo "=== [$(date -u +%T)] $* ==="; }

log "Host CPU: $(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -n1); QEMU CPU model: $QEMU_CPU"

QEMU_PID=""
stop_qemu() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
}
trap stop_qemu EXIT

start_qemu() {
  stop_qemu
  rm -f "$OVERLAY_IMG" "$MON_SOCK"
  # Throw-away copy-on-write overlay: the cached base image is never modified.
  qemu-img create -q -f qcow2 -b "$BASE_IMG" -F qcow2 "$OVERLAY_IMG"
  qemu-system-x86_64 \
    -enable-kvm \
    -machine q35,accel=kvm \
    -cpu "$QEMU_CPU" \
    -smp 4 \
    -m 6G \
    -display none \
    -vga std \
    -monitor "unix:$MON_SOCK,server,nowait" \
    -serial "file:$SERIAL_LOG" \
    -device ahci,id=ahci \
    -drive "file=$OVERLAY_IMG,format=qcow2,if=none,id=hd0,cache=writeback" \
    -device ide-hd,drive=hd0,bus=ahci.0 \
    -netdev user,id=net0,restrict=on,hostfwd=tcp:127.0.0.1:2222-:22 \
    -device e1000e,netdev=net0 &
  QEMU_PID=$!
}

qemu_monitor() {
  printf '%s\n' "$@" | socat - "UNIX-CONNECT:$MON_SOCK" >/dev/null 2>&1 || true
}

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes
          -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -p 2222)
SCP_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes
          -o ConnectTimeout=10 -P 2222)
# Commands are PowerShell executed by the guest's sshd, so they are meant to be passed through verbatim.
# shellcheck disable=SC2029
guest_ssh() { ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 "$@"; }

wait_for_ssh() {
  local max_wait="$1" start attempt=0 err=""
  start=$(date +%s)
  while true; do
    attempt=$((attempt + 1))
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      echo "ERROR: QEMU exited while waiting for SSH" >&2
      return 1
    fi
    if err=$(guest_ssh 'echo ready' 2>&1); then
      return 0
    fi
    if (( attempt % 10 == 1 )); then
      echo "[wait_for_ssh +$(( $(date +%s) - start ))s] $(echo "$err" | tr '\n' ' ' | cut -c1-200)"
    fi
    if (( $(date +%s) - start >= max_wait )); then
      echo "ERROR: no SSH after ${max_wait}s; saving screenshot." >&2
      qemu_monitor "screendump $RESULTS_DIR/no-ssh-screen.ppm"
      return 1
    fi
    sleep 3
  done
}

payload_complete() {
  [[ -f "$PAYLOAD_DIR/DokanSetup.exe" && -f "$PAYLOAD_DIR/fsx.exe" && -f "$PAYLOAD_DIR/fstest/dokan_fstest.exe" ]]
}

# Downloads one artifact of run $PAYLOAD_RUN_ID into $PAYLOAD_DIR, waiting until it has been uploaded.
fetch_artifact() {
  local name="$1" repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}" run_id="${PAYLOAD_RUN_ID:?PAYLOAD_RUN_ID not set}"
  local deadline=$(( $(date +%s) + 2400 )) artifact_id="" failed_builds="" attempt
  log "Waiting for artifact '$name'"
  while true; do
    artifact_id=$(gh api "repos/$repo/actions/runs/$run_id/artifacts?name=$name" --jq '.artifacts[0].id // empty' 2>/dev/null || true)
    [[ -n "$artifact_id" ]] && break
    failed_builds=$(gh api "repos/$repo/actions/runs/$run_id/jobs?per_page=100" \
      --jq '[.jobs[] | select((.name | startswith("Build")) and .status == "completed" and .conclusion != "success") | .name] | join(", ")' 2>/dev/null || true)
    if [[ -n "$failed_builds" ]]; then
      echo "ERROR: build job(s) did not succeed: $failed_builds" >&2
      return 1
    fi
    if (( $(date +%s) > deadline )); then
      echo "ERROR: timed out waiting for artifact '$name'." >&2
      return 1
    fi
    sleep 10
  done
  # An artifact can be listed a few seconds before its zip is downloadable (HTTP 404 meanwhile).
  for attempt in $(seq 1 18); do
    if gh api "repos/$repo/actions/artifacts/$artifact_id/zip" > "$WORK_DIR/artifact.zip" 2> "$WORK_DIR/artifact.err" \
        && unzip -tq "$WORK_DIR/artifact.zip" >/dev/null 2>&1; then
      mkdir -p "$PAYLOAD_DIR"
      unzip -o -q "$WORK_DIR/artifact.zip" -d "$PAYLOAD_DIR"
      rm -f "$WORK_DIR/artifact.zip"
      return 0
    fi
    echo "Artifact '$name' not downloadable yet (attempt $attempt/18): $(head -c 200 "$WORK_DIR/artifact.err" | tr '\n' ' ')"
    sleep 10
  done
  echo "ERROR: could not download artifact '$name'." >&2
  return 1
}

fetch_payload() {
  payload_complete && return 0
  local name
  for name in ${PAYLOAD_ARTIFACTS:-dokan-test-payload dokan-test-tools}; do
    fetch_artifact "$name"
  done
  if ! payload_complete; then
    echo "ERROR: payload is incomplete (need DokanSetup.exe, fsx.exe, fstest/dokan_fstest.exe)." >&2
    return 1
  fi
}

# Stage the guest's C:\ci tree: the installer, run_guest_tests.ps1, the samples\ harnesses exactly as in
# the repository (with fsx.exe where they expect it), and the dokan_fstest runner + baselines.
stage_guest_files() {
  local stage="$WORK_DIR/guest-ci"
  rm -rf "$stage"
  mkdir -p "$stage/repo/samples/fstools/src/fsx" "$stage/repo/scripts"
  cp "$PAYLOAD_DIR/DokanSetup.exe" "$stage/"
  cp "$PAYLOAD_DIR/fsx.exe" "$stage/repo/samples/fstools/src/fsx/"
  cp -r "$PAYLOAD_DIR/fstest" "$stage/"
  cp "$SCRIPT_DIR/run_guest_tests.ps1" "$stage/"
  cp "$REPO_ROOT/samples/memfs_test.ps1" "$REPO_ROOT/samples/mirror_test.ps1" "$stage/repo/samples/"
  cp "$REPO_ROOT/scripts/run_ifstest.ps1" "$REPO_ROOT/scripts/fstest_common.ps1" "$stage/repo/scripts/"
  guest_ssh 'Remove-Item -Recurse -Force C:\ci -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path C:\ci | Out-Null'
  scp "${SCP_OPTS[@]}" -r "$stage"/* "Administrator@127.0.0.1:C:/ci/"
}

NMI_INJECTED=false
inject_nmi() {
  log "Guest is unresponsive: saving screenshot and injecting NMI (BugCheck 0x80 -> MEMORY.DMP)"
  qemu_monitor "screendump $RESULTS_DIR/hang-screen.ppm" "nmi"
  NMI_INJECTED=true
}

DUMP_COLLECTED=false
# Brings the guest back after a crash or hang if needed, then copies logs, scorecards and MEMORY.DMP.
collect_results() {
  local test_rc="$1" guest_up=false
  if [[ $test_rc -eq 124 ]]; then
    echo "Test shard exceeded ${GUEST_TEST_TIMEOUT}s."
    inject_nmi
    wait_for_ssh 480 && guest_up=true
  elif [[ $test_rc -ne 0 ]]; then
    # SSH can drop because of a real BugCheck: give Windows time to write the dump and reboot.
    sleep 8
    if wait_for_ssh 180; then
      guest_up=true
    elif kill -0 "$QEMU_PID" 2>/dev/null; then
      inject_nmi
      wait_for_ssh 480 && guest_up=true
    fi
  else
    wait_for_ssh 60 && guest_up=true
  fi

  if [[ "$guest_up" != true ]]; then
    echo "ERROR: guest did not come back; no logs or dump can be collected." >&2
    return 1
  fi

  local dump_rc=0
  # After a crash, wait (up to ~45s) for Windows to finish writing C:\Windows\MEMORY.DMP.
  # shellcheck disable=SC2016 # PowerShell variables, expanded by the guest.
  guest_ssh '
    $dump = "C:\Windows\MEMORY.DMP"
    for ($i = 0; $i -lt 15; $i++) {
      $crashed = Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = 1001; ProviderName = "Microsoft-Windows-WER-SystemErrorReporting" } -MaxEvents 1 -ErrorAction SilentlyContinue
      if (-not $crashed -and $i -ge 2) { break }
      if (Test-Path $dump) {
        $size = (Get-Item $dump).Length; Start-Sleep -Seconds 3
        if ($size -gt 0 -and $size -eq (Get-Item $dump).Length) { break }
      } else { Start-Sleep -Seconds 3 }
    }
    Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = 1001; ProviderName = "Microsoft-Windows-WER-SystemErrorReporting" } -MaxEvents 3 -ErrorAction SilentlyContinue |
      Format-List TimeCreated, Message
    if (Test-Path $dump) { exit 42 }
  ' || dump_rc=$?

  scp "${SCP_OPTS[@]}" "Administrator@127.0.0.1:C:/ci/dokan_install*.log" "$RESULTS_DIR/" 2>/dev/null || true
  scp "${SCP_OPTS[@]}" -r "Administrator@127.0.0.1:C:/ci/fstest-results" "$RESULTS_DIR/" 2>/dev/null || true

  if [[ $dump_rc -eq 42 ]]; then
    log "Collecting C:\\Windows\\MEMORY.DMP"
    scp "${SCP_OPTS[@]}" "Administrator@127.0.0.1:C:/Windows/MEMORY.DMP" "$WORK_DIR/MEMORY.DMP"
    7z a -t7z -mx=3 "$RESULTS_DIR/MEMORY.DMP.7z" "$WORK_DIR/MEMORY.DMP" >/dev/null
    rm -f "$WORK_DIR/MEMORY.DMP"
    echo "MEMORY.DMP.7z: $(du -h "$RESULTS_DIR/MEMORY.DMP.7z" | cut -f1) (NMI injected: $NMI_INJECTED)"
    DUMP_COLLECTED=true
  elif [[ "$NMI_INJECTED" == true ]]; then
    echo "ERROR: an NMI was injected but Windows wrote no MEMORY.DMP." >&2
  fi
  guest_ssh 'Stop-Computer -Force' >/dev/null 2>&1 || true
  wait "$QEMU_PID" 2>/dev/null || true
  [[ "$DUMP_COLLECTED" != true && "$NMI_INJECTED" != true ]]
}

log "Booting guest (shard=$SHARD, simulate=$SIMULATE)"
t_boot=$(date +%s)
start_qemu
# Under nested KVM Windows occasionally stalls on the boot logo; retry once with a fresh overlay.
if ! wait_for_ssh 90; then
  echo "WARNING: guest not reachable after 90s; retrying boot once with a fresh overlay." >&2
  t_boot=$(date +%s)
  start_qemu
  wait_for_ssh 150
fi
boot_secs=$(( $(date +%s) - t_boot ))
log "Guest reachable over SSH after ${boot_secs}s"

t_wait=$(date +%s)
fetch_payload
wait_secs=$(( $(date +%s) - t_wait ))
stage_guest_files

guest_cmd="& C:\\ci\\run_guest_tests.ps1 -Shard $SHARD"
case "$SIMULATE" in
  bugcheck) guest_cmd+=" -SimulateBugCheck" ;;
  hang) guest_cmd+=" -SimulateHang" ;;
esac

log "Running: $guest_cmd (timeout ${GUEST_TEST_TIMEOUT}s)"
t_test=$(date +%s)
set +e
timeout "$GUEST_TEST_TIMEOUT" ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 "$guest_cmd"
test_rc=$?
set -e
test_secs=$(( $(date +%s) - t_test ))
log "Guest tests exited with code $test_rc after ${test_secs}s"

collect_rc=0
collect_results "$test_rc" || collect_rc=$?

cat <<EOF
=== Summary ===
Boot to SSH:           ${boot_secs}s
Waited for payload:    ${wait_secs}s
Tests:                 ${test_secs}s (exit code $test_rc)
NMI injected:          $NMI_INJECTED
Crash dump collected:  $DUMP_COLLECTED
EOF

if [[ "$SIMULATE" != "none" ]]; then
  # Self-test: success means a dump was produced and collected.
  [[ "$DUMP_COLLECTED" == true ]]
  exit $?
fi
[[ $test_rc -eq 0 && $collect_rc -eq 0 ]]
