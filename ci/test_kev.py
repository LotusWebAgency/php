"""ci/kev.py: which Trivy findings it flags and what it refuses to read."""
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ci"))

import kev  # noqa: E402


def catalog(*cves):
    return {
        "catalogVersion": "2026.10.23",
        "count": len(cves),
        "vulnerabilities": [
            {"cveID": cve, "dateAdded": "2026-01-02", "knownRansomwareCampaignUse": "Known"} for cve in cves
        ],
    }


def report(*vulns):
    return {"SchemaVersion": 2, "Results": [{"Target": "img", "Class": "os-pkgs", "Vulnerabilities": list(vulns)}]}


def vuln(cve, fixed=None):
    found = {"VulnerabilityID": cve, "PkgName": "libfoo", "InstalledVersion": "1.0-r0", "Severity": "MEDIUM"}
    if fixed:
        found["FixedVersion"] = fixed
    return found


class TestKev(unittest.TestCase):
    def run_main(self, report_doc, catalog_doc):
        with tempfile.TemporaryDirectory() as tmp:
            report_path = Path(tmp) / "report.json"
            catalog_path = Path(tmp) / "kev.json"
            for path, doc in ((report_path, report_doc), (catalog_path, catalog_doc)):
                path.write_text(doc if isinstance(doc, str) else json.dumps(doc), encoding="utf-8")
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = kev.main([str(report_path), "--catalog", str(catalog_path)])
        return code, out.getvalue(), err.getvalue()

    def test_a_listed_cve_fails_and_is_described(self):
        code, out, _ = self.run_main(report(vuln("CVE-2026-1", fixed="1.1-r0")), catalog("CVE-2026-1"))
        self.assertEqual(code, 1)
        for text in ("CVE-2026-1", "libfoo", "1.0-r0", "1.1-r0", "2026-01-02", "Known", "2026.10.23"):
            self.assertIn(text, out)

    def test_no_listed_cve_passes_and_names_the_catalog_version(self):
        code, out, _ = self.run_main(report(vuln("CVE-2026-2")), catalog("CVE-2026-1"))
        self.assertEqual(code, 0)
        self.assertIn("2026.10.23", out)

    def test_an_unfixed_listed_cve_fails(self):
        code, out, _ = self.run_main(report(vuln("CVE-2026-1")), catalog("CVE-2026-1"))
        self.assertEqual(code, 1)
        self.assertIn("no fix", out)

    def test_only_the_listed_finding_among_several_is_reported(self):
        code, out, _ = self.run_main(report(vuln("CVE-2026-2"), vuln("CVE-2026-1")), catalog("CVE-2026-1"))
        self.assertEqual(code, 1)
        self.assertIn("CVE-2026-1", out)
        self.assertNotIn("CVE-2026-2", out)

    def test_empty_results_pass(self):
        for doc in ({"SchemaVersion": 2}, {"SchemaVersion": 2, "Results": None}, {"SchemaVersion": 2, "Results": []},
                    {"Results": [{"Target": "img", "Class": "os-pkgs"}]}):
            with self.subTest(doc=doc):
                self.assertEqual(self.run_main(doc, catalog("CVE-2026-1"))[0], 0)

    def test_a_malformed_catalog_fails_instead_of_passing(self):
        bad = (
            "not json",
            [],
            {"vulnerabilities": [{"cveID": "CVE-2026-1"}]},
            {"catalogVersion": "", "vulnerabilities": [{"cveID": "CVE-2026-1"}]},
            {"catalogVersion": "1"},
            {"catalogVersion": "1", "vulnerabilities": {}},
            {"catalogVersion": "1", "vulnerabilities": []},
            {"catalogVersion": "1", "vulnerabilities": [{"dateAdded": "2026-01-02"}]},
        )
        for doc in bad:
            with self.subTest(doc=doc):
                code, out, err = self.run_main(report(vuln("CVE-2026-1")), doc)
                self.assertEqual(code, 2)
                self.assertNotIn("no finding", out)
                self.assertIn("kev:", err)

    def test_a_malformed_report_fails(self):
        for doc in ("not json", [], {"Results": {}}, report({"PkgName": "libfoo"})):
            with self.subTest(doc=doc):
                self.assertEqual(self.run_main(doc, catalog("CVE-2026-1"))[0], 2)

    def test_a_missing_file_fails(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(kev.main(["/nonexistent/report.json", "--catalog", "/nonexistent/kev.json"]), 2)


if __name__ == "__main__":
    unittest.main()
