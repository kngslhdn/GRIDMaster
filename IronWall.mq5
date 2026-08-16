//+------------------------------------------------------------------+
//|                                                   IronWall.mq5   |
//|                  IronWall V1 - Dual Pending Engine               |
//|                         Version 1.00                              |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "IronWall V1 - simple dual pending / reversal engine"

#include <Trade/Trade.mqh>

CTrade trade;

//====================================================================
// INPUTS
//====================================================================
input group "=== IRONWALL V1 ==="
input double InpLotSize         = 0.01;
input double InpDistancePrice   = 5.0;
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
   double distance = MathMax(InpDistancePrice, 0.0);
   const double minimum = MinStopDistance();

   if(distance < minimum)
      distance = minimum;

   return distance;
}

bool IsOurOrder(const ulong ticket)
{
   if(ticket == 0 || !OrderSelect(ticket))
      return false;

   if(OrderGetString(ORDER_SYMBOL) != _Symbol)
      return false;

   return (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagicNumber;
}

bool IsOurPosition(const ulong ticket)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return false;

   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;

   return (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber;
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
                    double &openPrice,
                    double &volume)
{
   ticket    = 0;
   openPrice = 0.0;
   volume    = 0.0;
   type      = POSITION_TYPE_BUY;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong positionTicket = PositionGetTicket(i);

      if(!IsOurPosition(positionTicket))
         continue;

      ticket    = positionTicket;
      type      = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      volume    = PositionGetDouble(POSITION_VOLUME);
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
         Print("IronWall: failed to delete pending #", ticket,
               " retcode=", trade.ResultRetcode(),
               " ", trade.ResultRetcodeDescription());
      }
   }
}

bool PlaceBuyStop(const double price)
{
   const double distance = EffectiveDistance();

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double buyPrice = price;
   const double minimumPrice = tick.ask + distance;

   if(buyPrice < minimumPrice)
      buyPrice = minimumPrice;

   buyPrice = NormalizePrice(buyPrice);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   const bool ok = trade.BuyStop(
      InpLotSize,
      buyPrice,
      _Symbol,
      0.0,
      0.0,
      ORDER_TIME_GTC,
      0,
      "IronWall BUY STOP"
   );

   if(!ok)
   {
      Print("IronWall: BUY STOP failed. price=", buyPrice,
            " retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
   }

   return ok;
}

bool PlaceSellStop(const double price)
{
   const double distance = EffectiveDistance();

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double sellPrice = price;
   const double minimumPrice = tick.bid - distance;

   if(sellPrice > minimumPrice)
      sellPrice = minimumPrice;

   sellPrice = NormalizePrice(sellPrice);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   const bool ok = trade.SellStop(
      InpLotSize,
      sellPrice,
      _Symbol,
      0.0,
      0.0,
      ORDER_TIME_GTC,
      0,
      "IronWall SELL STOP"
   );

   if(!ok)
   {
      Print("IronWall: SELL STOP failed. price=", sellPrice,
            " retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
   }

   return ok;
}

//====================================================================
// POSITION PROTECTION
//====================================================================
// BUY position:
//   upper BUY STOP  = profit boundary / next BUY cycle
//   lower SELL STOP  = loss boundary / reversal
//
// SELL position:
//   upper BUY STOP   = loss boundary / reversal
//   lower SELL STOP  = profit boundary / next SELL cycle
bool SetPositionBoundaries(const double upperPrice,
                           const double lowerPrice)
{
   ulong ticket;
   ENUM_POSITION_TYPE type;
   double openPrice;
   double volume;

   if(!GetOurPosition(ticket, type, openPrice, volume))
      return false;

   double sl = 0.0;
   double tp = 0.0;

   if(type == POSITION_TYPE_BUY)
   {
      sl = NormalizePrice(lowerPrice);
      tp = NormalizePrice(upperPrice);
   }
   else
   {
      sl = NormalizePrice(upperPrice);
      tp = NormalizePrice(lowerPrice);
   }

   trade.SetExpertMagicNumber(InpMagicNumber);

   const bool ok = trade.PositionModify(ticket, sl, tp);

   if(!ok)
   {
      Print("IronWall: PositionModify failed. ticket=", ticket,
            " SL=", sl,
            " TP=", tp,
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

   const double distance = EffectiveDistance();

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

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
// REBUILD WALL AROUND NEW POSITION
//====================================================================
void RebuildWallAroundPosition()
{
   if(g_busy)
      return;

   ulong ticket;
   ENUM_POSITION_TYPE type;
   double openPrice;
   double volume;

   if(!GetOurPosition(ticket, type, openPrice, volume))
      return;

   const double distance = EffectiveDistance();
   const double upperPrice = NormalizePrice(openPrice + distance);
   const double lowerPrice = NormalizePrice(openPrice - distance);

   DeleteAllPending();

   // Set position boundaries first, then place matching pending orders.
   SetPositionBoundaries(upperPrice, lowerPrice);

   PlaceBuyStop(upperPrice);
   PlaceSellStop(lowerPrice);

   Print("IronWall: WALL REBUILT | OPEN=", openPrice,
         " | BUY STOP=", upperPrice,
         " | SELL STOP=", lowerPrice);
}

//====================================================================
// POSITION RESET
//====================================================================
bool CloseAllOurPositions()
{
   bool allClosed = true;

   for(int pass = 0; pass < 3; pass++)
   {
      bool found = false;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         const ulong ticket = PositionGetTicket(i);

         if(!IsOurPosition(ticket))
            continue;

         found = true;

         if(!trade.PositionClose(ticket))
         {
            Print("IronWall: failed to close position #", ticket,
                  " retcode=", trade.ResultRetcode(),
                  " ", trade.ResultRetcodeDescription());
            allClosed = false;
         }
      }

      if(!found)
         break;
   }

   return allClosed && OurPositionCount() == 0;
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
      Print("IronWall: market reopen failed. direction=",
            direction == DEAL_TYPE_BUY ? "BUY" : "SELL",
            " retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
      return false;
   }

   return true;
}

bool ResetToTriggeredDirection(const ENUM_DEAL_TYPE direction)
{
   // Normalize the cycle to exactly ONE position with InpLotSize.
   // This works consistently on netting and hedging accounts.
   DeleteAllPending();

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

   // No position = exactly two pending orders.
   if(positions == 0)
   {
      if(pending != 2)
         CreateInitialWall();

      return;
   }

   // Position active = exactly two pending orders.
   if(positions == 1 && pending != 2)
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

   // A BUY STOP or SELL STOP has just been triggered.
   g_busy = true;

   Print("IronWall: TRIGGER | ",
         dealType == DEAL_TYPE_BUY ? "BUY" : "SELL",
         " deal=", trans.deal);

   if(ResetToTriggeredDirection(dealType))
   {
      g_busy = false;
      RebuildWallAroundPosition();
      return;
   }

   Print("IronWall: trigger recovery failed. Repair will retry.");

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
   Print("IronWall V1 started");
   Print("Symbol   : ", _Symbol);
   Print("Lot      : ", InpLotSize);
   Print("Distance : ", InpDistancePrice);
   Print("Magic    : ", InpMagicNumber);
   Print("Mode     : DUAL PENDING / REVERSAL ENGINE");
   Print("Filters  : NONE");
   Print("==================================================");

   RepairEngine();

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("IronWall V1 stopped. reason=", reason);
}

void OnTick()
{
   RepairEngine();
}
//+------------------------------------------------------------------+
