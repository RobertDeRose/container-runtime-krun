"""Failure evidence must locate the stalled phase without changing stream framing."""

import contextlib
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "benchmark_network_streams.py"
SPEC = importlib.util.spec_from_file_location("stream_failure_bench", SCRIPT)
assert SPEC and SPEC.loader
bench = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bench
SPEC.loader.exec_module(bench)


class GuestFailureTests(unittest.TestCase):
    def source_namespace(self):
        # Load the exact embedded program's definitions without launching threads.
        definitions = bench.GUEST_SOURCE.split("\nthreads = ", 1)[0]
        namespace = {}
        with mock.patch.object(sys, "argv", ["source", "127.0.0.1", "1234", "1", "1", "1024"]):
            exec(compile(definitions, "<guest-source-definitions>", "exec"), namespace)
        namespace["barrier"] = mock.Mock()
        namespace["state"].update(start_ns=0, deadline_ns=2)
        return namespace

    def socket(self):
        sock = mock.MagicMock(spec=bench.socket.socket)
        sock.__enter__.return_value = sock
        sock.__exit__.return_value = False
        sock.getsockname.return_value = ("192.0.2.2", 50001)
        sock.getpeername.return_value = ("192.0.2.1", 50002)
        sock.getsockopt.return_value = b"\x01\x02"
        return sock

    def run_worker(self, namespace, sock, times):
        with mock.patch.object(bench.socket, "create_connection", return_value=sock):
            with mock.patch.object(bench.time, "perf_counter_ns", side_effect=times):
                with mock.patch.object(pathlib.Path, "read_text", return_value="proc snapshot"):
                    namespace["worker"](7)
        self.assertEqual(len(namespace["failures"]), 1)
        return namespace["failures"][0]

    def test_send_timeout_reports_only_completed_send_calls(self):
        namespace = self.source_namespace()
        sock = self.socket()
        sock.sendall.side_effect = [None, TimeoutError("send stalled")]
        record = self.run_worker(namespace, sock, [0, 1, 3])
        self.assertEqual(record["stream_id"], 7)
        self.assertEqual(record["phase"], "send_payload")
        self.assertEqual(record["completed_send_bytes"], 1024)
        self.assertEqual(record["local_address"], ("192.0.2.2", 50001))
        self.assertEqual(record["peer_address"], ("192.0.2.1", 50002))
        self.assertEqual(set(namespace["failure_network"]), {"tcp", "snmp", "netstat"})
        namespace["barrier"].abort.assert_called_once()

    def test_trailer_timeout_is_not_labelled_payload_timeout(self):
        namespace = self.source_namespace()
        sock = self.socket()
        sock.sendall.side_effect = TimeoutError("trailer stalled")
        record = self.run_worker(namespace, sock, [3, 3, 4])
        self.assertEqual(record["phase"], "send_trailer")
        self.assertEqual(record["completed_send_bytes"], 0)
        self.assertTrue(sock.sendall.call_args.args[0].startswith(bench.STREAM_TRAILER_MAGIC))

    def test_ack_timeout_collects_tcp_info_before_socket_close(self):
        namespace = self.source_namespace()
        sock = self.socket()
        sock.recv.side_effect = TimeoutError("ack stalled")
        closed = False

        def tcp_info(*args):
            self.assertFalse(closed)
            return b"\x01\x02"

        def close(*args):
            nonlocal closed
            closed = True
            return False

        sock.getsockopt.side_effect = tcp_info
        sock.__exit__.side_effect = close
        # TCP_INFO exists in the Linux guest; provide it for macOS test hosts too.
        with mock.patch.object(bench.socket, "TCP_INFO", 11, create=True):
            record = self.run_worker(namespace, sock, [3, 3, 4])
        self.assertEqual(record["phase"], "receive_ack")
        self.assertEqual(record["tcp_info_hex"], "0102")
        self.assertTrue(closed)

    def test_tcp_snapshot_errors_preserve_the_original_operation_error(self):
        namespace = self.source_namespace()
        sock = self.socket()
        sock.recv.side_effect = TimeoutError("ack stalled")
        sock.getsockname.side_effect = OSError("no endpoint")
        sock.getsockopt.side_effect = OSError("no TCP info")
        with mock.patch.object(bench.socket, "TCP_INFO", 11, create=True):
            record = self.run_worker(namespace, sock, [3, 3, 4])
        self.assertIn("ack stalled", record["error"])
        self.assertIn("no endpoint", record["local_address"]["error"])
        self.assertIn("no TCP info", record["tcp_info_hex"]["error"])
        self.assertEqual(namespace["errors"], ["TimeoutError('ack stalled')"])

    def test_connect_failure_is_recorded_once_and_proc_is_captured_once(self):
        namespace = self.source_namespace()
        with mock.patch.object(bench.socket, "create_connection", side_effect=ConnectionRefusedError("refused")):
            with mock.patch.object(pathlib.Path, "read_text", return_value="proc snapshot") as read:
                namespace["worker"](0)
                namespace["worker"](1)
        self.assertEqual(read.call_count, 3)
        self.assertEqual(len(namespace["failures"]), 2)
        self.assertTrue(all(row["phase"] == "connect" for row in namespace["failures"]))
        self.assertNotIn("tcp_info_hex", namespace["failures"][0])

    def test_complete_guest_program_emits_one_machine_readable_failure_record(self):
        stderr = io.StringIO()
        with mock.patch.object(sys, "argv", ["source", "127.0.0.1", "1234", "2", "1", "1024"]):
            with mock.patch.object(bench.socket, "create_connection", side_effect=ConnectionRefusedError("refused")):
                with mock.patch.object(pathlib.Path, "read_text", side_effect=OSError("unavailable")):
                    with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
                        exec(compile(bench.GUEST_SOURCE, "<guest-source>", "exec"), {})
        lines = stderr.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("KRUN_STREAM_FAILURE "))
        record = json.loads(lines[0].removeprefix("KRUN_STREAM_FAILURE "))
        self.assertEqual([row["stream_id"] for row in record["streams"]], [0, 1])
        self.assertTrue(all(row["elapsed_seconds"] is None for row in record["streams"]))
        self.assertIn("ERROR:", record["network_at_first_failure"]["tcp"])


