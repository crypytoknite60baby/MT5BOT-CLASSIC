//+------------------------------------------------------------------+
//|                                                    ICT_ALGO.mq5 |
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
input bool   EnableIOFED = true;             // Enable IOFED (wick into FVG, no full close)
input bool   EnableLRLRDetection = true;     // Enable LRLR/HRLR detection
input bool   EnableLimitOrders = true;       // Use limit orders for precision
input bool   EnablePartialProfits = true;    // Take partial profits mid-target

//--- Advanced ICT Parameters
input double FVG_ReactionDistance = 0.3;     // ATR multiplier for FVG proximity
input double RelativeLevelTolerance = 0.001; // Tolerance for relative equal levels
input double MinimumBodySize = 0.4;          // ATR multiplier for strong bodies
// --- Switch defaults to simpler behavior
input bool   UseHTFBias = false;              // Trade with HTF bias (EMA)
input int    HTF_EMA = 200;                   // HTF EMA period
input bool   RequireDisplacement = false;     // Require displacement candle
input double DisplacementAtr = 0.8;           // Body > x*ATR to qualify
input bool   RequireLiquiditySweep = false;   // Require liquidity sweep before entry
input int    SweepLookback = 5;               // Bars to look back for sweep
input bool   UseOTE = false;                  // Require OTE retracement zone
input double OTE_Min = 0.62;                  // Min retracement
input double OTE_Max = 0.79;                  // Max retracement
input bool   UseFibEntry = false;             // Use specific Fibonacci entry
input double FibEntry = 0.705;                // Fibonacci entry level (e.g., 0.705)
input bool   PlacePendingOrders = false;      // Place pending limit orders at Fib entry
input int    CancelPendingMinutes = 180;      // Auto-cancel pending after N minutes
input bool   UseFibTPExt = false;             // Use Fibonacci extension for TP
input double FibTP = 1.272;                   // Fib extension (1.272 or 1.618)
input bool   UseDynamicTP = true;             // Use liquidity/Fibonacci-based TP when available
input bool   PartialOnlyInHRLR = true;        // Take partials only in HRLR conditions
// Momentum pump catcher
input bool   EnablePumpCatch = true;          // Allow momentum pump entries
input double PumpBodyATR = 1.2;               // Body >= this * ATR qualifies
input bool   PumpBreakPrev = true;            // Require break of previous high/low

// Anti flip/whipsaw and execution hygiene
input int    AntiFlipMinutes = 30;            // Block opposite entries for N minutes after a trade
input double PumpPullbackPct = 0.30;          // Require this % pullback of pump body before entry
input int    PumpPullbackBars = 3;            // Max bars to wait for pullback after pump
input int    MinHoldBars = 2;                 // Minimum bars to hold before breakeven/management
input double MinRRBeforeOpposite = 0.5;       // Block opposite entries until current trade reaches this RR
input int    MinSpreadPoints = 25;            // Skip entries if spread too wide (points)

// Relax throttles a bit
input int    MaxTradesPerSession = 6;         // Session throttle
input int    MinMinutesBetweenTrades = 5;     // Min minutes between trades

//--- Time-based Trading (NY Local Time)
input int    LondonKillZone_Start = 2;       // London Kill Zone Start (2 AM ET)
input int    LondonKillZone_End = 4;         // London Kill Zone End (4 AM ET)
input int    NYOpen_Start = 9;               // NY Open Start (9:30 AM ET)
input int    NYOpen_End = 10;                // NY Open End (10:00 AM ET)
input int    LunchMacro = 11;                // Lunch Macro (11:30 AM ET)
input int    PM_Macro = 14;                  // PM Macro (2:50 PM ET)

//--- Risk Management
input double MaxDailyLoss = 7.0;             // Max daily loss (%)
input int    MaxDailyTrades = 8;             // Max daily trades
input double BreakevenPips = 12.0;           // Pips to move SL to breakeven
input double PartialTP_Percent = 50.0;       // Partial TP percentage (unused here)
input double PartialTP_Close = 0.5;          // Close % at partial TP
input double HRLR_StopMultiplier = 2.0;      // Wider stops in HRLR

