//+------------------------------------------------------------------+
//|                                          IronWall_V3.1.mq5        |
//|        IronWall V3.1 - Session Edge + Loss Containment           |
//+------------------------------------------------------------------+
#property strict
#property version   "3.10"
#property description "IronWall V3.1 - 10:00-11:00 session, two-sided wall, hard loss control and profit protection"

#include <Trade/Trade.mqh>
CTrade trade;

//====================================================================
// INPUTS
//====================================================================
input group "=== IRONWALL CORE ==="
input double InpLotSize            = 0.05;
input double InpDistancePrice      = 10.0;
input ulong  InpMagicNumber        = 26081601;
input int    InpDeviationPoints    = 30;

input group "=== SESSION ENGINE ==="
input bool   InpUseSessionFilter  = true;
input int    InpSessionStartHour  = 10;
input int    InpSessionStartMinute= 0;
input int    InpSessionEndHour    = 11;
input int    InpSessionEndMinute  = 0;
input bool   InpCloseAtSessionEnd = true;

input group "=== LOSS CONTAINMENT ==="
input bool   InpUseHardSL         = true;
input double InpHardSLPrice       = 12.0;
input bool   InpUseBreakEven      = true;
input double InpBreakEvenStart    = 5.0;
input double InpBreakEvenLock     = 0.5;

input group "=== PROFIT TRAIL ==="
input bool   InpUseProfitTrail    = true;
input double InpTrailStartPrice   = 8.0;
input double InpTrailDistance     = 4.0;

//====================================================================
// GLOBALS
//====================================================================
bool g_busy=false;

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
   const int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(stops,freeze)*PointSize();
}

double EffectiveDistance()
{
   return MathMax(InpDistancePrice,MinStopDistance());
}

bool IsOurOrder(const ulong ticket)
{
   if(ticket==0 || !OrderSelect(ticket)) return false;
   return OrderGetString(ORDER_SYMBOL)==_Symbol &&
          (ulong)OrderGetInteger(ORDER_MAGIC)==InpMagicNumber;
}

bool IsOurPosition(const ulong ticket)
{
   if(ticket==0 || !PositionSelectByTicket(ticket)) return false;
   return PositionGetString(POSITION_SYMBOL)==_Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber;
}

int OurPositionCount()
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      const ulong t=PositionGetTicket(i);
      if(IsOurPosition(t)) n++;
   }
   return n;
}

int OurPendingCount()
{
   int n=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      const ulong t=OrderGetTicket(i);
      if(!IsOurOrder(t)) continue;
      const ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_SELL_STOP) n++;
   }
   return n;
}

bool GetOurPosition(ulong &ticket,ENUM_POSITION_TYPE &type,double &openPrice)
{
   ticket=0; openPrice=0.0; type=POSITION_TYPE_BUY;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      const ulong t=PositionGetTicket(i);
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
   const int now=tm.hour*60+tm.min;
   const int start=InpSessionStartHour*60+InpSessionStartMinute;
   const int end=InpSessionEndHour*60+InpSessionEndMinute;

   if(start==end) return true;
   if(start<end) return now>=start && now<end;
   return now>=start || now<end;
}

bool IsAfterSessionEnd()
{
   if(!InpUseSessionFilter) return false;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(),tm);
   const int now=tm.hour*60+tm.min;
   const int start=InpSessionStartHour*60+InpSessionStartMinute;
   const int end=InpSessionEndHour*60+InpSessionEndMinute;

   if(start<end) return now>=end;
   return now>=end && now<start;
}

//====================================================================
// PENDING ENGINE
//====================================================================
void DeleteAllPending()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      const ulong ticket=OrderGetTicket(i);
      if(!IsOurOrder(ticket)) continue;
      const ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type!=ORDER_TYPE_BUY_STOP && type!=ORDER_TYPE_SELL_STOP) continue;
      if(!trade.OrderDelete(ticket))
         Print("IronWall V3.1: delete failed #",ticket," ",trade.ResultRetcodeDescription());
   }
}

bool PlaceBuyStop(const double requestedPrice)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;

   const double d=EffectiveDistance();
   const double price=NormalizePrice(MathMax(requestedPrice,tick.ask+d));

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   const bool ok=trade.BuyStop(InpLotSize,price,_Symbol,0.0,0.0,ORDER_TIME_GTC,0,"IronWall V3.1 BUY STOP");
   if(!ok) Print("IronWall V3.1: BUY STOP failed @",price," ",trade.ResultRetcodeDescription());
   return ok;
}

