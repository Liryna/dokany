#!/usr/bin/env bash
set -euo pipefail

IMAGE_DIR="${1:?usage: run_kvm_tests.sh <image_dir> <artifacts_dir> <results_dir> [shard] [simulate_bsod]}"
ARTIFACTS_DIR="${2:?usage: run_kvm_tests.sh <image_dir> <artifacts_dir> <results_dir> [shard] [simulate_bsod]}"
RESULTS_DIR="${3:?usage: run_kvm_tests.sh <image_dir> <artifacts_dir> <results_dir> [shard] [simulate_bsod]}"
SHARD="${4:-all}"
SIMULATE_BSOD="${5:-false}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${RUNNER_TEMP:-/tmp}/kvm-test-run"
mkdir -p "$WORK_DIR" "$RESULTS_DIR"

BASE_IMG="$IMAGE_DIR/base.qcow2"
SSH_KEY="$IMAGE_DIR/id_ed25519"
OVERLAY_IMG="$WORK_DIR/overlay.qcow2"
SERIAL_LOG="$RESULTS_DIR/serial.log"

chmod 600 "$SSH_KEY"
rm -f "$OVERLAY_IMG"
qemu-img create -f qcow2 -b "$BASE_IMG" -F qcow2 "$OVERLAY_IMG"

: > "$SERIAL_LOG"
QEMU_PID=""
cleanup() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "=== [$(date -u +%T)] Booting network-isolated KVM guest (restrict=on, shard=${SHARD}, simulate_bsod=${SIMULATE_BSOD}) ==="
T_BOOT0=$(date +%s)
qemu-system-x86_64 \
  -enable-kvm \
  -machine q35,accel=kvm \
  -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
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
      echo "ERROR: Timed out after ${max_wait}s waiting for guest SSH. Verbose SSH probe:" >&2
      ssh -v "${SSH_OPTS[@]}" Administrator@127.0.0.1 'echo SSH_READY' 2>&1 | tail -n 50 >&2 || true
      echo "Capturing QEMU screendump to $RESULTS_DIR/boot-screen.ppm..." >&2
      printf 'screendump %s/boot-screen.ppm\ninfo status\ninfo network\n' "$RESULTS_DIR" | socat - "UNIX-CONNECT:${WORK_DIR}/mon.sock" 2>&1 || true
      return 1
    fi
    sleep 3
  done
}

wait_for_ssh 180
T_BOOT1=$(date +%s)
echo "=== [$(date -u +%T)] Guest SSH ready in $((T_BOOT1 - T_BOOT0))s ==="

echo "=== [$(date -u +%T)] Copying build artifacts and test scripts into guest ==="
ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 'New-Item -ItemType Directory -Force -Path C:\ci | Out-Null'
scp "${SCP_OPTS[@]}" \
  "$ARTIFACTS_DIR/DokanSetup.exe" \
  "$ARTIFACTS_DIR/fsx.exe" \
  "$REPO_ROOT/scripts/run_ifstest.ps1" \
  "$REPO_ROOT/scripts/ci_kvm/guest_test.ps1" \
  "Administrator@127.0.0.1:C:/ci/"

if [[ -f "$ARTIFACTS_DIR/dokan_fstest.exe" ]]; then
  echo "Staging dokan_fstest.exe + baselines into guest..."
  scp "${SCP_OPTS[@]}" "$ARTIFACTS_DIR/dokan_fstest.exe" "Administrator@127.0.0.1:C:/ci/"
  if [[ -d "$ARTIFACTS_DIR/baselines" ]]; then
    scp "${SCP_OPTS[@]}" -r "$ARTIFACTS_DIR/baselines" "Administrator@127.0.0.1:C:/ci/"
  fi
fi

GUEST_CMD="& C:\ci\guest_test.ps1 -Shard '${SHARD}'"
if [[ "$SIMULATE_BSOD" == "true" ]]; then
  GUEST_CMD="${GUEST_CMD} -SimulateBsod"
fi

echo "=== [$(date -u +%T)] Executing Dokan install + Driver Verifier + FS tests (${GUEST_CMD}) ==="
T_TEST0=$(date +%s)
set +e
ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 "$GUEST_CMD"
TEST_RC=$?
set -e
T_TEST1=$(date +%s)
echo "=== [$(date -u +%T)] Guest test script exited with code $TEST_RC in $((T_TEST1 - T_TEST0))s ==="

# Harvest logs, fstest scorecards, and check for BSOD (even if SSH dropped mid-test due to a bugcheck!)
BSOD_HARVESTED="false"
harvest_bsod_if_any() {
  echo "=== [$(date -u +%T)] Checking for BSOD / MEMORY.DMP and harvesting logs ==="
  # If SSH dropped (e.g. rc=255 during BSOD), give Windows a few seconds to begin writing crash dump + rebooting
  if [[ $TEST_RC -ne 0 ]]; then
    sleep 8
  fi
  if wait_for_ssh 180; then
    local bsod_check_rc=0
    ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 '
      # Wait up to 45s for SaveDump/WER to finish copying pagefile to C:\Windows\MEMORY.DMP after reboot
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
      T_DMP0=$(date +%s)
      scp "${SCP_OPTS[@]}" "Administrator@127.0.0.1:C:/Windows/MEMORY.DMP" "$WORK_DIR/MEMORY.DMP"
      ls -lh "$WORK_DIR/MEMORY.DMP"
      7z a -t7z -mx=3 "$RESULTS_DIR/MEMORY.DMP.7z" "$WORK_DIR/MEMORY.DMP" >/dev/null
      rm -f "$WORK_DIR/MEMORY.DMP"
      T_DMP1=$(date +%s)
      echo "Saved compressed crash dump to $RESULTS_DIR/MEMORY.DMP.7z ($(du -h "$RESULTS_DIR/MEMORY.DMP.7z" | awk '{print $1}')) in $((T_DMP1 - T_DMP0))s"
      BSOD_HARVESTED="true"
      echo "BSOD_DETECTED" > "$RESULTS_DIR/BSOD_DETECTED"
      ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 'shutdown /s /t 0' 2>/dev/null || true
      wait "$QEMU_PID" 2>/dev/null || true
      return 1
    fi
    ssh "${SSH_OPTS[@]}" Administrator@127.0.0.1 'shutdown /s /t 0' 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    return 0
  else
    echo "Guest did not return over SSH (possible hang/boot-loop); attempting offline disk harvest..."
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
  fi
}

BSOD_RC=0
harvest_bsod_if_any || BSOD_RC=$?

echo "=== Summary Timings ==="
echo "VM boot to SSH:  $((T_BOOT1 - T_BOOT0))s"
echo "Test duration:   $((T_TEST1 - T_TEST0))s"
echo "BSOD harvested:  ${BSOD_HARVESTED}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "bsod_detected=${BSOD_HARVESTED}" >> "$GITHUB_OUTPUT"
fi

if [[ "$SIMULATE_BSOD" == "true" ]]; then
  if [[ "$BSOD_HARVESTED" == "true" ]]; then
    echo "=== SIMULATED BSOD SELF-TEST: MEMORY.DMP.7z successfully harvested! ==="
    exit 0
  else
    echo "ERROR: SIMULATE_BSOD=true was set, but no MEMORY.DMP was harvested!" >&2
    exit 1
  fi
fi

if [[ $TEST_RC -ne 0 ]] || [[ $BSOD_RC -ne 0 ]]; then
  exit 1
fi
