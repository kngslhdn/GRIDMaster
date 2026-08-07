//================================================================================================//
// Expert Advisor: A New Grid V1 - RECOVERY & GROWTH EDITION 2026
// Adaptive Equity Scaling Edition
//================================================================================================//
#property strict
#property copyright "Copyright 2026, Jarvis"
#property version   "6.001"

//--- Enums ---
enum Type {Open_Buy_And_Sell, Open__Only_Buy, Open__Only_Sell};

//========================================================
// RECOVERY STATE
//========================================================
enum RecoveryState
{
   RECOVERY_OFF = 0,
   RECOVERY_MONITOR,
   RECOVERY_ACTIVE,
   RECOVERY_COOLDOWN
};

//--- Input Parameters ---
input string SafeParameters       = "||========== SAFETY & RECOVERY ==========||";
input double MaxEquityLossPercent = 15.0;
input bool   UseTrailingProfit    = true;
input double TrailingStartUSD     = 5.0;
input double TrailingStopUSD      = 2.0;

input string RSI_Settings         = "||========== INDICATORS ==========||";
input int    MAPeriod             = 200;
input int    RSIPeriod            = 14;
input int    RSIUpper             = 70;
input int    RSILower             = 30;

input string Grid_Settings        = "||========== GRID LOGIC ==========||";
input Type   TypeOrdersPlace      = Open_Buy_And_Sell;
input double PointsForFirstGap    = 5000.0;
input double GapMultiplier        = 1.3;
input double TargetProfitUSD      = 5.0;
input double ManualLotSize        = 0.01;
input int    MaxOrders            = 6;
input int    MagicNumber          = 88888;
input string CommentsOrders       = "GRID SAFE 2026";

//========================================================
// RECOVERY EXIT ENGINE
//========================================================
input string Recovery_Settings     = "||========== RECOVERY EXIT ENGINE ==========||";
input bool   UseRecoveryExit       = true;
input double RecoveryStartDD       = 8.0;      // Mulai bekerja
input double SurvivalDD            = 12.0;     // Mode Survival
input double RetraceTriggerPoints  = 500;      // Minimal retrace
input int    RecoveryCooldownSec   = 180;      // 3 menit
input int    RecoveryFreezeSec     = 180;
input double MinRecoveryLossUSD    = 20.0;

//--- Trading Hour ---
input string TradingHourSettings  = "||========== TRADING HOURS ==========||";
input bool   UseTradingHour       = true;
input int    StartHour            = 7;
input int    EndHour              = 22;

//--- Global Variables ---
string SymbolTrade;
int    OrdersID, HandleRSI, HandleMA;
int    BuyOrders, SellOrders;
double BuyProfits, SellProfits;
double PriceOpenLastBuy, PriceOpenLastSell;

bool   IsTerminated = false;
double HighWaterMark = 0;
datetime FreezeGridUntil = 0;

//========================================================
// RECOVERY ENGINE VARIABLES
//========================================================
datetime LastRecoveryAction = 0;

double LowestPriceAfterBuy  = 0;
double HighestPriceAfterSell = 0;

//========================================================
// RECOVERY POSITION STRUCT
//========================================================
struct RecoveryPosition
{
   ulong    Ticket;
   double   Profit;
   double   Volume;
   double   OpenPrice;
   double   Distance;
   double   Score;
};

//========================================================
// ADAPTIVE EQUITY VARIABLES
//========================================================
double InitialBalance     = 0;
double AdaptiveEquityBase = 0;
double LockedProfit       = 0;

//================================================================================================//
bool IsTradingHour()
{
   if(!UseTradingHour)
      return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   int hour = dt.hour;

   if(StartHour < EndHour)
      return (hour >= StartHour && hour < EndHour);
   else
      return (hour >= StartHour || hour < EndHour);
}

