//+------------------------------------------------------------------+
//|                                  IronWall_V1.20_NY_LONDON.mq5     |
//|                 IronWall V1.20 - London + New York Session       |
//|                 Session-only build of the V1.10 engine            |
//+------------------------------------------------------------------+
#property strict
#property version   "1.20"
#property description "IronWall V1.20 - original V1.10 momentum wall, London/New York session gate only"

#include <Trade/Trade.mqh>

CTrade trade;

//====================================================================
// INPUTS
//====================================================================
input group "=== IRONWALL V1.20 ==="
input double InpLotSize         = 0.01;
input double InpDistancePrice   = 10.0;
input ulong  InpMagicNumber     = 26081601;
input int    InpDeviationPoints = 30;

input group "=== LONDON / NEW YORK SESSION ==="
// Hours are broker/server time. Use the Strategy Tester broker clock.
// London session: 08:00 - 16:00 server time
// New York session: 13:00 - 21:00 server time
input bool   InpUseLondonSession       = true;
input int    InpLondonStartHour        = 8;
input int    InpLondonEndHour          = 16;
input bool   InpUseNewYorkSession      = true;
input int    InpNewYorkStartHour       = 13;
input int    InpNewYorkEndHour         = 21;
input bool   InpClosePositionsOutside  = false;

//====================================================================
// GLOBALS
//====================================================================
bool g_busy = false;

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

double EffectiveDistance()
{
   return MathMax(InpDistancePrice, MinStopDistance());
}

bool IsHedgingAccount()
{
   const ENUM_ACCOUNT_MARGIN_MODE mode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   return(mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

bool IsOurOrder(const ulong ticket)
{
   if(ticket == 0 || !OrderSelect(ticket))
      return false;

   if(OrderGetString(ORDER_SYMBOL) != _Symbol)
      return false;

   return((ulong)OrderGetInteger(ORDER_MAGIC) == InpMagicNumber);
}

bool IsOurPosition(const ulong ticket)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return false;

   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;

   return((ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber);
}

bool IsWithinSession(const int hour, const int startHour, const int endHour)
{
   if(startHour == endHour)
      return true;

   if(startHour < endHour)
      return(hour >= startHour && hour < endHour);

   return(hour >= startHour || hour < endHour);
}

bool IsLondonOrNewYorkSession()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);

   const bool london = InpUseLondonSession &&
                       IsWithinSession(tm.hour, InpLondonStartHour, InpLondonEndHour);

   const bool newYork = InpUseNewYorkSession &&
                        IsWithinSession(tm.hour, InpNewYorkStartHour, InpNewYorkEndHour);

   return(london || newYork);
}

//====================================================================
// POSITION ENGINE
//====================================================================
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

bool GetOurPosition(ulong &ticket,
                    ENUM_POSITION_TYPE &type,
                    double &openPrice)
{
   ticket    = 0;
   openPrice = 0.0;
   type      = POSITION_TYPE_BUY;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong positionTicket = PositionGetTicket(i);

      if(!IsOurPosition(positionTicket))
         continue;

      ticket    = positionTicket;
      type      = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      return true;
   }

   return false;
}

//====================================================================
// PENDING ENGINE
//====================================================================
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

      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
         count++;
   }

   return count;
}

void DeleteAllPending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);

      if(!IsOurOrder(ticket))
         continue;

      const ENUM_ORDER_TYPE type =
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
         continue;

      if(!trade.OrderDelete(ticket))
      {
         Print("IronWall V1.20: delete pending failed #", ticket,
               " retcode=", trade.ResultRetcode(),
               " ", trade.ResultRetcodeDescription());
      }
   }
}

bool PlaceBuyStop(const double requestedPrice)
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   const double distance = EffectiveDistance();

   double price = MathMax(requestedPrice, tick.ask + distance);
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
      "IronWall V1.20 BUY STOP"
   );

   if(!ok)
   {
      Print("IronWall V1.20: BUY STOP failed price=", price,
            " retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
   }

   return ok;
}

