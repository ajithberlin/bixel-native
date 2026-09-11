#!/usr/bin/env python3
"""Install a skill folder into goose's global skills directory.

Copies a skill directory (containing SKILL.md) into `~/.agents/skills/<name>`
so goose's native skills extension discovers it immediately. Intended to be run
from the skill-creator workflow inside Bixel Studio.

Usage:
    python3 install_skill.py <path/to/skill-folder> [--name NAME] [--force]
"""
import argparse
import shutil
import sys
from pathlib import Path


def skills_dir() -> Path:
    return Path.home() / ".agents" / "skills"


def main() -> int:
    parser = argparse.ArgumentParser(description="Install a skill into ~/.agents/skills")
    parser.add_argument("skill_folder", help="Directory containing SKILL.md")
    parser.add_argument("--name", help="Install name (defaults to the folder name)")
    parser.add_argument("--force", action="store_true", help="Replace an existing skill")
    args = parser.parse_args()

    source = Path(args.skill_folder).expanduser().resolve()
    if not (source / "SKILL.md").is_file():
        print(f"error: {source} has no SKILL.md", file=sys.stderr)
        return 1

    name = args.name or source.name
    target = skills_dir() / name
    if target.exists():
        if not args.force:
            print(f"error: {target} already exists (use --force to replace)", file=sys.stderr)
            return 1
        shutil.rmtree(target)

    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, target)
    print(f"installed {name} -> {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
