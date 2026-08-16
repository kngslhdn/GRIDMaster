//+------------------------------------------------------------------+
//|                 IronWall_V1.22_TIER_A_SESSION.mq5                |
//|        IronWall V1 engine + Tier-A trading session control       |
//+------------------------------------------------------------------+
#property strict
#property version   "1.22"
#property description "IronWall V1.22 - original engine with Tier-A session control"

#include <Trade/Trade.mqh>
CTrade trade;

//====================================================================
// ORIGINAL IRONWALL CORE INPUTS
//====================================================================
input group "=== IRONWALL V1 CORE ==="
input double InpLotSize         = 0.05;
input double InpDistancePrice   = 10.0;
input ulong  InpMagicNumber     = 26081601;
input int    InpDeviationPoints = 30;

//====================================================================
// TIER-A SESSION CONTROL
// Server/broker time. End hour is exclusive.
// Outside all active windows: close positions + delete pending.
//====================================================================
input group "=== TIER-A SESSION CONTROL ==="
input bool InpUseTierASessions = true;

// 00:00 - 01:00
input bool InpSession_00_01 = true;

// 04:00 - 06:00
input bool InpSession_04_06 = true;

// 10:00 - 12:00
input bool InpSession_10_12 = true;

// 13:00 - 16:00
input bool InpSession_13_16 = true;

//====================================================================
// GLOBAL STATE
//====================================================================
bool g_busy=false;
bool g_wasTradingSession=false;

//====================================================================
// SESSION ENGINE
//====================================================================
bool IsTierATradingTime()
{
   if(!InpUseTierASessions)
      return true;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(),tm);
   int hour=tm.hour;

   if(InpSession_00_01 && hour>=0 && hour<1)
      return true;

   if(InpSession_04_06 && hour>=4 && hour<6)
      return true;

   if(InpSession_10_12 && hour>=10 && hour<12)
      return true;

   if(InpSession_13_16 && hour>=13 && hour<16)
      return true;

   return false;
}

//====================================================================
// ORDER / POSITION HELPERS
//====================================================================
bool IsOurOrder(ulong ticket)
{
   if(ticket==0 || !OrderSelect(ticket))
      return false;

   return OrderGetString(ORDER_SYMBOL)==_Symbol &&
          (ulong)OrderGetInteger(ORDER_MAGIC)==InpMagicNumber;
}

bool IsOurPosition(ulong ticket)
{
   if(ticket==0 || !PositionSelectByTicket(ticket))
      return false;

   return PositionGetString(POSITION_SYMBOL)==_Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber;
}

int CountOurPositions()
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(IsOurPosition(ticket))
         count++;
   }
   return count;
}

void DeleteOurPendingOrders()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(!IsOurOrder(ticket))
         continue;

      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type!=ORDER_TYPE_BUY_STOP && type!=ORDER_TYPE_SELL_STOP)
         continue;

      if(!trade.OrderDelete(ticket))
      {
         Print("IronWall V1.22: pending delete failed #",ticket,
               " ",trade.ResultRetcodeDescription());
      }
   }
}

void CloseOurPositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOurPosition(ticket))
         continue;

      if(!trade.PositionClose(ticket))
      {
         Print("IronWall V1.22: position close failed #",ticket,
               " ",trade.ResultRetcodeDescription());
      }
   }
}

//====================================================================
// ORIGINAL IRONWALL ORDER ENGINE
//====================================================================
void PlaceIronWall()
{
   if(g_busy || !IsTierATradingTime())
      return;

   if(CountOurPositions()>0)
      return;

   // Do not duplicate a complete wall.
   int pending=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(!IsOurOrder(ticket))
         continue;

      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_SELL_STOP)
         pending++;
   }

   if(pending>=2)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
      return;

   double buyPrice=NormalizeDouble(tick.ask+InpDistancePrice,_Digits);
   double sellPrice=NormalizeDouble(tick.bid-InpDistancePrice,_Digits);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool buyOK=trade.BuyStop(InpLotSize,buyPrice,_Symbol,0,0,
                            ORDER_TIME_GTC,0,"IronWall BUY STOP");
   if(!buyOK)
      Print("IronWall V1.22: BUY STOP failed ",trade.ResultRetcodeDescription());

   bool sellOK=trade.SellStop(InpLotSize,sellPrice,_Symbol,0,0,
                              ORDER_TIME_GTC,0,"IronWall SELL STOP");
   if(!sellOK)
      Print("IronWall V1.22: SELL STOP failed ",trade.ResultRetcodeDescription());
}

//====================================================================
// ORIGINAL TRIGGER / REBUILD ENGINE
//====================================================================
void ManageTriggeredPosition()
{
   if(g_busy || !IsTierATradingTime())
      return;

   if(CountOurPositions()<=0)
      return;

   // Opposite pending is removed once a side is active.
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(!IsOurOrder(ticket))
         continue;

      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_SELL_STOP)
         trade.OrderDelete(ticket);
   }
}

//====================================================================
// SESSION TRANSITION
//====================================================================
void ManageSession()
{
   bool active=IsTierATradingTime();

   // ACTIVE -> OUTSIDE: one-time cleanup.
   if(g_wasTradingSession && !active)
   {
      Print("IronWall V1.22: Tier-A session ended. Closing positions and deleting pending orders.");
      CloseOurPositions();
      DeleteOurPendingOrders();
   }

   // OUTSIDE -> ACTIVE: normal engine resumes.
   if(!g_wasTradingSession && active)
      Print("IronWall V1.22: Tier-A session started. IronWall engine ON.");

   // Outside session, continuously enforce a clean state in case a
   // broker event or restart leaves an order/position behind.
   if(!active)
   {
      DeleteOurPendingOrders();
      CloseOurPositions();
   }

   g_wasTradingSession=active;
}

//====================================================================
// LIFECYCLE
//====================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_wasTradingSession=IsTierATradingTime();

   Print("==================================================");
   Print("IronWall V1.22 TIER-A SESSION STARTED");
   Print("Symbol       : ",_Symbol);
   Print("Lot          : ",InpLotSize);
   Print("Distance     : ",InpDistancePrice);
   Print("Magic        : ",InpMagicNumber);
   Print("Sessions      : 00-01 | 04-06 | 10-12 | 13-16");
   Print("Server Time  : ",TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS));
   Print("==================================================");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   // Do not modify market state during EA removal.
   Print("IronWall V1.22 stopped. reason=",reason);
}

void OnTick()
{
   ManageSession();

   if(!IsTierATradingTime())
      return;

   ManageTriggeredPosition();

   if(CountOurPositions()==0)
      PlaceIronWall();
}
//+------------------------------------------------------------------+
