"""ci/candidate.py: the per-entry record and the complete-or-nothing merge."""
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ci"))

import candidate  # noqa: E402

REPO = "ghcr.io/lotuswebagency/php/dev"
CREATED = "2026-11-26T10:00:00Z"
BUILT = "123"
CI_HASH = "e" * 64


def sha(char):
    return "sha256:" + char * 64


def entry(arch="amd64", names=("php-8_5-fpm", "php-8_5-cli")):
    return {
        "name": f"8.5-{arch}",
        "php": "8.5",
        "uarch": "baseline",
        "arch": arch,
        "targets": [
            {"name": n, "flavor": n.split("-", 2)[2], "tag": f"lotuswebagency/php:8.5-{n.split('-', 2)[2]}"}
            for n in names
        ],
    }


def write_out(out, e, passed, platform_of=None):
    """What ci/test-images.sh --mode digest leaves: passed.txt and per-target artifact files."""
    out = Path(out)
    (out / "passed.txt").write_text("".join(n + "\n" for n in passed))
    for i, name in enumerate(passed):
        artifact = out / name / "artifact"
        artifact.mkdir(parents=True)
        (artifact / e["arch"]).write_text(sha(str(i + 1)))
        platform = (platform_of or {}).get(name, sha("a"))
        (artifact / f"{e['arch']}.test-result.json").write_text(json.dumps({"platforms": [{"image_digest": platform}]}))


def targets(names=("php-8_5-fpm", "php-8_5-cli")):
    return [{"name": n, "tags": [f"lotuswebagency/php:8.5-{n.split('-', 2)[2]}"]} for n in names]


def merge(records, wanted=None, **kw):
    return candidate.merge_records(
        records, wanted if wanted is not None else targets(), "c" * 40, "d" * 40, "hash", 123, 2, ci_hash=kw.pop("ci_hash", CI_HASH), **kw
    )


