"""Exercise the probe without Apple Container, vmnet, or a guest VM."""

from contextlib import redirect_stdout
import errno
import io
import os
from pathlib import Path
import signal
import sys
import unittest
from unittest.mock import call, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pty_resize_probe as probe


class PTYProbeTests(unittest.TestCase):
    def run_probe(self, command: list[str], *, resize_timeout: float = 0.4) -> tuple[int, str]:
        output = io.StringIO()
        # Keep failure tests short; the public probe uses longer deadlines.
        with redirect_stdout(output):
            status = probe.run_probe(
                command,
                mode="startup",
                ready_timeout=1.5,
                resize_timeout=resize_timeout,
                exit_timeout=1.0,
                term_timeout=0.1,
                kill_timeout=1.0,
            )
        return status, output.getvalue()

    def test_real_pty_resize_and_clean_exit(self) -> None:
        status, output = self.run_probe(["/bin/sh", "-c", probe.STARTUP_GUEST_SCRIPT], resize_timeout=2.0)
        self.assertEqual(status, 0, output)
        self.assertIn("ready initial=24 80", output)
        self.assertIn("guest sample size=40 100", output)
        self.assertIn("guest winch size=40 100", output)
        self.assertIn("first_attempt=PASS", output)
        self.assertIn("retry=NOT_NEEDED", output)
        self.assertIn("exit_code=0 forced=false", output)

    def test_initial_size_winch_does_not_end_guest(self) -> None:
        script = probe.STARTUP_GUEST_SCRIPT.replace("trap on_winch WINCH", "trap on_winch WINCH\nkill -WINCH $$")
        status, output = self.run_probe(["/bin/sh", "-c", script], resize_timeout=2.0)
        self.assertEqual(status, 0, output)
        self.assertIn("guest winch size=24 80", output)
        self.assertIn("guest resized=40 100", output)

    def test_geometry_alone_does_not_pass(self) -> None:
        script = probe.STARTUP_GUEST_SCRIPT.replace("trap on_winch WINCH", "trap '' WINCH")
        status, output = self.run_probe(["/bin/sh", "-c", script])
        self.assertEqual(status, 1, output)
        self.assertIn("guest sample size=40 100", output)
        self.assertNotIn("guest winch size=40 100", output)
        self.assertIn("first_attempt=FAIL", output)
        self.assertIn("retry=FAILED", output)

    def test_retry_recovery_does_not_pass_or_repeat_ioctl(self) -> None:
        # Drop both first-attempt notifications. Register the listener only
        # after observing the changed geometry, while the first window runs.
        script = '''
import signal, termios, time
signal.signal(signal.SIGWINCH, signal.SIG_IGN)
print('ready initial=24 80', flush=True)
while termios.tcgetwinsize(0) != (40, 100):
    time.sleep(0.005)
time.sleep(0.05)
def resized(signum: int, frame: object) -> None:
    print('resized=40 100', flush=True)
    raise SystemExit(0)
signal.signal(signal.SIGWINCH, resized)
while True:
    time.sleep(1)
'''
        with patch.object(probe.termios, "tcsetwinsize", wraps=probe.termios.tcsetwinsize) as resize:
            status, output = self.run_probe([sys.executable, "-S", "-u", "-c", script])
        self.assertEqual(status, 1, output)
        self.assertIn("first_attempt=FAIL", output)
        self.assertIn("retry=RECOVERED: first_attempt remains FAIL", output)
        self.assertIn("exit_code=0 forced=false", output)
        self.assertNotIn("result=PASS", output)
        # The child's pre-exec initialization is in a separate address space.
        self.assertEqual(resize.call_count, 1)
        self.assertEqual(resize.call_args.args[1], (40, 100))

    def test_sigterm_ignored_escalates_to_sigkill_and_preserves_failure(self) -> None:
        script = '''
import signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
signal.signal(signal.SIGWINCH, signal.SIG_IGN)
print('ready initial=24 80', flush=True)
while True:
    time.sleep(1)
'''
        with patch.object(probe.os, "waitpid", wraps=os.waitpid) as waitpid:
            status, output = self.run_probe([sys.executable, "-S", "-u", "-c", script], resize_timeout=0.05)
        self.assertEqual(status, 1, output)
        self.assertIn("cleanup signal=SIGTERM", output)
        self.assertIn("cleanup signal=SIGKILL", output)
        self.assertIn(f"exit_code={-signal.SIGKILL} forced=true", output)
        self.assertIn("result=FAIL: guest PTY did not confirm resize", output)
        self.assertTrue(all(args.args[1] == os.WNOHANG for args in waitpid.call_args_list))

    def test_readiness_failure_never_sends_resize(self) -> None:
        with patch.object(probe.termios, "tcsetwinsize", wraps=probe.termios.tcsetwinsize) as resize:
            status, output = self.run_probe(["/bin/sh", "-c", "echo not-ready; exit 3"])
        self.assertEqual(status, 1, output)
        resize.assert_not_called()
        self.assertIn("PTY did not arm resize handling", output)
        self.assertIn("exit_code=3", output)
        self.assertNotIn("retry signal=", output)

    def test_missing_executable_is_reported_and_reaped(self) -> None:
        status, output = self.run_probe(["/nonexistent/krun-pty-probe-test"])
        self.assertEqual(status, 1, output)
        self.assertIn("exec failed:", output)
        self.assertIn("exit_code=127", output)

    def test_nonzero_exit_after_resize_still_fails(self) -> None:
        script = probe.STARTUP_GUEST_SCRIPT.replace("        exit 0", "        exit 7")
        status, output = self.run_probe(["/bin/sh", "-c", script], resize_timeout=2.0)
        self.assertEqual(status, 1, output)
        self.assertIn("first_attempt=PASS", output)
        self.assertIn("exit_code=7", output)
        self.assertIn("result=FAIL", output)

    def test_wrong_size_marker_does_not_pass(self) -> None:
        script = probe.STARTUP_GUEST_SCRIPT.replace("printf 'resized=%s", "printf 'resized=0%s")
        status, output = self.run_probe(["/bin/sh", "-c", script], resize_timeout=2.0)
        self.assertEqual(status, 1, output)
        self.assertIn("guest resized=040 100", output)
        self.assertIn("first_attempt=FAIL", output)
        self.assertIn("exit_code=0 forced=false", output)

    def test_cleanup_error_does_not_replace_readiness_failure(self) -> None:
        cleanup = probe.cleanup_child

        def fail_after_reaping(pid: int, output: probe.PTYOutput, **timeouts: float) -> tuple[int | None, bool]:
            cleanup(pid, output, **timeouts)
            raise RuntimeError("simulated cleanup failure")

        with patch.object(probe, "cleanup_child", side_effect=fail_after_reaping):
            status, output = self.run_probe(["/bin/sh", "-c", "exit 3"])
        self.assertEqual(status, 1, output)
        self.assertIn("cleanup error: simulated cleanup failure", output)
        self.assertIn("result=FAIL: PTY did not arm resize handling", output)

    def test_cleanup_drains_output_before_waiting_for_exit(self) -> None:
        script = probe.STARTUP_GUEST_SCRIPT.replace(
            "        exit 0",
            "        dd if=/dev/zero bs=4096 count=32 2>/dev/null | tr '\\000' 'x'; printf '\\n'\n        exit 0",
        )
        status, output = self.run_probe(["/bin/sh", "-c", script], resize_timeout=2.0)
        self.assertEqual(status, 0, output[-2000:])
        self.assertIn("exit_code=0 forced=false", output)


