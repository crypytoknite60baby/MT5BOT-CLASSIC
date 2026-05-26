//+------------------------------------------------------------------+
//|                                                new_strategy.mq5 |
//|                    ICT Algorithmic Trading System v1.0           |
//+------------------------------------------------------------------+
#property copyright   "ICT Algorithmic Trading"
#property link        ""
#property version     "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Files\FileTxt.mqh>

//--- Input Parameters
input double RiskPercent = 1.5;              // Risk per trade (%)
input double RR_Ratio = 3.0;                 // Risk:Reward ratio
input int    Slippage = 5;                   // Max slippage
input int    MagicNumber = 202500;           // Unique EA identifier
input ENUM_TIMEFRAMES TimeFrame = PERIOD_H1; // Primary timeframe
input ENUM_TIMEFRAMES HTF = PERIOD_H4;       // Higher timeframe for bias

//--- ICT Strategy Parameters
input bool   EnableFVGs = true;              // Enable Fair Value Gaps
input bool   EnableOrderBlocks = true;       // Enable Order Blocks
input bool   EnableBreakers = true;          // Enable Breakers
input bool   EnableTurtleSoup = true;        // Enable Turtle Soup
input bool   EnableNDOG = true;              // Enable New Day Opening Gaps
input bool   EnableTimeBased = true;         // Enable time-based entries
input bool   EnableJudasSwing = true;        // Enable Judas Swing
input bool   EnableConsequentEncroachment = true; // Enable CE
input bool   EnableInversionFVG = true;      // Enable Inversion FVG
input bool   EnableRelativeEqualLevels = true; // Enable Relative Equal Levels
input bool   EnableIOFED = true;             // Enable IOFED entries
input bool   EnableQuadrantLevels = true;    // Enable Quadrant Levels
input bool   EnableLimitOrders = true;       // Use limit orders for entries

//--- Market Condition Parameters
input bool   EnableLRLRDetection = true;     // Enable LRLR/HRLR detection
input double LRLR_Threshold = 0.7;           // Threshold for LRLR detection
input double HRLR_StopMultiplier = 2.0;     // Stop loss multiplier for HRLR
input bool   EnablePartialProfits = true;    // Enable partial profits
input double PartialProfitLevel = 0.5;      // Partial profit at 50% of target

//--- Advanced ICT Parameters
input double FVG_ReactionDistance = 0.3;     // Distance for FVG reactions
input double CE_ReactionDistance = 0.2;      // Distance for CE reactions
input double RelativeLevelTolerance = 0.001; // Tolerance for relative levels
input int    JudasSwingLookback = 5;        // Lookback for Judas Swing
input double MinimumBodySize = 0.4;          // Minimum candle body size

//--- Time-based Trading (NY Local Time)
input int    LondonKillZone_Start = 2;       // London Kill Zone Start
input int    LondonKillZone_End = 4;         // London Kill Zone End
input int    NYOpen_Start = 9;               // NY Open Start
input int    NYOpen_End = 10;                // NY Open End
input int    LunchMacro = 11;                // Lunch Macro
input int    PM_Macro = 14;                  // PM Macro (2:50 PM ET)

//--- Risk Management
input double MaxDailyLoss = 7.0;             // Max daily loss (%)
input int    MaxDailyTrades = 8;             // Max daily trades
input double BreakevenPips = 12.0;          // Pips to move SL to breakeven
input double PartialTP_Percent = 50.0;      // Partial TP percentage
input double PartialTP_Close = 0.5;         // Close % at partial TP
input bool   EnableAdaptiveLots = true;     // Enable adaptive lot sizing
input double HighConfidenceMultiplier = 1.5; // Lot multiplier for high confidence
input bool   EnableMarketConditionRisk = true; // Adjust risk based on market condition

//--- Global Variables
bool trade_in_progress = false;
int consecutive_losses = 0;
datetime last_loss_time = 0;
int daily_trades = 0;
double daily_profit = 0.0;
datetime last_trade_date = 0;
double initial_balance = 0.0;
bool isLRLR = false;                         // Market condition flag
bool partial_taken = false;                  // Track partial profits

//--- ICT Arrays
struct FVG {
   double high, low, mid;
   bool bullish;
   datetime time;
   bool filled;
   bool active;
   bool isInversion;
   double quadrant25, quadrant50, quadrant75; // Quadrant levels
};

struct OrderBlock {
   double high, low, mid;
   bool bullish;
   datetime time;
   bool active;
};

struct Breaker {
   double level;
   bool bullish;
   datetime time;
   bool active;
};

struct RelativeLevel {
   double level;
   bool isHigh;
   datetime time;
   bool active;
};

struct LiquidityZone {
   double level;
   string type; // "Session", "Relative", "NDOG", "NWOG"
   datetime time;
   bool active;
};

FVG fvgs[100];
OrderBlock obs[50];
Breaker breakers[30];
RelativeLevel relativeLevels[40];
LiquidityZone liquidityZones[50];
int fvg_count = 0, ob_count = 0, breaker_count = 0, relative_count = 0, liquidity_count = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   initial_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   Print("Advanced ICT Algorithmic Trading System Initialized");
   Print("Balance: $", initial_balance);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Print("Advanced ICT Algorithmic Trading System Deinitialized");
}

