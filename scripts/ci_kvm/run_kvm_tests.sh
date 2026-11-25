#!/usr/bin/env bash
# Boots a cached, test-signed Windows Server Core image under KVM (network-isolated),
# installs Dokan under Driver Verifier, runs the FS test shard, and harvests crash dumps.
#
# The VM boots *before* the Windows build finishes: if <artifacts_dir> has no DokanSetup.exe
# and DOKAN_ARTIFACT_RUN_ID is set, the script polls the GitHub API for the
# 'dokan-build-artifacts' artifact of that run once the guest is up.
#
# Hangs: if the guest test times out or SSH dies while QEMU is still running, an NMI is
# injected (guest image has CrashControl\NMICrashDump=1) so Windows writes a kernel
# MEMORY.DMP of the hung state, which is then harvested like any other BugCheck.
set -euo pipefail

usage='usage: run_kvm_tests.sh <image_dir> <artifacts_dir> <results_dir> [shard] [mode: false|bugcheck|nmi|idle|idle-dokan]'
IMAGE_DIR="${1:?$usage}"
ARTIFACTS_DIR="${2:?$usage}"
RESULTS_DIR="${3:?$usage}"
SHARD="${4:-all}"
SIMULATE="${5:-false}"
case "$SIMULATE" in
  true|bugcheck) SIMULATE="bugcheck" ;;
  false|nmi|idle|idle-dokan) ;;
  *) echo "ERROR: invalid mode '$SIMULATE'" >&2; exit 2 ;;
esac
CANARY_IDLE_MINUTES="${CANARY_IDLE_MINUTES:-20}"
# Default CPU model; QEMU_CPU overrides it (e.g. to test additional Hyper-V enlightenments)
QEMU_CPU="${QEMU_CPU:-host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time}"
echo "QEMU CPU model: $QEMU_CPU"
echo "Host CPU: $(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -n1)"

GUEST_TEST_TIMEOUT="${GUEST_TEST_TIMEOUT:-2700}"
if [[ "$SIMULATE" == "nmi" ]]; then
  GUEST_TEST_TIMEOUT=120
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${RUNNER_TEMP:-/tmp}/kvm-test-run"
mkdir -p "$WORK_DIR" "$RESULTS_DIR"

SSH_KEY="$IMAGE_DIR/id_ed25519"
OVERLAY_IMG="$WORK_DIR/overlay.qcow2"
SERIAL_LOG="$RESULTS_DIR/serial.log"

if [[ -f "$IMAGE_DIR/base.qcow2" ]]; then
  BASE_IMG="$IMAGE_DIR/base.qcow2"
elif [[ -f "$IMAGE_DIR/base.qcow2.zst" ]]; then
  BASE_IMG="$WORK_DIR/base.qcow2"
  echo "=== [$(date -u +%T)] Decompressing legacy base.qcow2.zst ==="
  zstd -d --long=27 -T0 -f "$IMAGE_DIR/base.qcow2.zst" -o "$BASE_IMG"
else
  echo "ERROR: No base.qcow2 (or legacy base.qcow2.zst) in $IMAGE_DIR" >&2
  exit 1
fi
echo "Base image: $BASE_IMG ($(du -h "$BASE_IMG" | awk '{print $1}'))"

chmod 600 "$SSH_KEY"

: > "$SERIAL_LOG"
QEMU_PID=""
cleanup() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

start_qemu() {
  cleanup
  rm -f "$OVERLAY_IMG" "${WORK_DIR}/mon.sock"
  qemu-img create -f qcow2 -b "$BASE_IMG" -F qcow2 "$OVERLAY_IMG" >/dev/null
  qemu-system-x86_64 \
    -enable-kvm \
    -machine q35,accel=kvm \
    -cpu "$QEMU_CPU" \
    -smp 4 \
    -m 6G \
    -display none \
    -vga std \
    -monitor "unix:${WORK_DIR}/mon.sock,server,nowait" \
    -serial "file:${SERIAL_LOG}" \
    -device ahci,id=ahci \
    -drive "file=${OVERLAY_IMG},format=qcow2,if=none,id=hd0,cache=writeback" \
    -device ide-hd,drive=hd0,bus=ahci.0 \
    -netdev user,id=net0,restrict=on,hostfwd=tcp:127.0.0.1:2222-:22 \
    -device e1000e,netdev=net0 &
  QEMU_PID=$!
}