class TestEntryRecord(unittest.TestCase):
    def test_records_passed_targets_only(self):
        e = entry()
        with tempfile.TemporaryDirectory() as tmp:
            write_out(tmp, e, ["php-8_5-cli"], {"php-8_5-cli": sha("b")})
            rec = candidate.entry_record(e, tmp, CREATED, REPO, BUILT)
        self.assertEqual(list(rec["targets"]), ["php-8_5-cli"])
        self.assertEqual(rec["targets"]["php-8_5-cli"], {"tag": "8.5-cli", "index": sha("1"), "platform": sha("b")})
        self.assertEqual((rec["arch"], rec["created"], rec["repository"]), ("amd64", CREATED, REPO))
        self.assertEqual(rec["built_run"], BUILT)

    def test_no_passed_txt_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(candidate.CandidateError, "did not finish"):
                candidate.entry_record(entry(), tmp, CREATED, REPO, BUILT)

    def test_unknown_passed_target(self):
        e = entry()
        with tempfile.TemporaryDirectory() as tmp:
            write_out(tmp, e, ["php-8_5-fpm"])
            (Path(tmp) / "passed.txt").write_text("php-9_9-fpm\n")
            with self.assertRaisesRegex(candidate.CandidateError, "not in entry"):
                candidate.entry_record(e, tmp, CREATED, REPO, BUILT)

    def test_malformed_digest(self):
        e = entry()
        with tempfile.TemporaryDirectory() as tmp:
            write_out(tmp, e, ["php-8_5-fpm"])
            (Path(tmp) / "php-8_5-fpm" / "artifact" / "amd64").write_text("sha256:short")
            with self.assertRaisesRegex(candidate.CandidateError, "not a sha256 digest"):
                candidate.entry_record(e, tmp, CREATED, REPO, BUILT)

    def test_bad_timestamp(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(candidate.CandidateError, "not a UTC timestamp"):
                candidate.entry_record(entry(), tmp, "yesterday", REPO, BUILT)

    def test_bad_built_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(candidate.CandidateError, "not a run id"):
                candidate.entry_record(entry(), tmp, CREATED, REPO, "latest")


def record(arch, created=CREATED, names=("php-8_5-fpm", "php-8_5-cli"), repo=REPO, built_run=BUILT):
    return {
        "name": f"8.5-{arch}", "php": "8.5", "uarch": "baseline", "arch": arch, "created": created, "built_run": built_run, "repository": repo,
        "targets": {n: {"tag": f"8.5-{n.split('-', 2)[2]}", "index": sha("1"), "platform": sha("2")} for n in names},
    }


class TestMerge(unittest.TestCase):
    def test_complete_set(self):
        doc = merge([record("amd64"), record("arm64", created="2026-11-26T11:00:00Z")])
        self.assertEqual(doc["schema"], 1)
        self.assertEqual((doc["sha"], doc["tree"], doc["inputs_hash"], doc["ci_hash"]), ("c" * 40, "d" * 40, "hash", CI_HASH))
        self.assertEqual((doc["run_id"], doc["run_attempt"], doc["repository"]), ("123", "2", REPO))
        self.assertEqual(doc["built_run"], BUILT)
        self.assertEqual(list(doc["targets"]), ["php-8_5-fpm", "php-8_5-cli"])
        fpm = doc["targets"]["php-8_5-fpm"]
        self.assertEqual(fpm["tag"], "8.5-fpm")
        self.assertEqual(fpm["archs"]["amd64"], {"index": sha("1"), "platform": sha("2"), "created": CREATED, "built_run": BUILT})
        self.assertEqual(fpm["archs"]["arm64"]["created"], "2026-11-26T11:00:00Z")

    def test_ci_hash_must_be_a_sha256(self):
        for bad in ("", "abc", "E" * 64, None):
            with self.assertRaises(candidate.CandidateError):
                merge([record("amd64"), record("arm64")], ci_hash=bad)

    def test_missing_arch_target_lists_every_gap(self):
        with self.assertRaises(candidate.CandidateError) as cm:
            merge([record("amd64"), record("arm64", names=("php-8_5-fpm",))])
        self.assertIn("php-8_5-cli arm64 is missing", str(cm.exception))
        self.assertNotIn("php-8_5-fpm", str(cm.exception))

    def test_no_arm64_at_all(self):
        with self.assertRaises(candidate.CandidateError) as cm:
            merge([record("amd64")])
        self.assertEqual(str(cm.exception).count("is missing"), 2)

    def test_duplicate_record(self):
        with self.assertRaisesRegex(candidate.CandidateError, "more than one record"):
            merge([record("amd64"), record("amd64"), record("arm64")])

    def test_unknown_target(self):
        with self.assertRaisesRegex(candidate.CandidateError, "not a target of this matrix"):
            merge([record("amd64", names=("php-8_5-fpm", "php-8_5-cli", "php-8_5-cli-builder")), record("arm64")])

    def test_tag_drift(self):
        rec = record("amd64")
        rec["targets"]["php-8_5-fpm"]["tag"] = "8.5-other"
        with self.assertRaisesRegex(candidate.CandidateError, "expected 8.5-fpm"):
            merge([rec, record("arm64")])

    def test_mixed_repositories(self):
        with self.assertRaisesRegex(candidate.CandidateError, "more than one repository"):
            merge([record("amd64"), record("arm64", repo="ghcr.io/other")])

    def test_bad_digest_in_record(self):
        rec = record("amd64")
        rec["targets"]["php-8_5-cli"]["platform"] = "nope"
        with self.assertRaisesRegex(candidate.CandidateError, "not a sha256 digest"):
            merge([rec, record("arm64")])

    def test_reused_images_keep_their_build_run_and_time(self):
        old = "2026-11-23T08:00:00Z"
        doc = merge([record("amd64", created=old, built_run="77"), record("arm64", created=old, built_run="77")])
        self.assertEqual((doc["run_id"], doc["built_run"]), ("123", "77"))
        self.assertEqual(doc["targets"]["php-8_5-cli"]["archs"]["arm64"]["created"], old)

    def test_two_build_runs_are_refused(self):
        with self.assertRaisesRegex(candidate.CandidateError, "more than one build run"):
            merge([record("amd64"), record("arm64", built_run="77")])

    def test_record_without_built_run(self):
        rec = record("amd64")
        del rec["built_run"]
        with self.assertRaisesRegex(candidate.CandidateError, "built_run"):
            merge([rec, record("arm64")])

    def test_unknown_arch(self):
        with self.assertRaisesRegex(candidate.CandidateError, "not one of"):
            merge([record("amd64"), record("arm64"), record("s390x")])


class TestCli(unittest.TestCase):
    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = candidate.main(list(argv))
        return rc, out.getvalue(), err.getvalue()

    def test_entry_then_merge(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            records = tmp / "records"
            records.mkdir()
            for arch in ("amd64", "arm64"):
                e = entry(arch)
                out = tmp / f"out-{arch}"
                out.mkdir()
                write_out(out, e, ["php-8_5-fpm", "php-8_5-cli"])
                (tmp / f"entry-{arch}.json").write_text(json.dumps(e))
                rc, stdout, _ = self.run_cli("entry", "--entry", str(tmp / f"entry-{arch}.json"), "--out", str(out),
                                             "--created", CREATED, "--built-run", BUILT, "--repository", REPO)
                self.assertEqual(rc, 0)
                (records / arch).mkdir()
                (records / arch / "record.json").write_text(stdout)
            (tmp / "targets.json").write_text(json.dumps(targets()))
            dest = tmp / "release-candidate.json"
            rc, stdout, _ = self.run_cli("merge", "--targets", str(tmp / "targets.json"), "--records", str(records),
                                         "--sha", "c" * 40, "--tree", "d" * 40, "--inputs-hash", "h", "--ci-hash", CI_HASH,
                                         "--run-id", "9", "--run-attempt", "1", "--out", str(dest))
            self.assertEqual(rc, 0, stdout)
            doc = json.loads(dest.read_text())
            self.assertEqual(sorted(doc["targets"]["php-8_5-cli"]["archs"]), ["amd64", "arm64"])
            self.assertEqual(doc["ci_hash"], CI_HASH)

    def test_merge_of_an_incomplete_set_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "targets.json").write_text(json.dumps(targets()))
            (tmp / "records").mkdir()
            (tmp / "records" / "a.json").write_text(json.dumps(record("amd64")))
            rc, _, err = self.run_cli("merge", "--targets", str(tmp / "targets.json"), "--records", str(tmp / "records"),
                                      "--sha", "c" * 40, "--tree", "d" * 40, "--inputs-hash", "h", "--ci-hash", CI_HASH,
                                      "--run-id", "9", "--run-attempt", "1", "--out", str(tmp / "out.json"))
            self.assertEqual(rc, 1)
            self.assertIn("is missing", err)
            self.assertFalse((tmp / "out.json").exists())


class TestPin(unittest.TestCase):
    def cand(self):
        records = [
            {"name": f"8.5-{a}", "php": "8.5", "uarch": "baseline", "arch": a, "created": CREATED, "built_run": BUILT, "repository": REPO,
             "targets": {n: {"tag": f"8.5-{n.split('-', 2)[2]}", "index": sha("1" if a == "amd64" else "2"), "platform": sha("3" if a == "amd64" else "4")}
                         for n in ("php-8_5-fpm", "php-8_5-cli")}}
            for a in ("amd64", "arm64")
        ]
        return merge(records)

    def pin(self, cand=None, name="php-8_5-fpm", arch="amd64", **kw):
        args = dict(sha="c" * 40, inputs_hash="hash", run_id="123")
        args.update(kw)
        return candidate.pin(cand or self.cand(), name, arch, args["sha"], args["inputs_hash"], args["run_id"])

    def test_the_index_ref_and_platform_of_one_arch(self):
        self.assertEqual(self.pin(), (f"{REPO}@{sha('1')}", sha("3")))
        self.assertEqual(self.pin(arch="arm64"), (f"{REPO}@{sha('2')}", sha("4")))

    def test_a_candidate_of_another_commit_hash_or_run_is_refused(self):
        for kw, text in (({"sha": "e" * 40}, "commit"), ({"inputs_hash": "other"}, "inputs hash"), ({"run_id": "999"}, "ci run 123")):
            with self.assertRaisesRegex(candidate.CandidateError, text):
                self.pin(**kw)

    def test_no_run_id_means_any_run(self):
        self.assertEqual(self.pin(run_id="")[0], f"{REPO}@{sha('1')}")

    def test_a_target_or_arch_the_candidate_lacks(self):
        with self.assertRaisesRegex(candidate.CandidateError, "no php-8_5-zts amd64"):
            self.pin(name="php-8_5-zts")
        cand = self.cand()
        del cand["targets"]["php-8_5-fpm"]["archs"]["arm64"]
        with self.assertRaisesRegex(candidate.CandidateError, "no php-8_5-fpm arm64"):
            self.pin(cand, arch="arm64")

    def test_a_malformed_digest_is_refused(self):
        cand = self.cand()
        cand["targets"]["php-8_5-fpm"]["archs"]["amd64"]["index"] = "sha256:short"
        with self.assertRaisesRegex(candidate.CandidateError, "not a sha256 digest"):
            self.pin(cand)

    def test_cli_pin_and_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / "release-candidate.json"
            f.write_text(json.dumps(self.cand()))
            base = ["--candidate", str(f), "--sha", "c" * 40, "--inputs-hash", "hash", "--run-id", "123"]
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(candidate.main(["pin", *base, "--target", "php-8_5-cli", "--arch", "amd64"]), 0)
                self.assertEqual(candidate.main(["check", *base]), 0)
            self.assertIn(f"{REPO}@{sha('1')}\t{sha('3')}", out.getvalue())
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                self.assertEqual(candidate.main(["pin", *base[:-1], "999", "--target", "php-8_5-cli", "--arch", "amd64"]), 1)
                self.assertEqual(candidate.main(["check", "--candidate", str(Path(tmp) / "missing.json"), *base[2:]]), 1)
            self.assertIn("FAIL:", err.getvalue())


if __name__ == "__main__":
    unittest.main()
