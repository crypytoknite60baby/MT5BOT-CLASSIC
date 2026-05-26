//+------------------------------------------------------------------+
//|                                        WEMADEIT_Watcher.mq5      |
//|         Standalone EA Monitor — attach to ANY chart              |
//+------------------------------------------------------------------+
#property copyright   "WEMADEIT Monitoring System"
#property link        ""
#property version     "1.00"
#property strict
#property description "Watches WEMADEIT EA positions in real-time."
#property description "Detects stale positions, bad SL/TP, spread anomalies,"
#property description "broker connection issues, and state corruption."
#property description "Attach to any chart — runs independently."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include "TelegramBot.mqh"

TelegramBot g_watcher_bot;

//--- Watcher inputs
input int      WatchMagicNumber = 202500;       // EA Magic Number to watch
input string   WatchSymbol = "XAUUSD";           // Symbol to watch (empty=all)
input bool     EnableChartLabels = true;         // Show status on chart
input int      CheckIntervalSec = 10;            // Scan interval (seconds)
input double   MaxSpreadPoints = 80;             // Alert when spread > this
input double   MaxDailyLossPct = 5.0;            // Alert at this daily loss %
input double   CriticalMarginLevel = 200;        // Alert when margin < this %
input bool     EnableSoundAlerts = false;        // Play sound on errors
input bool     EnablePushAlerts = false;         // Send push notifications
input int      MaxSwapPerLot = 15;               // Alert when swap > $/lot
input string   TelegramToken = "8908559475:AAEFd7Ii5hpJerpHD626o1ETdVgLNSK3cCA"; // Telegram bot token (empty=off)
input string   TelegramChatID = "688755863";                                // Telegram chat ID

//--- Internal state
enum WATCHER_ALERT_TYPE {
   ALERT_INFO,
   ALERT_WARN,
   ALERT_ERROR,
   ALERT_CRITICAL
};

struct WatcherAlert {
   WATCHER_ALERT_TYPE type;
   string             tag;
   string             message;
   datetime           time;
};

struct PositionSnapshot {
   ulong    ticket;
   string   symbol;
   long     type;
   double   volume;
   double   entry;
   double   sl;
   double   tp;
   double   profit;
   double   swap;
   datetime open_time;
   int      magic;
   bool     valid;
};

WatcherAlert g_alerts[200];
int          g_alert_count;
datetime     g_last_scan;
datetime     g_last_daily_reset;
double       g_day_start_balance;
double       g_peak_balance;
int          g_scan_count;
ulong        g_last_known_positions[50];
int          g_last_known_count;
int          g_missing_sl_count;
int          g_bad_sl_count;
int          g_stale_count;

//+------------------------------------------------------------------+
//| Script start                                                      |
//+------------------------------------------------------------------+
int OnInit()
{
   g_last_scan = 0;
   g_last_daily_reset = 0;
   g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peak_balance = g_day_start_balance;
   g_scan_count = 0;
   g_alert_count = 0;
   g_last_known_count = 0;
   g_missing_sl_count = 0;
   g_bad_sl_count = 0;
   g_stale_count = 0;

   EventSetTimer(CheckIntervalSec);

   if(TelegramToken != "") {
      g_watcher_bot.Init(TelegramToken, TelegramChatID);
   }

   WatcherLog(ALERT_INFO, "INIT", "Watcher started — monitoring Magic="
      + IntegerToString(WatchMagicNumber) + " Symbol=" + WatchSymbol
      + " Balance=$" + DoubleToString(g_day_start_balance, 2)
      + " Telegram=" + (TelegramToken != "" ? "ON" : "OFF"));

   // Immediate first scan
   ScanAll();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Timer tick                                                        |
//+------------------------------------------------------------------+
void OnTimer()
{
   ScanAll();
   UpdateChartLabels();
}

//+------------------------------------------------------------------+
//| Cleanup                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   WatcherLog(ALERT_INFO, "DEINIT", "Watcher stopped (reason="
      + IntegerToString(reason) + ")");

   // Final flush
   if(ObjectFind(0, "Watcher_Label") >= 0)
      ObjectDelete(0, "Watcher_Label");
}

