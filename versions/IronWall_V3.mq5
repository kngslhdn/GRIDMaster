//+------------------------------------------------------------------+
//|                                              IronWall_V3.mq5      |
//|             IronWall V3 - Adaptive Trend Wall Engine             |
//|                         Version 3.00                              |
//+------------------------------------------------------------------+
#property strict
#property version   "3.00"
#property description "IronWall V3 - trend-filtered ATR breakout wall with adaptive protection"

#include <Trade/Trade.mqh>

CTrade trade;

//====================================================================
// INPUTS
//====================================================================
input group "=== IRONWALL V3 CORE ==="
input double InpLotSize            = 0.01;
input double InpWallDistancePrice  = 10.0;
input ulong  InpMagicNumber        = 26081601;
input int    InpDeviationPoints    = 30;

input group "=== TREND ENGINE ==="
input bool   InpUseTrendFilter     = true;
input int    InpFastEMA             = 50;
input int    InpSlowEMA             = 200;
input bool   InpRequireEMASlope     = true;
input int    InpSlopeBars           = 3;

input group "=== VOLATILITY ENGINE ==="
input bool   InpUseATRFilter       = true;
input int    InpATRPeriod           = 14;
input int    InpATRMeanBars         = 20;
input double InpMinATRRatio         = 0.90;
input double InpEntryATRBuffer      = 0.15;

input group "=== RISK ENGINE ==="
input bool   InpUseHardSL           = true;
input double InpSL_ATR_Multiplier   = 1.50;
input bool   InpUseProfitTrail       = true;
input double InpTrailStartATR        = 1.00;
input double InpTrailATRDistance     = 1.20;
input double InpBreakEvenATR         = 0.80;
input double InpBreakEvenOffset      = 0.10;

input group "=== SESSION ENGINE ==="
input bool   InpUseSessionFilter    = true;
input int    InpTradingStartHour    = 7;
input int    InpTradingEndHour      = 23;

input group "=== EXECUTION SAFETY ==="
input double InpMaxSpreadPrice      = 1.50;
input int    InpCooldownBars        = 1;

//====================================================================
// GLOBALS
//====================================================================
bool     g_busy = false;
datetime g_lastBarTime = 0;
datetime g_lastExitTime = 0;

int g_fastEMAHandle = INVALID_HANDLE;
int g_slowEMAHandle = INVALID_HANDLE;
int g_atrHandle     = INVALID_HANDLE;

//====================================================================
// UTILITY
//====================================================================
double NormalizePrice(const double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

double PointSize()
{
   return SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

double MinStopDistance()
{
   const int stops  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(stops, freeze) * PointSize();
}

double EffectiveWallDistance()
{
   return MathMax(InpWallDistancePrice, MinStopDistance());
}

bool IsTradingSession()
{
   if(!InpUseSessionFilter)
      return true;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);

   if(InpTradingStartHour == InpTradingEndHour)
      return true;

   if(InpTradingStartHour < InpTradingEndHour)
      return (tm.hour >= InpTradingStartHour && tm.hour < InpTradingEndHour);

   return (tm.hour >= InpTradingStartHour || tm.hour < InpTradingEndHour);
}

bool IsSpreadOK()
{
   if(InpMaxSpreadPrice <= 0.0)
      return true;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   return (tick.ask - tick.bid) <= InpMaxSpreadPrice;
}

bool IsOurOrder(const ulong ticket)
{
   if(ticket == 0 || !OrderSelect(ticket))
      return false;

   return OrderGetString(ORDER_SYMBOL) == _Symbol &&
          (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagicNumber;
}

bool IsOurPosition(const ulong ticket)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return false;

   return PositionGetString(POSITION_SYMBOL) == _Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber;
}

int OurPositionCount()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);

      if(IsOurPosition(ticket))
         count++;
   }

   return count;
}

int OurPendingCount()
{
   int count = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);

      if(!IsOurOrder(ticket))
         continue;

      const ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type == ORDER_TYPE_BUY_STOP ||
         type == ORDER_TYPE_SELL_STOP)
      {
         count++;
      }
   }

   return count;
}

bool GetOurPosition(ulong &ticket,
                    ENUM_POSITION_TYPE &type,
                    double &openPrice)
{
   ticket    = 0;
   openPrice = 0.0;
   type      = POSITION_TYPE_BUY;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong t = PositionGetTicket(i);

      if(!IsOurPosition(t))
         continue;

      ticket    = t;
      type      = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      return true;
   }

   return false;
}

bool IsNewBar()
{
   const datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);

   if(currentBar <= 0)
      return false;

   if(currentBar != g_lastBarTime)
   {
      g_lastBarTime = currentBar;
      return true;
   }

   return false;
}

