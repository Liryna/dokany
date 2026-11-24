#!/usr/bin/env bash
set -euo pipefail

OS_ID="${1:?usage: bake_image.sh <server2025|server2022|server2019> <output_dir>}"
OUT_DIR="${2:?usage: bake_image.sh <server2025|server2022|server2019> <output_dir>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${RUNNER_TEMP:-/tmp}/kvm-bake-${OS_ID}"
mkdir -p "$WORK_DIR" "$OUT_DIR"

case "$OS_ID" in
  server2025)
    ISO_URL="https://go.microsoft.com/fwlink/?linkid=2293312&clcid=0x409&culture=en-us&country=us"
    IMAGE_INDEX="1" # Windows Server 2025 Standard Evaluation (Server Core)
    ;;
  server2022)
    ISO_URL="https://go.microsoft.com/fwlink/?linkid=2195280&clcid=0x409&culture=en-us&country=us"
    IMAGE_INDEX="1" # Windows Server 2022 Standard Evaluation (Server Core)
    ;;
  server2019)
    ISO_URL="https://go.microsoft.com/fwlink/?linkid=2195167&clcid=0x409&culture=en-us&country=us"
    IMAGE_INDEX="1" # Windows Server 2019 Standard Evaluation (Server Core)
    ;;
  *)
    echo "ERROR: Unsupported OS_ID '$OS_ID'" >&2
    exit 1
    ;;
esac

OPENSSH_URL="https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.4.0.0p1-Preview/OpenSSH-Win64.zip"

echo "=== [$(date -u +%T)] Checking KVM & disk space ==="
ls -la /dev/kvm
df -h / "$WORK_DIR"

echo "=== [$(date -u +%T)] Generating ephemeral SSH keypair for guest ==="
rm -f "$OUT_DIR/id_ed25519" "$OUT_DIR/id_ed25519.pub"
ssh-keygen -t ed25519 -N "" -f "$OUT_DIR/id_ed25519" -C "dokany-ci-kvm" >/dev/null
chmod 600 "$OUT_DIR/id_ed25519"

echo "=== [$(date -u +%T)] Downloading Windows Evaluation ISO ($OS_ID) ==="
T0=$(date +%s)
curl -fsSL --retry 3 --retry-delay 5 -o "$WORK_DIR/windows.iso" "$ISO_URL"
T1=$(date +%s)
echo "Downloaded windows.iso ($(du -h "$WORK_DIR/windows.iso" | awk '{print $1}')) in $((T1 - T0))s"

echo "=== [$(date -u +%T)] Downloading Win32-OpenSSH ==="
curl -fsSL --retry 3 --retry-delay 5 -o "$WORK_DIR/OpenSSH-Win64.zip" "$OPENSSH_URL"

echo "=== [$(date -u +%T)] Building seed ISO (autounattend.xml + setup-guest.ps1) ==="
SEED_DIR="$WORK_DIR/seed"
mkdir -p "$SEED_DIR"
cp "$OUT_DIR/id_ed25519.pub" "$SEED_DIR/authorized_keys"
cp "$REPO_ROOT/cert/DokanCA.cer" "$SEED_DIR/DokanCA.cer"
cp "$REPO_ROOT/scripts/install_wlk_ifstest.ps1" "$SEED_DIR/install_wlk_ifstest.ps1"
cp "$WORK_DIR/OpenSSH-Win64.zip" "$SEED_DIR/OpenSSH-Win64.zip"

cat > "$SEED_DIR/autounattend.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Size>500</Size>
              <Type>Primary</Type>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Extend>true</Extend>
              <Type>Primary</Type>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Label>System</Label>
              <Format>NTFS</Format>
              <Active>true</Active>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>2</PartitionID>
              <Label>Windows</Label>
              <Letter>C</Letter>
              <Format>NTFS</Format>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/INDEX</Key>
              <Value>${IMAGE_INDEX}</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>2</PartitionID>
          </InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>DokanCI</FullName>
        <Organization>Dokany</Organization>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>dokan-ci</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <fDenyTSConnections>true</fDenyTSConnections>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserAccounts>
        <AdministratorPassword>
          <Value>DokanCI!Pass123</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>Administrator</Username>
        <Password>
          <Value>DokanCI!Pass123</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>cmd /c "for %i in (D E F G H) do if exist %i:\run-bake.cmd call %i:\run-bake.cmd %i:"</CommandLine>
          <Description>Provision Dokan CI guest image</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
    </component>
  </settings>
</unattend>
EOF

cat > "$SEED_DIR/setup-guest.ps1" <<'PSEOF'
param([string]$SeedDrive = 'E:')
$ErrorActionPreference = 'Stop'

$logFile = 'C:\ci-bake.log'
function Log($msg) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
    Add-Content -Path $logFile -Value $line
    Write-Output $line
}

