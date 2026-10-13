import json
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _parts(v):
    return tuple(int(x) for x in v.split("."))


def vkey(v):
    parts = [int(x) for x in v.split(".")] + [0, 0]
    return tuple(parts[:3])


def satisfies(constraint, version):
    """Same semantics as the shell/python filters in php/*.sh."""
    for clause in (constraint or "").split(","):
        clause = clause.strip()
        for op in (">=", "<=", "<", ">", "=="):
            if clause.startswith(op):
                bound, cur = _parts(clause[len(op):]), _parts(version)
                if not {">=": cur >= bound, "<=": cur <= bound, "<": cur < bound,
                        ">": cur > bound, "==": cur == bound}[op]:
                    return False
                break
    return True
EXT = ROOT / "php" / "ext.json"
ARGS = ROOT / "php" / "configure-args.sh"

STATIC_REQUIRED = {
    "bcmath", "calendar", "ctype", "curl", "dom", "exif", "fileinfo", "filter",
    "ftp", "gd", "gettext", "gmp", "hash", "iconv", "intl", "json", "mbstring",
    "mysqli", "mysqlnd", "opcache", "openssl", "pcntl", "pdo", "pdo_mysql",
    "pdo_pgsql", "pdo_sqlite", "pgsql", "phar", "posix", "readline", "session",
    "shmop", "simplexml", "soap", "sockets", "sodium", "sqlite3", "sysvmsg",
    "sysvsem", "sysvshm", "tokenizer", "xml", "xmlreader", "xmlwriter", "xsl",
    "zip", "zlib", "igbinary", "redis", "imagick", "memcached", "apcu", "zstd",
}

SHARED_REQUIRED = {
    "amqp", "bz2", "ffi", "imap", "ldap", "lz4", "mcrypt", "mongodb", "msgpack",
    "pcov", "protobuf", "snmp", "ssh2", "swoole", "tidy",
    "uuid", "xdebug", "xmlrpc", "yaml", "brotli", "event", "snuffleupagus",
}