bool CooldownPassed()
{
   if(InpCooldownBars <= 0 || g_lastExitTime <= 0)
      return true;

   const int shift = iBarShift(_Symbol, PERIOD_CURRENT, g_lastExitTime, false);

   if(shift < 0)
      return true;

   return shift >= InpCooldownBars;
}

//====================================================================
// INDICATOR ENGINE
//====================================================================
bool GetBufferValue(const int handle,
                    const int buffer,
                    const int shift,
                    double &value)
{
   value = 0.0;

   if(handle == INVALID_HANDLE)
      return false;

   double data[];
   ArraySetAsSeries(data, true);

   if(CopyBuffer(handle, buffer, shift, 1, data) != 1)
      return false;

   value = data[0];

   return value > 0.0;
}

double GetATR(const int shift = 1)
{
   double value = 0.0;

   if(!GetBufferValue(g_atrHandle, 0, shift, value))
      return 0.0;

   return value;
}

double GetATRMean()
{
   if(g_atrHandle == INVALID_HANDLE)
      return 0.0;

   const int count = MathMax(2, InpATRMeanBars);

   double data[];
   ArraySetAsSeries(data, true);

   if(CopyBuffer(g_atrHandle, 0, 1, count, data) != count)
      return 0.0;

   double sum = 0.0;

   for(int i = 0; i < count; i++)
      sum += data[i];

   return sum / count;
}

bool GetTrendDirection(int &direction)
{
   direction = 0;

   if(!InpUseTrendFilter)
      return true;

   double fastNow = 0.0;
   double slowNow = 0.0;

   if(!GetBufferValue(g_fastEMAHandle, 0, 1, fastNow))
      return false;

   if(!GetBufferValue(g_slowEMAHandle, 0, 1, slowNow))
      return false;

   const double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);

   if(close1 <= 0.0)
      return false;

   bool bullish = fastNow > slowNow && close1 > slowNow;
   bool bearish = fastNow < slowNow && close1 < slowNow;

   if(InpRequireEMASlope && InpSlopeBars > 0)
   {
      double fastPast = 0.0;
      double slowPast = 0.0;

      if(!GetBufferValue(g_fastEMAHandle, 0, 1 + InpSlopeBars, fastPast))
         return false;

      if(!GetBufferValue(g_slowEMAHandle, 0, 1 + InpSlopeBars, slowPast))
         return false;

      bullish = bullish && fastNow > fastPast && slowNow >= slowPast;
      bearish = bearish && fastNow < fastPast && slowNow <= slowPast;
   }

   if(bullish)
      direction = 1;
   else if(bearish)
      direction = -1;

   return true;
}

bool VolatilityOK()
{
   if(!InpUseATRFilter)
      return true;

   const double atr = GetATR(1);
   const double mean = GetATRMean();

   if(atr <= 0.0 || mean <= 0.0)
      return false;

   return atr >= mean * InpMinATRRatio;
}

//====================================================================
// PENDING ENGINE
//====================================================================
void DeleteAllPending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);

      if(!IsOurOrder(ticket))
         continue;

      const ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type != ORDER_TYPE_BUY_STOP &&
         type != ORDER_TYPE_SELL_STOP)
      {
         continue;
      }

      if(!trade.OrderDelete(ticket))
      {
         Print("IronWall V3: delete pending failed #", ticket,
               " retcode=", trade.ResultRetcode(),
               " ", trade.ResultRetcodeDescription());
      }
   }
}

bool PlaceBuyStop(const double requestedPrice,
                  const double atr)
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   const double minDistance = EffectiveWallDistance();

   double price = requestedPrice;

   if(InpEntryATRBuffer > 0.0 && atr > 0.0)
      price += atr * InpEntryATRBuffer;

   price = MathMax(price, tick.ask + minDistance);
   price = NormalizePrice(price);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   const bool ok = trade.BuyStop(
      InpLotSize,
      price,
      _Symbol,
      0.0,
      0.0,
      ORDER_TIME_GTC,
      0,
      "IronWall V3 BUY STOP"
   );

   if(!ok)
   {
      Print("IronWall V3: BUY STOP failed @", price,
            " retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
   }

   return ok;
}

