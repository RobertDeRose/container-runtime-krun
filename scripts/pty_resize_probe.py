#!/usr/bin/env python3
"""Validate established PTY resize delivery; diagnose CLI startup separately."""

import argparse
from collections.abc import Callable, Sequence
from datetime import UTC, datetime
import errno
import os
import pty
import select
import signal
import sys
import termios
import time
from typing import Literal

INITIAL_SIZE = (24, 80)
TARGET_SIZE = (40, 100)
SETUP_SIZE = (30, 90)
MEASURED_SIZES = ((40, 100), (32, 72), (24, 80))

# Read the guest PTY independently of the trap. A geometry change alone is not
# enough to pass: the guest must also handle a WINCH at the requested size.
STARTUP_GUEST_SCRIPT = r'''
resized=0
on_winch() {
    size=$(stty size </dev/tty) || exit 2
    printf 'winch size=%s\n' "$size"
    [ "$size" != '40 100' ] || resized=1
}
trap on_winch WINCH
printf 'ready initial=%s pid=%s tty=%s\n' "$(stty size </dev/tty)" "$$" "$(tty)"
i=0
while [ "$i" -lt 120 ]; do
    size=$(stty size </dev/tty) || exit 2
    printf 'sample size=%s\n' "$size"
    if [ "$resized" -eq 1 ] && [ "$size" = '40 100' ]; then
        printf 'resized=%s\n' "$size"
        exit 0
    fi
    i=$((i + 1))
    sleep 0.25
done
printf 'guest observation limit reached\n'
exit 1
'''


# A distinct setup size proves a real host-to-guest round trip. Subsequent sizes
# are unique so stale setup/previous-step markers cannot pass a measured resize.
COMPATIBILITY_GUEST_SCRIPT = r'''
winch_size=
on_winch() {
    if size=$(stty size </dev/tty 2>/dev/null); then
        printf 'winch size=%s\n' "$size"
        winch_size=$size
    fi
}
trap on_winch WINCH
ready=0
i=0
set -- __SIZES__
while [ "$i" -lt 240 ]; do
    i=$((i + 1))
    if size=$(stty size </dev/tty 2>/dev/null); then
        printf 'sample size=%s\n' "$size"
        if [ "$ready" -eq 0 ] && [ "$size" = '24 80' ]; then
            printf 'ready initial=%s pid=%s tty=%s\n' "$size" "$$" "$(tty)"
            ready=1
        fi
        if [ "$ready" -eq 1 ] && [ "$size" = "$1" ] && [ "$winch_size" = "$1" ]; then
            printf 'confirmed=%s\n' "$size"
            shift
            [ "$#" -ne 0 ] || exit 0
        fi
    fi
    sleep 0.25
done
printf 'guest observation limit reached\n'
exit 1
'''.replace('__SIZES__', ' '.join(f"'{rows} {cols}'" for rows, cols in (SETUP_SIZE, *MEASURED_SIZES)))


def report(message: str) -> None:
    stamp = datetime.now(UTC).isoformat(timespec="milliseconds")
    print(f"{stamp} monotonic={time.monotonic():.6f} {message}", flush=True)


