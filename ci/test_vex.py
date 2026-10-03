import argparse
import copy
import datetime
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ci"))

import result_predicate  # noqa: E402
import vex  # noqa: E402

DIGEST = "sha256:" + "ab" * 32


class TestVexFile(unittest.TestCase):
    def setUp(self):
        self.doc = vex.load()

    def test_the_committed_file_is_valid_openvex(self):
        self.assertEqual(vex.validate(self.doc), [])

    def test_review_date_is_exclusive_like_trivys_exp(self):
        due = vex.review_date(self.doc["statements"][0])
        day_before = due - datetime.timedelta(days=1)
        self.assertEqual(vex.expired(self.doc, day_before), [])
        self.assertEqual(len(vex.expired(self.doc, due)), len(self.doc["statements"]))

    def test_due_within_lists_statements_inside_the_window_soonest_first(self):
        due = vex.review_date(self.doc["statements"][0])
        names = {st["vulnerability"]["name"] for st in self.doc["statements"]}
        day = datetime.timedelta(days=1)
        self.assertEqual(vex.due_within(self.doc, due - 15 * day, 14), [])
        self.assertEqual({n for n, _ in vex.due_within(self.doc, due - 14 * day, 14)}, names)
        self.assertEqual({n for n, _ in vex.due_within(self.doc, due + 30 * day, 14)}, names)

    def test_trivyignore_is_the_generated_file(self):
        self.assertEqual(
            vex.TRIVYIGNORE_PATH.read_text(), vex.trivyignore(self.doc),
            ".trivyignore drifted from vex/php.openvex.json -- run: python3 ci/vex.py trivyignore --write",
        )

    def test_trivyignore_lines_carry_the_statements_deadline(self):
        lines = {ln.split()[0]: ln.split()[1] for ln in vex.TRIVYIGNORE_PATH.read_text().splitlines()
                 if re.match(r"^CVE-\S+ exp:", ln)}
        want = {st["vulnerability"]["name"]: f"exp:{vex.review_date(st)}" for st in self.doc["statements"]
                if st["status"] in vex.IGNORED_STATUSES}
        self.assertEqual(lines, want)

    def test_statements_name_real_packages(self):
        for st in self.doc["statements"]:
            for p in st["products"]:
                for sub in p["subcomponents"]:
                    self.assertRegex(sub["@id"], r"^pkg:npm/[^@]+@\d+\.\d+\.\d+$")


class TestValidate(unittest.TestCase):
    def setUp(self):
        self.doc = copy.deepcopy(vex.load())

    def problems_after(self, edit):
        edit(self.doc)
        return vex.validate(self.doc)

    def test_unknown_statement_key_is_refused(self):
        p = self.problems_after(lambda d: d["statements"][0].update(review_by="2026-11-30"))
        self.assertTrue(any("unknown key 'review_by'" in x for x in p), p)

    def test_affected_needs_an_action_statement(self):
        p = self.problems_after(lambda d: d["statements"][0].pop("action_statement"))
        self.assertTrue(any("action_statement" in x for x in p), p)

    def test_not_affected_needs_a_justification(self):
        def edit(d):
            d["statements"][0]["status"] = "not_affected"
        p = self.problems_after(edit)
        self.assertTrue(any("justification" in x for x in p), p)

    def test_not_affected_with_a_justification_is_accepted_and_ignored_by_the_gate(self):
        def edit(d):
            d["statements"][0].update(status="not_affected", justification="vulnerable_code_not_in_execute_path")
            d["statements"][0].pop("action_statement")
        self.assertEqual(self.problems_after(edit), [])
        self.assertIn("CVE-2026-102276 exp:", vex.trivyignore(self.doc))

    def test_under_investigation_is_never_ignored(self):
        def edit(d):
            d["statements"][0]["status"] = "under_investigation"
        self.assertEqual(self.problems_after(edit), [])
        self.assertNotIn("CVE-2026-102276", vex.trivyignore(self.doc))

    def test_every_statement_needs_a_review_deadline(self):
        p = self.problems_after(lambda d: d["statements"][0].update(status_notes="accepted, no date"))
        self.assertTrue(any("review-by" in x for x in p), p)

    def test_empty_statement_list_is_refused(self):
        p = self.problems_after(lambda d: d.update(statements=[]))
        self.assertTrue(any("non-empty" in x for x in p), p)

    def test_unknown_justification_is_refused(self):
        def edit(d):
            d["statements"][0].update(status="not_affected", justification="because")
        p = self.problems_after(edit)
        self.assertTrue(any("justification" in x for x in p), p)


