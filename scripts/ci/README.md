# Continuous integration

Dokan's CI is the GitHub Actions workflow
[`.github/workflows/build-and-test.yml`](../../.github/workflows/build-and-test.yml) ("Build and Test").
It runs on every pull request, on pushes to `master`, and on demand (`workflow_dispatch`).

```
            ┌───────────────────────────────────┐
            │ Build, sign and package (Windows) │──► dokan-<version>         (release artifacts)
            │                                   │──► dokan-test-payload ─────────┐
 push / PR ─┼───────────────────────────────────┤                                │ downloaded as soon
            │ Build test tools (Windows)        │──► dokan-fstest-<version>      │ as they are uploaded
            │                                   │──► dokan-test-tools ───────────┤
            ├───────────────────────────────────┤                                ▼
            │ Prepare VM image (×4, cached)     │──► Test (<os>, shard1|shard2) (×8, Linux + QEMU/KVM)
            └───────────────────────────────────┘                                │ crash or hang
                                                                                 ▼
                                               Find crash dumps ──► Analyze crash dumps (kd.exe)
```

## Jobs

| Job | Runner | What it does |
| :--- | :--- | :--- |
| `Build, sign and package` | `windows-2025-vs2026` | [`build_and_package.ps1`](build_and_package.ps1): builds Win32/x64/ARM64 and Cygwin + MSYS2 `dokan_fuse`, test-signs with `cert/DokanSign.pfx`, builds the WiX bundle. Publishes `DokanSetup-<version>.exe` and `dokan-<version>.zip`. |
| `Build test tools` | `windows-2025-vs2026` | [`build_test_tools.ps1`](build_test_tools.ps1): builds `dokan_fstest.exe` (static CRT, self-tests) and `fsx.exe`. Publishes `dokan-fstest-<version>.zip`. Runs in parallel with the Dokan build. |
| `Prepare VM image (<os>)` | `ubuntu-latest` | Only on a cache miss: [`vm/bake_image.sh`](vm/bake_image.sh) installs Windows Server Core from Microsoft's evaluation ISO and provisions it (see below). The image is stored in the Actions cache. |
| `Test (<os>, <shard>)` | `ubuntu-latest` | [`vm/run_vm_tests.sh`](vm/run_vm_tests.sh) boots the cached image under QEMU/KVM, installs `DokanSetup.exe` and runs [`vm/run_guest_tests.ps1`](vm/run_guest_tests.ps1) inside the guest. |
| `Find crash dumps` / `Analyze crash dumps` | `ubuntu-latest` / `windows-2022` | When any `crash-dump-*` artifact exists, [`analyze_crash_dumps.ps1`](analyze_crash_dumps.ps1) runs `kd.exe` on it with `dokan3.sys`/`dokan3.pdb` and posts the result to the job summary. |
| `Crash-capture self-test` | `ubuntu-latest` | Manual only (`crash_selftest` input): crashes (`bugcheck`) or hangs (`hang`) a Server 2022 VM with Dokan loaded, to check the dump pipeline end to end. |

The test VMs boot while the builds are still running: `run_vm_tests.sh` polls the run's artifacts and
downloads `dokan-test-payload` and `dokan-test-tools` as soon as they are uploaded. It stops waiting if a
job whose name starts with `Build` fails. Installer versions are `<BaseVersion>.<2000 + run number>`
([`get_version.ps1`](get_version.ps1)), continuing after the last AppVeyor build.

## Test coverage

Windows Server Core **2016 (14393)**, **2019 (17763)**, **2022 (20348)** and **2025 (26100)**, x64, with
Driver Verifier (`verifier /standard /driver dokan3.sys`) active from the first load of the driver.
Each OS runs two shards in parallel; together they are exactly the former AppVeyor FsTest coverage:

