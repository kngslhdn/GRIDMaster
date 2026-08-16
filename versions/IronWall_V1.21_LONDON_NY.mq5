//+------------------------------------------------------------------+
//|                                  IronWall_V1.21_LONDON_NY.mq5     |
//|        IronWall V1.21 - V1.10 Core + London / New York Gate      |
//+------------------------------------------------------------------+
#property strict
#property version   "1.21"
#property description "IronWall V1.21 - V1.10 momentum wall, London/New York session only"

#include <Trade/Trade.mqh>

CTrade trade;

//====================================================================
// INPUTS
//====================================================================
input group "=== IRONWALL V1.21 CORE - UNCHANGED ==="
input double InpLotSize         = 0.01;
input double InpDistancePrice   = 10.0;
input ulong  InpMagicNumber     = 26081601;
input int    InpDeviationPoints = 30;

input group "=== LONDON / NEW YORK SESSION ==="
input bool   InpUseLondonSession = true;
input int    InpLondonStartHour  = 8;
input int    InpLondonEndHour    = 16;
input bool   InpUseNewYorkSession = true;
input int    InpNewYorkStartHour  = 13;
input int    InpNewYorkEndHour    = 21;

//====================================================================
// GLOBALS
//====================================================================
bool g_busy = false;

//====================================================================
// SESSION ENGINE - THE ONLY STRATEGY CHANGE FROM V1.10
// Times are broker/server time. London/New York overlap is allowed.
// Outside both windows all pending walls are removed. Existing active
// positions are NOT force-closed; only new trading is blocked.
//====================================================================
bool IsHourInWindow(const int hour,const int startHour,const int endHour)
{
   if(startHour == endHour)
      return true;

   if(startHour < endHour)
      return(hour >= startHour && hour < endHour);

   return(hour >= startHour || hour < endHour);
}

bool IsLondonSession()
{
   if(!InpUseLondonSession)
      return false;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(),tm);
   return IsHourInWindow(tm.hour,InpLondonStartHour,InpLondonEndHour);
}

bool IsNewYorkSession()
{
   if(!InpUseNewYorkSession)
      return false;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(),tm);
   return IsHourInWindow(tm.hour,InpNewYorkStartHour,InpNewYorkEndHour);
}

bool IsAllowedTradingSession()
{
   // If both session switches are disabled, fail closed: no trading.
   if(!InpUseLondonSession && !InpUseNewYorkSession)
      return false;

   return(IsLondonSession() || IsNewYorkSession());
}

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
   return stops*PointSize();
}

double EffectiveDistance()
{
   return MathMax(InpDistancePrice,MinStopDistance());
}

bool IsHedgingAccount()
{
   const ENUM_ACCOUNT_MARGIN_MODE mode=
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   return(mode==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

bool IsOurOrder(const ulong ticket)
{
   if(ticket==0 || !OrderSelect(ticket))
      return false;

   if(OrderGetString(ORDER_SYMBOL)!=_Symbol)
      return false;

   return((ulong)OrderGetInteger(ORDER_MAGIC)==InpMagicNumber);
}

bool IsOurPosition(const ulong ticket)
{
   if(ticket==0 || !PositionSelectByTicket(ticket))
      return false;

   if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
      return false;

   return((ulong)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber);
}

//====================================================================
// POSITION ENGINE
//====================================================================
int OurPositionCount()
{
   int count=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      const ulong ticket=PositionGetTicket(i);

      if(IsOurPosition(ticket))
         count++;
   }

   return count;
}

bool GetOurPosition(ulong &ticket,
                    ENUM_POSITION_TYPE &type,
                    double &openPrice)
{
   ticket=0;
   openPrice=0.0;
   type=POSITION_TYPE_BUY;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      const ulong positionTicket=PositionGetTicket(i);

      if(!IsOurPosition(positionTicket))
         continue;

      ticket=positionTicket;
      type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      openPrice=PositionGetDouble(POSITION_PRICE_OPEN);

      return true;
   }

   return false;
}