class TestRegistry(unittest.TestCase):
    def setUp(self):
        self.exts = json.loads(EXT.read_text())["extensions"]
        self.by_name = {e["name"]: e for e in self.exts}
        self.matrix = sorted(json.loads((ROOT / "matrix.json").read_text())["versions"],
                             key=vkey)

    def test_no_duplicate_names(self):
        names = [e["name"] for e in self.exts]
        self.assertEqual(len(names), len(set(names)))

    def test_static_set_complete(self):
        static = {n for n, e in self.by_name.items() if e["linkage"] == "static"}
        self.assertEqual(static, STATIC_REQUIRED)

    def test_shared_set_complete(self):
        shared = {n for n, e in self.by_name.items() if e["linkage"] == "shared"}
        self.assertEqual(shared, SHARED_REQUIRED)

    def test_every_entry_has_rationale(self):
        for e in self.exts:
            self.assertTrue(e.get("why"), f"{e['name']} has no 'why'")

    def test_source_and_linkage_are_valid(self):
        for e in self.exts:
            self.assertIn(e["source"], ("core", "pecl", "github"), e["name"])
            for v, o in (e.get("overrides") or {}).items():
                # a per-version core source only ever steps back into php-src;
                # a github override would have no url of its own to fetch
                self.assertIn(o.get("source", "core"), ("core", "pecl"), f"{e['name']}@{v}")
            self.assertIn(e["linkage"], ("static", "shared"), e["name"])
            if e["source"] == "github":
                self.assertTrue(e.get("url"), f"{e['name']} needs a pinned url")

    def test_imap_excluded_above_83(self):
        # imap was removed from core in 8.4
        self.assertEqual(self.by_name["imap"]["php"], ">=7.0,<8.4")

    def test_mcrypt_and_xmlrpc_are_seven_only(self):
        # xmlrpc's upper bound is a php-src fact (it left core in 8.0);
        # mcrypt's is a product decision: PrestaShop 1.6 needs it on every 7.x.
        # It comes from php-src on 7.0/7.1 (still core there) and from the
        # pinned PECL package (7.2.0 floor) after that.
        mcrypt = self.by_name["mcrypt"]
        self.assertEqual(mcrypt["php"], ">=7.0,<8.0")
        self.assertEqual(mcrypt["source"], "pecl")
        for v in ("7.0", "7.1"):
            self.assertEqual(mcrypt["overrides"][v], {"source": "core", "configure": "--with-mcrypt"})
        self.assertEqual(self.by_name["xmlrpc"]["php"], ">=7.0,<8.0")

    def _lock_rows(self):
        """{key: (version, php_min, php_max)} from pecl.lock, '-' for unset."""
        rows = {}
        for line in (ROOT / "php" / "pecl.lock").read_text().splitlines():
            if line.startswith("#") or not line.strip():
                continue
            parts = line.split()
            if len(parts) >= 5:
                rows[parts[0]] = (parts[1], parts[3], parts[4])
        return rows

    def test_every_matrix_version_gets_a_package_that_supports_it(self):
        """For every version an extension claims, the package fetched supports it.

        Compares the registry against the range each pinned package declares for
        itself, transcribed into pecl.lock from its package.xml. Catches a pin
        bumped past the versions its extension still claims, which would fail
        late in the build or produce an extension built against a PHP its
        authors never supported.
        """
        rows = self._lock_rows()
        self.assertGreater(len(rows), 0, "no rows with declared ranges parsed out of pecl.lock")
        checked = 0
        for e in self.exts:
            if e["source"] != "pecl":
                continue
            for version in self.matrix:
                if not satisfies(e["php"], version):
                    continue
                override = (e.get("overrides") or {}).get(version, {})
                if override.get("source", "pecl") != "pecl":
                    continue
                lock_key = f"{e['name']}@{version}" if override.get("version") else e["name"]
                row = rows.get(lock_key)
                self.assertIsNotNone(row, f"{lock_key} has no pecl.lock row")
                ver, php_min, php_max = row
                if php_min != "-":
                    self.assertGreaterEqual(
                        vkey(version), vkey(php_min),
                        f"ext.json says {e['name']} supports PHP {version}, but {lock_key} "
                        f"({ver}) declares a {php_min} floor")
                if php_max != "-":
                    self.assertLessEqual(
                        vkey(version), vkey(php_max),
                        f"ext.json says {e['name']} supports PHP {version}, but {lock_key} "
                        f"({ver}) declares a {php_max} ceiling")
                checked += 1
        self.assertGreater(checked, 0, "no version/package pairs were compared")

    def test_no_floor_is_higher_than_its_package_requires(self):
        """The other direction: a floor raised past what the package needs.

        A floor set too high is invisible to runtime checks: tests/smoke.sh
        derives its expected set from the same constraints, so the expectation
        shrinks in lockstep.

        Two exemptions:
          - a floor equal to the project's lowest version is not an extension
            floor (imagick declares 5.6.0, but nothing here builds PHP 5);
          - an extension with per-version pins has already pinned older releases
            below its default pin, and the test above checks those directly.
        Upper bounds are not checked: `<8.0` on mcrypt is a product decision
        (its package declares support to 8.6.0), and nobody adds an upper bound
        by accident, whereas a pin bump raises floors mechanically.
        """
        rows = self._lock_rows()
        lowest = self.matrix[0]
        checked = 0
        for e in self.exts:
            if e["source"] != "pecl":
                continue
            floor = None
            for clause in (e["php"] or "").split(","):
                clause = clause.strip()
                if clause.startswith(">="):
                    floor = clause[2:]
            if floor is None or vkey(floor) == vkey(lowest):
                continue
            if any((o or {}).get("version") for o in (e.get("overrides") or {}).values()):
                continue
            row = rows.get(e["name"])
            if row is None or row[1] == "-":
                continue
            self.assertEqual(
                vkey(floor), vkey(row[1]),
                f"{e['name']} has an ext.json floor of {floor} but its pinned package "
                f"({row[0]}) declares {row[1]} -- the floor removes it from versions it "
                "would work on, and no era pin says that was intentional")
            checked += 1
        self.assertGreater(checked, 0, "no floors were compared")

    def test_the_lock_declares_a_range_for_every_pecl_row(self):
        # A row without the range columns would make every comparison for that
        # extension skip silently.
        rows = self._lock_rows()
        names = {e["name"] for e in self.exts if e["source"] == "pecl"}
        for line in (ROOT / "php" / "pecl.lock").read_text().splitlines():
            if line.startswith("#") or not line.strip():
                continue
            key = line.split()[0]
            if key.split("@")[0] in names:
                self.assertIn(key, rows, f"pecl.lock row {key} has no php-min/php-max columns")

    def test_era_pins_have_a_matching_lock_row(self):
        # Every overrides.version must resolve to a name@X.Y row in pecl.lock
        # carrying that exact version: a missing row fetches nothing, a
        # mismatched one fetches the wrong release. Failing here is cheaper than
        # failing late in a build.
        lock = (ROOT / "php" / "pecl.lock").read_text().splitlines()
        rows = {}
        for line in lock:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.split()
            if len(parts) >= 3:
                rows[parts[0]] = parts[1]
        self.assertGreater(len(rows), 0, "no rows parsed out of pecl.lock")
        seen = 0
        for e in self.exts:
            for version, override in (e.get("overrides") or {}).items():
                pin = override.get("version")
                if not pin:
                    continue
                key = f"{e['name']}@{version}"
                self.assertIn(key, rows, f"{key} pinned to {pin} but no pecl.lock row")
                self.assertEqual(rows[key], pin, f"{key} disagrees with pecl.lock")
                seen += 1
        self.assertGreater(seen, 0, "no version pins found -- the check measured nothing")

    def test_always_available_extensions_are_on_every_version(self):
        """Every extension marked always_available ships on every PHP version.

        A floor-vs-package comparison cannot catch a floor that equals what the
        pinned package declares yet still drops a version the extension could be
        built for (xdebug declares 8.0.0, so a >=8.0 floor looks correct). The
        capability is asserted instead. `always_available` in ext.json says
        "every image carries this one, whatever the pins do", and it is read
        from the registry so a new must-have needs no test edit.
        """
        required = [e["name"] for e in self.exts if e.get("always_available")]
        self.assertGreater(len(required), 0,
                           "no extension is marked always_available -- this test would "
                           "pass having checked nothing")
        for version in self.matrix:
            shared = subprocess.run(
                ["bash", str(ROOT / "php" / "build-shared-ext.sh"), "--list", version],
                capture_output=True, text=True, check=True,
            ).stdout.split()
            for name in required:
                self.assertIn(name, shared,
                              f"PHP {version} does not ship {name}, which ext.json marks "
                              "always_available")