//================================================================================================//
int OnInit()
{
   SymbolTrade = _Symbol;

   OrdersID = (MagicNumber == 0)
      ? 101010
      : MagicNumber;

   HandleRSI = iRSI(SymbolTrade, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);

   HandleMA  = iMA(SymbolTrade,
                   PERIOD_CURRENT,
                   MAPeriod,
                   0,
                   MODE_SMA,
                   PRICE_CLOSE);

   HighWaterMark = AccountInfoDouble(ACCOUNT_BALANCE);

   //========================================================
   // ADAPTIVE EQUITY INIT
   //========================================================
   InitialBalance     = AccountInfoDouble(ACCOUNT_BALANCE);
   AdaptiveEquityBase = InitialBalance;
   LockedProfit       = 0;

   if(HandleRSI == INVALID_HANDLE || HandleMA == INVALID_HANDLE)
   {
      Print("Gagal inisialisasi indikator!");
      return(INIT_FAILED);
   }

   return(INIT_SUCCEEDED);
}

//================================================================================================//
void OnDeinit(const int reason)
{
   IndicatorRelease(HandleRSI);
   IndicatorRelease(HandleMA);
   Comment("");
}

//================================================================================================//
void OnTick()
{
   if(IsTerminated
      || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)
      || !IsTradingHour())
      return;

   UpdateStatus();

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   //========================================================
   // ADAPTIVE EQUITY SCALING
   //========================================================

   LockedProfit = balance - InitialBalance;

   if(LockedProfit < 0)
      LockedProfit = 0;

   AdaptiveEquityBase = InitialBalance + LockedProfit;

   //========================================================
   // ORIGINAL RECOVERY ENGINE
   //========================================================

   if(balance > HighWaterMark)
      HighWaterMark = balance;

   bool IsInRecovery = (balance < HighWaterMark);

   //========================================================
   // DRAWDOWN FROM ADAPTIVE EQUITY
   //========================================================

   double currentDrawdown = 0;

   if(equity < AdaptiveEquityBase)
   {
      currentDrawdown =
         ((AdaptiveEquityBase - equity)
         / AdaptiveEquityBase) * 100.0;
   }

   //========================================================
   // EQUITY PROTECTION
   //========================================================

   if(currentDrawdown >= MaxEquityLossPercent)
   {
      PrintFormat("!!! EMERGENCY CUT LOSS: Drawdown %.2f%% !!!",
                  currentDrawdown);

      CloseAllOrders();

      IsTerminated = true;
      return;
   }

   double rsi   = GetRSIValue();
   double ma    = GetMAValue();
   double price = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);

   int lowRSI  = IsInRecovery ? (RSILower - 5) : RSILower;
   int highRSI = IsInRecovery ? (RSIUpper + 5) : RSIUpper;

   bool canOpenBuy  = false;
   bool canOpenSell = false;

   //========================================================
   // FIRST ENTRY (TIDAK DI-FREEZE)
   //========================================================

   if(BuyOrders == 0 &&
      (TypeOrdersPlace == Open_Buy_And_Sell
      || TypeOrdersPlace == Open__Only_Buy))
   {
      if(price > ma && rsi < lowRSI)
         canOpenBuy = true;
   }

   if(SellOrders == 0 &&
      (TypeOrdersPlace == Open_Buy_And_Sell
      || TypeOrdersPlace == Open__Only_Sell))
   {
      if(price < ma && rsi > highRSI)
         canOpenSell = true;
   }

   //========================================================
   // GRID RECOVERY
   // Freeze hanya untuk penambahan layer GRID
   //========================================================

   bool GridFreeze = (TimeCurrent() < FreezeGridUntil);

   if(!GridFreeze)
   {
      //================ BUY GRID =================

      if(BuyOrders > 0 && BuyOrders < MaxOrders)
      {
         double gap =
            PointsForFirstGap *
            MathPow(GapMultiplier, BuyOrders - 1);

         if(SymbolInfoDouble(SymbolTrade, SYMBOL_ASK)
            <= PriceOpenLastBuy - (gap * _Point))
         {
            canOpenBuy = true;
         }
      }

      //================ SELL GRID =================

      if(SellOrders > 0 && SellOrders < MaxOrders)
      {
         double gap =
            PointsForFirstGap *
            MathPow(GapMultiplier, SellOrders - 1);

         if(price >= PriceOpenLastSell + (gap * _Point))
         {
            canOpenSell = true;
         }
      }
   }

   //========================================================
   // EXECUTION
   //========================================================

   if(canOpenBuy)
      ExecuteTrade(ORDER_TYPE_BUY);

   if(canOpenSell)
      ExecuteTrade(ORDER_TYPE_SELL);

   ManageExit(IsInRecovery);

   RecoveryExitEngine(currentDrawdown);

   DisplayDashboard(currentDrawdown, rsi, IsInRecovery);
}
//================================================================================================//
void ManageExit(bool recovery)
{
   double target =
      recovery
      ? (TargetProfitUSD + 2.0)
      : TargetProfitUSD;

   if(BuyOrders > 0)
   {
      if(!UseTrailingProfit)
      {
         if(BuyProfits >= target)
            CloseOrdersByType(POSITION_TYPE_BUY);
      }
      else
      {
         if(BuyProfits >= TrailingStartUSD)
         {
            static double maxBuyProfit = 0;

            if(BuyProfits > maxBuyProfit)
               maxBuyProfit = BuyProfits;

            if(BuyProfits <= maxBuyProfit - TrailingStopUSD)
            {
               CloseOrdersByType(POSITION_TYPE_BUY);
               maxBuyProfit = 0;
            }
         }
      }
   }

   if(SellOrders > 0)
   {
      if(!UseTrailingProfit)
      {
         if(SellProfits >= target)
            CloseOrdersByType(POSITION_TYPE_SELL);
      }
      else
      {
         if(SellProfits >= TrailingStartUSD)
         {
            static double maxSellProfit = 0;

            if(SellProfits > maxSellProfit)
               maxSellProfit = SellProfits;

            if(SellProfits <= maxSellProfit - TrailingStopUSD)
            {
               CloseOrdersByType(POSITION_TYPE_SELL);
               maxSellProfit = 0;
            }
         }
      }
   }
}

