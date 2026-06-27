//+------------------------------------------------------------------+
//|                                         PinBarBreakout_Gold.mq5  |
//|   Multi-timeframe pin bar breakout EA for XAUUSD                 |
//|                                                                    |
//|   Logic:                                                          |
//|   - On each new H1 bar, scan the last CLOSED H1 candle for a      |
//|     pin bar (wick >= 3x body, AND body positioned within          |
//|     PinBarBodyPositionPct of the relevant extreme). If found and  |
//|     no signal is already armed, "arm" a breakout watch on that    |
//|     bar's high (bullish pin bar) or low (bearish pin bar).        |
//|   - On each new M15 bar, check if the last CLOSED M15 candle      |
//|     closed beyond the armed level. If so, open a trade.           |
//|   - Armed pin bars expire after MaxBarsToWaitBreakout M15 bars    |
//|     if no breakout occurs.                                        |
//|   - Position size is calculated from RiskPercent of account       |
//|     balance against FixedSL_Dollars.                              |
//|   - TP distance = FixedSL_Dollars * RiskRewardRatio.               |
//|   - Max MaxOpenTrades concurrent positions opened by this EA.      |
//|                                                                    |
//|   v1.01 changes vs v1.00:                                          |
//|   - Added PinBarBodyPositionPct input: body must sit within this  |
//|     % of the candle's range from the wick-side extreme to qualify |
//|     as a real pin bar (long wick alone is no longer enough).      |
//|   - ScanForNewPinBar() now exits immediately if a signal is       |
//|     already armed, instead of silently overwriting it.            |
//|                                                                    |
//|   v1.02 changes vs v1.01:                                          |
//|   - OnTick() M15 detection counts all M15 bars that closed since  |
//|     the last tick via (time delta / period), so "Open prices only" |
//|     mode on any chart timeframe works correctly without skipping   |
//|     bars (e.g. 4 M15 bars close per tick when chart is H1).       |
//|   - gBarsWaited initialised to -1 on arming; the coincident M15   |
//|     check at H1 bar close increments it to 0, so the full         |
//|     MaxBarsToWaitBreakout window remains available for real        |
//|     subsequent breakout bars.                                      |
//+------------------------------------------------------------------+
#property copyright "Yusuf"
#property version   "1.02"
#property strict

#include <Trade\Trade.mqh>

//--- Inputs
input double RiskPercent           = 1.0;   // % of account balance risked per trade
input double FixedSL_Dollars       = 5.0;   // Fixed stop loss distance in price ($)
input double RiskRewardRatio       = 1.5;   // Reward multiple of risk (TP = SL * this)
input int    MaxOpenTrades         = 3;     // Max concurrent open trades from this EA
input double PinBarWickMultiplier  = 3.0;   // Min wick-to-body ratio to qualify as a pin bar
input double PinBarBodyPositionPct = 0.40;  // Body must sit within this % of the wick-side extreme
input int    MaxBarsToWaitBreakout = 20;    // M15 bars before an armed pin bar expires
input int    MagicNumber           = 20260620; // Magic number to identify this EA's trades

//--- Globals
CTrade trade;
string gSymbol;

datetime gLastH1BarTime  = 0;
datetime gLastM15BarTime = 0;

bool     gArmed          = false;   // Is a pin bar breakout currently armed?
bool     gArmedIsBullish = false;   // true = watching for breakout above high, false = below low
double   gArmedLevel     = 0.0;     // The H1 pin bar high (bullish) or low (bearish)
int      gBarsWaited     = 0;       // M15 bars elapsed since arming

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   gSymbol = _Symbol;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(gSymbol);

   gLastH1BarTime  = iTime(gSymbol, PERIOD_H1, 0);
   gLastM15BarTime = iTime(gSymbol, PERIOD_M15, 0);

   Print("PinBarBreakout_Gold initialized on ", gSymbol);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Print("PinBarBreakout_Gold deinitialized. Reason: ", reason);
  }