//====================================================================
// PENDING ENGINE
//====================================================================
int OurPendingCount()
{
   int count=0;

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      const ulong ticket=OrderGetTicket(i);

      if(!IsOurOrder(ticket))
         continue;

      const ENUM_ORDER_TYPE type=
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_SELL_STOP)
         count++;
   }

   return count;
}

void DeleteAllPending()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      const ulong ticket=OrderGetTicket(i);

      if(!IsOurOrder(ticket))
         continue;

      const ENUM_ORDER_TYPE type=
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type!=ORDER_TYPE_BUY_STOP && type!=ORDER_TYPE_SELL_STOP)
         continue;

      if(!trade.OrderDelete(ticket))
      {
         Print("IronWall V1.21: delete pending failed #",ticket,
               " retcode=",trade.ResultRetcode(),
               " ",trade.ResultRetcodeDescription());
      }
   }
}

bool PlaceBuyStop(const double requestedPrice)
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol,tick))
      return false;

   const double distance=EffectiveDistance();

   double price=MathMax(requestedPrice,tick.ask+distance);
   price=NormalizePrice(price);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   const bool ok=trade.BuyStop(
      InpLotSize,
      price,
      _Symbol,
      0.0,
      0.0,
      ORDER_TIME_GTC,
      0,
      "IronWall V1.21 BUY STOP"
   );

   if(!ok)
   {
      Print("IronWall V1.21: BUY STOP failed price=",price,
            " retcode=",trade.ResultRetcode(),
            " ",trade.ResultRetcodeDescription());
   }

   return ok;
}

bool PlaceSellStop(const double requestedPrice)
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol,tick))
      return false;

   const double distance=EffectiveDistance();

   double price=MathMin(requestedPrice,tick.bid-distance);
   price=NormalizePrice(price);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   const bool ok=trade.SellStop(
      InpLotSize,
      price,
      _Symbol,
      0.0,
      0.0,
      ORDER_TIME_GTC,
      0,
      "IronWall V1.21 SELL STOP"
   );

   if(!ok)
   {
      Print("IronWall V1.21: SELL STOP failed price=",price,
            " retcode=",trade.ResultRetcode(),
            " ",trade.ResultRetcodeDescription());
   }

   return ok;
}

//====================================================================
// INITIAL WALL
//====================================================================
// V1.10 core preserved exactly in behavior:
// No position:
//   BUY STOP  = above market
//   SELL STOP = below market
// The first side touched becomes the active position.
//====================================================================
void CreateInitialWall()
{
   if(g_busy || OurPositionCount()>0)
      return;

   if(!IsAllowedTradingSession())
      return;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol,tick))
      return;

   const double distance=EffectiveDistance();

   const double buyPrice=NormalizePrice(tick.ask+distance);
   const double sellPrice=NormalizePrice(tick.bid-distance);

   DeleteAllPending();

   const bool buyOK=PlaceBuyStop(buyPrice);
   const bool sellOK=PlaceSellStop(sellPrice);

   Print("IronWall V1.21: INITIAL WALL | SESSION=",
         IsLondonSession()?"LONDON":"",
         IsNewYorkSession()?" NEW_YORK":"",
         " | BUY STOP=",buyPrice,
         " | SELL STOP=",sellPrice,
         " | BUY=",buyOK,
         " | SELL=",sellOK);
}

//====================================================================
// WALL AROUND ACTIVE POSITION
//====================================================================
// V1.10 core preserved:
// BUY active at 4000:
//   BUY STOP  = 4010 -> continuation / profit step
//   SELL STOP = 3990 -> reversal / loss step
// SELL active at 4000:
//   BUY STOP  = 4010 -> reversal / loss step
//   SELL STOP = 3990 -> continuation / profit step
//====================================================================
void RebuildWallAroundPosition()
{
   if(g_busy)
      return;

   if(!IsAllowedTradingSession())
   {
      DeleteAllPending();
      return;
   }

   ulong ticket;
   ENUM_POSITION_TYPE type;
   double openPrice;

   if(!GetOurPosition(ticket,type,openPrice))
      return;

   const double distance=EffectiveDistance();

   const double upperPrice=NormalizePrice(openPrice+distance);
   const double lowerPrice=NormalizePrice(openPrice-distance);

   DeleteAllPending();

   PlaceBuyStop(upperPrice);
   PlaceSellStop(lowerPrice);

   Print("IronWall V1.21: WALL | SESSION=",
         IsLondonSession()?"LONDON":"",
         IsNewYorkSession()?" NEW_YORK":"",
         " | direction=",
         type==POSITION_TYPE_BUY?"BUY":"SELL",
         " | OPEN=",openPrice,
         " | BUY STOP=",upperPrice,
         " | SELL STOP=",lowerPrice);
}

