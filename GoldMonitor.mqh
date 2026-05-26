//+------------------------------------------------------------------+
//|              GoldMonitor.mqh — Real-time Diagnostics & Watchdog  |
//|              Include this in any EA for self-monitoring          |
//+------------------------------------------------------------------+
#property strict

#include "TelegramBot.mqh"

// --- Global Telegram bot instance
TelegramBot g_telegram;

// --- Monitor configuration (can be overridden by the EA before #include)
#ifndef MONITOR_LOG_TAG
#define MONITOR_LOG_TAG "[MONITOR]"
#endif
#ifndef MONITOR_CHECK_INTERVAL_SEC
#define MONITOR_CHECK_INTERVAL_SEC 300
#endif
#ifndef MONITOR_MAX_SPREAD_ANOMALY
#define MONITOR_MAX_SPREAD_ANOMALY 3.0
#endif
#ifndef MONITOR_MAX_SLIPPAGE_ANOMALY
#define MONITOR_MAX_SLIPPAGE_ANOMALY 50
#endif

// --- Error severity levels
enum ENUM_MONITOR_SEVERITY {
   MON_SEV_INFO,
   MON_SEV_WARN,
   MON_SEV_ERROR,
   MON_SEV_CRITICAL
};

// --- Signal performance tracker
struct SignalPerf {
   string   name;
   int      total;
   int      wins;
   int      losses;
   double   total_pnl;
   double   win_rate;
   double   avg_rr;
   datetime last_updated;
   bool     auto_disabled;
   double   max_drawdown_hit;
};

// --- Error log entry
struct MonitorLogEntry {
   ENUM_MONITOR_SEVERITY severity;
   string                tag;
   string                message;
   double                value;
   datetime              time;
};

// --- Connection quality snapshot
struct ConnectionQuality {
   double   spread;
   double   spread_ma;       // 20-tick moving average spread
   int      consecutive_wide;
   double   slippage_avg;
   int      trade_retries;
   datetime last_off_quote;
   int      off_quote_count;
};

//--- Global monitor state
ConnectionQuality g_mon_conn;
SignalPerf        g_mon_signals[20];
int               g_mon_signal_count;
MonitorLogEntry   g_mon_log[500];
int               g_mon_log_count;
datetime          g_mon_last_check;
bool              g_mon_initialized;
double            g_mon_spread_buffer[20];
int               g_mon_spread_idx;
int               g_mon_trade_sequence;   // increment on each trade attempt
int               g_mon_failed_trades;    // consecutive failed trade attempts
datetime          g_mon_last_tp_hit;
datetime          g_mon_last_sl_hit;
double            g_mon_peak_balance;
double            g_mon_initial_balance;

//+------------------------------------------------------------------+
//| Initialize monitor                                                |
//+------------------------------------------------------------------+
void MonitorInit()
{
   g_mon_initialized = false;
   g_mon_last_check = 0;
   g_mon_signal_count = 0;
   g_mon_log_count = 0;
   g_mon_conn.spread = 0;
   g_mon_conn.spread_ma = 0;
   g_mon_conn.consecutive_wide = 0;
   g_mon_conn.slippage_avg = 0;
   g_mon_conn.trade_retries = 0;
   g_mon_conn.last_off_quote = 0;
   g_mon_conn.off_quote_count = 0;
   g_mon_spread_idx = 0;
   g_mon_trade_sequence = 0;
   g_mon_failed_trades = 0;
   g_mon_last_tp_hit = 0;
   g_mon_last_sl_hit = 0;
   g_mon_initial_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_mon_peak_balance = g_mon_initial_balance;

   MonitorLog(MON_SEV_INFO, "INIT", "GoldMonitor initialized. Balance: " +
      DoubleToString(g_mon_initial_balance, 2));
   g_mon_initialized = true;
}

//+------------------------------------------------------------------+
//| Initialize Telegram bot                                            |
//+------------------------------------------------------------------+
void MonitorInitTelegram(string token, string chat_id)
{
   g_telegram.Init(token, chat_id);
   if(g_telegram.IsReady())
      MonitorLog(MON_SEV_INFO, "TG", "Telegram notifier active");
}

