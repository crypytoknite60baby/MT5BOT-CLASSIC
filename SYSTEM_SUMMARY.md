# WEMADEIT — System Summary & Scale-Up Roadmap

**Date:** 2026-05-25
**Bot:** WEMADEIT.mq5 → WEMADEIT_dev.mq5 (v1.01)
**Target Instrument:** XAUUSD (Gold)
**Target Return:** 10–15% monthly, max 20% drawdown

---

## 1. What Has Been Built

### 1.1 The Production Line

| File | Lines | Role | Status |
|------|-------|------|--------|
| `WEMADEIT.mq5` | 819 | Production EA (v1.00 — original) | Live |
| `WEMADEIT_dev.mq5` | 963 | Development EA (v1.01 — gold-tuned + monitor) | **Active dev target** |
| `GoldMonitor.mqh` | 616 | Real-time diagnostics include | Wired into dev |
| `WEMADEIT_Watcher.mq5` | 636 | Standalone chart watcher script | Ready to attach |
| `TelegramBot.mqh` | 191 | Telegram notification sender | Wired into both |
| `ProfitMaximizer.mqh` | 342 | ADX-based regime detection + trailing | Exists, **not yet wired** |
| `OnnxModel.mqh` | 68 | ONNX ML inference wrapper | Exists, **not yet wired** |
| `new_strategy.mq5` | 1153 | Experimental patterns (Judas Swing, CE, IFVG) | Merge one-at-a-time |

### 1.2 Supporting Files

| File | Role |
|------|------|
| `GOLD_UPGRADE_PLAN.md` | Full upgrade strategy, guardrails, timeline |
| `monitor_config.json` | Tunable thresholds for monitoring + Telegram |
| `AGENTS.md` | Agent context — canonical files + monitoring docs |
| `state/backlog.json` | Upgrade backlog tracker |
| `state/last_run.json` | Last Hermes cron run state |
| `train_regime_model.py` | ML regime classifier training pipeline |
| `regime_classifier.onnx` | Trained ONNX model (unused) |

---

## 2. Architecture — How It All Fits Together

```
┌─────────────────────────────────────────────────────────────┐
│                     MT5 TERMINAL                            │
│                                                             │
│  ┌─────────────────────────────────┐  ┌──────────────────┐  │
│  │   WEMADEIT_dev.mq5 (EA)        │  │ WEMADEIT_Watcher │  │
│  │   Chart: XAUUSD H1             │  │ (standalone)     │  │
│  │                                │  │ Attach any chart │  │
│  │  ┌─────────────────────────┐   │  │                  │  │
│  │  │ GoldMonitor.mqh (incl.) │   │  │ Scans positions  │  │
│  │  │  - Connection check/tick│   │  │ Checks SL/TP     │  │
│  │  │  - Spread anomaly       │   │  │ Broker status    │  │
│  │  │  - Bad SL/TP detection  │   │  │ On-chart label   │  │
│  │  │  - Signal perf tracking │   │  │                  │  │
│  │  │  - Auto-disable <30%WR  │   │  └────────┬─────────┘  │
│  │  │  - Drawdown monitoring  │   │           │             │
│  │  └────────────┬────────────┘   │           │             │
│  │               │               │           │             │
│  │  ┌────────────┴────────────┐  │  ┌────────┴─────────┐  │
│  │  │   TelegramBot.mqh       │  │  │  TelegramBot.mqh │  │
│  │  │   (WebRequest API)      │  │  │  (same class)    │  │
│  │  └────────────┬────────────┘  │  └────────┬─────────┘  │
│  └───────────────┼───────────────┘           │             │
│                  │                          │             │
│                  └──────────┬───────────────┘             │
│                             │                            │
│                    ┌────────┴────────┐                   │
│                    │   Telegram API  │                   │
│                    │  api.telegram   │                   │
│                    │  .org           │                   │
│                    └────────┬────────┘                   │
│                             │                            │
│                    ┌────────┴────────┐                   │
│                    │   Your Phone   │                   │
│                    │  @Solomon_     │                   │
│                    │  Defi12         │                   │
│                    └─────────────────┘                   │
└─────────────────────────────────────────────────────────────┘
```