qemu_monitor() {
  printf '%s\n' "$@" | socat - "UNIX-CONNECT:${WORK_DIR}/mon.sock" 2>&1 || true
}

SSH_OPTS=(
  -i "$SSH_KEY"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=15
  -o BatchMode=yes
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=4
  -p 2222
)
SCP_OPTS=(
  -i "$SSH_KEY"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o BatchMode=yes
  -P 2222
)

wait_for_ssh() {
  local max_wait="${1:-180}"
  local start attempt=0 last_err=""
  start=$(date +%s)
  while true; do
    attempt=$((attempt + 1))
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      echo "ERROR: QEMU exited unexpectedly while waiting for SSH" >&2
      return 1
    fi
    if last_err=$(ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 'echo SSH_READY' 2>&1); then
      return 0
    fi
    if (( attempt % 10 == 1 )); then
      echo "[wait_for_ssh +$(( $(date +%s) - start ))s] $(echo "$last_err" | tr '\n' ' ' | cut -c1-200)"
    fi
    if (( $(date +%s) - start >= max_wait )); then
      echo "ERROR: Timed out after ${max_wait}s waiting for guest SSH." >&2
      echo "Capturing QEMU screendump to $RESULTS_DIR/boot-screen.ppm..." >&2
      qemu_monitor "screendump $RESULTS_DIR/boot-screen.ppm" "info status" >/dev/null
      return 1
    fi
    sleep 3
  done
}

fetch_build_artifacts() {
  if [[ -f "$ARTIFACTS_DIR/DokanSetup.exe" ]]; then
    return 0
  fi
  local run_id="${DOKAN_ARTIFACT_RUN_ID:?DokanSetup.exe missing and DOKAN_ARTIFACT_RUN_ID not set}"
  local repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
  local name="${DOKAN_ARTIFACT_NAME:-dokan-build-artifacts}"
  local deadline=$(( $(date +%s) + ${DOKAN_ARTIFACT_TIMEOUT:-2400} ))
  local artifact_id="" build_state=""
  echo "=== [$(date -u +%T)] Guest is up; waiting for '$name' from run $run_id ==="
  while true; do
    artifact_id=$(gh api "repos/$repo/actions/runs/$run_id/artifacts?name=$name" --jq '.artifacts[0].id // empty' 2>/dev/null || true)
    if [[ -n "$artifact_id" ]]; then
      break
    fi
    build_state=$(gh api "repos/$repo/actions/runs/$run_id/jobs?per_page=100" \
      --jq '[.jobs[] | select(.name | startswith("Build & Test-Sign"))][0] | "\(.status):\(.conclusion)"' 2>/dev/null || echo "unknown:")
    if [[ "$build_state" == completed:* && "$build_state" != "completed:success" ]]; then
      echo "ERROR: Build job finished as '$build_state'; no artifacts to test." >&2
      return 1
    fi
    if (( $(date +%s) > deadline )); then
      echo "ERROR: Timed out waiting for build artifact '$name' (last build state: $build_state)" >&2
      return 1
    fi
    sleep 10
  done
  mkdir -p "$ARTIFACTS_DIR"
  # The artifact can be listed a few seconds before its zip is downloadable (finalization race -> HTTP 404).
  local attempt downloaded="false"
  for attempt in $(seq 1 18); do
    if gh api "repos/$repo/actions/artifacts/$artifact_id/zip" > "$WORK_DIR/build-artifacts.zip" 2> "$WORK_DIR/artifact-dl.err" \
        && unzip -tq "$WORK_DIR/build-artifacts.zip" >/dev/null 2>&1; then
      downloaded="true"
      break
    fi
    echo "Artifact $artifact_id not downloadable yet (attempt $attempt/18): $(head -c 200 "$WORK_DIR/artifact-dl.err" | tr '\n' ' ')"
    sleep 10
  done
  if [[ "$downloaded" != "true" ]]; then
    echo "ERROR: Could not download artifact $artifact_id after 18 attempts" >&2
    return 1
  fi
  unzip -o -q "$WORK_DIR/build-artifacts.zip" -d "$ARTIFACTS_DIR"
  rm -f "$WORK_DIR/build-artifacts.zip"
  if [[ ! -f "$ARTIFACTS_DIR/DokanSetup.exe" ]]; then
    echo "ERROR: Downloaded artifact $artifact_id does not contain DokanSetup.exe" >&2
    return 1
  fi
}

