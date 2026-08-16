# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Not a distro — my personal configuration of Fedora's own [bootc](https://containers.github.io/bootc/) image, built as two Containerfiles on a common `base`:

- **base** — plain Fedora bootc + KVM/libvirt + zsh/chezmoi/atuin/dev tooling. No desktop, no Kubernetes. Not published/used standalone, just the shared parent.
- **server** — base + K3s + KubeVirt + Agent Substrate, all combined into one image (not three layered flavors), plus a basic Niri+DankMaterialShell desktop for when a monitor's plugged in. Boots headless by default.
- **desktop** — base + Niri/DankMaterialShell, Sway, and COSMIC, all three installed side by side and switchable from the graphical COSMIC greeter, plus a bluefin-dx-inspired developer experience layer (Homebrew, Docker, VS Code, mise, Ptyxis, Flatpak). Boots to the login screen.

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
2. **The two flavors use greeters appropriate to their scope.** Server keeps
   the small `greetd` + `tuigreet` login path for its optional single Niri
   session. Desktop uses `cosmic-greeter`, which is already required by the
   COSMIC package set and provides a graphical chooser for Niri, Sway, and
   COSMIC. `/usr/share/wayland-sessions/*.desktop` entries are written
   explicitly for all three desktop sessions.

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
niri/systemd/                        # per-user chezmoi initialization/update units shared by both flavors
wallpapers/                          # original Bootsy wallpapers shared by every desktop environment
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

`FROM` base, five sections in this order — preserve the order; the first three depend on each other, the last two are independent of them and of each other:

1. **K3s** — SELinux to permissive, `curl https://get.k3s.io | ... sh -s - server --disable=traefik --disable=servicelb --write-kubeconfig-mode=644` baked into the image (`INSTALL_K3S_SKIP_ENABLE=true`, since the installer's own enable step needs a live systemd bus that doesn't exist during a container build — `systemctl enable k3s.service` is done explicitly instead), `/etc/profile.d/k3s-kubeconfig.sh` so every shell has `KUBECONFIG` set.
2. **KubeVirt** — resolves the current stable release tag at build time, installs `virtctl`, writes `/etc/kubevirt-version` as the single source of truth a first-boot `kubevirt-bootstrap.service` reads from. Version pinning is build-time-only; nothing at runtime re-resolves "latest".
3. **Agent Substrate** — built from source (`golang` toolchain, no prebuilt binaries published) at a pinned `SUBSTRATE_VERSION` build arg (default `v0.0.0`, which is genuinely the only tag `agent-substrate/substrate` has published as of this writing — bump the default, and any CI build-args, when that changes). Runs its own local anonymous OCI registry (`docker-distribution`) since there's nothing to `kubectl apply` the way KubeVirt has; `agent-substrate-bootstrap.service` waits for K3s *and* that registry, then runs Substrate's own `hack/install-ate.sh`.
4. **PostgreSQL** — a native host service, not a K3s workload: plain `postgresql-server` from Fedora's repos, data under `/var/lib/pgsql/data`, runs independently of K3s/KubeVirt/Substrate and of cluster state. Fedora's RPM deliberately skips auto-`initdb` on first start (avoids clobbering a slow-to-mount remote `PGDATA` — see `/usr/libexec/postgresql-check-db-dir`), so a `postgresql-bootstrap.service` (`ConditionPathExists=!/var/lib/pgsql/data/PG_VERSION`, ordered `Before=postgresql.service`) runs `postgresql-setup --initdb` once, the same first-boot-bootstrap shape used for KubeVirt/Substrate above. No network exposure or auth changes beyond the RPM's own defaults (localhost-only) — deliberately left that way until there's an actual consumer that needs otherwise.
5. **Basic Niri+DMS desktop** — same package set and `niri-session`/DMS wiring as `desktop/Containerfile`'s niri parts, but single-session (no picker, no theming, no dev layer) and left off the default boot target. It retains the lightweight `greetd` + `tuigreet` login path.

## desktop/Containerfile

`FROM` base, five sections in this order:

