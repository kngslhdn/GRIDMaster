#property strict

#include <Trade/Trade.mqh>

CTrade trade;

//==================================================
// INPUTS
//==================================================

input double Lots = 0.01;

input int ATRPeriod = 14;

input double EntryATRMultiplier = 0.5;

input int MaxSpread = 300;

input ulong MagicNumber = 20260616;

input double SL_ATR_Multiplier = 0.8;

input double BE_ATR_Multiplier = 0.5;

input double TrailStartATR = 0.1;

input double TrailATR = 0.5;

input double MinATR = 1.0;

input double TP_ATR_Multiplier = 1.2;

input int CooldownMinutes = 30;

//==================================================
// GLOBALS
//==================================================

int ATRHandle;
datetime LastPendingTime = 0;
datetime LastCloseTime = 0;
int EMA50Handle;
int EMA200Handle;
int LastHistoryDeals = 0;

//==================================================
// ONINIT
//==================================================

int OnInit()
{
   ATRHandle = iATR(_Symbol, PERIOD_M15, ATRPeriod);

   if(ATRHandle == INVALID_HANDLE)
      return INIT_FAILED;

   trade.SetExpertMagicNumber(MagicNumber);

   EMA50Handle = iMA(_Symbol, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);

   EMA200Handle = iMA(_Symbol, PERIOD_M15, 200, 0, MODE_EMA, PRICE_CLOSE);

   if(EMA50Handle == INVALID_HANDLE || EMA200Handle == INVALID_HANDLE)
      return INIT_FAILED;

   LastHistoryDeals = HistoryDealsTotal();

   return INIT_SUCCEEDED;
}

//==================================================
// ONDEINIT
//==================================================

void OnDeinit(const int reason)
{
   if(ATRHandle != INVALID_HANDLE)
      IndicatorRelease(ATRHandle);

   if(EMA50Handle != INVALID_HANDLE)
      IndicatorRelease(EMA50Handle);

   if(EMA200Handle != INVALID_HANDLE)
      IndicatorRelease(EMA200Handle);
}

//==================================================
// ONTICK
//==================================================

void OnTick()
{
   // Detect posisi yang baru saja tutup
   DetectPositionClosed();

   // Hapus pending lawan jika posisi sudah aktif
   CheckTriggeredPosition();

   // Position management tetap berjalan walaupun spread sedang tinggi
   ApplyBreakEven();
   ApplyTrailing();

   // Entry baru
   if(!SpreadAllowed())
      return;

   if(GetATR() <= 0)
      return;

   // Entry baru hanya jika:
   // - tidak ada posisi
   // - tidak ada pending
   // - cooldown selesai
   if(NoPositionAndNoPending() && CooldownFinished())
   {
      PlacePendingOrders();
   }
}

//==================================================
// SPREAD FILTER
//==================================================

bool SpreadAllowed()
{
   double spread =
      (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
       SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;

   return(spread <= MaxSpread);
}

//==================================================
// ATR
//==================================================

double GetATR()
{
   double buffer[];
   ArraySetAsSeries(buffer, true);

   if(CopyBuffer(ATRHandle, 0, 0, 1, buffer) <= 0)
      return 0;

   return buffer[0];
}

//==================================================
// CHECK POSITION
//==================================================

bool HasPosition()
{
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);

      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            return true;
         }
      }
   }

   return false;
}

//==================================================
// CHECK PENDING
//==================================================

bool HasPending()
{
   for(int i=0; i<OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);

      if(OrderSelect(ticket))
      {
         if(OrderGetInteger(ORDER_MAGIC) == (long)MagicNumber &&
            OrderGetString(ORDER_SYMBOL) == _Symbol)
         {
            return true;
         }
      }
   }

   return false;
}

//==================================================
// NO POSITION + NO PENDING
//==================================================

bool NoPositionAndNoPending()
{
   return(!HasPosition() && !HasPending());
}

//==================================================
// PLACE PENDING
//==================================================

void PlacePendingOrders()
{
   double atr = GetATR();

   if(atr <= 0)
      return;

   if(atr < MinATR)
      return;

   double distance = atr * EntryATRMultiplier;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double stopLevel =
      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   double buyPrice = NormalizeDouble(ask + distance, _Digits);
   double sellPrice = NormalizeDouble(bid - distance, _Digits);

   //=====================
   // BUY
   //=====================

   double buySL = NormalizeDouble(
      buyPrice - (atr * SL_ATR_Multiplier),
      _Digits
   );

   double buyTP = NormalizeDouble(
      buyPrice + (atr * TP_ATR_Multiplier),
      _Digits
   );

   //=====================
   // SELL
   //=====================

   double sellSL = NormalizeDouble(
      sellPrice + (atr * SL_ATR_Multiplier),
      _Digits
   );

   double sellTP = NormalizeDouble(
      sellPrice - (atr * TP_ATR_Multiplier),
      _Digits
   );

   bool buyResult = false;
   bool sellResult = false;

   //=====================
   // BUY TREND
   //=====================

   if(TrendBuy())
   {
      if(buyPrice - ask >= stopLevel)
      {
         buyResult = trade.BuyStop(
            Lots,
            buyPrice,
            _Symbol,
            buySL,
            buyTP
         );
      }
   }

   //=====================
   // SELL TREND
   //=====================

   if(TrendSell())
   {
      if(bid - sellPrice >= stopLevel)
      {
         sellResult = trade.SellStop(
            Lots,
            sellPrice,
            _Symbol,
            sellSL,
            sellTP
         );
      }
   }

   //=====================
   // LOG
   //=====================

   if(buyResult || sellResult)
   {
      LastPendingTime = TimeCurrent();

      Print("Pending Created");
   }
   else
   {
      Print(
         "No Pending Created. TrendBuy=",
         TrendBuy(),
         " TrendSell=",
         TrendSell(),
         " ATR=",
         atr,
         " StopLevel=",
         stopLevel
      );
   }
}