//+------------------------------------------------------------------+
//| Structured logging with severity + tag                             |
//+------------------------------------------------------------------+
void MonitorLog(ENUM_MONITOR_SEVERITY sev, string tag, string msg, double val = 0)
{
   string sev_str = "INFO";
   if(sev == MON_SEV_WARN) sev_str = "WARN";
   else if(sev == MON_SEV_ERROR) sev_str = "ERROR";
   else if(sev == MON_SEV_CRITICAL) sev_str = "CRIT";

   Print(MonHeader(sev_str, tag) + msg + (val != 0 ? " | val=" + DoubleToString(val, 4) : ""));

   if(g_mon_log_count < 500) {
      g_mon_log[g_mon_log_count].severity = sev;
      g_mon_log[g_mon_log_count].tag = tag;
      g_mon_log[g_mon_log_count].message = msg;
      g_mon_log[g_mon_log_count].value = val;
      g_mon_log[g_mon_log_count].time = TimeCurrent();
      g_mon_log_count++;
   }

   if(g_telegram.IsReady() && (sev == MON_SEV_CRITICAL || sev == MON_SEV_ERROR))
      g_telegram.SendAlert(sev_str, tag, msg);
}

string MonHeader(string sev, string tag)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string ts = StringFormat("%02d:%02d:%02d", dt.hour, dt.min, dt.sec);
   return MONITOR_LOG_TAG + "[" + sev + "][" + tag + "][" + ts + "] ";
}

//+------------------------------------------------------------------+
//| Track signal performance (call on trade close)                    |
//+------------------------------------------------------------------+
void MonitorTrackSignal(string signal_name, bool win, double pnl, double rr)
{
   if(!g_mon_initialized) MonitorInit();

   for(int i = 0; i < g_mon_signal_count; i++) {
      if(g_mon_signals[i].name == signal_name) {
         g_mon_signals[i].total++;
         if(win) g_mon_signals[i].wins++;
         else    g_mon_signals[i].losses++;
         g_mon_signals[i].total_pnl += pnl;
         g_mon_signals[i].avg_rr = (g_mon_signals[i].avg_rr * (g_mon_signals[i].total - 1) + rr) / g_mon_signals[i].total;
         g_mon_signals[i].last_updated = TimeCurrent();
         g_mon_signals[i].win_rate = (g_mon_signals[i].total > 0)
            ? (double)g_mon_signals[i].wins / g_mon_signals[i].total : 0;

         // Auto-disable signals below 30% win rate after 15+ trades
         if(!g_mon_signals[i].auto_disabled && g_mon_signals[i].total >= 15
            && g_mon_signals[i].win_rate < 0.30) {
            g_mon_signals[i].auto_disabled = true;
            MonitorLog(MON_SEV_WARN, "SIGNAL", "Auto-disabled signal \"" + signal_name +
               "\" — win rate " + DoubleToString(g_mon_signals[i].win_rate * 100, 1) +
               "% after " + IntegerToString(g_mon_signals[i].total) + " trades");
         }
         return;
      }
   }

   // New signal
   if(g_mon_signal_count < 20) {
      g_mon_signals[g_mon_signal_count].name = signal_name;
      g_mon_signals[g_mon_signal_count].total = 1;
      g_mon_signals[g_mon_signal_count].wins = win ? 1 : 0;
      g_mon_signals[g_mon_signal_count].losses = win ? 0 : 1;
      g_mon_signals[g_mon_signal_count].total_pnl = pnl;
      g_mon_signals[g_mon_signal_count].avg_rr = rr;
      g_mon_signals[g_mon_signal_count].win_rate = win ? 1.0 : 0.0;
      g_mon_signals[g_mon_signal_count].last_updated = TimeCurrent();
      g_mon_signals[g_mon_signal_count].auto_disabled = false;
      g_mon_signals[g_mon_signal_count].max_drawdown_hit = 0;
      g_mon_signal_count++;
   }

   MonitorLog(MON_SEV_INFO, "SIGNAL", signal_name + " | " + (win ? "WIN" : "LOSS") +
      " | PnL=" + DoubleToString(pnl, 2) + " | RR=" + DoubleToString(rr, 2));
}

