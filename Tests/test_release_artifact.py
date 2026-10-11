"""Keep tag publication tied to a successful build of the exact main commit."""

import copy
import importlib.util
from pathlib import Path
import unittest
from urllib.parse import parse_qs, urlsplit


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/find_release_artifact.py"
SPEC = importlib.util.spec_from_file_location("find_release_artifact", SCRIPT)
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)


class ReleaseArtifactTests(unittest.TestCase):
    def setUp(self):
        self.commit = "a" * 40
        self.repository = "zh0ngtian/SignOs"
        self.run = {
            "id": 100,
            "head_sha": self.commit,
            "head_branch": "main",
            "head_repository": {"full_name": self.repository},
            "event": "push",
            "status": "completed",
            "conclusion": "success",
        }
        self.artifact = {"id": 200, "name": f"SignOs-ci-{self.commit}", "expired": False}
        self.requests = []

    def find(self, runs=None, artifacts=None):
        runs = [self.run] if runs is None else runs
        artifacts = {100: [self.artifact]} if artifacts is None else artifacts

        def get_json(endpoint):
            self.requests.append(endpoint)
            url = urlsplit(endpoint)
            query = parse_qs(url.query)
            page = int(query["page"][0])
            offset = (page - 1) * 100
            if url.path.endswith("/runs"):
                self.assertEqual(query["head_sha"], [self.commit])
                self.assertEqual(query["branch"], ["main"])
                self.assertEqual(query["status"], ["completed"])
                return {"workflow_runs": runs[offset:offset + 100]}
            run_id = int(url.path.split("/")[-2])
            return {"artifacts": artifacts.get(run_id, [])[offset:offset + 100]}

        return RELEASE.find_artifact(self.repository, self.commit, get_json)

    def test_selects_successful_main_build(self):
        self.assertEqual(self.find(), {"run_id": 100, "artifact_id": 200})

    def test_accepts_manual_main_rebuild(self):
        self.run["event"] = "workflow_dispatch"
        self.assertEqual(self.find()["run_id"], 100)

    def test_rejects_wrong_commit_branch_repository_event_or_conclusion(self):
        changes = [
            {"head_sha": "b" * 40},
            {"head_branch": "v1.0.13"},
            {"head_repository": {"full_name": "other/SignOs"}},
            {"event": "pull_request"},
            {"status": "in_progress"},
            {"conclusion": "failure"},
            {"conclusion": "cancelled"},
        ]
        for change in changes:
            with self.subTest(change=change):
                run = {**self.run, **change}
                with self.assertRaisesRegex(ValueError, "Rerun that commit"):
                    self.find(runs=[run])

    def test_rejects_missing_expired_or_wrong_artifacts(self):
        for artifacts in ([], [{**self.artifact, "expired": True}], [{**self.artifact, "name": "other"}]):
            with self.subTest(artifacts=artifacts), self.assertRaisesRegex(ValueError, "No retained IPA"):
                self.find(artifacts={100: artifacts})

    def test_uses_latest_successful_run_with_retained_artifact(self):
        old = {**self.run, "id": 99}
        newer = {**self.run, "id": 101}
        expired = {**self.artifact, "expired": True}
        result = self.find(runs=[old, self.run, newer], artifacts={99: [self.artifact], 100: [self.artifact], 101: [expired]})
        self.assertEqual(result["run_id"], 100)

    def test_paginates_runs_and_artifacts(self):
        invalid = {**self.run, "conclusion": "failure"}
        runs = [copy.deepcopy(invalid) for _ in range(100)] + [self.run]
        artifacts = [{**self.artifact, "name": "unrelated"} for _ in range(100)] + [self.artifact]
        self.assertEqual(self.find(runs, {100: artifacts})["artifact_id"], 200)
        self.assertEqual(len([url for url in self.requests if "page=2" in url]), 2)

    def test_rejects_invalid_repository_and_sha(self):
        for repository, commit in (("invalid", self.commit), (self.repository, "short")):
            with self.subTest(repository=repository, commit=commit), self.assertRaises(ValueError):
                RELEASE.find_artifact(repository, commit, lambda _: self.fail("Unexpected API call"))


if __name__ == "__main__":
    unittest.main()