class PTYOutputTests(unittest.TestCase):
    def test_partial_lines_are_not_ready_until_newline(self) -> None:
        reader = probe.PTYOutput(123)
        with (
            patch.object(probe.select, "select", return_value=([123], [], [])),
            patch.object(probe.os, "read", side_effect=[b"ready initial=24", b" 80\r\nresized=40 1", b"00\r\n"]),
            patch.object(probe, "report"),
        ):
            self.assertEqual(reader.read(0), [])
            self.assertEqual(reader.read(0), ["ready initial=24 80"])
            self.assertEqual(reader.read(0), ["resized=40 100"])

    def test_eof_does_not_accept_unterminated_success(self) -> None:
        reader = probe.PTYOutput(123)
        with (
            patch.object(probe.select, "select", return_value=([123], [], [])),
            patch.object(probe.os, "read", side_effect=[b"resized=40 100", b""]),
            patch.object(probe, "report"),
        ):
            self.assertFalse(reader.wait_for(lambda line: line == "resized=40 100", 0.5))
            self.assertTrue(reader.eof)

    def test_eio_is_eof_but_other_read_errors_propagate(self) -> None:
        for code in (errno.EIO, errno.EBADF):
            with (
                self.subTest(errno=code),
                patch.object(probe.select, "select", return_value=([123], [], [])),
                patch.object(probe.os, "read", side_effect=OSError(code, "test")),
            ):
                reader = probe.PTYOutput(123)
                if code == errno.EIO:
                    self.assertEqual(reader.read(0), [])
                    self.assertTrue(reader.eof)
                else:
                    with self.assertRaises(OSError):
                        reader.read(0)

    def test_cleanup_stays_bounded_when_exit_is_never_confirmed(self) -> None:
        with (
            patch.object(probe, "wait_for_exit", return_value=None) as wait,
            patch.object(probe.os, "kill") as kill,
            patch.object(probe, "report"),
        ):
            status, forced = probe.cleanup_child(123, probe.PTYOutput(456))
        self.assertIsNone(status)
        self.assertTrue(forced)
        self.assertEqual(kill.call_args_list, [call(123, signal.SIGTERM), call(123, signal.SIGKILL)])
        self.assertEqual([item.args[2] for item in wait.call_args_list], [5.0, 1.0, 2.0])

    def test_cleanup_read_error_does_not_prevent_reaping(self) -> None:
        reader = probe.PTYOutput(123)
        with (
            patch.object(probe.os, "waitpid", side_effect=[(0, 0), (456, 0)]),
            patch.object(reader, "read", side_effect=OSError(errno.EBADF, "test")),
            patch.object(probe, "report"),
        ):
            self.assertEqual(probe.wait_for_exit(456, reader, 1.0), 0)
            self.assertTrue(reader.eof)


