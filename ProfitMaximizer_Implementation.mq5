//+------------------------------------------------------------------+
//|            ProfitMaximizer Implementation for Enhanced Smart Money Trader        |
//+------------------------------------------------------------------+
//
// This file demonstrates how to properly implement the ProfitMaximizer with your existing EA
// Copy and adapt this code into your main EA file to avoid function duplication errors
//

// 1. Include file - Add this near the top of your EA after other includes
#include <ProfitMaximizer.mqh>

// 2. Add these new input parameters - Add this section after your "Re-Entry Prevention" group
input group "Profit Maximization Settings"
input bool   USE_MARKET_REGIME_DETECTION = true;  // Enable market regime-based optimization
input bool   USE_MULTI_STAGE_TRAILING = true;     // Use enhanced multi-stage trailing stop
input bool   ANALYZE_TRADING_PATTERNS = true;     // Analyze trading patterns to optimize entries
input double TRENDING_TP_BONUS = 30.0;            // Increase TP by percentage in trending markets
input double RANGING_TP_REDUCTION = 20.0;         // Decrease TP by percentage in ranging markets

// 3. Add code to OnInit() - Add this before the return statement in your OnInit() function
// Initialize market regime detection
void InitializeProfitMaximizer()
{
   if(USE_MARKET_REGIME_DETECTION) 
   {
      g_current_market_regime = DetectMarketRegime(_Symbol, ENTRY_TIMEFRAME, TREND_TIMEFRAME, ATR_PERIOD);
      
      if(g_current_market_regime != REGIME_UNDEFINED) 
      {
         OptimizeForMarketRegime(g_current_market_regime, 
                               RISK_PERCENT, ATR_MULTIPLIER, TP_MULTIPLIER, 
                               TRENDING_TP_BONUS, RANGING_TP_REDUCTION,
                               current_risk_percent, current_atr_multiplier, current_tp_multiplier,
                               g_current_drawdown_percent, VERBOSE_MODE);
                               
         if(VERBOSE_MODE)
            Print("Initial market regime detected: ", GetRegimeString(g_current_market_regime));
      }
   }
}

// 4. Add this code to your OnTick() function - Inside the "new bar" section
void UpdateMarketRegimeDetection(datetime current_time)
{
   static datetime last_regime_check = 0;
   if(USE_MARKET_REGIME_DETECTION && current_time - last_regime_check > 14400) // 4 hours
   {
      g_current_market_regime = DetectMarketRegime(_Symbol, ENTRY_TIMEFRAME, TREND_TIMEFRAME, ATR_PERIOD);
      
      if(g_current_market_regime != REGIME_UNDEFINED) 
      {
         OptimizeForMarketRegime(g_current_market_regime, 
                               RISK_PERCENT, ATR_MULTIPLIER, TP_MULTIPLIER, 
                               TRENDING_TP_BONUS, RANGING_TP_REDUCTION,
                               current_risk_percent, current_atr_multiplier, current_tp_multiplier,
                               g_current_drawdown_percent, VERBOSE_MODE);
                               
         if(VERBOSE_MODE)
            Print("Market regime updated: ", GetRegimeString(g_current_market_regime));
            
         // Send Telegram notification if enabled
         if(ENABLE_TELEGRAM && SEND_TELEGRAM_MESSAGES)
         {
            string message = "🔄 Market Regime Update for " + _Symbol + "\n";
            message += "Regime: " + GetRegimeString(g_current_market_regime) + "\n";
            message += "Trading parameters adjusted:\n";
            message += "- Risk: " + DoubleToString(current_risk_percent, 2) + "%\n";
            message += "- ATR Multiplier: " + DoubleToString(current_atr_multiplier, 2) + "\n";
            message += "- TP Multiplier: " + DoubleToString(current_tp_multiplier, 2) + "\n";
            
            SendTelegramMessage(message);
         }
      }
      
      last_regime_check = current_time;
   }
}

// 5. Add this to your ManageOpenPositions() function - Replace existing trailing stop logic
// Enhanced multi-stage trailing implementation
void ApplyAdvancedTrailingStop(ulong ticket, ENUM_POSITION_TYPE position_type, 
                              double open_price, double current_price, 
                              double stop_loss, double take_profit, 
                              double profit_ratio, double profit_distance)
{
   // Enhanced multi-stage trailing stop with market regime adaptation
   if(profit_ratio >= TRAILING_TRIGGER && USE_MULTI_STAGE_TRAILING)
   {
      double new_sl = CalculateMultiStageTrailing(
                     position_type, open_price, current_price, stop_loss,
                     profit_distance, TRAILING_STEP, g_current_market_regime,
                     current_market_sentiment, _Point, _Digits, VERBOSE_MODE);
      
      // Only modify if the new stop loss is better than current
      if((position_type == POSITION_TYPE_BUY && new_sl > stop_loss) ||
         (position_type == POSITION_TYPE_SELL && (new_sl < stop_loss || stop_loss == 0)))
      {
         if(trade.PositionModify(ticket, new_sl, take_profit))
         {
            if(VERBOSE_MODE)
               Print("Applied multi-stage trailing stop: ", DoubleToString(new_sl, _Digits), 
                     " (Profit ratio: ", DoubleToString(profit_ratio, 2), ")");
                     
            if(ENABLE_TELEGRAM && SEND_TELEGRAM_MESSAGES)
            {
               string message = "🔄 Advanced Trailing Stop updated on " + _Symbol + "\n";
               message += "Ticket: " + IntegerToString((long)ticket) + "\n";
               message += "New SL: " + DoubleToString(new_sl, _Digits) + "\n";
               message += "Profit secured: " + DoubleToString(profit_ratio, 2) + 
                          " × stop distance\n";
               
               SendTelegramMessage(message);
            }
         }
      }
   }
}

