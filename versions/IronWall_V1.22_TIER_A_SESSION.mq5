//+------------------------------------------------------------------+
//|              IronWall_V2.1_GOOD_HOURS.mq5                        |
//|     IronWall V1 core + empirically selected trading windows     |
//+------------------------------------------------------------------+
#property strict
#property version   "2.10"
#property description "IronWall V2.1 - only profitable test windows"

#include <Trade/Trade.mqh>
CTrade trade;

//====================================================================
// IRONWALL CORE - UNCHANGED
//====================================================================
input group "=== IRONWALL CORE ==="
input double InpLotSize         = 0.05;
input double InpDistancePrice   = 10.0;
input ulong  InpMagicNumber     = 26081601;
input int    InpDeviationPoints = 30;

//====================================================================
// GOOD-HOURS SESSION CONTROL
// Broker/server time. End hour is exclusive.
// 04:00-06:00 = positive
// 10:00-11:00 = strongest edge
// All other hours = OFF
//====================================================================
input group "=== GOOD HOURS ONLY ==="
input bool InpUseTradingSessions = true;
input bool InpSession_04_06 = true;
input bool InpSession_10_11 = true;

bool g_wasTradingSession=false;

bool IsTradingSession()
{
   if(!InpUseTradingSessions)
      return true;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(),tm);
   int hour=tm.hour;

   if(InpSession_04_06 && hour>=4 && hour<6)
      return true;
   if(InpSession_10_11 && hour>=10 && hour<11)
      return true;

   return false;
}

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
      if(IsOurPosition(ticket)) count++;
   }
   return count;
}

void DeleteOurPendingOrders()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(!IsOurOrder(ticket)) continue;

      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type!=ORDER_TYPE_BUY_STOP && type!=ORDER_TYPE_SELL_STOP) continue;

      if(!trade.OrderDelete(ticket))
         Print("IronWall V2.1: delete pending #",ticket," failed: ",trade.ResultRetcodeDescription());
   }
}

void CloseOurPositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!IsOurPosition(ticket)) continue;

      if(!trade.PositionClose(ticket))
         Print("IronWall V2.1: close position #",ticket," failed: ",trade.ResultRetcodeDescription());
   }
}

void EnforceFlatOutsideSession()
{
   DeleteOurPendingOrders();
   CloseOurPositions();
}

void PlaceIronWall()
{
   if(!IsTradingSession() || CountOurPositions()>0)
      return;

   int pending=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(!IsOurOrder(ticket)) continue;
      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_SELL_STOP) pending++;
   }
   if(pending>=2) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;

   double buyPrice=NormalizeDouble(tick.ask+InpDistancePrice,_Digits);
   double sellPrice=NormalizeDouble(tick.bid-InpDistancePrice,_Digits);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(!trade.BuyStop(InpLotSize,buyPrice,_Symbol,0,0,ORDER_TIME_GTC,0,"IronWall BUY STOP"))
      Print("IronWall V2.1: BUY STOP failed: ",trade.ResultRetcodeDescription());
   if(!trade.SellStop(InpLotSize,sellPrice,_Symbol,0,0,ORDER_TIME_GTC,0,"IronWall SELL STOP"))
      Print("IronWall V2.1: SELL STOP failed: ",trade.ResultRetcodeDescription());
}

void ManageTriggeredPosition()
{
   if(!IsTradingSession() || CountOurPositions()<=0) return;

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(!IsOurOrder(ticket)) continue;
      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_SELL_STOP)
         trade.OrderDelete(ticket);
   }
}

void ManageSession()
{
   bool active=IsTradingSession();

   if(g_wasTradingSession && !active)
   {
      Print("IronWall V2.1: good-hour session ended -> CLOSE ALL + DELETE PENDING");
      EnforceFlatOutsideSession();
   }

   if(!g_wasTradingSession && active)
      Print("IronWall V2.1: good-hour session started -> IRONWALL ON");

   if(!active)
      EnforceFlatOutsideSession();

   g_wasTradingSession=active;
}

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_wasTradingSession=IsTradingSession();

   Print("IronWall V2.1 GOOD HOURS ONLY | ON: 04:00-06:00, 10:00-11:00 | OFF: all other hours");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("IronWall V2.1 stopped. reason=",reason);
}

void OnTick()
{
   ManageSession();
   if(!IsTradingSession()) return;
   ManageTriggeredPosition();
   if(CountOurPositions()==0) PlaceIronWall();
}
//+------------------------------------------------------------------+
