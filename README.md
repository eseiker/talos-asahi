# Talos Linux on Apple Silicon through Asahi

This repository builds an experimental, reproducible Talos Linux installer for
Apple Silicon Macs that already boot through Asahi's m1n1 and U-Boot chain. It
publishes an ARM64 installer to GHCR and produces an ESP boot bundle containing
systemd-boot, a generic Talos UKI, and `loader.conf`.

The first hardware-tested pin is Talos v1.13.9 with the Asahi 7.1.9 downstream
kernel. It booted a Mac14,13 and joined an existing Kubernetes cluster as a
worker. This is not an upstream-supported Talos platform.

## What the custom build changes

- Builds the Asahi kernel with Apple AIC, DART, PCIe, NVMe, SMC, and related
  platform drivers.
- Uses 16 KiB pages because this Asahi kernel still requires them for Apple
  PCIe. That is a known container-compatibility tradeoff.
- Reuses the already installed m1n1, U-Boot, Apple firmware, and Asahi ESP;
  there is no board overlay or platform installer in the update path.
- Makes sd-boot updates use `loader/loader.conf` as the authoritative default.
  EFI variable reads, writes, and boot-entry creation become best effort, which
  is necessary for the Asahi U-Boot environment used in testing.
- Allows Omni's `os:operator` role to call the streaming upgrade API. Upstream
  Talos normally requires `os:admin`, while Omni deliberately exposes only
  `os:operator` for ordinary managed-node access.

The generated installer does not contain an Omni join token, a machine config,
or a static `ip=` argument. Existing Talos machine configuration remains in the
STATE partition during a normal upgrade.

## Published image

For a repository named `OWNER/talos-asahi`, the immutable release tag is:

```text
ghcr.io/OWNER/talos-asahi/installer:v1.13.9-asahi.3
```

After the first ESP-based installation is working, upgrade a node with:

```sh
NODE_IP=192.0.2.10
talosctl upgrade \
  --nodes "${NODE_IP}" \
  --image ghcr.io/OWNER/talos-asahi/installer:v1.13.9-asahi.3 \
  --reboot-mode=powercycle
```

`powercycle` avoids relying on kexec while the boot path is still experimental.
For unattended use, replace the mutable tag with the published
`@sha256:<digest>` reference. This build deliberately grants `os:operator` an
unrestricted upgrade API, so that role can install any installer image. It is
intended for a single-administrator cluster; do not use this authorization
change where untrusted users or service accounts have Omni Operator access.

An existing node without this authorization patch cannot install the first
patched release through the Omni tunnel. Install the release UKI and
`loader.conf` on the ESP once; subsequent releases can use the command above.

## ESP contract

The existing Asahi ESP must have GPT partition label `EFI`, because Talos finds
the partition by that label. Keep the Apple GPT, iBootSystemContainer, macOS,
RecoveryOS, and the existing Asahi boot chain intact.

A completed installation also needs a separate Talos `META` partition on the
same internal disk. Copying the boot bundle to the ESP does not create it. If
the normal installer is not allowed to repartition the shared Apple disk,
create it in free space before the first install with this exact contract:

- GPT partition name/PARTLABEL: `META` (uppercase)
- GPT partition type: Linux filesystem data
  (`0FC63DAF-8483-4772-8E79-3D69D8477DE4`)
- Size: exactly 1 MiB
- Contents: raw and initially zero-filled; do not create a filesystem

Talos locates this partition by the GPT PARTLABEL, not by a filesystem label or
a directory named `META` on the ESP. It stores raw metadata and upgrade state
there. `STATE` and `EPHEMERAL` remain separate Talos partitions. A conceptual
shared-disk layout is:

```text
[Apple/macOS partitions] [Asahi ESP: EFI] [META: 1 MiB] [Talos data/free space] [RecoveryOS]
```

Do not copy LBAs from another Mac. Choose an actually free, 1 MiB-aligned
extent on the target disk, and verify the resulting GPT names before booting:

```sh
sudo gpt -r show -l /dev/disk0
```

The output must show separate GPT entries named `EFI` and `META`. macOS may
display the latter generically as `Linux Filesystem`; the GPT name is the field
that matters. Some macOS Recovery configurations reject GPT label changes, so
perform the operation from an environment that has exclusive write access to
the disk rather than weakening macOS security protections.

### Machine UUID override for Omni

The tested Asahi U-Boot environment exposes the SMBIOS machine UUID as
`00000000-0000-0000-0000-000000000000`. Talos and Omni require a stable,
non-zero machine identity. After Talos discovers the META partition and before
enrolling the machine in Omni, generate a UUID once and store it in the Talos
META `UUIDOverride` key (`0x0f`):

```sh
NODE=192.0.2.10
MACHINE_UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"

talosctl \
  --nodes "${NODE}" \
  --endpoints "${NODE}" \
  --insecure \
  meta write 0x0f "${MACHINE_UUID}"
```

