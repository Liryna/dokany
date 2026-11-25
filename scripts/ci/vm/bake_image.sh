#!/usr/bin/env bash
# Bakes a test-ready Windows Server Core qcow2 image under QEMU/KVM (unattended install + provisioning).
#
# Usage: bake_image.sh <server2016|server2019|server2022|server2025> <output_dir>
#
# Output (<output_dir>): base.qcow2 (compacted, uncompressed; actions/cache compresses it with zstd)
# and id_ed25519 (the key authorized for SSH into the guest as Administrator).
set -euo pipefail

usage='usage: bake_image.sh <server2016|server2019|server2022|server2025> <output_dir>'
OS_ID="${1:?$usage}"
OUT_DIR="${2:?$usage}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROVISIONING_DIR="$SCRIPT_DIR/provisioning"
WORK_DIR="${RUNNER_TEMP:-/tmp}/vm-bake-${OS_ID}"
mkdir -p "$WORK_DIR" "$OUT_DIR"

# Microsoft evaluation media. Image index 1 = Standard Evaluation (Server Core) on all four ISOs.
case "$OS_ID" in
  server2016) ISO_URL="https://software-download.microsoft.com/download/pr/Windows_Server_2016_Datacenter_EVAL_en-us_14393_refresh.ISO" ;;
  server2019) ISO_URL="https://go.microsoft.com/fwlink/?linkid=2195167&clcid=0x409&culture=en-us&country=us" ;;
  server2022) ISO_URL="https://go.microsoft.com/fwlink/?linkid=2195280&clcid=0x409&culture=en-us&country=us" ;;
  server2025) ISO_URL="https://go.microsoft.com/fwlink/?linkid=2293312&clcid=0x409&culture=en-us&country=us" ;;
  *) echo "ERROR: unsupported OS '$OS_ID'. $usage" >&2; exit 2 ;;
esac
IMAGE_INDEX=1

OPENSSH_URL="https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.4.0.0p1-Preview/OpenSSH-Win64.zip"
OPENSSH_SHA256="b67ff8becd203502190ec42ac7787c24c2cd3325ed7700485fe7a1c83d2a7957"

log() { echo "=== [$(date -u +%T)] $* ==="; }

log "Host CPU: $(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -n1)"

log "Downloading Windows evaluation ISO ($OS_ID)"
t0=$(date +%s)
curl -fsSL --retry 3 --retry-delay 5 -o "$WORK_DIR/windows.iso" "$ISO_URL"
echo "windows.iso: $(du -h "$WORK_DIR/windows.iso" | cut -f1) in $(( $(date +%s) - t0 ))s, sha256 $(sha256sum "$WORK_DIR/windows.iso" | cut -d' ' -f1)"

log "Downloading Win32-OpenSSH"
curl -fsSL --retry 3 --retry-delay 5 -o "$WORK_DIR/OpenSSH-Win64.zip" "$OPENSSH_URL"
echo "$OPENSSH_SHA256  $WORK_DIR/OpenSSH-Win64.zip" | sha256sum --check --quiet

log "Building seed ISO"
SEED_DIR="$WORK_DIR/seed"
rm -rf "$SEED_DIR"
mkdir -p "$SEED_DIR"
rm -f "$OUT_DIR/id_ed25519" "$OUT_DIR/id_ed25519.pub"
ssh-keygen -q -t ed25519 -N "" -C "dokany-ci" -f "$OUT_DIR/id_ed25519"
cp "$OUT_DIR/id_ed25519.pub" "$SEED_DIR/authorized_keys"
cp "$WORK_DIR/OpenSSH-Win64.zip" "$REPO_ROOT/cert/DokanCA.cer" "$REPO_ROOT/scripts/install_wlk_ifstest.ps1" \
   "$PROVISIONING_DIR/provision_guest.ps1" "$SEED_DIR/"
sed "s/@IMAGE_INDEX@/$IMAGE_INDEX/" "$PROVISIONING_DIR/autounattend.xml" > "$SEED_DIR/autounattend.xml"
sed 's/\r$//; s/$/\r/' "$PROVISIONING_DIR/run_provisioning.cmd" > "$SEED_DIR/run_provisioning.cmd"
xmllint --noout "$SEED_DIR/autounattend.xml"
genisoimage -quiet -J -r -V DOKANSEED -o "$WORK_DIR/seed.iso" "$SEED_DIR"