//+------------------------------------------------------------------+
//| Get EMA value                                                    |
//+------------------------------------------------------------------+
double GetEMA(int period, ENUM_TIMEFRAMES tf, int shift=1) {
   int handle = iMA(_Symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return 0.0;
   double buffer[2];
   if(CopyBuffer(handle, 0, shift, 1, buffer) <= 0) return 0.0;
   return buffer[0];
}

//+------------------------------------------------------------------+
//| Get ATR value                                                    |
//+------------------------------------------------------------------+
double GetATR(int period, ENUM_TIMEFRAMES tf, int shift=1) {
   int handle = iATR(_Symbol, tf, period);
   if(handle == INVALID_HANDLE) return 0.0;
   double buffer[2];
   if(CopyBuffer(handle, 0, shift, 1, buffer) <= 0) return 0.0;
   return buffer[0];
}

//+------------------------------------------------------------------+
//| Get RSI value                                                    |
//+------------------------------------------------------------------+
double GetRSI(int period, ENUM_TIMEFRAMES tf, int shift=1) {
   int handle = iRSI(_Symbol, tf, period, PRICE_CLOSE);
   if(handle == INVALID_HANDLE) return 0.0;
   double buffer[2];
   if(CopyBuffer(handle, 0, shift, 1, buffer) <= 0) return 0.0;
   return buffer[0];
}

//+------------------------------------------------------------------+
//| Detect Judas Swing (manipulative move)                          |
//+------------------------------------------------------------------+
bool DetectJudasSwing(int shift=1) {
   double atr = GetATR(14, TimeFrame, shift);
   double current_high = iHigh(_Symbol, TimeFrame, shift);
   double current_low = iLow(_Symbol, TimeFrame, shift);
   double current_close = iClose(_Symbol, TimeFrame, shift);
   double current_open = iOpen(_Symbol, TimeFrame, shift);
   
   // Look for strong move in one direction followed by reversal
   double body = MathAbs(current_close - current_open);
   double range = current_high - current_low;
   
   // Strong candle with significant body
   if(body > atr * MinimumBodySize && range > atr * 0.8) {
      // Check if this is a reversal from previous direction
      double prev_close = iClose(_Symbol, TimeFrame, shift+1);
      double prev_open = iOpen(_Symbol, TimeFrame, shift+1);
      double prev_body = MathAbs(prev_close - prev_open);
      
      // Previous candle was in opposite direction
      if((current_close > current_open && prev_close < prev_open) || 
         (current_close < current_open && prev_close > prev_open)) {
         
         if(body > prev_body * 1.2) { // Current move stronger than previous
            Print("Judas Swing detected: ", (current_close > current_open ? "Bullish" : "Bearish"));
            return true;
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Detect Consequent Encroachment (midpoint reactions)              |
//+------------------------------------------------------------------+
bool DetectConsequentEncroachment(int shift=1) {
   double atr = GetATR(14, TimeFrame, shift);
   double current_price = iClose(_Symbol, TimeFrame, shift);
   
   // Check FVG midpoints for reactions
   for(int i = 0; i < fvg_count; i++) {
      if(fvgs[i].active && !fvgs[i].filled) {
         double distance = MathAbs(current_price - fvgs[i].mid);
         if(distance < atr * CE_ReactionDistance) {
            Print("Consequent Encroachment detected at FVG midpoint: ", fvgs[i].mid);
            return true;
         }
      }
   }
   
   // Check Order Block midpoints
   for(int i = 0; i < ob_count; i++) {
      if(obs[i].active) {
         double distance = MathAbs(current_price - obs[i].mid);
         if(distance < atr * CE_ReactionDistance) {
            Print("Consequent Encroachment detected at Order Block midpoint: ", obs[i].mid);
            return true;
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Detect Inversion Fair Value Gap                                 |
//+------------------------------------------------------------------+
bool DetectInversionFVG(int shift=1) {
   double high1 = iHigh(_Symbol, TimeFrame, shift+2);
   double low1 = iLow(_Symbol, TimeFrame, shift+2);
   double high3 = iHigh(_Symbol, TimeFrame, shift);
   double low3 = iLow(_Symbol, TimeFrame, shift);
   double current_close = iClose(_Symbol, TimeFrame, shift);
   
   // Check if price has breached an existing FVG
   for(int i = 0; i < fvg_count; i++) {
      if(fvgs[i].active && !fvgs[i].isInversion) {
         // Price has moved through the FVG
         if((fvgs[i].bullish && current_close > fvgs[i].high) ||
            (!fvgs[i].bullish && current_close < fvgs[i].low)) {
            
            // Mark as Inversion FVG
            fvgs[i].isInversion = true;
            Print("Inversion FVG detected at level: ", fvgs[i].mid);
            return true;
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Detect Relative Equal Highs/Lows                                |
//+------------------------------------------------------------------+
bool DetectRelativeEqualLevels(int shift=1) {
   double current_high = iHigh(_Symbol, TimeFrame, shift);
   double current_low = iLow(_Symbol, TimeFrame, shift);
   
   // Look for equal highs
   for(int i = 1; i <= 20; i++) {
      double prev_high = iHigh(_Symbol, TimeFrame, shift+i);
      if(MathAbs(current_high - prev_high) < RelativeLevelTolerance) {
         if(relative_count < 40) {
            relativeLevels[relative_count].level = current_high;
            relativeLevels[relative_count].isHigh = true;
            relativeLevels[relative_count].time = iTime(_Symbol, TimeFrame, shift);
            relativeLevels[relative_count].active = true;
            relative_count++;
            Print("Relative Equal High detected at: ", current_high);
            return true;
         }
      }
   }
   
   // Look for equal lows
   for(int i = 1; i <= 20; i++) {
      double prev_low = iLow(_Symbol, TimeFrame, shift+i);
      if(MathAbs(current_low - prev_low) < RelativeLevelTolerance) {
         if(relative_count < 40) {
            relativeLevels[relative_count].level = current_low;
            relativeLevels[relative_count].isHigh = false;
            relativeLevels[relative_count].time = iTime(_Symbol, TimeFrame, shift);
            relativeLevels[relative_count].active = true;
            relative_count++;
            Print("Relative Equal Low detected at: ", current_low);
            return true;
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Detect Market Condition (LRLR vs HRLR)                          |
//+------------------------------------------------------------------+
bool DetectMarketCondition() {
   double atr = GetATR(14, TimeFrame, 1);
   double overlap_count = 0;
   double total_candles = 0;
   
   // Check last 10 candles for overlapping
   for(int i = 1; i <= 10; i++) {
      double high1 = iHigh(_Symbol, TimeFrame, i);
      double low1 = iLow(_Symbol, TimeFrame, i);
      double high2 = iHigh(_Symbol, TimeFrame, i+1);
      double low2 = iLow(_Symbol, TimeFrame, i+1);
      
      // Check if candles overlap significantly
      if(MathMax(low1, low2) < MathMin(high1, high2)) {
         overlap_count++;
      }
      total_candles++;
   }
   
   double overlap_ratio = overlap_count / total_candles;
   
   // LRLR: Low overlap, separated candles, fast moves
   if(overlap_ratio < LRLR_Threshold) {
      isLRLR = true;
      Print("LRLR detected - Low resistance, fast moves expected");
      return true;
   } else {
      isLRLR = false;
      Print("HRLR detected - High resistance, back and forth expected");
      return false;
   }
}

//+------------------------------------------------------------------+
//| Detect Liquidity Zones                                           |
//+------------------------------------------------------------------+
bool DetectLiquidityZones() {
   double current_high = iHigh(_Symbol, TimeFrame, 0);
   double current_low = iLow(_Symbol, TimeFrame, 0);
   
   // Session highs/lows
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   
   // Asian session high/low
   if(hour >= 19 && hour <= 23) {
      if(liquidity_count < 50) {
         liquidityZones[liquidity_count].level = current_high;
         liquidityZones[liquidity_count].type = "Asian_High";
         liquidityZones[liquidity_count].time = TimeCurrent();
         liquidityZones[liquidity_count].active = true;
         liquidity_count++;
         
         liquidityZones[liquidity_count].level = current_low;
         liquidityZones[liquidity_count].type = "Asian_Low";
         liquidityZones[liquidity_count].time = TimeCurrent();
         liquidityZones[liquidity_count].active = true;
         liquidity_count++;
      }
   }
   
   // London session high/low
   if(hour >= 2 && hour <= 6) {
      if(liquidity_count < 50) {
         liquidityZones[liquidity_count].level = current_high;
         liquidityZones[liquidity_count].type = "London_High";
         liquidityZones[liquidity_count].time = TimeCurrent();
         liquidityZones[liquidity_count].active = true;
         liquidity_count++;
         
         liquidityZones[liquidity_count].level = current_low;
         liquidityZones[liquidity_count].type = "London_Low";
         liquidityZones[liquidity_count].time = TimeCurrent();
         liquidityZones[liquidity_count].active = true;
         liquidity_count++;
      }
   }
   
   // NY session high/low
   if(hour >= 9 && hour <= 17) {
      if(liquidity_count < 50) {
         liquidityZones[liquidity_count].level = current_high;
         liquidityZones[liquidity_count].type = "NY_High";
         liquidityZones[liquidity_count].time = TimeCurrent();
         liquidityZones[liquidity_count].active = true;
         liquidity_count++;
         
         liquidityZones[liquidity_count].level = current_low;
         liquidityZones[liquidity_count].type = "NY_Low";
         liquidityZones[liquidity_count].time = TimeCurrent();
         liquidityZones[liquidity_count].active = true;
         liquidity_count++;
      }
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Enhanced Fair Value Gap Detection with Quadrant Levels           |
//+------------------------------------------------------------------+
bool DetectFVG(int shift=1) {
   double high1 = iHigh(_Symbol, TimeFrame, shift+2);
   double low1 = iLow(_Symbol, TimeFrame, shift+2);
   double high3 = iHigh(_Symbol, TimeFrame, shift);
   double low3 = iLow(_Symbol, TimeFrame, shift);
   
   // Bullish FVG: low3 > high1
   if(low3 > high1) {
      if(fvg_count < 100) {
         fvgs[fvg_count].high = high3;
         fvgs[fvg_count].low = low1;
         fvgs[fvg_count].mid = (high3 + low1) / 2;
         fvgs[fvg_count].bullish = true;
         fvgs[fvg_count].time = iTime(_Symbol, TimeFrame, shift);
         fvgs[fvg_count].filled = false;
         fvgs[fvg_count].active = true;
         fvgs[fvg_count].isInversion = false;
         
         // Calculate quadrant levels
         double range = high3 - low1;
         fvgs[fvg_count].quadrant25 = low1 + (range * 0.25);
         fvgs[fvg_count].quadrant50 = low1 + (range * 0.50);
         fvgs[fvg_count].quadrant75 = low1 + (range * 0.75);
         
         fvg_count++;
         Print("Enhanced Bullish FVG detected at ", fvgs[fvg_count-1].mid, " with quadrants: 25%=", fvgs[fvg_count-1].quadrant25, " 50%=", fvgs[fvg_count-1].quadrant50, " 75%=", fvgs[fvg_count-1].quadrant75);
         return true;
      }
   }
   
   // Bearish FVG: high3 < low1
   if(high3 < low1) {
      if(fvg_count < 100) {
         fvgs[fvg_count].high = high1;
         fvgs[fvg_count].low = low3;
         fvgs[fvg_count].mid = (high1 + low3) / 2;
         fvgs[fvg_count].bullish = false;
         fvgs[fvg_count].time = iTime(_Symbol, TimeFrame, shift);
         fvgs[fvg_count].filled = false;
         fvgs[fvg_count].active = true;
         fvgs[fvg_count].isInversion = false;
         
         // Calculate quadrant levels
         double range = high1 - low3;
         fvgs[fvg_count].quadrant25 = low3 + (range * 0.25);
         fvgs[fvg_count].quadrant50 = low3 + (range * 0.50);
         fvgs[fvg_count].quadrant75 = low3 + (range * 0.75);
         
         fvg_count++;
         Print("Enhanced Bearish FVG detected at ", fvgs[fvg_count-1].mid, " with quadrants: 25%=", fvgs[fvg_count-1].quadrant25, " 50%=", fvgs[fvg_count-1].quadrant50, " 75%=", fvgs[fvg_count-1].quadrant75);
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Enhanced Order Block Detection                                   |
//+------------------------------------------------------------------+
bool DetectOrderBlock(int shift=1) {
   double open = iOpen(_Symbol, TimeFrame, shift);
   double close = iClose(_Symbol, TimeFrame, shift);
   double high = iHigh(_Symbol, TimeFrame, shift);
   double low = iLow(_Symbol, TimeFrame, shift);
   
   // Look for strong move after order block
   double next_close = iClose(_Symbol, TimeFrame, shift-1);
   double move = MathAbs(next_close - close);
   double atr = GetATR(14, TimeFrame, shift);
   double body = MathAbs(close - open);
   
   // Enhanced criteria: strong body + significant move
   if(body > atr * MinimumBodySize && move > atr * 0.8) {
      // Bullish Order Block: strong down candle before up move
      if(close < open && next_close > close) {
         if(ob_count < 50) {
            obs[ob_count].high = high;
            obs[ob_count].low = low;
            obs[ob_count].mid = (high + low) / 2;
            obs[ob_count].bullish = true;
            obs[ob_count].time = iTime(_Symbol, TimeFrame, shift);
            obs[ob_count].active = true;
            ob_count++;
            Print("Enhanced Bullish Order Block detected at ", obs[ob_count-1].mid);
            return true;
         }
      }
      
      // Bearish Order Block: strong up candle before down move
      if(close > open && next_close < close) {
         if(ob_count < 50) {
            obs[ob_count].high = high;
            obs[ob_count].low = low;
            obs[ob_count].mid = (high + low) / 2;
            obs[ob_count].bullish = false;
            obs[ob_count].time = iTime(_Symbol, TimeFrame, shift);
            obs[ob_count].active = true;
            ob_count++;
            Print("Enhanced Bearish Order Block detected at ", obs[ob_count-1].mid);
            return true;
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Enhanced Breaker Detection                                       |
//+------------------------------------------------------------------+
bool DetectBreaker(int shift=1) {
   double high1 = iHigh(_Symbol, TimeFrame, shift+2);
   double low1 = iLow(_Symbol, TimeFrame, shift+2);
   double high2 = iHigh(_Symbol, TimeFrame, shift+1);
   double low2 = iLow(_Symbol, TimeFrame, shift+1);
   double high3 = iHigh(_Symbol, TimeFrame, shift);
   double low3 = iLow(_Symbol, TimeFrame, shift);
   
   double atr = GetATR(14, TimeFrame, shift);
   
   // Enhanced Bearish Breaker: high-low-higher high with momentum
   if(high2 < high1 && high3 > high1) {
      double momentum = high3 - high1;
      if(momentum > atr * 0.5) { // Significant momentum
         if(breaker_count < 30) {
            breakers[breaker_count].level = high1;
            breakers[breaker_count].bullish = false;
            breakers[breaker_count].time = iTime(_Symbol, TimeFrame, shift);
            breakers[breaker_count].active = true;
            breaker_count++;
            Print("Enhanced Bearish Breaker detected at ", breakers[breaker_count-1].level);
            return true;
         }
      }
   }
   
   // Enhanced Bullish Breaker: low-high-lower low with momentum
   if(low2 > low1 && low3 < low1) {
      double momentum = low1 - low3;
      if(momentum > atr * 0.5) { // Significant momentum
         if(breaker_count < 30) {
            breakers[breaker_count].level = low1;
            breakers[breaker_count].bullish = true;
            breakers[breaker_count].time = iTime(_Symbol, TimeFrame, shift);
            breakers[breaker_count].active = true;
            breaker_count++;
            Print("Enhanced Bullish Breaker detected at ", breakers[breaker_count-1].level);
            return true;
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Enhanced Turtle Soup Detection                                   |
//+------------------------------------------------------------------+
bool DetectTurtleSoup(int shift=1) {
   double current_high = iHigh(_Symbol, TimeFrame, shift);
   double current_low = iLow(_Symbol, TimeFrame, shift);
   double prev_high = iHigh(_Symbol, TimeFrame, shift+1);
   double prev_low = iLow(_Symbol, TimeFrame, shift+1);
   
   double atr = GetATR(14, TimeFrame, shift);
   double body = MathAbs(iClose(_Symbol, TimeFrame, shift) - iOpen(_Symbol, TimeFrame, shift));
   
   // Enhanced Bullish Turtle Soup: sweep low then reverse up with strong body
   if(current_low < prev_low && iClose(_Symbol, TimeFrame, shift) > prev_low) {
      if(body > atr * MinimumBodySize) {
         Print("Enhanced Bullish Turtle Soup detected at ", prev_low);
         return true;
      }
   }
   
   // Enhanced Bearish Turtle Soup: sweep high then reverse down with strong body
   if(current_high > prev_high && iClose(_Symbol, TimeFrame, shift) < prev_high) {
      if(body > atr * MinimumBodySize) {
         Print("Enhanced Bearish Turtle Soup detected at ", prev_high);
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Calculate Signal Strength (0.0 to 1.0)                         |
//+------------------------------------------------------------------+
double CalculateSignalStrength(bool bullish, bool fvg, bool ob, bool breaker, bool turtle, bool judas, bool ce, bool inversion, bool relative) {
   double strength = 0.0;
   
   // Base signal strength - prioritize advanced patterns
   if(judas) strength += 0.8;        // Judas Swing is strongest
   if(inversion) strength += 0.7;    // Inversion FVG is very strong
   if(ce) strength += 0.6;           // Consequent Encroachment
   if(relative) strength += 0.5;     // Relative Equal Levels
   if(fvg) strength += 0.4;          // Regular FVG
   if(ob) strength += 0.3;           // Order Block
   if(breaker) strength += 0.3;      // Breaker
   if(turtle) strength += 0.2;       // Turtle Soup
   
   // Additional filters that increase confidence
   double ema20 = GetEMA(20, TimeFrame, 1);
   double ema50 = GetEMA(50, TimeFrame, 1);
   double rsi = GetRSI(14, TimeFrame, 1);
   double current_price = iClose(_Symbol, TimeFrame, 1);
   
   if(bullish) {
      if(current_price > ema20 && current_price > ema50) strength += 0.2;
      if(rsi < 70) strength += 0.1;
   } else {
      if(current_price < ema20 && current_price < ema50) strength += 0.2;
      if(rsi > 30) strength += 0.1;
   }
   
   return MathMin(strength, 1.0);
}

//+------------------------------------------------------------------+
//| Calculate Adaptive Lot Size                                      |
//+------------------------------------------------------------------+
double CalculateAdaptiveLotSize(double baseLotSize, double signalStrength) {
   if(!EnableAdaptiveLots) return baseLotSize;
   
   if(signalStrength > 0.7) {
      return baseLotSize * HighConfidenceMultiplier;
   }
   
   return baseLotSize;
}

//+------------------------------------------------------------------+
//| Calculate Adaptive Risk Based on Market Condition                |
//+------------------------------------------------------------------+
double CalculateAdaptiveRisk() {
   if(!EnableMarketConditionRisk) return RiskPercent;
   
   if(isLRLR) {
      // LRLR: Lower risk, faster moves, easier targets
      return RiskPercent * 1.2; // Increase risk in LRLR
   } else {
      // HRLR: Higher risk, wider stops needed
      return RiskPercent * 0.8; // Decrease risk in HRLR
   }
}

//+------------------------------------------------------------------+
//| Calculate Adaptive Stop Loss Based on Market Condition           |
//+------------------------------------------------------------------+
double CalculateAdaptiveStopLoss(double baseStopLoss) {
   if(isLRLR) {
      return baseStopLoss; // Normal stop in LRLR
   } else {
      return baseStopLoss * HRLR_StopMultiplier; // Wider stop in HRLR
   }
}

//+------------------------------------------------------------------+
//| Check if current time is in kill zone                           |
//+------------------------------------------------------------------+
bool IsInKillZone() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   int minute = dt.min;
   
   // London Kill Zone (2-4 AM ET)
   if(hour >= LondonKillZone_Start && hour <= LondonKillZone_End) return true;
   
   // NY Open (9:30-10:00 AM ET)
   if(hour == NYOpen_Start && minute >= 30) return true;
   if(hour == NYOpen_End && minute <= 0) return true;
   
   // Lunch Macro (11:30 AM ET)
   if(hour == LunchMacro && minute >= 30) return true;
   
   // PM Macro (2:50 PM ET)
   if(hour == PM_Macro && minute >= 50) return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Check for New Day Opening Gap                                   |
//+------------------------------------------------------------------+
bool HasNDOG() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   // Check if this is a new trading day
   static datetime last_check = 0;
   if(TimeCurrent() - last_check < 3600) return false; // Check once per hour
   
   last_check = TimeCurrent();
   
   // Get previous day's close and current day's open
   double prev_close = iClose(_Symbol, PERIOD_D1, 1);
   double curr_open = iOpen(_Symbol, PERIOD_D1, 0);
   
   double gap = MathAbs(curr_open - prev_close);
   double atr = GetATR(14, PERIOD_D1, 1);
   
   // Significant gap (more than 0.5 ATR)
   if(gap > atr * 0.5) {
      Print("NDOG detected: Gap = ", gap, " pips");
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| IOFED Entry Detection (Institutional Order Flow Entry Drill)     |
//+------------------------------------------------------------------+
bool DetectIOFED(bool bullish, int shift=1) {
   double current_price = iClose(_Symbol, TimeFrame, shift);
   double current_high = iHigh(_Symbol, TimeFrame, shift);
   double current_low = iLow(_Symbol, TimeFrame, shift);
   double current_body = MathAbs(iClose(_Symbol, TimeFrame, shift) - iOpen(_Symbol, TimeFrame, shift));
   
   // Check for FVG entries with IOFED criteria
   for(int i = 0; i < fvg_count; i++) {
      if(!fvgs[i].filled && fvgs[i].active) {
         double distance = MathAbs(current_price - fvgs[i].mid);
         double atr = GetATR(14, TimeFrame, shift);
         
         // Price wicks into FVG but doesn't fully close it
         if(bullish && fvgs[i].bullish) {
            if(current_low <= fvgs[i].high && current_high >= fvgs[i].mid && current_price < fvgs[i].high) {
               Print("IOFED BUY signal detected at FVG: ", fvgs[i].mid);
               return true;
            }
         } else if(!bullish && !fvgs[i].bullish) {
            if(current_high >= fvgs[i].low && current_low <= fvgs[i].mid && current_price > fvgs[i].low) {
               Print("IOFED SELL signal detected at FVG: ", fvgs[i].mid);
               return true;
            }
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Enhanced ICT Entry Conditions with IOFED                         |
//+------------------------------------------------------------------+
bool CheckICTEntry(bool bullish) {
   double current_price = iClose(_Symbol, TimeFrame, 1);
   double atr = GetATR(14, TimeFrame, 1);
   double ema20 = GetEMA(20, TimeFrame, 1);
   double ema50 = GetEMA(50, TimeFrame, 1);
   double rsi = GetRSI(14, TimeFrame, 1);
   
   // Check for IOFED entries first (highest priority)
   if(EnableIOFED) {
      if(DetectIOFED(bullish, 1)) {
         return true;
      }
   }
   
   // Check for advanced ICT patterns
   bool judas_signal = false;
   bool ce_signal = false;
   bool inversion_signal = false;
   bool relative_signal = false;
   
   if(EnableJudasSwing) {
      judas_signal = DetectJudasSwing(1);
   }
   
   if(EnableConsequentEncroachment) {
      ce_signal = DetectConsequentEncroachment(1);
   }
   
   if(EnableInversionFVG) {
      inversion_signal = DetectInversionFVG(1);
   }
   
   if(EnableRelativeEqualLevels) {
      relative_signal = DetectRelativeEqualLevels(1);
   }
   
   // Check for FVG entries
   bool fvg_signal = false;
   if(EnableFVGs) {
      for(int i = 0; i < fvg_count; i++) {
         if(!fvgs[i].filled && fvgs[i].active) {
            double distance = MathAbs(current_price - fvgs[i].mid);
            if(distance < atr * FVG_ReactionDistance) {
               if((bullish && fvgs[i].bullish) || (!bullish && !fvgs[i].bullish)) {
                  fvg_signal = true;
                  break;
               }
            }
         }
      }
   }
   
   // Check for Order Block entries
   bool ob_signal = false;
   if(EnableOrderBlocks) {
      for(int i = 0; i < ob_count; i++) {
         if(obs[i].active) {
            if(current_price >= obs[i].low && current_price <= obs[i].high) {
               if((bullish && obs[i].bullish) || (!bullish && !obs[i].bullish)) {
                  ob_signal = true;
                  break;
               }
            }
         }
      }
   }
   
   // Check for Breaker entries
   bool breaker_signal = false;
   if(EnableBreakers) {
      for(int i = 0; i < breaker_count; i++) {
         if(breakers[i].active) {
            double distance = MathAbs(current_price - breakers[i].level);
            if(distance < atr * 0.3) {
               if((bullish && breakers[i].bullish) || (!bullish && !breakers[i].bullish)) {
                  breaker_signal = true;
                  break;
               }
            }
         }
      }
   }
   
   // Check for Turtle Soup
   bool turtle_signal = false;
   if(EnableTurtleSoup) {
      turtle_signal = DetectTurtleSoup(1);
   }
   
   // Calculate signal strength
   double signalStrength = CalculateSignalStrength(bullish, fvg_signal, ob_signal, breaker_signal, turtle_signal, judas_signal, ce_signal, inversion_signal, relative_signal);
   
   // Require minimum signal strength
   if(signalStrength < 0.4) return false;
   
   // Additional filters
   if(bullish) {
      return (current_price > ema20 && current_price > ema50 && rsi < 70);
   } else {
      return (current_price < ema20 && current_price < ema50 && rsi > 30);
   }
}

//+------------------------------------------------------------------+
//| Manage Partial Profits                                           |
//+------------------------------------------------------------------+
void ManagePartialProfits() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double tp = PositionGetDouble(POSITION_TP);
      double volume = PositionGetDouble(POSITION_VOLUME);
      long type = PositionGetInteger(POSITION_TYPE);
      
      double current_price = (type == POSITION_TYPE_BUY) ? 
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                           SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      double profit_pips = (type == POSITION_TYPE_BUY) ? 
                          (current_price - entry) / _Point : 
                          (entry - current_price) / _Point;
      
      double target_pips = (type == POSITION_TYPE_BUY) ? 
                          (tp - entry) / _Point : 
                          (entry - tp) / _Point;
      
      // Take partial profit at 50% of target
      if(!partial_taken && profit_pips >= target_pips * PartialProfitLevel) {
         double partial_volume = volume * PartialTP_Close;
         
         MqlTradeRequest req;
         MqlTradeResult res;
         ZeroMemory(req);
         ZeroMemory(res);
         
         req.action = TRADE_ACTION_DEAL;
         req.symbol = _Symbol;
         req.volume = partial_volume;
         req.position = ticket;
         req.type = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         req.price = current_price;
         req.deviation = Slippage;
         req.magic = MagicNumber;
         req.comment = "Partial_Profit";
         
         if(OrderSend(req, res)) {
            Print("Partial profit taken for ticket ", ticket, " at ", profit_pips, " pips");
            partial_taken = true;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Enhanced Position Management                                     |
//+------------------------------------------------------------------+
void ManagePositions() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double volume = PositionGetDouble(POSITION_VOLUME);
      long type = PositionGetInteger(POSITION_TYPE);
      
      double current_price = (type == POSITION_TYPE_BUY) ? 
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                           SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      double profit_pips = (type == POSITION_TYPE_BUY) ? 
                          (current_price - entry) / _Point : 
                          (entry - current_price) / _Point;
      
      // Move to breakeven
      if(profit_pips >= BreakevenPips) {
         double new_sl = entry;
         if((type == POSITION_TYPE_BUY && new_sl > sl) || 
            (type == POSITION_TYPE_SELL && new_sl < sl)) {
            
            MqlTradeRequest req;
            MqlTradeResult res;
            ZeroMemory(req);
            ZeroMemory(res);
            
            req.action = TRADE_ACTION_SLTP;
            req.symbol = _Symbol;
            req.position = ticket;
            req.sl = new_sl;
            req.tp = tp;
            req.magic = MagicNumber;
            
            if(OrderSend(req, res)) {
               Print("Moved SL to breakeven for ticket ", ticket);
            }
         }
      }
   }
   
   // Manage partial profits
   if(EnablePartialProfits) {
      ManagePartialProfits();
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                |
//+------------------------------------------------------------------+
double CalculateLotSize(double stopLossPips) {
   double adaptiveRisk = CalculateAdaptiveRisk();
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * adaptiveRisk / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   if(stopLossPips <= 0.0) return 0.01;
   
   double lot = riskAmount / (stopLossPips * (tickValue / tickSize));
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathFloor(lot / lotStep) * lotStep;
   
   return lot;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, TimeFrame, 0);
   
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;
   
   // Reset daily counters
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   MqlDateTime last_dt;
   TimeToStruct(last_trade_date, last_dt);
   if(dt.day != last_dt.day) {
      daily_trades = 0;
      daily_profit = 0.0;
   }
   
   // Check daily limits
   if(daily_trades >= MaxDailyTrades) {
      Print("Daily trade limit reached");
      return;
   }
   
   double daily_loss_limit = AccountInfoDouble(ACCOUNT_BALANCE) * MaxDailyLoss / 100.0;
   if(daily_profit < -daily_loss_limit) {
      Print("Daily loss limit reached");
      return;
   }
   
   // Cooldown after losses
   if(consecutive_losses >= 2 && (TimeCurrent() - last_loss_time) < 4 * 3600) {
      Print("Cooldown active");
      return;
   }
   
   // Detect market condition
   if(EnableLRLRDetection) {
      DetectMarketCondition();
   }
   
   // Detect enhanced ICT patterns
   DetectFVG(1);
   DetectOrderBlock(1);
   DetectBreaker(1);
   DetectRelativeEqualLevels(1);
   DetectLiquidityZones();
   
   // Check for NDOG
   if(EnableNDOG && HasNDOG()) {
      Print("NDOG detected - potential setup");
   }
   
   // Check if in kill zone
   if(EnableTimeBased && !IsInKillZone()) {
      return; // Only trade during kill zones
   }
   
   // Check for entry conditions
   bool bullish_signal = CheckICTEntry(true);
   bool bearish_signal = CheckICTEntry(false);
   
   if(!bullish_signal && !bearish_signal) return;
   
   // Calculate entry parameters
   double atr = GetATR(14, TimeFrame, 1);
   double entry, stopLoss, takeProfit, lotSize;
   
   if(bullish_signal) {
      if(EnableLimitOrders) {
         entry = SymbolInfoDouble(_Symbol, SYMBOL_BID); // Use bid for limit buy
      } else {
         entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      }
      
      double baseStopLoss = entry - 1.0 * atr;
      stopLoss = CalculateAdaptiveStopLoss(baseStopLoss);
      takeProfit = entry + RR_Ratio * atr;
      double stopLossPips = (entry - stopLoss) / _Point;
      double baseLotSize = CalculateLotSize(stopLossPips);
      
      // Calculate signal strength for adaptive lot sizing
      double signalStrength = CalculateSignalStrength(true, false, false, false, false, false, false, false, false);
      lotSize = CalculateAdaptiveLotSize(baseLotSize, signalStrength);
      
      MqlTradeRequest req;
      MqlTradeResult res;
      ZeroMemory(req);
      ZeroMemory(res);
      
      req.action = TRADE_ACTION_DEAL;
      req.symbol = _Symbol;
      req.volume = lotSize;
      req.type = ORDER_TYPE_BUY;
      req.price = entry;
      req.sl = stopLoss;
      req.tp = takeProfit;
      req.deviation = Slippage;
      req.magic = MagicNumber;
      req.comment = "ICT_ADVANCED_BULL";
      
      if(OrderSend(req, res)) {
         daily_trades++;
         last_trade_date = TimeCurrent();
         partial_taken = false;
         Print("Advanced ICT BUY order placed: Entry=", entry, " SL=", stopLoss, " TP=", takeProfit, " Lot=", lotSize, " Market=", (isLRLR ? "LRLR" : "HRLR"));
      }
   }
   
   if(bearish_signal) {
      if(EnableLimitOrders) {
         entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK); // Use ask for limit sell
      } else {
         entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      }
      
      double baseStopLoss = entry + 1.0 * atr;
      stopLoss = CalculateAdaptiveStopLoss(baseStopLoss);
      takeProfit = entry - RR_Ratio * atr;
      double stopLossPips = (stopLoss - entry) / _Point;
      double baseLotSize = CalculateLotSize(stopLossPips);
      
      // Calculate signal strength for adaptive lot sizing
      double signalStrength = CalculateSignalStrength(false, false, false, false, false, false, false, false, false);
      lotSize = CalculateAdaptiveLotSize(baseLotSize, signalStrength);
      
      MqlTradeRequest req;
      MqlTradeResult res;
      ZeroMemory(req);
      ZeroMemory(res);
      
      req.action = TRADE_ACTION_DEAL;
      req.symbol = _Symbol;
      req.volume = lotSize;
      req.type = ORDER_TYPE_SELL;
      req.price = entry;
      req.sl = stopLoss;
      req.tp = takeProfit;
      req.deviation = Slippage;
      req.magic = MagicNumber;
      req.comment = "ICT_ADVANCED_BEAR";
      
      if(OrderSend(req, res)) {
         daily_trades++;
         last_trade_date = TimeCurrent();
         partial_taken = false;
         Print("Advanced ICT SELL order placed: Entry=", entry, " SL=", stopLoss, " TP=", takeProfit, " Lot=", lotSize, " Market=", (isLRLR ? "LRLR" : "HRLR"));
      }
   }
   
   ManagePositions();
} 