//--- Global Variables
bool trade_in_progress = false;
int consecutive_losses = 0;
datetime last_loss_time = 0;
int daily_trades = 0;
double daily_profit = 0.0;
datetime last_trade_date = 0;
double initial_balance = 0.0;
bool isLRLR = true;               // Default assume LRLR until detected
bool partial_taken = false;       // Track partial TP status
datetime last_trade_time = 0;     // Throttle trades
int session_trade_count = 0;      // Trades taken this session
int last_trade_dir = 0; // 1=buy, -1=sell, 0=none

//--- ICT Arrays
struct FVG {
   double high, low, mid;
   bool bullish;
   datetime time;
   bool filled;
   bool active;           // NEW: active flag
   bool isInversion;      // NEW: inversion FVG
   double q25, q50, q75;  // NEW: quadrant levels inside FVG
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

FVG fvgs[100];
OrderBlock obs[50];
Breaker breakers[30];
int fvg_count = 0, ob_count = 0, breaker_count = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   initial_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   Print("ICT Algorithmic Trading System Initialized");
   Print("Balance: $", initial_balance);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Print("ICT Algorithmic Trading System Deinitialized");
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

// Calculate adaptive risk based on LRLR/HRLR
double CalculateAdaptiveRisk() {
   if(!EnableLRLRDetection) return RiskPercent;
   return isLRLR ? RiskPercent * 1.2 : RiskPercent * 0.8;
}

// Calculate lot size based on risk (uses adaptive risk)
double CalculateLotSize(double stopLossPips) {
   double riskPct = CalculateAdaptiveRisk();
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0;
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

// Detect LRLR vs HRLR by candle overlap
double GetOverlapRatio() {
   int lookback = 10; double overlaps = 0;
   for(int i=1; i<=lookback; i++) {
      double h1=iHigh(_Symbol,TimeFrame,i), l1=iLow(_Symbol,TimeFrame,i);
      double h2=iHigh(_Symbol,TimeFrame,i+1), l2=iLow(_Symbol,TimeFrame,i+1);
      if(MathMax(l1,l2) < MathMin(h1,h2)) overlaps++;
   }
   return overlaps / 10.0;
}

void DetectMarketCondition() {
   if(!EnableLRLRDetection) { isLRLR=true; return; }
   double ratio = GetOverlapRatio();
   // Lower overlap => LRLR
   isLRLR = (ratio < 0.7);
}

//+------------------------------------------------------------------+
//| Detect Fair Value Gap (FVG)                                     |
//+------------------------------------------------------------------+
bool DetectFVG(int shift=1) {
   double high1 = iHigh(_Symbol, TimeFrame, shift+2);
   double low1 = iLow(_Symbol, TimeFrame, shift+2);
   double high3 = iHigh(_Symbol, TimeFrame, shift);
   double low3 = iLow(_Symbol, TimeFrame, shift);
   
   // Bullish FVG
   if(low3 > high1 && fvg_count < 100) {
      fvgs[fvg_count].high = high3;
      fvgs[fvg_count].low  = low1;
      fvgs[fvg_count].mid  = (high3 + low1) / 2;
      fvgs[fvg_count].bullish = true;
      fvgs[fvg_count].time = iTime(_Symbol, TimeFrame, shift);
      fvgs[fvg_count].filled=false; fvgs[fvg_count].active=true; fvgs[fvg_count].isInversion=false;
      double range = high3 - low1; fvgs[fvg_count].q25 = low1+range*0.25; fvgs[fvg_count].q50=low1+range*0.50; fvgs[fvg_count].q75=low1+range*0.75;
      fvg_count++; Print("Bullish FVG detected at ", fvgs[fvg_count-1].mid);
      return true;
   }
   // Bearish FVG
   if(high3 < low1 && fvg_count < 100) {
      fvgs[fvg_count].high = high1;
      fvgs[fvg_count].low  = low3;
      fvgs[fvg_count].mid  = (high1 + low3) / 2;
      fvgs[fvg_count].bullish = false;
      fvgs[fvg_count].time = iTime(_Symbol, TimeFrame, shift);
      fvgs[fvg_count].filled=false; fvgs[fvg_count].active=true; fvgs[fvg_count].isInversion=false;
      double range = high1 - low3; fvgs[fvg_count].q25 = low3+range*0.25; fvgs[fvg_count].q50=low3+range*0.50; fvgs[fvg_count].q75=low3+range*0.75;
      fvg_count++; Print("Bearish FVG detected at ", fvgs[fvg_count-1].mid);
      return true;
   }
   return false;
}

// IOFED: wick into FVG without full close
bool DetectIOFED(bool bullish, int shift=1) {
   if(!EnableIOFED) return false;
   double c=iClose(_Symbol,TimeFrame,shift), o=iOpen(_Symbol,TimeFrame,shift);
   double h=iHigh(_Symbol,TimeFrame,shift), l=iLow(_Symbol,TimeFrame,shift);
   double atr = GetATR(14, TimeFrame, shift);
   if(MathAbs(c-o) < atr*MinimumBodySize) return false;
   for(int i=0;i<fvg_count;i++) {
      if(!fvgs[i].active || fvgs[i].filled) continue;
      if(bullish && fvgs[i].bullish) {
         if(l <= fvgs[i].high && h >= fvgs[i].q50 && c < fvgs[i].high) return true;
      }
      if(!bullish && !fvgs[i].bullish) {
         if(h >= fvgs[i].low && l <= fvgs[i].q50 && c > fvgs[i].low) return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Detect Order Block                                               |
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
   
   // Bullish Order Block: strong down candle before up move
   if(close < open && move > atr * 0.8) {
      if(ob_count < 50) {
         obs[ob_count].high = high;
         obs[ob_count].low = low;
         obs[ob_count].mid = (high + low) / 2;
         obs[ob_count].bullish = true;
         obs[ob_count].time = iTime(_Symbol, TimeFrame, shift);
         obs[ob_count].active = true;
         ob_count++;
         Print("Bullish Order Block detected at ", obs[ob_count-1].mid);
         return true;
      }
}

   // Bearish Order Block: strong up candle before down move
   if(close > open && move > atr * 0.8) {
      if(ob_count < 50) {
         obs[ob_count].high = high;
         obs[ob_count].low = low;
         obs[ob_count].mid = (high + low) / 2;
         obs[ob_count].bullish = false;
         obs[ob_count].time = iTime(_Symbol, TimeFrame, shift);
         obs[ob_count].active = true;
         ob_count++;
         Print("Bearish Order Block detected at ", obs[ob_count-1].mid);
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Detect Breaker                                                   |
//+------------------------------------------------------------------+
bool DetectBreaker(int shift=1) {
   double high1 = iHigh(_Symbol, TimeFrame, shift+2);
   double low1 = iLow(_Symbol, TimeFrame, shift+2);
   double high2 = iHigh(_Symbol, TimeFrame, shift+1);
   double low2 = iLow(_Symbol, TimeFrame, shift+1);
   double high3 = iHigh(_Symbol, TimeFrame, shift);
   double low3 = iLow(_Symbol, TimeFrame, shift);
   
   // Bearish Breaker: high-low-higher high
   if(high2 < high1 && high3 > high1) {
      if(breaker_count < 30) {
         breakers[breaker_count].level = high1;
         breakers[breaker_count].bullish = false;
         breakers[breaker_count].time = iTime(_Symbol, TimeFrame, shift);
         breakers[breaker_count].active = true;
         breaker_count++;
         Print("Bearish Breaker detected at ", breakers[breaker_count-1].level);
         return true;
      }
   }
   
   // Bullish Breaker: low-high-lower low
   if(low2 > low1 && low3 < low1) {
      if(breaker_count < 30) {
         breakers[breaker_count].level = low1;
         breakers[breaker_count].bullish = true;
         breakers[breaker_count].time = iTime(_Symbol, TimeFrame, shift);
         breakers[breaker_count].active = true;
         breaker_count++;
         Print("Bullish Breaker detected at ", breakers[breaker_count-1].level);
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Detect Turtle Soup                                               |
//+------------------------------------------------------------------+
bool DetectTurtleSoup(int shift=1) {
   double current_high = iHigh(_Symbol, TimeFrame, shift);
   double current_low = iLow(_Symbol, TimeFrame, shift);
   double prev_high = iHigh(_Symbol, TimeFrame, shift+1);
   double prev_low = iLow(_Symbol, TimeFrame, shift+1);
   
   // Look for sweep of previous high/low followed by reversal
   double atr = GetATR(14, TimeFrame, shift);

   // Bullish Turtle Soup: sweep low then reverse up
   if(current_low < prev_low && iClose(_Symbol, TimeFrame, shift) > prev_low) {
      double body = MathAbs(iClose(_Symbol, TimeFrame, shift) - iOpen(_Symbol, TimeFrame, shift));
      if(body > atr * 0.5) {
         Print("Bullish Turtle Soup detected at ", prev_low);
         return true;
     }
   }
   
   // Bearish Turtle Soup: sweep high then reverse down
   if(current_high > prev_high && iClose(_Symbol, TimeFrame, shift) < prev_high) {
      double body = MathAbs(iClose(_Symbol, TimeFrame, shift) - iOpen(_Symbol, TimeFrame, shift));
      if(body > atr * 0.5) {
         Print("Bearish Turtle Soup detected at ", prev_high);
         return true;
     }
   }
   
   return false;
  }

//+------------------------------------------------------------------+
//| Check if current time is in kill zone (with minutes)
bool IsInKillZone() {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int hour=dt.hour, minute=dt.min;
   if(hour>=LondonKillZone_Start && hour<=LondonKillZone_End) return true;
   if(hour==NYOpen_Start && minute>=30) return true; // 9:30-10:00
   if(hour==NYOpen_End && minute<=0) return true;
   if(hour==LunchMacro && minute>=30) return true;   // 11:30+
   if(hour==PM_Macro && minute>=50) return true;     // 14:50+
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

// --- HTF Bias
bool HTFBias(bool bullish) {
  if(!UseHTFBias) return true;
  double ema = GetEMA(HTF_EMA, HTF, 1);
  double price = iClose(_Symbol, HTF, 1);
  return bullish ? (price > ema) : (price < ema);
}

// --- Displacement candle check
bool HasDisplacement(bool bullish, int shift=1) {
  if(!RequireDisplacement) return true;
  double body = MathAbs(iClose(_Symbol, TimeFrame, shift)-iOpen(_Symbol, TimeFrame, shift));
  double atr  = GetATR(14, TimeFrame, shift);
  if(body < DisplacementAtr*atr) return false;
  if(!PumpBreakPrev) return true;
  if(bullish) { double prevHigh = iHigh(_Symbol, TimeFrame, shift+1); return (iClose(_Symbol, TimeFrame, shift) > prevHigh); }
  else { double prevLow = iLow(_Symbol, TimeFrame, shift+1); return (iClose(_Symbol, TimeFrame, shift) < prevLow); }
}

// Momentum pump detector (uses last closed candle)
bool IsPump(bool bullish, int shift=1) {
  if(!EnablePumpCatch) return false;
  double body = MathAbs(iClose(_Symbol, TimeFrame, shift)-iOpen(_Symbol, TimeFrame, shift));
  double atr  = GetATR(14, TimeFrame, shift);
  if(body < PumpBodyATR*atr) return false;
  if(!PumpBreakPrev) return true;
  if(bullish) { double prevHigh = iHigh(_Symbol, TimeFrame, shift+1); return (iHigh(_Symbol, TimeFrame, shift) > prevHigh); }
  else { double prevLow = iLow(_Symbol, TimeFrame, shift+1); return (iLow(_Symbol, TimeFrame, shift) < prevLow); }
}

// --- Liquidity sweep (Turtle Soup style) in recent bars
bool SweptLiquidity(bool bullish) {
  if(!RequireLiquiditySweep) return true;
  double prevExtreme=0, curExtreme=0;
  if(bullish) {
    prevExtreme = iLow(_Symbol, TimeFrame, 2);
    for(int i=2;i<=SweepLookback+1;i++) prevExtreme = MathMin(prevExtreme, iLow(_Symbol, TimeFrame, i));
    curExtreme = iLow(_Symbol, TimeFrame, 1);
    return (curExtreme < prevExtreme); // swept sell-side
  } else {
    prevExtreme = iHigh(_Symbol, TimeFrame, 2);
    for(int i=2;i<=SweepLookback+1;i++) prevExtreme = MathMax(prevExtreme, iHigh(_Symbol, TimeFrame, i));
    curExtreme = iHigh(_Symbol, TimeFrame, 1);
    return (curExtreme > prevExtreme); // swept buy-side
  }
}

// --- Simple swing finder (last N bars)
void FindSwing(int lookback, bool bullish, double &swingLow, double &swingHigh) {
  swingLow = iLow(_Symbol, TimeFrame, 1);
  swingHigh = iHigh(_Symbol, TimeFrame, 1);
  for(int i=1;i<=lookback;i++) {
    swingLow  = MathMin(swingLow,  iLow(_Symbol, TimeFrame, i));
    swingHigh = MathMax(swingHigh, iHigh(_Symbol, TimeFrame, i));
  }
}

// --- OTE zone check using last swing range
bool InOTEZone(bool bullish) {
  if(!UseOTE) return true;
  double low, high; FindSwing(10, bullish, low, high);
  double price = iClose(_Symbol, TimeFrame, 1);
  if(bullish) {
    double retr = (high - price) / MathMax(0.0000001, (high - low));
    return (retr >= OTE_Min && retr <= OTE_Max);
  } else {
    double retr = (price - low) / MathMax(0.0000001, (high - low));
    return (retr >= OTE_Min && retr <= OTE_Max);
  }
}

// Compute Fib entry and extension targets from swing
void GetFibLevels(bool bullish, double &entryPrice, double &tpPrice, double atr) {
  double low, high; FindSwing(10, bullish, low, high);
  if(bullish) {
    double range = high - low;
    entryPrice = high - range*FibEntry;
    if(UseFibTPExt) tpPrice = high + range*(FibTP-1.0); else tpPrice = 0.0;
  } else {
    double range = high - low;
    entryPrice = low + range*FibEntry;
    if(UseFibTPExt) tpPrice = low - range*(FibTP-1.0); else tpPrice = 0.0;
  }
}

// --- Nearest simple liquidity target (recent swing)
double NearestLiquidityTP(bool bullish) {
  if(!UseDynamicTP) return 0.0;
  double low, high; FindSwing(20, bullish, low, high);
  return bullish ? high : low;
}

// Helpers
int BarsSince(datetime t) { return (int)MathMax(0,(TimeCurrent()-t)/ (double)(PeriodSeconds(TimeFrame))); }
bool SpreadOK(){ double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID); return ((ask-bid)/_Point) <= MinSpreadPoints; }

// Get last pump candle info
bool GetLastPumpCandle(bool bullish, int &pumpShift) {
  for(int s=1; s<=PumpPullbackBars; s++) if(IsPump(bullish,s)) { pumpShift=s; return true; }
  return false;
}

bool PullbackFromPumpOK(bool bullish){
  int sh; if(!GetLastPumpCandle(bullish, sh)) return true; // no pump recently -> OK
  double o=iOpen(_Symbol,TimeFrame,sh), c=iClose(_Symbol,TimeFrame,sh);
  double body=c-o; if(body==0) return false;
  double hi=iHigh(_Symbol,TimeFrame,sh), lo=iLow(_Symbol,TimeFrame,sh);
  double now=iClose(_Symbol,TimeFrame,1);
  if(bullish){ // require pullback into lower portion of pump body
    double entryLevel = o + body*(1.0-PumpPullbackPct);
    return (now <= MathMax(o,entryLevel));
  } else {
    double entryLevel = o + body*(PumpPullbackPct);
    return (now >= MathMin(o,entryLevel));
  }
}

// Prevent flip-flop: block opposite within AntiFlipMinutes and until RR threshold is met
bool CanOpenDirection(bool bullish){
  if(last_trade_time!=0 && (TimeCurrent()-last_trade_time) < AntiFlipMinutes*60) {
    if((bullish && last_trade_dir==-1) || (!bullish && last_trade_dir==1)) return false;
  }
  // If there is an open position same symbol, avoid immediate opposite unless RR achieved
  for(int i=PositionsTotal()-1;i>=0;i--){
    ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
    if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
    if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
    long type=PositionGetInteger(POSITION_TYPE);
    if((bullish && type==POSITION_TYPE_SELL) || (!bullish && type==POSITION_TYPE_BUY)){
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double price=(type==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double oneR=(type==POSITION_TYPE_BUY)?(entry - sl):(sl - entry); if(oneR<=0) return false;
      double u=(type==POSITION_TYPE_BUY)?(price-entry):(entry-price);
      double rr=u/oneR; if(rr < MinRRBeforeOpposite) return false;
    }
  }
  return true;
}

//+------------------------------------------------------------------+
//| Check for ICT entry conditions                                  |
//+------------------------------------------------------------------+
bool CheckICTEntry(bool bullish) {
   double current_price = iClose(_Symbol, TimeFrame, 1);
   double atr = GetATR(14, TimeFrame, 1);
   double ema20 = GetEMA(20, TimeFrame, 1);
   double ema50 = GetEMA(50, TimeFrame, 1);
   double rsi = GetRSI(14, TimeFrame, 1);

   if(!SpreadOK()) return false;             // skip wide spreads
   if(!CanOpenDirection(bullish)) return false; // anti-flip logic
   if(!PullbackFromPumpOK(bullish)) return false; // wait for pullback after pump

   // Optional: advanced filters if enabled
   if(UseHTFBias && !HTFBias(bullish)) return false;
   if(!HasDisplacement(bullish,1)) return false; // respects RequireDisplacement flag
   if(RequireLiquiditySweep && !SweptLiquidity(bullish)) return false;
   if(UseOTE && !InOTEZone(bullish)) return false;

   // Simple ICT arrays first
   // 1) FVG proximity
   if(EnableFVGs) {
      for(int i=0;i<fvg_count;i++) {
         if(!fvgs[i].active || fvgs[i].filled) continue;
         double distance = MathAbs(current_price - fvgs[i].mid);
         if(distance < atr * FVG_ReactionDistance) {
            if((bullish && fvgs[i].bullish) || (!bullish && !fvgs[i].bullish)) return true;
         }
      }
   }
   // 2) Order Block zone
   if(EnableOrderBlocks) {
      for(int i=0;i<ob_count;i++) {
         if(!obs[i].active) continue;
         if(current_price>=obs[i].low && current_price<=obs[i].high) {
            if((bullish && obs[i].bullish) || (!bullish && !obs[i].bullish)) return true;
         }
      }
   }
   // 3) Breaker proximity
   if(EnableBreakers) {
      for(int i=0;i<breaker_count;i++) {
         if(!breakers[i].active) continue;
         double distance = MathAbs(current_price - breakers[i].level);
         if(distance < atr*0.3) {
            if((bullish && breakers[i].bullish) || (!bullish && !breakers[i].bullish)) return true;
         }
      }
   }
   // 4) Turtle Soup reversal signal
   if(EnableTurtleSoup && DetectTurtleSoup(1)) return true;

   // 5) Momentum pump catcher (entries near big pumps)
   if(IsPump(bullish,1)) return true;

   // Final trend/RSI sanity (loose)
   if(bullish) return (current_price > ema20 && rsi < 75);
   else        return (current_price < ema20 && rsi > 25);
}

// Manage partial profits at 50% to target
void ManagePartialProfits() {
   if(!EnablePartialProfits) return;
   if(PartialOnlyInHRLR && isLRLR) return; // only take partials in HRLR
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double tp    = PositionGetDouble(POSITION_TP);
      double vol   = PositionGetDouble(POSITION_VOLUME);
      double price = (type==POSITION_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double profPips = (type==POSITION_TYPE_BUY)?(price-entry)/_Point:(entry-price)/_Point;
      double tgtPips  = (type==POSITION_TYPE_BUY)?(tp-entry)/_Point:(entry-tp)/_Point;
      if(!partial_taken && tgtPips>0 && profPips >= tgtPips*0.5) {
         double closeVol = vol * PartialTP_Close;
         MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
         req.action=TRADE_ACTION_DEAL; req.symbol=_Symbol; req.volume=closeVol; req.position=ticket;
         req.type = (type==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY; req.price=price; req.deviation=Slippage; req.magic=MagicNumber; req.comment="PartialTP";
         if(OrderSend(req,res)) { partial_taken=true; Print("Partial profit taken on ", ticket); }
      }
   }
}

// Helper: check existing pending order at similar price
bool PendingExists(int order_type, double price, double tolPoints) {
  for(int i=OrdersTotal()-1;i>=0;i--) {
    ulong ticket = OrderGetTicket(i);
    if(!OrderSelect(ticket)) continue;
    if((int)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
    if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
    int type = (int)OrderGetInteger(ORDER_TYPE);
    if(type != order_type) continue;
    double p = OrderGetDouble(ORDER_PRICE_OPEN);
    if(MathAbs(p - price) <= tolPoints*_Point) return true;
  }
  return false;
}

// Auto-cancel stale pending orders
void CancelStalePendings() {
  datetime now = TimeCurrent();
  for(int i=OrdersTotal()-1;i>=0;i--) {
    ulong ticket = OrderGetTicket(i);
    if(!OrderSelect(ticket)) continue;
    if((int)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
    if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
    int type = (int)OrderGetInteger(ORDER_TYPE);
    if(type!=ORDER_TYPE_BUY_LIMIT && type!=ORDER_TYPE_SELL_LIMIT) continue;
    datetime timeSetup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
    if((now - timeSetup) > CancelPendingMinutes*60) {
      MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
      rq.action = TRADE_ACTION_REMOVE; rq.order = ticket; rq.magic = MagicNumber; rq.symbol = _Symbol;
      if(!OrderSend(rq, rs)) {
        Print("Failed to remove pending order ", ticket, " ret=", rs.retcode);
      }
    }
  }
}

//+------------------------------------------------------------------+
//| Manage open positions                                            |
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
      long type = PositionGetInteger(POSITION_TYPE);
      datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      int barsOpen = BarsSince(ot);
      double current_price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profit_pips = (type == POSITION_TYPE_BUY) ? (current_price - entry) / _Point : (entry - current_price) / _Point;
      if(barsOpen >= MinHoldBars && profit_pips >= BreakevenPips) {
         double new_sl = entry;
         if((type == POSITION_TYPE_BUY && new_sl > sl) || (type == POSITION_TYPE_SELL && new_sl < sl)) {
            MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
            req.action = TRADE_ACTION_SLTP; req.symbol = _Symbol; req.position = ticket; req.sl = new_sl; req.tp = tp; req.magic = MagicNumber;
            if(OrderSend(req, res)) { Print("Moved SL to breakeven for ticket ", ticket); }
         }
      }
   }
   ManagePartialProfits();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, TimeFrame, 0);
   if(currentBarTime == lastBarTime) return; lastBarTime = currentBarTime;

   // Reset daily counters (fix TimeDay usage)
   MqlDateTime dtc, dtt; TimeToStruct(TimeCurrent(), dtc); TimeToStruct(last_trade_date, dtt);
   if(dtc.day != dtt.day || dtc.mon != dtt.mon || dtc.year != dtt.year) { daily_trades = 0; daily_profit = 0.0; session_trade_count=0; }

   if(daily_trades >= MaxDailyTrades) { Print("Daily trade limit reached"); return; }
   double daily_loss_limit = AccountInfoDouble(ACCOUNT_BALANCE) * MaxDailyLoss / 100.0;
   if(daily_profit < -daily_loss_limit) { Print("Daily loss limit reached"); return; }
   if(consecutive_losses >= 2 && (TimeCurrent() - last_loss_time) < 4 * 3600) { Print("Cooldown active"); return; }

   // Detect conditions and patterns
   DetectMarketCondition();
   DetectFVG(1); DetectOrderBlock(1); DetectBreaker(1);
   if(EnableNDOG && HasNDOG()) { Print("NDOG detected - potential setup"); }
   if(EnableTimeBased && !IsInKillZone()) return;

   // Session throttling & spacing
   if(session_trade_count >= MaxTradesPerSession) { Print("Session trade cap reached"); return; }
   if(last_trade_time!=0 && (TimeCurrent()-last_trade_time) < MinMinutesBetweenTrades*60) { Print("Spacing throttle active"); return; }

   // housekeeping: cancel stale pending orders
   if(PlacePendingOrders) CancelStalePendings();

   bool bullish_signal = CheckICTEntry(true);
   bool bearish_signal = CheckICTEntry(false);
   if(!bullish_signal && !bearish_signal) return;

   double atr = GetATR(14, TimeFrame, 1);
   double entry, stopLoss, takeProfit, lotSize;

   if(bullish_signal) {
    double fibEntry=0.0, fibTP=0.0; GetFibLevels(true, fibEntry, fibTP, atr);
    if(UseFibEntry && PlacePendingOrders) {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(fibEntry < ask && !PendingExists(ORDER_TYPE_BUY_LIMIT, fibEntry, 5)) {
        double baseSL = fibEntry - 1.0*atr; double sl = isLRLR? baseSL : fibEntry - (HRLR_StopMultiplier*atr);
        double tp = (UseDynamicTP && fibTP>0.0) ? fibTP : fibEntry + RR_Ratio*atr;
        double slPips = (fibEntry - sl)/_Point; lotSize = CalculateLotSize(slPips);
        MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
        rq.action=TRADE_ACTION_PENDING; rq.symbol=_Symbol; rq.volume=lotSize; rq.type=ORDER_TYPE_BUY_LIMIT; rq.price=fibEntry; rq.sl=sl; rq.tp=tp; rq.deviation=Slippage; rq.magic=MagicNumber; rq.comment="ICT_FIB_BUY";
        if(!OrderSend(rq, rs)) {
          Print("Failed to place BUY_LIMIT at ", fibEntry, " ret=", rs.retcode);
        }
      }
      return;
    }
    // market/instant execution path (if not placing pending)
    double entryPx = EnableLimitOrders ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double baseSL = entryPx - 1.0 * atr; double stopLoss = isLRLR ? baseSL : entryPx - (HRLR_StopMultiplier * atr);
    double takeProfit = (UseDynamicTP? (double)NearestLiquidityTP(true): 0.0); if(takeProfit<=0.0) takeProfit = entryPx + RR_Ratio*atr;
    double stopLossPips = (entryPx - stopLoss) / _Point; double lotSize = CalculateLotSize(stopLossPips);
    MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
    req.action=TRADE_ACTION_DEAL; req.symbol=_Symbol; req.volume=lotSize; req.type=ORDER_TYPE_BUY; req.price=entryPx; req.sl=stopLoss; req.tp=takeProfit; req.deviation=Slippage; req.magic=MagicNumber; req.comment="ICT_ADV_BULL";
    if(OrderSend(req,res)) { daily_trades++; session_trade_count++; last_trade_date = TimeCurrent(); last_trade_time=TimeCurrent(); partial_taken=false; last_trade_dir=1; Print("BUY:", entryPx, " SL=", stopLoss, " TP=", takeProfit, " LRLR=", isLRLR); }
  }

  if(bearish_signal) {
    double fibEntry=0.0, fibTP=0.0; GetFibLevels(false, fibEntry, fibTP, atr);
    if(UseFibEntry && PlacePendingOrders) {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(fibEntry > bid && !PendingExists(ORDER_TYPE_SELL_LIMIT, fibEntry, 5)) {
        double baseSL = fibEntry + 1.0*atr; double sl = isLRLR? baseSL : fibEntry + (HRLR_StopMultiplier*atr);
        double tp = (UseDynamicTP && fibTP>0.0) ? fibTP : fibEntry - RR_Ratio*atr;
        double slPips = (sl - fibEntry)/_Point; lotSize = CalculateLotSize(slPips);
        MqlTradeRequest rq; MqlTradeResult rs; ZeroMemory(rq); ZeroMemory(rs);
        rq.action=TRADE_ACTION_PENDING; rq.symbol=_Symbol; rq.volume=lotSize; rq.type=ORDER_TYPE_SELL_LIMIT; rq.price=fibEntry; rq.sl=sl; rq.tp=tp; rq.deviation=Slippage; rq.magic=MagicNumber; rq.comment="ICT_FIB_SELL";
        if(!OrderSend(rq, rs)) {
          Print("Failed to place SELL_LIMIT at ", fibEntry, " ret=", rs.retcode);
        }
      }
      return;
    }
    // market/instant execution path
    double entryPx = EnableLimitOrders ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double baseSL = entryPx + 1.0 * atr; double stopLoss = isLRLR ? baseSL : entryPx + (HRLR_StopMultiplier * atr);
    double takeProfit = (UseDynamicTP? (double)NearestLiquidityTP(false): 0.0); if(takeProfit<=0.0) takeProfit = entryPx - RR_Ratio*atr;
    double stopLossPips = (stopLoss - entryPx) / _Point; double lotSize = CalculateLotSize(stopLossPips);
    MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
    req.action=TRADE_ACTION_DEAL; req.symbol=_Symbol; req.volume=lotSize; req.type=ORDER_TYPE_SELL; req.price=entryPx; req.sl=stopLoss; req.tp=takeProfit; req.deviation=Slippage; req.magic=MagicNumber; req.comment="ICT_ADV_BEAR";
    if(OrderSend(req,res)) { daily_trades++; session_trade_count++; last_trade_date = TimeCurrent(); last_trade_time=TimeCurrent(); partial_taken=false; last_trade_dir=-1; Print("SELL:", entryPx, " SL=", stopLoss, " TP=", takeProfit, " LRLR=", isLRLR); }
  }
  ManagePositions();
} 