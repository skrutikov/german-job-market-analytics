#!/usr/bin/env python3
"""Pin both GHCR application images to one tested immutable main-commit tag.

Usage:
    python scripts/release_images.py set-dev <40-character-commit-sha>
    python scripts/release_images.py check-dev <40-character-commit-sha>
    python scripts/release_images.py promote-prod <40-character-commit-sha>
    python scripts/release_images.py check-prod <40-character-commit-sha>
"""

import argparse
import re
from pathlib import Path

import yaml

IMAGE_NAMES = (
    "ghcr.io/skrutikov/german-job-market-analytics",
    "ghcr.io/skrutikov/german-job-market-analytics-airflow",
)
SHA_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
TAG_PATTERN = re.compile(r"(main|dev|sha-[0-9a-f]{40})\Z")
PROJECT_ROOT = Path(__file__).resolve().parent.parent


def release_tag(sha: str) -> str:
    if not SHA_PATTERN.fullmatch(sha):
        raise ValueError("Release SHA must be a full lowercase 40-character Git SHA.")
    return f"sha-{sha}"


def overlay_path(root: Path, environment: str) -> Path:
    if environment not in {"dev", "prod"}:
        raise ValueError(f"Unexpected environment: {environment}")
    return root / "kubernetes" / "overlays" / environment / "kustomization.yaml"


def read_tags(root: Path, environment: str) -> list[str]:
    document = yaml.safe_load(overlay_path(root, environment).read_text())
    images = document.get("images", [])
    if len(images) != len(IMAGE_NAMES):
        raise ValueError(f"{environment}: expected exactly two application images")
    names = tuple(image.get("name") for image in images)
    if set(names) != set(IMAGE_NAMES) or len(set(names)) != len(IMAGE_NAMES):
        raise ValueError(f"{environment}: unexpected or duplicate image names: {names}")
    tags = [image.get("newTag", "") for image in images]
    if any(not isinstance(tag, str) or not TAG_PATTERN.fullmatch(tag) for tag in tags):
        raise ValueError(f"{environment}: invalid image tag in Kustomize overlay")
    return tags


def check(root: Path, environment: str, sha: str) -> None:
    expected = release_tag(sha)
    tags = read_tags(root, environment)
    if tags != [expected, expected]:
        raise ValueError(
            f"{environment}: expected both images at {expected}; found {tags}"
        )


def set_tags(root: Path, environment: str, sha: str) -> bool:
    new_tag = release_tag(sha)
    path = overlay_path(root, environment)
    read_tags(root, environment)  # Reject unexpected images before changing anything.
    before = path.read_text()
    after = before
    for image_name in IMAGE_NAMES:
        pattern = re.compile(
            r"(^[ \t]*- name: "
            + re.escape(image_name)
            + r"[ \t]*\n[ \t]*newTag:[ \t]*)"
            + r"(?:main|dev|sha-[0-9a-f]{40})([ \t]*$)",
            re.MULTILINE,
        )
        after, count = pattern.subn(lambda match: match[1] + new_tag + match[2], after)
        if count != 1:
            raise ValueError(f"{environment}: could not uniquely update {image_name}")
    if after == before:
        return False
    path.write_text(after)
    check(root, environment, sha)
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action", choices=("set-dev", "check-dev", "promote-prod", "check-prod")
    )
    parser.add_argument("sha", help="Full 40-character lowercase main commit SHA")
    parser.add_argument("--root", type=Path, default=PROJECT_ROOT)
    args = parser.parse_args()
    try:
        release_tag(args.sha)
        if args.action == "set-dev":
            changed = set_tags(args.root, "dev", args.sha)
            print(f"dev: {'pinned' if changed else 'already pinned'} to sha-{args.sha}")
        elif args.action == "check-dev":
            check(args.root, "dev", args.sha)
            print(f"dev: both images use sha-{args.sha}")
        elif args.action == "promote-prod":
            # The candidate must be the exact release currently selected for dev.
            check(args.root, "dev", args.sha)
            changed = set_tags(args.root, "prod", args.sha)
            print(
                f"prod: {'promoted' if changed else 'already pinned'} to sha-{args.sha}"
            )
        else:
            check(args.root, "prod", args.sha)
            print(f"prod: both images use sha-{args.sha}")
    except (OSError, ValueError, KeyError, yaml.YAMLError) as exc:
        parser.exit(1, f"ERROR: {exc}\n")


if __name__ == "__main__":
    main()
