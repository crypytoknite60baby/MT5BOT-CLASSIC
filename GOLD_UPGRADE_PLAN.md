# Gold (XAUUSD) Upgrade Plan — 10–15% Monthly Target

**Date:** 2026-05-25
**Bot:** WEMADEIT.mq5 → WEMADEIT_dev.mq5
**Instrument:** XAUUSD (Gold)
**Target:** 10–15% monthly return, max 20% drawdown

---

## 1. Why Gold Is Different from Forex

The bot was originally designed for forex pairs. Gold (XAUUSD) has fundamentally different characteristics that require specific adaptations.

| Property | Forex (EURUSD) | Gold (XAUUSD) | Impact |
|---|---|---|---|
| Digits | 5 (0.00001) | 2 (0.01) | `_Point` = 0.01 → all pip/point logic breaks |
| H1 ATR | ~15–25 pips | ~$8–15 (800–1500 points) | Stops need 3–5× wider |
| Daily range | ~50–80 pips | ~$30–80 (3000–8000 points) | Much larger moves |
| Spread | 0.5–2 pips | 15–50 points (0.15–0.50) | Spread filter needs 5–10× higher threshold |
| Tick value | ~$1.0 per 0.1 lot | ~$1.0 per 0.01 lot per $1 move | Lot sizing math is different |
| News sensitivity | Moderate | Extreme (CPI, NFP, FOMC, geopolitics) | Need news filter or widen SL on news days |
| Liquidity profile | Even across sessions | Peaks during London-NY overlap | Kill zones need adjustment |
| Liquidity sweeps | Common | Very common (fake breakouts) | Require confirmation before entry |

---

## 2. Critical Bugs to Fix First (Phase A — Stability)

These must be resolved before any strategy changes. Each is a silent killer.

### Bug 1: `consecutive_losses` / `daily_profit` Never Update

**File:** `WEMADEIT.mq5`
**Problem:** Variables are declared but no code ever increments `consecutive_losses` or decrements `daily_profit` on a losing trade. The cooldown-after-2-losses and max-daily-loss-7% checks are dead code — they never trigger.

**Fix:** In `OnTradeTransaction()` or `OnTick()` position-close handler:
```mql5
if(profit < 0) {
    consecutive_losses++;
    last_loss_time = TimeCurrent();
} else {
    consecutive_losses = 0;
}
daily_profit += profit;
```
Also reset `daily_profit` on new trading day.

### Bug 2: Spread Filter Uses `_Point` — Wrong for Gold

**File:** `WEMADEIT.mq5` — `SpreadOK()`
**Problem:** `(ask - bid) / _Point` on gold returns a value in gold-points (0.01 increments). A spread of 0.50 on gold = 50 points, which exceeds the 25-point default filter, blocking all trades.

**Fix:** Use `SymbolInfoInteger(_Symbol, SYMBOL_TRADE_CALC_MODE)` to detect gold, or simply use absolute spread in price terms:
```mql5
// Gold-safe spread check
double spread = ask - bid;
double maxSpread = (StringFind(_Symbol, "XAU") >= 0) ? 0.80 : MinSpreadPoints * _Point;
return spread <= maxSpread;  // 0.80 = 80 points on gold = reasonable
```

### Bug 3: `partial_taken` Not Reset on Full Close

**File:** `WEMADEIT.mq5`
**Problem:** After a full close (both partial and remainder), `partial_taken` stays `true`. Next trade starts with stale state — partial TP logic is skipped.

**Fix:** Reset `partial_taken = false` when `SelectPositionCount() == 0`.

### Bug 4: `NYOpen_End` Minute Check Logic Error

**File:** `WEMADEIT.mq5` — `IsInKillZone()`
**Problem:** The check `hour == NYOpen_End && minute <= 0` means minute ≤ 0 is always true at exactly 10:00, but the condition is logically incomplete for edge cases.

**Fix:** Use explicit range bounds:
```mql5
// NY Open window: 9:30 – 10:00
if(hour == 9 && minute >= 30) return true;
if(hour == 10 && minute == 0) return true;
```

---

## 3. Gold-Specific Parameter Tuning

### Input Parameter Overrides for XAUUSD

