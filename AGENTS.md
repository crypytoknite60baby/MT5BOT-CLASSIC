# THE NEW BOT — Agent context

Hermes and other agents working here must follow `UPGRADE_SCHEDULE.md`, `HERMES_RUNBOOK.md`, and `GOLD_UPGRADE_PLAN.md`.

## Canonical files

| Role | Path |
|------|------|
| Production EA | `WEMADEIT.mq5` |
| Development EA | `WEMADEIT_dev.mq5` (v1.01 — gold-tuned + monitor) |
| Experimental | `new_strategy.mq5` (merge one feature at a time) |
| ML train | `train_regime_model.py`, `.venv/` |
| State | `state/backlog.json`, `state/last_run.json` |
| Monitor include | `GoldMonitor.mqh` |
| Standalone watcher | `WEMADEIT_Watcher.mq5` (attach to any chart) |
| Monitor config | `monitor_config.json` |

## Monitoring system

Two-layer real-time diagnostic system:

### Layer 1 — GoldMonitor.mqh (EA include)
- **Included in** `WEMADEIT_dev.mq5` via `#include "GoldMonitor.mqh"`
- Runs inside the EA's `OnTick()` — connection check EVERY tick
- `MonitorPeriodicCheck()` runs every 300s for deep audits
- Tracks: spread anomalies, slippage, bad SL/TP, stale positions, connection quality, drawdown
- **Auto-disables** signals with <30% win rate after 15+ trades
- Structured Journal output with `[MONITOR][SEV][TAG]` prefix

### Layer 2 — WEMADEIT_Watcher.mq5 (standalone script)
- Attach to ANY MT5 chart — runs independently from the EA
- Scans all positions with the target magic number
- Audits every position for: missing SL, bad SL/TP, price past SL/TP, high swap, stale age
- Checks broker connection, margin level, daily drawdown, pending order staleness
- On-chart label showing account state, current positions, last 3 critical errors
- Optional sound + push notifications for critical alerts
- Logs with `[WATCHER][SEV][TAG]` prefix

### Tag format
```
[MONITOR][ERROR][SPREAD][14:32:01] Anomalous spread — current=85pt, ma=28pt
[MONITOR][CRIT][RISK][14:35:00] Drawdown from peak >12%: 14.2%
[MONITOR][INFO][ENTRY][14:40:00] BUY Entry=3450.20 SL=3442.00 TP=3466.00 Lot=0.10
[WATCHER][CRIT][NO_SL][14:41:00] Ticket 123456 BUY has NO stop loss!
```

### Telegram integration
- `TelegramBot.mqh` — WebRequest-based sender, auto-URL-encodes messages
- **Included in** both `GoldMonitor.mqh` and `WEMADEIT_Watcher.mq5`
- CRITICAL + ERROR severity logs auto-forward to Telegram
- Trade entries → Telegram with 🟢/🔴 emoji, entry/SL/TP/lot/signal
- Trade exits → Telegram with ✅/❌, PnL, RR
- Config token + chat ID in `monitor_config.json` or input params
- **Setup in MT5:** Tools → Options → Expert Advisors → tick "Allow WebRequest for" → add `https://api.telegram.org`

### Health check
- Weekly: parse Journal for `MONITOR` and `WATCHER` tagged entries
- Count WARN/ERROR/CRIT per tag → report in METRICS.md
- If any signal auto-disabled → flag in weekly report
- If drawdown >15% → pause upgrades, rollback last config

## Do not edit

- `archive/*`
- `Enhanced_Smart_Money_Trader_v5*.mq5`, `*_v6*.mq5`, `*_Fixed.mq5`

## Skill

Hermes cron jobs attach skill: `the-new-bot-upgrade` (in `~/.hermes/skills/devops/the-new-bot-upgrade/`).