class PTYOutput:
    """Keep partial lines across reads; only complete lines satisfy a handshake."""

    def __init__(self, fd: int) -> None:
        self.fd = fd
        self.pending = bytearray()
        self.eof = False

    def read(self, timeout: float) -> list[str]:
        if self.eof:
            time.sleep(timeout)
            return []
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return []
        try:
            chunk = os.read(self.fd, 4096)
        except OSError as error:
            # Linux reports PTY closure as EIO; macOS may return an empty read.
            if error.errno != errno.EIO:
                raise
            chunk = b""
        if not chunk:
            self.eof = True
            if self.pending:
                report(f"guest partial={bytes(self.pending)!r}")
                self.pending.clear()
            return []
        self.pending.extend(chunk)
        parts = self.pending.split(b"\n")
        self.pending = bytearray(parts.pop())
        lines = [part.rstrip(b"\r").decode(errors="replace") for part in parts]
        for line in lines:
            report(f"guest {line}")
        return lines

    def wait_for(self, predicate: Callable[[str], bool], timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while not self.eof:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            if any(predicate(line) for line in self.read(min(0.1, remaining))):
                return True
        return False


def wait_for_exit(pid: int, output: PTYOutput, timeout: float) -> int | None:
    deadline = time.monotonic() + timeout
    while True:
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            return status
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        # Drain while waiting so a child writing its final output can exit.
        try:
            output.read(min(0.05, remaining))
        except OSError as error:
            # A broken read must not prevent TERM/KILL or mask the probe failure.
            report(f"cleanup output error: {error}")
            output.eof = True


def cleanup_child(
    pid: int,
    output: PTYOutput,
    *,
    exit_timeout: float = 5.0,
    term_timeout: float = 1.0,
    kill_timeout: float = 2.0,
) -> tuple[int | None, bool]:
    status = wait_for_exit(pid, output, exit_timeout)
    forced = False
    for sig, timeout in ((signal.SIGTERM, term_timeout), (signal.SIGKILL, kill_timeout)):
        if status is not None:
            break
        forced = True
        report(f"cleanup signal={sig.name} pid={pid}")
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass
        status = wait_for_exit(pid, output, timeout)
    if status is None:
        report(f"cleanup FAILED: child pid={pid} was not reaped before the deadline")
    else:
        report(f"cleanup exit_code={os.waitstatus_to_exitcode(status)} forced={str(forced).lower()}")
    return status, forced


def request_resize(pid: int, fd: int, size: tuple[int, int], label: str) -> None:
    termios.tcsetwinsize(fd, size)
    actual = termios.tcgetwinsize(fd)
    report(f"{label} ioctl requested={size} observed={actual} cli_pid={pid}")
    if actual != size:
        raise RuntimeError(f"host PTY size is {actual}, expected {size}")
    report(f"{label} signal=SIGWINCH cli_pid={pid}")
    os.kill(pid, signal.SIGWINCH)


def observe_startup(pid: int, fd: int, output: PTYOutput, timeout: float) -> str | None:
    request_resize(pid, fd, TARGET_SIZE, "first_attempt")

    def matched(line: str) -> bool:
        return line == "resized=40 100"

    if output.wait_for(matched, timeout):
        report("first_attempt=PASS")
        report("retry=NOT_NEEDED")
        return None

    failure = "guest PTY did not confirm resize to 40x100 on the first attempt"
    report(f"first_attempt=FAIL: {failure}")
    if output.eof:
        report("retry=SKIPPED: PTY closed")
    else:
        # Diagnostic only: recovery never changes the failed startup result.
        report(f"retry signal=SIGWINCH only cli_pid={pid} host_size={termios.tcgetwinsize(fd)}")
        os.kill(pid, signal.SIGWINCH)
        if output.wait_for(matched, timeout):
            report("retry=RECOVERED: first_attempt remains FAIL")
        else:
            report("retry=FAILED: no target confirmation")
    return failure


def observe_compatibility(
    pid: int,
    fd: int,
    output: PTYOutput,
    *,
    setup_timeout: float,
    setup_interval: float,
    resize_timeout: float,
) -> None:
    # Resends are permitted only here, to establish the CLI-to-guest path.
    # Readiness text or a fixed sleep is not evidence of listener readiness.
    deadline = time.monotonic() + setup_timeout
    request_resize(pid, fd, SETUP_SIZE, "setup")
    attempts = 1
    expected = f"confirmed={SETUP_SIZE[0]} {SETUP_SIZE[1]}"
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or output.eof:
            raise RuntimeError("PTY setup did not confirm a resize round trip before its deadline")
        if output.wait_for(lambda line: line == expected, min(setup_interval, remaining)):
            report(f"setup=PASS notifications={attempts}; setup is not a measured resize")
            break
        if time.monotonic() < deadline and not output.eof:
            attempts += 1
            report(f"setup resend=SIGWINCH notification={attempts} cli_pid={pid}")
            os.kill(pid, signal.SIGWINCH)

    for index, size in enumerate(MEASURED_SIZES, start=1):
        label = f"measured[{index}]"
        request_resize(pid, fd, size, label)
        expected = f"confirmed={size[0]} {size[1]}"
        if not output.wait_for(lambda line: line == expected, resize_timeout):
            raise RuntimeError(f"{label} did not confirm {size[0]}x{size[1]}; retries are disabled")
        report(f"{label}=PASS size={size} retry=NOT_ALLOWED")


def run_probe(
    command: Sequence[str],
    *,
    mode: Literal["compatibility", "startup"] = "compatibility",
    ready_timeout: float = 10.0,
    setup_timeout: float = 10.0,
    setup_interval: float = 0.5,
    resize_timeout: float = 10.0,
    exit_timeout: float = 5.0,
    term_timeout: float = 1.0,
    kill_timeout: float = 2.0,
) -> int:
    if not command:
        raise ValueError("probe command must not be empty")
    if mode not in ("compatibility", "startup"):
        raise ValueError(f"unknown probe mode: {mode}")
    if setup_timeout <= 0 or setup_interval <= 0:
        raise ValueError("setup deadlines must be positive")
    sys.stdout.flush()
    pid, fd = pty.fork()
    if pid == 0:
        try:
            # Establish the baseline before the CLI exists, without delivering
            # a startup SIGWINCH to an incompletely initialized CLI listener.
            termios.tcsetwinsize(0, INITIAL_SIZE)
            os.execvp(command[0], command)
        except (OSError, ValueError) as error:
            os.write(2, f"exec failed: {error}\n".encode())
            os._exit(127)

    output = PTYOutput(fd)
    failure: str | None = None
    status: int | None = None
    forced = False
    report(f"probe mode={mode} cli_pid={pid} initial=24x80")
    try:
        def ready(line: str) -> bool:
            if mode == "startup":
                return line.startswith("ready initial=")
            return line == "ready initial=24 80" or line.startswith("ready initial=24 80 ")

        if not output.wait_for(ready, ready_timeout):
            raise RuntimeError("PTY did not arm resize handling with the required initial geometry")
        if mode == "startup":
            failure = observe_startup(pid, fd, output, resize_timeout)
        else:
            observe_compatibility(
                pid, fd, output, setup_timeout=setup_timeout,
                setup_interval=setup_interval, resize_timeout=resize_timeout,
            )
    except (OSError, RuntimeError) as error:
        report(f"probe error: {error}")
        failure = failure or str(error)
    finally:
        try:
            status, forced = cleanup_child(
                pid, output, exit_timeout=exit_timeout, term_timeout=term_timeout, kill_timeout=kill_timeout
            )
        except (OSError, RuntimeError) as error:
            report(f"cleanup error: {error}")
            failure = failure or f"cleanup failed: {error}"
        finally:
            os.close(fd)

    if status != 0 or forced:
        failure = failure or "container exec did not exit cleanly without forced cleanup"
    report(f"result={'FAIL: ' + failure if failure else 'PASS'}")
    return int(failure is not None)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("container_id", help="Existing running test container")
    parser.add_argument(
        "--mode", choices=("compatibility", "startup"), default="compatibility",
        help="Required established-session validation (default), or strict startup diagnostic",
    )
    args = parser.parse_args()
    script = COMPATIBILITY_GUEST_SCRIPT if args.mode == "compatibility" else STARTUP_GUEST_SCRIPT
    return run_probe(["container", "exec", "-i", "-t", args.container_id, "sh", "-c", script], mode=args.mode)


if __name__ == "__main__":
    raise SystemExit(main())