//==================================================
// DELETE OPPOSITE
//==================================================

void DeleteAllPending()
{
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      if(OrderSelect(ticket))
      {
         if(OrderGetInteger(ORDER_MAGIC) == (long)MagicNumber &&
            OrderGetString(ORDER_SYMBOL) == _Symbol)
         {
            trade.OrderDelete(ticket);
         }
      }
   }
}

//==================================================
// CHECK TRIGGER
//==================================================

void CheckTriggeredPosition()
{
   if(!HasPosition())
      return;

   DeleteAllPending();
}

//==================================================
// BREAK EVEN ENGINE
//==================================================

void ApplyBreakEven()
{
   double atr = GetATR();

   if(atr <= 0)
      return;

   double stopLevel =
      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber ||
         PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      string symbol = PositionGetString(POSITION_SYMBOL);

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      //=========================
      // BUY
      //=========================

      if(type == POSITION_TYPE_BUY)
      {
         double profitDistance = bid - open;

         if(profitDistance < atr * BE_ATR_Multiplier)
            continue;

         if((bid - open) <= stopLevel)
            continue;

         if(sl < open - _Point)
         {
            trade.PositionModify(symbol, open, tp);
         }
      }

      //=========================
      // SELL
      //=========================

      if(type == POSITION_TYPE_SELL)
      {
         double profitDistance = open - ask;

         if(profitDistance < atr * BE_ATR_Multiplier)
            continue;

         if((open - ask) <= stopLevel)
            continue;

         // SELL BE harus tetap valid
         double beSL = ask + stopLevel + (_Point * 5);

         if(sl == 0 || sl > beSL)
         {
            trade.PositionModify(symbol, beSL, tp);
         }
      }
   }
}

//==================================================
// TRAILING ENGINE
//==================================================

void ApplyTrailing()
{
   double atr = GetATR();

   if(atr <= 0)
      return;

   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber ||
         PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double profitDistance =
         (type == POSITION_TYPE_BUY) ? bid - open : open - ask;

      if(profitDistance < atr * TrailStartATR)
         continue;

      double newSL;

      if(type == POSITION_TYPE_BUY)
      {
         newSL = bid - (atr * TrailATR);

         if(sl == 0 || newSL > sl)
         {
            string symbol = PositionGetString(POSITION_SYMBOL);
            double tp = PositionGetDouble(POSITION_TP);

            trade.PositionModify(symbol, newSL, tp);
         }
      }
      else
      {
         newSL = ask + (atr * TrailATR);

         if(sl == 0 || newSL < sl)
         {
            string symbol = PositionGetString(POSITION_SYMBOL);
            double tp = PositionGetDouble(POSITION_TP);

            trade.PositionModify(symbol, newSL, tp);
         }
      }
   }
}

//==================================================
// DETECT POSITION
//==================================================

void DetectPositionClosed()
{
   if(!HistorySelect(0, TimeCurrent()))
      return;

   int deals = HistoryDealsTotal();

   if(deals > LastHistoryDeals)
   {
      for(int i=LastHistoryDeals; i<deals; i++)
      {
         ulong dealTicket = HistoryDealGetTicket(i);

         if(dealTicket == 0)
            continue;

         if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != (long)MagicNumber)
            continue;

         if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
            continue;

         ENUM_DEAL_ENTRY entry =
            (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         {
            LastCloseTime = TimeCurrent();

            Print("Cooldown Start");
         }
      }

      LastHistoryDeals = deals;
   }
}

//==================================================
// COOLDOWN
//==================================================

bool CooldownFinished()
{
   return(TimeCurrent() > LastCloseTime + (CooldownMinutes * 60));
}

//==================================================
// TREND BUY
//==================================================

bool TrendBuy()
{
   double ema50[];
   double ema200[];

   ArraySetAsSeries(ema50, true);
   ArraySetAsSeries(ema200, true);

   if(CopyBuffer(EMA50Handle, 0, 0, 1, ema50) <= 0)
      return false;

   if(CopyBuffer(EMA200Handle, 0, 0, 1, ema200) <= 0)
      return false;

   return(ema50[0] > ema200[0]);
}

//==================================================
// TREND SELL
//==================================================

bool TrendSell()
{
   double ema50[];
   double ema200[];

   ArraySetAsSeries(ema50, true);
   ArraySetAsSeries(ema200, true);

   if(CopyBuffer(EMA50Handle, 0, 0, 1, ema50) <= 0)
      return false;

   if(CopyBuffer(EMA200Handle, 0, 0, 1, ema200) <= 0)
      return false;

   return(ema50[0] < ema200[0]);
}
