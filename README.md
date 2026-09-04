# Talos Linux on Apple Silicon through Asahi

This repository builds an experimental, reproducible Talos Linux installer for
Apple Silicon Macs that already boot through Asahi's m1n1 and U-Boot chain. It
publishes an ARM64 installer to GHCR and produces an ESP boot bundle containing
systemd-boot, a one-time preparation UKI, a generic Talos UKI, and
`loader.conf`.

The first hardware-tested pin is Talos v1.13.9 with the Asahi 7.1.9 downstream
kernel. It booted a Mac14,13 and joined an existing Kubernetes cluster as a
worker. This is not an upstream-supported Talos platform.

## What the custom build changes

- Builds the Asahi kernel with Apple AIC, DART, PCIe, NVMe, SMC, and related
  platform drivers.
- Uses 16 KiB pages for the Asahi and default mainline flavors. The additional
  `mainline-4k` flavor retains Talos' standard 4 KiB page size and relies on
  Apple DART's forced identity-domain fallback where the hardware IOMMU
  granule is 16 KiB. That improves container compatibility at the cost of DMA
  isolation and remains experimental.
- Reuses the already installed m1n1, U-Boot, Apple firmware, and Asahi ESP;
  there is no board overlay or platform installer in the update path.
- Makes sd-boot updates use `loader/loader.conf` as the authoritative default.
  EFI variable reads, writes, and boot-entry creation become best effort, which
  is necessary for the Asahi U-Boot environment used in testing.
- Builds `installer-base` from the same patched Talos source and uses it as the
  published installer's base. CI inspects `/bin/installer` in the final OCI
  archive and rejects an artifact without the sd-boot `loader.conf` fallback.
- Allows Omni's `os:operator` role to call the streaming upgrade API. Upstream
  Talos normally requires `os:admin`, while Omni deliberately exposes only
  `os:operator` for ordinary managed-node access.

The generated installer does not contain an Omni join token, a machine config,
or a static `ip=` argument. Existing Talos machine configuration remains in the
STATE partition during a normal upgrade.

## How to install

This procedure preserves the existing Apple GPT, macOS, Asahi stub, and
RecoveryOS partitions. It is nevertheless an experimental installer which
writes the internal disk's GPT. Make a current backup before starting.

### 1. Download the ESP bundle

Download the ZIP for the desired kernel flavor from the matching GitHub
Release:

```text
talos-asahi-v1.13.9-asahi.9-esp.zip
talos-asahi-v1.13.9-asahi.9-mainline-esp.zip
talos-asahi-v1.13.9-asahi.9-mainline-4k-esp.zip
talos-asahi-v1.13.9-asahi.9-longhorn-esp.zip
talos-asahi-v1.13.9-asahi.9-mainline-longhorn-esp.zip
talos-asahi-v1.13.9-asahi.9-mainline-4k-longhorn-esp.zip
```

The Asahi flavor is the default. Both mainline flavors are experimental and
have a smaller set of working Apple drivers. `mainline` uses 16 KiB pages;
`mainline-4k` uses 4 KiB pages with DART bypass where required. Verify the ZIP
against the release's `SHA256SUMS` before copying it to the internal disk.

The archive has no enclosing top-level directory. Extracting it at the root of
an ESP produces exactly this overlay:

```text
EFI/BOOT/BOOTAA64.efi
EFI/Linux/Talos-prepare.efi
EFI/Linux/Talos-v1.13.9.efi
loader/loader.conf
```

The mainline bundle names its final UKI
`EFI/Linux/Talos-v1.13.9-mainline.efi`; the 4 KiB bundle uses
`EFI/Linux/Talos-v1.13.9-mainline-4k.efi`. The three Longhorn bundles append
`-longhorn` to those UKI names and include `iscsi-tools` and
`util-linux-tools` in the UKI initramfs. None of the bundles contains or
replaces Asahi's `m1n1/boot.bin`.

### 2. Install the official Asahi UEFI environment