### Message Flow

```
EVERY TICK → MonitorCheckConnection() → spread anomaly?
                                            ↓ yes → Telegram CRIT alert
EVERY NEW BAR → OnNewBar() → entry logic → trade opens?
                                              ↓ yes → Telegram 🟢/🔴 entry
                                              ↓ no → ManagePositions() → breakeven/trail
EVERY 300s → MonitorPeriodicCheck() → drawdown? bad SL/TP? stale pos?
                                        ↓ yes → Telegram 🚨/🛑 alert
TRADE CLOSE → TrackClosedTrades() → PnL recorded → Telegram ✅/❌ exit
```

---

## 3. What Was Fixed (Critical Bugs)

| Bug | File | Before | After |
|-----|------|--------|-------|
| `consecutive_losses` never updates | `WEMADEIT.mq5` | Dead variable — no code increments it | `TrackClosedTrades()` in OnTick reads deal history, updates on close |
| `daily_profit` never updates | `WEMADEIT.mq5` | Same — dead variable | Same fix — accumulated from closed deal profits |
| `partial_taken` never resets | `WEMADEIT.mq5` | Stays `true` after full close → next trade skips partial TP | Reset to `false` on every full position close |
| Spread filter uses `_Point` | `WEMADEIT.mq5` | `(ask-bid)/_Point` = correct for 5-digit forex, wrong for gold's 2-digit | Gold-safe check with adjusted MinSpreadPoints (25→80) |
| `NYOpen_End` minute logic | `WEMADEIT.mq5` | `hour==NYOpen_End && minute<=0` — always true at that hour | `hour==NYOpen_End && minute>=0 && minute<=30` |
| Cooldown after 2 losses | `WEMADEIT.mq5` | Dead code — never triggers | Now triggers: `consecutive_losses >= 2 → 4h cooldown` |
| Daily loss limit 7% | `WEMADEIT.mq5` | Dead code — `daily_profit` never decremented | Now triggers: `daily_profit < -daily_loss_limit → stop trading` |

---

## 4. What Was Tuned for Gold

| Parameter | Old Value | New Value | Why |
|-----------|-----------|-----------|-----|
| `RiskPercent` | 1.5% | 1.0% | Gold volatility 3-5× higher than forex |
| `RR_Ratio` | 3.0 | 2.0 | Gold rarely hits 3R without retracing |
| `Slippage` | 5 pts | 50 pts | Gold moves $2-10 in seconds |
| `MinSpreadPoints` | 25 | 80 | Gold spread naturally 0.30-0.80 |
| `FVG_ReactionDistance` | 0.3 ATR | 0.5 ATR | Gold wicks deeper |
| `PumpBodyATR` | 1.2 | 1.5 | Avoid false pumps in volatility |
| `AntiFlipMinutes` | 30 | 60 | Gold whipsaws more |
| `MaxDailyTrades` | 8 | 4 | Quality over quantity |
| `MaxTradesPerSession` | 6 | 3 | Gold beats you up in choppy sessions |
| `HRLR_StopMultiplier` | 2.0 | 2.5 | HRLR on gold is extremely choppy |
| Gold-NY Overlap zone | — | 13-16 UTC | Best gold liquidity window added |

---

## 5. Scale-Up Roadmap

### Phase A — Go Live with Monitoring (Week 1-2)

```
[ ] Compile WEMADEIT_dev.mq5 in MT5 MetaEditor
[ ] Add https://api.telegram.org to WebRequest allowlist
[ ] Attach WEMADEIT_dev.mq5 to XAUUSD H1 chart
[ ] Attach WEMADEIT_Watcher.mq5 to any chart
[ ] Verify Telegram alerts arrive for:
    - Trade entries/exits
    - Account drawdown >7%
    - Spread anomalies
    - Broker disconnects
[ ] Run 5 days demo — collect Journal logs
[ ] Patch any issues found in live Journal
```

### Phase B — Wire ProfitMaximizer (Week 3-4)

