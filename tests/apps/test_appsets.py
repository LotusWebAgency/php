"""tests/apps/appsets.py against a fixture matrix, ext registry and sets file,
plus the CLI against the real tree for the exit codes the shell callers rely on.

    python3 -m unittest discover -s tests/apps -p 'test_*.py'
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import appsets  # noqa: E402

MATRIX = {
    "flavors": ["fpm", "cli", "cli-builder", "ext-builder"],
    "versions": {
        "7.1": {"uarch": ["baseline"]},
        "7.2": {"uarch": ["baseline"]},
        "8.0": {"uarch": ["baseline"]},
        "8.1": {"uarch": ["baseline"]},
        "8.2": {"uarch": ["baseline", "v3"]},
    },
}
EXT = {"extensions": [{"name": "snuffleupagus", "php": ">=7.2"}]}


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ext = os.path.join(self.tmp.name, "ext.json")
        with open(self.ext, "w") as fh:
            json.dump(EXT, fh)

    def rows(self, text):
        path = os.path.join(self.tmp.name, "sets")
        with open(path, "w") as fh:
            fh.write(text)
        return appsets.load_rows(MATRIX, path)

    def cells(self, text, **kw):
        return appsets.cells(self.rows(text), MATRIX, ext_path=self.ext, **kw)

    def fails(self, text, fragment):
        with self.assertRaises(appsets.SetsError) as cm:
            self.rows(text)
        self.assertIn(fragment, str(cm.exception))


class TestRanges(Fixture):
    def test_range_expands_to_matrix_versions_only(self):
        (row,) = self.rows("app 1 7.1-8.0 - mariadb\n")
        self.assertEqual(row.php, ["7.1", "7.2", "8.0"])
        self.assertEqual((row.lo, row.hi), ("7.1", "8.0"))

    def test_list_and_range_mix_sorted(self):
        (row,) = self.rows("app 1 8.1,7.1,7.2-8.0 - mariadb\n")
        self.assertEqual(row.php, ["7.1", "7.2", "8.0", "8.1"])

    def test_gaps_are_kept(self):
        (row,) = self.rows("app 1 7.1,8.1 - mariadb\n")
        self.assertEqual(row.php, ["7.1", "8.1"])

    def test_duplicate_version(self):
        self.fails("app 1 7.1,7.1 - mariadb\n", "listed twice")

    def test_overlapping_range_and_version(self):
        self.fails("app 1 7.1-8.0,7.2 - mariadb\n", "7.2 listed twice")

    def test_backwards_range(self):
        self.fails("app 1 8.0-7.1 - mariadb\n", "runs backwards")

    def test_unknown_version(self):
        self.fails("app 1 7.4 - mariadb\n", "PHP 7.4 is not a version in matrix.json")

    def test_unknown_range_end(self):
        self.fails("app 1 8.0-9.9 - mariadb\n", "PHP 9.9 is not a version")

    def test_not_a_version(self):
        self.fails("app 1 seven - mariadb\n", "not a PHP version")

    def test_duplicate_row(self):
        self.fails("app 1 7.1 - mariadb\napp 1 8.1 - mariadb\n", "is already a row")

    def test_same_app_two_sets_may_overlap(self):
        rows = self.rows("app 1 7.1-8.0 - mariadb\napp 2 8.0-8.1 - mariadb\n")
        self.assertEqual(len(rows), 2)

    def test_column_count(self):
        self.fails("app 1 7.1 mariadb\n", "want 5 columns")

    def test_comments_and_blank_lines(self):
        rows = self.rows("# head\n\napp 1 7.1 - mariadb  # trailing\n")
        self.assertEqual(len(rows), 1)

    def test_set_name_must_be_lowercase(self):
        self.fails("app 1B 7.1 - mariadb\n", "lowercase")
        self.assertEqual(self.rows("app 6.9 7.1 - mariadb\n")[0].set, "6.9")

    def test_app_name_must_be_lowercase(self):
        self.fails("App 1 7.1 - mariadb\n", "lowercase")


class TestFlags(Fixture):
    def test_unknown_flag(self):
        self.fails("app 1 7.1 turbo mariadb\n", "flag 'turbo'")

    def test_repeated_flag(self):
        self.fails("app 1 7.1 builder,builder mariadb\n", "listed twice")

    def test_unknown_database(self):
        self.fails("app 1 7.1 - oracle\n", "database 'oracle'")

    def test_v3_needs_a_v3_capable_php(self):
        self.fails("app 1 7.1-8.1 v3 mariadb\n", "flag v3 does nothing")

    def test_v3_ok_when_any_php_has_it(self):
        (row,) = self.rows("app 1 8.1-8.2 v3 mariadb\n")
        self.assertEqual(row.flags, ["v3"])

    def test_v3_cells_only_where_matrix_has_v3(self):
        out = self.cells("app 1 8.1-8.2 v3 mariadb\n", flavors=["fpm"])
        self.assertEqual(
            [(c[2], c[4]) for c in out],
            [("8.1", "baseline"), ("8.2", "baseline"), ("8.2", "v3")],
        )

    def test_no_v3_flag_no_v3_cell(self):
        out = self.cells("app 1 8.2 - mariadb\n")
        self.assertEqual({c[4] for c in out}, {"baseline"})

    def test_builder_adds_cli_builder_only_with_flag(self):
        plain = self.cells("app 1 8.1 - mariadb\n")
        built = self.cells("app 1 8.1 builder mariadb\n")
        self.assertEqual({c[3] for c in plain}, {"fpm", "cli"})
        self.assertEqual({c[3] for c in built}, {"fpm", "cli", "cli-builder"})

    def test_ext_builder_is_never_a_cell(self):
        out = self.cells("app 1 8.1 builder,hardened mariadb\n")
        self.assertNotIn("ext-builder", {c[3] for c in out})

    def test_hardened_floor(self):
        out = self.cells("app 1 7.1-8.0 hardened mariadb\n")
        fpm = {c[2]: c[5] for c in out if c[3] == "fpm"}
        self.assertEqual(fpm, {"7.1": "default", "7.2": "default,hardened", "8.0": "default,hardened"})

    def test_hardened_is_fpm_only(self):
        out = self.cells("app 1 8.0 hardened mariadb\n")
        self.assertEqual({c[3]: c[5] for c in out}, {"fpm": "default,hardened", "cli": "default"})

    def test_hardened_requires_flag(self):
        out = self.cells("app 1 8.0 - mariadb\n")
        self.assertEqual({c[5] for c in out}, {"default"})

    def test_stock_drops_hardened_and_v3(self):
        out = self.cells("app 1 8.2 v3,hardened mariadb\n", stock=True)
        self.assertEqual({(c[4], c[5]) for c in out}, {("baseline", "default")})

    def test_filters(self):
        text = "a 1 7.1-8.2 builder mariadb\nb 1 8.0 - mariadb\n"
        self.assertEqual({c[0] for c in self.cells(text, apps=["b"])}, {"b"})
        self.assertEqual({c[2] for c in self.cells(text, php=["8.0"])}, {"8.0"})
        self.assertEqual({c[3] for c in self.cells(text, flavors=["cli-builder"])}, {"cli-builder"})
        self.assertEqual(self.cells(text, php=["7.1"], apps=["b"]), [])


class TestApps(Fixture):
    def test_unknown_app_is_an_error(self):
        rows = self.rows("a 1 7.1 - mariadb\n")
        with self.assertRaises(appsets.SetsError) as cm:
            appsets.require_apps(rows, ["wrodpress"])
        self.assertIn("'wrodpress' is not in tests/apps/sets", str(cm.exception))

    def test_known_and_empty_pass(self):
        rows = self.rows("a 1 7.1 - mariadb\n")
        appsets.require_apps(rows, ["a"])
        appsets.require_apps(rows, [])


class TestRealTree(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, os.path.join(HERE, "appsets.py"), *args],
            capture_output=True,
            text=True,
        )

    def test_check_passes(self):
        r = self.run_cli("check")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_unknown_app_exits_nonzero_everywhere(self):
        for sub in ("cells", "sets", "rows"):
            r = self.run_cli(sub, "--app", "wrodpress")
            self.assertEqual(r.returncode, 1, sub)
            self.assertIn("wrodpress", r.stderr)
            self.assertEqual(r.stdout, "")

    def test_known_app_with_no_cell_is_empty_success(self):
        r = self.run_cli("cells", "--app", "laravel", "--php", "7.0", "--variant", "v3")
        self.assertEqual((r.returncode, r.stdout), (0, ""))


class TestKnownFailures(Fixture):
    SETS = "laravel 10 8.1,8.2 builder mariadb\n"

    def known(self, text):
        path = os.path.join(self.tmp.name, "known-failures")
        with open(path, "w") as fh:
            fh.write(text)
        return appsets.check_known_failures(self.rows(self.SETS), path)

    def known_fails(self, text, fragment):
        with self.assertRaises(appsets.SetsError) as cm:
            self.known(text)
        self.assertIn(fragment, str(cm.exception))

    def test_valid_rows_are_counted(self):
        self.assertEqual(self.known("# c\nlaravel 10 8.2 console: cache:warmup -- why\n"), 1)

    def test_php_outside_the_row(self):
        self.known_fails("laravel 10 8.0 x -- why\n", "not tested on 8.0")

    def test_unknown_set(self):
        self.known_fails("laravel 9 8.1 x -- why\n", "no laravel set '9'")

    def test_why_is_required(self):
        self.known_fails("laravel 10 8.1 console: x\n", "want 'app set php check -- why'")
        self.known_fails("laravel 10 8.1 console: x --  \n", "want 'app set php check -- why'")

    def test_duplicate(self):
        self.known_fails("laravel 10 8.1 a -- one\nlaravel 10 8.1 a -- two\n", "duplicate")

    def test_real_file_is_valid(self):
        appsets.check_known_failures(appsets.load_rows())


if __name__ == "__main__":
    unittest.main()