// 6. Add this to your pattern analysis or trade validation logic
void AnalyzePatternsWithHistory()
{
   // Analyze trading patterns after losses
   if(ANALYZE_TRADING_PATTERNS && g_consecutive_losses >= 2)
   {
      AnalyzeTradingPatterns(g_trade_history, ArraySize(g_trade_history), 
                           g_active_direction, g_correlated_pairs_active, 
                           VERBOSE_MODE);
                           
      if(g_active_direction != "" && VERBOSE_MODE)
      {
         Print("Trade pattern analysis suggests favoring ", g_active_direction, " trades");
         
         // Send Telegram notification if enabled
         if(ENABLE_TELEGRAM && SEND_TELEGRAM_MESSAGES)
         {
            string message = "⚠️ Trading Pattern Analysis\n";
            message += "Analysis suggests temporarily favoring " + g_active_direction + " signals\n";
            message += "Based on recent trading performance patterns.";
            SendTelegramMessage(message);
         }
      }
   }
}

// 7. Modify take profit calculation in your trade logic or position sizing
double CalculateOptimizedTakeProfit(ENUM_POSITION_TYPE trade_type, double entry_price, double stop_distance)
{
   double tp_multiplier = current_tp_multiplier; // Use the dynamically optimized TP multiplier
   
   // If market regime is trending and trade direction aligns with trend, increase TP
   if(USE_MARKET_REGIME_DETECTION && g_current_market_regime == REGIME_TRENDING)
   {
      bool trade_with_trend = false;
      
      // Check if trade is aligned with trend
      if((trade_type == POSITION_TYPE_BUY && current_market_sentiment > 50) ||
         (trade_type == POSITION_TYPE_SELL && current_market_sentiment < -50))
      {
         trade_with_trend = true;
      }
      
      // Add extra TP distance when trading with strong trend
      if(trade_with_trend)
      {
         tp_multiplier *= (1.0 + (TRENDING_TP_BONUS / 100.0));
         
         if(VERBOSE_MODE)
            Print("Taking larger profit target due to strong trend alignment");
      }
   }
   
   double take_profit_price;
   if(trade_type == POSITION_TYPE_BUY)
      take_profit_price = entry_price + (stop_distance * tp_multiplier);
   else
      take_profit_price = entry_price - (stop_distance * tp_multiplier);
      
   return take_profit_price;
}

// 8. Implementation example: Pattern direction check in trade validation
bool CheckPatternDirectionBias(ENUM_POSITION_TYPE trade_type)
{
   // Check trade pattern direction bias if applicable
   if(ANALYZE_TRADING_PATTERNS && g_active_direction != "")
   {
      if(g_consecutive_losses >= 2)
      {
         bool signal_matches_bias = (trade_type == POSITION_TYPE_BUY && g_active_direction == "BUY") ||
                                   (trade_type == POSITION_TYPE_SELL && g_active_direction == "SELL");
                                   
         if(!signal_matches_bias)
         {
            if(VERBOSE_MODE)
               Print("Trade rejected: Direction doesn't match pattern analysis bias (", g_active_direction, ")");
               
            return false;
         }
      }
   }
   
   return true;
}

//+------------------------------------------------------------------+
//|       HOW TO IMPLEMENT THIS IN YOUR MAIN EA                      |
//+------------------------------------------------------------------+
/*

1. Add the include file:
   #include <ProfitMaximizer.mqh>

2. Add the input parameters group as shown above

3. Add the InitializeProfitMaximizer() call to your OnInit():
   InitializeProfitMaximizer();

4. Add the UpdateMarketRegimeDetection() call to your OnTick():
   UpdateMarketRegimeDetection(current_time);

5. Replace your trailing stop code with ApplyAdvancedTrailingStop():
   ApplyAdvancedTrailingStop(ticket, position_type, open_price, current_price, stop_loss, take_profit, profit_ratio, profit_distance);

6. Add pattern analysis after checking for consecutive losses:
   AnalyzePatternsWithHistory();

7. Use the optimized take profit calculation:
   double take_profit_price = CalculateOptimizedTakeProfit(trade_type, entry_price, stop_distance);

8. Add direction bias checking to your trade validation:
   if(!CheckPatternDirectionBias(trade_type)) return false;

This clean implementation avoids duplicating functions that already exist in your EA.

*/ 