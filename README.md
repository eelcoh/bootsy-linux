<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/bootsy-wordmark-dark.svg">
    <img src="branding/bootsy-wordmark.svg" alt="bootsy-linux" height="72">
  </picture>
</p>

# bootsy-linux

**Not a distro** — my personal configuration of Fedora's own
[bootc](https://containers.github.io/bootc/) image. Two Containerfiles,
`server` and `desktop`, layered on a shared `base` that's itself just
`quay.io/fedora/fedora-bootc:44` plus some `dnf install`s and config. No
separate package repository, no installer branding, no release cadence of
its own — it's Fedora underneath, start to finish, just built the way I
want it out of the box instead of configured by hand after the fact.
Everything is baked into the image at build time — a box needs no network
access on first boot to come up working, and SSH (`sshd.service`) is
enabled out of the box on both flavors.

Descended from an earlier, more fragmented study,
[kubevirt-host-bootc-image](https://github.com/eelcoh/kubevirt-host-bootc-image)
— see [`CLAUDE.md`](CLAUDE.md) for what changed and why. This document is
about *using* the appliances once installed.

## Flavors

| Image | What it is |
|---|---|
| `ghcr.io/eelcoh/bootsy-linux/base` | Plain Fedora bootc + KVM/libvirt + zsh/chezmoi/dev tooling. No desktop, no Kubernetes. Not published/used standalone — the shared parent of both flavors below. |
| `ghcr.io/eelcoh/bootsy-linux/server` | base + K3s + KubeVirt + Agent Substrate + PostgreSQL, all in one image, plus a basic Niri+DankMaterialShell desktop for when a monitor's plugged in. Boots headless by default. See [`server/README.md`](server/README.md). |
| `ghcr.io/eelcoh/bootsy-linux/desktop` | base + Niri/DankMaterialShell (default), Sway, and COSMIC, switchable at login, plus a bluefin-dx-inspired developer experience layer (Homebrew, Docker, VS Code, mise, Flatpak). No Kubernetes. Boots to the login screen. |

## Prerequisites

- A CPU with hardware virtualization (Intel VT-x / AMD-V) and `/dev/kvm`
  available — KVM/libvirt is in `base`, and `bootsy-server`'s KubeVirt runs
  VMs under emulation without it, which works but is very slow.
- For bare metal: BIOS/UEFI virtualization extensions enabled.

## Installing

Replace `<image>` below with `ghcr.io/eelcoh/bootsy-linux/server:latest` or
`ghcr.io/eelcoh/bootsy-linux/desktop:latest`.

### Onto an existing bootc/Fedora system

```sh
sudo bootc switch <image>
sudo systemctl reboot
```

This also works to move between `server` and `desktop` on a box you already
installed.

### Fresh bare metal / VM

Anaconda itself isn't part of the deployed appliance — `quay.io/fedora/fedora-bootc:44`
doesn't ship it. "Install with Anaconda" means building install *media* that
boots into Anaconda pointed at this image:

**Unattended, graphical progress (recommended)** — build an installer ISO
with [`bootc-image-builder`](https://github.com/osbuild/bootc-image-builder):

```sh
cat > config.toml <<'EOF'
[[customizations.user]]
name = "youruser"
password = "yourpassword"
groups = ["wheel"]
EOF

sudo podman run --rm -it --privileged \
  --pull=newer \
  --security-opt label=type:unconfined_t \
  -v ./config.toml:/config.toml:ro \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type iso \
  --rootfs ext4 \
  <image>
```

`--rootfs` is required: plain `quay.io/fedora/fedora-bootc:44` ships no
`/usr/lib/bootc/install.toml`, so `bootc-image-builder` has no default
root-fs-type to fall back on. `config.toml` is also required: neither image
creates a login user or sets a root password on its own, so without a
`[[customizations.user]]` block the install completes with a system nothing
can log into.

**Hostname is not settable this way.** `bootc-image-builder`'s ISO path
never writes a hostname into the kickstart it generates, so the install
always comes up as `fedora` (from the base image's `/usr/lib/os-release`)
regardless of what's typed into Anaconda or `config.toml`. Set a real one
after first boot:

```sh
sudo hostnamectl set-hostname mybox
```

Swap `--type iso` for `--type qcow2` or `--type raw` for a disk image
instead of installer media.

[`scripts/make-installer-usb.sh`](scripts/make-installer-usb.sh) automates
the ISO build above and writes the result straight to a USB stick (defaults
to the `desktop` flavor):

```sh
sudo scripts/make-installer-usb.sh -d /dev/sdb -u eelco
sudo scripts/make-installer-usb.sh -d /dev/sdb -u eelco -i ghcr.io/eelcoh/bootsy-linux/server:latest
```

**Scripted, via kickstart on a stock Fedora Anaconda ISO** — no custom image
build needed:

```
zerombr
clearpart --all --initlabel
autopart

lang en_US.UTF-8
keyboard us
timezone UTC --utc
rootpw --lock

bootc --source-imgref=registry:<image>
```

Boot the installer with `inst.ks=http://.../bootsy.ks` on the kernel command
line, or embed it in the ISO with `mkksiso`.

## First boot

### bootsy-server

Boots to a console (`multi-user.target`); K3s/KubeVirt/Agent Substrate all
come up automatically with no network needed on first boot. See
[`server/README.md`](server/README.md) for `kubectl`/`virtctl` usage,
deploying workloads/VMs, and bringing up the bundled desktop on demand.

### bootsy-desktop

Boots straight to the login screen (`greetd` + `tuigreet`). Log in and
you're in Niri+DankMaterialShell by default. `alacritty` is the default
terminal for Niri/Sway (matches Niri's own `Mod+T` keybind); COSMIC uses its
own `cosmic-term`.

**Switching desktops**: at the login prompt, press `F3` to open the session
picker and choose Niri, Sway, or COSMIC — `tuigreet` remembers each user's
last choice (`--remember-user-session`) across reboots, so switching is just
logging out, hitting F3, and picking the other one.

**Developer experience** (bluefin-dx-inspired): `brew` (Homebrew, extracted
to `/var/home/linuxbrew` on first boot by `brew-setup.service` — give it a
few seconds after your first login), `docker` (add yourself to the `docker`
group: `sudo usermod -aG docker $USER`, then re-login), `code` (VS Code),
`mise` (per-project toolchain versions — add `eval "$(mise activate zsh)"`
to your `~/.zshrc` to enable it, e.g. via chezmoi), `just` (task runner),
`ptyxis` (a distrobox-integrated terminal alongside alacritty), and
`flatpak` (Flathub already added as a remote).

Every interactive shell also opens with a `fastfetch` banner (the Boxed
logo plus OS/kernel/CPU/memory info) — wired up in `base`, so it's on both
flavors.

SSH stays available on both flavors regardless of the boot target.

## Troubleshooting

```sh
journalctl -u greetd.service       # login screen not coming up
journalctl -u brew-setup.service   # bootsy-desktop: Homebrew not showing up after first boot
```

See [`server/README.md`](server/README.md#troubleshooting) for
K3s/KubeVirt/Agent Substrate troubleshooting and SELinux notes
(`bootsy-server` only — `bootsy-desktop` stays at Fedora's default
`enforcing`).