bool PlaceSellStop(const double requestedPrice)
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   const double distance = EffectiveDistance();

   double price = MathMin(requestedPrice, tick.bid - distance);
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
      "IronWall V1.20 SELL STOP"
   );

   if(!ok)
   {
      Print("IronWall V1.20: SELL STOP failed price=", price,
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

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   const double distance = EffectiveDistance();

   const double buyPrice  = NormalizePrice(tick.ask + distance);
   const double sellPrice = NormalizePrice(tick.bid - distance);

   DeleteAllPending();

   const bool buyOK  = PlaceBuyStop(buyPrice);
   const bool sellOK = PlaceSellStop(sellPrice);

   Print("IronWall V1.20: INITIAL WALL | BUY STOP=", buyPrice,
         " | SELL STOP=", sellPrice,
         " | BUY=", buyOK,
         " | SELL=", sellOK);
}

//====================================================================
// WALL AROUND ACTIVE POSITION
//====================================================================
void RebuildWallAroundPosition()
{
   if(g_busy)
      return;

   ulong ticket;
   ENUM_POSITION_TYPE type;
   double openPrice;

   if(!GetOurPosition(ticket, type, openPrice))
      return;

   const double distance = EffectiveDistance();

   const double upperPrice = NormalizePrice(openPrice + distance);
   const double lowerPrice = NormalizePrice(openPrice - distance);

   DeleteAllPending();

   PlaceBuyStop(upperPrice);
   PlaceSellStop(lowerPrice);

   Print("IronWall V1.20: WALL | direction=",
         type == POSITION_TYPE_BUY ? "BUY" : "SELL",
         " | OPEN=", openPrice,
         " | BUY STOP=", upperPrice,
         " | SELL STOP=", lowerPrice);
}

//====================================================================
// POSITION CLOSE ENGINE
//====================================================================
bool ClosePositionTicket(const ulong ticket)
{
   if(!IsOurPosition(ticket))
      return true;

   if(!trade.PositionClose(ticket))
   {
      Print("IronWall V1.20: close position failed #", ticket,
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
         const ulong ticket = PositionGetTicket(i);

         if(!IsOurPosition(ticket) || ticket == keepTicket)
            continue;

         found = true;

         if(!ClosePositionTicket(ticket))
            success = false;
      }

      if(!found)
         break;
   }

   return success;
}

bool CloseAllOurPositions()
{
   bool success = true;

   for(int pass = 0; pass < 3; pass++)
   {
      bool found = false;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         const ulong ticket = PositionGetTicket(i);

         if(!IsOurPosition(ticket))
            continue;

         found = true;

         if(!ClosePositionTicket(ticket))
            success = false;
      }

      if(!found)
         break;
   }

   return success && OurPositionCount() == 0;
}

bool OpenMarketDirection(const ENUM_DEAL_TYPE direction)
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool ok = false;

   if(direction == DEAL_TYPE_BUY)
      ok = trade.Buy(InpLotSize, _Symbol, 0.0, 0.0, 0.0, "IronWall V1.20 BUY");
   else if(direction == DEAL_TYPE_SELL)
      ok = trade.Sell(InpLotSize, _Symbol, 0.0, 0.0, 0.0, "IronWall V1.20 SELL");

   if(!ok)
   {
      Print("IronWall V1.20: market reopen failed direction=",
            direction == DEAL_TYPE_BUY ? "BUY" : "SELL",
            " retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
   }

   return ok;
}

//====================================================================
// TRIGGER HANDLER
//====================================================================
bool HandleTriggeredDeal(const ulong dealTicket)
{
   if(!HistoryDealSelect(dealTicket))
      return false;

   const ENUM_DEAL_TYPE direction =
      (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);

   if(direction != DEAL_TYPE_BUY && direction != DEAL_TYPE_SELL)
      return false;

   const ulong triggeredPositionTicket =
      (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);

   DeleteAllPending();

   if(IsHedgingAccount())
   {
      if(!CloseAllExcept(triggeredPositionTicket))
         return false;

      if(!IsOurPosition(triggeredPositionTicket))
      {
         Print("IronWall V1.20: triggered position disappeared #",
               triggeredPositionTicket);
         return false;
      }

      return true;
   }

   if(!CloseAllOurPositions())
      return false;

   if(!OpenMarketDirection(direction))
      return false;

   return true;
}

