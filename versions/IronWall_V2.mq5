//+------------------------------------------------------------------+
//|                                              IronWall_V2.mq5      |
//|                 IronWall V2 - Momentum Retention Engine           |
//|                         Version 2.00                              |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"
#property description "IronWall V2 - keep the active position, trail profit, and use one reversal wall"

#include <Trade/Trade.mqh>

CTrade trade;

//====================================================================
// INPUTS
//====================================================================
input group "=== IRONWALL V2 ==="
input double InpLotSize         = 0.01;
input double InpDistancePrice   = 10.0;
input ulong  InpMagicNumber     = 26081601;
input int    InpDeviationPoints = 30;

input group "=== MOMENTUM PROFIT ENGINE ==="
input bool   InpUseProfitLock   = true;
input double InpLockStartPrice  = 5.0;   // price move before SL protection begins
input double InpLockDistance    = 3.0;   // price distance behind market

input group "=== EMERGENCY ==="
input bool   InpUseEmergencySL  = false;
input double InpEmergencySLPrice= 100.0;

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

bool IsHedgingAccount()
{
   const ENUM_ACCOUNT_MARGIN_MODE mode=
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return mode==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
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
      ulong ticket=PositionGetTicket(i);
      if(IsOurPosition(ticket)) n++;
   }
   return n;
}

int OurPendingCount()
{
   int n=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(!IsOurOrder(ticket)) continue;
      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_SELL_STOP) n++;
   }
   return n;
}

bool GetOurPosition(ulong &ticket,ENUM_POSITION_TYPE &type,double &openPrice)
{
   ticket=0; openPrice=0.0; type=POSITION_TYPE_BUY;
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
      if(type!=ORDER_TYPE_BUY_STOP && type!=ORDER_TYPE_SELL_STOP) continue;
      if(!trade.OrderDelete(ticket))
         Print("IronWall V2: delete pending failed #",ticket," ",trade.ResultRetcodeDescription());
   }
}

bool PlaceBuyStop(const double requestedPrice)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;
   double price=NormalizePrice(MathMax(requestedPrice,tick.ask+EffectiveDistance()));

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool ok=trade.BuyStop(InpLotSize,price,_Symbol,0.0,0.0,ORDER_TIME_GTC,0,"IronWall V2 BUY STOP");
   if(!ok) Print("IronWall V2: BUY STOP failed @",price," ",trade.ResultRetcodeDescription());
   return ok;
}

bool PlaceSellStop(const double requestedPrice)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;
   double price=NormalizePrice(MathMin(requestedPrice,tick.bid-EffectiveDistance()));

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool ok=trade.SellStop(InpLotSize,price,_Symbol,0.0,0.0,ORDER_TIME_GTC,0,"IronWall V2 SELL STOP");
   if(!ok) Print("IronWall V2: SELL STOP failed @",price," ",trade.ResultRetcodeDescription());
   return ok;
}

void CreateInitialWall()
{
   if(g_busy || OurPositionCount()>0) return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;

   DeleteAllPending();
   const double d=EffectiveDistance();
   double buyPrice=NormalizePrice(tick.ask+d);
   double sellPrice=NormalizePrice(tick.bid-d);

   bool buyOK=PlaceBuyStop(buyPrice);
   bool sellOK=PlaceSellStop(sellPrice);

   Print("IronWall V2: INITIAL WALL | BUY=",buyPrice," / ",buyOK,
         " | SELL=",sellPrice," / ",sellOK);
}

void RebuildReversalWall(const ENUM_POSITION_TYPE type,const double openPrice)
{
   if(g_busy) return;
   DeleteAllPending();

   const double d=EffectiveDistance();
   const double upper=NormalizePrice(openPrice+d);
   const double lower=NormalizePrice(openPrice-d);

   if(type==POSITION_TYPE_BUY)
   {
      // Only the opposite wall remains as a reversal trigger.
      PlaceSellStop(lower);
   }
   else
   {
      // Only the opposite wall remains as a reversal trigger.
      PlaceBuyStop(upper);
   }
}

//====================================================================
// POSITION ENGINE
//====================================================================
bool ClosePositionTicket(const ulong ticket)
{
   if(!IsOurPosition(ticket)) return true;
   if(!trade.PositionClose(ticket))
   {
      Print("IronWall V2: close failed #",ticket," ",trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

bool CloseAllExcept(const ulong keepTicket)
{
   bool success=true;
   for(int pass=0;pass<3;pass++)
   {
      bool found=false;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong t=PositionGetTicket(i);
         if(!IsOurPosition(t) || t==keepTicket) continue;
         found=true;
         if(!ClosePositionTicket(t)) success=false;
      }
      if(!found) break;
   }
   return success;
}

bool CloseAllOurPositions()
{
   bool success=true;
   for(int pass=0;pass<3;pass++)
   {
      bool found=false;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong t=PositionGetTicket(i);
         if(!IsOurPosition(t)) continue;
         found=true;
         if(!ClosePositionTicket(t)) success=false;
      }
      if(!found) break;
   }
   return success && OurPositionCount()==0;
}

bool OpenMarketDirection(const ENUM_DEAL_TYPE direction)
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   bool ok=false;
   if(direction==DEAL_TYPE_BUY) ok=trade.Buy(InpLotSize,_Symbol,0,0,0,"IronWall V2 BUY");
   if(direction==DEAL_TYPE_SELL) ok=trade.Sell(InpLotSize,_Symbol,0,0,0,"IronWall V2 SELL");
   if(!ok) Print("IronWall V2: reopen failed ",trade.ResultRetcodeDescription());
   return ok;
}