```
[ ] #include "ProfitMaximizer.mqh" in WEMADEIT_dev.mq5
[ ] Replace LRLR/HRLR with DetectMarketRegime() (ADX + ATR ratio)
[ ] Wire OptimizeForMarketRegime() for dynamic risk/ATR/TP
[ ] Wire CalculateMultiStageTrailing() — 3-stage trailing stop
[ ] ExitStagnantTrades() — close trades stuck >48h
[ ] Backtest 12 months XAUUSD — compare vs old LRLR
[ ] Demo 5 days — verify trailing behavior
```

### Phase C — ML Integration (Week 5-6)

```
[ ] Load regime_classifier.onnx in OnTick() via OnnxModel.mqh
[ ] Build 20-bar return feature vector (same as Python training)
[ ] Run inference every 6 hours — classify TRENDING/RANGING/VOLATILE
[ ] Gate entries by regime:
    - RANGING → skip turtle soup + pump catcher
    - VOLATILE → skip entries when spread >1.0, risk ×0.4
    - TRENDING → normal operation, risk ×1.0
[ ] Retrain ONNX: python3 train_regime_model.py
[ ] Demo 7 days with ML-gated vs non-gated A/B test
```

### Phase D — Merge Strategy Edge (Week 7-10)

```
Merge one pattern at a time from new_strategy.mq5:
[ ] Week 7: Consequent Encroachment
[ ] Week 8: Inversion FVG
[ ] Week 9: Judas Swing
[ ] Week 10: Relative Equal Levels
Each merge → backtest 12mo → demo 5 days → commit if passes
```

### Phase E — Automation via Hermes (Week 11-12)

```
[ ] Start Hermes gateway: hermes gateway install
[ ] Install cron jobs: ./scripts/install-hermes-cron.sh
[ ] Verify weekly health checks parse MONITOR/WATCHER tags
[ ] Verify biweekly ONNX retrain pipeline
[ ] Verify rollback triggers (daily loss >7%, 3 consecutive loss days)
[ ] Set up weekly METRICS.md report with Telegram delivery
```

---

## 6. Guardrails — What Prevents Over-Optimization

### Auto-Disabled Signals
Any signal with <30% win rate after 15+ trades is **auto-disabled** by GoldMonitor.mqh. It logs `[MONITOR][WARN][SIGNAL] Auto-disabled "TurtleSoup" — win rate 28% after 18 trades` and stops trading that pattern.

### Health Score (Weekly)
```
Health Score = (WinRate × 0.3) + (AvgRR × 0.2) + (ProfitFactor × 0.3) + (DD_penalty × 0.2)
DD_penalty = 1.0 - (current_drawdown / 20%), capped at 0
If Health Score < 0.4 for 2 consecutive weeks → revert to last known good config
```

### Hard Rollback Triggers
| Condition | Action |
|-----------|--------|
| Daily loss >7% | Stop all trading for 24h, revert last config change |
| Weekly drawdown >12% | Cut risk to 0.5% for next week |
| 3 consecutive losing days | Pause 48h, run backtest of last 3 config changes |
| Monthly return < -5% | Full rollback to last known positive month config |
| Spread >1.50 for >1 hour | Skip all entries until spread normalizes |

### Walk-Forward Requirement
Every change must pass: train on 2024 data → test on 2025 data unchanged. If 2025 performance <60% of 2024 → reject (overfit).

---

## 7. File Inventory

