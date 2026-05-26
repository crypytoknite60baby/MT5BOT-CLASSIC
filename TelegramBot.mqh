//+------------------------------------------------------------------+
//|              TelegramBot.mqh — Production-Grade Notifier          |
//|              Retry, queue, heartbeat, daily summary, health       |
//+------------------------------------------------------------------+
#property strict

#define TG_RATE_LIMIT 18
#define TG_WINDOW_SEC 60
#define TG_TIMEOUT_MS 3000
#define TG_MAX_RETRIES 3
#define TG_RETRY_DELAY_MS 2000
#define TG_QUEUE_MAX 50
#define TG_HEALTH_WINDOW 50

enum ENUM_TG_LOG_LEVEL {
   TG_LOG_SILENT,
   TG_LOG_ERRORS,
   TG_LOG_ALL
};

enum ENUM_TG_NOTIFY_TYPE {
   TG_NOTIFY_ENTRY,
   TG_NOTIFY_EXIT,
   TG_NOTIFY_ERROR,
   TG_NOTIFY_CRITICAL,
   TG_NOTIFY_DRAWDOWN,
   TG_NOTIFY_DAILY_SUMMARY,
   TG_NOTIFY_HEARTBEAT,
   TG_NOTIFY_UPGRADE
};

struct TgQueueItem {
   string   text;
   datetime queued_at;
};

struct TgHealth {
   int      total_attempts;
   int      successes;
   int      failures;
   double   success_rate;
   datetime last_success;
   datetime last_failure;
};

class TelegramBot {
private:
   string         m_token;
   string         m_chat_id;
   bool           m_ready;
   int            m_sent_this_min;
   datetime       m_window_start;
   ENUM_TG_LOG_LEVEL m_log;
   int            m_last_status;
   bool           m_notify_flags[8];
   TgQueueItem    m_queue[TG_QUEUE_MAX];
   int            m_queue_head;
   int            m_queue_tail;
   int            m_queue_count;
   TgHealth       m_health;