//====================================================================
// PROFIT ENGINE
//====================================================================
void ManageProfitLock()
{
   if(!InpUseProfitLock) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOurPosition(ticket)) continue;

      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      double favorable=(type==POSITION_TYPE_BUY)?(bid-open):(open-ask);
      if(favorable<InpLockStartPrice) continue;

      double newSL=(type==POSITION_TYPE_BUY)?(bid-InpLockDistance):(ask+InpLockDistance);
      newSL=NormalizePrice(newSL);

      double minDist=MinStopDistance();
      if(type==POSITION_TYPE_BUY)
         newSL=MathMin(newSL,bid-minDist);
      else
         newSL=MathMax(newSL,ask+minDist);

      newSL=NormalizePrice(newSL);

      bool improve=(type==POSITION_TYPE_BUY)?(sl==0.0 || newSL>sl):(sl==0.0 || newSL<sl);
      if(improve)
      {
         if(!trade.PositionModify(ticket,newSL,tp))
            Print("IronWall V2: profit lock modify failed #",ticket," ",trade.ResultRetcodeDescription());
      }
   }
}

void ManageEmergencySL()
{
   if(!InpUseEmergencySL) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOurPosition(ticket)) continue;

      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double target=(type==POSITION_TYPE_BUY)?open-InpEmergencySLPrice:open+InpEmergencySLPrice;
      target=NormalizePrice(target);

      bool valid=(type==POSITION_TYPE_BUY)?(sl==0.0 || sl<target):(sl==0.0 || sl>target);
      if(valid && !trade.PositionModify(ticket,target,tp))
         Print("IronWall V2: emergency SL modify failed #",ticket," ",trade.ResultRetcodeDescription());
   }
}

//====================================================================
// TRIGGER HANDLER
//====================================================================
// V2 principle:
// 1. Do NOT close/reopen on SAME-DIRECTION continuation.
// 2. Keep the current position running.
// 3. The only pending order while a position exists is the opposite
//    reversal wall.
// 4. If reversal triggers, normalize the campaign to the new side.
//
bool HandleTriggeredDeal(const ulong dealTicket)
{
   if(!HistoryDealSelect(dealTicket)) return false;

   ENUM_DEAL_TYPE direction=(ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket,DEAL_TYPE);
   if(direction!=DEAL_TYPE_BUY && direction!=DEAL_TYPE_SELL) return false;

   DeleteAllPending();

   if(IsHedgingAccount())
   {
      ulong triggered=(ulong)HistoryDealGetInteger(dealTicket,DEAL_POSITION_ID);
      if(!CloseAllExcept(triggered)) return false;
      return IsOurPosition(triggered);
   }

   // In netting, the triggered deal can reverse the net position.
   // Do not immediately close/reopen it. Treat the broker's resulting
   // net position as the active campaign and rebuild from its state.
   return OurPositionCount()==1;
}

//====================================================================
// REPAIR / STATE MACHINE
//====================================================================
void RepairEngine()
{
   if(g_busy) return;

   const int positions=OurPositionCount();
   const int pending=OurPendingCount();

   if(positions==0)
   {
      if(pending!=2) CreateInitialWall();
      return;
   }

   if(positions>1)
   {
      ulong keep; ENUM_POSITION_TYPE type; double open;
      if(GetOurPosition(keep,type,open))
      {
         CloseAllExcept(keep);
      }
   }

   ulong ticket; ENUM_POSITION_TYPE type; double openPrice;
   if(!GetOurPosition(ticket,type,openPrice)) return;

   // Position exists: V2 keeps only ONE opposite reversal wall.
   // The active trade itself is allowed to run; no artificial close /
   // reopen occurs on favorable continuation.
   if(pending!=1)
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

   ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(entry!=DEAL_ENTRY_IN) return;

   ENUM_DEAL_TYPE direction=(ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal,DEAL_TYPE);
   if(direction!=DEAL_TYPE_BUY && direction!=DEAL_TYPE_SELL) return;

   g_busy=true;
   DeleteAllPending();

   if(!HandleTriggeredDeal(trans.deal))
      Print("IronWall V2: trigger normalization failed. Repair engine will retry.");

   g_busy=false;
   RepairEngine();
}

//====================================================================
// LIFECYCLE
//====================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpLotSize<=0.0 || InpDistancePrice<=0.0)
      return INIT_PARAMETERS_INCORRECT;

   Print("==================================================");
   Print("IronWall V2.00 STARTED");
   Print("Symbol   : ",_Symbol);
   Print("Lot      : ",InpLotSize);
   Print("Distance : ",InpDistancePrice);
   Print("Magic    : ",InpMagicNumber);
   Print("Mode     : MOMENTUM RETENTION");
   Print("Filters  : NONE");
   Print("==================================================");

   RepairEngine();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("IronWall V2.00 stopped. reason=",reason);
}

void OnTick()
{
   // No EMA, RSI, ATR, ADX, spread or session filter.
   // The tick loop only maintains the state and protects profit.
   ManageProfitLock();
   ManageEmergencySL();
   RepairEngine();
}
//+------------------------------------------------------------------+
