# container-runtime-krun

`container-runtime-krun` is an experimental Apple Container runtime plugin that boots the normal Apple Container Linux guest stack with [libkrun](https://github.com/libkrun/libkrun) and Hypervisor.framework instead of Virtualization.framework.

The project exists to validate and productize one specific advantage demonstrated by the preceding feasibility experiment: Apple's stock Container kernel negotiates `VIRTIO_BALLOON_F_REPORTING` with libkrun, allowing guest-released pages to become reclaimable by macOS while the VM remains running.

No changes to `apple/container` or `apple/containerization` are required. The plugin uses Apple Container's public `runtime` plugin contract.

## v0.1 scope

v0.1 intentionally targets the smallest useful runtime surface:

| Capability | v0.1 |
| --- | --- |
| Boot Apple kernel + vminitd with libkrun | yes |
| Run initial container process | yes |
| `container exec` | yes |
| stdin/stdout/stderr | yes, fixed predeclared vsock pool |
| terminal resize | yes |
| signal / stop / wait | yes |
| container statistics | yes |
| automatic free-page reporting | yes, provided by libkrun + Apple kernel |
| Networking | no |
| Published ports | no |
| Host/volume/virtiofs mounts | no |
| Published Unix sockets | no |
| Arbitrary runtime `dial(port)` | no |
| `copyIn` / `copyOut` | no |
| Disk snapshot / trim | no |
| Rosetta | no |
| Nested virtualization | no |
| SSH agent forwarding | no |
| `--init` | no |

Unsupported features fail with `ContainerizationError(.unsupported)` rather than silently degrading.

Because Apple Container normally attaches a default network, v0.1 must be invoked with `--network none`.

## Prerequisites

- Apple Silicon Mac
- Apple Container source/API compatible with commit `eee7ad097079cc3b02d5309ec10160143f2d0c6a`
- Containerization `0.43.0`
- Swift 6.2+
- libkrun 1.19.4
- the libkrun Homebrew tap's matching `virglrenderer` (`0.10.4e`), not Homebrew core's newer incompatible ABI

Recommended libkrun installation:

```bash
brew tap libkrun/krun
brew install libkrun/krun/virglrenderer
brew install libkrun/krun/libkrun
```

## Build and install

```bash
make release
make install
```

`make install` derives the Apple Container installation root from the resolved `container` executable. Override it when necessary:

```bash
make install INSTALL_ROOT=/path/to/container/install/root
```

The installed layout is:

```text
$INSTALL_ROOT/libexec/container-plugins/container-runtime-krun/
├── config.toml
└── bin/
    ├── container-runtime-krun
    └── container-krun-vmm-helper
```

The VMM helper is ad-hoc signed with the `com.apple.security.hypervisor` entitlement. The runtime plugin does not need that entitlement because libkrun is isolated in the helper process.

Restart the Apple Container system after installing so the API server rescans runtime plugins:

```bash
container system stop
container system start
```

## Use

Start with the runtime selected explicitly:

```bash
container run --rm \
  --runtime container-runtime-krun \
  --network none \
  alpine:3.20 echo hello-from-libkrun
```

Once feature parity is sufficient, a separately installed user plugin named `container-runtime-linux` can shadow Apple's bundled runtime. v0.1 deliberately does not install itself that way.

## Design constraints

The runtime is one plugin process per Apple Container sandbox. It starts one child `container-krun-vmm-helper` process that owns libkrun and the Hypervisor.framework entitlement.

libkrun's vsock mappings are configured before VM start. v0.1 therefore reserves:

- guest port `1024` for the host-to-guest vminitd control channel;
- 96 guest-to-host ports beginning at `0x10000000` for process stdio.

The pool supports 32 simultaneously connected processes when all three stdio streams are present. Ports are returned to the pool when a process is cleaned up.

See [docs/design.md](docs/design.md) for the lifecycle and rationale.

## Status

The underlying VM path is proven on macOS: Apple kernel boot, vminitd, ext4 block devices, OCI process execution, vsock control, and `VIRTIO_BALLOON_F_REPORTING` all succeeded with libkrun 1.19.4. The standalone plugin packaging and its predeclared stdio bridge are the new v0.1 integration layer and still require end-to-end validation on macOS.
