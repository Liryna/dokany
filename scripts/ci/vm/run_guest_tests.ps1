<#
.SYNOPSIS
    Runs inside the CI test VM: installs Dokan, checks Driver Verifier, and runs one test shard.

.DESCRIPTION
    Expects the C:\ci layout staged by run_vm_tests.sh:
        C:\ci\DokanSetup.exe
        C:\ci\fstest\dokan_fstest.exe, C:\ci\fstest\baselines\
        C:\ci\repo\samples\memfs_test.ps1, mirror_test.ps1, fstools\src\fsx\fsx.exe
        C:\ci\repo\scripts\run_ifstest.ps1, fstest_common.ps1
    The samples\ harnesses are the same scripts developers run locally, so CI and local runs stay identical.

    Shards (balanced to ~8-10 min each under Driver Verifier):
        shard1: real NTFS --strict gate, memfs x64 + x86, mirror x64 (drive, dirJunction, driveRemovable, netUnc)
        shard2: mirror x64 (driveMntMgr, driveRemovableMntMgr), mirror x86 (drive, netUnc)
        all:    everything above (same coverage as the former AppVeyor FsTest jobs)
#>
param(
    [ValidateSet('all', 'shard1', 'shard2')]
    [string]$Shard = 'all',
    # Crash-capture self-tests: crash or hang the guest after Dokan is loaded under Driver Verifier.
    [switch]$SimulateBugCheck,
    [switch]$SimulateHang
)

$ErrorActionPreference = 'Stop'

function Exec-External {
    param([Parameter(Position = 0, Mandatory = $true)][scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Command returned non-zero exit code ${LASTEXITCODE}: $Command"
    }
}

function Assert-NoBugCheck {
    $bugChecks = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting' } -ErrorAction SilentlyContinue
    if ($bugChecks) {
        $bugChecks | Format-List TimeCreated, Message | Out-String | Write-Host
        throw 'BugCheck event found in the System event log.'
    }
}

$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Host "=== $($os.ProductName), build $($os.CurrentBuildNumber).$($os.UBR), shard $Shard ===" -ForegroundColor Cyan

# The image clears the pagefile at shutdown only so the bake compacts well; skip that for test VMs.
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'ClearPageFileAtShutdown' -Type DWord -Value 0

if ((& bcdedit.exe /enum '{current}' | Out-String) -notmatch 'testsigning\s+Yes') {
    throw 'Test signing is not enabled in this image.'
}

Write-Host '=== Installing Dokan ===' -ForegroundColor Cyan
$install = Start-Process -PassThru -Wait -FilePath 'C:\ci\DokanSetup.exe' -ArgumentList @('/quiet', '/norestart', '/log', 'C:\ci\dokan_install.log')
if ($install.ExitCode -ne 0) {
    Get-Content 'C:\ci\dokan_install*.log' -ErrorAction SilentlyContinue | Select-Object -Last 80
    throw "DokanSetup.exe failed with exit code $($install.ExitCode)"
}

$verifierState = & verifier.exe /query | Out-String
Write-Host $verifierState
if ($verifierState -notmatch 'dokan3\.sys') {
    throw 'Driver Verifier is not monitoring dokan3.sys.'
}

if ($SimulateHang) {
    Write-Host '=== Self-test: blocking so the host detects a hang and injects an NMI ===' -ForegroundColor Yellow
    Start-Sleep -Seconds 3600
    throw 'The host did not interrupt the simulated hang.'
}
if ($SimulateBugCheck) {
    Write-Host '=== Self-test: raising BugCheck 0xDEADDEAD ===' -ForegroundColor Yellow
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CrashTrigger {
    [DllImport("ntdll.dll")]
    static extern uint RtlAdjustPrivilege(int privilege, bool enable, bool currentThread, out bool enabled);
    [DllImport("ntdll.dll")]
    static extern uint NtRaiseHardError(uint status, uint parameterCount, uint stringMask, IntPtr parameters, uint responseOption, out uint response);
    public static void BugCheck() {
        bool enabled;
        uint response;
        RtlAdjustPrivilege(19 /* SeShutdownPrivilege */, true, false, out enabled);
        NtRaiseHardError(0xDEADDEAD, 0, 0, IntPtr.Zero, 6 /* OptionShutdownSystem */, out response);
    }
}
'@
    [CrashTrigger]::BugCheck()
    throw 'NtRaiseHardError returned without crashing the system.'
}

# Win32-OpenSSH sessions start with every privilege of the account enabled (SeBackupPrivilege,
# SeRestorePrivilege, SeTakeOwnershipPrivilege, ...). Kernel32 opens files for delete/rename/attribute
# changes with FILE_OPEN_FOR_BACKUP_INTENT, so enabled backup/restore privileges silently bypass DACLs and
# break the security tests. Match an interactive (elevated) administrator instead, where only
# SeChangeNotify, SeImpersonate and SeCreateGlobal are enabled. Child processes (mirror.exe,
# dokan_fstest.exe, IFSTest) inherit this token state.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class TokenPrivileges {
    const uint SE_PRIVILEGE_ENABLED = 0x2;
    const uint TOKEN_ADJUST_PRIVILEGES = 0x20, TOKEN_QUERY = 0x8;
    const int TokenPrivilegesClass = 3;
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr info, int length, out int returnLength);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, IntPtr newState, int length, IntPtr previous, IntPtr returnLength);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LookupPrivilegeNameW(string system, ref long luid, StringBuilder name, ref int length);

    // Disables every enabled privilege whose name is not in 'keep'; returns the names it disabled.
    public static string[] DisableAllExcept(string[] keep) {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token)) throw new Win32Exception();
        var disabled = new List<string>();
        IntPtr info = IntPtr.Zero;
        try {
            int length;
            GetTokenInformation(token, TokenPrivilegesClass, IntPtr.Zero, 0, out length);
            info = Marshal.AllocHGlobal(length);
            if (!GetTokenInformation(token, TokenPrivilegesClass, info, length, out length)) throw new Win32Exception();
            int count = Marshal.ReadInt32(info);
            for (int i = 0; i < count; i++) {
                IntPtr entry = IntPtr.Add(info, 4 + i * 12);  // TOKEN_PRIVILEGES: count, then LUID_AND_ATTRIBUTES[]
                long luid = Marshal.ReadInt64(entry);
                uint attributes = (uint)Marshal.ReadInt32(IntPtr.Add(entry, 8));
                if ((attributes & SE_PRIVILEGE_ENABLED) == 0) continue;
                var name = new StringBuilder(64);
                int nameLength = name.Capacity;
                string privilege = LookupPrivilegeNameW(null, ref luid, name, ref nameLength) ? name.ToString() : luid.ToString();
                if (Array.IndexOf(keep, privilege) >= 0) continue;
                IntPtr state = Marshal.AllocHGlobal(16);
                try {
                    Marshal.WriteInt32(state, 1);
                    Marshal.WriteInt64(IntPtr.Add(state, 4), luid);
                    Marshal.WriteInt32(IntPtr.Add(state, 12), 0);
                    if (!AdjustTokenPrivileges(token, false, state, 16, IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception();
                } finally {
                    Marshal.FreeHGlobal(state);
                }
                disabled.Add(privilege);
            }
        } finally {
            if (info != IntPtr.Zero) Marshal.FreeHGlobal(info);
            CloseHandle(token);
        }
        return disabled.ToArray();
    }
}
'@
$disabledPrivileges = [TokenPrivileges]::DisableAllExcept(@('SeChangeNotifyPrivilege', 'SeImpersonatePrivilege', 'SeCreateGlobalPrivilege'))
Write-Host "Disabled privileges for the tests: $($disabledPrivileges -join ', ')"
& whoami.exe /user /priv