1. **Desktops** — one `dnf install` for all three DEs' packages plus shared portal/audio/font plumbing. `cosmic-desktop` is a comps group (`dnf group install`) and pulls in `cosmic-greeter`. Package names/versions were confirmed directly against live Fedora 44 repos while building this image (`dnf5 repoquery`), not assumed — same verification discipline the reference repo used. No COPRs for anything in this section.
2. **Session entries** — explicit `/usr/share/wayland-sessions/{niri,sway,cosmic}.desktop`, so the graphical greeter always shows these three stable names and commands.
3. **Per-DE wiring** — the original collection under `wallpapers/` is installed to `/usr/share/backgrounds/bootsy-linux` for every picker, with `bootsy-zircon-flow.webp` as the common default. Niri's chezmoi source under `/usr/share/bootsy/dotfiles` is derived from niri's own shipped default (Waybar autostart stripped, Fuzzel binding replaced by DMS Spotlight, focus-ring recolored from niri's stock light blue to the same neutral tone Sway uses, `prefer-no-csd` and a `geometry-corner-radius`/`clip-to-geometry` window-rule turned on so the focus-ring/shadow actually follow rounded window corners instead of framing the client's full rectangular surface, shadows turned on at niri's own stock softness/spread/offset/color, DMS and swaybg spawned at startup) and shared systemd user units install it to `~/.config/niri/config.kdl` before the first graphical session and track image updates; `~/.config/niri/local.kdl` is reserved for durable user overrides. The same chezmoi source also seeds `~/.local/state/DankMaterialShell/session.json` with `wallpaperPath` (via chezmoi's `create_` prefix — written once, never reapplied) so DMS's own background layer, which is otherwise blank until configured through its settings UI, agrees with swaybg's wallpaper from first login instead of briefly showing nothing once DMS finishes starting. It likewise `create_`-seeds `~/.config/DankMaterialShell/settings.json` with `currentThemeName: "dynamic"`, switching DMS from its static default theme to matugen-driven wallpaper theming — every relevant per-app template toggle already defaults on in DMS itself — and niri's `config.kdl` includes `dms/colors.kdl`, the file DMS's built-in niri matugen template writes to, so the focus-ring accent color updates with the wallpaper (falling back to the static neutral color above until that file exists). GTK and alacritty get the same treatment, shared across both Niri and Sway sessions: `~/.config/gtk-{3,4}.0/gtk.css` (always-managed, pure plumbing) `@import`s DMS's generated `dank-colors.css`, and `~/.config/alacritty/alacritty.toml` (`create_`-seeded, user-owned) imports DMS's generated `dank-theme.toml`; neither GTK nor alacritty loads those generated filenames on its own. Sway uses administrator snippets for the wallpaper, neutral one-pixel border decorations, DMS Spotlight binding, and DMS in place of Fedora's Waybar; cosmic's wallpaper uses an `/etc/xdg/cosmic/...` override.
4. **Login / session switching** — `cosmic-greeter` provides a graphical session chooser for all three sessions.
5. **Developer experience** — bluefin-dx-inspired, not a 1:1 port (skips Incus, JetBrains Toolbox, GPU compute libs, kernel tracing tools — none of that was asked for; add it the same way if it's ever wanted):
   - **Docker Engine** via Docker's official repo (`download.docker.com`) — Fedora's own repos don't ship `docker-ce`, so this is the one deliberate exception to the "Fedora repos only, no third-party repos" rule the rest of this image family follows. Uses dnf5's `config-manager addrepo --from-repofile=` syntax, not dnf4's `--add-repo`.
   - **Homebrew** via `COPY --from=ghcr.io/ublue-os/brew:latest /system_files /` + `brew-setup.service` — Homebrew's installer refuses to run as root (which a Containerfile `RUN` is), so this bakes in ublue-os's own pre-packaged image and extracts it to `/var/home/linuxbrew` on first boot instead, per their documented integration pattern.
   - **VS Code** via Microsoft's official repo, plus a first-login `vscode-dms-theme.service` (same one-time pattern as the chezmoi dotfiles init) that installs DMS's bundled dynamic-theme extension and a `create_`-seeded `Code/User/settings.json` selecting it, so VS Code's colors follow the wallpaper too.
   - **mise** via its own official install script to `/usr/local/bin` (not Fedora-packaged).
   - **Ptyxis** + **Just**, plain Fedora packages, no extra repo.
   - **Flatpak**, with the Flathub remote add and app installs (Zen, Flatseal,
     Bazaar) deferred to a first-boot `flatpak-bootstrap.service` — both
     write under `/var/lib/flatpak`, which bootc doesn't re-seed on
     `bootc update` of an already-provisioned machine, only on a genuinely
     fresh deployment.
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