//====================================================================
// SESSION ENGINE
//====================================================================
void EnforceSessionState()
{
   if(IsLondonOrNewYorkSession())
      return;

   // Asia / outside-session: remove the wall so no new orders can fire.
   DeleteAllPending();

   // Default behavior preserves the active position. This is the only
   // session change: no SL/TP or other engine logic is altered.
   if(InpClosePositionsOutside && OurPositionCount() > 0)
      CloseAllOurPositions();
}

//====================================================================
// EMERGENCY REPAIR
//====================================================================
void RepairEngine()
{
   if(g_busy)
      return;

   EnforceSessionState();

   if(!IsLondonOrNewYorkSession())
      return;

   const int positions = OurPositionCount();
   const int pending    = OurPendingCount();

   if(positions == 0)
   {
      if(pending != 2)
         CreateInitialWall();

      return;
   }

   if(positions > 1)
   {
      ulong keepTicket;
      ENUM_POSITION_TYPE keepType;
      double keepOpen;

      if(GetOurPosition(keepTicket, keepType, keepOpen))
      {
         for(int i = PositionsTotal() - 1; i >= 0; i--)
         {
            const ulong ticket = PositionGetTicket(i);

            if(!IsOurPosition(ticket) || ticket == keepTicket)
               continue;

            ClosePositionTicket(ticket);
         }
      }
   }

   if(OurPendingCount() != 2)
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

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(trans.deal == 0)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;

   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber)
      return;

   const ENUM_DEAL_ENTRY entry =
      (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

   if(entry != DEAL_ENTRY_IN)
      return;

   const ENUM_DEAL_TYPE dealType =
      (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);

   if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL)
      return;

   // A pending order must never be allowed to trigger while the session
   // gate is closed. The transaction is still handled normally if it
   // happened at the exact session boundary.
   g_busy = true;

   Print("==================================================");
   Print("IronWall V1.20: MOMENTUM TRIGGER");
   Print("Direction : ", dealType == DEAL_TYPE_BUY ? "BUY" : "SELL");
   Print("Deal      : ", trans.deal);
   Print("==================================================");

   if(HandleTriggeredDeal(trans.deal))
      RebuildWallAroundPosition();
   else
      Print("IronWall V1.20: trigger handling failed. Repair pending.");

   g_busy = false;

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

   if(InpLotSize <= 0.0)
   {
      Print("IronWall V1.20: invalid lot size.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpDistancePrice <= 0.0)
   {
      Print("IronWall V1.20: invalid distance.");
      return INIT_PARAMETERS_INCORRECT;
   }

   Print("==================================================");
   Print("IronWall V1.20 started");
   Print("Symbol       : ", _Symbol);
   Print("Lot          : ", InpLotSize);
   Print("Distance     : ", InpDistancePrice);
   Print("Magic        : ", InpMagicNumber);
   Print("London       : ", InpUseLondonSession ? "ON" : "OFF",
         " ", InpLondonStartHour, "-", InpLondonEndHour);
   Print("New York     : ", InpUseNewYorkSession ? "ON" : "OFF",
         " ", InpNewYorkStartHour, "-", InpNewYorkEndHour);
   Print("Outside      : PENDING ORDERS OFF");
   Print("Core Engine  : UNCHANGED V1.10");
   Print("==================================================");

   RepairEngine();

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("IronWall V1.20 stopped. reason=", reason);
}

void OnTick()
{
   // Session gate only. No indicator, trend, spread, SL, TP or other
   // strategy change has been introduced in this build.
   RepairEngine();
}
//+------------------------------------------------------------------+