//+------------------------------------------------------------------+
//| Count open positions opened by this EA on this symbol             |
//+------------------------------------------------------------------+
int CountOpenTrades()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
      {
       ulong ticket = PositionGetTicket(i);
       if(ticket == 0) continue;
       if(PositionGetString(POSITION_SYMBOL) == gSymbol &&
          PositionGetInteger(POSITION_MAGIC) == MagicNumber)
          count++;
      }
   return count;
  }

//+------------------------------------------------------------------+
//| Calculate lot size from risk percent and SL distance in dollars   |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistanceDollars)
  {
   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount   = balance * (RiskPercent / 100.0);

   double tickValue   = SymbolInfoDouble(gSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize     = SymbolInfoDouble(gSymbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0)
      {
       Print("Invalid tick value/size for ", gSymbol, ". Defaulting to minimum lot.");
       return SymbolInfoDouble(gSymbol, SYMBOL_VOLUME_MIN);
      }

   // Value of slDistanceDollars price-move per 1.0 lot
   double valuePerLot = (slDistanceDollars / tickSize) * tickValue;
   if(valuePerLot <= 0)
      return SymbolInfoDouble(gSymbol, SYMBOL_VOLUME_MIN);

   double lots = riskAmount / valuePerLot;

   double lotStep = SymbolInfoDouble(gSymbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(gSymbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(gSymbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
//| Scan the last CLOSED H1 bar for a pin bar, arm breakout if found  |
//| v1.01: requires body to sit within PinBarBodyPositionPct of the   |
//| wick-side extreme, and will NOT re-arm if a signal is already     |
//| armed and waiting on a breakout.                                  |
//+------------------------------------------------------------------+
void ScanForNewPinBar()
  {
   // Don't overwrite a signal that's still live and waiting
   if(gArmed)
      return;

   // Index 1 = last fully closed H1 bar (index 0 is the forming bar)
   double openP  = iOpen(gSymbol, PERIOD_H1, 1);
   double closeP = iClose(gSymbol, PERIOD_H1, 1);
   double highP  = iHigh(gSymbol, PERIOD_H1, 1);
   double lowP   = iLow(gSymbol, PERIOD_H1, 1);

   double range = highP - lowP;
   if(range <= 0)
      range = _Point; // avoid division by zero

   double body = MathAbs(closeP - openP);
   if(body <= 0)
      body = _Point; // avoid division by zero on a doji

   double upperWick = highP - MathMax(openP, closeP);
   double lowerWick = MathMin(openP, closeP) - lowP;

   bool wickRatioBullish = (lowerWick >= PinBarWickMultiplier * body) && (lowerWick > upperWick);
   bool wickRatioBearish = (upperWick >= PinBarWickMultiplier * body) && (upperWick > lowerWick);

   // Body-position filter: for a bullish pin bar (long lower wick), the body's
   // lower edge must sit within PinBarBodyPositionPct of the candle's HIGH end
   // of the range. For a bearish pin bar (long upper wick), the body's upper
   // edge must sit within PinBarBodyPositionPct of the candle's LOW end.
   double bodyTop    = MathMax(openP, closeP);
   double bodyBottom = MathMin(openP, closeP);

   bool bodyPositionBullish = ((highP - bodyTop) <= PinBarBodyPositionPct * range);
   bool bodyPositionBearish = ((bodyBottom - lowP) <= PinBarBodyPositionPct * range);

   bool isBullishPinBar = wickRatioBullish && bodyPositionBullish;
   bool isBearishPinBar = wickRatioBearish && bodyPositionBearish;

   if(isBullishPinBar)
      {
       gArmed          = true;
       gArmedIsBullish = true;
       gArmedLevel     = highP;
       gBarsWaited     = -1;
       PrintFormat("Bullish pin bar detected on H1. Arming breakout watch above %.2f", gArmedLevel);
      }
   else if(isBearishPinBar)
      {
       gArmed          = true;
       gArmedIsBullish = false;
       gArmedLevel     = lowP;
       gBarsWaited     = -1;
       PrintFormat("Bearish pin bar detected on H1. Arming breakout watch below %.2f", gArmedLevel);
      }
  }

//+------------------------------------------------------------------+
//| Check a specific closed M15 bar for a breakout of the armed level |
//| barIndex 1 = most recent closed bar, 2 = one bar before, etc.    |
//+------------------------------------------------------------------+
void CheckBreakoutOnM15(int barIndex)
  {
   if(!gArmed)
      return;

   gBarsWaited++;
   if(gBarsWaited > MaxBarsToWaitBreakout)
      {
       PrintFormat("Armed pin bar expired after %d M15 bars without breakout.", MaxBarsToWaitBreakout);
       gArmed = false;
       return;
      }

   double closeP = iClose(gSymbol, PERIOD_M15, barIndex);

   bool breakoutUp   = gArmedIsBullish  && (closeP > gArmedLevel);
   bool breakoutDown = !gArmedIsBullish && (closeP < gArmedLevel);

   if(breakoutUp || breakoutDown)
      {
       OpenTrade(breakoutUp);
       gArmed = false; // consume the signal whether or not the trade succeeds
      }
  }

//+------------------------------------------------------------------+
//| Open a trade in the given direction with risk-managed size         |
//+------------------------------------------------------------------+
void OpenTrade(bool isBuy)
  {
   int openTrades = CountOpenTrades();
   if(openTrades >= MaxOpenTrades)
      {
       PrintFormat("Max open trades (%d) reached. Skipping new entry.", MaxOpenTrades);
       return;
      }

   double price = isBuy ? SymbolInfoDouble(gSymbol, SYMBOL_ASK)
                         : SymbolInfoDouble(gSymbol, SYMBOL_BID);

   double sl, tp;
   double tpDistance = FixedSL_Dollars * RiskRewardRatio;

   if(isBuy)
      {
       sl = price - FixedSL_Dollars;
       tp = price + tpDistance;
      }
   else
      {
       sl = price + FixedSL_Dollars;
       tp = price - tpDistance;
      }

   double lots = CalculateLotSize(FixedSL_Dollars);

   int digits = (int)SymbolInfoInteger(gSymbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   bool result;
   if(isBuy)
      result = trade.Buy(lots, gSymbol, price, sl, tp, "PinBarBreakout-BUY");
   else
      result = trade.Sell(lots, gSymbol, price, sl, tp, "PinBarBreakout-SELL");

   if(result)
      PrintFormat("Trade opened: %s %.2f lots @ %.2f, SL=%.2f, TP=%.2f",
                  isBuy ? "BUY" : "SELL", lots, price, sl, tp);
   else
      PrintFormat("Trade FAILED: retcode=%d, comment=%s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   // --- Step 1: Check for a newly closed H1 bar, scan for pin bar ---
   datetime currentH1BarTime = iTime(gSymbol, PERIOD_H1, 0);
   if(currentH1BarTime != gLastH1BarTime)
      {
       gLastH1BarTime = currentH1BarTime;
       ScanForNewPinBar();
      }

   // --- Step 2: Process all M15 bars that closed since the last tick ---
   // Dividing the time delta by the period length gives the number of M15
   // bars that have elapsed. In "Every tick" mode this is always 1. In
   // "Open prices only" mode on an H1 chart this is 4, catching all bars
   // that would otherwise be skipped by a simple != guard.
   datetime currentM15BarTime = iTime(gSymbol, PERIOD_M15, 0);
   if(currentM15BarTime != gLastM15BarTime)
      {
       int barsElapsed = (int)((currentM15BarTime - gLastM15BarTime) / PeriodSeconds(PERIOD_M15));
       gLastM15BarTime = currentM15BarTime;
       for(int i = barsElapsed; i >= 1 && gArmed; i--)
          CheckBreakoutOnM15(i);
      }
  }
//+------------------------------------------------------------------+