class TestSnuffleupagusRules(unittest.TestCase):
    """The rulesets vendor upstream's config/default.rules for one tag.

    A newer module under an older ruleset looks fine and is not: v0.14.0 fixed
    mail()'s 8.0 argument name, which v0.13.0's rules leave unguarded on 8.0-8.2.
    """

    RULES = ROOT / "conf" / "snuffleupagus"
    BLOCK = re.compile(r"# =+ BEGIN upstream =+\n(.*?)# =+ END upstream =+\n", re.S)

    def built_tag(self):
        e = next(x for x in json.loads(EXT.read_text())["extensions"] if x["name"] == "snuffleupagus")
        m = re.search(r"/tags/(v[0-9.]+)\.tar\.gz$", e["url"])
        self.assertIsNotNone(m, e["url"])
        return m.group(1)

    def test_rules_name_the_built_tag(self):
        tag = self.built_tag()
        header = (self.RULES / "default.rules").read_text()
        self.assertTrue(f"snuffleupagus/{tag}/config/default.rules" in header,
                      f"php/ext.json builds snuffleupagus {tag} but default.rules vendors another "
                      "tag -- re-sync the rulesets (procedure in default.rules' header)")
        for p in sorted(self.RULES.glob("*.rules")):
            self.assertTrue(f"DIVERGENCES FROM UPSTREAM {tag}" in p.read_text(), f"{p.name} still names another tag")

    def test_four_rulesets_share_one_upstream_block(self):
        blocks = {p.name: self.BLOCK.search(p.read_text()) for p in sorted(self.RULES.glob("*.rules"))}
        self.assertEqual(len(blocks), 4)
        for name, m in blocks.items():
            self.assertIsNotNone(m, f"{name} has no BEGIN/END upstream block")
        first = blocks["default.rules"].group(1)
        for name, m in blocks.items():
            self.assertTrue(m.group(1) == first, f"{name}'s upstream block drifted from default.rules'")