`--insecure` is for maintenance mode over the local network. On an already
authenticated node, omit `--endpoints` and `--insecure`. Reboot after writing
the key, then verify that both the META key and reported system UUID contain
the generated value:

```sh
talosctl --nodes "${NODE}" get metakeys 0x0f -o yaml
talosctl --nodes "${NODE}" get systeminformation -o yaml
```

Do not generate a new value on every boot or upgrade. META preserves this value
across normal upgrades. If META must be recreated and the existing Omni machine
identity should be retained, restore the same UUID; a new UUID represents a new
machine to Omni. This machine UUID is unrelated to the GPT disk GUID, the META
partition PARTUUID, or a filesystem UUID. META remains an unformatted raw
partition.

Download and extract the release boot bundle, then install its files into the
existing Asahi ESP as follows:

```text
EFI/BOOT/BOOTAA64.efi         <- BOOTAA64.efi
EFI/Linux/Talos-v1.13.9~3.efi <- Talos-v1.13.9~3.efi
loader/loader.conf            <- loader.conf
```

The `~BUILD_REVISION` suffix keeps an existing UKI with the same upstream
Talos version intact during a manual ESP transition. Use the `loader.conf`
shipped in the same release; its exact default pattern selects the new file
without accidentally matching the older UKI.

On upgrade, Talos keeps the currently booted UKI as fallback, writes the next
UKI, and changes `loader.conf` to select it. The patch also teaches Talos probe
and revert paths to read and update that file without requiring persistent UEFI
variables.

Automatic systemd-boot boot counting is not implemented yet, so a completely
unbootable new kernel may still require choosing or restoring the prior UKI
from the ESP manually. “Upgradeable” here means the Talos installer can perform
the normal UKI replacement and reboot flow; it does not promise unattended
rollback from every early-boot failure.

## CI operation

`Validate patches` runs for pull requests and pushes to `main`. It verifies all
three source pins, applies every patch with `git apply --check`, compile-checks
the lifecycle package, and runs the focused sd-boot unit tests.

`Build and publish Asahi Talos` runs manually or when a matching release tag is
pushed. It uses GitHub's native ARM64 runner, builds the kernel and Talos
imager, verifies the final artifacts, and optionally publishes:

```text
ghcr.io/OWNER/talos-asahi/installer:<release>
ghcr.io/OWNER/talos-asahi/kernel:<kernel-release>
```

CI imports and exports the kernel's full BuildKit layer cache through
`ghcr.io/OWNER/talos-asahi/build-cache:kernel-arm64-asahi`. The cache is
separate from release images and is reused across Talos-only patch revisions.
Local builds do not use a remote cache unless `KERNEL_CACHE_IMAGE` is set
explicitly.

Manual workflow runs can instead select the experimental `mainline` kernel
flavor. It keeps the Talos pkgs pin on upstream Linux 6.18.44, enables the
Apple SoC drivers available there, and builds a separate 16 KiB-page UKI and
installer. Mainline release output is artifact-only: the workflow will not
publish installer or kernel release images or create a release, even if
`publish` is selected. Its names carry a `-mainline` suffix, and its build
cache is isolated in GHCR at
`build-cache:kernel-arm64-mainline`.

The initial mainline test target is boot, internal NVMe, and the Mac Studio's
wired 10 GbE interface. Wi-Fi, Bluetooth, GPU acceleration, USB-C data ports,
RTC, CPU idle, and suspend are not expected to work with Linux 6.18 on this
machine. Keep the known-good downstream Asahi UKI on the ESP while testing.

A matching Git tag also creates a GitHub Release containing only the ESP boot
bundle and its checksum. The bundle contains systemd-boot, the UKI, and the
matching `loader.conf`; individual files are not published because GitHub
normalizes the `~N` suffix used by Talos for same-version UKI slots. The
installer OCI archive and `build.env` metadata remain available only in the
short-lived Actions artifact. The repository itself does not track a binary
output directory.

For a release, update `versions.env`, make sure the patches still apply, bump
`BUILD_REVISION` when appropriate, and push the exact computed tag. For the
current pins that tag is `v1.13.9-asahi.3`.

## Local validation and build

Patch validation only needs Git and Docker:

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

- Talos `3ebd10a7c1bd0f81742bdcd0c3fe56d727db7401`
- Talos pkgs `f541ca434ee63964319bb912e370f0ed407f8a18`
- AsahiLinux/linux `77cb8f24c2381a8abb7272d7bbdec548d6426a8a`
- Mainline Linux `6.18.44` (the kernel source pinned by Talos pkgs)

Do not write a generated raw disk image over the whole internal Apple NVMe.
That would replace the partition table instead of preserving the Asahi/macOS
layout this project is designed around.
