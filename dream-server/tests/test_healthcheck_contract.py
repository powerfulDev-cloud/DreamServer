#!/usr/bin/env python3
"""Contract tests for scripts/healthcheck.py using unittest."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import socket
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import MagicMock, patch


SCRIPT_PATH = Path(__file__).resolve().parent.parent / "scripts" / "healthcheck.py"
SPEC = importlib.util.spec_from_file_location("dream_healthcheck", SCRIPT_PATH)
healthcheck = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = healthcheck
SPEC.loader.exec_module(healthcheck)


class ParseHelpersTest(unittest.TestCase):
    def test_parse_target_accepts_http_and_tcp_forms(self) -> None:
        self.assertEqual(healthcheck._parse_target("http://localhost:3000/health"), ("http", "http://localhost:3000/health"))
        self.assertEqual(healthcheck._parse_target("tcp://localhost:5432"), ("tcp", "localhost:5432"))
        self.assertEqual(healthcheck._parse_target("localhost:6333"), ("tcp", "localhost:6333"))

    def test_parse_target_rejects_invalid_target(self) -> None:
        with self.assertRaises(ValueError):
            healthcheck._parse_target("localhost")

    def test_parse_host_port_validates_shape(self) -> None:
        self.assertEqual(healthcheck._parse_host_port("localhost:8080"), ("localhost", 8080))
        with self.assertRaisesRegex(ValueError, "host is empty"):
            healthcheck._parse_host_port(":8080")
        with self.assertRaisesRegex(ValueError, "port must be an integer"):
            healthcheck._parse_host_port("localhost:abc")
        with self.assertRaisesRegex(ValueError, "port out of range"):
            healthcheck._parse_host_port("localhost:70000")

    def test_parse_expected_status_supports_ranges_and_classes(self) -> None:
        parsed = healthcheck._parse_expected_status("200,204,3xx,401-403")
        self.assertIn(200, parsed)
        self.assertIn(204, parsed)
        self.assertIn(302, parsed)
        self.assertIn(401, parsed)
        self.assertIn(403, parsed)
        self.assertNotIn(500, parsed)


class TcpChecksTest(unittest.TestCase):
    @patch.object(healthcheck.socket, "create_connection")
    def test_check_tcp_success(self, mock_create: MagicMock) -> None:
        mock_socket = MagicMock()
        mock_create.return_value.__enter__.return_value = mock_socket
        ok, detail = healthcheck.check_tcp("localhost", 5432, 1.0)
        self.assertTrue(ok)
        self.assertEqual(detail, "tcp connect ok")

    @patch.object(healthcheck.socket, "create_connection", side_effect=socket.timeout)
    def test_check_tcp_timeout(self, _mock_create: MagicMock) -> None:
        ok, detail = healthcheck.check_tcp("localhost", 5432, 1.0)
        self.assertFalse(ok)
        self.assertEqual(detail, "tcp connect timeout")

    @patch.object(healthcheck.socket, "create_connection", side_effect=ConnectionRefusedError)
    def test_check_tcp_refused(self, _mock_create: MagicMock) -> None:
        ok, detail = healthcheck.check_tcp("localhost", 5432, 1.0)
        self.assertFalse(ok)
        self.assertEqual(detail, "tcp connection refused")


class HttpChecksTest(unittest.TestCase):
    @patch.object(healthcheck, "_http_request")
    def test_check_http_success_with_head(self, mock_request: MagicMock) -> None:
        response = MagicMock()
        response.status = 200
        mock_request.return_value.__enter__.return_value = response

        ok, detail, status = healthcheck.check_http(
            "http://localhost:8080/health",
            method="HEAD",
            timeout=1.0,
            allowed_status={200},
            body_regex=None,
            user_agent="test-agent",
        )

        self.assertTrue(ok)
        self.assertEqual(detail, "http HEAD: ok")
        self.assertEqual(status, 200)

    @patch.object(healthcheck, "_http_request")
    def test_check_http_unexpected_status_fails(self, mock_request: MagicMock) -> None:
        response = MagicMock()
        response.status = 503
        mock_request.return_value.__enter__.return_value = response

        ok, detail, status = healthcheck.check_http(
            "http://localhost:8080/health",
            method="GET",
            timeout=1.0,
            allowed_status={200},
            body_regex=None,
            user_agent="test-agent",
        )

        self.assertFalse(ok)
        self.assertIn("unexpected status 503", detail)
        self.assertEqual(status, 503)

    @patch.object(healthcheck, "_http_request")
    def test_check_http_body_regex_forces_get(self, mock_request: MagicMock) -> None:
        response = MagicMock()
        response.status = 200
        response.read.return_value = b"service ready"
        mock_request.return_value.__enter__.return_value = response

        ok, detail, status = healthcheck.check_http(
            "http://localhost:8080/health",
            method="HEAD",
            timeout=1.0,
            allowed_status={200},
            body_regex=healthcheck.re.compile("ready"),
            user_agent="test-agent",
        )

        self.assertTrue(ok)
        self.assertEqual(detail, "http GET: ok")
        self.assertEqual(status, 200)

    @patch.object(healthcheck, "_http_request")
    def test_check_http_head_falls_back_to_get_on_405(self, mock_request: MagicMock) -> None:
        good_response = MagicMock()
        good_response.status = 200
        mock_request.side_effect = [
            urllib.error.HTTPError("http://localhost", 405, "not allowed", hdrs=None, fp=None),
            contextlib.nullcontext(good_response),
        ]

        ok, detail, status = healthcheck.check_http(
            "http://localhost:8080/health",
            method="HEAD",
            timeout=1.0,
            allowed_status={200},
            body_regex=None,
            user_agent="test-agent",
        )

        self.assertTrue(ok)
        self.assertEqual(detail, "http GET: ok")
        self.assertEqual(status, 200)

    @patch.object(healthcheck, "_http_request")
    def test_check_http_allowed_error_status_can_pass(self, mock_request: MagicMock) -> None:
        mock_request.side_effect = urllib.error.HTTPError("http://localhost", 401, "unauthorized", hdrs=None, fp=None)

        ok, detail, status = healthcheck.check_http(
            "http://localhost:8080/health",
            method="GET",
            timeout=1.0,
            allowed_status={401},
            body_regex=None,
            user_agent="test-agent",
        )

        self.assertTrue(ok)
        self.assertIn("error status allowed", detail)
        self.assertEqual(status, 401)

    @patch.object(healthcheck, "_http_request")
    def test_check_http_body_regex_mismatch_fails(self, mock_request: MagicMock) -> None:
        response = MagicMock()
        response.status = 200
        response.read.return_value = b"service booting"
        mock_request.return_value.__enter__.return_value = response

        ok, detail, status = healthcheck.check_http(
            "http://localhost:8080/health",
            method="GET",
            timeout=1.0,
            allowed_status={200},
            body_regex=healthcheck.re.compile("ready"),
            user_agent="test-agent",
        )

        self.assertFalse(ok)
        self.assertIn("body regex did not match", detail)
        self.assertEqual(status, 200)


class RetryAndCliTest(unittest.TestCase):
    def test_with_retries_stops_after_success(self) -> None:
        calls: list[int] = []

        def flaky() -> tuple[bool, str]:
            calls.append(len(calls))
            return (len(calls) >= 2, "ok" if len(calls) >= 2 else "retry")

        result = healthcheck.with_retries(flaky, retries=3, base_sleep=0)
        self.assertEqual(result, (True, "ok"))
        self.assertEqual(len(calls), 2)

    def test_main_returns_usage_error_for_invalid_target(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = healthcheck.main(["not-a-target", "--json"])
        payload = json.loads(stdout.getvalue())
        self.assertEqual(rc, 2)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["kind"], "unknown")

    @patch.object(healthcheck, "check_tcp", return_value=(True, "tcp connect ok"))
    def test_main_tcp_success_json(self, _mock_tcp: MagicMock) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = healthcheck.main(["tcp://localhost:5432", "--json", "--timeout", "1"])
        payload = json.loads(stdout.getvalue())
        self.assertEqual(rc, 0)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["kind"], "tcp")

    def test_main_rejects_bad_expect_status(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = healthcheck.main(["http://localhost:8080/health", "--expect-status", "oops"])
        self.assertEqual(rc, 2)
        self.assertIn("invalid --expect-status", stdout.getvalue())

    def test_main_rejects_bad_regex(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = healthcheck.main(["http://localhost:8080/health", "--expect-body-regex", "["])
        self.assertEqual(rc, 2)
        self.assertIn("invalid regex", stdout.getvalue())

    @patch.object(healthcheck, "check_http", return_value=(False, "http GET: unexpected status 503", 503))
    def test_main_http_failure_plaintext(self, _mock_http: MagicMock) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = healthcheck.main(["http://localhost:8080/health", "--method", "GET", "--retries", "0"])
        self.assertEqual(rc, 1)
        self.assertIn("[FAIL] http http://localhost:8080/health status=503", stdout.getvalue())


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
