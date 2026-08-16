//+------------------------------------------------------------------+
//|                                              IronWall_V4.mq5      |
//|              IronWall V4 - Adaptive Trend Breakout Engine        |
//|                         Version 4.00                              |
//+------------------------------------------------------------------+
#property strict
#property version   "4.00"
#property description "IronWall V4 - trend breakout with ATR risk, trend exit and loss protection"

#include <Trade/Trade.mqh>

CTrade trade;

//====================================================================
// INPUTS
//====================================================================
input group "=== IRONWALL V4 CORE ==="
input double InpLotSize              = 0.01;
input double InpWallDistancePrice    = 5.0;
input ulong  InpMagicNumber          = 26081601;
input int    InpDeviationPoints      = 30;

input group "=== TREND ENGINE ==="
input bool   InpUseTrendFilter       = true;
input int    InpFastEMA              = 50;
input int    InpSlowEMA              = 200;
input int    InpSlopeBars            = 3;
input double InpMinTrendSepATR       = 0.10;
input bool   InpUseTrendExit         = true;
input int    InpTrendExitBars        = 2;

input group "=== BREAKOUT ENGINE ==="
input int    InpBreakoutLookback     = 3;
input double InpEntryATRBuffer       = 0.20;
input bool   InpUseATRFilter         = true;
input int    InpATRPeriod            = 14;
input int    InpATRMeanBars          = 20;
input double InpMinATRRatio          = 1.00;

input group "=== RISK / PROFIT ENGINE ==="
input bool   InpUseHardSL            = true;
input double InpSL_ATR_Multiplier    = 1.20;
input bool   InpUseBreakEven         = true;
input double InpBreakEvenATR         = 0.70;
input double InpBreakEvenOffset      = 0.05;
input bool   InpUseProfitTrail       = true;
input double InpTrailStartATR        = 1.20;
input double InpTrailATRDistance     = 0.90;

input group "=== LOSS PROTECTION ==="
input bool   InpUseLossCooldown      = true;
input int    InpLossCooldownBars     = 4;
input int    InpMaxConsecutiveLosses = 2;
input int    InpLockoutBars          = 8;

input group "=== SESSION ENGINE ==="
input bool   InpUseSessionFilter     = true;
input int    InpTradingStartHour     = 7;
input int    InpTradingEndHour       = 23;

input group "=== EXECUTION SAFETY ==="
input double InpMaxSpreadPrice       = 1.50;

//====================================================================
// GLOBALS
//====================================================================
bool     g_busy=false;
datetime g_lastBarTime=0;
datetime g_lastExitTime=0;
int      g_consecutiveLosses=0;
datetime g_lockoutUntil=0;

int g_fastEMAHandle=INVALID_HANDLE;
int g_slowEMAHandle=INVALID_HANDLE;
int g_atrHandle=INVALID_HANDLE;

//====================================================================
// UTILITY
//====================================================================
double NormalizePrice(const double price)
{
   return NormalizeDouble(price,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
}

double PointSize()
{
   return SymbolInfoDouble(_Symbol,SYMBOL_POINT);
}

double MinStopDistance()
{
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   int freeze=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(stops,freeze)*PointSize();
}

double EffectiveWallDistance()
{
   return MathMax(InpWallDistancePrice,MinStopDistance());
}

bool IsOurOrder(const ulong ticket)
{
   if(ticket==0 || !OrderSelect(ticket))
      return false;

   return OrderGetString(ORDER_SYMBOL)==_Symbol &&
          (ulong)OrderGetInteger(ORDER_MAGIC)==InpMagicNumber;
}

bool IsOurPosition(const ulong ticket)
{
   if(ticket==0 || !PositionSelectByTicket(ticket))
      return false;

   return PositionGetString(POSITION_SYMBOL)==_Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber;
}

int OurPositionCount()
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(IsOurPosition(t)) n++;
   }
   return n;
}

int OurPendingCount()
{
   int n=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(!IsOurOrder(t)) continue;

      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_SELL_STOP)
         n++;
   }
   return n;
}