//================================================================================================//
void UpdateStatus()
{
   BuyOrders   = 0;
   SellOrders  = 0;
   BuyProfits  = 0;
   SellProfits = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(PositionSelectByTicket(ticket)
         && PositionGetInteger(POSITION_MAGIC) == OrdersID
         && PositionGetString(POSITION_SYMBOL) == SymbolTrade)
      {
         ENUM_POSITION_TYPE type =
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         double p =
            PositionGetDouble(POSITION_PROFIT)
            + PositionGetDouble(POSITION_SWAP);

         if(type == POSITION_TYPE_BUY)
         {
            BuyOrders++;
            BuyProfits += p;
            PriceOpenLastBuy =
               PositionGetDouble(POSITION_PRICE_OPEN);
         }
         else
         {
            SellOrders++;
            SellProfits += p;
            PriceOpenLastSell =
               PositionGetDouble(POSITION_PRICE_OPEN);
         }
      }
   }
}

//================================================================================================//
double GetRSIValue()
{
   double b[];
   ArraySetAsSeries(b, true);

   return (CopyBuffer(HandleRSI, 0, 0, 1, b) > 0)
      ? b[0]
      : 50.0;
}

//================================================================================================//
double GetMAValue()
{
   double b[];
   ArraySetAsSeries(b, true);

   return (CopyBuffer(HandleMA, 0, 0, 1, b) > 0)
      ? b[0]
      : 0;
}

