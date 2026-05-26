#!/usr/bin/env python3
"""
Hermes no-agent daily cron: print lines only when attention needed.
Installed copy should live at ~/.hermes/scripts/newbot-health-check.py
"""
from __future__ import annotations

import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path("/Users/samueladjaye/METATRADER 5 MQL5/THE NEW BOT")
METRICS = ROOT / "METRICS.md"
PROD = ROOT / "WEMADEIT.mq5"
LAST_RUN = ROOT / "state/last_run.json"


def main() -> int:
    alerts: list[str] = []

    if not ROOT.is_dir():
        print(f"THE NEW BOT project missing: {ROOT}")
        return 0

    hc = ROOT / "scripts/health_check.py"
    if hc.is_file():
        r = subprocess.run(
            [sys.executable, str(hc)],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            alerts.append("health_check.py failed:\n" + (r.stdout or "") + (r.stderr or ""))

    if METRICS.is_file():
        text = METRICS.read_text(encoding="utf-8", errors="replace")
        weeks = re.findall(r"^## Week (\d{4}-W\d{2})", text, re.MULTILINE)
        if len(weeks) < 2:
            alerts.append("METRICS.md has no completed weekly entries yet.")
    else:
        alerts.append("METRICS.md missing.")

    if PROD.is_file():
        t = PROD.read_text(encoding="utf-8", errors="replace")
        if "compile_pending" in (LAST_RUN.read_text() if LAST_RUN.is_file() else ""):
            pass
        vm = re.search(r'#property\s+version\s+"([^"]+)"', t)
        if not vm:
            alerts.append("WEMADEIT.mq5 missing #property version.")

    if not alerts:
        return 0

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    print(f"THE NEW BOT daily health ({now})\n")
    for a in alerts:
        print(f"- {a.strip()}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