//+------------------------------------------------------------------+
//| Check if a signal is auto-disabled                                |
//+------------------------------------------------------------------+
bool MonitorIsSignalDisabled(string signal_name)
{
   for(int i = 0; i < g_mon_signal_count; i++) {
      if(g_mon_signals[i].name == signal_name)
         return g_mon_signals[i].auto_disabled;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Connection quality check — run every tick                          |
//+------------------------------------------------------------------+
void MonitorCheckConnection()
{
   if(!g_mon_initialized) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) {
      g_mon_conn.off_quote_count++;
      g_mon_conn.last_off_quote = TimeCurrent();
      if(g_mon_conn.off_quote_count == 1) {
         MonitorLog(MON_SEV_WARN, "CONN", "Off-quote detected (ask=" +
            DoubleToString(ask, 2) + " bid=" + DoubleToString(bid, 2) + ")");
      }
      return;
   }
   g_mon_conn.off_quote_count = 0;

   double spread = ask - bid;
   g_mon_conn.spread = spread;

   // Update rolling spread average
   g_mon_spread_buffer[g_mon_spread_idx % 20] = spread;
   g_mon_spread_idx++;
   int count = MathMin(g_mon_spread_idx, 20);
   double sum = 0;
   for(int i = 0; i < count; i++) sum += g_mon_spread_buffer[i];
   g_mon_conn.spread_ma = (count > 0) ? sum / count : spread;

   // Detect anomalous spread spikes
   if(g_mon_conn.spread_ma > 0 && spread > g_mon_conn.spread_ma * MONITOR_MAX_SPREAD_ANOMALY) {
      g_mon_conn.consecutive_wide++;
      if(g_mon_conn.consecutive_wide == 3) {
         MonitorLog(MON_SEV_WARN, "SPREAD", "Anomalous spread detected — current=" +
            DoubleToString(spread / _Point, 1) + "pt, ma=" +
            DoubleToString(g_mon_conn.spread_ma / _Point, 1) + "pt, ratio=" +
            DoubleToString(spread / g_mon_conn.spread_ma, 1) + "x");
      }
   } else {
      g_mon_conn.consecutive_wide = 0;
   }
}

//+------------------------------------------------------------------+
//| Periodic deep check — run every N seconds                         |
//+------------------------------------------------------------------+
void MonitorPeriodicCheck(int ea_magic, string ea_symbol)
{
   if(!g_mon_initialized) MonitorInit();
   datetime now = TimeCurrent();
   if(now - g_mon_last_check < MONITOR_CHECK_INTERVAL_SEC) return;
   g_mon_last_check = now;

   // 1. Account drawdown check
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance > g_mon_peak_balance) g_mon_peak_balance = balance;
   double dd_from_peak = (g_mon_peak_balance > 0)
      ? (g_mon_peak_balance - equity) / g_mon_peak_balance * 100.0 : 0;
   double dd_from_initial = (g_mon_initial_balance > 0)
      ? (g_mon_initial_balance - equity) / g_mon_initial_balance * 100.0 : 0;

   if(dd_from_peak > 12.0) {
      MonitorLog(MON_SEV_CRITICAL, "RISK", "Drawdown from peak >12%: " +
         DoubleToString(dd_from_peak, 1) + "%");
   } else if(dd_from_peak > 7.0) {
      MonitorLog(MON_SEV_ERROR, "RISK", "Drawdown from peak >7%: " +
         DoubleToString(dd_from_peak, 1) + "%");
   }

   // 2. Position audit
   int ea_positions = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == ea_magic
         && PositionGetString(POSITION_SYMBOL) == ea_symbol) {
         ea_positions++;
         AuditSinglePosition(t, ea_magic);
      }
   }

   // 3. Check for orphaned positions (EA magic but wrong symbol)
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == ea_magic
         && PositionGetString(POSITION_SYMBOL) != ea_symbol) {
         MonitorLog(MON_SEV_WARN, "ORPHAN", "Position on wrong symbol: " +
            PositionGetString(POSITION_SYMBOL) + " ticket=" + IntegerToString(t));
      }
   }

   // 4. Connection quality summary
   if(g_mon_conn.off_quote_count > 0 && now - g_mon_conn.last_off_quote < 60) {
      MonitorLog(MON_SEV_WARN, "CONN", "Recent off-quotes: " +
         IntegerToString(g_mon_conn.off_quote_count) + " at " +
         TimeToString(g_mon_conn.last_off_quote));
   }

   // 5. Risk limit check
   double daily_loss = g_mon_initial_balance - balance;
   double daily_loss_pct = (g_mon_initial_balance > 0)
      ? daily_loss / g_mon_initial_balance * 100.0 : 0;
   if(daily_loss_pct > 5.0) {
      MonitorLog(MON_SEV_ERROR, "RISK", "Daily loss exceeds 5%: " +
         DoubleToString(daily_loss_pct, 1) + "%");
   }

   // 6. Signal performance health report
   string sig_report = "";
   for(int i = 0; i < g_mon_signal_count; i++) {
      if(g_mon_signals[i].total > 0) {
         sig_report += g_mon_signals[i].name + "(" +
            IntegerToString(g_mon_signals[i].wins) + "W/" +
            IntegerToString(g_mon_signals[i].losses) + "L, WR=" +
            DoubleToString(g_mon_signals[i].win_rate * 100, 0) + "%, RR=" +
            DoubleToString(g_mon_signals[i].avg_rr, 1) + ") ";
         if(g_mon_signals[i].auto_disabled) sig_report += "[OFF] ";
      }
   }
   if(sig_report != "") {
      MonitorLog(MON_SEV_INFO, "HEALTH", "Signal stats: " + sig_report);
   }

   // 7. Failed trades alert
   if(g_mon_failed_trades >= 3) {
      MonitorLog(MON_SEV_CRITICAL, "BROKER", IntegerToString(g_mon_failed_trades) +
         " consecutive trade failures — possible broker issue");
   }
}