class PTYCompatibilityTests(unittest.TestCase):
    def run_compatibility(
        self, command: list[str], *, setup_timeout: float = 1.0, resize_timeout: float = 1.0
    ) -> tuple[int, str]:
        output = io.StringIO()
        with redirect_stdout(output):
            status = probe.run_probe(
                command,
                ready_timeout=1.0,
                setup_timeout=setup_timeout,
                setup_interval=0.1,
                resize_timeout=resize_timeout,
                exit_timeout=0.1,
                term_timeout=0.1,
                kill_timeout=1.0,
            )
        return status, output.getvalue()

    def test_real_pty_setup_then_three_sizes_without_retry(self) -> None:
        with patch.object(probe.termios, "tcsetwinsize", wraps=probe.termios.tcsetwinsize) as resize:
            status, output = self.run_compatibility(["/bin/sh", "-c", probe.COMPATIBILITY_GUEST_SCRIPT])
        self.assertEqual(status, 0, output)
        self.assertIn("probe mode=compatibility", output)
        self.assertIn("setup=PASS", output)
        for index, size in enumerate(probe.MEASURED_SIZES, start=1):
            self.assertIn(f"measured[{index}]=PASS size={size} retry=NOT_ALLOWED", output)
            self.assertIn(f"guest winch size={size[0]} {size[1]}", output)
            self.assertIn(f"guest sample size={size[0]} {size[1]}", output)
        self.assertEqual([c.args[1] for c in resize.call_args_list], [probe.SETUP_SIZE, *probe.MEASURED_SIZES])
        self.assertIn("exit_code=0 forced=false", output)

    def test_delayed_startup_listener_may_recover_only_during_setup(self) -> None:
        script = '''
import signal, termios, time
signal.signal(signal.SIGWINCH, signal.SIG_IGN)
print('ready initial=24 80', flush=True)
while termios.tcgetwinsize(0) != (30, 90):
    time.sleep(0.005)
time.sleep(0.05)
def resized(signum: int, frame: object) -> None:
    rows, cols = termios.tcgetwinsize(0)
    print(f'winch size={rows} {cols}', flush=True)
    print(f'sample size={rows} {cols}', flush=True)
    print(f'confirmed={rows} {cols}', flush=True)
    if (rows, cols) == (24, 80):
        raise SystemExit(0)
signal.signal(signal.SIGWINCH, resized)
while True:
    time.sleep(1)
'''
        with patch.object(probe.termios, "tcsetwinsize", wraps=probe.termios.tcsetwinsize) as resize:
            status, output = self.run_compatibility([sys.executable, "-S", "-u", "-c", script])
        self.assertEqual(status, 0, output)
        self.assertIn("setup resend=SIGWINCH", output)
        self.assertIn("measured[3]=PASS", output)
        self.assertEqual(resize.call_count, 4, output)
        after_setup = output.split("setup=PASS", 1)[1]
        self.assertNotIn("resend=SIGWINCH", after_setup)

    def test_setup_geometry_without_signal_confirmation_fails(self) -> None:
        script = probe.COMPATIBILITY_GUEST_SCRIPT.replace("trap on_winch WINCH", "trap '' WINCH")
        with patch.object(probe.termios, "tcsetwinsize", wraps=probe.termios.tcsetwinsize) as resize:
            status, output = self.run_compatibility(["/bin/sh", "-c", script], setup_timeout=0.4)
        self.assertEqual(status, 1, output)
        self.assertIn("guest sample size=30 90", output)
        self.assertIn("setup did not confirm a resize round trip", output)
        self.assertNotIn("measured[1]", output)
        self.assertEqual(resize.call_count, 1)

    def test_measured_geometry_without_winch_fails_without_retry(self) -> None:
        script = probe.COMPATIBILITY_GUEST_SCRIPT.replace(
            '        winch_size=$size', '        [ "$size" = "40 100" ] || winch_size=$size'
        )
        with patch.object(probe.termios, "tcsetwinsize", wraps=probe.termios.tcsetwinsize) as resize:
            status, output = self.run_compatibility(["/bin/sh", "-c", script], resize_timeout=0.4)
        self.assertEqual(status, 1, output)
        self.assertIn("guest sample size=40 100", output)
        self.assertIn("measured[1] did not confirm 40x100; retries are disabled", output)
        self.assertNotIn("measured[2]", output)
        self.assertEqual([c.args[1] for c in resize.call_args_list], [probe.SETUP_SIZE, probe.MEASURED_SIZES[0]])
        self.assertNotIn("resend=SIGWINCH", output.split("setup=PASS", 1)[1])

    def test_empty_or_wrong_readiness_does_not_request_setup(self) -> None:
        for readiness in ("ready initial= pid=23", "ready initial=0 0", "ready initial=24 800"):
            with (
                self.subTest(readiness=readiness),
                patch.object(probe.termios, "tcsetwinsize", wraps=probe.termios.tcsetwinsize) as resize,
            ):
                status, output = self.run_compatibility(["/bin/sh", "-c", f"echo '{readiness}'"])
                self.assertEqual(status, 1, output)
                self.assertIn("required initial geometry", output)
                resize.assert_not_called()

    def test_stale_confirmation_cannot_pass_measured_step(self) -> None:
        script = probe.COMPATIBILITY_GUEST_SCRIPT.replace(
            "printf 'confirmed=%s\\n' \"$size\"", "printf 'confirmed=%s\\n' '30 90'"
        )
        status, output = self.run_compatibility(["/bin/sh", "-c", script], resize_timeout=0.4)
        self.assertEqual(status, 1, output)
        self.assertIn("setup=PASS", output)
        self.assertIn("measured[1] did not confirm", output)

    def test_nonzero_exit_cannot_pass_after_all_sizes(self) -> None:
        script = probe.COMPATIBILITY_GUEST_SCRIPT.replace('|| exit 0', '|| exit 7')
        status, output = self.run_compatibility(["/bin/sh", "-c", script])
        self.assertEqual(status, 1, output)
        self.assertIn("measured[3]=PASS", output)
        self.assertIn("exit_code=7", output)
        self.assertIn("result=FAIL", output)

    def test_eof_after_setup_does_not_skip_measurements(self) -> None:
        script = probe.COMPATIBILITY_GUEST_SCRIPT.replace('            shift', '            exit 0')
        status, output = self.run_compatibility(["/bin/sh", "-c", script])
        self.assertEqual(status, 1, output)
        self.assertIn("setup=PASS", output)
        self.assertIn("result=FAIL", output)
        self.assertNotIn("measured[1]=PASS", output)

    def test_missing_initial_sample_is_retried_before_readiness(self) -> None:
        script = probe.COMPATIBILITY_GUEST_SCRIPT.replace(
            'if size=$(stty size </dev/tty 2>/dev/null); then\n        printf',
            'if [ "$i" -gt 1 ] && size=$(stty size </dev/tty 2>/dev/null); then\n        printf',
        )
        status, output = self.run_compatibility(["/bin/sh", "-c", script])
        self.assertEqual(status, 0, output)
        self.assertIn("ready initial=24 80", output)
        self.assertNotIn("ready initial= pid=", output)

    def test_invalid_mode_and_nonpositive_setup_deadline_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            probe.run_probe(["/bin/sh"], mode="unknown")
        with self.assertRaises(ValueError):
            probe.run_probe(["/bin/sh"], setup_timeout=0)

    def test_cli_defaults_to_compatibility_and_keeps_startup_explicit(self) -> None:
        for args, mode, script in (
            (["probe", "test"], "compatibility", probe.COMPATIBILITY_GUEST_SCRIPT),
            (["probe", "test", "--mode", "startup"], "startup", probe.STARTUP_GUEST_SCRIPT),
        ):
            with (
                self.subTest(mode=mode),
                patch.object(sys, "argv", args),
                patch.object(probe, "run_probe", return_value=0) as run,
            ):
                self.assertEqual(probe.main(), 0)
                run.assert_called_once_with(["container", "exec", "-i", "-t", "test", "sh", "-c", script], mode=mode)


if __name__ == "__main__":
    unittest.main()
