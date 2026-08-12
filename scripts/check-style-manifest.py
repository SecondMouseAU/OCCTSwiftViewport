#!/usr/bin/env python3
"""Enforce "if you touch a legacy file, you fix it" for the code-style rollout (#95).

Ported verbatim from OCCTSwift's already-debugged version (#876/PR #878), including its
fix for a real seeding-vs-growing bug found via testing against real git history (see
`read_manifest_at`'s docstring below). Only the manifest path list and this header are
adapted for this repo: no C++ bridge here (pure Metal/SwiftUI viewport library, no OCCT
dependency), so there's a single manifest, not two, and this repo's own `scripts/`
directory is lowercase (matching its pre-existing `scripts/overnight-stress.sh`), unlike
OCCTSwift's capitalized `Scripts/`.

A whole-tree zero-tolerance swift-format/SwiftLint gate would fail every PR against the
1,503 pre-existing swift-format diagnostics already measured across
Sources/OCCTSwiftViewport (52 files, none of which has ever been run through the tool).
Forcing a big-bang fix before any gate can turn on is the outcome the ecosystem's
rollout plan explicitly rejects in favor of gradual adoption: fix what you touch, not
the whole tree at once.

One manifest file holds the exemption list, seeded once on rollout day with every file
that existed then:
  - scripts/style-manifest-swift.txt   (Sources/OCCTSwiftViewport/*.swift)

The rule, checked against the PR's diff relative to a base ref (`origin/main` by
default):
  1. A file NOT on the manifest must already be clean (checked separately, by the
     normal swift-format/swiftlint gate steps -- this script doesn't re-run those
     tools, it only enforces the manifest's own bookkeeping).
  2. A file ON the manifest that appears in the diff must be REMOVED from it in the
     same PR. Leaving it listed while touching it is exactly what this script exists
     to catch -- "touched a legacy file, left it on the exemption list" is a silent
     failure to comply, not a clean pass.
  3. The manifest may only shrink. Comparing HEAD's manifest against the base ref's,
     any entry present at HEAD but absent at the base is a new grandfather-listing,
     which this policy doesn't allow: everything new complies from creation.

Usage:
  scripts/check-style-manifest.py                # compares against origin/main
  scripts/check-style-manifest.py --base <ref>
  scripts/check-style-manifest.py --self-test
"""
import argparse
import subprocess
import sys

MANIFESTS = [
    'scripts/style-manifest-swift.txt',
]


def run(args):
    return subprocess.run(args, capture_output=True, text=True, check=False)


def read_manifest_at(ref, path):
    """The manifest's contents at `ref` ('' for the working tree), as a set of paths,
    or None if the file doesn't exist at that ref.

    None vs. an empty set matters: a manifest that doesn't exist yet at the base ref is
    being seeded by this PR (fine, not a shrink violation); a manifest that exists and
    is empty has genuinely had every entry removed (also fine, same reason). Collapsing
    the two to "empty set" is exactly the bug this distinction exists to avoid -- it's
    what made this script fail against its own seeding PR on first real-git-history run
    (#876), since every entry in a brand-new manifest read as "newly added" relative to
    a base where the file didn't exist at all.
    """
    if ref == '':
        try:
            with open(path, encoding='utf-8') as fh:
                lines = fh.read().splitlines()
        except FileNotFoundError:
            return None
    else:
        result = run(['git', 'show', f'{ref}:{path}'])
        if result.returncode != 0:
            return None
        lines = result.stdout.splitlines()
    return {line.strip() for line in lines if line.strip() and not line.strip().startswith('#')}


def diff_files(base):
    result = run(['git', 'diff', '--name-only', f'{base}...HEAD'])
    if result.returncode != 0:
        print(f'FAIL: git diff against {base} failed: {result.stderr.strip()}', file=sys.stderr)
        sys.exit(2)
    return set(result.stdout.splitlines())


def check(manifest_path, base, changed):
    """Pure logic: given one manifest's base/HEAD contents and the PR's changed-file
    set, return (touched_but_not_removed, newly_added). Both should be empty to pass.
    """
    base_entries = read_manifest_at(base, manifest_path)
    head_entries = read_manifest_at('', manifest_path) or set()

    touched_but_not_removed = sorted(head_entries & changed)
    # base_entries is None exactly when the manifest doesn't exist at the base ref yet:
    # this PR is seeding it, not growing an existing one. Nothing to compare against,
    # so nothing counts as "newly added" -- see read_manifest_at's own docstring.
    newly_added = [] if base_entries is None else sorted(head_entries - base_entries)
    return touched_but_not_removed, newly_added


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--base', default='origin/main', help='ref to diff against (default: origin/main)')
    ap.add_argument('--self-test', action='store_true')
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    changed = diff_files(args.base)
    fail = False
    for manifest_path in MANIFESTS:
        touched, added = check(manifest_path, args.base, changed)
        if touched:
            fail = True
            print(f'FAIL: {manifest_path} still lists {len(touched)} file(s) this PR touches:')
            for f in touched:
                print(f'  {f}')
            print('  Bring each into compliance (swift-format/swiftlint clean) '
                  'and remove it from the manifest in this same PR.')
        if added:
            fail = True
            print(f'FAIL: {manifest_path} grew by {len(added)} entr{"y" if len(added) == 1 else "ies"} '
                  f'not present at {args.base}:')
            for f in added:
                print(f'  {f}')
            print('  New files comply from creation; they do not get grandfathered onto the manifest.')

    if not fail:
        print(f'check-style-manifest: clean against {args.base}')
    return 1 if fail else 0


def self_test():
    """Exercise check() against synthetic manifest snapshots, no real git repo needed."""
    import unittest.mock as mock

    cases = [
        ('untouched legacy file, left alone',
         {'A.swift', 'B.swift'}, {'A.swift', 'B.swift'}, set(),
         [], []),
        ('legacy file touched and removed from the manifest (the compliant fix)',
         {'A.swift', 'B.swift'}, {'B.swift'}, {'A.swift'},
         [], []),
        ('legacy file touched, left on the manifest (the violation this script exists for)',
         {'A.swift', 'B.swift'}, {'A.swift', 'B.swift'}, {'A.swift'},
         ['A.swift'], []),
        ('new file grandfathered onto the manifest (not allowed)',
         {'A.swift'}, {'A.swift', 'C.swift'}, set(),
         [], ['C.swift']),
        ('both violations at once',
         {'A.swift', 'B.swift'}, {'A.swift', 'B.swift', 'C.swift'}, {'A.swift'},
         ['A.swift'], ['C.swift']),
        ('manifest does not exist at base: this PR is seeding it, not growing it (#876)',
         None, {'A.swift', 'B.swift', 'C.swift'}, set(),
         [], []),
    ]

    failed = 0
    for name, base_set, head_set, changed, want_touched, want_added in cases:
        with mock.patch.object(sys.modules[__name__], 'read_manifest_at',
                                side_effect=lambda ref, path, b=base_set, h=head_set:
                                h if ref == '' else b):
            touched, added = check('fake-manifest.txt', 'fake-base', changed)
        ok = touched == want_touched and added == want_added
        failed += not ok
        print(f'  {"ok  " if ok else "MISS"} {name}: touched={touched} added={added}')

    print(f'{len(cases) - failed}/{len(cases)} cases correct')
    return 1 if failed else 0


if __name__ == '__main__':
    import os
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
    sys.exit(main())