Run the [official Asahi installer](https://github.com/AsahiLinux/asahi-installer)
from macOS and choose `UEFI environment only (m1n1 + U-Boot + ESP)`. Allocate
the space intended for Talos. The Asahi UEFI profile creates its 500 MB ESP and
leaves the remaining selected space unallocated.

At the final `Press enter to shut down the system` prompt, do **not** press
Enter yet. Keep that terminal open and use a second macOS terminal to copy the
release overlay. The installer prints the new EFI PARTUUID; use that value
below:

```sh
BUNDLE="$HOME/Downloads/talos-asahi-v1.13.9-asahi.10-esp.zip"
ESP_PARTUUID="replace-with-the-EFI-PARTUUID-shown-by-the-installer"

diskutil mount "${ESP_PARTUUID}"
ESP_MOUNT="$(diskutil info "${ESP_PARTUUID}" | sed -n 's/^ *Mount Point: *//p')"
test -n "${ESP_MOUNT}"

sudo ditto -x -k "${BUNDLE}" "${ESP_MOUNT}"

test -s "${ESP_MOUNT}/m1n1/boot.bin"
test -s "${ESP_MOUNT}/EFI/BOOT/BOOTAA64.efi"
test -s "${ESP_MOUNT}/EFI/Linux/Talos-prepare.efi"
test -s "${ESP_MOUNT}/loader/loader.conf"

sync
diskutil unmount "${ESP_PARTUUID}"
```

Return to the Asahi installer terminal, press Enter, and follow its power-off
and One True RecoveryOS (1TR) stage 2 instructions exactly. In particular,
start the fully powered-off Mac by holding the power button until startup
options appear.

### 3. Let the preparation UKI create META and STATE

The first UEFI boot selects `Talos-prepare.efi`. It identifies the correct ESP
from Asahi's device-tree PARTUUID, verifies that it is on NVMe, and performs the
following one-time transaction:

This must be a complete firmware boot. A normal `talosctl reboot` may use
kexec and therefore skip U-Boot and systemd-boot entirely; use a cold boot or
`talosctl reboot --mode powercycle` when retrying preparation from a running
configured node.

1. Reject a GPT with inconsistent headers, overlapping partitions, or other
   verification failures.
2. Create an aligned, exactly 1 MiB Linux GPT partition in the free extent
   immediately after the ESP, initially named `TALOS_META_PENDING`.
3. Zero-fill and verify the whole new partition.
4. Rename the ESP to `EFI` and the new partition to `META`.
5. Sort GPT entries into physical LBA order, then create an aligned, exactly
   100 MiB partition immediately after META as `TALOS_STATE_PENDING`.
6. Zero-fill and verify the new STATE extent, rename it to `STATE`, sort the
   GPT again, and reject any remaining overlap or out-of-order entry.
7. Generate a random UUID and store it as Talos META key `UUIDOverride`
   (`0x0f`), then read it back from both redundant ADV copies.
8. Change `loader.conf` to select the final Talos UKI.
9. Delete `EFI/Linux/Talos-prepare.efi`, flush the ESP, and reboot.

An interrupted run resumes from `TALOS_META_PENDING` or
`TALOS_STATE_PENDING`. Existing valid `META` and `STATE` partitions are never
zero-filled again, and an existing valid `UUIDOverride` is preserved. The
preparation UKI intentionally leaves `EPHEMERAL` unallocated so Talos can
apply its configured size and growth policy. Malformed metadata or any
unexpected partition, size, type, placement, overlap, or GPT ordering failure
stops preparation without deleting the prepare UKI or switching the boot
target. Do not proceed to `apply-config` after such an error.

### 4. Verify the machine UUID before applying configuration

The tested Asahi U-Boot environment exposes an all-zero SMBIOS machine UUID.
The preparation UKI therefore generates one stable random UUID and stores it in
META key `UUIDOverride` (`0x0f`) before booting Talos. After the automatic
reboot reaches Talos maintenance mode, verify both the stored key and the live
system UUID:

```sh
NODE=192.0.2.10

talosctl get metakeys 0x0f -o yaml \
  --nodes "${NODE}" \
  --endpoints "${NODE}" \
  --insecure
talosctl get systeminformation -o yaml \
  --nodes "${NODE}" --endpoints "${NODE}" --insecure
```

The two values must match and must not be all zeroes. Direct maintenance-mode
connections intentionally receive only the Talos `Reader` role, so
`talosctl meta write ... --insecure` is not a valid fallback and returns
`PermissionDenied`. Do not apply a machine configuration if the key is absent
or the values differ.

The generated UUID survives retries, reinstalls, and normal upgrades because
the existing META contents are preserved. Back it up before manually
recovering META; changing it creates a different machine identity in Omni.

### 5. Apply a non-wiping Talos configuration

Keep the generated machine configuration's install section pointed at the
internal NVMe and matching downstream image, with whole-disk wiping disabled:

```yaml
machine:
  install:
    disk: /dev/nvme0n1
    image: ghcr.io/OWNER/talos-asahi/installer:v1.13.9-asahi.9
    wipe: false
```

Because the preparation UKI has already created META, Talos considers the
machine installed and the first `apply-config` runs no installer phases. The
section above is therefore a safety contract for any later explicitly staged
installation; it does not create STATE on the first configured boot.

Keep the installer image flavor matched to the ESP bundle. Use
`:v1.13.9-asahi.9-mainline` with the mainline 16K ZIP and
`:v1.13.9-asahi.9-mainline-4k` with the mainline 4K ZIP. Mixing them causes
the installer to replace the selected test UKI with a different kernel flavor.
Likewise, use a `*-longhorn-esp.zip` only with the matching installer tag that
ends in `-longhorn`.

Confirm the actual NVMe device name on the target rather than copying the
example blindly, then apply the complete generated machine configuration in
maintenance mode:

```sh
talosctl apply-config \
  --nodes "${NODE}" \
  --endpoints "${NODE}" \
  --insecure \
  --file worker.yaml
```

Talos reuses the prepared `EFI`, `META`, and raw `STATE` partitions. It formats
and mounts STATE, then creates `EPHEMERAL` from the remaining free space using
the machine configuration's volume policy. GPT entries are already in physical
LBA order, so this online allocation keeps the in-use META and STATE entry
numbers stable and only moves the unmounted RecoveryOS entry if necessary.
Never write a generic Talos raw disk image to the whole internal NVMe.

## Published image

For a repository named `OWNER/talos-asahi`, the immutable release tag is:

```text
ghcr.io/OWNER/talos-asahi/installer:v1.13.9-asahi.9
```

Every kernel flavor also has a `-longhorn` installer variant. It contains the
same patched kernel and installer, plus the Talos `iscsi-tools` and
`util-linux-tools` system extensions required by Longhorn:

```text
ghcr.io/OWNER/talos-asahi/installer:v1.13.9-asahi.9-longhorn
ghcr.io/OWNER/talos-asahi/installer:v1.13.9-asahi.9-mainline-longhorn
ghcr.io/OWNER/talos-asahi/installer:v1.13.9-asahi.9-mainline-4k-longhorn
```

Choose the Longhorn variant only when those extensions are required. Its ESP
bundle has the same Apple boot chain and prepare flow, but its final Talos UKI
is different because the extensions are embedded in the initramfs.
GitHub Releases contain only the six ESP ZIPs and their `SHA256SUMS`; installer
OCI images are distributed through GHCR instead of duplicated as tar archives.

After the first ESP-based installation is working, upgrade a node with:

```sh
NODE_IP=192.0.2.10
talosctl upgrade \
  --nodes "${NODE_IP}" \
  --image ghcr.io/OWNER/talos-asahi/installer:v1.13.9-asahi.9 \
  --reboot-mode=powercycle
```

`powercycle` avoids relying on kexec while the boot path is still experimental.
For unattended use, replace the mutable tag with the published
`@sha256:<digest>` reference. This build deliberately grants `os:operator` an
unrestricted upgrade API, so that role can install any installer image. It is
intended for a single-administrator cluster; do not use this authorization
change where untrusted users or service accounts have Omni Operator access.

An existing node without this authorization patch cannot install the first
patched release through the Omni tunnel. Install the release ESP ZIP once;
subsequent releases can use the command above.

## ESP contract

The existing Asahi ESP must have GPT partition label `EFI`, because Talos finds
the partition by that label. Keep the Apple GPT, iBootSystemContainer, macOS,
RecoveryOS, and the existing Asahi boot chain intact.

A completed installation also needs separate Talos `META` and `STATE`
partitions on the same internal disk. The release's one-time preparation UKI
creates them with these exact contracts:

- GPT partition name/PARTLABEL: `META` (uppercase)
- GPT partition type: Linux filesystem data
  (`0FC63DAF-8483-4772-8E79-3D69D8477DE4`)
- Size: exactly 1 MiB
- Contents: raw Talos META/ADV data containing the generated `UUIDOverride`;
  do not create a filesystem

STATE:

- GPT partition name/PARTLABEL: `STATE` (uppercase)
- GPT partition type: Linux filesystem data
  (`0FC63DAF-8483-4772-8E79-3D69D8477DE4`)
- Size: exactly 100 MiB
- Initial contents: zero-filled and unformatted; Talos formats it after the
  machine configuration is applied

Talos locates this partition by the GPT PARTLABEL, not by a filesystem label or
a directory named `META` on the ESP. It stores raw metadata and upgrade state
there. STATE stores the machine configuration and persistent system state.
`EPHEMERAL` remains a separate Talos partition created from the configured
volume policy. GPT entry numbers are sorted by physical start LBA before the
preparation UKI exits. A conceptual shared-disk layout before `apply-config`
is:

```text
[Apple/macOS partitions] [Asahi ESP: EFI] [META: 1 MiB] [STATE: 100 MiB] [free space] [RecoveryOS]
```

Do not copy LBAs from another Mac or create META or STATE manually for a new
installation. The preparation UKI derives the correct disk from the Asahi ESP
PARTUUID and refuses occupied or ambiguous post-ESP extents. After it finishes,
the resulting GPT names can be inspected from macOS with:

```sh
sudo gpt -r show -l /dev/disk0
```

The output must show separate GPT entries named `EFI`, `META`, and `STATE`, in
that physical order before RecoveryOS. macOS may display META and STATE
generically as `Linux Filesystem`; the GPT names are the fields that matter.
META remains an unformatted raw partition, and STATE remains unformatted until
Talos applies the machine configuration. The machine UUID override is
unrelated to the GPT disk GUID, META PARTUUID, or a filesystem UUID.

The ZIP uses a stable final UKI name rather than encoding the downstream build
revision in the ESP filename. Its initial `loader.conf` selects
`Talos-prepare.efi`; preparation rewrites it to the exact final filename. The
mainline bundles use `Talos-v1.13.9-mainline.efi` and
`Talos-v1.13.9-mainline-4k.efi` so all kernel flavors remain distinguishable.

On upgrade, Talos keeps the currently booted UKI as fallback, writes the next
same-version UKI as `Talos-v1.13.9~N.efi`, and changes `loader.conf` to select
it. The `~N` suffix is owned by the installer and is independent of the
downstream release revision. The patch also teaches Talos probe and revert
paths to read and update that file without requiring persistent UEFI variables.

Copying a newer same-version boot bundle manually replaces the stable bootstrap
UKI instead of creating a rollback slot. Once the first patched release is
installed, use the installer image for normal updates. If a manual ESP recovery
is necessary, preserve a known-good UKI under a different filename before
replacing the bootstrap file.

Automatic systemd-boot boot counting is not implemented yet, so a completely
unbootable new kernel may still require choosing or restoring the prior UKI
from the ESP manually. “Upgradeable” here means the Talos installer can perform
the normal UKI replacement and reboot flow; it does not promise unattended
rollback from every early-boot failure.

## CI operation

`Validate patches` runs for pull requests and pushes to `main`. It verifies the
source pins and the Asahi, mainline 16K, and mainline 4K patch stacks, applies
every patch with `git apply --check`, compile-checks the lifecycle package,
runs the focused sd-boot unit tests, and exercises META/STATE creation,
pending recovery, physical GPT sorting, idempotency, and invalid-geometry
rejection against disposable disk images.

`Build and publish Asahi Talos` runs manually or when a matching release tag is
pushed. Manual runs build the selected kernel flavor; `both` retains the older
Asahi-plus-mainline selection and `all` selects all three. A matching release
tag builds the Asahi, mainline 16K, and mainline 4K flavors in parallel on
separate native ARM64 runners. Each job builds the kernel, patched Talos
installer base, and Talos imager, then verifies the final artifacts and
installer binary. On tag builds, all jobs publish flavor-specific immutable
images:

```text
ghcr.io/OWNER/talos-asahi/installer:<release>
ghcr.io/OWNER/talos-asahi/installer:<release>-longhorn
ghcr.io/OWNER/talos-asahi/installer:<release>-mainline
ghcr.io/OWNER/talos-asahi/installer:<release>-mainline-longhorn
ghcr.io/OWNER/talos-asahi/installer:<release>-mainline-4k
ghcr.io/OWNER/talos-asahi/installer:<release>-mainline-4k-longhorn
ghcr.io/OWNER/talos-asahi/kernel:<asahi-kernel-release>
ghcr.io/OWNER/talos-asahi/kernel:<mainline-kernel-release>
ghcr.io/OWNER/talos-asahi/kernel:<mainline-4k-kernel-release>
```

Only the regular Asahi installer moves `installer:latest`; Longhorn and
mainline variants cannot replace that tag.

Each flavor job reuses its already-built custom kernel and imager to generate
both installer archives. CI inspects the Longhorn initramfs for both extension
metadata records before publishing. The extension image references are pinned
in `versions.env`, and the upstream update automation refreshes them from the
matching Talos Image Factory catalog.

CI imports and exports the kernel's full BuildKit layer cache through
`ghcr.io/OWNER/talos-asahi/build-cache:kernel-arm64-asahi`. The cache is
separate from release images and is reused across Talos-only patch revisions.
Local builds do not use a remote cache unless `KERNEL_CACHE_IMAGE` is set
explicitly.

The experimental `mainline` and `mainline-4k` flavors can be selected directly
in a manual run and are also built alongside Asahi for every matching release
tag. Both keep the Talos pkgs pin on upstream Linux 6.18.48 and enable the
Apple SoC drivers available there. `mainline` builds a 16 KiB-page UKI and
installer; `mainline-4k` retains the upstream Talos 4 KiB page size. Their
outputs carry `-mainline` and `-mainline-4k` suffixes respectively. A tag build
publishes both installer and kernel images and adds both ESP ZIPs to the GitHub
Release; a manual build publishes only when `publish` is selected. Their build
caches are isolated in GHCR at:

```text
build-cache:kernel-arm64-mainline
build-cache:kernel-arm64-mainline-4k
```

On Apple DART instances whose hardware page size is 16 KiB, the 4 KiB kernel
cannot construct translated DART page tables. Mainline Linux therefore selects
an identity domain when the DART advertises bypass support. The resulting
kernel has the usual 4 KiB userspace and container ABI, but devices behind
those DARTs are not isolated from host memory. Do not treat `mainline-4k` as a
safe VFIO or untrusted-device-passthrough host.

The initial mainline test target is boot, internal NVMe, and the Mac Studio's
wired 10 GbE interface. Wi-Fi, Bluetooth, GPU acceleration, USB-C data ports,
RTC, CPU idle, and suspend are not expected to work with Linux 6.18 on this
machine. Keep the known-good downstream Asahi UKI on the ESP while testing.

A matching Git tag also creates one GitHub Release after all three builds
succeed. It contains separate Asahi, mainline 16K, and mainline 4K ESP ZIPs
plus one combined checksum file. Each ZIP contains systemd-boot, a matching
one-time prepare UKI, the final Talos UKI, and `loader.conf` in their
ESP-relative paths. Individual files are not published because the ZIP is the
atomic installation overlay. The regular and Longhorn installer OCI archives
and `build.env` metadata remain available only in the short-lived Actions
artifacts. The repository itself does not track a binary output directory.

`Track upstream releases` runs daily and can also be dispatched manually.
It resolves the latest stable Talos release and downstream AsahiLinux
`asahi-X.Y.Z-N` kernel tag. The tag's commit and archive checksums are pinned
for reproducibility.
Either upstream changing triggers an update. For Talos updates, the workflow
also extracts the matching pkgs commit, mainline kernel version, and Longhorn
extension references. It resets `BUILD_REVISION=1` for a new Talos release and
increments it for Asahi-only rebuilds, then pushes a unique
`automation/talos-vX.Y.Z-asahi-X.Y.Z-SHA` branch and
dispatches artifact-only Asahi, mainline 16K, and mainline 4K builds. The
workflow also tries to open a draft pull request; repositories which keep
GitHub Actions pull request creation disabled still get the update branch and
test builds, and can open the pull request manually. It never publishes
images, moves `latest`, or creates a release tag automatically.

For a release, update `versions.env`, make sure the patches still apply, bump
`BUILD_REVISION` when appropriate, and push the exact computed tag. For the
current pins that tag is `v1.14.0-asahi.1`.

## Local validation and build

Validation builds the small prepare rootfs, tests its GPT transaction against
disposable disk images, and runs `olddefconfig` for the Asahi, mainline 16K, and
mainline 4K kernels. It prints each kernel config diff and rejects changes to
the requested Apple platform or page-size settings:

```sh
./scripts/validate.sh
```

A full local build also needs GNU Make, Buildx, and an insecure local registry
reachable by the active BuildKit builder. On Linux with a host-network BuildKit
builder:

```sh
docker run --detach --rm --name talos-asahi-registry \
  --publish 127.0.0.1:5000:5000 registry:2
LOCAL_REGISTRY=localhost:5000 ./scripts/build.sh
```

Docker Desktop commonly needs a registry address such as
`host.docker.internal:5050` plus matching insecure-registry BuildKit settings.
The CI workflow contains the known-good Linux builder configuration.

## Source pins

All refs are recorded in `versions.env`. The current build uses:

- Talos `9abd05af449ebf9cb1827648298291afce18d714`
- Talos pkgs `2f03590c50e45a9439a4b3abcdbe247693c179e0`
- AsahiLinux/linux `asahi-7.1.12-1`
  (`ca9a850f237f98949996eefb8980371a5d58c886`)
- Mainline Linux `6.18.48` (the kernel source pinned by Talos pkgs)

Do not write a generated raw disk image over the whole internal Apple NVMe.
That would replace the partition table instead of preserving the Asahi/macOS
layout this project is designed around.
