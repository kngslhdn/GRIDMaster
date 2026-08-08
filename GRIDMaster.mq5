//================================================================================================//
// Expert Advisor: A New Grid V1 - RECOVERY & GROWTH EDITION 2026
// Adaptive Equity Scaling Edition
// 24/7 EXIT & PROTECTION FIX
// TRAILING STATE FIX
// LAST GRID PRICE FIX
//================================================================================================//
#property strict
#property copyright "Copyright 2026, Jarvis"
#property version   "6.004"

enum Type {Open_Buy_And_Sell, Open__Only_Buy, Open__Only_Sell};
enum RecoveryState { RECOVERY_OFF = 0, RECOVERY_MONITOR, RECOVERY_ACTIVE, RECOVERY_COOLDOWN };

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

input string Recovery_Settings     = "||========== RECOVERY EXIT ENGINE ==========||";
input bool   UseRecoveryExit       = true;
input double RecoveryStartDD       = 8.0;
input double SurvivalDD            = 12.0;
input double RetraceTriggerPoints  = 500;
input int    RecoveryCooldownSec   = 180;
input int    RecoveryFreezeSec     = 180;
input double MinRecoveryLossUSD    = 20.0;

input string TradingHourSettings  = "||========== TRADING HOURS ==========||";
input bool   UseTradingHour       = true;
input int    StartHour            = 7;
input int    EndHour              = 22;

string SymbolTrade;
int    OrdersID, HandleRSI, HandleMA;
int    BuyOrders, SellOrders;
double BuyProfits, SellProfits;
double PriceOpenLastBuy, PriceOpenLastSell;

bool     IsTerminated = false;
double   HighWaterMark = 0;
datetime FreezeGridUntil = 0;

datetime LastRecoveryAction = 0;
double   LowestPriceAfterBuy = 0;
double   HighestPriceAfterSell = 0;

double InitialBalance = 0;
double AdaptiveEquityBase = 0;
double LockedProfit = 0;

double MaxBuyProfitSeen = 0;
double MaxSellProfitSeen = 0;

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

   return (hour >= StartHour || hour < EndHour);
}