//+------------------------------------------------------------------+
//| Main scan — checks EVERYTHING                                     |
//+------------------------------------------------------------------+
void ScanAll()
{
   g_scan_count++;
   datetime now = TimeCurrent();

   // — Daily rollover —
   MqlDateTime dt_now, dt_last;
   TimeToStruct(now, dt_now);
   TimeToStruct(g_last_daily_reset, dt_last);
   if(dt_now.day != dt_last.day || dt_now.mon != dt_last.mon || dt_now.year != dt_last.year) {
      g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_last_daily_reset = now;
      g_alert_count = 0;
      WatcherLog(ALERT_INFO, "DAILY", "New day — Balance=$"
         + DoubleToString(g_day_start_balance, 2));
   }

   // — 1. Account health —
   CheckAccountHealth();

   // — 2. Positions scan —
   ScanPositions();

   // — 3. Pending orders scan —
   ScanPendingOrders();

   // — 4. Spread check —
   CheckSpread();

   // — 5. Broker status —
   CheckBroker();

   // — 6. Detect orphaned positions (closed by broker but EA thinks open) —
   CheckOrphaned();

   // — 7. Throttle overflow detection —
   CheckTradeFrequency();
}

//+------------------------------------------------------------------+
//| Account health checks                                             |
//+------------------------------------------------------------------+
void CheckAccountHealth()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance > g_peak_balance) g_peak_balance = balance;

   // Daily loss
   double daily_loss = g_day_start_balance - equity;
   double daily_loss_pct = (g_day_start_balance > 0)
      ? daily_loss / g_day_start_balance * 100.0 : 0;
   if(daily_loss_pct > MaxDailyLossPct) {
      WatcherLog(ALERT_CRITICAL, "DAILY_LOSS",
         "Daily loss " + DoubleToString(daily_loss_pct, 1) + "% exceeds limit "
         + DoubleToString(MaxDailyLossPct, 1) + "%");
   }

   // Drawdown from peak
   double dd_peak = (g_peak_balance > 0)
      ? (g_peak_balance - equity) / g_peak_balance * 100.0 : 0;
   if(dd_peak > 15.0) {
      WatcherLog(ALERT_CRITICAL, "DRAWDOWN",
         "Drawdown from peak " + DoubleToString(dd_peak, 1)
         + "% — check EA immediately");
   } else if(dd_peak > 10.0) {
      WatcherLog(ALERT_ERROR, "DRAWDOWN",
         "Drawdown from peak " + DoubleToString(dd_peak, 1) + "%");
   }

   // Margin level
   double margin_lvl = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(margin_lvl > 0 && margin_lvl < CriticalMarginLevel) {
      WatcherLog(ALERT_CRITICAL, "MARGIN",
         "Margin level " + DoubleToString(margin_lvl, 1) + "% below critical "
         + DoubleToString(CriticalMarginLevel, 1) + "%");
   } else if(margin_lvl > 0 && margin_lvl < 500) {
      WatcherLog(ALERT_WARN, "MARGIN",
         "Margin level low: " + DoubleToString(margin_lvl, 1) + "%");
   }

   // Free margin
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(free < 50) {
      WatcherLog(ALERT_CRITICAL, "MARGIN",
         "Free margin below $50: $" + DoubleToString(free, 2));
   }
}

//+------------------------------------------------------------------+
//| Scan all open positions for the EA                                |
//+------------------------------------------------------------------+
void ScanPositions()
{
   PositionSnapshot snaps[50];
   int snap_count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != WatchMagicNumber) continue;
      if(WatchSymbol != "" && PositionGetString(POSITION_SYMBOL) != WatchSymbol) continue;

      if(snap_count < 50) {
         snaps[snap_count].ticket = ticket;
         snaps[snap_count].symbol = PositionGetString(POSITION_SYMBOL);
         snaps[snap_count].type = PositionGetInteger(POSITION_TYPE);
         snaps[snap_count].volume = PositionGetDouble(POSITION_VOLUME);
         snaps[snap_count].entry = PositionGetDouble(POSITION_PRICE_OPEN);
         snaps[snap_count].sl = PositionGetDouble(POSITION_SL);
         snaps[snap_count].tp = PositionGetDouble(POSITION_TP);
         snaps[snap_count].profit = PositionGetDouble(POSITION_PROFIT);
         snaps[snap_count].swap = PositionGetDouble(POSITION_SWAP);
         snaps[snap_count].open_time = (datetime)PositionGetInteger(POSITION_TIME);
         snaps[snap_count].magic = (int)PositionGetInteger(POSITION_MAGIC);
         snaps[snap_count].valid = true;
         snap_count++;
      }
   }

   // Track position changes
   if(snap_count != g_last_known_count) {
      WatcherLog(ALERT_INFO, "POSITIONS",
         "Position count changed: " + IntegerToString(g_last_known_count)
         + " -> " + IntegerToString(snap_count));
   }

   // Audit each position
   for(int i = 0; i < snap_count; i++) {
      AuditPosition(snaps[i]);
   }

   g_last_known_count = snap_count;
   for(int i = 0; i < snap_count && i < 50; i++) {
      g_last_known_positions[i] = snaps[i].ticket;
   }
}