//====================================================================
// POSITION CLOSE ENGINE - V1.10 CORE UNCHANGED
//====================================================================
bool ClosePositionTicket(const ulong ticket)
{
   if(!IsOurPosition(ticket))
      return true;

   if(!trade.PositionClose(ticket))
   {
      Print("IronWall V1.21: close position failed #",ticket,
            " retcode=",trade.ResultRetcode(),
            " ",trade.ResultRetcodeDescription());
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
         const ulong ticket=PositionGetTicket(i);

         if(!IsOurPosition(ticket) || ticket==keepTicket)
            continue;

         found=true;

         if(!ClosePositionTicket(ticket))
            success=false;
      }

      if(!found)
         break;
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
         const ulong ticket=PositionGetTicket(i);

         if(!IsOurPosition(ticket))
            continue;

         found=true;

         if(!ClosePositionTicket(ticket))
            success=false;
      }

      if(!found)
         break;
   }

   return success && OurPositionCount()==0;
}

bool OpenMarketDirection(const ENUM_DEAL_TYPE direction)
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool ok=false;

   if(direction==DEAL_TYPE_BUY)
      ok=trade.Buy(InpLotSize,_Symbol,0.0,0.0,0.0,"IronWall V1.21 BUY");
   else if(direction==DEAL_TYPE_SELL)
      ok=trade.Sell(InpLotSize,_Symbol,0.0,0.0,0.0,"IronWall V1.21 SELL");

   if(!ok)
   {
      Print("IronWall V1.21: market reopen failed direction=",
            direction==DEAL_TYPE_BUY?"BUY":"SELL",
            " retcode=",trade.ResultRetcode(),
            " ",trade.ResultRetcodeDescription());
   }

   return ok;
}

//====================================================================
// TRIGGER HANDLER - V1.10 CORE UNCHANGED
//====================================================================
bool HandleTriggeredDeal(const ulong dealTicket)
{
   if(!HistoryDealSelect(dealTicket))
      return false;

   const ENUM_DEAL_TYPE direction=
      (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket,DEAL_TYPE);

   if(direction!=DEAL_TYPE_BUY && direction!=DEAL_TYPE_SELL)
      return false;

   const ulong triggeredPositionTicket=
      (ulong)HistoryDealGetInteger(dealTicket,DEAL_POSITION_ID);

   DeleteAllPending();

   // HEDGING ACCOUNT
   if(IsHedgingAccount())
   {
      if(!CloseAllExcept(triggeredPositionTicket))
         return false;

      if(!IsOurPosition(triggeredPositionTicket))
      {
         Print("IronWall V1.21: triggered position disappeared #",
               triggeredPositionTicket);
         return false;
      }

      return true;
   }

   // NETTING ACCOUNT
   if(!CloseAllOurPositions())
      return false;

   if(!OpenMarketDirection(direction))
      return false;

   return true;
}

//====================================================================
// EMERGENCY REPAIR
//====================================================================
void RepairEngine()
{
   if(g_busy)
      return;

   // SESSION GATE: Asia and all other hours are completely inactive.
   // Pending orders are removed so they cannot trigger during Asia.
   // Existing positions are intentionally left open.
   if(!IsAllowedTradingSession())
   {
      if(OurPendingCount()>0)
         DeleteAllPending();

      return;
   }

   const int positions=OurPositionCount();
   const int pending=OurPendingCount();

   if(positions==0)
   {
      // Active London/NY session must always have exactly two wall orders.
      if(pending!=2)
         CreateInitialWall();

      return;
   }

   // IronWall remains designed around exactly one active position.
   if(positions>1)
   {
      ulong keepTicket;
      ENUM_POSITION_TYPE keepType;
      double keepOpen;

      if(GetOurPosition(keepTicket,keepType,keepOpen))
      {
         for(int i=PositionsTotal()-1;i>=0;i--)
         {
            const ulong ticket=PositionGetTicket(i);

            if(!IsOurPosition(ticket) || ticket==keepTicket)
               continue;

            ClosePositionTicket(ticket);
         }
      }
   }

   if(OurPendingCount()!=2)
      RebuildWallAroundPosition();
}