//================================================================================================//
int OnInit()
{
   SymbolTrade = _Symbol;
   OrdersID = (MagicNumber == 0) ? 101010 : MagicNumber;

   HandleRSI = iRSI(SymbolTrade, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
   HandleMA  = iMA(SymbolTrade, PERIOD_CURRENT, MAPeriod, 0, MODE_SMA, PRICE_CLOSE);

   HighWaterMark = AccountInfoDouble(ACCOUNT_BALANCE);
   InitialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   AdaptiveEquityBase = InitialBalance;
   LockedProfit = 0;

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
   // CRITICAL: trading hours must NOT gate exits, recovery, or protection.
   if(IsTerminated)
      return;

   UpdateStatus();

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   LockedProfit = balance - InitialBalance;
   if(LockedProfit < 0)
      LockedProfit = 0;

   AdaptiveEquityBase = InitialBalance + LockedProfit;

   if(balance > HighWaterMark)
      HighWaterMark = balance;

   bool IsInRecovery = (balance < HighWaterMark);

   //========================================================
   // 24/7 EQUITY PROTECTION
   //========================================================
   double currentDrawdown = 0;

   if(AdaptiveEquityBase > 0 && equity < AdaptiveEquityBase)
   {
      currentDrawdown = ((AdaptiveEquityBase - equity) / AdaptiveEquityBase) * 100.0;
   }

   if(currentDrawdown >= MaxEquityLossPercent)
   {
      PrintFormat("!!! EMERGENCY CUT LOSS: Drawdown %.2f%% !!!", currentDrawdown);

      CloseAllOrders();
      UpdateStatus();

      if(BuyOrders == 0 && SellOrders == 0)
      {
         IsTerminated = true;
         Print("[PROTECTION] All managed positions closed. EA terminated for safety.");
      }
      else
      {
         PrintFormat("[PROTECTION] Close incomplete. BUY=%d SELL=%d. Retrying on next tick.", BuyOrders, SellOrders);
      }

      DisplayDashboard(currentDrawdown, GetRSIValue(), IsInRecovery);
      return;
   }

   //========================================================
   // 24/7 EXIT ENGINES - NEVER gated by trading hours
   //========================================================
   ManageExit(IsInRecovery);
   RecoveryExitEngine(currentDrawdown);
   UpdateStatus();

   double rsi = GetRSIValue();
   double ma  = GetMAValue();
   double price = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);

   //========================================================
   // NEW ENTRY / GRID LOGIC - trading hours apply ONLY here
   //========================================================
   if(IsTradingHour() && TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      int lowRSI  = IsInRecovery ? (RSILower - 5) : RSILower;
      int highRSI = IsInRecovery ? (RSIUpper + 5) : RSIUpper;

      bool canOpenBuy  = false;
      bool canOpenSell = false;

      if(BuyOrders == 0 && (TypeOrdersPlace == Open_Buy_And_Sell || TypeOrdersPlace == Open__Only_Buy))
      {
         if(price > ma && rsi < lowRSI)
            canOpenBuy = true;
      }

      if(SellOrders == 0 && (TypeOrdersPlace == Open_Buy_And_Sell || TypeOrdersPlace == Open__Only_Sell))
      {
         if(price < ma && rsi > highRSI)
            canOpenSell = true;
      }

      bool GridFreeze = (TimeCurrent() < FreezeGridUntil);

      if(!GridFreeze)
      {
         if(BuyOrders > 0 && BuyOrders < MaxOrders)
         {
            double gap = PointsForFirstGap * MathPow(GapMultiplier, BuyOrders - 1);
            if(SymbolInfoDouble(SymbolTrade, SYMBOL_ASK) <= PriceOpenLastBuy - (gap * _Point))
               canOpenBuy = true;
         }

         if(SellOrders > 0 && SellOrders < MaxOrders)
         {
            double gap = PointsForFirstGap * MathPow(GapMultiplier, SellOrders - 1);
            if(price >= PriceOpenLastSell + (gap * _Point))
               canOpenSell = true;
         }
      }

      if(canOpenBuy)
         ExecuteTrade(ORDER_TYPE_BUY);

      if(canOpenSell)
         ExecuteTrade(ORDER_TYPE_SELL);
   }

   DisplayDashboard(currentDrawdown, rsi, IsInRecovery);
}

//================================================================================================//
void ManageExit(bool recovery)
{
   double target = recovery ? (TargetProfitUSD + 2.0) : TargetProfitUSD;

   //========================================================
   // TRAILING STATE
   // Once armed, peak profit remains active until the basket
   // is actually closed. A retrace below TrailingStartUSD is
   // still allowed to trigger the trailing stop.
   //========================================================

   if(BuyOrders == 0)
      MaxBuyProfitSeen = 0;

   if(SellOrders == 0)
      MaxSellProfitSeen = 0;

   //================ BUY EXIT =================
   if(BuyOrders > 0)
   {
      if(!UseTrailingProfit)
      {
         if(BuyProfits >= target)
            CloseOrdersByType(POSITION_TYPE_BUY);
      }
      else
      {
         if(BuyProfits >= TrailingStartUSD && BuyProfits > MaxBuyProfitSeen)
            MaxBuyProfitSeen = BuyProfits;

         if(MaxBuyProfitSeen >= TrailingStartUSD && BuyProfits <= MaxBuyProfitSeen - TrailingStopUSD)
            CloseOrdersByType(POSITION_TYPE_BUY);
      }
   }

   //================ SELL EXIT =================
   if(SellOrders > 0)
   {
      if(!UseTrailingProfit)
      {
         if(SellProfits >= target)
            CloseOrdersByType(POSITION_TYPE_SELL);
      }
      else
      {
         if(SellProfits >= TrailingStartUSD && SellProfits > MaxSellProfitSeen)
            MaxSellProfitSeen = SellProfits;

         if(MaxSellProfitSeen >= TrailingStartUSD && SellProfits <= MaxSellProfitSeen - TrailingStopUSD)
            CloseOrdersByType(POSITION_TYPE_SELL);
      }
   }
}