echo "=== [$(date -u +%T)] Booting network-isolated KVM guest (restrict=on, shard=${SHARD}, simulate=${SIMULATE}) ==="
T_BOOT0=$(date +%s)
start_qemu
# Retry initial boot once if Windows stalls on the early boot logo under nested KVM
if ! wait_for_ssh 90; then
  echo "WARNING: Guest did not reach SSH within 90s; resetting fresh CoW overlay and retrying once..." >&2
  T_BOOT0=$(date +%s)
  start_qemu
  wait_for_ssh 150
fi
T_BOOT1=$(date +%s)
echo "=== [$(date -u +%T)] Guest SSH ready in $((T_BOOT1 - T_BOOT0))s ==="

T_ART0=$(date +%s)
if [[ "$SIMULATE" != "idle" ]]; then
  fetch_build_artifacts
fi
T_ART1=$(date +%s)
echo "=== [$(date -u +%T)] Build artifacts ready (waited $((T_ART1 - T_ART0))s after guest boot) ==="

echo "=== [$(date -u +%T)] Copying build artifacts and test scripts into guest ==="
ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 'New-Item -ItemType Directory -Force -Path C:\ci | Out-Null'
scp "${SCP_OPTS[@]}" \
  "$REPO_ROOT/scripts/run_ifstest.ps1" \
  "$REPO_ROOT/scripts/ci_kvm/guest_test.ps1" \
  "Administrator@127.0.0.1:C:/ci/"
if [[ "$SIMULATE" != "idle" ]]; then
  scp "${SCP_OPTS[@]}" "$ARTIFACTS_DIR/DokanSetup.exe" "$ARTIFACTS_DIR/fsx.exe" "Administrator@127.0.0.1:C:/ci/"
fi

if [[ -f "$ARTIFACTS_DIR/dokan_fstest.exe" ]]; then
  echo "Staging dokan_fstest.exe + baselines into guest..."
  scp "${SCP_OPTS[@]}" "$ARTIFACTS_DIR/dokan_fstest.exe" "Administrator@127.0.0.1:C:/ci/"
  if [[ -d "$ARTIFACTS_DIR/baselines" ]]; then
    scp "${SCP_OPTS[@]}" -r "$ARTIFACTS_DIR/baselines" "Administrator@127.0.0.1:C:/ci/"
  fi
fi

GUEST_CMD="& C:\ci\guest_test.ps1 -Shard '${SHARD}'"
case "$SIMULATE" in
  bugcheck) GUEST_CMD="${GUEST_CMD} -SimulateBsod" ;;
  nmi) GUEST_CMD="${GUEST_CMD} -SimulateHang" ;;
  idle) GUEST_CMD="${GUEST_CMD} -SkipInstall -IdleMinutes ${CANARY_IDLE_MINUTES}" ;;
  idle-dokan) GUEST_CMD="${GUEST_CMD} -IdleMinutes ${CANARY_IDLE_MINUTES}" ;;
esac