bool PlaceSellStop(const double requestedPrice)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;

   const double d=EffectiveDistance();
   const double price=NormalizePrice(MathMin(requestedPrice,tick.bid-d));

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   const bool ok=trade.SellStop(InpLotSize,price,_Symbol,0.0,0.0,ORDER_TIME_GTC,0,"IronWall V3.1 SELL STOP");
   if(!ok) Print("IronWall V3.1: SELL STOP failed @",price," ",trade.ResultRetcodeDescription());
   return ok;
}

void CreateInitialWall()
{
   if(g_busy || OurPositionCount()>0) return;
   if(!IsTradingSession()) { DeleteAllPending(); return; }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;

   DeleteAllPending();
   const double d=EffectiveDistance();
   const double buyPrice=NormalizePrice(tick.ask+d);
   const double sellPrice=NormalizePrice(tick.bid-d);

   const bool buyOK=PlaceBuyStop(buyPrice);
   const bool sellOK=PlaceSellStop(sellPrice);

   Print("IronWall V3.1: INITIAL WALL | BUY=",buyPrice,"/",buyOK,
         " SELL=",sellPrice,"/",sellOK);
}

void RebuildReversalWall(const ENUM_POSITION_TYPE type,const double openPrice)
{
   if(g_busy || !IsTradingSession()) return;

   DeleteAllPending();
   const double d=EffectiveDistance();

   if(type==POSITION_TYPE_BUY)
      PlaceSellStop(NormalizePrice(openPrice-d));
   else
      PlaceBuyStop(NormalizePrice(openPrice+d));
}

//====================================================================
// POSITION ENGINE
//====================================================================
bool ClosePositionTicket(const ulong ticket)
{
   if(!IsOurPosition(ticket)) return true;
   if(!trade.PositionClose(ticket))
   {
      Print("IronWall V3.1: close failed #",ticket," ",trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

bool CloseAllOurPositions()
{
   bool success=true;
   for(int pass=0;pass<3;pass++)
   {
      bool found=false;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         const ulong t=PositionGetTicket(i);
         if(!IsOurPosition(t)) continue;
         found=true;
         if(!ClosePositionTicket(t)) success=false;
      }
      if(!found) break;
   }
   return success && OurPositionCount()==0;
}

bool CloseAllExcept(const ulong keepTicket)
{
   bool success=true;
   for(int pass=0;pass<3;pass++)
   {
      bool found=false;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         const ulong t=PositionGetTicket(i);
         if(!IsOurPosition(t) || t==keepTicket) continue;
         found=true;
         if(!ClosePositionTicket(t)) success=false;
      }
      if(!found) break;
   }
   return success;
}

//====================================================================
// RISK ENGINE
//====================================================================
void ManageProtection()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      const ulong ticket=PositionGetTicket(i);
      if(!IsOurPosition(ticket)) continue;

      const ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double open=PositionGetDouble(POSITION_PRICE_OPEN);
      const double oldSL=PositionGetDouble(POSITION_SL);
      const double tp=PositionGetDouble(POSITION_TP);
      const double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      const double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      const double favorable=(type==POSITION_TYPE_BUY)?(bid-open):(open-ask);

      double desiredSL=oldSL;
      bool hasCandidate=false;

      // Hard SL: caps the exact adverse price movement.
      if(InpUseHardSL && InpHardSLPrice>0.0)
      {
         const double hard=(type==POSITION_TYPE_BUY)?open-InpHardSLPrice:open+InpHardSLPrice;
         desiredSL=NormalizePrice(hard);
         hasCandidate=true;
      }

      // Break-even locks a small amount after the trade has moved in favor.
      if(InpUseBreakEven && favorable>=InpBreakEvenStart)
      {
         const double be=(type==POSITION_TYPE_BUY)?open+InpBreakEvenLock:open-InpBreakEvenLock;
         if(!hasCandidate ||
            (type==POSITION_TYPE_BUY && be>desiredSL) ||
            (type==POSITION_TYPE_SELL && be<desiredSL))
         {
            desiredSL=NormalizePrice(be);
            hasCandidate=true;
         }
      }

      // Profit trail only moves SL in the profitable direction.
      if(InpUseProfitTrail && favorable>=InpTrailStartPrice && InpTrailDistance>0.0)
      {
         const double trail=(type==POSITION_TYPE_BUY)?bid-InpTrailDistance:ask+InpTrailDistance;
         if(!hasCandidate ||
            (type==POSITION_TYPE_BUY && trail>desiredSL) ||
            (type==POSITION_TYPE_SELL && trail<desiredSL))
         {
            desiredSL=NormalizePrice(trail);
            hasCandidate=true;
         }
      }

      if(!hasCandidate) continue;

      const double minDist=MinStopDistance();
      if(type==POSITION_TYPE_BUY)
         desiredSL=MathMin(desiredSL,bid-minDist);
      else
         desiredSL=MathMax(desiredSL,ask+minDist);
      desiredSL=NormalizePrice(desiredSL);

      bool improve=false;
      if(type==POSITION_TYPE_BUY)
         improve=(oldSL==0.0 || desiredSL>oldSL+PointSize()*0.5);
      else
         improve=(oldSL==0.0 || desiredSL<oldSL-PointSize()*0.5);

      if(improve)
      {
         if(!trade.PositionModify(ticket,desiredSL,tp))
            Print("IronWall V3.1: SL modify failed #",ticket," ",trade.ResultRetcodeDescription());
      }
   }
}

