#!/usr/bin/env python3
"""Pin the published frontend and rebuild scheduled Docker releases only on changes."""
import json
import os
import re
import time
import urllib.error
import urllib.request
from pathlib import Path


def get_json(url, headers=None):
    request = urllib.request.Request(url, headers=headers or {})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except (urllib.error.URLError, TimeoutError):
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def resolve_frontend(release):
    assets = [
        asset for asset in release.get("assets", [])
        if re.fullmatch(r"openlist-frontend-dist-.+\.tar\.gz", asset["name"])
        and "lite" not in asset["name"]
    ]
    if release.get("draft") or len(assets) != 1:
        raise ValueError("Expected one published, standard frontend archive")
    asset = assets[0]
    digest = asset.get("digest") or ""
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("Published frontend archive is missing a SHA-256 digest")
    url = asset["browser_download_url"]
    if not url.startswith("https://github.com/") or "\n" in url:
        raise ValueError("Unexpected frontend download URL")
    return {
        "frontend_url": url,
        "frontend_sha256": digest.removeprefix("sha256:"),
        "frontend_version": asset["name"].removeprefix("openlist-frontend-dist-").removesuffix(".tar.gz"),
    }


def published_image_labels(image):
    if not re.fullmatch(r"[a-z0-9._-]+/[a-z0-9._-]+", image):
        raise ValueError("Unexpected GHCR image path")
    token = get_json("https://ghcr.io/token?service=ghcr.io&scope=repository:" + image + ":pull")["token"]
    headers = {
        "Authorization": "Bearer " + token,
        "Accept": ",".join([
            "application/vnd.oci.image.index.v1+json",
            "application/vnd.docker.distribution.manifest.list.v2+json",
            "application/vnd.oci.image.manifest.v1+json",
            "application/vnd.docker.distribution.manifest.v2+json",
        ]),
    }
    base = "https://ghcr.io/v2/" + image
    manifest = get_json(base + "/manifests/beta", headers)
    if "manifests" in manifest:
        amd64 = next(item for item in manifest["manifests"]
                     if item.get("platform", {}).get("architecture") == "amd64"
                     and item.get("platform", {}).get("os") == "linux")
        manifest = get_json(base + "/manifests/" + amd64["digest"], headers)
    config = get_json(base + "/blobs/" + manifest["config"]["digest"], headers)
    return config.get("config", {}).get("Labels", {})


def needs_rebuild(event, revision, frontend_sha256, labels):
    return event != "schedule" or (
        labels.get("org.opencontainers.image.revision") != revision
        or labels.get("org.opencontainers.image.frontend.sha256") != frontend_sha256
    )


def main():
    repo = os.environ.get("FRONTEND_REPO") or "v200dd/OpenList-Frontend"
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("Unexpected frontend repository")
    headers = {"Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    release = get_json("https://api.github.com/repos/" + repo + "/releases/tags/edge", headers)
    outputs = resolve_frontend(release)
    event = os.environ.get("GITHUB_EVENT_NAME", "workflow_dispatch")
    labels = {}
    if event == "schedule":
        try:
            labels = published_image_labels(os.environ.get("DOCKER_IMAGE", "v200dd/openlist-git"))
        except (urllib.error.URLError, TimeoutError, ValueError, KeyError, StopIteration) as error:
            print("Image metadata unavailable; rebuild the published frontend:", type(error).__name__)
    outputs["should_build"] = str(needs_rebuild(
        event, os.environ.get("GITHUB_SHA", ""), outputs["frontend_sha256"], labels
    )).lower()
    for key, value in outputs.items():
        if "\n" in value or "\r" in value:
            raise ValueError("Unexpected multiline workflow output")
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as file:
            for key, value in outputs.items():
                file.write(f"{key}={value}\n")
    print(json.dumps(outputs, indent=2))


if __name__ == "__main__":
    main()