| Parameter | Current Default | XAUUSD Recommended | Reason |
|---|---|---|---|
| `RiskPercent` | 1.5% | **1.0%** | Gold volatility is 3-5× higher; 1.5% risks 4.5-7.5% per trade in worst case |
| `RR_Ratio` | 3.0 | **2.0** | Gold often reverses at 1:1.5–2.0; 3.0 rarely gets hit |
| `Slippage` | 5 points | **50 points** | Gold moves fast; 5 points is unrealistically tight |
| `MinSpreadPoints` | 25 | **80** | Gold spread is naturally wider; 25 blocks all trades |
| `FVG_ReactionDistance` | 0.3 ATR | **0.5 ATR** | Gold wicks deeper; need more room |
| `MinimumBodySize` | 0.4 ATR | **0.6 ATR** | Gold has more noise candles |
| `PumpBodyATR` | 1.2 ATR | **1.5 ATR** | Avoid false pump signals in volatility |
| `BreakevenPips` | 12 | **50 (points)** | 12 gold-points is only $0.12 — too small |
| `HRLR_StopMultiplier` | 2.0 | **2.5** | HRLR on gold is extremely choppy |
| `AntiFlipMinutes` | 30 | **60** | Gold whipsaws more; need longer filter |
| `MinHoldBars` | 2 | **3** | Give gold room to breathe before management |
| `MaxDailyTrades` | 8 | **4** | Quality over quantity on gold |
| `MaxTradesPerSession` | 6 | **3** | Gold beats you up in choppy sessions |

### Kill Zones Retuned for Gold

Gold is most active during **London-NY overlap**. Current kill zones are in ET. No change needed for the zone logic itself, but the **session labels** should be mapped to UTC for clarity:

| Label | ET (Current) | UTC Equivalent | Gold Activity |
|---|---|---|---|
| London KZ | 2:00–4:00 | 7:00–9:00 | Medium — London open |
| NY Open | 9:30–10:00 | 14:30–15:00 | **HIGH — best window** |
| Lunch Macro | 11:30– | 16:30– | Medium-high |
| PM Macro | 14:50– | 19:50– | Medium |

**Recommendation:** Add a fifth kill zone specifically for gold during the **London-NY Overlap (13:00–16:00 UTC / 8:00–11:00 ET)**. This is when gold has the tightest spreads and cleanest moves.

---

## 4. Strategy Upgrades for Gold (Phase B — Risk & Edge)

### 4.1 Replace LRLR/HRLR with ProfitMaximizer Regime Detection

**Current:** 10-bar candle overlap ratio → binary LRLR/HRLR. Crude.

**Target:** Wire `ProfitMaximizer.mqh` → `DetectMarketRegime()` which uses:
- **ADX** (14) on H4 → trending (>25) vs ranging (<20)
- **ATR ratio** (current / 20-bar avg) → volatile (>1.5) vs quiet
- **Higher-highs/lower-lows count** → trend strength

Then call `OptimizeForMarketRegime()` to dynamically adjust:
- Trending: risk ×1.1, ATR ×1.2, TP bonus
- Ranging: risk ×0.8, ATR ×0.8, TP reduction
- Volatile: risk ×0.7, ATR ×1.5 (wider stops), TP ×1.0

**Why this matters for gold:** Gold oscillates between trending (news-driven) and ranging (consolidation) rapidly. The current binary LRLR/HRLR cannot distinguish between a quiet trending day and a choppy volatile day. ADX + ATR ratio gives three regimes with appropriate responses.

### 4.2 Multi-Stage Trailing Stop

**Current:** Fixed 12-pip breakeven, no trailing.

**Target:** Wire `CalculateMultiStageTrailing()` from ProfitMaximizer:
- Profit ≥ 0.5R → move SL to breakeven + 5 points
- Profit ≥ 1.0R → trail SL at trailing_step behind price
- Profit ≥ 1.5R → tighter trail (0.7× step)

**Gold rationale:** Gold frequently runs 2–3R before reversing violently. A fixed TP leaves huge money on the table. Trailing captures extended moves while protecting against reversals.

### 4.3 Stagnant Trade Exit

**Current:** No time-based exit. Trades can sit for days.

**Target:** Add `ExitStagnantTrades()` — close any trade that hasn't moved ≥0.3R after `MaxSLBars` (default: 48 H1 bars = 2 days).

**Gold rationale:** Gold can chop sideways for 1–2 days between news events. Sitting in a trade costs swap (gold swap is high: ~$12–20 per lot per day for longs) and ties up capital.

### 4.4 Adaptive Lot Sizing with Confidence Score

**Current:** Fixed risk% × LRLR/HRLR multiplier.

