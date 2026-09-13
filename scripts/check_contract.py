#!/usr/bin/env python3
"""Static checks that do not require resolving Swift package dependencies."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
main = (ROOT / "Sources/KrunRuntimePlugin/main.swift").read_text()
helper = (ROOT / "Sources/KrunVMMHelper/main.swift").read_text()
config = (ROOT / "plugin/container-runtime-krun/config.toml").read_text()

routes = {
    "bootstrap",
    "createProcess",
    "state",
    "stop",
    "kill",
    "resize",
    "wait",
    "start",
    "dial",
    "shutdown",
    "statistics",
    "copyIn",
    "copyOut",
    "snapshotDisk",
}
wired = set(re.findall(r"RuntimeRoutes\.([A-Za-z0-9_]+)\.rawValue", main))
wired.discard("createEndpoint")
missing = sorted(routes - wired)
extra = sorted(wired - routes)
if missing or extra:
    print(f"runtime route mismatch: missing={missing}, extra={extra}", file=sys.stderr)
    raise SystemExit(1)

required_symbols = {
    "krun_init_log",
    "krun_create_ctx",
    "krun_free_ctx",
    "krun_set_vm_config",
    "krun_disable_implicit_vsock",
    "krun_add_vsock",
    "krun_add_vsock_port2",
    "krun_add_net_unixgram",
    "krun_add_disk",
    "krun_disable_implicit_console",
    "krun_add_virtio_console_default",
    "krun_set_kernel",
    "krun_start_enter",
}
missing_symbols = sorted(symbol for symbol in required_symbols if f'"{symbol}"' not in helper)
if missing_symbols:
    print(f"helper symbol set incomplete: {missing_symbols}", file=sys.stderr)
    raise SystemExit(1)

if 'type = "runtime"' not in config:
    print("plugin config does not declare a runtime service", file=sys.stderr)
    raise SystemExit(1)

if "ContainerNetworkClient" not in (ROOT / "Package.swift").read_text():
    print("runtime target is missing ContainerNetworkClient", file=sys.stderr)
    raise SystemExit(1)

runtime_service = (ROOT / "Sources/KrunRuntimeCore/KrunRuntimeService.swift").read_text()
cleanup_match = re.search(
    r"private func cleanupContainer\(\) async \{(?P<body>.*?)\n  \}",
    runtime_service,
    re.DOTALL,
)
if cleanup_match is None:
    print("could not locate cleanupContainer", file=sys.stderr)
    raise SystemExit(1)
if "processes = [:]" in cleanup_match.group("body"):
    print(
        "cleanupContainer must preserve completed process records for concurrent/late waiters",
        file=sys.stderr,
    )
    raise SystemExit(1)

wait_match = re.search(
    r"private func waitForProcess\(_ id: String\) async throws -> ExitStatus \{(?P<body>.*?)\n  \}",
    runtime_service,
    re.DOTALL,
)
if wait_match is None:
    print("could not locate waitForProcess", file=sys.stderr)
    raise SystemExit(1)
wait_body = wait_match.group("body")
if "cleanupContainer" in wait_body or "waitForOutput" in wait_body:
    print(
        "waitForProcess must only await the shared process-exit task",
        file=sys.stderr,
    )
    raise SystemExit(1)
if "await io.waitForOutput()" not in runtime_service and "await io?.waitForOutput()" not in runtime_service:
    print(
        "the shared process wait task must own stdout/stderr drain before publishing exit",
        file=sys.stderr,
    )
    raise SystemExit(1)
if "await self.finalizeProcessExit(id: id, status: status)" not in runtime_service:
    print(
        "the shared process wait task must finalize cleanup before releasing XPC waiters",
        file=sys.stderr,
    )
    raise SystemExit(1)

if "if state != .stopping" not in runtime_service:
    print(
        "init exit finalization must not tear down the VM while explicit stop is in progress",
        file=sys.stderr,
    )
    raise SystemExit(1)
if "await waitForStopCompletion()" not in wait_body:
    print(
        "init waiters must remain gated until explicit stop cleanup completes",
        file=sys.stderr,
    )
    raise SystemExit(1)
if "releaseStopWaiters()" not in cleanup_match.group("body"):
    print(
        "container cleanup must release waiters blocked behind explicit stop",
        file=sys.stderr,
    )
    raise SystemExit(1)

if "var agent: Vminitd?" not in runtime_service:
    print(
        "each process record must own a dedicated vminitd connection",
        file=sys.stderr,
    )
    raise SystemExit(1)
if "controller.dialAgent()" not in runtime_service:
    print(
        "process start must dial a dedicated vminitd agent",
        file=sys.stderr,
    )
    raise SystemExit(1)
if "processAgent.waitProcess(id: id, containerID: containerID)" not in runtime_service:
    print(
        "process wait must use its dedicated vminitd agent",
        file=sys.stderr,
    )
    raise SystemExit(1)

bootstrap_match = re.search(
    r"public func bootstrap\(_ message: XPCMessage\) async throws -> XPCMessage \{(?P<body>.*?)\n  \}",
    runtime_service,
    re.DOTALL,
)
if bootstrap_match is None:
    print("could not locate bootstrap", file=sys.stderr)
    raise SystemExit(1)
bootstrap_body = bootstrap_match.group("body")
if "KrunProcessIO.prepare" in bootstrap_body or ".createProcess(" in bootstrap_body:
    print(
        "bootstrap must stop at VM/guest setup and defer init process/stdout setup to startProcess",
        file=sys.stderr,
    )
    raise SystemExit(1)

start_match = re.search(
    r"public func startProcess\(_ message: XPCMessage\) async throws -> XPCMessage \{(?P<body>.*?)\n  \}",
    runtime_service,
    re.DOTALL,
)
if start_match is None:
    print("could not locate startProcess", file=sys.stderr)
    raise SystemExit(1)
start_body = start_match.group("body")
for required in (
    "KrunProcessIO.prepare",
    "controller.dialAgent()",
    "processAgent.createProcess",
    "io.waitForGuestConnections()",
    "processAgent.startProcess",
):
    if required not in start_body:
        print(f"startProcess lifecycle is missing {required}", file=sys.stderr)
        raise SystemExit(1)
if "if !isInit" in start_body:
    print("init and exec must share the same create/start lifecycle", file=sys.stderr)
    raise SystemExit(1)

if "prepareNetworking(" not in bootstrap_body:
    print("bootstrap must allocate network attachments before VM boot", file=sys.stderr)
    raise SystemExit(1)
if "networkAttachments: networkResources.attachments" not in bootstrap_body:
    print("VM boot must receive allocated network attachments", file=sys.stderr)
    raise SystemExit(1)


vmnet_backend = (ROOT / "Sources/KrunRuntimeCore/KrunVMNetBackend.swift").read_text()
for required in (
    'case "allocationOnly"',
    'case "reserved"',
    'variant=allocationOnly',
    '"--operation-mode", "shared"',
    '"--enable-isolation"',
):
    if required not in vmnet_backend:
        print(f"vmnet backend is missing {required}", file=sys.stderr)
        raise SystemExit(1)
for forbidden in (
    "vmnet_network_create_with_serialization",
    "vmnet_interface_start_with_network(",
    "vmnet_read(",
    "vmnet_write(",
):
    if forbidden in vmnet_backend:
        print(
            f"runtime must not attempt reserved-network raw vmnet I/O: found {forbidden}",
            file=sys.stderr,
        )
        raise SystemExit(1)

vm_controller = (ROOT / "Sources/KrunRuntimeCore/KrunVMController.swift").read_text()
for required in (
    "agent.addressAdd(",
    "agent.up(",
    "agent.routeAddDefault(",
    "agent.configureDNS(",
    "agent.configureHosts(",
):
    if required not in vm_controller:
        print(f"guest network setup is missing {required}", file=sys.stderr)
        raise SystemExit(1)

print(
    "PASS: runtime routes, helper ABI surface, plugin type, lifecycle durability, and v0.2 allocation-only network wiring are complete"
)