//================================================================================================//
void UpdateStatus()
{
   BuyOrders = 0;
   SellOrders = 0;
   BuyProfits = 0;
   SellProfits = 0;
   PriceOpenLastBuy = 0;
   PriceOpenLastSell = 0;

   datetime latestBuyTime = 0;
   datetime latestSellTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != OrdersID)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != SymbolTrade)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      if(type == POSITION_TYPE_BUY)
      {
         BuyOrders++;
         BuyProfits += p;

         // CRITICAL: use the most recently opened BUY layer.
         if(openTime >= latestBuyTime)
         {
            latestBuyTime = openTime;
            PriceOpenLastBuy = openPrice;
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         SellOrders++;
         SellProfits += p;

         // CRITICAL: use the most recently opened SELL layer.
         if(openTime >= latestSellTime)
         {
            latestSellTime = openTime;
            PriceOpenLastSell = openPrice;
         }
      }
   }

   // Reset trailing state ONLY after the basket has actually disappeared.
   if(BuyOrders == 0)
      MaxBuyProfitSeen = 0;

   if(SellOrders == 0)
      MaxSellProfitSeen = 0;
}

//================================================================================================//
double GetRSIValue()
{
   double b[];
   ArraySetAsSeries(b, true);
   return (CopyBuffer(HandleRSI, 0, 0, 1, b) > 0) ? b[0] : 50.0;
}

//================================================================================================//
double GetMAValue()
{
   double b[];
   ArraySetAsSeries(b, true);
   return (CopyBuffer(HandleMA, 0, 0, 1, b) > 0) ? b[0] : 0;
}

//================================================================================================//
void ExecuteTrade(ENUM_ORDER_TYPE type)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   int c = (type == ORDER_TYPE_BUY) ? BuyOrders : SellOrders;

   req.action = TRADE_ACTION_DEAL;
   req.symbol = SymbolTrade;
   req.magic = OrdersID;
   req.volume = NormalizeDouble(ManualLotSize * (c + 1), 2);
   req.type = type;
   req.deviation = 10;
   req.type_filling = ORDER_FILLING_IOC;
   req.comment = CommentsOrders;
   req.price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(SymbolTrade, SYMBOL_ASK) : SymbolInfoDouble(SymbolTrade, SYMBOL_BID);

   ResetLastError();

   if(!OrderSend(req, res))
   {
      PrintFormat("Gagal membuka %s. Error=%d RetCode=%u Comment=%s", EnumToString(type), GetLastError(), res.retcode, res.comment);
      return;
   }

   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_DONE_PARTIAL && res.retcode != TRADE_RETCODE_PLACED)
   {
      PrintFormat("Open %s rejected. RetCode=%u Comment=%s", EnumToString(type), res.retcode, res.comment);
   }
}

//================================================================================================//
bool IsCloseRetcodeSuccess(uint retcode)
{
   return (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL || retcode == TRADE_RETCODE_PLACED);
}

//================================================================================================//
void CloseOrdersByType(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);

      if(!PositionSelectByTicket(t))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != OrdersID)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != SymbolTrade)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};

      req.action = TRADE_ACTION_DEAL;
      req.position = t;
      req.symbol = SymbolTrade;
      req.magic = OrdersID;
      req.volume = PositionGetDouble(POSITION_VOLUME);
      req.type = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(SymbolTrade, SYMBOL_BID) : SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);
      req.deviation = 10;
      req.type_filling = ORDER_FILLING_IOC;

      ResetLastError();
      bool sent = OrderSend(req, res);

      if(!sent || !IsCloseRetcodeSuccess(res.retcode))
      {
         PrintFormat("Gagal menutup tiket #%I64u. Sent=%s RetCode=%u Comment=%s Error=%d", t, sent ? "true" : "false", res.retcode, res.comment, GetLastError());
      }
      else
      {
         PrintFormat("[EXIT] Close request accepted #%I64u RetCode=%u", t, res.retcode);
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
   ulong bestTicket = 0;
   double bestScore = -DBL_MAX;

   double currentPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(SymbolTrade, SYMBOL_BID) : SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);

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
      if(profit >= 0)
         continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double distance = MathAbs(currentPrice - openPrice) / _Point;
      double score = (volume * 1000.0) + distance;

      if(score > bestScore)
      {
         bestScore = score;
         bestTicket = ticket;
      }
   }

   return bestTicket;
}