//+------------------------------------------------------------------+
//| Audit a single position for errors                                |
//+------------------------------------------------------------------+
void AuditSinglePosition(ulong ticket, int ea_magic)
{
   if(!PositionSelectByTicket(ticket)) return;

   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   long type = PositionGetInteger(POSITION_TYPE);
   double vol = PositionGetDouble(POSITION_VOLUME);
   double swap = PositionGetDouble(POSITION_SWAP);
   datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
   double current_price = (type == POSITION_TYPE_BUY)
      ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
      : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // 1. Check for missing SL
   if(sl == 0) {
      MonitorLog(MON_SEV_CRITICAL, "NO_SL", "Position " + IntegerToString(ticket)
         + " has NO stop loss! Entry=" + DoubleToString(entry, 2));
   }

   // 2. Check for missing TP
   if(tp == 0) {
      MonitorLog(MON_SEV_WARN, "NO_TP", "Position " + IntegerToString(ticket)
         + " has NO take profit.");
   }

   // 3. Check if SL/TP are on the wrong side
   if(type == POSITION_TYPE_BUY) {
      if(sl != 0 && sl >= entry)
         MonitorLog(MON_SEV_ERROR, "BAD_SL", "BUY position " + IntegerToString(ticket)
            + " SL >= entry: SL=" + DoubleToString(sl, 2) + " Entry=" + DoubleToString(entry, 2));
      if(tp != 0 && tp <= entry)
         MonitorLog(MON_SEV_ERROR, "BAD_TP", "BUY position " + IntegerToString(ticket)
            + " TP <= entry: TP=" + DoubleToString(tp, 2) + " Entry=" + DoubleToString(entry, 2));
   } else {
      if(sl != 0 && sl <= entry)
         MonitorLog(MON_SEV_ERROR, "BAD_SL", "SELL position " + IntegerToString(ticket)
            + " SL <= entry: SL=" + DoubleToString(sl, 2) + " Entry=" + DoubleToString(entry, 2));
      if(tp != 0 && tp >= entry)
         MonitorLog(MON_SEV_ERROR, "BAD_TP", "SELL position " + IntegerToString(ticket)
            + " TP >= entry: TP=" + DoubleToString(tp, 2) + " Entry=" + DoubleToString(entry, 2));
   }

   // 4. Check if already stopped but position still open (stale)
   if(type == POSITION_TYPE_BUY) {
      if(sl != 0 && current_price <= sl)
         MonitorLog(MON_SEV_WARN, "STALE", "BUY " + IntegerToString(ticket)
            + " price below SL: price=" + DoubleToString(current_price, 2)
            + " sl=" + DoubleToString(sl, 2));
      if(tp != 0 && current_price >= tp)
         MonitorLog(MON_SEV_WARN, "STALE", "BUY " + IntegerToString(ticket)
            + " price above TP: price=" + DoubleToString(current_price, 2)
            + " tp=" + DoubleToString(tp, 2));
   } else {
      if(sl != 0 && current_price >= sl)
         MonitorLog(MON_SEV_WARN, "STALE", "SELL " + IntegerToString(ticket)
            + " price above SL: price=" + DoubleToString(current_price, 2)
            + " sl=" + DoubleToString(sl, 2));
      if(tp != 0 && current_price <= tp)
         MonitorLog(MON_SEV_WARN, "STALE", "SELL " + IntegerToString(ticket)
            + " price below TP: price=" + DoubleToString(current_price, 2)
            + " tp=" + DoubleToString(tp, 2));
   }

   // 5. High swap cost warning
   if(swap < -10.0) {
      MonitorLog(MON_SEV_WARN, "SWAP", "Position " + IntegerToString(ticket)
         + " high swap cost: " + DoubleToString(swap, 2));
   }

   // 6. Stale position (open > 48 hours on H1)
   int bars_open = (int)((TimeCurrent() - ot) / PeriodSeconds(PERIOD_H1));
   if(bars_open > 48) {
      MonitorLog(MON_SEV_WARN, "STALE", "Position " + IntegerToString(ticket)
         + " open for " + IntegerToString(bars_open) + " hours");
   }
}