SERIAL_LOG="$WORK_DIR/serial.log"
DIAG_DIR="$WORK_DIR/diag"
MON_SOCK="$WORK_DIR/monitor.sock"
rm -rf "$DIAG_DIR"
mkdir -p "$DIAG_DIR"

# Screenshot every 2 minutes (uploaded on failure). While the guest has not reached provisioning
# (empty serial log), 4 identical screenshots in a row mean the installer is stuck, typically on the
# boot logo under nested KVM: stop QEMU so the install can be retried.
watch_install() {
  local i=0 last="" same=0 sum
  while sleep 120; do
    i=$((i + 1))
    printf 'screendump %s/screen-%03d.ppm\n' "$DIAG_DIR" "$i" | socat - "UNIX-CONNECT:$MON_SOCK" >/dev/null 2>&1 || continue
    sleep 2
    [[ -s "$SERIAL_LOG" ]] && continue
    sum=$(md5sum "$DIAG_DIR/screen-$(printf %03d "$i").ppm" 2>/dev/null | cut -d' ' -f1)
    if [[ -n "$sum" && "$sum" == "$last" ]]; then same=$((same + 1)); else same=0; fi
    last="$sum"
    if (( same >= 3 )); then
      echo "Installer screen unchanged for 8 minutes; stopping QEMU." >&2
      touch "$WORK_DIR/install-stalled"
      pkill -f "qemu-system-x86_64.*$WORK_DIR/install.qcow2" || true
      return
    fi
  done
}

install_windows() {
  qemu-img create -q -f qcow2 "$WORK_DIR/install.qcow2" 20G
  : > "$SERIAL_LOG"
  rm -f "$MON_SOCK" "$WORK_DIR/install-stalled"
  tail -f "$SERIAL_LOG" &
  local tail_pid=$!
  watch_install &
  local watch_pid=$!
  local rc=0
  # 30 minute cap: install (~5-10 min) + provisioning incl. HLK download and DISM component cleanup.
  timeout 1800 qemu-system-x86_64 \
    -enable-kvm \
    -machine q35,accel=kvm \
    -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
    -smp 4 \
    -m 6G \
    -display none \
    -vga std \
    -monitor "unix:$MON_SOCK,server,nowait" \
    -serial "file:$SERIAL_LOG" \
    -device ahci,id=ahci \
    -drive "file=$WORK_DIR/install.qcow2,format=qcow2,if=none,id=hd0,cache=unsafe,discard=unmap" \
    -device ide-hd,drive=hd0,bus=ahci.0 \
    -drive "file=$WORK_DIR/windows.iso,media=cdrom,if=none,id=cd0" \
    -device ide-cd,drive=cd0,bus=ahci.1 \
    -drive "file=$WORK_DIR/seed.iso,media=cdrom,if=none,id=cd1" \
    -device ide-cd,drive=cd1,bus=ahci.2 \
    -netdev user,id=net0 \
    -device e1000e,netdev=net0 \
    -boot order=dc || rc=$?
  kill "$tail_pid" "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  return "$rc"
}

for attempt in 1 2; do
  log "Installing and provisioning Windows ($OS_ID) under QEMU/KVM (attempt $attempt)"
  t0=$(date +%s)
  qemu_rc=0
  install_windows || qemu_rc=$?
  echo "QEMU exited with code $qemu_rc after $(( $(date +%s) - t0 ))s"
  if [[ $qemu_rc -eq 0 ]] && grep -q PROVISIONING_SUCCEEDED "$SERIAL_LOG"; then
    break
  fi
  if [[ -f "$WORK_DIR/install-stalled" && $attempt -eq 1 ]]; then
    echo "WARNING: installer stalled; retrying with a fresh disk." >&2
    mv "$DIAG_DIR" "$WORK_DIR/diag-attempt1"
    mkdir -p "$DIAG_DIR"
    continue
  fi
  echo "ERROR: install/provisioning failed (QEMU exit code $qemu_rc, no PROVISIONING_SUCCEEDED marker)." >&2
  exit 1
done

log "Compacting image"
rm -f "$WORK_DIR/windows.iso" "$WORK_DIR/seed.iso"
# Drops the zeroed free space and the pagefile cleared at shutdown. No extra compression here:
# actions/cache already compresses with 'zstd --long=30' and decompresses inline on restore.
qemu-img convert -O qcow2 "$WORK_DIR/install.qcow2" "$OUT_DIR/base.qcow2"
rm -f "$WORK_DIR/install.qcow2"
ls -lh "$OUT_DIR/base.qcow2"