bool GetOurPosition(ulong &ticket,ENUM_POSITION_TYPE &type,double &openPrice)
{
   ticket=0;
   type=POSITION_TYPE_BUY;
   openPrice=0.0;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(!IsOurPosition(t)) continue;

      ticket=t;
      type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
      return true;
   }
   return false;
}

bool IsTradingSession()
{
   if(!InpUseSessionFilter) return true;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(),tm);

   if(InpTradingStartHour==InpTradingEndHour)
      return true;

   if(InpTradingStartHour<InpTradingEndHour)
      return tm.hour>=InpTradingStartHour && tm.hour<InpTradingEndHour;

   return tm.hour>=InpTradingStartHour || tm.hour<InpTradingEndHour;
}

bool IsSpreadOK()
{
   if(InpMaxSpreadPrice<=0.0) return true;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;

   return (tick.ask-tick.bid)<=InpMaxSpreadPrice;
}

bool IsNewBar()
{
   datetime bar=iTime(_Symbol,PERIOD_CURRENT,0);
   if(bar<=0) return false;

   if(bar!=g_lastBarTime)
   {
      g_lastBarTime=bar;
      return true;
   }
   return false;
}

bool InLossLockout()
{
   return g_lockoutUntil>0 && TimeCurrent()<g_lockoutUntil;
}

bool LossCooldownPassed()
{
   if(!InpUseLossCooldown || g_lastExitTime<=0)
      return true;

   int shift=iBarShift(_Symbol,PERIOD_CURRENT,g_lastExitTime,false);
   if(shift<0) return true;

   return shift>=InpLossCooldownBars;
}

//====================================================================
// INDICATOR ENGINE
//====================================================================
bool GetBufferValue(const int handle,const int buffer,const int shift,double &value)
{
   value=0.0;
   if(handle==INVALID_HANDLE) return false;

   double data[];
   ArraySetAsSeries(data,true);

   if(CopyBuffer(handle,buffer,shift,1,data)!=1)
      return false;

   value=data[0];
   return value>0.0;
}

double GetATR(const int shift=1)
{
   double value=0.0;
   if(!GetBufferValue(g_atrHandle,0,shift,value))
      return 0.0;
   return value;
}

double GetATRMean()
{
   if(g_atrHandle==INVALID_HANDLE) return 0.0;

   int count=MathMax(2,InpATRMeanBars);
   double data[];
   ArraySetAsSeries(data,true);

   if(CopyBuffer(g_atrHandle,0,1,count,data)!=count)
      return 0.0;

   double sum=0.0;
   for(int i=0;i<count;i++)
      sum+=data[i];

   return sum/(double)count;
}

double HighestHigh(const int startShift,const int count)
{
   double highest=0.0;

   for(int i=startShift;i<startShift+count;i++)
   {
      double h=iHigh(_Symbol,PERIOD_CURRENT,i);
      if(h<=0.0) return 0.0;
      if(highest==0.0 || h>highest) highest=h;
   }
   return highest;
}

double LowestLow(const int startShift,const int count)
{
   double lowest=0.0;

   for(int i=startShift;i<startShift+count;i++)
   {
      double l=iLow(_Symbol,PERIOD_CURRENT,i);
      if(l<=0.0) return 0.0;
      if(lowest==0.0 || l<lowest) lowest=l;
   }
   return lowest;
}