**Target:** Base risk on signal quality:
- 3+ confluent signals → risk ×1.0 (normal)
- 2 confluent signals → risk ×0.7
- 1 signal only → risk ×0.4

Merge this logic from `new_strategy.mq5`'s signal strength scoring (0.0–1.0).

**Gold rationale:** When multiple ICT patterns align on gold (FVG + OB + Liquidity sweep), the probability of success is much higher. Single-pattern entries on gold are low-probability due to noise.

---

## 5. ML Integration (Phase C — Regime Classification)

### Current State
- `train_regime_model.py` trains a LogisticRegression on 20 lagged returns → 3 classes (TRENDING/RANGING/VOLATILE)
- `OnnxModel.mqh` wraps ONNX Runtime for MQL5
- `regime_classifier.onnx` and `regime_classes.json` exist
- **None of this is connected to the EA**

### Integration Plan

1. **In `OnInit()`:** Load `regime_classifier.onnx` via `OnnxModel`
2. **Every hour (or on new bar):** Build 20-bar return array → run inference → get current regime
3. **Use regime to gate entries:**
   - `TRENDING` → allow all signals, risk ×1.0
   - `RANGING` → skip turtle soup & pump catcher, risk ×0.6, shorter TP
   - `VOLATILE` → skip entries entirely when spread > 1.0, risk ×0.4, wider SL
4. **Bi-weekly retraining:** Hermes cron triggers Python retrain → new ONNX file → EA reloads

This replaces the crude LRLR/HRLR with a proper ML-based regime filter.

---

## 6. Merging from new_strategy.mq5 (Phase D — Strategy Edge)

Merge **one pattern at a time** into WEMADEIT_dev.mq5:

| Week | Pattern | Why for Gold |
|---|---|---|
| 1 | **Consequent Encroachment** | Gold often retraces exactly to FVG/OB midpoints before continuing |
| 2 | **Inversion FVG** | Gold frequently breaches then flips FVGs → high-probability continuation |
| 3 | **Judas Swing** | Gold's liquidity sweeps are violent; Judas swing catches the reversal |
| 4 | **Relative Equal Levels** | Gold forms obvious EQH/EQL at psychological price levels ($50 intervals) |

---

## 7. Guardrail System — Tracking What Works vs What Doesn't

### 7.1 Per-Pattern Performance Tracking

Add a struct to track performance by signal type:

```mql5
struct SignalStats {
    string   name;           // "FVG", "OB", "TurtleSoup", etc.
    int      total_trades;
    int      wins;
    int      losses;
    double   total_pnl;
    double   win_rate;       // computed
    double   avg_rr;         // average realized RR
    datetime last_updated;
};
```

On each trade close, log the signal(s) that triggered the entry. Every Sunday, compute stats. If any signal has <20 trades but <30% win rate → **auto-disable** that signal.

### 7.2 Weekly Health Score

Each Sunday at 22:00 ET (Hermes cron), compute:

```
Health Score = (WinRate × 0.3) + (AvgRR × 0.2) + (ProfitFactor × 0.3) + (MaxDD_penalty × 0.2)
```

Where `MaxDD_penalty = 1.0 - (current_drawdown / 20%)`, capped at 0.

**If Health Score < 0.4 for 2 consecutive weeks → revert to last known good configuration and pause new features.**

### 7.3 Configuration Versioning

Each upgrade cycle in `state/backlog.json` stores:

```json
{
  "cycle": 5,
  "date": "2026-06-01",
  "changes": ["Wired ProfitMaximizer trailing", "Fixed spread filter for gold"],
  "performance": {
    "win_rate": 0.62,
    "avg_monthly_return": 8.3,
    "max_drawdown": 11.2,
    "health_score": 0.72
  },
  "previous_config": { ... backup of all changed params ... },
  "rolled_back": false
}
```

### 7.4. Rollback Triggers (Hard Rules)

| Condition | Action |
|---|---|
| Daily loss > 7% | Stop all trading for 24h, revert last config change |
| Weekly drawdown > 12% | Cut risk to 0.5% for next week |
| 3 consecutive losing days | Pause 48h, run backtest of last 3 config changes |
| Monthly return < -5% | Full rollback to last known positive month config |
| Signal has <30% win rate after 15 trades | Auto-disable that signal |
| Spread > 1.50 for >1 hour | Skip all entries until spread normalizes |

### 7.5 Configuration Backup File

