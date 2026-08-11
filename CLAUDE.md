# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

My personal Linux flavor: two [bootc](https://containers.github.io/bootc/) (bootable container) OS images built from a common `base`:

- **base** — plain Fedora bootc + KVM/libvirt + zsh/chezmoi/atuin/dev tooling. No desktop, no Kubernetes. Not published/used standalone, just the shared parent.
- **server** — base + K3s + KubeVirt + Agent Substrate, all combined into one image (not three layered flavors), plus a basic Niri+DankMaterialShell desktop for when a monitor's plugged in. Boots headless by default.
- **desktop** — base + Niri/DankMaterialShell (default), Sway, and COSMIC, all three installed side by side and switchable at login via `tuigreet`'s session picker, plus a bluefin-dx-inspired developer experience layer (Homebrew, Docker, VS Code, mise, Ptyxis, Flatpak). Boots to the login screen.

There is no application code — the entire project is the image definitions plus the CI pipeline that builds and publishes them.

### Descended from kubevirt-host-bootc-image

This repo is a deliberate simplification of an earlier study,
[kubevirt-host-bootc-image](https://github.com/eelcoh/kubevirt-host-bootc-image),
which shipped eight separate layered flavors (base / k3s / kubevirt /
agent-runtime / niri / sway / cosmic / niri-kubevirt). bootsy-linux collapses
that down to two flavors people actually pick between, with three
consequential departures worth knowing about before touching either
Containerfile:

1. **Server is one image, not three layered ones.** K3s, KubeVirt, and Agent
   Substrate are all installed in `server/Containerfile` directly, in that
   order, rather than as separate `k3s`/`kubevirt`/`agent-runtime` images.
   There's no scenario here where you want K3s without KubeVirt or Substrate,
   so the extra image-graph complexity wasn't worth it.
2. **`tuigreet` drives login everywhere, not DankMaterialShell's own bundled
   greeter.** The reference repo's niri flavor used DMS's own greeter via a
   hand-rolled fallback (a `greeter` system user + manual tmpfiles wiring),
   because Fedora ships no `dms-greeter` RPM. bootsy-desktop needs a generic,
   session-agnostic greeter anyway (to pick between niri/sway/cosmic at
   login), so both `server` and `desktop` standardize on `tuigreet` instead —
   one login mechanism, no greeter-specific user wiring, no Fedora packaging
   gap to work around. DankMaterialShell itself is unaffected: `dms.service`
   (a systemd `--user` unit wanted by `graphical-session.target`) starts
   however `niri-session` gets invoked, regardless of which greeter called it.
3. **`cosmic-greeter` is installed but disabled, not skipped.** `desktop`
   needs one greeter across three sessions, so `cosmic-greeter` (a
   self-contained display manager that claims `display-manager.service` for
   itself) can't be the one driving login. It can't be left out of the
   package set either, though: `cosmic-session` — mandatory in the
   `cosmic-desktop` comps group — hard-`Requires: cosmic-greeter` as of
   Fedora 44's packaging (confirmed with `dnf5 repoquery --whatrequires
   cosmic-greeter`), so it's pulled in regardless. `desktop/Containerfile`
   explicitly `systemctl disable`s it and force-enables `greetd` over it
   (`systemctl enable --force greetd.service`) rather than assuming it's
   absent. `/usr/share/wayland-sessions/*.desktop` entries are written
   explicitly for all three sessions instead of trusting each DE's RPM to
   ship one with a stable name.

Also dropped from the reference repo, deliberately, as things nobody asked
for here and easy to add later the same way they were added there: the
four-theme Sway color system (Nord/Catppuccin/Matcha Green/Chameleon Grove
Green — `desktop/Containerfile` just uses Fedora's stock `mermaid_dark.webp`
wallpaper everywhere), and Google's `ax`/Antigravity agent runtime
(Substrate's control plane only, same reasoning as the reference repo — see
`server/Containerfile`'s Agent Substrate section).

## Repository layout

```
base/Containerfile                   # shared by both flavors below
server/Containerfile                 # FROM base; k3s + kubevirt + agent substrate + basic niri/dms
server/README.md                     # K3s/KubeVirt/Substrate usage, specific to this flavor
desktop/Containerfile                # FROM base; niri/dms + sway + cosmic + dev-experience layer
scripts/make-installer-usb.sh        # builds+writes an installer ISO, defaults to `desktop`
.github/workflows/build-image.yml    # reusable workflow: builds+pushes one flavor
.github/workflows/build-images.yml   # orchestrator: base -> {server, desktop}
```

`server/Containerfile` and `desktop/Containerfile` both start with:

```dockerfile
ARG BASE_IMAGE=ghcr.io/eelcoh/bootsy-linux/base:latest
FROM ${BASE_IMAGE}
```

so `podman build` works standalone against the published `:latest` base by default, while CI overrides `BASE_IMAGE` to pin each flavor to the base image built earlier in the *same* workflow run rather than a possibly-stale `latest`.

`base/Containerfile` is `FROM quay.io/fedora/fedora-bootc:44` — see the reference repo's own CLAUDE.md for the fuller rationale (fedora-bootc's minimalism, real `/usr/local` vs. ostree-symlinked alternatives, why Hummingbird's `bootc-os` was rejected). That reasoning is unchanged here; it isn't re-derived in this repo.

## base/Containerfile

Numbered steps, preserve the numbering when editing:

1. `systemctl set-default multi-user.target` — boot to console by default. `server` stays on this; `desktop` overrides it to `graphical.target`.
2. KVM/virt packages (`qemu-kvm`, `libvirt`, `virt-install`, etc.) — every flavor gets host virtualization for free.
3. Mask `systemd-remount-fs.service` (fails every boot on this composefs root — known upstream ostree/bootc issue, `static` unit so `disable` can't touch it) and enable `sshd.service`.
4. Interactive dev tooling (`git`, `zsh`, `chezmoi`, `atuin`, `zoxide`, `htop`, `btop`, `distrobox`), zsh made the default shell for root and any account created afterwards.

SELinux is left at Fedora's default `enforcing` in `base`. `server` flips it to `permissive` (K3s's CNI, KubeVirt's device plugin, Substrate's sandboxed actors all need more than targeted allows); `desktop` never touches it.

## server/Containerfile

`FROM` base, four sections in this order — preserve the order, each depends on the previous:

1. **K3s** — SELinux to permissive, `curl https://get.k3s.io | ... sh -s - server --disable=traefik --disable=servicelb --write-kubeconfig-mode=644` baked into the image (`INSTALL_K3S_SKIP_ENABLE=true`, since the installer's own enable step needs a live systemd bus that doesn't exist during a container build — `systemctl enable k3s.service` is done explicitly instead), `/etc/profile.d/k3s-kubeconfig.sh` so every shell has `KUBECONFIG` set.
2. **KubeVirt** — resolves the current stable release tag at build time, installs `virtctl`, writes `/etc/kubevirt-version` as the single source of truth a first-boot `kubevirt-bootstrap.service` reads from. Version pinning is build-time-only; nothing at runtime re-resolves "latest".
3. **Agent Substrate** — built from source (`golang` toolchain, no prebuilt binaries published) at a pinned `SUBSTRATE_VERSION` build arg (default `v0.0.0`, which is genuinely the only tag `agent-substrate/substrate` has published as of this writing — bump the default, and any CI build-args, when that changes). Runs its own local anonymous OCI registry (`docker-distribution`) since there's nothing to `kubectl apply` the way KubeVirt has; `agent-substrate-bootstrap.service` waits for K3s *and* that registry, then runs Substrate's own `hack/install-ate.sh`.
4. **Basic Niri+DMS desktop** — same package set and `niri-session`/DMS wiring as `desktop/Containerfile`'s niri parts, but single-session (no picker, no theming, no dev layer) and left off the default boot target. See "Descended from..." above for why `tuigreet` and not DMS's own greeter.

## desktop/Containerfile

`FROM` base, five sections in this order:

1. **Desktops** — one `dnf install` for all three DEs' packages plus shared portal/audio/font plumbing. `cosmic-desktop` is a comps group (`dnf group install`); `cosmic-greeter` is deliberately *not* installed (see "Descended from..." above). Package names/versions were confirmed directly against live Fedora 44 repos while building this image (`dnf5 repoquery`), not assumed — same verification discipline the reference repo used. No COPRs for anything in this section.
2. **Session entries** — explicit `/usr/share/wayland-sessions/{niri,sway,cosmic}.desktop`, so `tuigreet`'s F3 picker always shows exactly these three, under these names, regardless of what each RPM does or doesn't ship on its own.
3. **Per-DE wiring** — niri's `/etc/niri/config.kdl` derived from niri's own shipped default (waybar autostart line stripped, wallpaper added); sway's wallpaper via `/etc/sway/config.d/40-wallpaper.conf` (picked up by `sway-config-fedora`'s own layered include); cosmic's wallpaper via an `/etc/xdg/cosmic/...` override (admin-tier in `cosmic-config`'s layering, below `~/.config/cosmic`, above the RPM-owned vendor default).
4. **Login / session switching** — single `tuigreet` config (`--remember --remember-user-session --cmd niri-session`) for all three sessions. F3 opens the picker; switching desktops day-to-day is log out, F3, pick the other one.
5. **Developer experience** — bluefin-dx-inspired, not a 1:1 port (skips Incus, JetBrains Toolbox, GPU compute libs, kernel tracing tools — none of that was asked for; add it the same way if it's ever wanted):
   - **Docker Engine** via Docker's official repo (`download.docker.com`) — Fedora's own repos don't ship `docker-ce`, so this is the one deliberate exception to the "Fedora repos only, no third-party repos" rule the rest of this image family follows. Uses dnf5's `config-manager addrepo --from-repofile=` syntax, not dnf4's `--add-repo`.
   - **Homebrew** via `COPY --from=ghcr.io/ublue-os/brew:latest /system_files /` + `brew-setup.service` — Homebrew's installer refuses to run as root (which a Containerfile `RUN` is), so this bakes in ublue-os's own pre-packaged image and extracts it to `/var/home/linuxbrew` on first boot instead, per their documented integration pattern.
   - **VS Code** via Microsoft's official repo.
   - **mise** via its own official install script to `/usr/local/bin` (not Fedora-packaged).
   - **Ptyxis** + **Just**, plain Fedora packages, no extra repo.
   - **Flatpak** + Flathub remote added.
6. `systemctl set-default graphical.target` — unlike `server`, `desktop` boots straight to the login screen.

## CI (.github/workflows/)

`build-image.yml` is a reusable workflow (`workflow_call`) that builds and pushes exactly one flavor: given `flavor`, `containerfile`, and optional `build_args`, computes a short SHA, builds with buildx, pushes `ghcr.io/<repo>/<flavor>:latest` and `:sha-<short>`.

`build-images.yml` is the orchestrator (push to `main` touching `base/**`/`server/**`/`desktop/**`/workflows, weekly Sunday cron, manual dispatch). Dependency order:

```
base ──┬─→ server
       └─→ desktop
```

Every job runs on every trigger — no per-flavor path filtering — so a downstream flavor is never built against a stale published base.

## Working with this repo

- No build/lint/test tooling beyond the Containerfiles themselves. Validate a change by building locally:
  ```sh
  podman build -f base/Containerfile -t local/base:dev .
  podman build -f server/Containerfile --build-arg BASE_IMAGE=local/base:dev -t local/server:dev .
  podman build -f desktop/Containerfile --build-arg BASE_IMAGE=local/base:dev -t local/desktop:dev .
  ```
  bootc images require a container runtime capable of building OCI images; there's no Kubernetes/VM available to test the first-boot bootstrap scripts or greeter flows short of actually booting the image.
- When evaluating a new package or an unfamiliar RPM, prefer checking it directly (`dnf5 repoquery --available <pkg>`, `dnf5 group info <group>`, `rpm -qlp`/`rpm -qp --scripts` on a downloaded RPM) over trusting docs or search results going stale. This is how every package name and version cited in this file and in the Containerfiles' own comments was confirmed while building this image.
- CI (`build-images.yml` + `build-image.yml`) is the source of truth for how the images are built and published; mirror any local build flags/context changes there.
- Multi-line heredoc `COPY <<-'EOF' ... EOF` blocks in the Containerfiles inject files directly — edit the heredoc body in place rather than switching to separate files unless there's a reason to.