bool GetTrendDirection(int &direction)
{
   direction=0;

   if(!InpUseTrendFilter)
      return true;

   double fast=0.0,slow=0.0,fastPast=0.0,slowPast=0.0;

   if(!GetBufferValue(g_fastEMAHandle,0,1,fast)) return false;
   if(!GetBufferValue(g_slowEMAHandle,0,1,slow)) return false;
   if(!GetBufferValue(g_fastEMAHandle,0,1+InpSlopeBars,fastPast)) return false;
   if(!GetBufferValue(g_slowEMAHandle,0,1+InpSlopeBars,slowPast)) return false;

   double close1=iClose(_Symbol,PERIOD_CURRENT,1);
   double atr=GetATR(1);

   if(close1<=0.0 || atr<=0.0)
      return false;

   bool bullish=(fast>slow &&
                 close1>fast &&
                 fast>fastPast &&
                 slow>=slowPast &&
                 (fast-slow)>=atr*InpMinTrendSepATR);

   bool bearish=(fast<slow &&
                 close1<fast &&
                 fast<fastPast &&
                 slow<=slowPast &&
                 (slow-fast)>=atr*InpMinTrendSepATR);

   if(bullish) direction=1;
   else if(bearish) direction=-1;

   return true;
}

bool VolatilityOK()
{
   if(!InpUseATRFilter) return true;

   double atr=GetATR(1);
   double mean=GetATRMean();

   if(atr<=0.0 || mean<=0.0)
      return false;

   return atr>=mean*InpMinATRRatio;
}

//====================================================================
// PENDING ENGINE
//====================================================================
void DeleteAllPending()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(!IsOurOrder(ticket)) continue;

      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type!=ORDER_TYPE_BUY_STOP && type!=ORDER_TYPE_SELL_STOP)
         continue;

      if(!trade.OrderDelete(ticket))
         Print("IronWall V4: pending delete failed #",ticket,
               " ",trade.ResultRetcodeDescription());
   }
}

bool PlaceBuyStop(const double requestedPrice,const double atr)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;

   double price=requestedPrice+atr*InpEntryATRBuffer;
   price=MathMax(price,tick.ask+EffectiveWallDistance());
   price=NormalizePrice(price);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool ok=trade.BuyStop(InpLotSize,price,_Symbol,0.0,0.0,
                         ORDER_TIME_GTC,0,"IronWall V4 BUY STOP");

   if(!ok)
      Print("IronWall V4: BUY STOP failed @",price,
            " ",trade.ResultRetcodeDescription());

   return ok;
}

bool PlaceSellStop(const double requestedPrice,const double atr)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;

   double price=requestedPrice-atr*InpEntryATRBuffer;
   price=MathMin(price,tick.bid-EffectiveWallDistance());
   price=NormalizePrice(price);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool ok=trade.SellStop(InpLotSize,price,_Symbol,0.0,0.0,
                          ORDER_TIME_GTC,0,"IronWall V4 SELL STOP");

   if(!ok)
      Print("IronWall V4: SELL STOP failed @",price,
            " ",trade.ResultRetcodeDescription());

   return ok;
}

void CreateBreakoutOrder()
{
   if(g_busy || OurPositionCount()>0)
      return;

   if(!IsTradingSession() || !IsSpreadOK() ||
      !LossCooldownPassed() || InLossLockout())
   {
      DeleteAllPending();
      return;
   }

   if(!VolatilityOK())
   {
      DeleteAllPending();
      return;
   }

   int direction=0;
   if(!GetTrendDirection(direction))
      return;

   if(direction==0)
   {
      DeleteAllPending();
      return;
   }

   double atr=GetATR(1);
   if(atr<=0.0) return;

   int lookback=MathMax(1,InpBreakoutLookback);
   double high=HighestHigh(1,lookback);
   double low=LowestLow(1,lookback);

   if(high<=0.0 || low<=0.0)
      return;

   DeleteAllPending();

   bool ok=false;
   if(direction>0)
      ok=PlaceBuyStop(high,atr);
   else
      ok=PlaceSellStop(low,atr);

   Print("IronWall V4: SETUP | direction=",
         direction>0?"BUY":"SELL",
         " ATR=",DoubleToString(atr,2),
         " lookback=",lookback,
         " placed=",ok);
}

