import contextlib
import datetime
import io
import json
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ci"))

import ghcr_prune_dev as prune  # noqa: E402

NOW = datetime.datetime(2026, 10, 20, 12, 0, tzinfo=datetime.timezone.utc)
SHA_OLD = "a" * 12
SHA_MID = "b" * 12
SHA_NEW = "c" * 12
_next_id = [1000]


def days_ago(n):
    return (NOW - datetime.timedelta(days=n)).strftime("%Y-%m-%dT%H:%M:%SZ")


def version(tags, age, name=None):
    _next_id[0] += 1
    return {
        "id": _next_id[0],
        "name": name or "sha256:%064x" % _next_id[0],
        "created_at": days_ago(age),
        "updated_at": days_ago(age),
        "metadata": {"container": {"tags": tags}},
    }


def sha_set(tag, sha, age):
    """The three versions a target leaves behind for one commit: list + 2 per-arch."""
    return {
        "list": version([f"{tag}-{sha}"], age),
        "amd64": version([f"{tag}-{sha}-amd64"], age),
        "arm64": version([f"{tag}-{sha}-arm64"], age),
    }


def no_children(_digest):
    return set()


def ids(pairs):
    return {v["id"] for v, _ in pairs}


class TestTags(unittest.TestCase):
    def test_parse_tag(self):
        self.assertEqual(prune.parse_tag(f"8.5-fpm-{SHA_NEW}"), ("8.5-fpm", SHA_NEW, None))
        self.assertEqual(prune.parse_tag(f"8.4-cli-builder-v3-{SHA_NEW}-arm64"),
                         ("8.4-cli-builder-v3", SHA_NEW, "arm64"))
        self.assertIsNone(prune.parse_tag("8.5-fpm"))
        self.assertIsNone(prune.parse_tag("8.4-cli-builder-v3"))
        self.assertIsNone(prune.parse_tag("8.5-ext-builder"))
        self.assertIsNone(prune.parse_tag("8.5-fpm-" + "c" * 11))
        self.assertIsNone(prune.parse_tag("8.5-fpm-" + "g" * 12))

    def test_only_the_dev_package_is_addressable(self):
        self.assertIn("php%2Fdev", prune.package_url())
        with self.assertRaises(SystemExit):
            prune.package_url(package="php/corpus")
        with self.assertRaises(SystemExit):
            prune.package_url(org="someone-else")