bool PlaceSellStop(const double requestedPrice,
                   const double atr)
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   const double minDistance = EffectiveWallDistance();

   double price = requestedPrice;

   if(InpEntryATRBuffer > 0.0 && atr > 0.0)
      price -= atr * InpEntryATRBuffer;

   price = MathMin(price, tick.bid - minDistance);
   price = NormalizePrice(price);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   const bool ok = trade.SellStop(
      InpLotSize,
      price,
      _Symbol,
      0.0,
      0.0,
      ORDER_TIME_GTC,
      0,
      "IronWall V3 SELL STOP"
   );

   if(!ok)
   {
      Print("IronWall V3: SELL STOP failed @", price,
            " retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
   }

   return ok;
}

//====================================================================
// INITIAL WALL
//====================================================================
void CreateInitialWall()
{
   if(g_busy || OurPositionCount() > 0)
      return;

   if(!IsTradingSession() || !IsSpreadOK() || !CooldownPassed())
   {
      DeleteAllPending();
      return;
   }

   if(!VolatilityOK())
   {
      DeleteAllPending();
      return;
   }

   int direction = 0;

   if(!GetTrendDirection(direction))
      return;

   if(direction == 0)
   {
      DeleteAllPending();
      return;
   }

   const double atr = GetATR(1);

   if(atr <= 0.0)
      return;

   const double prevHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);
   const double prevLow  = iLow(_Symbol, PERIOD_CURRENT, 1);

   if(prevHigh <= 0.0 || prevLow <= 0.0)
      return;

   DeleteAllPending();

   bool ok = false;

   if(direction > 0)
      ok = PlaceBuyStop(prevHigh, atr);
   else
      ok = PlaceSellStop(prevLow, atr);

   Print("IronWall V3: INITIAL WALL | direction=",
         direction > 0 ? "BUY" : "SELL",
         " | ATR=", atr,
         " | placed=", ok);
}

//====================================================================
// POSITION ENGINE
//====================================================================
bool ClosePositionTicket(const ulong ticket)
{
   if(!IsOurPosition(ticket))
      return true;

   if(!trade.PositionClose(ticket))
   {
      Print("IronWall V3: close failed #", ticket,
            " retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
      return false;
   }

   return true;
}

bool CloseAllExcept(const ulong keepTicket)
{
   bool success = true;

   for(int pass = 0; pass < 3; pass++)
   {
      bool found = false;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         const ulong t = PositionGetTicket(i);

         if(!IsOurPosition(t) || t == keepTicket)
            continue;

         found = true;

         if(!ClosePositionTicket(t))
            success = false;
      }

      if(!found)
         break;
   }

   return success;
}

//====================================================================
// PROTECTION ENGINE
//====================================================================
bool ModifySL(const ulong ticket,
              const double requestedSL)
{
   if(!IsOurPosition(ticket))
      return false;

   const ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   const double tp = PositionGetDouble(POSITION_TP);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double minDist = MinStopDistance();

   double sl = requestedSL;

   if(type == POSITION_TYPE_BUY)
      sl = MathMin(sl, bid - minDist);
   else
      sl = MathMax(sl, ask + minDist);

   sl = NormalizePrice(sl);

   if(sl <= 0.0)
      return false;

   const double currentSL = PositionGetDouble(POSITION_SL);

   if(type == POSITION_TYPE_BUY)
   {
      if(currentSL > 0.0 && sl <= currentSL)
         return false;
   }
   else
   {
      if(currentSL > 0.0 && sl >= currentSL)
         return false;
   }

   if(!trade.PositionModify(ticket, sl, tp))
   {
      Print("IronWall V3: SL modify failed #", ticket,
            " retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
      return false;
   }

   return true;
}

void ApplyHardSL()
{
   if(!InpUseHardSL)
      return;

   const double atr = GetATR(0);

   if(atr <= 0.0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);

      if(!IsOurPosition(ticket))
         continue;

      const ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      const double open = PositionGetDouble(POSITION_PRICE_OPEN);
      const double currentSL = PositionGetDouble(POSITION_SL);

      double target;

      if(type == POSITION_TYPE_BUY)
         target = open - atr * InpSL_ATR_Multiplier;
      else
         target = open + atr * InpSL_ATR_Multiplier;

      target = NormalizePrice(target);

      bool needsSL = currentSL == 0.0;

      if(type == POSITION_TYPE_BUY)
         needsSL = needsSL || currentSL < target;
      else
         needsSL = needsSL || currentSL > target;

      if(needsSL)
         ModifySL(ticket, target);
   }
}