//+------------------------------------------------------------------+
//| Audit a single position for errors                                |
//+------------------------------------------------------------------+
void AuditPosition(PositionSnapshot &p)
{
   // 1. Missing stop loss
   if(p.sl == 0) {
      g_missing_sl_count++;
      WatcherLog(ALERT_CRITICAL, "NO_SL",
         "Ticket " + IntegerToString(p.ticket) + " " + p.symbol
         + " " + (p.type == POSITION_TYPE_BUY ? "BUY" : "SELL")
         + " vol=" + DoubleToString(p.volume, 2)
         + " entry=" + DoubleToString(p.entry, 2)
         + " has NO stop loss!");
   }

   // 2. Invalid SL/TP
   double bid = SymbolInfoDouble(p.symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(p.symbol, SYMBOL_ASK);
   double price = (p.type == POSITION_TYPE_BUY) ? bid : ask;

   if(p.type == POSITION_TYPE_BUY) {
      if(p.sl != 0 && p.sl >= p.entry) {
         g_bad_sl_count++;
         WatcherLog(ALERT_ERROR, "BAD_SL",
            "BUY " + IntegerToString(p.ticket) + " SL >= entry: SL="
            + DoubleToString(p.sl, 2) + " Entry=" + DoubleToString(p.entry, 2));
      }
      if(p.tp != 0 && p.tp <= p.entry) {
         WatcherLog(ALERT_ERROR, "BAD_TP",
            "BUY " + IntegerToString(p.ticket) + " TP <= entry: TP="
            + DoubleToString(p.tp, 2) + " Entry=" + DoubleToString(p.entry, 2));
      }
      // Price already past SL (broker didn't execute)
      if(p.sl != 0 && price <= p.sl) {
         g_stale_count++;
         WatcherLog(ALERT_ERROR, "STALE",
            "BUY " + IntegerToString(p.ticket) + " price below SL: price="
            + DoubleToString(price, 2) + " SL=" + DoubleToString(p.sl, 2));
      }
      // Price already past TP (broker didn't execute)
      if(p.tp != 0 && price >= p.tp) {
         g_stale_count++;
         WatcherLog(ALERT_ERROR, "STALE",
            "BUY " + IntegerToString(p.ticket) + " price above TP: price="
            + DoubleToString(price, 2) + " TP=" + DoubleToString(p.tp, 2));
      }
   } else {
      if(p.sl != 0 && p.sl <= p.entry) {
         g_bad_sl_count++;
         WatcherLog(ALERT_ERROR, "BAD_SL",
            "SELL " + IntegerToString(p.ticket) + " SL <= entry: SL="
            + DoubleToString(p.sl, 2) + " Entry=" + DoubleToString(p.entry, 2));
      }
      if(p.tp != 0 && p.tp >= p.entry) {
         WatcherLog(ALERT_ERROR, "BAD_TP",
            "SELL " + IntegerToString(p.ticket) + " TP >= entry: TP="
            + DoubleToString(p.tp, 2) + " Entry=" + DoubleToString(p.entry, 2));
      }
      // Price already past SL
      if(p.sl != 0 && price >= p.sl) {
         g_stale_count++;
         WatcherLog(ALERT_ERROR, "STALE",
            "SELL " + IntegerToString(p.ticket) + " price above SL: price="
            + DoubleToString(price, 2) + " SL=" + DoubleToString(p.sl, 2));
      }
      // Price already past TP
      if(p.tp != 0 && price <= p.tp) {
         g_stale_count++;
         WatcherLog(ALERT_ERROR, "STALE",
            "SELL " + IntegerToString(p.ticket) + " price below TP: price="
            + DoubleToString(price, 2) + " TP=" + DoubleToString(p.tp, 2));
      }
   }

   // 3. High swap cost
   double swap_per_lot = p.volume > 0 ? p.swap / p.volume : 0;
   if(swap_per_lot < -MaxSwapPerLot) {
      WatcherLog(ALERT_WARN, "SWAP",
         "High swap: ticket=" + IntegerToString(p.ticket)
         + " swap=$" + DoubleToString(p.swap, 2)
         + " ($" + DoubleToString(swap_per_lot, 2) + "/lot)");
   }

   // 4. Position open too long (stale)
   int bars_open = (int)((TimeCurrent() - p.open_time) / PeriodSeconds(PERIOD_H1));
   if(bars_open > 72) {
      WatcherLog(ALERT_WARN, "STALE",
         "Position " + IntegerToString(p.ticket) + " open "
         + IntegerToString(bars_open) + " hours (>72h)");
   }
}

//+------------------------------------------------------------------+
//| Scan pending orders                                               |
//+------------------------------------------------------------------+
void ScanPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;
      if((int)OrderGetInteger(ORDER_MAGIC) != WatchMagicNumber) continue;
      if(WatchSymbol != "" && OrderGetString(ORDER_SYMBOL) != WatchSymbol) continue;

      int type = (int)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT
         && type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
         continue;

      datetime setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      double current = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP)
         ? SymbolInfoDouble(NULL, SYMBOL_ASK)
         : SymbolInfoDouble(NULL, SYMBOL_BID);

      int hours_open = (int)((TimeCurrent() - setup) / 3600);
      if(hours_open > 6) {
         WatcherLog(ALERT_WARN, "PENDING",
            "Stale pending order: ticket=" + IntegerToString(ticket)
            + " type=" + IntegerToString(type)
            + " price=" + DoubleToString(price, 2)
            + " open=" + IntegerToString(hours_open) + "h");
      }

      // Price already far past pending order (should have triggered)
      double dist = MathAbs(current - price);
      if(dist > 5.0) {
         WatcherLog(ALERT_WARN, "PENDING",
            "Price far from pending: ticket=" + IntegerToString(ticket)
            + " price=" + DoubleToString(price, 2)
            + " current=" + DoubleToString(current, 2)
            + " diff=$" + DoubleToString(dist, 2));
      }
   }
}