class TestEmit(unittest.TestCase):
    def setUp(self):
        self.doc = vex.load()

    def emit(self, flavor, digest=DIGEST):
        return vex.emit(self.doc, "lotuswebagency/php", digest, flavor, "2026-10-03T12:00:00Z")

    def test_cli_builder_gets_every_statement_scoped_to_the_digest(self):
        out = self.emit("cli-builder")
        purl = f"pkg:oci/php@{DIGEST}?repository_url=index.docker.io/lotuswebagency/php"
        self.assertEqual(len(out["statements"]), len(self.doc["statements"]))
        for st in out["statements"]:
            self.assertEqual([p["@id"] for p in st["products"]], [purl])
            self.assertEqual(st["products"][0]["hashes"], {"sha-256": "ab" * 32})
            self.assertNotIn("flavor=", json.dumps(st))
        self.assertEqual(out["timestamp"], "2026-10-03T12:00:00Z")

    def test_other_flavors_get_nothing(self):
        for flavor in ("fpm", "cli", "ext-builder"):
            self.assertIsNone(self.emit(flavor), flavor)

    def test_the_emitted_document_passes_the_same_validation(self):
        self.assertEqual(vex.validate(self.emit("cli-builder")), [])

    def test_a_bad_digest_is_refused(self):
        with self.assertRaises(ValueError):
            self.emit("cli-builder", "sha256:abc")

    def test_image_purl_follows_matrix_json(self):
        self.assertEqual(vex.image_repository(), "lotuswebagency/php")


class TestResultPredicate(unittest.TestCase):
    def log(self, text):
        f = tempfile.NamedTemporaryFile("w", suffix=".log", delete=False)
        self.addCleanup(Path(f.name).unlink)
        f.write(text)
        f.close()
        return f.name

    def test_a_passing_log_lists_its_ok_lines_only(self):
        r = result_predicate.smoke_result(self.log("noise\nok: php 8.2\nok: uid 33\nSMOKE PASSED\n"))
        self.assertEqual(r["verdict"], "pass")
        self.assertEqual(r["passed_checks"], ["php 8.2", "uid 33"])
        self.assertEqual(r["check_count"], 2)

    def test_a_failure_line_refuses_even_after_ok_lines(self):
        with self.assertRaises(ValueError):
            result_predicate.smoke_result(self.log("ok: a\nFAIL: b\nSMOKE PASSED\n"))

    def test_a_run_that_never_finished_refuses(self):
        with self.assertRaises(ValueError):
            result_predicate.smoke_result(self.log("ok: a\nok: b\n"))

    def test_a_pass_with_no_checks_refuses(self):
        with self.assertRaises(ValueError):
            result_predicate.smoke_result(self.log("SMOKE PASSED\n"))

    def predicate_args(self, outcome, info=None):
        return argparse.Namespace(
            trivy_outcome=outcome, trivy_severity="CRITICAL,HIGH", trivy_info=info,
            trivyignore=str(vex.TRIVYIGNORE_PATH), vex=str(vex.VEX_PATH),
        )

    def test_trivy_verdict_comes_from_the_step_outcome(self):
        r = result_predicate.trivy_result(self.predicate_args("success"))
        self.assertEqual((r["verdict"], r["severity"]), ("pass", "CRITICAL,HIGH"))
        for outcome in ("failure", "cancelled", "skipped", ""):
            with self.assertRaises(ValueError, msg=outcome):
                result_predicate.trivy_result(self.predicate_args(outcome))

    def test_trivy_version_and_db_date_are_recorded_when_present(self):
        info = self.log('{"Version": "0.70.0", "VulnerabilityDB": {"UpdatedAt": "2026-10-03T06:00:00Z"}}')
        r = result_predicate.trivy_result(self.predicate_args("success", info))
        self.assertEqual((r["version"], r["db_updated_at"]), ("0.70.0", "2026-10-03T06:00:00Z"))
        for bad in ("not json", "[]", "{}"):
            r = result_predicate.trivy_result(self.predicate_args("success", self.log(bad)))
            self.assertNotIn("version", r)
            self.assertNotIn("db_updated_at", r)
        self.assertNotIn("version", result_predicate.trivy_result(self.predicate_args("success", "/nonexistent")))

    def platform(self, arch, **over):
        p = {k: f"{k}-v" for k in result_predicate.COMMON}
        p.update(created="2026-10-03T00:00:00Z", platforms=[{"arch": arch, "image_digest": DIGEST}])
        p.update(over)
        return p

    def test_aggregate_merges_platforms_in_arch_order(self):
        out = result_predicate.aggregate([self.platform("arm64"), self.platform("amd64")])
        self.assertEqual([p["arch"] for p in out["platforms"]], ["amd64", "arm64"])

    def test_aggregate_refuses_results_that_disagree(self):
        with self.assertRaises(ValueError):
            result_predicate.aggregate([self.platform("amd64"), self.platform("arm64", git_sha="other")])

    def test_aggregate_refuses_a_repeated_architecture(self):
        with self.assertRaises(ValueError):
            result_predicate.aggregate([self.platform("amd64"), self.platform("amd64")])


class TestWiring(unittest.TestCase):
    def test_the_predicate_type_is_spelled_the_same_in_the_signing_script(self):
        script = (ROOT / "ci" / "attest-image.sh").read_text()
        m = re.search(r'^TEST_RESULT_TYPE="([^"]+)"', script, re.M)
        self.assertIsNotNone(m)
        self.assertEqual(m.group(1), result_predicate.PREDICATE_TYPE)


if __name__ == "__main__":
    unittest.main()