class TestPlan(unittest.TestCase):
    def run_plan(self, versions, children=no_children, days=14):
        return prune.plan(versions, NOW, days, children)

    def test_floating_sha_is_kept_whatever_its_age(self):
        cur = sha_set("8.5-fpm", SHA_OLD, 60)
        cur["list"]["metadata"]["container"]["tags"].append("8.5-fpm")
        other = sha_set("8.4-fpm", SHA_NEW, 1)
        everything = [*cur.values(), *other.values()]
        keep, delete, _ = self.run_plan(everything)
        self.assertEqual(delete, [])
        self.assertEqual(ids(keep), {v["id"] for v in everything})

    def test_stale_sha_with_no_floating_tag_is_deleted_as_a_whole(self):
        floating = sha_set("8.5-fpm", SHA_NEW, 1)
        floating["list"]["metadata"]["container"]["tags"].append("8.5-fpm")
        stale = sha_set("8.5-fpm", SHA_OLD, 30)
        keep, delete, _ = self.run_plan([*floating.values(), *stale.values()])
        self.assertEqual(ids(delete), {v["id"] for v in stale.values()})
        self.assertEqual(ids(keep), {v["id"] for v in floating.values()})

    def test_sha_within_retention_is_kept_even_unfloated(self):
        floating = sha_set("8.5-fpm", SHA_NEW, 1)
        floating["list"]["metadata"]["container"]["tags"].append("8.5-fpm")
        recent = sha_set("8.5-fpm", SHA_MID, 5)
        keep, delete, _ = self.run_plan([*floating.values(), *recent.values()])
        self.assertEqual(delete, [])

    def test_a_sha_is_as_young_as_its_newest_version(self):
        floating = sha_set("8.5-fpm", SHA_NEW, 1)
        floating["list"]["metadata"]["container"]["tags"].append("8.5-fpm")
        half = sha_set("8.5-fpm", SHA_MID, 40)
        half["arm64"] = version([f"8.5-fpm-{SHA_MID}-arm64"], 2)
        _, delete, _ = self.run_plan([*floating.values(), *half.values()])
        self.assertEqual(delete, [])

    def test_retention_days_is_honoured(self):
        floating = sha_set("8.5-fpm", SHA_NEW, 1)
        floating["list"]["metadata"]["container"]["tags"].append("8.5-fpm")
        mid = sha_set("8.5-fpm", SHA_MID, 10)
        _, delete14, _ = self.run_plan([*floating.values(), *mid.values()], days=14)
        _, delete7, _ = self.run_plan([*floating.values(), *mid.values()], days=7)
        self.assertEqual(delete14, [])
        self.assertEqual(len(delete7), 3)

    def test_floating_tags_pointing_at_different_shas_keep_both(self):
        a = sha_set("8.5-fpm", SHA_OLD, 60)
        a["list"]["metadata"]["container"]["tags"].append("8.5-fpm")
        b = sha_set("8.4-fpm", SHA_NEW, 1)
        b["list"]["metadata"]["container"]["tags"].append("8.4-fpm")
        _, delete, _ = self.run_plan([*a.values(), *b.values()])
        self.assertEqual(delete, [])

    def test_newest_sha_is_kept_when_no_floating_tag_exists(self):
        old = sha_set("8.5-fpm", SHA_OLD, 90)
        newest = sha_set("8.5-fpm", SHA_NEW, 30)
        keep, delete, _ = self.run_plan([*old.values(), *newest.values()])
        self.assertEqual(ids(delete), {v["id"] for v in old.values()})
        self.assertEqual(ids(keep), {v["id"] for v in newest.values()})

    def test_floating_version_without_a_sha_tag_is_kept_and_noted(self):
        lone = version(["8.5-fpm"], 90)
        keep, delete, notes = self.run_plan([lone])
        self.assertEqual(delete, [])
        self.assertEqual(len(notes), 1)

    def test_untagged_versions(self):
        floating = sha_set("8.5-fpm", SHA_NEW, 1)
        floating["list"]["metadata"]["container"]["tags"].append("8.5-fpm")
        fresh = version([], 3)
        old_unreferenced = version([], 30)
        old_referenced = version([], 30)
        children = {floating["list"]["name"]: {old_referenced["name"]}}
        asked = []

        def children_of(digest):
            asked.append(digest)
            return children.get(digest, set())

        everything = [*floating.values(), fresh, old_unreferenced, old_referenced]
        keep, delete, _ = self.run_plan(everything, children_of)
        self.assertEqual(ids(delete), {old_unreferenced["id"]})
        self.assertIn(fresh["id"], ids(keep))
        self.assertIn(old_referenced["id"], ids(keep))
        self.assertEqual(sorted(asked), sorted(v["name"] for v in floating.values()),
                         "every kept tagged version is asked, a per-arch push can be an index too")

    def test_children_of_a_deleted_list_do_not_protect_an_untagged_version(self):
        floating = sha_set("8.5-fpm", SHA_NEW, 1)
        floating["list"]["metadata"]["container"]["tags"].append("8.5-fpm")
        stale = sha_set("8.5-fpm", SHA_OLD, 30)
        orphan = version([], 30)
        children = {stale["list"]["name"]: {orphan["name"]}}
        _, delete, _ = self.run_plan([*floating.values(), *stale.values(), orphan],
                                     lambda d: children.get(d, set()))
        self.assertIn(orphan["id"], ids(delete))

    def test_unresolvable_children_keep_every_untagged_version(self):
        floating = sha_set("8.5-fpm", SHA_NEW, 1)
        floating["list"]["metadata"]["container"]["tags"].append("8.5-fpm")
        old = version([], 30)

        def boom(_digest):
            raise RuntimeError("registry unreachable")

        keep, delete, notes = self.run_plan([*floating.values(), old], boom)
        self.assertEqual(delete, [])
        self.assertIn(old["id"], ids(keep))
        self.assertEqual(len(notes), 1)

    def test_children_are_not_resolved_when_no_untagged_version_is_old(self):
        floating = sha_set("8.5-fpm", SHA_NEW, 1)
        floating["list"]["metadata"]["container"]["tags"].append("8.5-fpm")

        def boom(_digest):
            raise AssertionError("not needed")

        keep, delete, _ = self.run_plan([*floating.values(), version([], 2)], boom)
        self.assertEqual(delete, [])


class TestIo(unittest.TestCase):
    def test_paginated_gh_output_is_concatenated_arrays(self):
        page1 = json.dumps([{"id": 1}, {"id": 2}])
        page2 = json.dumps([{"id": 3}])
        result = mock.Mock(stdout=page1 + "\n" + page2 + "\n")
        with mock.patch.object(prune.subprocess, "run", return_value=result):
            self.assertEqual([v["id"] for v in prune.gh_json_pages(["x"])], [1, 2, 3])

    def test_registry_children(self):
        raw = json.dumps({"manifests": [{"digest": "sha256:aa"}, {"digest": "sha256:bb"}]})
        with mock.patch.object(prune.subprocess, "run", return_value=mock.Mock(stdout=raw)) as run:
            self.assertEqual(prune.registry_children("sha256:cc"), {"sha256:aa", "sha256:bb"})
        self.assertIn("ghcr.io/lotuswebagency/php/dev@sha256:cc", run.call_args[0][0])
        with mock.patch.object(prune.subprocess, "run", return_value=mock.Mock(stdout='{"layers": []}')):
            self.assertEqual(prune.registry_children("sha256:dd"), set())

    def test_dry_run_deletes_nothing(self):
        floating = sha_set("8.5-fpm", SHA_NEW, 1)
        floating["list"]["metadata"]["container"]["tags"].append("8.5-fpm")
        stale = sha_set("8.5-fpm", SHA_OLD, 30)
        with mock.patch.object(prune, "list_versions", return_value=[*floating.values(), *stale.values()]), \
                mock.patch.object(prune, "delete_version") as delete:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(prune.main(["--dry-run"], now=NOW), 0)
                delete.assert_not_called()
                self.assertEqual(prune.main([], now=NOW), 0)
            self.assertEqual(delete.call_count, 3)

    def test_delete_goes_to_the_dev_package_only(self):
        with mock.patch.object(prune.subprocess, "run", return_value=mock.Mock(returncode=0, stderr="")) as run:
            prune.delete_version(123)
        cmd = run.call_args[0][0]
        self.assertEqual(cmd[:4], ["gh", "api", "-X", "DELETE"])
        self.assertEqual(cmd[4], "/orgs/LotusWebAgency/packages/container/php%2Fdev/versions/123")


if __name__ == "__main__":
    unittest.main()