```
THE NEW BOT/
├── WEMADEIT.mq5                    # Production EA — do not edit
├── WEMADEIT_dev.mq5                # Development EA — make all changes here
├── WEMADEIT_Watcher.mq5            # Standalone chart watcher (attach any chart)
├── new_strategy.mq5                # Experimental — merge features one-at-a-time
├── TelegramBot.mqh                 # Telegram notification sender
├── GoldMonitor.mqh                 # Real-time diagnostics include
├── ProfitMaximizer.mqh             # ADX regime detection + trailing (unwired)
├── OnnxModel.mqh                   # ONNX ML inference wrapper (unwired)
├── monitor_config.json             # Threshold config for all monitors
├── GOLD_UPGRADE_PLAN.md            # Full upgrade strategy + guardrails
├── SYSTEM_SUMMARY.md               # ← THIS FILE
├── AGENTS.md                       # Agent context (Hermes)
├── train_regime_model.py           # ML training pipeline
├── regime_classifier.onnx          # Trained ONNX model
├── regime_classes.json             # Class label mappings
├── ML_Regime_Demo.mq5              # Standalone ONNX inference test
│
├── scripts/
│   ├── install-hermes-cron.sh      # Hermes cron installer
│   ├── health_check.py             # Weekly health validator
│   └── newbot-health-check.py      # Structured health check
│
├── state/
│   ├── backlog.json                # Upgrade items tracker
│   └── last_run.json               # Last Hermes run state
│
├── archive/                        # Old versions — do not edit
├── backtests/                      # Backtest results
├── logs/                           # Log output
├── .venv/                          # Python virtualenv for ML
└── Enhanced_Smart_Money_Trader_v*.mq5  # Legacy — do not edit
```

---

## 8. Monitoring Tag Reference

All structured log output follows this format for Hermes to parse:

```
[SOURCE][SEVERITY][TAG][HH:MM:SS] Message
```

| Source | Severity | Tags | Example |
|--------|----------|------|---------|
| `MONITOR` | INFO | `ENTRY`, `WIN`, `LOSS`, `INIT`, `HEALTH` | `[MONITOR][INFO][ENTRY][14:40:00] BUY Entry=3450.20` |
| `MONITOR` | WARN | `SPREAD`, `SIGNAL`, `MARGIN`, `SWAP` | `[MONITOR][WARN][SPREAD][14:32:01] Anomalous spread 85pt` |
| `MONITOR` | ERROR | `RISK`, `EXEC`, `ORDER`, `ORPHAN` | `[MONITOR][ERROR][RISK][14:35:00] Drawdown >7%: 8.2%` |
| `MONITOR` | CRIT | `RISK`, `BROKER`, `NO_SL`, `MARGIN` | `[MONITOR][CRIT][RISK][14:36:00] Drawdown >12%: 14.1%` |
| `WATCHER` | INFO | `POSITIONS`, `DAILY`, `INIT` | `[WATCHER][INFO][POSITIONS][14:40:00] Count: 2` |
| `WATCHER` | WARN | `PENDING`, `SWAP`, `STALE`, `SPREAD` | `[WATCHER][WARN][STALE][14:41:00] Position open 72h` |
| `WATCHER` | ERROR | `STALE`, `BAD_SL`, `BAD_TP`, `MARGIN` | `[WATCHER][ERROR][BAD_SL][14:42:00] BUY SL >= entry` |
| `WATCHER` | CRIT | `NO_SL`, `DAILY_LOSS`, `DRAWDOWN`, `MARGIN`, `BROKER` | `[WATCHER][CRIT][NO_SL][14:43:00] Ticket 123 NO SL!` |
| `BOT` | — | `—` | `[BOT] Sent: 🟢 BUY XAUUSD...` |

---

## 9. Quick Start Checklist

### First Time in MT5

```
1. Open MetaEditor (F4 in MT5)
2. File → Open → WEMADEIT_dev.mq5 → Compile (F7)
3. File → Open → WEMADEIT_Watcher.mq5 → Compile (F7)
4. In MT5: Tools → Options → Expert Advisors
   → Allow WebRequest for: https://api.telegram.org
5. New chart → XAUUSD, H1 timeframe
6. Drag WEMADEIT_dev onto chart → OK
7. New chart → any pair, any timeframe
8. Drag WEMADEIT_Watcher onto chart → OK
```

### Daily Check

```
- Check Telegram for overnight alerts
- Scan MT5 Journal for [MONITOR] and [WATCHER] tags
- Verify on-chart watcher label shows correct positions
```

### Weekly Check

```
- Run: grep "\[MONITOR\]" Journal.log > weekly_monitor_report.txt
- Count WARN/ERROR/CRIT per tag
- Check if any signal was auto-disabled
- Update METRICS.md
- If drawdown >15% → pause upgrades, rollback last config
```
