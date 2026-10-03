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
echo "$step" >&2
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

    def calls(self):
        if not os.path.exists(self.count):
            return 0
        with open(self.count) as f:
            return int(f.read())

    def reset(self):
        if os.path.exists(self.count):
            os.remove(self.count)

    def run_retry(self, plan, delays="0 0 0 0", attempts=None, rc=1):
        env = dict(os.environ, STUB_PLAN=plan, STUB_COUNT=self.count,
                   STUB_RC=str(rc), RETRY_DELAYS=delays)
        env.pop("RETRY_ATTEMPTS", None)
        if attempts is not None:
            env["RETRY_ATTEMPTS"] = str(attempts)
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
        ]
        not_retried = [
            "unexpected status from HEAD request to https://registry-1.docker.io/v2/ns/php/manifests/sha256:"
            "500a0b1c2d3e4f5061728394a5b6c7d8e9f00112233445566778899aabbccddee: 404 Not Found",
            "unexpected status from GET request to https://x/token: 401 Unauthorized",
            "denied: requested access to the resource is denied",
            "manifest unknown",
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


if __name__ == "__main__":
    unittest.main()