//+------------------------------------------------------------------+
//| Spread anomaly detection                                          |
//+------------------------------------------------------------------+
void CheckSpread()
{
   if(WatchSymbol == "") return;

   double ask = SymbolInfoDouble(WatchSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(WatchSymbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) {
      WatcherLog(ALERT_ERROR, "CONN",
         "Invalid quotes for " + WatchSymbol
         + " ask=" + DoubleToString(ask, 2)
         + " bid=" + DoubleToString(bid, 2));
      return;
   }

   double spread = (ask - bid) / SymbolInfoDouble(WatchSymbol, SYMBOL_POINT);
   if(spread > MaxSpreadPoints) {
      WatcherLog(ALERT_WARN, "SPREAD",
         "Wide spread: " + DoubleToString(spread, 1) + " pts (limit="
         + DoubleToString(MaxSpreadPoints, 1) + ")");
   }
}

//+------------------------------------------------------------------+
//| Broker / terminal status                                          |
//+------------------------------------------------------------------+
void CheckBroker()
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) {
      WatcherLog(ALERT_CRITICAL, "BROKER", "NOT CONNECTED to trade server");
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) {
      WatcherLog(ALERT_CRITICAL, "BROKER", "Trading NOT ALLOWED");
   }
}

//+------------------------------------------------------------------+
//| Detect orphaned positions (position exists but EA not running)    |
//+------------------------------------------------------------------+
void CheckOrphaned()
{
   if(WatchSymbol == "") return;

   // Check if an EA with our magic is actually on the chart
   // We do this indirectly: if positions exist but haven't changed
   // in hours with stale SL/TP, it's likely orphaned

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != WatchMagicNumber) continue;
      if(WatchSymbol != "" && PositionGetString(POSITION_SYMBOL) != WatchSymbol) continue;

      datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      // Position open > 4 hours with no SL/TP change — EA likely not managing
      int hours_open = (int)((TimeCurrent() - ot) / 3600);
      if(hours_open > 4 && sl == 0 && tp == 0) {
         WatcherLog(ALERT_WARN, "ORPHAN",
            "Possible orphan: ticket=" + IntegerToString(ticket)
            + " open " + IntegerToString(hours_open)
            + "h with NO SL/TP set");
      }
   }
}

//+------------------------------------------------------------------+
//| Detect abnormally high trade frequency (EA might be overtrading)  |
//+------------------------------------------------------------------+
void CheckTradeFrequency()
{
   int total_pos = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != WatchMagicNumber) continue;
      total_pos++;
   }

   if(total_pos > 5) {
      WatcherLog(ALERT_WARN, "OVER_TRADE",
         IntegerToString(total_pos) + " open positions — possible overtrading");
   }
}