$env:DokanLibrary3 = [System.Environment]::GetEnvironmentVariable('DokanLibrary3', 'Machine')
$fsTestExe = 'C:\ci\fstest\dokan_fstest.exe'
$baselinesDir = 'C:\ci\fstest\baselines'
$resultsDir = 'C:\ci\fstest-results'
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
$fsTestArgs = @{ FsTestExe = $fsTestExe; BaselinesDir = $baselinesDir; ResultsDir = $resultsDir }

$memfs = @("$env:DokanLibrary3\sample\memfs\memfs.exe", "$env:DokanLibrary3\x86\sample\memfs\memfs.exe")
$mirrorX64 = "$env:DokanLibrary3\sample\mirror\mirror.exe"
$mirrorX86 = "$env:DokanLibrary3\x86\sample\mirror\mirror.exe"

if ($Shard -in @('all', 'shard1')) {
    Write-Host '=== Real NTFS --strict gate (C:\fstest_ntfs) ===' -ForegroundColor Cyan
    $ntfsRoot = 'C:\fstest_ntfs'
    New-Item -ItemType Directory -Force -Path $ntfsRoot | Out-Null
    try {
        Exec-External { & $fsTestExe "--root=$ntfsRoot" '--strict' "--json-out=$resultsDir\ntfs_strict.json" }
    } finally {
        & $fsTestExe "--cleanup-dir=$ntfsRoot"
        if ($LASTEXITCODE -ne 0) {
            & cmd.exe /d /c "rmdir /s /q \\?\$ntfsRoot"
        }
    }
}

Push-Location 'C:\ci\repo\samples'
try {
    switch ($Shard) {
        'shard1' {
            .\memfs_test.ps1 -Memfs $memfs @fsTestArgs
            .\mirror_test.ps1 -Mirrors @($mirrorX64) -ConfigNames @('drive', 'dirJunction', 'driveRemovable', 'netUnc') @fsTestArgs
        }
        'shard2' {
            .\mirror_test.ps1 -Mirrors @($mirrorX64) -ConfigNames @('driveMntMgr', 'driveRemovableMntMgr') @fsTestArgs
            .\mirror_test.ps1 -Mirrors @($mirrorX86) -ConfigNames @('drive', 'netUnc') @fsTestArgs
        }
        'all' {
            .\memfs_test.ps1 -Memfs $memfs @fsTestArgs
            .\mirror_test.ps1 -Mirrors @($mirrorX64) @fsTestArgs
            .\mirror_test.ps1 -Mirrors @($mirrorX86) -ConfigNames @('drive', 'netUnc') @fsTestArgs
        }
    }
} finally {
    Pop-Location
}

Write-Host '=== Driver Verifier statistics ===' -ForegroundColor Cyan
Exec-External { & verifier.exe /query }
Assert-NoBugCheck
Write-Host "=== Shard $Shard passed ===" -ForegroundColor Green
