#!/usr/bin/env python3
"""Find a successful main build's retained IPA for the exact release commit."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import urlencode


def github_json(endpoint):
    return json.loads(subprocess.check_output(["gh", "api", endpoint], text=True))


def pages(endpoint, key, get_json):
    separator = "&" if "?" in endpoint else "?"
    page = 1
    while True:
        items = get_json(f"{endpoint}{separator}per_page=100&page={page}")[key]
        yield from items
        if len(items) < 100:
            return
        page += 1


def find_artifact(repository, commit, get_json=github_json):
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
        raise ValueError("Expected OWNER/REPO")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected a full commit SHA")
    query = urlencode({"branch": "main", "head_sha": commit, "status": "completed"})
    endpoint = f"repos/{repository}/actions/workflows/ios-build.yml/runs?{query}"
    runs = sorted(pages(endpoint, "workflow_runs", get_json), key=lambda run: run["id"], reverse=True)
    for run in runs:
        if not (
            run["head_sha"] == commit
            and run["head_branch"] == "main"
            and run["head_repository"]["full_name"].lower() == repository.lower()
            and run["event"] in ("push", "workflow_dispatch")
            and run["status"] == "completed"
            and run["conclusion"] == "success"
        ):
            continue
        endpoint = f"repos/{repository}/actions/runs/{run['id']}/artifacts"
        for artifact in pages(endpoint, "artifacts", get_json):
            if artifact["name"] == f"SignOs-ci-{commit}" and artifact["expired"] is False:
                return {"run_id": run["id"], "artifact_id": artifact["id"]}
    raise ValueError(
        f"No retained IPA from a successful main build for {commit}. "
        "Rerun that commit's main iOS Build Check, then rerun this tag workflow."
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository")
    parser.add_argument("commit")
    args = parser.parse_args()
    result = find_artifact(args.repository, args.commit)
    print(json.dumps(result))
    if output := os.environ.get("GITHUB_OUTPUT"):
        with Path(output).open("a") as stream:
            for key, value in result.items():
                stream.write(f"{key}={value}\n")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary).open("a") as stream:
            stream.write(
                f"Reusing IPA from [verified main build](https://github.com/{args.repository}"
                f"/actions/runs/{result['run_id']}) for `{args.commit}`. No rebuild.\n"
            )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