class TestConfigureArgs(unittest.TestCase):
    def run_args(self, version, *extra):
        out = subprocess.run(["bash", str(ARGS), version, *extra],
                             capture_output=True, text=True, check=True)
        return out.stdout.split()

    def test_85_omits_the_opcache_flag_php_85_removed(self):
        # 8.5 UPGRADING: opcache is always built in and --enable-opcache was
        # removed, so emitting it aborts --enable-option-checking=fatal.
        self.assertNotIn("--enable-opcache", self.run_args("8.5"))

    def test_84_and_below_still_get_the_opcache_flag(self):
        for version in ("7.0", "8.4"):
            self.assertIn("--enable-opcache", self.run_args(version))

    def test_core_filter_drops_pecl_flags_and_keeps_core_ones(self):
        # A core-only build has no pecl sources in ext/, and an unknown flag is
        # fatal under --enable-option-checking=fatal.
        args = self.run_args("8.5", "core")
        self.assertIn("--enable-bcmath", args)
        self.assertIn("--enable-fpm", args)
        for flag in ("--enable-redis", "--with-imagick", "--enable-apcu"):
            self.assertNotIn(flag, args)

    def test_pecl_filter_keeps_only_pecl_flags(self):
        args = self.run_args("8.5", "pecl")
        self.assertIn("--enable-redis", args)
        self.assertNotIn("--enable-bcmath", args)

    def test_all_filter_includes_both_core_and_pecl_flags(self):
        # pecl sources are unpacked into ext/ before buildconf, so the real
        # build renders "all" (build.sh's EXT_SOURCES default).
        args = self.run_args("8.5", "all")
        self.assertIn("--enable-bcmath", args)
        for flag in ("--enable-redis", "--enable-redis-igbinary",
                     "--enable-redis-zstd", "--enable-igbinary",
                     "--enable-zstd", "--enable-memcached", "--enable-apcu"):
            self.assertIn(flag, args)

    def test_imagick_points_at_the_vendored_imagemagick_prefix(self):
        # Bare --with-imagick searches /usr, /usr/local, /opt, ..., none of which
        # holds the vendored ImageMagick; an explicit DIR makes imagick's
        # config.m4 find MagickWand-config directly instead of falling through
        # to its pkg-config path (which clobbers PKG_CONFIG_PATH when no DIR is
        # given).
        args = self.run_args("8.5", "all")
        self.assertIn("--with-imagick=/opt/imagemagick", args)

    def test_unknown_source_filter_is_rejected(self):
        out = subprocess.run(["bash", str(ARGS), "8.5", "nonsense"],
                             capture_output=True, text=True)
        self.assertNotEqual(out.returncode, 0)

    def test_85_includes_core_static_flags(self):
        args = self.run_args("8.5")
        self.assertIn("--enable-bcmath", args)
        self.assertIn("--enable-intl", args)
        self.assertIn("--with-openssl", args)

    def test_85_excludes_seven_only_extensions(self):
        args = " ".join(self.run_args("8.5"))
        self.assertNotIn("mcrypt", args)
        self.assertNotIn("xmlrpc", args)

    def test_85_excludes_shared_extensions(self):
        args = " ".join(self.run_args("8.5"))
        self.assertNotIn("--with-ffi", args)
        self.assertNotIn("--with-tidy", args)

    def test_70_excludes_sodium(self):
        # sodium landed in 7.2
        self.assertNotIn("--with-sodium", self.run_args("7.0"))

    def test_both_sapis_always_requested(self):
        for version in ("7.0", "8.5"):
            args = self.run_args(version)
            self.assertIn("--enable-fpm", args)
            self.assertIn("--enable-cli", args)

    def test_gd_uses_the_legacy_flag_form_below_74(self):
        args = " ".join(self.run_args("7.0"))
        self.assertIn("--with-gd", args)
        self.assertIn("--with-jpeg-dir=/usr", args)
        self.assertNotIn("--enable-gd", args)

    def test_gd_uses_the_modern_flag_form_from_74(self):
        for version in ("7.4", "8.5"):
            args = " ".join(self.run_args(version))
            self.assertIn("--enable-gd", args)
            self.assertNotIn("--with-jpeg-dir", args)

    def test_zip_uses_the_legacy_flag_form_below_74(self):
        args = " ".join(self.run_args("7.0"))
        self.assertIn("--enable-zip", args)
        self.assertNotIn("--with-zip", args)

    def test_zip_uses_the_modern_flag_form_from_74(self):
        for version in ("7.4", "8.5"):
            args = " ".join(self.run_args(version))
            self.assertIn("--with-zip", args)
            self.assertNotIn("--enable-zip", args)

    def test_argon2_is_omitted_below_72(self):
        # Argon2 landed in 7.2; 7.0 and 7.1 register no such option, and
        # --enable-option-checking=fatal makes an unknown flag a configure error.
        for version in ("7.0", "7.1"):
            self.assertNotIn("--with-password-argon2", self.run_args(version))

    def test_argon2_is_requested_from_72(self):
        for version in ("7.2", "7.4", "8.0", "8.5"):
            self.assertIn("--with-password-argon2", self.run_args(version))

    def test_icu_dir_is_requested_on_70_only(self):
        # 7.0's PHP_SETUP_ICU has no pkg-config branch (it shells out to
        # icu-config, which trixie does not ship), so only 7.0 must be told where
        # the vendored ICU is. 7.1+ use pkg-config only when --with-icu-dir is
        # absent; passing it there would route them into the legacy branch.
        self.assertIn("--with-icu-dir", self.run_args("7.0"))
        for version in ("7.1", "7.3", "7.4", "8.0", "8.5"):
            self.assertNotIn("--with-icu-dir", self.run_args(version))


if __name__ == "__main__":
    unittest.main()