//====================================================================
// PROTECTION ENGINE
//====================================================================
bool ModifySL(const ulong ticket,double requestedSL)
{
   if(!IsOurPosition(ticket))
      return false;

   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double tp=PositionGetDouble(POSITION_TP);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
      return false;

   double minDist=MinStopDistance();

   if(type==POSITION_TYPE_BUY)
      requestedSL=MathMin(requestedSL,tick.bid-minDist);
   else
      requestedSL=MathMax(requestedSL,tick.ask+minDist);

   requestedSL=NormalizePrice(requestedSL);
   double currentSL=PositionGetDouble(POSITION_SL);

   bool improve=false;
   if(type==POSITION_TYPE_BUY)
      improve=(currentSL==0.0 || requestedSL>currentSL);
   else
      improve=(currentSL==0.0 || requestedSL<currentSL);

   if(!improve)
      return true;

   trade.SetExpertMagicNumber(InpMagicNumber);

   if(!trade.PositionModify(ticket,requestedSL,tp))
   {
      Print("IronWall V4: SL modify failed #",ticket,
            " ",trade.ResultRetcodeDescription());
      return false;
   }

   return true;
}

void ApplyHardSL()
{
   if(!InpUseHardSL) return;

   double atr=GetATR(0);
   if(atr<=0.0) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOurPosition(ticket)) continue;

      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);

      double target=(type==POSITION_TYPE_BUY)
                    ? open-atr*InpSL_ATR_Multiplier
                    : open+atr*InpSL_ATR_Multiplier;

      target=NormalizePrice(target);

      bool needs=(sl==0.0);
      if(type==POSITION_TYPE_BUY)
         needs=needs || sl<target;
      else
         needs=needs || sl>target;

      if(needs)
         ModifySL(ticket,target);
   }
}

void ApplyBreakEven()
{
   if(!InpUseBreakEven) return;

   double atr=GetATR(0);
   if(atr<=0.0) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOurPosition(ticket)) continue;

      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);

      double favorable=(type==POSITION_TYPE_BUY)
                        ? tick.bid-open
                        : open-tick.ask;

      if(favorable<atr*InpBreakEvenATR)
         continue;

      double target=(type==POSITION_TYPE_BUY)
                    ? open+atr*InpBreakEvenOffset
                    : open-atr*InpBreakEvenOffset;

      ModifySL(ticket,target);
   }
}

void ApplyProfitTrail()
{
   if(!InpUseProfitTrail) return;

   double atr=GetATR(0);
   if(atr<=0.0) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOurPosition(ticket)) continue;

      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);

      double favorable=(type==POSITION_TYPE_BUY)
                        ? tick.bid-open
                        : open-tick.ask;

      if(favorable<atr*InpTrailStartATR)
         continue;

      double target=(type==POSITION_TYPE_BUY)
                    ? tick.bid-atr*InpTrailATRDistance
                    : tick.ask+atr*InpTrailATRDistance;

      ModifySL(ticket,target);
   }
}

//====================================================================
// TREND EXIT ENGINE
//====================================================================
int CountTrendExitBars(const ENUM_POSITION_TYPE type)
{
   int count=0;
   int bars=MathMax(1,InpTrendExitBars);

   double fastData[];
   ArraySetAsSeries(fastData,true);

   if(CopyBuffer(g_fastEMAHandle,0,1,bars,fastData)!=bars)
      return 0;

   for(int i=0;i<bars;i++)
   {
      double close=iClose(_Symbol,PERIOD_CURRENT,1+i);
      if(close<=0.0) break;

      if(type==POSITION_TYPE_BUY && close<fastData[i])
         count++;
      else if(type==POSITION_TYPE_SELL && close>fastData[i])
         count++;
      else
         break;
   }

   return count;
}

void ApplyTrendExit()
{
   if(!InpUseTrendExit) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOurPosition(ticket)) continue;

      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(CountTrendExitBars(type)<MathMax(1,InpTrendExitBars))
         continue;

      if(!trade.PositionClose(ticket))
         Print("IronWall V4: trend exit failed #",ticket,
               " ",trade.ResultRetcodeDescription());
      else
         Print("IronWall V4: TREND EXIT #",ticket);
   }
}

