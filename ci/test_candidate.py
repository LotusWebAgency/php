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
        records, wanted if wanted is not None else targets(), "c" * 40, "d" * 40, "hash", 123, 2, **kw
    )


class TestEntryRecord(unittest.TestCase):
    def test_records_passed_targets_only(self):
        e = entry()
        with tempfile.TemporaryDirectory() as tmp:
            write_out(tmp, e, ["php-8_5-cli"], {"php-8_5-cli": sha("b")})
            rec = candidate.entry_record(e, tmp, CREATED, REPO)
        self.assertEqual(list(rec["targets"]), ["php-8_5-cli"])
        self.assertEqual(rec["targets"]["php-8_5-cli"], {"tag": "8.5-cli", "index": sha("1"), "platform": sha("b")})
        self.assertEqual((rec["arch"], rec["created"], rec["repository"]), ("amd64", CREATED, REPO))

    def test_no_passed_txt_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(candidate.CandidateError, "did not finish"):
                candidate.entry_record(entry(), tmp, CREATED, REPO)

    def test_unknown_passed_target(self):
        e = entry()
        with tempfile.TemporaryDirectory() as tmp:
            write_out(tmp, e, ["php-8_5-fpm"])
            (Path(tmp) / "passed.txt").write_text("php-9_9-fpm\n")
            with self.assertRaisesRegex(candidate.CandidateError, "not in entry"):
                candidate.entry_record(e, tmp, CREATED, REPO)

    def test_malformed_digest(self):
        e = entry()
        with tempfile.TemporaryDirectory() as tmp:
            write_out(tmp, e, ["php-8_5-fpm"])
            (Path(tmp) / "php-8_5-fpm" / "artifact" / "amd64").write_text("sha256:short")
            with self.assertRaisesRegex(candidate.CandidateError, "not a sha256 digest"):
                candidate.entry_record(e, tmp, CREATED, REPO)

    def test_bad_timestamp(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(candidate.CandidateError, "not a UTC timestamp"):
                candidate.entry_record(entry(), tmp, "yesterday", REPO)


def record(arch, created=CREATED, names=("php-8_5-fpm", "php-8_5-cli"), repo=REPO):
    return {
        "name": f"8.5-{arch}", "php": "8.5", "uarch": "baseline", "arch": arch, "created": created, "repository": repo,
        "targets": {n: {"tag": f"8.5-{n.split('-', 2)[2]}", "index": sha("1"), "platform": sha("2")} for n in names},
    }


class TestMerge(unittest.TestCase):
    def test_complete_set(self):
        doc = merge([record("amd64"), record("arm64", created="2026-11-26T11:00:00Z")])
        self.assertEqual(doc["schema"], 1)
        self.assertEqual((doc["sha"], doc["tree"], doc["inputs_hash"]), ("c" * 40, "d" * 40, "hash"))
        self.assertEqual((doc["run_id"], doc["run_attempt"], doc["repository"]), ("123", "2", REPO))
        self.assertEqual(list(doc["targets"]), ["php-8_5-fpm", "php-8_5-cli"])
        fpm = doc["targets"]["php-8_5-fpm"]
        self.assertEqual(fpm["tag"], "8.5-fpm")
        self.assertEqual(fpm["archs"]["amd64"], {"index": sha("1"), "platform": sha("2"), "created": CREATED})
        self.assertEqual(fpm["archs"]["arm64"]["created"], "2026-11-26T11:00:00Z")

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
                                             "--created", CREATED, "--repository", REPO)
                self.assertEqual(rc, 0)
                (records / arch).mkdir()
                (records / arch / "record.json").write_text(stdout)
            (tmp / "targets.json").write_text(json.dumps(targets()))
            dest = tmp / "release-candidate.json"
            rc, stdout, _ = self.run_cli("merge", "--targets", str(tmp / "targets.json"), "--records", str(records),
                                         "--sha", "c" * 40, "--tree", "d" * 40, "--inputs-hash", "h",
                                         "--run-id", "9", "--run-attempt", "1", "--out", str(dest))
            self.assertEqual(rc, 0, stdout)
            self.assertEqual(sorted(json.loads(dest.read_text())["targets"]["php-8_5-cli"]["archs"]), ["amd64", "arm64"])

    def test_merge_of_an_incomplete_set_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "targets.json").write_text(json.dumps(targets()))
            (tmp / "records").mkdir()
            (tmp / "records" / "a.json").write_text(json.dumps(record("amd64")))
            rc, _, err = self.run_cli("merge", "--targets", str(tmp / "targets.json"), "--records", str(tmp / "records"),
                                      "--sha", "c" * 40, "--tree", "d" * 40, "--inputs-hash", "h",
                                      "--run-id", "9", "--run-attempt", "1", "--out", str(tmp / "out.json"))
            self.assertEqual(rc, 1)
            self.assertIn("is missing", err)
            self.assertFalse((tmp / "out.json").exists())


if __name__ == "__main__":
    unittest.main()
