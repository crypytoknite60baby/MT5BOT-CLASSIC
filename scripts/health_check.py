#!/usr/bin/env python3
"""Automated preflight for THE NEW BOT Hermes upgrade runs."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_DIRS = ["archive", "logs/weekly", "state", "backtests", "scripts"]
REQUIRED_FILES = [
    "WEMADEIT.mq5",
    "UPGRADE_SCHEDULE.md",
    "HERMES_RUNBOOK.md",
    "state/backlog.json",
    "METRICS.md",
    "CHANGELOG.md",
]


def err(msg: str) -> None:
    print(f"FAIL: {msg}")


def ok(msg: str) -> None:
    print(f"OK: {msg}")


def main() -> int:
    errors = 0

    for d in REQUIRED_DIRS:
        p = ROOT / d
        if not p.is_dir():
            err(f"missing directory {d}/")
            errors += 1
        else:
            ok(f"directory {d}/")

    for f in REQUIRED_FILES:
        p = ROOT / f
        if not p.is_file():
            err(f"missing file {f}")
            errors += 1
        else:
            ok(f"file {f}")

    dev = ROOT / "WEMADEIT_dev.mq5"
    prod = ROOT / "WEMADEIT.mq5"
    if not dev.is_file():
        err("WEMADEIT_dev.mq5 missing — copy from WEMADEIT.mq5")
        errors += 1
    else:
        ok("WEMADEIT_dev.mq5 present")

    if prod.is_file():
        text = prod.read_text(encoding="utf-8", errors="replace")
        m = re.search(r'#property\s+version\s+"([^"]+)"', text)
        if m:
            ok(f"WEMADEIT.mq5 version {m.group(1)}")
        else:
            err("WEMADEIT.mq5 has no #property version")
            errors += 1

    backlog_path = ROOT / "state/backlog.json"
    if backlog_path.is_file():
        try:
            data = json.loads(backlog_path.read_text())
            cid = data.get("current_item_id")
            if not cid:
                err("backlog.json missing current_item_id")
                errors += 1
            else:
                ok(f"backlog current_item_id={cid}")
        except json.JSONDecodeError:
            err("backlog.json invalid JSON")
            errors += 1

    venv_python = ROOT / ".venv/bin/python"
    if venv_python.is_file():
        ok(".venv present")
    else:
        err(".venv missing — run: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt")
        errors += 1

    if errors:
        print(f"\n{errors} check(s) failed.")
        return 1
    print("\nAll automated checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