try {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Log "Guest booted: $($cv.ProductName) build $($cv.CurrentBuildNumber).$($cv.UBR)"

    # 1. Disable Windows Update & Defender real-time overhead for deterministic CI
    Log "Disabling Windows Update and adding Defender exclusions..."
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Set-Service wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
    if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
        try {
            Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
            foreach ($excl in @('C:\ci', 'C:\FSTMP', 'C:\FSTMP2', 'C:\DokanMount', 'M:\')) {
                Add-MpPreference -ExclusionPath $excl -ErrorAction SilentlyContinue
            }
        } catch { }
    }

    # Copy seed files to local writable temp dir before using them
    $localSeed = 'C:\Windows\Temp\seed'
    New-Item -ItemType Directory -Force -Path $localSeed | Out-Null
    Copy-Item -Path "$SeedDrive\*" -Destination $localSeed -Recurse -Force

    # 2. Import Dokan test CA certificate (certutil works reliably on headless Server Core)
    Log "Importing DokanCA.cer..."
    & certutil.exe -addstore -f Root "$localSeed\DokanCA.cer" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "certutil Root failed: $LASTEXITCODE" }
    & certutil.exe -addstore -f TrustedPublisher "$localSeed\DokanCA.cer" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "certutil TrustedPublisher failed: $LASTEXITCODE" }

    # 3. Enable TESTSIGNING and pre-arm Driver Verifier for dokan3.sys
    Log "Enabling TESTSIGNING and Driver Verifier for dokan3.sys..."
    & bcdedit.exe /set testsigning on | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "bcdedit testsigning failed: $LASTEXITCODE" }
    $vOut = (& verifier.exe /standard /driver dokan3.sys 2>&1 | Out-String).Trim()
    # verifier.exe exit code 2 = EXIT_CODE_REBOOT_REQUIRED (success; changes take effect on next boot)
    Log "verifier exit=${LASTEXITCODE}: $vOut"
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) { throw "verifier config failed: $LASTEXITCODE" }

    # 4. Configure Kernel Memory Dump (CrashDumpEnabled=2 -> C:\Windows\MEMORY.DMP) + AutoReboot
    Log "Configuring Kernel Memory Dump (MEMORY.DMP)..."
    $cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
    Set-ItemProperty -Path $cc -Name 'CrashDumpEnabled' -Type DWord -Value 2
    Set-ItemProperty -Path $cc -Name 'DumpFile' -Type ExpandString -Value '%SystemRoot%\MEMORY.DMP'
    Set-ItemProperty -Path $cc -Name 'Overwrite' -Type DWord -Value 1
    Set-ItemProperty -Path $cc -Name 'AutoReboot' -Type DWord -Value 1
    # Ensure pagefile is large enough on C: for kernel memory dump
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'PagingFiles' -Type MultiString -Value @('C:\pagefile.sys 2048 4096')

    # 5. Install Win32-OpenSSH from local seed copy
    Log "Installing Win32-OpenSSH..."
    $sshDest = 'C:\Program Files\OpenSSH'
    New-Item -ItemType Directory -Force -Path $sshDest | Out-Null
    Expand-Archive -Path "$localSeed\OpenSSH-Win64.zip" -DestinationPath 'C:\Windows\Temp\openssh-extract' -Force
    $inner = Get-ChildItem 'C:\Windows\Temp\openssh-extract' -Directory | Select-Object -First 1
    if ($inner) {
        Copy-Item -Path "$($inner.FullName)\*" -Destination $sshDest -Recurse -Force
    } else {
        Copy-Item -Path 'C:\Windows\Temp\openssh-extract\*' -Destination $sshDest -Recurse -Force
    }
    Remove-Item 'C:\Windows\Temp\openssh-extract' -Recurse -Force
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$sshDest\install-sshd.ps1"
    Set-Service sshd -StartupType Automatic
    Start-Service sshd
    Start-Sleep -Seconds 2

    # Configure authorized_keys for Administrators
    $sshData = 'C:\ProgramData\ssh'
    New-Item -ItemType Directory -Force -Path $sshData | Out-Null
    $authKeys = "$sshData\administrators_authorized_keys"
    Copy-Item -LiteralPath "$localSeed\authorized_keys" -Destination $authKeys -Force
    & icacls.exe $authKeys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null

    # Set PowerShell as default SSH shell and open firewall port 22
    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue | Out-Null

    # 6. Create dokan_ifstest user & install HLK IFSTest
    Log "Creating dokan_ifstest user..."
    & net.exe user dokan_ifstest D0kan_1fstest /ADD
    if ($LASTEXITCODE -ne 0) { throw "net user failed: $LASTEXITCODE" }

    Log "Installing WLK/HLK IFSTest..."
    $env:WLK_INST_CACHE = 'C:\Windows\Temp\wlk_inst'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$localSeed\install_wlk_ifstest.ps1"
    if ($LASTEXITCODE -ne 0) { throw "install_wlk_ifstest.ps1 failed: $LASTEXITCODE" }
    Remove-Item -Path 'C:\Windows\Temp\wlk_inst' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $localSeed -Recurse -Force -ErrorAction SilentlyContinue

    # 7. Shrink disk before shutdown so zstd qcow2 compresses cleanly
    Log "Cleaning temp files and zeroing free space for compression..."
    Remove-Item -Path 'C:\Windows\Temp\*' -Recurse -Force -ErrorAction SilentlyContinue
    # Disable hibernation to eliminate hiberfil.sys
    & powercfg.exe /h off | Out-Null

    # Zero free blocks using a sparse-disabled zero stream (capped to avoid filling disk)
    $drive = Get-PSDrive C
    $freeBytes = [int64]($drive.Free - 256MB)
    if ($freeBytes -gt 0) {
        $zeroPath = 'C:\zero.tmp'
        $buf = New-Object byte[] (4MB)
        $fs = [System.IO.File]::Open($zeroPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $written = [int64]0
            while ($written -lt $freeBytes) {
                $chunk = [Math]::Min($buf.Length, $freeBytes - $written)
                $fs.Write($buf, 0, [int]$chunk)
                $written += $chunk
            }
            $fs.Flush()
        } catch {
            # Ignore disk-full edge case
        } finally {
            $fs.Close()
            Remove-Item -LiteralPath $zeroPath -Force -ErrorAction SilentlyContinue
        }
    }

    Log "BAKE_SUCCESS: Provisioning finished."
    exit 0
} catch {
    Log "BAKE_FAILED: $($_.Exception.Message)"
    Log ($_.ScriptStackTrace | Out-String)
    exit 1
}
PSEOF