Maintain a `config/gold_config_backups.json` with every parameter change. Before each upgrade, snapshot the current working config. If the upgrade degrades performance, restore the snapshot in one click.

### 7.6 Reporting Dashboard (in Journal)

Add structured logging with tags so Hermes can parse performance:

```
[GOLD][ENTRY] FVG+OB | Buy 0.10 | Entry: 3450.20 | SL: 3442.00 | TP: 3466.00 | Regime: TRENDING
[GOLD][EXIT]  Buy 0.10 | PnL: +$124.50 | RR: 2.1R | Signal: FVG+OB | Held: 4h
[GOLD][HEALTH] WinRate: 58% | AvgRR: 1.8 | PFactor: 1.6 | Score: 0.68 | Signals: FVG(4W/2L), OB(3W/3L), TS(1W/4L-DISABLED)
```

---

## 8. Implementation Timeline

| Week | Phase | Deliverable | Verification |
|---|---|---|---|
| 1 | A — Stability | Fix all 4 bugs, retune parameters, test spread filter | Run on demo XAUUSD, verify Journal output |
| 2 | B1 — Risk | Wire ProfitMaximizer trailing + stagnant exit | Backtest 12 months XAUUSD H1 |
| 3 | B2 — Risk | Wire regime detection (replace LRLR/HRLR) | Compare equity curve vs old LRLR method |
| 4 | B3 — Edge | Adaptive lot sizing with signal confidence | Track per-signal win rate |
| 5 | C — ML | Load ONNX in EA, gate entries by regime | A/B test: ML-gated vs non-gated |
| 6 | C — ML | Automate bi-weekly retrain pipeline | Verify ONNX reloads correctly |
| 7 | D1 — Merge | Consequent Encroachment from new_strategy | Backtest on XAUUSD |
| 8 | D2 — Merge | Inversion FVG | Backtest on XAUUSD |
| 9 | D3 — Merge | Judas Swing | Backtest on XAUUSD |
| 10 | D4 — Merge | Relative Equal Levels | Backtest on XAUUSD |
| 11 | E — Validation | Full 24-month walk-forward on XAUUSD | Compare to buy-and-hold |
| 12 | F — Go Live | Demo → live with 0.5% risk, ramp to 1.0% | Monitor health score weekly |

---

## 9. Risk of Over-Optimization (Guardrail)

Every change must pass a **walk-forward test** before going live:

1. Train/optimize on 2024 data
2. Test on 2025 data unchanged
3. If 2025 performance is <60% of 2024 performance → reject the change (overfit)
4. If both pass → run 2026 live/demo for 2 weeks before committing

**Do not optimize parameters for the current market** — gold regimes shift every 4–8 weeks. Optimize for robustness across regimes, not peak performance in one.

---

## 10. Expected Performance Profile

| Metric | Target | Warning Level | Hard Stop |
|---|---|---|---|
| Monthly return | 10–15% | <5% for 2 months | <0% for 1 month |
| Max drawdown | <15% | >15% | >25% |
| Win rate | 50–65% | <40% over 50 trades | <30% over 50 trades |
| Avg RR (realized) | 1.5–2.0R | <1.0R | <0.8R |
| Profit factor | >1.5 | <1.2 | <1.0 |
| Trades/month | 20–40 | >60 (over-trading) | >80 |
| Daily loss limit | 7% | 5% used | 7% hit → 24h stop |

---

## 11. Key Gold-Specific Rules (Summary)

1. **Trade only in London-NY overlap (13:00–17:00 UTC)** for best liquidity — this is the highest-probability window
2. **Skip Non-Farm Payrolls day** (first Friday of month) — gold moves $50+ in minutes
3. **Skip FOMC days** unless 30min after release
4. **Minimum 60-minute cooldown after 2 consecutive losses** (gold revenge-trades destroy accounts)
5. **Wider stops (1.5–2.5 ATR)** — gold wicks deep before reversing
6. **Partial profits at 1.0R, then trail** — gold rarely hits 3R fixed targets without retracing
7. **Never trade against HTF (H4) trend** on gold — trends are stronger and last longer than forex
8. **Monitor DXY correlation** — if DXY gaps or moves sharply, skip gold entries for 30min
9. **Swap cost check** — avoid holding gold longs through Wednesday rollover (triple swap)
10. **Regime-based risk** — cut risk by 40% in volatile regimes, boost by 10% in trending