//====================================================================
// STATE ENGINE
//====================================================================
void RepairEngine()
{
   if(g_busy) return;

   if(OurPositionCount()>0)
   {
      DeleteAllPending();
      return;
   }

   // A pending setup is valid for one bar only. This prevents a stale
   // breakout order from surviving after the market structure changes.
   if(IsNewBar())
      CreateBreakoutOrder();
}

//====================================================================
// TRADE TRANSACTION
//====================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(g_busy) return;
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   if(HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol)
      return;

   if((ulong)HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagicNumber)
      return;

   ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);

   if(entry==DEAL_ENTRY_IN)
   {
      DeleteAllPending();
      return;
   }

   if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY)
      return;

   double profit=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)
                +HistoryDealGetDouble(trans.deal,DEAL_SWAP)
                +HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);

   g_lastExitTime=(datetime)HistoryDealGetInteger(trans.deal,DEAL_TIME);

   if(profit<0.0)
   {
      g_consecutiveLosses++;

      if(InpUseLossCooldown &&
         InpMaxConsecutiveLosses>0 &&
         g_consecutiveLosses>=InpMaxConsecutiveLosses)
      {
         g_lockoutUntil=g_lastExitTime+
                        PeriodSeconds(PERIOD_CURRENT)*MathMax(1,InpLockoutBars);
      }

      Print("IronWall V4: LOSS | consecutive=",g_consecutiveLosses,
            " | profit=",DoubleToString(profit,2));
   }
   else
   {
      g_consecutiveLosses=0;
      g_lockoutUntil=0;
   }

   DeleteAllPending();
}

//====================================================================
// LIFECYCLE
//====================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpLotSize<=0.0 ||
      InpWallDistancePrice<=0.0 ||
      InpFastEMA<=0 ||
      InpSlowEMA<=0 ||
      InpATRPeriod<=0 ||
      InpBreakoutLookback<=0)
   {
      return INIT_PARAMETERS_INCORRECT;
   }

   g_fastEMAHandle=iMA(_Symbol,PERIOD_CURRENT,InpFastEMA,0,MODE_EMA,PRICE_CLOSE);
   g_slowEMAHandle=iMA(_Symbol,PERIOD_CURRENT,InpSlowEMA,0,MODE_EMA,PRICE_CLOSE);
   g_atrHandle=iATR(_Symbol,PERIOD_CURRENT,InpATRPeriod);

   if(g_fastEMAHandle==INVALID_HANDLE ||
      g_slowEMAHandle==INVALID_HANDLE ||
      g_atrHandle==INVALID_HANDLE)
   {
      Print("IronWall V4: indicator initialization failed.");
      return INIT_FAILED;
   }

   Print("==================================================");
   Print("IronWall V4.00 STARTED");
   Print("Symbol      : ",_Symbol);
   Print("Lot         : ",InpLotSize);
   Print("EMA         : ",InpFastEMA,"/",InpSlowEMA);
   Print("ATR         : ",InpATRPeriod);
   Print("SL ATR      : ",InpSL_ATR_Multiplier);
   Print("BE ATR      : ",InpBreakEvenATR);
   Print("Trail ATR   : ",InpTrailStartATR," / ",InpTrailATRDistance);
   Print("Trend Exit  : ",InpUseTrendExit);
   Print("Session     : ",InpTradingStartHour,"-",InpTradingEndHour);
   Print("==================================================");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fastEMAHandle!=INVALID_HANDLE)
      IndicatorRelease(g_fastEMAHandle);

   if(g_slowEMAHandle!=INVALID_HANDLE)
      IndicatorRelease(g_slowEMAHandle);

   if(g_atrHandle!=INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);

   Print("IronWall V4.00 stopped. reason=",reason);
}

void OnTick()
{
   ApplyHardSL();
   ApplyBreakEven();
   ApplyProfitTrail();
   ApplyTrendExit();
   RepairEngine();
}
//+------------------------------------------------------------------+