//====================================================================
// TRADE TRANSACTION
//====================================================================
void OnTradeTransaction(
   const MqlTradeTransaction &trans,
   const MqlTradeRequest &request,
   const MqlTradeResult &result)
{
   if(g_busy)
      return;

   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(trans.deal==0)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   if(HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol)
      return;

   if((ulong)HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagicNumber)
      return;

   const ENUM_DEAL_ENTRY entry=
      (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);

   // Only react to a NEW ENTRY deal.
   if(entry!=DEAL_ENTRY_IN)
      return;

   const ENUM_DEAL_TYPE dealType=
      (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal,DEAL_TYPE);

   if(dealType!=DEAL_TYPE_BUY && dealType!=DEAL_TYPE_SELL)
      return;

   // A pending order must never survive into a blocked session.
   if(!IsAllowedTradingSession())
   {
      DeleteAllPending();
      return;
   }

   g_busy=true;

   Print("==================================================");
   Print("IronWall V1.21: MOMENTUM TRIGGER");
   Print("Session   : ",IsLondonSession()?"LONDON":"",
         IsNewYorkSession()?" NEW_YORK":"");
   Print("Direction : ",dealType==DEAL_TYPE_BUY?"BUY":"SELL");
   Print("Deal      : ",trans.deal);
   Print("==================================================");

   if(HandleTriggeredDeal(trans.deal))
   {
      // Rebuild only after the old pending wall and old position
      // have been normalized.
      RebuildWallAroundPosition();
   }
   else
   {
      Print("IronWall V1.21: trigger handling failed. Repair pending.");
   }

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

   if(InpLotSize<=0.0)
   {
      Print("IronWall V1.21: invalid lot size.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpDistancePrice<=0.0)
   {
      Print("IronWall V1.21: invalid distance.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseLondonSession &&
      (InpLondonStartHour<0 || InpLondonStartHour>23 ||
       InpLondonEndHour<0 || InpLondonEndHour>23))
   {
      Print("IronWall V1.21: invalid London session hours.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseNewYorkSession &&
      (InpNewYorkStartHour<0 || InpNewYorkStartHour>23 ||
       InpNewYorkEndHour<0 || InpNewYorkEndHour>23))
   {
      Print("IronWall V1.21: invalid New York session hours.");
      return INIT_PARAMETERS_INCORRECT;
   }

   Print("==================================================");
   Print("IronWall V1.21 started");
   Print("Symbol   : ",_Symbol);
   Print("Lot      : ",InpLotSize);
   Print("Distance : ",InpDistancePrice);
   Print("Magic    : ",InpMagicNumber);
   Print("Mode     : MOMENTUM MOVING WALL");
   Print("Session  : LONDON + NEW YORK ONLY");
   Print("London   : ",InpLondonStartHour,":00 - ",InpLondonEndHour,":00 server");
   Print("New York : ",InpNewYorkStartHour,":00 - ",InpNewYorkEndHour,":00 server");
   Print("Asia     : OFF");
   Print("Core     : V1.10 UNCHANGED");
   Print("==================================================");

   RepairEngine();

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   // Remove pending orders when the EA is removed/stopped so they cannot
   // remain unmanaged after the strategy is no longer running.
   DeleteAllPending();
   Print("IronWall V1.21 stopped. reason=",reason);
}

void OnTick()
{
   // The only addition to V1.10 is the London/New York session gate
   // inside RepairEngine(). No indicator or trading logic is added.
   RepairEngine();
}
//+------------------------------------------------------------------+