//================================================================================================//
bool CloseRecoveryPosition(ulong ticket)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return false;

   if(PositionGetInteger(POSITION_MAGIC) != OrdersID || PositionGetString(POSITION_SYMBOL) != SymbolTrade)
      return false;

   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   MqlTradeRequest req = {};
   MqlTradeResult res = {};

   req.action = TRADE_ACTION_DEAL;
   req.position = ticket;
   req.symbol = SymbolTrade;
   req.magic = OrdersID;
   req.volume = PositionGetDouble(POSITION_VOLUME);
   req.type = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(SymbolTrade, SYMBOL_BID) : SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);
   req.deviation = 10;
   req.type_filling = ORDER_FILLING_IOC;

   ResetLastError();
   bool sent = OrderSend(req, res);

   if(sent && IsCloseRetcodeSuccess(res.retcode))
   {
      LastRecoveryAction = TimeCurrent();
      FreezeGridUntil = TimeCurrent() + RecoveryFreezeSec;
      PrintFormat("[REE] Recovery Close Success #%I64u RetCode=%u", ticket, res.retcode);
      return true;
   }

   PrintFormat("[REE] Recovery Close Failed #%I64u | Sent=%s | RetCode=%u | Comment=%s | Error=%d", ticket, sent ? "true" : "false", res.retcode, res.comment, GetLastError());
   return false;
}

//================================================================================================//
void RecoveryExitEngine(double currentDrawdown)
{
   if(!UseRecoveryExit)
      return;

   if(currentDrawdown < RecoveryStartDD)
   {
      LowestPriceAfterBuy = 0;
      HighestPriceAfterSell = 0;
      return;
   }

   if((TimeCurrent() - LastRecoveryAction) < RecoveryCooldownSec)
      return;

   double bid = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);
   double ask = SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);

   if(BuyOrders >= 2 && BuyProfits < 0)
   {
      if(LowestPriceAfterBuy == 0)
         LowestPriceAfterBuy = bid;
      if(bid < LowestPriceAfterBuy)
         LowestPriceAfterBuy = bid;

      double retrace = (bid - LowestPriceAfterBuy) / _Point;

      if(retrace >= RetraceTriggerPoints)
      {
         PrintFormat("[REE] BUY Retracement Detected : %.0f points", retrace);
         ulong ticket = FindBestRecoveryPosition(POSITION_TYPE_BUY);

         if(ticket > 0 && BuyOrders > 2)
         {
            if(CloseRecoveryPosition(ticket))
               LowestPriceAfterBuy = bid;
         }
      }
   }
   else
   {
      LowestPriceAfterBuy = 0;
   }

   if(SellOrders >= 2 && SellProfits < 0)
   {
      if(HighestPriceAfterSell == 0)
         HighestPriceAfterSell = ask;
      if(ask > HighestPriceAfterSell)
         HighestPriceAfterSell = ask;

      double retrace = (HighestPriceAfterSell - ask) / _Point;

      if(retrace >= RetraceTriggerPoints)
      {
         PrintFormat("[REE] SELL Retracement Detected : %.0f points", retrace);
         ulong ticket = FindBestRecoveryPosition(POSITION_TYPE_SELL);

         if(ticket > 0 && SellOrders > 2)
         {
            if(CloseRecoveryPosition(ticket))
               HighestPriceAfterSell = ask;
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
   string mode = recovery ? "RECOVERY MODE (Aggressive)" : "NORMAL GROWTH";

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