echo "=== [$(date -u +%T)] Executing Dokan install + Driver Verifier + FS tests (${GUEST_CMD}, timeout ${GUEST_TEST_TIMEOUT}s) ==="
T_TEST0=$(date +%s)
set +e
timeout --signal=TERM "$GUEST_TEST_TIMEOUT" ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 "$GUEST_CMD"
TEST_RC=$?
set -e
T_TEST1=$(date +%s)
echo "=== [$(date -u +%T)] Guest test script exited with code $TEST_RC in $((T_TEST1 - T_TEST0))s ==="

NMI_INJECTED="false"
inject_nmi() {
  echo "=== [$(date -u +%T)] Guest appears hung: capturing screen and injecting NMI (NMICrashDump=1 -> BugCheck 0x80) ==="
  qemu_monitor "screendump $RESULTS_DIR/hang-screen.ppm" >/dev/null
  qemu_monitor "nmi" >/dev/null
  NMI_INJECTED="true"
}

BSOD_HARVESTED="false"
harvest_bsod_if_any() {
  echo "=== [$(date -u +%T)] Checking for BSOD / hang and harvesting logs ==="
  local guest_back="false"
  if [[ $TEST_RC -eq 124 ]]; then
    echo "Guest test exceeded ${GUEST_TEST_TIMEOUT}s."
    inject_nmi
    wait_for_ssh 480 && guest_back="true"
  elif [[ $TEST_RC -ne 0 ]]; then
    # SSH may have dropped because of a real BugCheck: give Windows time to write the dump and reboot
    sleep 8
    if wait_for_ssh 180; then
      guest_back="true"
    elif kill -0 "$QEMU_PID" 2>/dev/null; then
      inject_nmi
      wait_for_ssh 480 && guest_back="true"
    fi
  else
    wait_for_ssh 60 && guest_back="true"
  fi

  if [[ "$guest_back" == "true" ]]; then
    local bsod_check_rc=0
    ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 '
      # Wait up to ~45s for the crash dump to be finalized as C:\Windows\MEMORY.DMP after reboot
      for ($w = 0; $w -lt 15; $w++) {
        if (Test-Path "C:\Windows\MEMORY.DMP") {
          $len1 = (Get-Item "C:\Windows\MEMORY.DMP").Length
          Start-Sleep -Seconds 3
          $len2 = (Get-Item "C:\Windows\MEMORY.DMP").Length
          if ($len2 -gt 0 -and $len1 -eq $len2) { break }
        } else {
          $bc = Get-WinEvent -FilterHashtable @{LogName="System"; Id=1001; ProviderName="Microsoft-Windows-WER-SystemErrorReporting"} -ErrorAction SilentlyContinue | Select-Object -First 1
          if (-not $bc -and $w -ge 2) { break }
          Start-Sleep -Seconds 3
        }
      }
      $bugchecks = Get-WinEvent -FilterHashtable @{LogName="System"; Id=1001; ProviderName="Microsoft-Windows-WER-SystemErrorReporting"} -ErrorAction SilentlyContinue | Select-Object -First 3
      if ($bugchecks) {
        Write-Host "=== BUGCHECK DETECTED IN EVENT LOG ==="
        $bugchecks | Format-List TimeCreated, Message | Out-String | Write-Host
      }
      if (Test-Path "C:\Windows\MEMORY.DMP") {
        Get-Item "C:\Windows\MEMORY.DMP" | Format-List FullName, Length, LastWriteTime
        exit 42
      }
    ' || bsod_check_rc=$?
    scp "${SCP_OPTS[@]}" "Administrator@127.0.0.1:C:/ci/dokan_install*.log" "$RESULTS_DIR/" 2>/dev/null || true
    scp "${SCP_OPTS[@]}" -r "Administrator@127.0.0.1:C:/ci/fstest-results" "$RESULTS_DIR/" 2>/dev/null || true
    if [[ $bsod_check_rc -eq 42 ]]; then
      echo "Downloading C:\Windows\MEMORY.DMP from guest..."
      local t0 t1
      t0=$(date +%s)
      scp "${SCP_OPTS[@]}" "Administrator@127.0.0.1:C:/Windows/MEMORY.DMP" "$WORK_DIR/MEMORY.DMP"
      ls -lh "$WORK_DIR/MEMORY.DMP"
      7z a -t7z -mx=3 "$RESULTS_DIR/MEMORY.DMP.7z" "$WORK_DIR/MEMORY.DMP" >/dev/null
      rm -f "$WORK_DIR/MEMORY.DMP"
      t1=$(date +%s)
      echo "Saved compressed crash dump to $RESULTS_DIR/MEMORY.DMP.7z ($(du -h "$RESULTS_DIR/MEMORY.DMP.7z" | awk '{print $1}')) in $((t1 - t0))s"
      BSOD_HARVESTED="true"
      if [[ "$NMI_INJECTED" == "true" ]]; then
        echo "HANG_NMI_DUMP" > "$RESULTS_DIR/HANG_DETECTED"
      else
        echo "BSOD_DETECTED" > "$RESULTS_DIR/BSOD_DETECTED"
      fi
      ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 'shutdown /s /t 0' 2>/dev/null || true
      wait "$QEMU_PID" 2>/dev/null || true
      return 1
    fi
    ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 'shutdown /s /t 0' 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    if [[ "$NMI_INJECTED" == "true" ]]; then
      echo "ERROR: NMI was injected but no MEMORY.DMP was produced." >&2
      return 1
    fi
    return 0
  fi

  echo "Guest did not return over SSH; attempting offline disk harvest..."
  kill "$QEMU_PID" 2>/dev/null || true
  wait "$QEMU_PID" 2>/dev/null || true
  if command -v qemu-nbd >/dev/null 2>&1; then
    sudo modprobe nbd max_part=8 || true
    sudo qemu-nbd --read-only --connect=/dev/nbd0 "$OVERLAY_IMG" || true
    sleep 2
    mkdir -p "$WORK_DIR/mnt"
    if sudo mount -o ro /dev/nbd0p2 "$WORK_DIR/mnt" 2>/dev/null; then
      if [[ -f "$WORK_DIR/mnt/Windows/MEMORY.DMP" ]]; then
        echo "Found offline C:\Windows\MEMORY.DMP!"
        7z a -t7z -mx=3 "$RESULTS_DIR/MEMORY.DMP.7z" "$WORK_DIR/mnt/Windows/MEMORY.DMP" >/dev/null
        BSOD_HARVESTED="true"
        echo "BSOD_DETECTED" > "$RESULTS_DIR/BSOD_DETECTED"
      fi
      cp "$WORK_DIR/mnt/ci/"dokan_install*.log "$RESULTS_DIR/" 2>/dev/null || true
      cp -r "$WORK_DIR/mnt/ci/fstest-results" "$RESULTS_DIR/" 2>/dev/null || true
      sudo umount "$WORK_DIR/mnt" || true
    fi
    sudo qemu-nbd --disconnect /dev/nbd0 || true
  fi
  return 1
}

BSOD_RC=0
harvest_bsod_if_any || BSOD_RC=$?

echo "=== Summary Timings ==="
echo "VM boot to SSH:          $((T_BOOT1 - T_BOOT0))s"
echo "Wait for build artifact: $((T_ART1 - T_ART0))s"
echo "Test duration:           $((T_TEST1 - T_TEST0))s"
echo "NMI injected:            ${NMI_INJECTED}"
echo "Crash dump harvested:    ${BSOD_HARVESTED}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "bsod_detected=${BSOD_HARVESTED}" >> "$GITHUB_OUTPUT"
fi

if [[ "$SIMULATE" == "bugcheck" || "$SIMULATE" == "nmi" ]]; then
  if [[ "$BSOD_HARVESTED" == "true" ]]; then
    echo "=== SIMULATED ${SIMULATE^^} SELF-TEST: MEMORY.DMP.7z successfully harvested ==="
    exit 0
  fi
  echo "ERROR: simulate=${SIMULATE} but no MEMORY.DMP was harvested!" >&2
  exit 1
fi

if [[ $TEST_RC -ne 0 ]] || [[ $BSOD_RC -ne 0 ]]; then
  exit 1
fi
