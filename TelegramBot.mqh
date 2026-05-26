//+------------------------------------------------------------------+
//|              TelegramBot.mqh — Telegram Notification Sender      |
//|              Built for WEMADEIT monitoring system                |
//+------------------------------------------------------------------+
#property strict

// Max 20 msgs/min per Telegram rate limit
#define TG_RATE_LIMIT 18
#define TG_WINDOW_SEC 60
#define TG_TIMEOUT_MS 3000

enum ENUM_TG_LOG_LEVEL {
   TG_LOG_SILENT,
   TG_LOG_ERRORS,
   TG_LOG_ALL
};

class TelegramBot {
private:
   string   m_token;
   string   m_chat_id;
   bool     m_ready;
   int      m_sent_this_min;
   datetime m_window_start;
   ENUM_TG_LOG_LEVEL m_log;
   int      m_last_status;

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

public:
   TelegramBot() {
      m_token = "";
      m_chat_id = "";
      m_ready = false;
      m_sent_this_min = 0;
      m_window_start = 0;
      m_log = TG_LOG_ERRORS;
      m_last_status = -1;
   }

   void Init(string token, string chat_id, ENUM_TG_LOG_LEVEL log = TG_LOG_ERRORS) {
      m_token = token;
      m_chat_id = chat_id;
      m_log = log;
      m_ready = (m_token != "" && m_chat_id != "");
      m_sent_this_min = 0;
      m_window_start = TimeCurrent();

      if(m_ready) {
         // Verify by sending a startup message
         if(m_log >= TG_LOG_ERRORS)
            Print("[BOT] Telegram notifier initialized — chat: " + m_chat_id);
         SendRaw("🔍 *WEMADEIT Monitor* connected and watching. Ready to report.");
      } else {
         Print("[BOT] Telegram notifier disabled — token or chat_id empty");
      }
   }

   bool IsReady() { return m_ready; }
   int LastStatus() { return m_last_status; }

   bool SendRaw(string text) {
      if(!m_ready) return false;

      // Rate limit check
      datetime now = TimeCurrent();
      if(now - m_window_start >= TG_WINDOW_SEC) {
         m_sent_this_min = 0;
         m_window_start = now;
      }
      if(m_sent_this_min >= TG_RATE_LIMIT) {
         if(m_log >= TG_LOG_ERRORS)
            Print("[BOT] Rate limit reached — waiting");
         return false;
      }

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

      if(status == -1) {
         int err = GetLastError();
         if(err == 4014) {
            Print("[BOT] ERROR 4014: URL not allowed. Add to MT5: Tools > Options > Expert Advisors > Allow WebRequest for 'https://api.telegram.org'");
         } else if(err == 4060) {
            Print("[BOT] ERROR 4060: Gateway timeout — check internet");
         } else {
            Print("[BOT] WebRequest failed: error " + IntegerToString(err));
         }
         return false;
      }

      if(status == 200) {
         m_sent_this_min++;
         if(m_log >= TG_LOG_ALL)
            Print("[BOT] Sent: " + StringSubstr(text, 0, 80) + "...");
         return true;
      }

      if(m_log >= TG_LOG_ERRORS)
         Print("[BOT] HTTP " + IntegerToString(status) + ": " + CharArrayToString(result));
      return false;
   }

   // Send a formatted trade entry notification
   bool SendTrade(string symbol, string direction, double entry, double sl, double tp,
                  double lot, double atr, string signal_name) {
      if(!m_ready) return false;
      string emoji = (direction == "BUY") ? "🟢" : "🔴";
      string text = emoji + " *" + direction + " " + symbol + "*\n"
         + "Entry: `" + DoubleToString(entry, 2) + "`\n"
         + "SL: `" + DoubleToString(sl, 2) + "` (" + StringFormat("%.1f", MathAbs(entry - sl)) + ")\n"
         + "TP: `" + DoubleToString(tp, 2) + "`\n"
         + "Lot: `" + DoubleToString(lot, 2) + "`\n"
         + "ATR: `" + DoubleToString(atr, 2) + "`\n"
         + "Signal: `" + signal_name + "`";
      return SendRaw(text);

   // Send a formatted exit notification
   bool SendExit(string symbol, double pnl, double rr, string reason) {
      if(!m_ready) return false;
      string emoji = (pnl >= 0) ? "✅" : "❌";
      string text = emoji + " *" + symbol + " CLOSED*\n"
         + "PnL: `$" + DoubleToString(pnl, 2) + "`\n"
         + "RR: `" + DoubleToString(rr, 2) + "R`\n"
         + "Reason: `" + reason + "`";
      return SendRaw(text);
   }

   // Send a monitor alert
   bool SendAlert(string severity, string tag, string message) {
      if(!m_ready) return false;
      string emoji = "ℹ️";
      if(severity == "WARN") emoji = "⚠️";
      else if(severity == "ERROR") emoji = "🚨";
      else if(severity == "CRIT") emoji = "🛑";

      string text = emoji + " *" + severity + " — " + tag + "*\n"
         + "`" + message + "`";
      return SendRaw(text);
   }

   // Send daily performance summary
   bool SendSummary(double balance, double equity, int trades_today, double daily_pnl,
                    double dd_pct, int signals_active, string disabled_signals) {
      if(!m_ready) return false;
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

   // Send config change / upgrade notification
   bool SendUpgrade(string version, string description) {
      if(!m_ready) return false;
      string text = "🔄 *Upgrade to " + version + "*\n`" + description + "`";
      return SendRaw(text);
   }
};