cat > "$SEED_DIR/run-bake.cmd" <<'CMDEOF'
@echo off
echo [run-bake.cmd] Starting setup-guest.ps1 from %1 > COM1:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File %1\setup-guest.ps1 %1 > COM1: 2>&1
set RC=%ERRORLEVEL%
echo [run-bake.cmd] setup-guest.ps1 exited with RC=%RC% > COM1:
shutdown.exe /s /t 2
CMDEOF
sed -i 's/$/\r/' "$SEED_DIR/run-bake.cmd"

python3 -c "import xml.etree.ElementTree as ET; ET.parse('$SEED_DIR/autounattend.xml')"
genisoimage -quiet -J -r -V "DOKANSEED" -o "$WORK_DIR/seed.iso" "$SEED_DIR"

echo "=== [$(date -u +%T)] Creating 20G raw qcow2 disk ==="
qemu-img create -f qcow2 "$WORK_DIR/base-raw.qcow2" 20G

SERIAL_LOG="$WORK_DIR/serial.log"
: > "$SERIAL_LOG"

echo "=== [$(date -u +%T)] Starting unattended Windows Server Core install under QEMU/KVM ==="
T_BOOT=$(date +%s)
tail -f "$SERIAL_LOG" &
TAIL_PID=$!
trap 'kill $TAIL_PID 2>/dev/null || true' EXIT

# Timeout at 20 minutes so a stuck install never hangs the runner
set +e
timeout 1200 qemu-system-x86_64 \
  -enable-kvm \
  -machine q35,accel=kvm \
  -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
  -smp 4 \
  -m 6G \
  -display none \
  -serial "file:${SERIAL_LOG}" \
  -device ahci,id=ahci \
  -drive "file=$WORK_DIR/base-raw.qcow2,format=qcow2,if=none,id=hd0,cache=unsafe,discard=unmap" \
  -device ide-hd,drive=hd0,bus=ahci.0 \
  -drive "file=$WORK_DIR/windows.iso,media=cdrom,if=none,id=cd0" \
  -device ide-cd,drive=cd0,bus=ahci.1 \
  -drive "file=$WORK_DIR/seed.iso,media=cdrom,if=none,id=cd1" \
  -device ide-cd,drive=cd1,bus=ahci.2 \
  -netdev user,id=net0 \
  -device e1000e,netdev=net0 \
  -boot order=dc
QEMU_RC=$?
set -e

kill "$TAIL_PID" 2>/dev/null || true
T_END=$(date +%s)
echo "=== [$(date -u +%T)] QEMU exited (rc=$QEMU_RC) after $((T_END - T_BOOT))s ==="

if [[ $QEMU_RC -ne 0 ]] || ! grep -q "BAKE_SUCCESS" "$SERIAL_LOG"; then
  echo "ERROR: Bake failed (qemu rc=$QEMU_RC) or BAKE_SUCCESS marker not found!" >&2
  cat "$SERIAL_LOG" >&2
  exit 1
fi

echo "=== [$(date -u +%T)] Removing Windows ISO to free space before compression ==="
rm -f "$WORK_DIR/windows.iso" "$WORK_DIR/seed.iso"
df -h / "$WORK_DIR"

echo "=== [$(date -u +%T)] Compressing base image with qcow2 zstd ==="
T_COMP0=$(date +%s)
qemu-img convert -O qcow2 -c -o compression_type=zstd "$WORK_DIR/base-raw.qcow2" "$OUT_DIR/base.qcow2"
T_COMP1=$(date +%s)
rm -f "$WORK_DIR/base-raw.qcow2"

echo "=== [$(date -u +%T)] Image bake complete! ==="
echo "Raw install+provision time: $((T_END - T_BOOT))s"
echo "zstd compression time:      $((T_COMP1 - T_COMP0))s"
ls -lh "$OUT_DIR/base.qcow2"
qemu-img info "$OUT_DIR/base.qcow2"