//================================================================================================//
void ExecuteTrade(ENUM_ORDER_TYPE type)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   int c =
      (type == ORDER_TYPE_BUY)
      ? BuyOrders
      : SellOrders;

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = SymbolTrade;
   req.magic        = OrdersID;
   req.volume       = NormalizeDouble(ManualLotSize * (c + 1), 2);
   req.type         = type;
   req.deviation    = 10;
   req.type_filling = ORDER_FILLING_IOC;

   req.price =
      (type == ORDER_TYPE_BUY)
      ? SymbolInfoDouble(SymbolTrade, SYMBOL_ASK)
      : SymbolInfoDouble(SymbolTrade, SYMBOL_BID);

   if(!OrderSend(req, res))
   {
      PrintFormat("Gagal membuka %s. Error: %d",
                  EnumToString(type),
                  GetLastError());
   }
}

//================================================================================================//
void CloseOrdersByType(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);

      if(PositionSelectByTicket(t)
         && PositionGetInteger(POSITION_MAGIC) == OrdersID
         && PositionGetInteger(POSITION_TYPE) == type)
      {
         MqlTradeRequest req = {};
         MqlTradeResult  res = {};

         req.action   = TRADE_ACTION_DEAL;
         req.position = t;
         req.symbol   = SymbolTrade;
         req.volume   = PositionGetDouble(POSITION_VOLUME);

         req.type =
            (type == POSITION_TYPE_BUY)
            ? ORDER_TYPE_SELL
            : ORDER_TYPE_BUY;

         req.price =
            (type == POSITION_TYPE_BUY)
            ? SymbolInfoDouble(SymbolTrade, SYMBOL_BID)
            : SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);

         if(!OrderSend(req, res))
         {
            PrintFormat("Gagal menutup tiket #%I64u. Error: %d",
                        t,
                        GetLastError());
         }
      }
   }
}

//================================================================================================//
void CloseAllOrders()
{
   CloseOrdersByType(POSITION_TYPE_BUY);
   CloseOrdersByType(POSITION_TYPE_SELL);
}

//================================================================================================//
ulong FindBestRecoveryPosition(ENUM_POSITION_TYPE type)
{
   ulong  bestTicket = 0;
   double bestScore  = -DBL_MAX;

   double currentPrice =
      (type == POSITION_TYPE_BUY)
      ? SymbolInfoDouble(SymbolTrade, SYMBOL_BID)
      : SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != OrdersID)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != SymbolTrade)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);

      // Recovery hanya untuk posisi loss
      if(profit >= 0)
         continue;

      double volume    = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      double distance =
         MathAbs(currentPrice - openPrice) / _Point;

      //====================================================
      // Recovery Contribution Score
      //
      // Prioritas:
      // 1. Lot besar
      // 2. Posisi paling jauh dari harga sekarang
      //
      // Loss tidak dipakai karena sudah tercermin
      // pada distance.
      //====================================================

      double score =
         (volume * 1000.0) +
         distance;

      if(score > bestScore)
      {
         bestScore  = score;
         bestTicket = ticket;
      }
   }

   return(bestTicket);
}


//================================================================================================//
bool CloseRecoveryPosition(ulong ticket)
{
   if(ticket == 0)
      return(false);

   if(!PositionSelectByTicket(ticket))
      return(false);

   ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   req.action   = TRADE_ACTION_DEAL;
   req.position = ticket;
   req.symbol   = SymbolTrade;
   req.magic    = OrdersID;
   req.volume   = PositionGetDouble(POSITION_VOLUME);

   if(type == POSITION_TYPE_BUY)
   {
      req.type  = ORDER_TYPE_SELL;
      req.price = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);
   }
   else
   {
      req.type  = ORDER_TYPE_BUY;
      req.price = SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);
   }

   req.deviation    = 10;
   req.type_filling = ORDER_FILLING_IOC;

   if(OrderSend(req, res))
   {
      //========================================================
      // Recovery Success
      //========================================================
      LastRecoveryAction = TimeCurrent();

      // Freeze Grid hanya jika recovery berhasil
      FreezeGridUntil = TimeCurrent() + RecoveryFreezeSec;

      PrintFormat("[REE] Recovery Close Success #%I64u",
                  ticket);

      return(true);
   }

   PrintFormat("[REE] Recovery Close Failed #%I64u | RetCode=%u | Error=%d",
               ticket,
               res.retcode,
               GetLastError());

   return(false);
}

