"""Tests for .github/scripts/upgrade_paths.py."""

import contextlib
import io
import json
import runpy
import sys
import unittest
from unittest import mock

from helpers import REPO, load_script

try:
    import yaml  # the script needs it
except ImportError:  # pragma: no cover - CI installs it
    yaml = None

SCRIPT = ".github/scripts/upgrade_paths.py"

ROWS = [
    {"from": "1.0.0", "to": "1.0.1", "strategy": "rolling"},
    {"from": "1.0.1", "to": "2.0.0", "strategy": "stop-start", "pr_smoke": True},
    {"from": "2.0.0", "to": "2.0.1", "strategy": "rolling", "pr_smoke": False},
    {"from": "2.0.1", "to": "2.1.0", "strategy": "rolling", "pr_smoke": True},
]


@unittest.skipUnless(yaml, "PyYAML is not installed")
class UpgradePathsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_script(SCRIPT, "upgrade_paths")

    def run_main(self, argv, rows=ROWS):
        out = io.StringIO()
        with mock.patch.object(self.mod, "ROWS", rows), contextlib.redirect_stdout(out):
            self.mod.main(argv)
        text = out.getvalue()
        self.assertTrue(text.startswith("matrix="), text)
        self.assertTrue(text.endswith("\n"))
        self.assertEqual(text.count("\n"), 1, "one GITHUB_OUTPUT line")
        return json.loads(text[len("matrix=") :])

    def assertExits(self, argv, message, rows=ROWS):
        with (
            mock.patch.object(self.mod, "ROWS", rows),
            self.assertRaises(SystemExit) as cm,
        ):
            self.mod.main(argv)
        self.assertEqual(cm.exception.code, message)

    def test_no_arguments_prints_every_row(self):
        self.assertEqual(self.run_main([]), {"include": ROWS})

    def test_output_is_compact_json(self):
        out = io.StringIO()
        with (
            mock.patch.object(self.mod, "ROWS", ROWS[:1]),
            contextlib.redirect_stdout(out),
        ):
            self.mod.main([])
        self.assertEqual(
            out.getvalue(),
            'matrix={"include":[{"from":"1.0.0","to":"1.0.1","strategy":"rolling"}]}\n',
        )

    def test_pr_smoke_keeps_only_rows_marked_true(self):
        self.assertEqual(self.run_main(["--pr-smoke"]), {"include": [ROWS[1], ROWS[3]]})

    def test_pr_smoke_with_no_marked_rows_is_an_empty_matrix(self):
        self.assertEqual(self.run_main(["--pr-smoke"], rows=ROWS[:1]), {"include": []})

    def test_only_builds_one_row_from_the_arguments(self):
        self.assertEqual(
            self.run_main(["--only", "26.7.5", "26.8.1", "stop-start"]),
            {"include": [{"from": "26.7.5", "to": "26.8.1", "strategy": "stop-start"}]},
        )

    def test_only_with_both_dist_urls(self):
        matrix = self.run_main(["--only", "a", "b", "rolling", "http://f", "http://t"])
        self.assertEqual(
            matrix["include"],
            [
                {
                    "from": "a",
                    "to": "b",
                    "strategy": "rolling",
                    "from_dist_url": "http://f",
                    "dist_url": "http://t",
                }
            ],
        )

    def test_only_with_empty_from_dist_url_keeps_dist_url(self):
        # workflow_dispatch passes empty inputs as empty strings
        matrix = self.run_main(["--only", "a", "b", "rolling", "", "http://t"])
        self.assertEqual(
            matrix["include"],
            [{"from": "a", "to": "b", "strategy": "rolling", "dist_url": "http://t"}],
        )

    def test_only_with_empty_dist_urls_adds_neither(self):
        matrix = self.run_main(["--only", "a", "b", "rolling", "", ""])
        self.assertEqual(
            matrix["include"], [{"from": "a", "to": "b", "strategy": "rolling"}]
        )

    def test_only_with_from_dist_url_alone(self):
        matrix = self.run_main(["--only", "a", "b", "rolling", "http://f"])
        self.assertEqual(
            matrix["include"],
            [
                {
                    "from": "a",
                    "to": "b",
                    "strategy": "rolling",
                    "from_dist_url": "http://f",
                }
            ],
        )

    def test_only_needs_three_arguments(self):
        self.assertExits(["--only", "a", "b"], "--only needs FROM TO STRATEGY")
        self.assertExits(["--only"], "--only needs FROM TO STRATEGY")

    def test_only_refuses_an_empty_required_argument(self):
        self.assertExits(
            ["--only", "a", "", "rolling"], "--only needs FROM TO STRATEGY"
        )

    def test_unknown_arguments_print_the_usage(self):
        self.assertExits(["--nightly"], self.mod.__doc__)
        self.assertExits(["--pr-smoke", "extra"], self.mod.__doc__)

    def test_a_row_without_strategy_is_refused(self):
        bad = [{"from": "1", "to": "2"}]
        self.assertExits([], "row %s lacks ['strategy']" % bad[0], rows=bad)

    def test_missing_keys_are_listed_sorted(self):
        bad = [{"pr_smoke": True}]
        self.assertExits(
            ["--pr-smoke"], "row %s lacks ['from', 'strategy', 'to']" % bad[0], rows=bad
        )

    # The real .github/upgrade-paths.yml, as the workflows read it.

    def test_every_row_of_the_real_file_is_complete(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.mod.main([])
        rows = json.loads(out.getvalue()[len("matrix=") :])["include"]
        self.assertTrue(rows)
        for row in rows:
            self.assertTrue(all(row[k] for k in ("from", "to", "strategy")), row)

    def test_the_real_file_has_pr_smoke_rows(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.mod.main(["--pr-smoke"])
        rows = json.loads(out.getvalue()[len("matrix=") :])["include"]
        self.assertTrue(rows, "pull requests would run no upgrade path")
        self.assertTrue(all(r["pr_smoke"] is True for r in rows))

    def test_runs_as_a_script(self):
        out = io.StringIO()
        argv = [SCRIPT, "--only", "x", "y", "rolling"]
        with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(out):
            runpy.run_path(str(REPO / SCRIPT), run_name="__main__")
        self.assertEqual(
            out.getvalue(),
            'matrix={"include":[{"from":"x","to":"y","strategy":"rolling"}]}\n',
        )


if __name__ == "__main__":
    unittest.main()
