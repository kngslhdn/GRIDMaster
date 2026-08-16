//+------------------------------------------------------------------+
//|                                                   IronWall.mq5   |
//|                    IronWall - XAUUSD Trading Engine              |
//|                           Version 1.00                            |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "IronWall - clean foundation for a robust MT5 trading engine"

#include <Trade/Trade.mqh>

//====================================================================
// INPUTS
//====================================================================
input group "=== CORE ==="
input ulong  InpMagicNumber          = 26081601;
input double InpFixedLot              = 0.01;
input bool   InpUseRiskLot            = false;
input double InpRiskPercent           = 0.50;

input group "=== EXECUTION ==="
input ENUM_TIMEFRAMES InpSignalTF    = PERIOD_M15;
input int    InpMaxSpreadPoints       = 80;
input int    InpSlippagePoints        = 30;
input bool   InpOnePositionPerSymbol  = true;

input group "=== PROTECTION ==="
input double InpStopLossUSD           = 30.0;
input double InpTakeProfitUSD         = 45.0;
input double InpDailyLossLimitPercent = 4.0;
input double InpMaxEquityDrawdownPct  = 15.0;

input group "=== BREAK EVEN ==="
input bool   InpUseBreakEven          = true;
input double InpBreakEvenTriggerUSD   = 5.0;
input double InpBreakEvenLockUSD      = 1.0;

input group "=== TRAILING ==="
input bool   InpUseTrailing           = true;
input double InpTrailingStartUSD      = 10.0;
input double InpTrailingDistanceUSD   = 5.0;

input group "=== DIRECTION ENGINE ==="
input bool   InpUseDirectionEngine    = true;
input int    InpFastMAPeriod           = 20;
input int    InpSlowMAPeriod           = 50;
input int    InpRSIPeriod              = 14;
input double InpRSIBuyMin              = 52.0;
input double InpRSISellMax             = 48.0;

//====================================================================
// GLOBALS
//====================================================================
CTrade   g_trade;
int      g_fastMAHandle = INVALID_HANDLE;
int      g_slowMAHandle = INVALID_HANDLE;
int      g_rsiHandle    = INVALID_HANDLE;
datetime g_lastBarTime  = 0;
double   g_dayStartEquity = 0.0;
datetime g_dayAnchor = 0;

//====================================================================
// UTILITY
//====================================================================
int DigitsForSymbol()
{
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
}