//====================================================================
// STATE REPAIR
//====================================================================
void RepairEngine()
{
   if(g_busy) return;

   if(!IsTradingSession())
   {
      DeleteAllPending();
      if(InpCloseAtSessionEnd && IsAfterSessionEnd() && OurPositionCount()>0)
         CloseAllOurPositions();
      return;
   }

   const int positions=OurPositionCount();
   const int pending=OurPendingCount();

   if(positions==0)
   {
      if(pending!=2) CreateInitialWall();
      return;
   }

   if(positions>1)
   {
      ulong keep; ENUM_POSITION_TYPE keepType; double keepOpen;
      if(GetOurPosition(keep,keepType,keepOpen))
         CloseAllExcept(keep);
   }

   ulong ticket; ENUM_POSITION_TYPE type; double openPrice;
   if(!GetOurPosition(ticket,type,openPrice)) return;

   // While a position exists, keep exactly one opposite reversal wall.
   if(OurPendingCount()!=1)
      RebuildReversalWall(type,openPrice);
}

//====================================================================
// TRADE TRANSACTION
//====================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(g_busy) return;
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol) return;
   if((ulong)HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagicNumber) return;

   const ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(entry!=DEAL_ENTRY_IN) return;

   g_busy=true;
   DeleteAllPending();
   g_busy=false;

   RepairEngine();
}

//====================================================================
// LIFECYCLE
//====================================================================
int OnInit()
{
   if(InpLotSize<=0.0 || InpDistancePrice<=0.0)
      return INIT_PARAMETERS_INCORRECT;
   if(InpUseHardSL && InpHardSLPrice<=0.0)
      return INIT_PARAMETERS_INCORRECT;
   if(InpUseProfitTrail && InpTrailDistance<=0.0)
      return INIT_PARAMETERS_INCORRECT;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   Print("==================================================");
   Print("IronWall V3.10 STARTED");
   Print("Session   : ",InpSessionStartHour,":",InpSessionStartMinute," -> ",InpSessionEndHour,":",InpSessionEndMinute);
   Print("Distance  : ",InpDistancePrice);
   Print("Hard SL   : ",InpUseHardSL?DoubleToString(InpHardSLPrice,2):"OFF");
   Print("BE        : ",InpUseBreakEven?DoubleToString(InpBreakEvenStart,2):"OFF");
   Print("Trail     : ",InpUseProfitTrail?DoubleToString(InpTrailStartPrice,2):"OFF");
   Print("==================================================");

   RepairEngine();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("IronWall V3.10 stopped. reason=",reason);
}

void OnTick()
{
   // Outside the tested profitable window: no new orders and optionally close.
   if(!IsTradingSession())
   {
      DeleteAllPending();
      if(InpCloseAtSessionEnd && IsAfterSessionEnd() && OurPositionCount()>0)
         CloseAllOurPositions();
      return;
   }

   ManageProtection();
   RepairEngine();
}
//+------------------------------------------------------------------+
