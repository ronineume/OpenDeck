#!/usr/bin/env python3
"""Mutation-test the review-24 fixes.

For each mutation: copy Sources, break exactly one repair, rebuild, run
--selftest, and report which checks FAIL. A mutation that leaves the suite
green means the corresponding check is hollow.
"""
import os
import re
import shutil
import subprocess
import sys

# Derived from this file's own location (Tools/..), so the script works from any
# checkout path rather than one developer's machine.
PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = "/tmp/ldfix/mut"

MUTATIONS = [
    (
        "M1-empty-pages-rotates-backup",
        "DeckStore.swift",
        "suppressNextBackupRotation = true",
        "suppressNextBackupRotation = false",
        "revert fix 1: let the empty-`pages` rebuild rotate its bogus file over `.bak`",
    ),
    (
        "M2-heal-write-result-ignored",
        "DeckStore.swift",
        "guard (try? seams.writeData(backupData, storeURL)) != nil else {",
        "guard true else { // MUTATION: ignore the recovery write's result",
        "revert fix 2: swallow the failed recovery write (the #29/#30 shape)",
    ),
    (
        "M3-preserve-failure-ignored",
        "DeckStore.swift",
        "if !preserved {",
        "if false { // MUTATION: treat a failed preservation as success",
        "revert #30 in the empty-`pages` branch: rebuild over the only copy anyway",
    ),
    (
        "M4-reconcile-always-saves",
        "DeckStore.swift",
        "if persistedState != stateBefore { save() }",
        "save() // MUTATION: unconditional write",
        "revert fix 6: let the automatic rescan persist a display-driven repack",
    ),
    (
        "M5-every-match-preselected",
        "UninstallView.swift",
        "candidate.matchKind == .identifier",
        "true // MUTATION: pre-select every match",
        "revert fix 3: pre-select name-only (cross-vendor) matches too",
    ),
    (
        "M6-save-writes-when-unchanged",
        "DeckStore.swift",
        """            if let onDisk = try? Data(contentsOf: storeURL), onDisk == data {
                return
            }
""",
        "",
        "revert review-26 fix B: let a no-op save write and rotate the backup anyway",
    ),
    (
        "M7-rotation-after-write",
        "DeckStore.swift",
        """            } else {
                rotateBackup()
            }
            try data.write(to: storeURL, options: .atomic)""",
        """            } else {
            }
            try data.write(to: storeURL, options: .atomic)
            rotateBackup() // MUTATION: rotate the new bytes as the "previous" generation""",
        "break the rotate-before-write order: `.bak` stops being the previous generation",
    ),
    (
        "M8-believe-every-scan",
        "DeckStore.swift",
        """    private func shouldAdoptScan(_ scannedIDs: Set<String>) -> Bool {
        let referenced = referencedAppIDs()""",
        """    private func shouldAdoptScan(_ scannedIDs: Set<String>) -> Bool {
        if true { return true } // MUTATION: believe every scan
        let referenced = referencedAppIDs()""",
        "revert review-26 fix A: adopt a partially failed scan as the truth",
    ),
    (
        "M9-launch-path-unscreened",
        "DeckStore.swift",
        """        let scannedIDs = Set(apps.map { $0.id })
        if !shouldAdoptScan(scannedIDs) { return }""",
        """        let scannedIDs = Set(apps.map { $0.id })
        // MUTATION: leave the launch path unscreened""",
        "revert only the reconcile-side guard: the launch (load) path loses its screen",
    ),
    (
        "M10-one-observation-is-an-uninstall",
        "DeckStore.swift",
        "        unconfirmedAbsent = previous.subtracting(scannedIDs)",
        "        unconfirmedAbsent = [] // MUTATION: believe a single missing observation",
        "revert the per-app rule: one missing scan observation dissolves folders and drops marks",
    ),
]


def build(sources_dir, out):
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    files = sorted(
        os.path.join(root, f)
        for root, _, names in os.walk(sources_dir)
        for f in names
        if f.endswith(".swift")
    )
    cmd = [
        "swiftc", "-sdk", sdk, "-target", "arm64-apple-macosx15.0",
        "-swift-version", "5", "-Onone",
    ] + files + ["-o", out]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return False, result.stderr[-3000:]
    return True, ""


def run(binary):
    result = subprocess.run([binary, "--selftest"], capture_output=True, text=True)
    lines = result.stdout.splitlines()
    fails = [ln for ln in lines if ln.startswith("FAIL")]
    summary = [ln for ln in lines if "checks passed" in ln]
    if not summary:
        # A crash (a trap aborts the process) is itself a signal.
        summary = ["<no summary — process exited %d>" % result.returncode]
    return fails, summary[-1]


def main():
    only = sys.argv[1:] or None
    failures = []
    for name, filename, old, new, why in MUTATIONS:
        if only and name not in only:
            continue
        target = os.path.join(PROJECT, "Sources", "LaunchDeck")
        # Locate the file (paths vary by directory).
        matches = [
            os.path.join(root, f)
            for root, _, names in os.walk(target)
            for f in names
            if f == filename
        ]
        if len(matches) != 1:
            print("!! %s: expected one %s, found %d" % (name, filename, len(matches)))
            failures.append(name)
            continue
        src = matches[0]
        rel = os.path.relpath(src, os.path.join(PROJECT, "Sources"))

        work = os.path.join(WORK, name)
        shutil.rmtree(work, ignore_errors=True)
        os.makedirs(work, exist_ok=True)
        shutil.copytree(os.path.join(PROJECT, "Sources"), os.path.join(work, "Sources"))

        broken = os.path.join(work, "Sources", rel)
        text = open(broken).read()
        if text.count(old) != 1:
            print("!! %s: anchor appears %d time(s), refusing to patch" % (name, text.count(old)))
            failures.append(name)
            continue
        open(broken, "w").write(text.replace(old, new))

        binary = os.path.join(work, "binary")
        ok, err = build(os.path.join(work, "Sources"), binary)
        if not ok:
            print("!! %s: build failed\n%s" % (name, err))
            failures.append(name)
            continue

        fails, summary = run(binary)
        print("=" * 78)
        print("%s\n  %s" % (name, why))
        print("  %s" % summary)
        for line in fails:
            print("  %s" % line[:160])
        if not fails:
            print("  ★★ MUTATION SURVIVED — the suite is still green; the check is hollow")
            failures.append(name)
        print()
        shutil.rmtree(work, ignore_errors=True)

    print("=" * 78)
    if failures:
        print("MUTATIONS THAT SURVIVED (fix the checks): %s" % ", ".join(failures))
        return 1
    print("ALL MUTATIONS KILLED — every new check has discriminating power")
    return 0


if __name__ == "__main__":
    sys.exit(main())
