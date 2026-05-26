//+------------------------------------------------------------------+
//|                      Market Regime Optimizer                       |
//|                     Enhanced Smart Money Trader                    |
//+------------------------------------------------------------------+
// This file contains functions to optimize trading based on market regimes
// To use these functions, copy and paste them into your main EA file or include this file

//+------------------------------------------------------------------+
//| Market Regime Detection and Classification                        |
//+------------------------------------------------------------------+
enum ENUM_MARKET_REGIME {
   REGIME_TRENDING,
   REGIME_RANGING,
   REGIME_VOLATILE,
   REGIME_UNDEFINED
};

//+------------------------------------------------------------------+
//| Detect the current market regime                                  |
//+------------------------------------------------------------------+
ENUM_MARKET_REGIME DetectMarketRegime(string symbol, ENUM_TIMEFRAMES entry_tf, 
                                     ENUM_TIMEFRAMES trend_tf, int atr_period)
{
   // Get various timeframe data
   double atr_short = GetATRValue(symbol, entry_tf, atr_period, 0);
   double atr_long = GetATRValue(symbol, entry_tf, atr_period, 20);
   
   // Volatility ratio
   double volatility_ratio = 1.0;
   if(atr_long > 0) volatility_ratio = atr_short / atr_long;
   
   // Get price data
   double close[], high[], low[];
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   if(CopyClose(symbol, entry_tf, 0, 50, close) <= 0) return REGIME_UNDEFINED;
   if(CopyHigh(symbol, entry_tf, 0, 50, high) <= 0) return REGIME_UNDEFINED;
   if(CopyLow(symbol, entry_tf, 0, 50, low) <= 0) return REGIME_UNDEFINED;
   
   // Calculate ADX for trend strength
   int adx_handle = iADX(symbol, trend_tf, 14);
   if(adx_handle == INVALID_HANDLE) return REGIME_UNDEFINED;
   
   double adx_values[];
   ArraySetAsSeries(adx_values, true);
   if(CopyBuffer(adx_handle, 0, 0, 3, adx_values) <= 0) 
   {
      IndicatorRelease(adx_handle);
      return REGIME_UNDEFINED;
   }
   
   IndicatorRelease(adx_handle);
   double adx = adx_values[0];
   
   // Calculate price highs/lows consistency
   int higher_highs = 0;
   int lower_lows = 0;
   
   for(int i = 1; i < 10; i++)
   {
      if(high[i] < high[i-1]) higher_highs++;
      if(low[i] > low[i-1]) lower_lows++;
   }
   
   // Determine regime
   if(adx > 25 && (higher_highs > 7 || lower_lows > 7) && volatility_ratio < 1.5)
   {
      return REGIME_TRENDING;
   }
   else if(adx < 20 && higher_highs <= 5 && lower_lows <= 5 && volatility_ratio < 1.2)
   {
      return REGIME_RANGING;
   }
   else if(volatility_ratio > 1.5 || (adx > 30 && volatility_ratio > 1.3))
   {
      return REGIME_VOLATILE;
   }
   
   return REGIME_UNDEFINED;
}

//+------------------------------------------------------------------+
//| Get string representation of market regime                        |
//+------------------------------------------------------------------+
string GetRegimeString(ENUM_MARKET_REGIME regime)
{
   switch(regime)
   {
      case REGIME_TRENDING: return "Trending";
      case REGIME_RANGING: return "Ranging";
      case REGIME_VOLATILE: return "Volatile";
      default: return "Undefined";
   }
}

//+------------------------------------------------------------------+
//| Get ATR value with proper error handling                          |
//+------------------------------------------------------------------+
double GetATRValue(string symbol, ENUM_TIMEFRAMES timeframe, int period, int shift)
{
   int temp_handle = iATR(symbol, timeframe, period);
   
   if(temp_handle == INVALID_HANDLE)
      return 0;
   
   // Get ATR values
   double atr_values[];
   ArraySetAsSeries(atr_values, true);
   
   if(CopyBuffer(temp_handle, 0, shift, 1, atr_values) <= 0)
   {
      IndicatorRelease(temp_handle);
      return 0;
   }
   
   // Release temporary handle
   IndicatorRelease(temp_handle);
      
   return atr_values[0];
}

