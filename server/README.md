# Using bootsy-server

Covers the K3s/KubeVirt/Agent Substrate parts of the `server` image and the
bundled basic desktop. For install/first-boot basics common to both
flavors, see the [top-level README](../README.md).

## First boot

`k3s.service` starts immediately (no network required — the binary is baked
into the image). `kubevirt-bootstrap.service` waits for the K3s API and
applies the KubeVirt operator + CR pinned in `/etc/kubevirt-version`.
`agent-substrate-bootstrap.service` waits for K3s *and* the local
`docker-distribution` registry, then deploys Agent Substrate's control plane
(this one needs network on first boot — it builds Substrate from source with
`ko` and pushes to the local registry). Give it a few minutes, then check:

```sh
kubectl get nodes
kubectl get pods -n kubevirt
kubectl get pods -n ate-system
```

`KUBECONFIG` is already exported for every shell via
`/etc/profile.d/k3s-kubeconfig.sh`.

Every interactive shell also opens with a `fastfetch` banner (the Boxed
logo plus OS/kernel/CPU/memory info) — wired up in `base`, so it's on
both flavors.

## Deploying containers to K3s

A normal single-node K3s cluster — `traefik` and `servicelb` are disabled
(no ingress/LB needed on a single box), everything else is stock.

```sh
kubectl apply -f hello.yaml
```

Locally built image, nothing pushed anywhere:

```sh
podman build -t local/myapp:dev .
podman save local/myapp:dev | sudo k3s ctr images import -
```

Reference `local/myapp:dev` with `imagePullPolicy: IfNotPresent` (or
`Never`) so K3s doesn't try to pull it from a registry.

## Running VMs in KubeVirt

`virtctl` is baked into `/usr/local/bin`, pinned to match the deployed
KubeVirt release. Only the core operator+CR are installed (no CDI), so the
straightforward way to get a disk image into a VM is **containerDisk**:

```dockerfile
FROM scratch
COPY my-disk.qcow2 /disk/
```

```sh
podman build -t ghcr.io/you/my-vm-disk:latest -f Containerfile.disk .
podman push ghcr.io/you/my-vm-disk:latest
```

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: my-vm
spec:
  running: false
  template:
    spec:
      domain:
        cpu: {cores: 2}
        resources:
          requests: {memory: 2Gi}
        devices:
          disks:
            - name: rootdisk
              disk: {bus: virtio}
            - name: cloudinitdisk
              disk: {bus: virtio}
      volumes:
        - name: rootdisk
          containerDisk:
            image: ghcr.io/you/my-vm-disk:latest
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              password: changeme
              chpasswd: {expire: false}
```

```sh
kubectl apply -f my-vm.yaml
virtctl start my-vm
virtctl console my-vm      # serial console
virtctl vnc my-vm          # graphical console (needs a local VNC viewer)
virtctl stop my-vm
```

> Want URL- or upload-based disk imports (`virtctl image-upload`,
> DataVolumes from a URL)? That needs CDI installed separately — it isn't
> part of this image's bootstrap step.

## Deploying agents on Agent Substrate

The control plane (CRDs, api-server, atenet-router, valkey) comes up fully
automatically with no external credentials needed. Deploying actual agent
workloads (`ActorTemplates`/`WorkerPools`/`SandboxConfigs`) is bring-your-own-harness —
Agent Substrate is framework-agnostic (LangChain, MCP servers, Claude Code
are all compatible per its own docs). See
[substrate's demos](https://github.com/agent-substrate/substrate/tree/main/demos)
for worked examples. Images you build for your own actors can go through the
same local registry the bootstrap script uses: `localhost:5000`.

## PostgreSQL

A native host service, not a K3s workload — it comes up on boot regardless
of cluster state. Data lives under `/var/lib/pgsql/data`, initialized once
by `postgresql-bootstrap.service` on first boot.

```sh
sudo -u postgres psql                          # local admin shell
sudo -u postgres createuser --pwprompt myapp
sudo -u postgres createdb --owner=myapp myapp
```

Fedora's defaults ship as-is: listening on `localhost` only, peer/ident
auth for local connections. If you need it reachable from K3s pods or over
the network, that's on you to configure (`postgresql.conf`'s
`listen_addresses`, `pg_hba.conf`) — nothing here changes those defaults.

## The bundled desktop

`niri` + `DankMaterialShell` is installed but the box boots headless
(`multi-user.target`) by default:

```sh
sudo systemctl start graphical.target       # this boot only
sudo systemctl set-default graphical.target  # persist across reboots
```

Login uses `tuigreet` (not DMS's own bundled greeter — see
[`../CLAUDE.md`](../CLAUDE.md) for why); it's a single fixed session, no
picker, no theming, no dev-experience layer. If you want the full desktop
experience with Sway/COSMIC switching and the bluefin-dx-inspired dev tools,
that's what `bootsy-desktop` is for.

## Troubleshooting

```sh
journalctl -u k3s.service
journalctl -u kubevirt-bootstrap.service
journalctl -u agent-substrate-bootstrap.service
journalctl -u docker-distribution.service
journalctl -u postgresql-bootstrap.service
journalctl -u postgresql.service
kubectl get pods -n kubevirt     # operator/virt-* components stuck/crashlooping
kubectl get pods -n ate-system   # Substrate control plane stuck/crashlooping
```

SELinux is set to `permissive` at build time on this flavor (K3s's CNI and
KubeVirt's device plugin need more than Fedora's default targeted policy
allows out of the box) — a deliberate, persisted setting, not something to
"fix" back to enforcing without also sorting out the required policy.
`bootsy-desktop` and `base` stay at Fedora's default `enforcing`.