| Shard | Tests |
| :--- | :--- |
| `shard1` | Real NTFS `dokan_fstest --strict` gate; `samples/memfs_test.ps1` (x64, x86); `samples/mirror_test.ps1` x64 (`drive`, `dirJunction`, `driveRemovable`, `netUnc`) |
| `shard2` | `samples/mirror_test.ps1` x64 (`driveMntMgr`, `driveRemovableMntMgr`), x86 (`drive`, `netUnc`) |

Each mount runs `fsx`, `dokan_fstest` against the `tests/fstest/baselines` manifests and HLK IFSTest,
using the same `samples/*.ps1` harnesses as local runs. Scorecards (`fstest-results/*.json`), install
logs and the serial console log are uploaded as `vm-logs-<os>-<shard>`.

## Crashes and hangs

- **BugCheck:** the guest writes a kernel memory dump and reboots; the host copies `C:\Windows\MEMORY.DMP`.
- **Hang:** if a shard exceeds its timeout, or SSH stops answering while the VM still runs, the host
  injects an NMI through the QEMU monitor. The image sets `CrashControl\NMICrashDump=1`, so Windows
  bugchecks with `0x80` and the hang becomes a regular dump.

Dumps are uploaded as `crash-dump-<os>-<shard>` and analyzed with `!analyze -v`, `kP`, `dv /t /i /V`,
`!running -it`, `!locks`, `!stacks 2 dokan` and `!verifier`. The full report is in the `crash-analysis`
artifact and a summary in the job summary.

**Known intermittent:** on Server 2025, `shard1` has occasionally hung with PatchGuard
(`CRITICAL_STRUCTURE_CORRUPTION`, `0x109`, type `0x115`) during IFSTest. The dumps show all Dokan threads
idle and no lock contention, and it has not been reproduced outside nested KVM, so this leg is marked
`continue-on-error`: it still shows red and its dump is still analyzed, but it does not fail the run.

## VM images

`bake_image.sh` runs an unattended install ([`vm/provisioning/autounattend.xml`](vm/provisioning/autounattend.xml)),
then [`vm/provisioning/provision_guest.ps1`](vm/provisioning/provision_guest.ps1) inside the guest:
test signing on, `cert/DokanCA.cer` trusted, Driver Verifier armed for `dokan3.sys`, kernel memory dumps
and NMI dumps enabled, Windows Update and Defender real-time scanning off, Win32-OpenSSH with a per-image
key, the `dokan_ifstest` user and HLK IFSTest (`scripts/install_wlk_ifstest.ps1`). Free space is zeroed
and the image compacted; `actions/cache` compresses it (2.6-3.9 GiB per OS).

The cache key hashes `vm/bake_image.sh`, `vm/provisioning/**`, `scripts/install_wlk_ifstest.ps1` and
`cert/DokanCA.cer`, so changing any of them rebakes all images (about 10-20 minutes, in parallel).

To add a Windows version, add its evaluation ISO URL to the `case` in `bake_image.sh` and the OS to the
`vm-image` and `vm-test` matrices.

## Security model for pull requests

- The workflow token is read-only (`contents: read`, `actions: read`); no secrets are used. Test signing
  uses the public test certificate already in the repository.
- Pull request code only runs inside throw-away VMs: each test boots a copy-on-write overlay of the
  cached image that is discarded afterwards. The guest network uses QEMU `restrict=on` (no outbound
  access); only SSH is forwarded to the runner's loopback interface.
- Images are built from Microsoft's evaluation ISOs and a SHA-256-pinned OpenSSH release. Caches written
  by pull requests are scoped to that pull request, so they cannot replace the images used by `master`.

## Running locally

Any x86-64 Linux machine with `/dev/kvm` works (install the packages listed in
[`.github/actions/setup-qemu-kvm/action.yml`](../../.github/actions/setup-qemu-kvm/action.yml)):

```sh
scripts/ci/vm/bake_image.sh server2022 ~/dokan-vm/server2022
# Payload: the dokan-test-payload and dokan-test-tools artifacts of a CI run, unzipped into one folder.
scripts/ci/vm/run_vm_tests.sh ~/dokan-vm/server2022 ~/dokan-payload ~/dokan-results shard1
```
