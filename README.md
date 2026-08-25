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
- Adds an `sbc-asahi` overlay whose installer deliberately leaves m1n1, U-Boot,
  Apple firmware, and the paired Asahi recovery layout untouched.
- Makes Talos propagate `--insecure` when a local overlay registry is used.
- Makes sd-boot updates use `loader/loader.conf` as the authoritative default.
  EFI variable reads, writes, and boot-entry creation become best effort, which
  is necessary for the Asahi U-Boot environment used in testing.

The generated installer does not contain an Omni join token, a machine config,
or a static `ip=` argument. Existing Talos machine configuration remains in the
STATE partition during a normal upgrade.

## Published image

For a repository named `OWNER/talos-asahi`, the immutable release tag is:

```text
ghcr.io/OWNER/talos-asahi/installer:v1.13.9-asahi.1
```

After the first ESP-based installation is working, upgrade a node with:

```sh
NODE_IP=192.0.2.10
talosctl upgrade \
  --nodes "${NODE_IP}" \
  --image ghcr.io/OWNER/talos-asahi/installer:v1.13.9-asahi.1 \
  --reboot-mode=powercycle
```

`powercycle` avoids relying on kexec while the boot path is still experimental.
If Omni has the machine locked against changes, temporarily unlock it for the
custom upgrade and lock it again after the node returns healthy.

## ESP contract

The existing Asahi ESP must have GPT partition label `EFI`, because Talos finds
the partition by that label. Keep the Apple GPT, iBootSystemContainer, macOS,
RecoveryOS, and the existing Asahi boot chain intact.

The initial boot bundle is installed into the existing Asahi ESP as follows:

```text
EFI/BOOT/BOOTAA64.EFI       <- dist/BOOTAA64.EFI
EFI/Linux/Talos-v1.13.9.efi <- dist/Talos-v1.13.9.efi
loader/loader.conf          <- dist/loader.conf
```

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
three source pins, applies every patch with `git apply --check`, and runs the
focused Talos sd-boot unit tests.

`Build and publish Asahi Talos` runs manually or when a matching release tag is
pushed. It uses GitHub's native ARM64 runner, builds the kernel, overlay, and
Talos imager, verifies the final artifacts, and optionally publishes:

```text
ghcr.io/OWNER/talos-asahi/installer:<release>
ghcr.io/OWNER/talos-asahi/kernel:<kernel-release>
ghcr.io/OWNER/talos-asahi/sbc-asahi:<overlay-release>
```

For a release, update `versions.env`, make sure the patches still apply, bump
`BUILD_REVISION` when appropriate, and push the exact computed tag. For the
current pins that tag is `v1.13.9-asahi.1`.

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
- sbc-template `c9ac1386c86e37bcee0e5daf21ffaa958240e081`
- AsahiLinux/linux `77cb8f24c2381a8abb7272d7bbdec548d6426a8a`

Do not write a generated raw disk image over the whole internal Apple NVMe.
That would replace the partition table instead of preserving the Asahi/macOS
layout this project is designed around.