//+------------------------------------------------------------------+
//| Optimize trading parameters based on market regime                |
//+------------------------------------------------------------------+
void OptimizeForMarketRegime(ENUM_MARKET_REGIME regime, 
                           double base_risk, double base_atr, double base_tp,
                           double trending_tp_bonus, double ranging_tp_reduction,
                           double &current_risk, double &current_atr, double &current_tp,
                           double current_drawdown, bool verbose_mode,
                           int digits)
{
   // Adjust trading parameters based on regime
   switch(regime)
   {
      case REGIME_TRENDING:
         // In trending markets, use wider stops and larger targets
         current_atr = base_atr * 1.2;
         current_tp = base_tp * (1.0 + (trending_tp_bonus / 100.0)); // Apply bonus percentage
         current_risk = base_risk * 1.1; // Slightly more aggressive
         
         if(verbose_mode)
            Print("Trending market detected - Optimizing for trend following");
         break;
         
      case REGIME_RANGING:
         // In ranging markets, use tighter stops and more conservative targets
         current_atr = base_atr * 0.8;
         current_tp = base_tp * (1.0 - (ranging_tp_reduction / 100.0)); // Apply reduction percentage
         current_risk = base_risk * 0.8; // More conservative
         
         if(verbose_mode)
            Print("Ranging market detected - Optimizing for range trading");
         break;
         
      case REGIME_VOLATILE:
         // In volatile markets, use wider stops and conservative risk
         current_atr = base_atr * 1.5;
         current_tp = base_tp * 1.0;
         current_risk = base_risk * 0.7; // Much more conservative
         
         if(verbose_mode)
            Print("Volatile market detected - Increasing protection measures");
         break;
         
      default:
         // Reset to default
         current_atr = base_atr;
         current_tp = base_tp;
         current_risk = base_risk;
         break;
   }
   
   // Apply drawdown-based risk reduction if needed
   if(current_drawdown > 0)
   {
      double drawdown_factor = 1.0;
      
      // Progressive risk reduction based on drawdown
      if(current_drawdown > 2.0 && current_drawdown <= 4.0)
         drawdown_factor = 0.9;
      else if(current_drawdown > 4.0 && current_drawdown <= 6.0)
         drawdown_factor = 0.8;
      else if(current_drawdown > 6.0)
         drawdown_factor = 0.7;
         
      // Apply the drawdown factor
      current_risk *= drawdown_factor;
      
      if(verbose_mode && drawdown_factor < 1.0)
         Print("Reducing risk due to drawdown of ", DoubleToString(current_drawdown, 2), 
               "%. Risk adjusted to ", DoubleToString(current_risk, 2), "%");
   }
   
   // Ensure sanity limits
   current_atr = MathMax(0.5, MathMin(current_atr, 2.0));
   current_tp = MathMax(0.7, MathMin(current_tp, 3.0));
   current_risk = MathMax(0.1, MathMin(current_risk, base_risk * 1.2));
   
   if(verbose_mode)
   {
      Print("Optimized parameters for ", GetRegimeString(regime), " market - Risk: ", DoubleToString(current_risk, 2), 
            "%, ATR Multiplier: ", DoubleToString(current_atr, 2),
            ", TP Multiplier: ", DoubleToString(current_tp, 2));
   }
}

//+------------------------------------------------------------------+
//| Apply advanced multi-stage trailing stop                          |
//+------------------------------------------------------------------+
void ApplyMultiStageTrailing(string symbol, ulong ticket, ENUM_POSITION_TYPE position_type, 
                           double open_price, double current_price, 
                           double current_sl, double profit_distance,
                           double trailing_step, ENUM_MARKET_REGIME market_regime, 
                           double market_sentiment, int point, int digits,
                           bool verbose_mode)
{
   double new_sl = current_sl;
   double stop_distance = MathAbs(open_price - current_sl) / point;
   double profit_ratio = profit_distance / stop_distance;
   
   // Stage 1: Initial breakeven (50% of stop distance) - REDUCED from previous 80%
   if(profit_ratio >= 0.5 && profit_ratio < 1.0)
   {
      if(position_type == POSITION_TYPE_BUY)
         new_sl = open_price + 5 * point; // Small buffer in profit
      else
         new_sl = open_price - 5 * point;
         
      if(verbose_mode)
         Print("Moving to breakeven+ at profit ratio: ", DoubleToString(profit_ratio, 2));
   }
   // Stage 2: Standard trailing (100% of stop distance)
   else if(profit_ratio >= 1.0 && profit_ratio < 1.5)
   {
      if(position_type == POSITION_TYPE_BUY)
         new_sl = current_price - trailing_step * point;
      else
         new_sl = current_price + trailing_step * point;
         
      if(verbose_mode)
         Print("Applying standard trailing at profit ratio: ", DoubleToString(profit_ratio, 2));
   }
   // Stage 3: Tighter trailing (150% of stop distance)
   else if(profit_ratio >= 1.5)
   {
      // Use tighter trailing for larger profits (70% of standard)
      trailing_step = trailing_step * 0.7;
      
      if(position_type == POSITION_TYPE_BUY)
         new_sl = current_price - trailing_step * point;
      else
         new_sl = current_price + trailing_step * point;
         
      if(verbose_mode)
         Print("Applying tighter trailing at profit ratio: ", DoubleToString(profit_ratio, 2));
   }
   
   // Adjust for market regime
   if(market_regime == REGIME_VOLATILE)
   {
      // Add extra space in volatile markets
      if(position_type == POSITION_TYPE_BUY)
         new_sl = new_sl - (5 * point);
      else
         new_sl = new_sl + (5 * point);
   }
   else if(market_regime == REGIME_TRENDING)
   {
      // Give more room in trending markets to capture larger moves
      if(position_type == POSITION_TYPE_BUY && market_sentiment > 50)
      {
         new_sl = new_sl - (8 * point);
      }
      else if(position_type == POSITION_TYPE_SELL && market_sentiment < -50)
      {
         new_sl = new_sl + (8 * point);
      }
   }
   
   // Return the normalized stop loss
   new_sl = NormalizeDouble(new_sl, digits);
   
   return new_sl;
}

//+------------------------------------------------------------------+
//| Analyze trading patterns for directional bias                     |
//+------------------------------------------------------------------+
bool AnalyzeTradingPatterns(struct TradeResult &trade_history[], int &losing_buys, int &losing_sells)
{
   int total_losing = 0;
   int total_analyzed = 0;
   losing_buys = 0;
   losing_sells = 0;
   
   // Count direction of recent losing trades
   for(int i = 0; i < ArraySize(trade_history); i++)
   {
      // Only analyze recent trades (last 24 hours)
      if(TimeCurrent() - trade_history[i].time > 86400) // 24 hours
         continue;
         
      total_analyzed++;
      
      if(!trade_history[i].is_win)
      {
         total_losing++;
         
         if(trade_history[i].direction == POSITION_TYPE_BUY)
            losing_buys++;
         else
            losing_sells++;
      }
   }
   
   // Return true if we have enough data for analysis
   return (total_losing >= 2 && total_analyzed >= 5);
} 