   string URLEncode(string str) {
      string out = "";
      int len = StringLen(str);
      for(int i = 0; i < len; i++) {
         int c = StringGetCharacter(str, i);
         if((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z')
            || (c >= 'a' && c <= 'z') || c == '_' || c == '-'
            || c == '.' || c == '~')
            out += ShortToString((ushort)c);
         else if(c == ' ')
            out += "%20";
         else if(c == '\n')
            out += "%0A";
         else
            out += StringFormat("%%%02X", c);
      }
      return out;
   }

   bool SendRawInternal(string text) {
      if(!m_ready) return false;

      string url = "https://api.telegram.org/bot" + m_token
         + "/sendMessage?chat_id=" + m_chat_id
         + "&text=" + URLEncode(text)
         + "&parse_mode=Markdown";

      char data[];
      char result[];
      string headers;
      ResetLastError();

      int status = WebRequest("GET", url, "", TG_TIMEOUT_MS, data, result, headers);
      m_last_status = status;

      m_health.total_attempts++;

      if(status == -1) {
         int err = GetLastError();
         if(err == 4014) {
            Print("[BOT] ERROR 4014: URL not allowed. Add to MT5: Tools > Options > Expert Advisors > Allow WebRequest for 'https://api.telegram.org'");
         } else if(err == 4060) {
            Print("[BOT] ERROR 4060: Gateway timeout — check internet");
         } else {
            Print("[BOT] WebRequest failed: error " + IntegerToString(err));
         }
         m_health.failures++;
         m_health.last_failure = TimeCurrent();
         m_health.success_rate = (m_health.total_attempts > 0)
            ? (double)m_health.successes / m_health.total_attempts : 0;
         return false;
      }

      if(status == 200) {
         m_sent_this_min++;
         m_health.successes++;
         m_health.last_success = TimeCurrent();
         m_health.success_rate = (m_health.total_attempts > 0)
            ? (double)m_health.successes / m_health.total_attempts : 0;
         if(m_log >= TG_LOG_ALL)
            Print("[BOT] Sent: " + StringSubstr(text, 0, 80) + "...");
         return true;
      }

      m_health.failures++;
      m_health.last_failure = TimeCurrent();
      m_health.success_rate = (m_health.total_attempts > 0)
         ? (double)m_health.successes / m_health.total_attempts : 0;
      if(m_log >= TG_LOG_ERRORS)
         Print("[BOT] HTTP " + IntegerToString(status) + ": " + CharArrayToString(result));
      return false;
   }

   void ProcessQueue() {
      if(m_queue_count == 0) return;
      if(!RateLimitOK()) return;

      string text = m_queue[m_queue_head].text;
      m_queue_head = (m_queue_head + 1) % TG_QUEUE_MAX;
      m_queue_count--;

      bool ok = false;
      for(int r = 0; r < TG_MAX_RETRIES; r++) {
         ok = SendRawInternal(text);
         if(ok) break;
         if(r < TG_MAX_RETRIES - 1) Sleep(TG_RETRY_DELAY_MS);
      }
      if(!ok && m_log >= TG_LOG_ERRORS)
         Print("[BOT] Queue item failed after retries: " + StringSubstr(text, 0, 60) + "...");
   }

   bool RateLimitOK() {
      datetime now = TimeCurrent();
      if(now - m_window_start >= TG_WINDOW_SEC) {
         m_sent_this_min = 0;
         m_window_start = now;
      }
      return m_sent_this_min < TG_RATE_LIMIT;
   }

public:
   TelegramBot() {
      m_token = "";
      m_chat_id = "";
      m_ready = false;
      m_sent_this_min = 0;
      m_window_start = 0;
      m_log = TG_LOG_ERRORS;
      m_last_status = -1;
      m_queue_head = 0;
      m_queue_tail = 0;
      m_queue_count = 0;
      m_health.total_attempts = 0;
      m_health.successes = 0;
      m_health.failures = 0;
      m_health.success_rate = 0;
      m_health.last_success = 0;
      m_health.last_failure = 0;
      for(int i = 0; i < 8; i++) m_notify_flags[i] = true;
   }

   void Init(string token, string chat_id, ENUM_TG_LOG_LEVEL log = TG_LOG_ERRORS) {
      m_token = token;
      m_chat_id = chat_id;
      m_log = log;
      m_ready = (m_token != "" && m_chat_id != "");
      m_sent_this_min = 0;
      m_window_start = TimeCurrent();

      if(m_ready) {
         if(m_log >= TG_LOG_ERRORS)
            Print("[BOT] Telegram notifier initialized — chat: " + m_chat_id);
         Enqueue("🔍 *WEMADEIT Monitor* connected and watching. Ready to report.");
      } else {
         Print("[BOT] Telegram notifier disabled — token or chat_id empty");
      }
   }

   bool IsReady() { return m_ready; }
   int LastStatus() { return m_last_status; }
   TgHealth GetHealth() { return m_health; }

   void SetNotify(ENUM_TG_NOTIFY_TYPE type, bool enabled) {
      m_notify_flags[type] = enabled;
   }

   void Enqueue(string text) {
      if(!m_ready) return;
      if(m_queue_count >= TG_QUEUE_MAX) {
         if(m_log >= TG_LOG_ERRORS)
            Print("[BOT] Queue full — dropping: " + StringSubstr(text, 0, 40) + "...");
         return;
      }
      m_queue[m_queue_tail].text = text;
      m_queue[m_queue_tail].queued_at = TimeCurrent();
      m_queue_tail = (m_queue_tail + 1) % TG_QUEUE_MAX;
      m_queue_count++;
      ProcessQueue();
   }

   bool SendRaw(string text) {
      if(!m_ready) return false;

      // Rate limit check → queue
      if(!RateLimitOK()) {
         Enqueue(text);
         return false;
      }

      bool ok = false;
      for(int r = 0; r < TG_MAX_RETRIES; r++) {
         ok = SendRawInternal(text);
         if(ok) break;
         if(r < TG_MAX_RETRIES - 1) Sleep(TG_RETRY_DELAY_MS);
      }
      return ok;
   }

   void Tick() {
      // Process queue on any tick when rate window allows
      if(m_queue_count > 0) ProcessQueue();
   }

   bool SendTrade(string symbol, string direction, double entry, double sl, double tp,
                  double lot, double atr, string signal_name) {
      if(!m_ready || !m_notify_flags[TG_NOTIFY_ENTRY]) return false;
      string emoji = (direction == "BUY") ? "🟢" : "🔴";
      string text = emoji + " *" + direction + " " + symbol + "*\n"
         + "Entry: `" + DoubleToString(entry, 2) + "`\n"
         + "SL: `" + DoubleToString(sl, 2) + "` (" + StringFormat("%.1f", MathAbs(entry - sl)) + ")\n"
         + "TP: `" + DoubleToString(tp, 2) + "`\n"
         + "Lot: `" + DoubleToString(lot, 2) + "`\n"
         + "ATR: `" + DoubleToString(atr, 2) + "`\n"
         + "Signal: `" + signal_name + "`";
      return SendRaw(text);
   }

   bool SendExit(string symbol, double pnl, double rr, string reason) {
      if(!m_ready || !m_notify_flags[TG_NOTIFY_EXIT]) return false;
      string emoji = (pnl >= 0) ? "✅" : "❌";
      string text = emoji + " *" + symbol + " CLOSED*\n"
         + "PnL: `$" + DoubleToString(pnl, 2) + "`\n"
         + "RR: `" + DoubleToString(rr, 2) + "R`\n"
         + "Reason: `" + reason + "`";
      return SendRaw(text);
   }

   bool SendAlert(string severity, string tag, string message) {
      if(!m_ready) return false;
      bool is_dd = (tag == "RISK" || tag == "DRAWDOWN");
      if(is_dd && !m_notify_flags[TG_NOTIFY_DRAWDOWN]) return false;
      if(severity == "ERROR" && !m_notify_flags[TG_NOTIFY_ERROR]) return false;
      if(severity == "CRIT" && !m_notify_flags[TG_NOTIFY_CRITICAL]) return false;

      string emoji = "ℹ️";
      if(severity == "WARN") emoji = "⚠️";
      else if(severity == "ERROR") emoji = "🚨";
      else if(severity == "CRIT") emoji = "🛑";

      string text = emoji + " *" + severity + " — " + tag + "*\n"
         + "`" + message + "`";
      return SendRaw(text);
   }

   bool SendSummary(double balance, double equity, int trades_today, double daily_pnl,
                    double dd_pct, int signals_active, string disabled_signals) {
      if(!m_ready || !m_notify_flags[TG_NOTIFY_DAILY_SUMMARY]) return false;
      string emoji = (daily_pnl >= 0) ? "📊" : "📉";
      string text = emoji + " *Daily Summary*\n"
         + "Balance: `$" + DoubleToString(balance, 2) + "`\n"
         + "Equity: `$" + DoubleToString(equity, 2) + "`\n"
         + "Today: `" + IntegerToString(trades_today) + "` trades `$"
         + DoubleToString(daily_pnl, 2) + "`\n"
         + "DD: `" + DoubleToString(dd_pct, 1) + "%`\n"
         + "Signals: `" + IntegerToString(signals_active) + "` active\n"
         + (disabled_signals != "" ? "Disabled: `" + disabled_signals + "`" : "");
      return SendRaw(text);
   }

   bool SendUpgrade(string version, string description) {
      if(!m_ready || !m_notify_flags[TG_NOTIFY_UPGRADE]) return false;
      string text = "🔄 *Upgrade to " + version + "*\n`" + description + "`";
      return SendRaw(text);
   }

   bool SendHeartbeat(string version, int uptime_hours, int open_positions,
                      double balance, double daily_pnl, double dd_pct) {
      if(!m_ready || !m_notify_flags[TG_NOTIFY_HEARTBEAT]) return false;
      string text = "💓 *Heartbeat* — v" + version + "\n"
         + "Uptime: `" + IntegerToString(uptime_hours) + "h`\n"
         + "Positions: `" + IntegerToString(open_positions) + "`\n"
         + "Balance: `$" + DoubleToString(balance, 2) + "`\n"
         + "Daily PnL: `$" + DoubleToString(daily_pnl, 2) + "`\n"
         + "DD: `" + DoubleToString(dd_pct, 1) + "%`\n"
         + "TG health: `" + DoubleToString(m_health.success_rate * 100, 0) + "%`";
      return SendRaw(text);
   }

   bool SendConfig(string config_json) {
      if(!m_ready) return false;
      string text = "⚙️ *Config Update*\n`" + config_json + "`";
      return SendRaw(text);
   }
};
