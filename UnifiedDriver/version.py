#!/usr/bin/env python3
"""Canonical package versions and stable tag selection; no network or tag writes."""
import argparse
import os
import plistlib
import re
import subprocess
from pathlib import Path

VERSION = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', re.ASCII)


def parse_version(value):
    if not VERSION.fullmatch(value):
        raise ValueError(f'Invalid stable version: {value!r}')
    return tuple(map(int, value.split('.')))


def next_version(source, tags, commit):
    """Tags contain canonical names and resolved commit SHAs from fetched refs."""
    minimum = parse_version(source)
    stable = []
    for name, sha in tags:
        if name.startswith('v') and VERSION.fullmatch(name[1:]):
            stable.append((parse_version(name[1:]), sha))
    existing = [version for version, sha in stable if sha == commit]
    if existing:
        selected = max(existing)
    elif stable:
        major, minor, patch = max(version for version, _ in stable)
        selected = max(minimum, (major, minor, patch + 1))
    else:
        selected = minimum
    return '.'.join(map(str, selected))


def build_version(source, run_number=None):
    """Use the source build locally; main pushes add the workflow run number."""
    for value in [source] + ([] if run_number is None else [run_number]):
        if not isinstance(value, str) or not re.fullmatch(r'[1-9][0-9]*', value, re.ASCII):
            raise ValueError(f'Invalid positive build number: {value!r}')
    return str(int(source) + (0 if run_number is None else int(run_number)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--override', help='Explicit local/CI package version')
    parser.add_argument('--next', metavar='COMMIT', help='Select next release from fetched tags')
    parser.add_argument('--build', action='store_true', help='Select the bundle build number')
    args = parser.parse_args()
    info = plistlib.loads(Path(__file__).with_name('Info.plist').read_bytes())
    source = info['CFBundleShortVersionString']
    if args.build:
        if args.next or args.override is not None:
            parser.error('--build cannot be combined with version selection')
        main_push = os.environ.get('GITHUB_EVENT_NAME') == 'push' and os.environ.get('GITHUB_REF') == 'refs/heads/main'
        run_number = os.environ.get('GITHUB_RUN_NUMBER', '') if main_push else None
        print(build_version(info['CFBundleVersion'], run_number))
        return
    if args.next:
        if args.override is not None:
            parser.error('--next and --override are mutually exclusive')
        def git(*arguments):
            return subprocess.check_output(['git', *arguments], text=True).strip()
        commit = git('rev-parse', '--verify', args.next + '^{commit}')
        tags = []
        for name in git('tag', '--list').splitlines():
            if name.startswith('v') and VERSION.fullmatch(name[1:]):
                # Peel annotated tags and fail if a stable tag does not resolve to a commit.
                tags.append((name, git('rev-parse', '--verify', 'refs/tags/' + name + '^{commit}')))
        # Tagged reruns keep their reservation, even after newer releases.
        if tags and not any(sha == commit for _, sha in tags):
            highest_tag, highest_commit = max(tags, key=lambda tag: parse_version(tag[0][1:]))
            ancestry = subprocess.run(['git', 'merge-base', '--is-ancestor', highest_commit, commit])
            if ancestry.returncode != 0:
                parser.error(f'Refusing next release: {highest_tag} is not a proven ancestor of {commit}')
        print(next_version(source, tags, commit))
    else:
        version = source if args.override is None else args.override
        parse_version(version)
        print(version)


if __name__ == '__main__':
    main()
