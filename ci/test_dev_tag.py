"""ci/dev-tag.sh against a fake regctl holding a dict of tags."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
OLD = "sha256:" + "1" * 64
NEW = "sha256:" + "2" * 64
SHA = "a" * 40
DEST = "r.io/dev:8.5-fpm-" + SHA[:12] + "-amd64"

# `image digest <ref>` prints the tag's digest or fails like regctl does for an absent tag;
# `image copy <src> <dest>` records the move.
FAKE_REGCTL = r"""#!/usr/bin/env bash
echo "$*" >>"$REGCTL_CALLS"
case "$1 $2" in
  "image digest")
    if [ -n "${REGCTL_DOWN:-}" ]; then echo "Error: dial tcp: lookup r.io: no such host" >&2; exit 1; fi
    d="$(jq -er --arg r "$3" '.[$r]' "$REGCTL_TAGS" 2>/dev/null)" || { echo "Error: failed to request manifest $3: not found" >&2; exit 1; }
    echo "$d" ;;
  "image copy") echo "copy $3 $4" >>"$REGCTL_MOVES" ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
"""


class TestDevTag(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="dev-tag-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        os.makedirs(os.path.join(self.tmp, "ci"))
        for f in ("dev-tag.sh", "retry.sh"):
            shutil.copy(os.path.join(HERE, f), os.path.join(self.tmp, "ci", f))
        self.regctl = os.path.join(self.tmp, "regctl")
        with open(self.regctl, "w") as f:
            f.write(FAKE_REGCTL)
        os.chmod(self.regctl, 0o755)
        self.entry = os.path.join(self.tmp, "entry.json")
        with open(self.entry, "w") as f:
            json.dump({"arch": "amd64", "targets": [{"name": "php-8_5-fpm", "tag": "lotuswebagency/php:8.5-fpm"}]}, f)
        out = os.path.join(self.tmp, "out")
        os.makedirs(os.path.join(out, "php-8_5-fpm", "artifact"))
        with open(os.path.join(out, "passed.txt"), "w") as f:
            f.write("php-8_5-fpm\n")
        with open(os.path.join(out, "php-8_5-fpm", "artifact", "amd64"), "w") as f:
            f.write(NEW)
        self.out = out
        self.tags = os.path.join(self.tmp, "tags.json")
        self.moves = os.path.join(self.tmp, "moves")
        self.set_tags({})

    def set_tags(self, tags):
        with open(self.tags, "w") as f:
            json.dump(tags, f)

    def go(self, **extra):
        env = {**os.environ, "GITHUB_SHA": SHA, "DEV_REPO": "r.io/dev", "REGCTL": self.regctl,
               "REGCTL_CALLS": os.path.join(self.tmp, "calls"), "REGCTL_TAGS": self.tags, "REGCTL_MOVES": self.moves,
               "RETRY_DELAYS": "0", **extra}
        env.pop("DEV_TAG_FORCE", None)
        env.update(extra)
        r = subprocess.run(["bash", os.path.join(self.tmp, "ci/dev-tag.sh"), self.entry, self.out], env=env, capture_output=True, text=True)
        moves = []
        if os.path.exists(self.moves):
            with open(self.moves) as f:
                moves = f.read().splitlines()
        return r, moves

    def test_an_absent_tag_is_created(self):
        r, moves = self.go()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(moves, [f"copy r.io/dev@{NEW} {DEST}"])

    def test_a_tag_naming_the_same_digest_is_left_alone(self):
        self.set_tags({DEST: NEW})
        r, moves = self.go()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(moves, [])
        self.assertIn("already is", r.stdout)

    def test_a_tag_naming_another_digest_is_refused(self):
        self.set_tags({DEST: OLD})
        r, moves = self.go()
        self.assertEqual(r.returncode, 1)
        self.assertEqual(moves, [])
        self.assertIn(f"already names {OLD}", r.stderr)
        self.assertIn("rebuild=true", r.stderr)

    def test_force_moves_it(self):
        self.set_tags({DEST: OLD})
        r, moves = self.go(DEV_TAG_FORCE="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(moves, [f"copy r.io/dev@{NEW} {DEST}"])

    def test_only_one_forces(self):
        self.set_tags({DEST: OLD})
        r, moves = self.go(DEV_TAG_FORCE="true")
        self.assertEqual((r.returncode, moves), (1, []))

    def test_an_unreadable_registry_is_not_an_absent_tag(self):
        r, moves = self.go(REGCTL_DOWN="1")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(moves, [])
        self.assertIn("cannot tell whether", r.stderr)


if __name__ == "__main__":
    unittest.main()