//================================================================================================//
void RecoveryExitEngine(double currentDrawdown)
{
   if(!UseRecoveryExit)
      return;

   // Mulai bekerja setelah DD tertentu
   if(currentDrawdown < RecoveryStartDD)
   {
      LowestPriceAfterBuy   = 0;
      HighestPriceAfterSell = 0;
      return;
   }

   // Cooldown
   if((TimeCurrent() - LastRecoveryAction) < RecoveryCooldownSec)
      return;

   double bid = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);
   double ask = SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);

   //========================================================
   // BUY RECOVERY
   //========================================================
   if(BuyOrders >= 2 && BuyProfits < 0)
   {
      if(LowestPriceAfterBuy == 0)
         LowestPriceAfterBuy = bid;

      if(bid < LowestPriceAfterBuy)
         LowestPriceAfterBuy = bid;

      double retrace =
         (bid - LowestPriceAfterBuy) / _Point;

      if(retrace >= RetraceTriggerPoints)
      {
         PrintFormat("[REE] BUY Retracement Detected : %.0f points",
                     retrace);
      
         ulong ticket = FindBestRecoveryPosition(POSITION_TYPE_BUY);
         
         //========================================================
         // Basket Health Check V1
         // Jangan recovery jika basket tinggal 2 layer
         //========================================================
         if(ticket > 0 && BuyOrders > 2)
         {
            if(CloseRecoveryPosition(ticket))
            {
               LowestPriceAfterBuy = bid;
            }
         }
      }
   }
   else
   {
      LowestPriceAfterBuy = 0;
   }

   //========================================================
   // SELL RECOVERY
   //========================================================
   if(SellOrders >= 2 && SellProfits < 0)
   {
      if(HighestPriceAfterSell == 0)
         HighestPriceAfterSell = ask;

      if(ask > HighestPriceAfterSell)
         HighestPriceAfterSell = ask;

      double retrace =
         (HighestPriceAfterSell - ask) / _Point;

      if(retrace >= RetraceTriggerPoints)
      {
         PrintFormat("[REE] SELL Retracement Detected : %.0f points",
                     retrace);
      
         ulong ticket = FindBestRecoveryPosition(POSITION_TYPE_SELL);
         
         //========================================================
         // Basket Health Check V1
         // Jangan recovery jika basket tinggal 2 layer
         //========================================================
         if(ticket > 0 && SellOrders > 2)
         {
            if(CloseRecoveryPosition(ticket))
            {
               HighestPriceAfterSell = ask;
            }
         }
      }
   }
   else
   {
      HighestPriceAfterSell = 0;
   }
}

//================================================================================================//
void DisplayDashboard(double dd, double rsi, bool recovery)
{
   string mode =
      recovery
      ? "RECOVERY MODE (Aggressive)"
      : "NORMAL GROWTH";

   Comment(
      "======== GRID RECOVERY GRID A New Grid V1 ========\n",
      "Status   : ", (IsTerminated ? "TERMINATED" : "RUNNING"), "\n",
      "Mode     : ", mode, "\n",
      "Drawdown : ", DoubleToString(dd, 2), "%\n",
      "Adaptive Base : ", DoubleToString(AdaptiveEquityBase, 2), "\n",
      "Locked Profit : ", DoubleToString(LockedProfit, 2), "\n",
      "RSI (14) : ", DoubleToString(rsi, 2), "\n",
      "----------------------------------\n",
      "Buy  Lapis: ", BuyOrders,
      " | Profit: ", DoubleToString(BuyProfits, 2), "\n",
      "Sell Lapis: ", SellOrders,
      " | Profit: ", DoubleToString(SellProfits, 2), "\n",
      "=================================="
   );
}
//================================================================================================//
