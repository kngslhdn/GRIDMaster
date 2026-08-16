//+------------------------------------------------------------------+
//|                                                   IronWall.mq5   |
//|            IronWall V1 - Momentum Moving Wall Engine             |
//|                         Version 1.10                              |
//+------------------------------------------------------------------+
#property strict
#property version   "1.10"
#property description "IronWall V1 - two-sided momentum wall with one active position"

#include <Trade/Trade.mqh>

CTrade trade;

//====================================================================
// INPUTS
//====================================================================
input group "=== IRONWALL V1 ==="
input double InpLotSize         = 0.01;
input double InpDistancePrice   = 10.0;
input ulong  InpMagicNumber     = 26081601;
input int    InpDeviationPoints = 30;

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
   const int stops = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return stops * PointSize();
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
         Print("IronWall: delete pending failed #", ticket,
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
      "IronWall BUY STOP"
   );

   if(!ok)
   {
      Print("IronWall: BUY STOP failed price=", price,
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
      "IronWall SELL STOP"
   );

   if(!ok)
   {
      Print("IronWall: SELL STOP failed price=", price,
            " retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
   }

   return ok;
}

//====================================================================
// INITIAL WALL
//====================================================================
// No position:
//   BUY STOP  = above market
//   SELL STOP = below market
//
// The first side touched becomes the active position.
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

   Print("IronWall: INITIAL WALL | BUY STOP=", buyPrice,
         " | SELL STOP=", sellPrice,
         " | BUY=", buyOK,
         " | SELL=", sellOK);
}

//====================================================================
// WALL AROUND ACTIVE POSITION
//====================================================================
// The wall is anchored to the ACTIVE POSITION OPEN PRICE.
// It is NOT moved on every tick.
//
// BUY active at 4000:
//   BUY STOP  = 4005  -> continuation / profit step
//   SELL STOP = 3995  -> reversal / loss step
//
// SELL active at 4000:
//   BUY STOP  = 4005  -> reversal / loss step
//   SELL STOP = 3995  -> continuation / profit step
//
// This lets IronWall capture directional momentum without chasing
// the market on every tick.
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

   Print("IronWall: WALL | direction=",
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
      Print("IronWall: close position failed #", ticket,
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
      ok = trade.Buy(InpLotSize, _Symbol, 0.0, 0.0, 0.0, "IronWall BUY");
   else if(direction == DEAL_TYPE_SELL)
      ok = trade.Sell(InpLotSize, _Symbol, 0.0, 0.0, 0.0, "IronWall SELL");

   if(!ok)
   {
      Print("IronWall: market reopen failed direction=",
            direction == DEAL_TYPE_BUY ? "BUY" : "SELL",
            " retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
   }

   return ok;
}

//====================================================================
// TRIGGER HANDLER
//====================================================================
// SAME DIRECTION:
//   BUY active + BUY STOP touched
//   -> close old BUY
//   -> keep newly triggered BUY
//
// OPPOSITE DIRECTION:
//   BUY active + SELL STOP touched
//   -> close old BUY
//   -> keep newly triggered SELL
//
// Then rebuild the wall around the new active position.
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

   //===============================================================
   // HEDGING ACCOUNT
   //===============================================================
   // The triggered pending order has its own position ticket.
   // Keep it and close every older IronWall position.
   if(IsHedgingAccount())
   {
      if(!CloseAllExcept(triggeredPositionTicket))
         return false;

      if(!IsOurPosition(triggeredPositionTicket))
      {
         Print("IronWall: triggered position disappeared #",
               triggeredPositionTicket);
         return false;
      }

      return true;
   }

   //===============================================================
   // NETTING ACCOUNT
   //===============================================================
   // Netting merges the new deal into the existing position, so
   // there is no separate old ticket to keep. Normalize to one fresh
   // market position in the triggered direction.
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

   const int positions = OurPositionCount();
   const int pending    = OurPendingCount();

   if(positions == 0)
   {
      // Flat state must always have exactly two wall orders.
      if(pending != 2)
         CreateInitialWall();

      return;
   }

   // IronWall is designed around exactly one active position.
   // If more than one exists, keep one and close the others.
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

   // Only react to a NEW ENTRY deal.
   // EXIT deals from closing the previous position are ignored.
   if(entry != DEAL_ENTRY_IN)
      return;

   const ENUM_DEAL_TYPE dealType =
      (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);

   if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL)
      return;

   g_busy = true;

   Print("==================================================");
   Print("IronWall: MOMENTUM TRIGGER");
   Print("Direction : ", dealType == DEAL_TYPE_BUY ? "BUY" : "SELL");
   Print("Deal      : ", trans.deal);
   Print("==================================================");

   if(HandleTriggeredDeal(trans.deal))
   {
      // Rebuild only after the old pending wall and old position
      // have been normalized.
      RebuildWallAroundPosition();
   }
   else
   {
      Print("IronWall: trigger handling failed. Repair pending.");
   }

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
      Print("IronWall: invalid lot size.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpDistancePrice <= 0.0)
   {
      Print("IronWall: invalid distance.");
      return INIT_PARAMETERS_INCORRECT;
   }

   Print("==================================================");
   Print("IronWall V1.10 started");
   Print("Symbol   : ", _Symbol);
   Print("Lot      : ", InpLotSize);
   Print("Distance : ", InpDistancePrice);
   Print("Magic    : ", InpMagicNumber);
   Print("Mode     : MOMENTUM MOVING WALL");
   Print("Filters  : NONE");
   Print("==================================================");

   RepairEngine();

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("IronWall V1.10 stopped. reason=", reason);
}

void OnTick()
{
   // No indicator, no trend filter, no spread filter.
   // OnTick only repairs the two-sided wall.
   RepairEngine();
}
//+------------------------------------------------------------------+