//+------------------------------------------------------------------+
//| Track trade execution result                                      |
//+------------------------------------------------------------------+
void MonitorTrackTradeResult(MqlTradeRequest &req, MqlTradeResult &res)
{
   g_mon_trade_sequence++;

   if(res.retcode != TRADE_RETCODE_DONE) {
      g_mon_failed_trades++;
      MonitorLog(MON_SEV_ERROR, "EXEC", "Trade failed: retcode=" +
         IntegerToString(res.retcode) + " seq=" + IntegerToString(g_mon_trade_sequence)
         + " | " + req.comment);
   } else {
      g_mon_failed_trades = 0;

      // Check slippage
      if(req.type == ORDER_TYPE_BUY || req.type == ORDER_TYPE_SELL) {
         double slippage_pts = MathAbs(res.price - req.price) / _Point;
         if(slippage_pts > MONITOR_MAX_SLIPPAGE_ANOMALY) {
            MonitorLog(MON_SEV_WARN, "SLIPPAGE", "High slippage: " +
               DoubleToString(slippage_pts, 1) + " pts (max=" +
               IntegerToString(MONITOR_MAX_SLIPPAGE_ANOMALY) + ") | " + req.comment);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Track partial profit events                                       |
//+------------------------------------------------------------------+
void MonitorTrackPartialProfit(double price, double vol, double pnl)
{
   MonitorLog(MON_SEV_INFO, "PARTIAL", "Partial TP hit: price=" +
      DoubleToString(price, 2) + " vol=" + DoubleToString(vol, 2) +
      " pnl=" + DoubleToString(pnl, 2));
}

//+------------------------------------------------------------------+
//| Detect broker-side errors from trade environment                  |
//+------------------------------------------------------------------+
void MonitorCheckBrokerStatus()
{
   // Check if trade is allowed
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) {
      MonitorLog(MON_SEV_CRITICAL, "BROKER", "Trading not allowed by terminal");
   }

   // Check if connected
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) {
      MonitorLog(MON_SEV_CRITICAL, "BROKER", "Not connected to trade server");
   }

   // Check margin level
   double margin_level = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(margin_level > 0 && margin_level < 200) {
      MonitorLog(MON_SEV_CRITICAL, "MARGIN", "Margin level critical: " +
         DoubleToString(margin_level, 1) + "%");
   } else if(margin_level > 0 && margin_level < 500) {
      MonitorLog(MON_SEV_WARN, "MARGIN", "Margin level low: " +
         DoubleToString(margin_level, 1) + "%");
   }

   // Check free margin
   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(free_margin < 100) {
      MonitorLog(MON_SEV_CRITICAL, "MARGIN", "Free margin below $100: $" +
         DoubleToString(free_margin, 2));
   }
}

//+------------------------------------------------------------------+
//| Dump all current monitor state (call on demand / error)           |
//+------------------------------------------------------------------+
void MonitorDumpState()
{
   MonitorLog(MON_SEV_INFO, "DUMP", "=== MONITOR STATE DUMP ===");
   MonitorLog(MON_SEV_INFO, "DUMP", "Trade seq: " + IntegerToString(g_mon_trade_sequence)
      + " | Failed trades: " + IntegerToString(g_mon_failed_trades)
      + " | Peak balance: " + DoubleToString(g_mon_peak_balance, 2));
   MonitorLog(MON_SEV_INFO, "DUMP", "Spread: " + DoubleToString(g_mon_conn.spread / _Point, 1)
      + "pt | MA: " + DoubleToString(g_mon_conn.spread_ma / _Point, 1) + "pt"
      + " | Consec wide: " + IntegerToString(g_mon_conn.consecutive_wide));
   MonitorLog(MON_SEV_INFO, "DUMP", "Off quotes: " + IntegerToString(g_mon_conn.off_quote_count)
      + " | Last trade fail: " + IntegerToString(g_mon_failed_trades));
   MonitorLog(MON_SEV_INFO, "DUMP", "Signals tracked: " + IntegerToString(g_mon_signal_count));
   for(int i = 0; i < g_mon_signal_count; i++) {
      if(g_mon_signals[i].total > 0) {
         MonitorLog(MON_SEV_INFO, "DUMP", "  " + g_mon_signals[i].name + ": "
            + IntegerToString(g_mon_signals[i].total) + "t (" + IntegerToString(g_mon_signals[i].wins)
            + "W/" + IntegerToString(g_mon_signals[i].losses) + "L) WR="
            + DoubleToString(g_mon_signals[i].win_rate * 100, 1) + "% RR="
            + DoubleToString(g_mon_signals[i].avg_rr, 2) + " PnL="
            + DoubleToString(g_mon_signals[i].total_pnl, 2)
            + (g_mon_signals[i].auto_disabled ? " [DISABLED]" : ""));
      }
   }
   MonitorLog(MON_SEV_INFO, "DUMP", "=== END DUMP ===");
}

//+------------------------------------------------------------------+
//| Get signal names that are auto-disabled (for EA to check)         |
//+------------------------------------------------------------------+
string MonitorGetDisabledSignals()
{
   string result = "";
   for(int i = 0; i < g_mon_signal_count; i++) {
      if(g_mon_signals[i].auto_disabled) {
         if(result != "") result += ",";
         result += g_mon_signals[i].name;
      }
   }
   return result;
}

//+------------------------------------------------------------------+
//| Reset monitor state (call on new day / config change)             |
//+------------------------------------------------------------------+
void MonitorResetDaily()
{
   g_mon_failed_trades = 0;
   g_mon_initial_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(g_mon_initial_balance > g_mon_peak_balance)
      g_mon_peak_balance = g_mon_initial_balance;
   MonitorLog(MON_SEV_INFO, "INIT", "Monitor daily reset. Balance: " +
      DoubleToString(g_mon_initial_balance, 2));
}

//+------------------------------------------------------------------+
//| Log to file for external tools to consume                         |
//+------------------------------------------------------------------+
void MonitorFlushToFile(string filename = "gold_monitor_log.csv")
{
   int handle = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_COMMON, ",");
   if(handle == INVALID_HANDLE) {
      Print(MonHeader("ERROR", "FILE") + "Failed to open: " + filename);
      return;
   }

   FileWrite(handle, "Time", "Severity", "Tag", "Message", "Value");
   for(int i = 0; i < g_mon_log_count; i++) {
      FileWrite(handle,
         TimeToString(g_mon_log[i].time),
         IntegerToString(g_mon_log[i].severity),
         g_mon_log[i].tag,
         g_mon_log[i].message,
         DoubleToString(g_mon_log[i].value, 4));
   }
   FileClose(handle);
   Print(MonHeader("INFO", "FILE") + "Wrote " + IntegerToString(g_mon_log_count)
      + " log entries to " + filename);
}

//+------------------------------------------------------------------+
//| Notify Telegram of a trade entry                                  |
//+------------------------------------------------------------------+
void MonitorNotifyEntry(string symbol, string direction, double entry, double sl,
                        double tp, double lot, double atr, string signal_name)
{
   if(g_telegram.IsReady())
      g_telegram.SendTrade(symbol, direction, entry, sl, tp, lot, atr, signal_name);
}

//+------------------------------------------------------------------+
//| Notify Telegram of a trade close                                  |
//+------------------------------------------------------------------+
void MonitorNotifyExit(double pnl, double rr, string reason)
{
   if(g_telegram.IsReady())
      g_telegram.SendExit(_Symbol, pnl, rr, reason);
}

//+------------------------------------------------------------------+
//| Send Telegram daily summary                                       |
//+------------------------------------------------------------------+
void MonitorSendDailySummary(int trades_today, double daily_pnl, string disabled)
{
   if(!g_telegram.IsReady()) return;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (g_mon_peak_balance > 0)
      ? (g_mon_peak_balance - eq) / g_mon_peak_balance * 100.0 : 0;
   g_telegram.SendSummary(bal, eq, trades_today, daily_pnl, dd, g_mon_signal_count, disabled);
}