class HostFailureTests(unittest.TestCase):
    def test_source_exception_is_not_replaced_by_sink_cleanup_exception(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "sink.json"
            original = RuntimeError("guest source timed out")
            with self.assertRaises(RuntimeError) as caught, contextlib.redirect_stderr(io.StringIO()):
                with bench.SinkServer("127.0.0.1", evidence_path=path) as sink:
                    sink.errors.append("ConnectionResetError: peer reset")
                    raise original
            self.assertIs(caught.exception, original)
            evidence = json.loads(path.read_text())
            self.assertIn("guest source timed out", evidence["primary_error"])
            self.assertIn("peer reset", evidence["close_error"])
            self.assertEqual(evidence["unfinished_workers"], 0)

    def test_sink_error_still_fails_an_otherwise_successful_context(self):
        with self.assertRaisesRegex(RuntimeError, "host sink failure"):
            with bench.SinkServer("127.0.0.1") as sink:
                sink.errors.append("unexpected EOF")

    def test_evidence_write_failure_does_not_replace_source_error(self):
        original = RuntimeError("source timed out")
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "sink.json"
            with mock.patch.object(pathlib.Path, "write_text", side_effect=OSError("disk full")):
                with self.assertRaises(RuntimeError) as caught, contextlib.redirect_stderr(io.StringIO()) as stderr:
                    with bench.SinkServer("127.0.0.1", evidence_path=path):
                        raise original
            self.assertIs(caught.exception, original)
            self.assertIn("disk full", stderr.getvalue())

    def test_sink_receive_failure_records_wire_progress(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "sink.json"
            with self.assertRaisesRegex(RuntimeError, "host sink failure"):
                with bench.SinkServer("127.0.0.1", evidence_path=path) as sink:
                    with bench.socket.create_connection(("127.0.0.1", sink.port), timeout=2) as source:
                        source.sendall(b"s" * 1024)
            record = json.loads(path.read_text())["connections"][0]
            self.assertEqual(record["wire_bytes"], 1024)
            self.assertEqual(record["phase"], "receive_payload")
            self.assertFalse(record["ack_sent"])
            self.assertIn("source closed before stream trailer", record["error"])

    def test_exact_guest_program_round_trips_without_success_diagnostic_output(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "sink.json"
            with bench.SinkServer("127.0.0.1", evidence_path=path) as sink:
                result = subprocess.run(
                    [sys.executable, "-c", bench.GUEST_SOURCE, "127.0.0.1", str(sink.port), "2", "0.05", "16384"],
                    capture_output=True, text=True, timeout=10, check=True,
                )
            measured = json.loads(result.stdout)
            evidence = json.loads(path.read_text())
            self.assertEqual(result.stderr, "")
            self.assertEqual(measured["streams"], 2)
            self.assertEqual(len(evidence["connections"]), 2)
            self.assertFalse(evidence["errors"])
            self.assertEqual(evidence["unfinished_workers"], 0)
            self.assertTrue(all(row["ack_sent"] for row in evidence["connections"]))
            self.assertEqual(sum(row["received_payload_bytes"] for row in evidence["connections"]), measured["bytes"])
            self.assertGreater(measured["bytes"], 0)


if __name__ == "__main__":
    unittest.main()
