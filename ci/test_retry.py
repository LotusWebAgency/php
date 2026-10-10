"""ci/retry.sh against a stub command: what it retries, what it must not, and
that the output and exit code come through untouched."""
import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RETRY = os.path.join(HERE, "retry.sh")

# Plays STUB_PLAN's entries ("|"-separated) in order, one per call, then repeats
# the last: "ok" prints "done" on stdout and exits 0; anything else is written
# to stderr and the call exits STUB_RC.
STUB = r"""#!/usr/bin/env bash
n=$(( $(cat "$STUB_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STUB_COUNT"
IFS='|' read -ra plan <<<"$STUB_PLAN"
i=$(( n - 1 )); [ "$i" -lt "${#plan[@]}" ] || i=$(( ${#plan[@]} - 1 ))
step="${plan[$i]}"
if [ "$step" = ok ]; then echo done; exit 0; fi
echo "out-$n"
if [ "${STUB_STDOUT_ONLY:-0}" = 1 ]; then echo "$step"; else echo "$step" >&2; fi
exit "${STUB_RC:-1}"
"""


class RetryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.stub = os.path.join(self.tmp.name, "stub.sh")
        with open(self.stub, "w") as f:
            f.write(STUB)
        os.chmod(self.stub, 0o755)
        self.count = os.path.join(self.tmp.name, "count")
        self.sleeps = os.path.join(self.tmp.name, "sleeps")
        sleep = os.path.join(self.tmp.name, "sleep")
        with open(sleep, "w") as f:
            f.write('#!/usr/bin/env bash\necho "$1" >> "$STUB_SLEEPS"\n')
        os.chmod(sleep, 0o755)

    def calls(self):
        if not os.path.exists(self.count):
            return 0
        with open(self.count) as f:
            return int(f.read())

    def reset(self):
        for path in (self.count, self.sleeps):
            if os.path.exists(path):
                os.remove(path)

    def run_retry(self, plan, delays="0 0 0 0", attempts=None, rc=1,
                  kind=None, stdout_only=False):
        env = dict(os.environ, STUB_PLAN=plan, STUB_COUNT=self.count,
                   STUB_RC=str(rc), STUB_SLEEPS=self.sleeps,
                   STUB_STDOUT_ONLY=str(int(stdout_only)),
                   PATH=self.tmp.name + os.pathsep + os.environ["PATH"])
        for name in ("RETRY_KIND", "RETRY_DELAYS", "RETRY_ATTEMPTS"):
            env.pop(name, None)
        if delays is not None:
            env["RETRY_DELAYS"] = delays
        if attempts is not None:
            env["RETRY_ATTEMPTS"] = str(attempts)
        if kind is not None:
            env["RETRY_KIND"] = kind
        proc = subprocess.run([RETRY, self.stub], env=env,
                              capture_output=True, text=True, timeout=60)
        return proc, self.calls()

    def test_success_first_try_is_not_retried(self):
        proc, calls = self.run_retry("ok")
        self.assertEqual((proc.returncode, calls), (0, 1))
        self.assertEqual(proc.stdout, "done\n")
        self.assertEqual(proc.stderr, "")

    def test_429_then_success(self):
        proc, calls = self.run_retry("429 Too Many Requests|429 Too Many Requests|ok")
        self.assertEqual((proc.returncode, calls), (0, 3))
        self.assertIn("retrying in", proc.stderr)
        self.assertTrue(proc.stdout.endswith("done\n"))

    def test_non_transient_failure_exits_at_once_with_its_code(self):
        proc, calls = self.run_retry("denied: requested access to the resource is denied", rc=3)
        self.assertEqual((proc.returncode, calls), (3, 1))
        self.assertIn("denied", proc.stderr)
        self.assertNotIn("retry.sh", proc.stderr)

    def test_gives_up_after_the_last_delay_with_the_commands_code(self):
        proc, calls = self.run_retry("toomanyrequests: rate limit", delays="0 0", rc=7)
        self.assertEqual((proc.returncode, calls), (7, 3))
        self.assertIn("giving up after 3 attempts", proc.stderr)

    def test_default_is_five_attempts(self):
        # Four delays -> five attempts; the delays are zeroed so the test does not wait.
        proc, calls = self.run_retry("429 Too Many Requests", delays="0 0 0 0")
        self.assertEqual((proc.returncode, calls), (1, 5))

    def test_attempts_cap(self):
        proc, calls = self.run_retry("429 Too Many Requests", attempts=2)
        self.assertEqual((proc.returncode, calls), (1, 2))

    def test_attempts_beyond_delays_repeat_the_last_delay(self):
        proc, calls = self.run_retry("429 Too Many Requests", delays="0", attempts=4)
        self.assertEqual((proc.returncode, calls), (1, 4))

    def test_stdout_and_stderr_stay_separate(self):
        proc, _ = self.run_retry("ok")
        self.assertNotIn("retry.sh", proc.stdout)
        self.reset()
        proc, _ = self.run_retry("denied", rc=2)
        self.assertEqual(proc.stdout, "out-1\n")
        self.assertEqual(proc.stderr, "denied\n")

    def test_arguments_reach_the_command(self):
        arg_stub = os.path.join(self.tmp.name, "args.sh")
        with open(arg_stub, "w") as f:
            f.write('#!/usr/bin/env bash\nprintf "%s|" "$@"\n')
        os.chmod(arg_stub, 0o755)
        proc = subprocess.run([RETRY, arg_stub, "a b", "--c=d", ""], capture_output=True, text=True)
        self.assertEqual(proc.stdout, "a b|--c=d||")

    def test_unknown_command_fails_at_once(self):
        proc = subprocess.run([RETRY, os.path.join(self.tmp.name, "nope")], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 127)

    def test_no_arguments_is_a_usage_error(self):
        proc = subprocess.run([RETRY], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 2)

    def test_platform_digest_rides_out_a_429(self):
        # A fake `docker` that 429s twice, then serves an index: platform-digest.sh
        # must still print exactly the platform manifest digest on stdout.
        fake = os.path.join(self.tmp.name, "docker")
        with open(fake, "w") as f:
            f.write(
                '#!/usr/bin/env bash\n'
                'n=$(( $(cat "$STUB_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_COUNT"\n'
                'if [ "$n" -lt 3 ]; then echo "ERROR: unexpected status from HEAD request to https://x/v2/y: '
                '429 Too Many Requests" >&2; exit 1; fi\n'
                'echo \'{"manifests":[{"digest":"sha256:aaa","platform":{"os":"linux","architecture":"amd64"}},'
                '{"digest":"sha256:bbb","platform":{"os":"unknown","architecture":"unknown"}}]}\'\n'
            )
        os.chmod(fake, 0o755)
        env = dict(os.environ, PATH=self.tmp.name + os.pathsep + os.environ["PATH"],
                   STUB_COUNT=self.count, RETRY_DELAYS="0 0 0 0")
        proc = subprocess.run([os.path.join(HERE, "platform-digest.sh"), "docker.io/x/y@sha256:1", "amd64"],
                              env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual((proc.returncode, proc.stdout, self.calls()), (0, "sha256:aaa\n", 3))

    def test_what_counts_as_transient(self):
        retried = [
            "ERROR: target php-7_1-ext-builder: failed to solve: unexpected status from HEAD request to "
            "https://registry-1.docker.io/v2/library/gcc/manifests/sha256:"
            "ef558a40d1f13115293feee01526dbdb9aaad7c9c5a00da05f471ce042e855c1: 429 Too Many Requests",
            "ERROR: unexpected status from HEAD request to https://registry-1.docker.io/v2/ns/php/manifests/sha256:aa: 429 Too Many Requests",
            "Error response from daemon: toomanyrequests: You have reached your pull rate limit.",
            "failed to copy: httpReadSeeker: unexpected status code https://x/blobs/sha256:aa 503 Service Unavailable",
            "unexpected status from PUT request to https://registry-1.docker.io/v2/ns/php/blobs/uploads/x: 502 Bad Gateway",
            "error: unexpected status code 500",
            "POST https://rekor.sigstore.dev/api/v1/log/entries: [POST /api/v1/log/entries][503] createLogEntryServiceUnavailable",
            'Get "https://registry-1.docker.io/v2/": net/http: TLS handshake timeout',
            "read tcp 10.0.0.1:443->10.0.0.2:5000: read: connection reset by peer",
            "dial tcp 1.2.3.4:443: i/o timeout",
            'Post "https://x/v2/y": unexpected EOF',
            "dial tcp: lookup registry-1.docker.io: Temporary failure in name resolution",
            "unknown blob",
            "ERROR: failed to push ghcr.io/lotuswebagency/php/release:x: unknown blob",
        ]
        not_retried = [
            "unexpected status from HEAD request to https://registry-1.docker.io/v2/ns/php/manifests/sha256:"
            "500a0b1c2d3e4f5061728394a5b6c7d8e9f00112233445566778899aabbccddee: 404 Not Found",
            "unexpected status from GET request to https://x/token: 401 Unauthorized",
            "denied: requested access to the resource is denied",
            "manifest unknown",
            "Error response from daemon: blob unknown to registry",
            "/src/ext/foo/foo.c:429:5: error: unknown type name 'bar'",
            "make: *** [Makefile:503: all] Error 2",
            "FAIL: expected exactly one linux/arm64 manifest",
        ]
        for line in retried:
            with self.subTest(retried=line[:80]):
                self.reset()
                _, calls = self.run_retry(f"{line}|ok")
                self.assertEqual(calls, 2)
        for line in not_retried:
            with self.subTest(not_retried=line[:80]):
                self.reset()
                proc, calls = self.run_retry(f"{line}|ok")
                self.assertEqual((calls, proc.returncode), (1, 1))

    def test_kind_specific_patterns(self):
        positives = {
            "registry": ["too many requests", "error: unknown blob"],
            "net": [
                "Temporary failure in name resolution", "Temporary failure resolving 'deb.debian.org'",
                "Could not resolve host: ghcr.io", "Could not resolve proxy: proxy.example",
                "lookup ghcr.io: no such host", "lookup ghcr.io on 127.0.0.53:53: server misbehaving",
                "lookup ghcr.io: i/o timeout", "getaddrinfo www.example.org failed",
                "connection reset by peer", "connection refused", "connection timed out",
                "Operation timed out", "Network is unreachable", "failed to connect to host",
                "unable to connect to host", "could not to connect to host", "Couldn't connect to server",
                "TLS handshake timeout", "SSL_ERROR_SYSCALL", "unexpected EOF", "early EOF",
                "Empty reply from server", "Recv failure", "Send failure",
                "transfer closed with 42 bytes remaining", "HTTP/2 stream 3 was not closed cleanly",
                "i/o timeout", "Client.Timeout exceeded", "net/http: request canceled",
            ],
            "http": [
                *[f"curl: ({code}) download failed" for code in (6, 7, 18, 28, 35, 52, 55, 56, 92)],
                *[f"curl error {code} while downloading https://example.org" for code in
                  (6, 7, 18, 28, 35, 52, 55, 56, 92)],
                "WordPress download failed: cURL error 6: Could not resolve host: api.wordpress.org",
                "returned error: 408", "returned error: 429", "returned error: 503",
                "download failed (HTTP/1.1 408)", "download failed (HTTP/2 429)",
                "download failed (HTTP/1.1 503)", "The requested URL returned error: 503",
            ],
            "apt": ["E: Failed to fetch https://deb.debian.org/pkg 503 Service Unavailable",
                    "E: Failed to fetch https://deb.debian.org/pkg Hash Sum mismatch",
                    "Hash Sum mismatch"],
            "git": ["error: RPC failed; curl 56 receive error", "RPC failed; HTTP 429",
                    "RPC failed; HTTP 503", "The requested URL returned error: 429",
                    "The requested URL returned error: 503", "gnutls_handshake() failed"],
        }
        positives["composer"] = positives["http"]
        for kind, lines in positives.items():
            for line in lines:
                with self.subTest(kind=kind, line=line):
                    self.reset()
                    proc, calls = self.run_retry(f"{line}|ok", kind=kind)
                    self.assertEqual((proc.returncode, calls), (0, 2))
                    expected = "http" if kind == "composer" else kind
                    # WordPress host resolution is an implied net match.
                    if "WordPress" in line:
                        expected = "net"
                    self.assertIn(f"transient {expected} error", proc.stderr)

    def test_net_is_implied_by_every_kind(self):
        for kind in (None, "registry", "http", "composer", "apt", "git", "net"):
            with self.subTest(kind=kind):
                self.reset()
                proc, calls = self.run_retry("lookup ghcr.io on 127.0.0.53:53: no such host|ok", kind=kind)
                self.assertEqual((proc.returncode, calls), (0, 2))
                self.assertIn("transient net error", proc.stderr)

    def test_reported_network_errors(self):
        cases = [
            ("http", "Error: Failed to get url 'https://develop.svn.wordpress.org/trunk/src/wp-includes/theme-i18n.json': "
             "cURL error 6: Could not resolve host: develop.svn.wordpress.org.", "net"),
            ("http", "curl: (6) Could not resolve host: x", "http"),
            ("apt", "E: Failed to fetch http://deb.debian.org/debian/pool/x.deb  503  Service Unavailable", "apt"),
            ("git", "fatal: unable to access 'https://github.com/x/': Could not resolve host: github.com", "net"),
            (None, "dial tcp: lookup ghcr.io on 127.0.0.53:53: no such host", "net"),
        ]
        for kind, line, matched in cases:
            with self.subTest(kind=kind, line=line):
                self.reset()
                proc, calls = self.run_retry(f"{line}|ok", kind=kind, rc=6)
                self.assertEqual((proc.returncode, calls), (0, 2))
                self.assertIn(f"transient {matched} error", proc.stderr)

    def test_kind_specific_negative_patterns(self):
        negatives = {
            "registry": ["curl: (6) download failed", "Hash Sum mismatch", "RPC failed; HTTP 503"],
            "net": ["too many requests", "curl: (6) download failed", "Hash Sum mismatch",
                    "returned error: 503", "RPC failed; HTTP 503"],
            "http": ["too many requests", "Hash Sum mismatch", "RPC failed; HTTP 503",
                     "curl error 60 while downloading https://example.org"],
            "composer": ["too many requests", "Hash Sum mismatch", "RPC failed; HTTP 503"],
            "apt": ["too many requests", "curl: (6) download failed", "RPC failed; HTTP 503"],
            "git": ["too many requests", "curl: (6) download failed", "Hash Sum mismatch",
                    "The requested URL returned error: 408"],
        }
        for kind, lines in negatives.items():
            for line in lines + ["curl: (22) The requested URL returned error: 404",
                                 "unknown blob in local file", "manifest unknown"]:
                with self.subTest(kind=kind, line=line):
                    self.reset()
                    proc, calls = self.run_retry(f"{line}|ok", kind=kind, rc=9)
                    self.assertEqual((proc.returncode, calls), (9, 1))
                    self.assertNotIn("retry.sh", proc.stderr)

    def test_permanent_errors_override_transient_matches(self):
        denied = ["SSL certificate problem", "certificate verify failed", "sha256 mismatch",
                  "Your requirements could not be resolved", "API rate limit exceeded",
                  "Unable to locate package", "Repository not found", "Authentication failed"]
        kinds = ("registry", "net", "http", "composer", "apt", "git", "registry,http,apt,git")
        for kind in kinds:
            for line in denied:
                for suffix in ("", "; connection reset by peer; too many requests; curl: (6); Hash Sum mismatch; RPC failed; HTTP 503"):
                    with self.subTest(kind=kind, line=line, combined=bool(suffix)):
                        self.reset()
                        proc, calls = self.run_retry(f"{line}{suffix}|ok", kind=kind, rc=8)
                        self.assertEqual((proc.returncode, calls), (8, 1))
                        self.assertNotIn("retry.sh", proc.stderr)

    def test_multiple_kinds_and_composer_alias(self):
        for kind, line, expected in [
            ("net,apt", "Hash Sum mismatch", "apt"),
            ("git,http", "curl: (6)", "http"),
            ("composer,registry", "curl error 28 while downloading https://example.org", "http"),
            ("http,registry", "unknown blob", "registry"),
        ]:
            with self.subTest(kind=kind):
                self.reset()
                proc, calls = self.run_retry(f"{line}|ok", kind=kind)
                self.assertEqual((proc.returncode, calls), (0, 2))
                self.assertIn(f"transient {expected} error", proc.stderr)

    def test_unknown_or_empty_kinds_fail_before_command(self):
        for kind in ("wat", "net,wat", "", ",net", "net,", "net,,http", "HTTP", "net, http", "net\nwat"):
            with self.subTest(kind=kind):
                self.reset()
                proc, calls = self.run_retry("ok", kind=kind)
                self.assertEqual((proc.returncode, calls), (2, 0))

    def test_transient_stdout_is_not_matched(self):
        for kind in ("registry", "net", "http", "composer", "apt", "git", "registry,http,apt,git"):
            with self.subTest(kind=kind):
                self.reset()
                line = "connection reset by peer; too many requests; curl: (6); Hash Sum mismatch; RPC failed; HTTP 503"
                proc, calls = self.run_retry(f"{line}|ok", kind=kind, stdout_only=True, rc=4)
                self.assertEqual((proc.returncode, calls), (4, 1))
                self.assertEqual(proc.stdout, f"out-1\n{line}\n")
                self.assertEqual(proc.stderr, "")

    def test_default_delays_and_attempt_counts(self):
        for kind in (None, "registry", "http,registry", "net", "http", "composer", "apt", "git"):
            with self.subTest(kind=kind):
                self.reset()
                bases = [30, 60, 120, 300, 600, 900] if kind is None or "registry" in kind else [5, 15, 45, 120]
                proc, calls = self.run_retry("connection refused", kind=kind, delays=None, rc=6)
                self.assertEqual((proc.returncode, calls), (6, len(bases) + 1))
                with open(self.sleeps) as f:
                    waits = [int(line) for line in f]
                self.assertEqual(len(waits), len(bases))
                for wait, base in zip(waits, bases):
                    self.assertGreaterEqual(wait, base)
                    self.assertLessEqual(wait, base + base // 2)

    def test_delay_and_attempt_overrides_for_every_kind(self):
        for kind in ("registry", "net", "http", "composer", "apt", "git"):
            with self.subTest(kind=kind):
                self.reset()
                proc, calls = self.run_retry("connection refused", kind=kind,
                                             delays="2 4", attempts=5, rc=5)
                self.assertEqual((proc.returncode, calls), (5, 5))
                with open(self.sleeps) as f:
                    waits = [int(line) for line in f]
                self.assertEqual(len(waits), 4)
                for wait, base in zip(waits, [2, 4, 4, 4]):
                    self.assertGreaterEqual(wait, base)
                    self.assertLessEqual(wait, base + base // 2)


if __name__ == "__main__":
    unittest.main()