//+------------------------------------------------------------------+
//| Log an alert with deduplication                                   |
//+------------------------------------------------------------------+
void WatcherLog(WATCHER_ALERT_TYPE type, string tag, string msg)
{
   // Deduplicate: skip if last 5 identical messages
   if(g_alert_count >= 5) {
      bool dup = true;
      for(int i = g_alert_count - 1; i >= g_alert_count - 5 && i >= 0; i--) {
         if(g_alerts[i].tag != tag || g_alerts[i].message != msg) {
            dup = false;
            break;
         }
      }
      if(dup) return;
   }

   string sev = "INFO";
   if(type == ALERT_WARN) sev = "WARN";
   else if(type == ALERT_ERROR) sev = "ERROR";
   else if(type == ALERT_CRITICAL) sev = "CRIT";

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string ts = StringFormat("%02d:%02d:%02d", dt.hour, dt.min, dt.sec);

   Print("[WATCHER][" + sev + "][" + tag + "][" + ts + "] " + msg);

   // Telegram for ERROR and CRITICAL
   if(g_watcher_bot.IsReady() && (type == ALERT_CRITICAL || type == ALERT_ERROR)) {
      g_watcher_bot.SendAlert(sev, tag, msg);
   }

   // Sound on critical
   if(type == ALERT_CRITICAL && EnableSoundAlerts) {
      PlaySound("alert.wav");
   }

   // Push on critical
   if(type == ALERT_CRITICAL && EnablePushAlerts) {
      string push_msg = "[WATCHER " + sev + " " + tag + "] " + msg;
      SendNotification(push_msg);
   }

   // Store
   if(g_alert_count < 200) {
      g_alerts[g_alert_count].type = type;
      g_alerts[g_alert_count].tag = tag;
      g_alerts[g_alert_count].message = msg;
      g_alerts[g_alert_count].time = TimeCurrent();
      g_alert_count++;
   }
}

//+------------------------------------------------------------------+
//| On-chart status display                                           |
//+------------------------------------------------------------------+
void UpdateChartLabels()
{
   if(!EnableChartLabels) return;

   string label = "WEMADEIT WATCHER\n";
   label += "=== ACCOUNT ===\n";
   label += "Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n";
   label += "Equity: $" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "\n";
   label += "Margin: " + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), 1) + "%\n";
   label += "Free: $" + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2) + "\n";

   double dd = (g_peak_balance > 0)
      ? (g_peak_balance - AccountInfoDouble(ACCOUNT_EQUITY)) / g_peak_balance * 100.0 : 0;
   label += "DD (peak): " + DoubleToString(dd, 1) + "%\n";
   label += "Daily loss: $" + DoubleToString(g_day_start_balance - AccountInfoDouble(ACCOUNT_EQUITY), 2) + "\n";

   label += "=== POSITIONS ===\n";
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != WatchMagicNumber) continue;
      if(WatchSymbol != "" && PositionGetString(POSITION_SYMBOL) != WatchSymbol) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      string dir = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double profit = PositionGetDouble(POSITION_PROFIT);
      double swap = PositionGetDouble(POSITION_SWAP);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      label += dir + " $" + DoubleToString(entry, 2)
         + " PnL=$" + DoubleToString(profit, 2)
         + (sl == 0 ? " NO_SL!" : "")
         + "\n";
   }

   label += "=== ERRORS ===\n";
   label += "NoSL:" + IntegerToString(g_missing_sl_count)
      + " BadSL:" + IntegerToString(g_bad_sl_count)
      + " Stale:" + IntegerToString(g_stale_count) + "\n";
   label += "Scans: " + IntegerToString(g_scan_count) + "\n";

   // Last 3 critical alerts
   int crit_shown = 0;
   for(int i = g_alert_count - 1; i >= 0 && crit_shown < 3; i--) {
      if(g_alerts[i].type == ALERT_CRITICAL || g_alerts[i].type == ALERT_ERROR) {
         label += g_alerts[i].tag + ": " + g_alerts[i].message + "\n";
         crit_shown++;
      }
   }

   ObjectDelete(0, "Watcher_Label");
   ObjectCreate(0, "Watcher_Label", OBJ_LABEL, 0, 0, 0);
   ObjectSetString(0, "Watcher_Label", OBJPROP_TEXT, label);
   ObjectSetInteger(0, "Watcher_Label", OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, "Watcher_Label", OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, "Watcher_Label", OBJPROP_YDISTANCE, 10);
   ObjectSetInteger(0, "Watcher_Label", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, "Watcher_Label", OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, "Watcher_Label", OBJPROP_BACK, false);
   ObjectSetInteger(0, "Watcher_Label", OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Chart event handler — right-click context                        |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK) {
      if(sparam == "Watcher_Label") {
         // Cycle display mode or trigger dump
         WatcherLog(ALERT_INFO, "CMD", "Manual health dump triggered");
         MqlDateTime dt;
         TimeToStruct(TimeCurrent(), dt);
         Print("[WATCHER] Manual dump at " + StringFormat("%02d:%02d:%02d", dt.hour, dt.min, dt.sec));
      }
   }
}