void ApplyProfitTrail()
{
   if(!InpUseProfitTrail)
      return;

   const double atr = GetATR(0);

   if(atr <= 0.0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);

      if(!IsOurPosition(ticket))
         continue;

      const ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      const double open = PositionGetDouble(POSITION_PRICE_OPEN);
      const double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      const double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      const double favorable =
         (type == POSITION_TYPE_BUY) ? (bid - open) : (open - ask);

      if(favorable < atr * InpBreakEvenATR)
         continue;

      double beSL;

      if(type == POSITION_TYPE_BUY)
         beSL = open + atr * InpBreakEvenOffset;
      else
         beSL = open - atr * InpBreakEvenOffset;

      ModifySL(ticket, beSL);

      if(favorable < atr * InpTrailStartATR)
         continue;

      double trailSL;

      if(type == POSITION_TYPE_BUY)
         trailSL = bid - atr * InpTrailATRDistance;
      else
         trailSL = ask + atr * InpTrailATRDistance;

      ModifySL(ticket, trailSL);
   }
}

//====================================================================
// ACTIVE POSITION WALL
//====================================================================
void MaintainActiveWall()
{
   ulong ticket;
   ENUM_POSITION_TYPE type;
   double openPrice;

   if(!GetOurPosition(ticket, type, openPrice))
      return;

   // V3 intentionally removes the unconditional opposite reversal
   // wall. V2's report showed that repeated counter-wall flips were
   // the dominant source of oversized losing trades.
   DeleteAllPending();
}

//====================================================================
// STATE ENGINE
//====================================================================
void RepairEngine()
{
   if(g_busy)
      return;

   const int positions = OurPositionCount();

   if(positions == 0)
   {
      if(OurPendingCount() != 1)
         CreateInitialWall();

      return;
   }

   if(positions > 1)
   {
      ulong keep;
      ENUM_POSITION_TYPE type;
      double open;

      if(GetOurPosition(keep, type, open))
         CloseAllExcept(keep);
   }

   MaintainActiveWall();
}

//====================================================================
// TRADE TRANSACTION
//====================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(g_busy)
      return;

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;

   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber)
      return;

   const ENUM_DEAL_ENTRY entry =
      (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
      g_lastExitTime = TimeCurrent();

   if(entry != DEAL_ENTRY_IN)
      return;

   const ENUM_DEAL_TYPE direction =
      (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);

   if(direction != DEAL_TYPE_BUY && direction != DEAL_TYPE_SELL)
      return;

   g_busy = true;
   DeleteAllPending();
   g_busy = false;

   Print("IronWall V3: ENTRY | direction=",
         direction == DEAL_TYPE_BUY ? "BUY" : "SELL",
         " | deal=", trans.deal);
}

//====================================================================
// LIFECYCLE
//====================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpLotSize <= 0.0 ||
      InpWallDistancePrice <= 0.0 ||
      InpFastEMA <= 0 ||
      InpSlowEMA <= 0 ||
      InpATRPeriod <= 0)
   {
      Print("IronWall V3: invalid parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_fastEMAHandle = iMA(
      _Symbol,
      PERIOD_CURRENT,
      InpFastEMA,
      0,
      MODE_EMA,
      PRICE_CLOSE
   );

   g_slowEMAHandle = iMA(
      _Symbol,
      PERIOD_CURRENT,
      InpSlowEMA,
      0,
      MODE_EMA,
      PRICE_CLOSE
   );

   g_atrHandle = iATR(
      _Symbol,
      PERIOD_CURRENT,
      InpATRPeriod
   );

   if(g_fastEMAHandle == INVALID_HANDLE ||
      g_slowEMAHandle == INVALID_HANDLE ||
      g_atrHandle == INVALID_HANDLE)
   {
      Print("IronWall V3: indicator handle creation failed.");
      return INIT_FAILED;
   }

   Print("==================================================");
   Print("IronWall V3.00 STARTED");
   Print("Symbol       : ", _Symbol);
   Print("Lot          : ", InpLotSize);
   Print("Wall         : ", InpWallDistancePrice);
   Print("EMA          : ", InpFastEMA, "/", InpSlowEMA);
   Print("ATR          : ", InpATRPeriod);
   Print("SL ATR       : ", InpSL_ATR_Multiplier);
   Print("Trail ATR    : ", InpTrailATRDistance);
   Print("Session      : ", InpTradingStartHour, "-", InpTradingEndHour);
   Print("Anti-whipsaw : TREND + ATR + CLOSED BAR");
   Print("==================================================");

   RepairEngine();

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fastEMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_fastEMAHandle);

   if(g_slowEMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_slowEMAHandle);

   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);

   Print("IronWall V3.00 stopped. reason=", reason);
}

void OnTick()
{
   ApplyHardSL();
   ApplyProfitTrail();

   // Re-evaluate the entry wall only on a new bar.
   // This prevents continuous cancellation/recreation/chasing.
   if(IsNewBar())
      RepairEngine();
}
//+------------------------------------------------------------------+