double PointValue()
{
   return SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

double NormalizePrice(const double price)
{
   return NormalizeDouble(price, DigitsForSymbol());
}

bool IsNewBar()
{
   datetime barTime = iTime(_Symbol, InpSignalTF, 0);
   if(barTime <= 0)
      return false;

   if(barTime != g_lastBarTime)
   {
      g_lastBarTime = barTime;
      return true;
   }
   return false;
}

void RefreshDailyAnchor()
{
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime today = StructToTime(dt);

   if(today != g_dayAnchor)
   {
      g_dayAnchor     = today;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
}

bool RiskBlocked()
{
   RefreshDailyAnchor();

   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   const double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(g_dayStartEquity > 0.0 && InpDailyLossLimitPercent > 0.0)
   {
      const double dayLossPct = (g_dayStartEquity - equity) / g_dayStartEquity * 100.0;
      if(dayLossPct >= InpDailyLossLimitPercent)
         return true;
   }

   if(balance > 0.0 && InpMaxEquityDrawdownPct > 0.0)
   {
      const double ddPct = (balance - equity) / balance * 100.0;
      if(ddPct >= InpMaxEquityDrawdownPct)
         return true;
   }

   return false;
}

bool SpreadOK()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   const double point = PointValue();
   if(point <= 0.0)
      return false;

   const double spreadPoints = (tick.ask - tick.bid) / point;
   return spreadPoints <= InpMaxSpreadPoints;
}

bool HasOurPosition()
{
   if(!PositionSelect(_Symbol))
      return false;

   const ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   return magic == InpMagicNumber;
}

//====================================================================
// LOT ENGINE
//====================================================================
double CalculateLot()
{
   if(!InpUseRiskLot)
      return InpFixedLot;

   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   const double volumeMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double volumeMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(equity <= 0.0 || tickValue <= 0.0 || tickSize <= 0.0 || InpStopLossUSD <= 0.0)
      return InpFixedLot;

   const double riskMoney = equity * InpRiskPercent / 100.0;
   const double moneyPerPriceUnitPerLot = tickValue / tickSize;
   const double rawLot = riskMoney / (InpStopLossUSD * moneyPerPriceUnitPerLot);

   double lot = MathMax(volumeMin, MathMin(volumeMax, rawLot));
   if(volumeStep > 0.0)
      lot = MathFloor(lot / volumeStep) * volumeStep;

   return NormalizeDouble(lot, 2);
}

//====================================================================
// USD -> PRICE DISTANCE
//====================================================================
double PriceDistanceForUSD(const double money, const double volume)
{
   if(money <= 0.0 || volume <= 0.0)
      return 0.0;

   const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return 0.0;

   return money / (volume * (tickValue / tickSize));
}

//====================================================================
// INDICATOR ENGINE
//====================================================================
bool ReadIndicatorValue(const int handle, const int buffer, const int shift, double &value)
{
   double data[];
   ArraySetAsSeries(data, true);

   if(CopyBuffer(handle, buffer, shift, 1, data) != 1)
      return false;

   value = data[0];
   return true;
}

enum DirectionSignal
{
   SIGNAL_NONE = 0,
   SIGNAL_BUY,
   SIGNAL_SELL
};

DirectionSignal GetDirectionSignal()
{
   if(!InpUseDirectionEngine)
      return SIGNAL_BUY;

   double fastMA = 0.0;
   double slowMA = 0.0;
   double rsi    = 0.0;

   if(!ReadIndicatorValue(g_fastMAHandle, 0, 1, fastMA))
      return SIGNAL_NONE;
   if(!ReadIndicatorValue(g_slowMAHandle, 0, 1, slowMA))
      return SIGNAL_NONE;
   if(!ReadIndicatorValue(g_rsiHandle, 0, 1, rsi))
      return SIGNAL_NONE;

   if(fastMA > slowMA && rsi >= InpRSIBuyMin)
      return SIGNAL_BUY;

   if(fastMA < slowMA && rsi <= InpRSISellMax)
      return SIGNAL_SELL;

   return SIGNAL_NONE;
}

//====================================================================
// ORDER ENGINE
//====================================================================
bool OpenMarket(const ENUM_ORDER_TYPE type)
{
   if(RiskBlocked() || !SpreadOK())
      return false;

   if(InpOnePositionPerSymbol && HasOurPosition())
      return false;

   const double volume = CalculateLot();
   if(volume <= 0.0)
      return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   const double entry = (type == ORDER_TYPE_BUY ? tick.ask : tick.bid);
   const double slDist = PriceDistanceForUSD(InpStopLossUSD, volume);
   const double tpDist = PriceDistanceForUSD(InpTakeProfitUSD, volume);

   if(slDist <= 0.0 || tpDist <= 0.0)
      return false;

   double sl = 0.0;
   double tp = 0.0;

   if(type == ORDER_TYPE_BUY)
   {
      sl = NormalizePrice(entry - slDist);
      tp = NormalizePrice(entry + tpDist);
   }
   else
   {
      sl = NormalizePrice(entry + slDist);
      tp = NormalizePrice(entry - tpDist);
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);

   if(type == ORDER_TYPE_BUY)
      return g_trade.Buy(volume, _Symbol, 0.0, sl, tp, "IronWall BUY");

   return g_trade.Sell(volume, _Symbol, 0.0, sl, tp, "IronWall SELL");
}

//====================================================================
// POSITION PROTECTION
//====================================================================
void ManagePosition()
{
   if(!HasOurPosition())
      return;

   const long positionType = PositionGetInteger(POSITION_TYPE);
   const double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
   const double currentSL  = PositionGetDouble(POSITION_SL);
   const double volume     = PositionGetDouble(POSITION_VOLUME);
   const double profit     = PositionGetDouble(POSITION_PROFIT);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   const bool isBuy = (positionType == POSITION_TYPE_BUY);
   const double marketPrice = isBuy ? tick.bid : tick.ask;

   double desiredSL = currentSL;

   //--- Break-even: lock a small amount after reaching the trigger.
   if(InpUseBreakEven && profit >= InpBreakEvenTriggerUSD)
   {
      const double lockDistance = PriceDistanceForUSD(InpBreakEvenLockUSD, volume);
      if(lockDistance > 0.0)
      {
         const double beSL = isBuy ? NormalizePrice(openPrice + lockDistance)
                                   : NormalizePrice(openPrice - lockDistance);

         if(isBuy)
         {
            if(desiredSL <= 0.0 || beSL > desiredSL)
               desiredSL = beSL;
         }
         else
         {
            if(desiredSL <= 0.0 || beSL < desiredSL)
               desiredSL = beSL;
         }
      }
   }

   //--- Trailing: only tightens the stop, never loosens it.
   if(InpUseTrailing && profit >= InpTrailingStartUSD)
   {
      const double trailDistance = PriceDistanceForUSD(InpTrailingDistanceUSD, volume);
      if(trailDistance > 0.0)
      {
         const double trailSL = isBuy ? NormalizePrice(marketPrice - trailDistance)
                                      : NormalizePrice(marketPrice + trailDistance);

         if(isBuy)
         {
            if(trailSL > desiredSL)
               desiredSL = trailSL;
         }
         else
         {
            if(desiredSL <= 0.0 || trailSL < desiredSL)
               desiredSL = trailSL;
         }
      }
   }

   if(desiredSL <= 0.0 || desiredSL == currentSL)
      return;

   //--- Respect broker minimum stop distance.
   const int stopsLevelPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const double minStopDistance = stopsLevelPoints * PointValue();

   if(isBuy && (marketPrice - desiredSL) < minStopDistance)
      desiredSL = NormalizePrice(marketPrice - minStopDistance);
   if(!isBuy && (desiredSL - marketPrice) < minStopDistance)
      desiredSL = NormalizePrice(marketPrice + minStopDistance);

   if(isBuy && desiredSL >= marketPrice)
      return;
   if(!isBuy && desiredSL <= marketPrice)
      return;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.PositionModify(_Symbol, desiredSL, PositionGetDouble(POSITION_TP));
}

//====================================================================
// LIFECYCLE
//====================================================================
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);

   g_fastMAHandle = iMA(_Symbol, InpSignalTF, InpFastMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_slowMAHandle = iMA(_Symbol, InpSignalTF, InpSlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_rsiHandle    = iRSI(_Symbol, InpSignalTF, InpRSIPeriod, PRICE_CLOSE);

   if(g_fastMAHandle == INVALID_HANDLE || g_slowMAHandle == INVALID_HANDLE || g_rsiHandle == INVALID_HANDLE)
      return INIT_FAILED;

   RefreshDailyAnchor();
   g_lastBarTime = iTime(_Symbol, InpSignalTF, 0);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fastMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_fastMAHandle);
   if(g_slowMAHandle != INVALID_HANDLE)
      IndicatorRelease(g_slowMAHandle);
   if(g_rsiHandle != INVALID_HANDLE)
      IndicatorRelease(g_rsiHandle);
}

void OnTick()
{
   RefreshDailyAnchor();
   ManagePosition();

   if(!IsNewBar())
      return;

   if(RiskBlocked() || !SpreadOK())
      return;

   if(InpOnePositionPerSymbol && HasOurPosition())
      return;

   const DirectionSignal signal = GetDirectionSignal();

   if(signal == SIGNAL_BUY)
      OpenMarket(ORDER_TYPE_BUY);
   else if(signal == SIGNAL_SELL)
      OpenMarket(ORDER_TYPE_SELL);
}
//+------------------------------------------------------------------+
