//================================================================================================//
// Expert Advisor: A New Grid V1 - RECOVERY & GROWTH EDITION 2026
// Adaptive Equity Scaling Edition
// 24/7 EXIT & PROTECTION FIX
// TRAILING STATE FIX
// LAST GRID PRICE FIX
// TRADE RESULT VALIDATION FIX
// SYMBOL / FILLING / VOLUME SAFETY FIX
// RECOVERY REDUCE EXPOSURE FIX
// RECOVERY EXIT ENGINE AUDIT FIX
// RECOVERY STATE MACHINE FIX
//================================================================================================//
#property strict
#property copyright "Copyright 2026, Jarvis"
#property version   "6.009"

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
RecoveryState CurrentRecoveryState = RECOVERY_OFF;

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
   CurrentRecoveryState = RECOVERY_OFF;

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

   double currentDrawdown = 0;
   if(AdaptiveEquityBase > 0 && equity < AdaptiveEquityBase)
      currentDrawdown = ((AdaptiveEquityBase - equity) / AdaptiveEquityBase) * 100.0;

   //========================================================
   // 24/7 EQUITY PROTECTION
   //========================================================
   if(currentDrawdown >= MaxEquityLossPercent)
   {
      PrintFormat("!!! EMERGENCY CUT LOSS: Drawdown %.2f%% !!!", currentDrawdown);

      CloseAllOrders();
      UpdateStatus();

      if(BuyOrders == 0 && SellOrders == 0)
      {
         IsTerminated = true;
         CurrentRecoveryState = RECOVERY_OFF;
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
   // RECOVERY STATE / EXIT ENGINES - 24/7
   //========================================================
   UpdateRecoveryState(currentDrawdown);
   ManageExit(IsInRecovery);
   RecoveryExitEngine(currentDrawdown);
   UpdateStatus();

   double rsi = GetRSIValue();
   double ma  = GetMAValue();
   double price = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);

   //========================================================
   // NEW ENTRY / GRID LOGIC - trading hours apply ONLY here
   // Recovery state ALWAYS blocks new exposure.
   //========================================================
   if(IsTradingHour() &&
      TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
      MQLInfoInteger(MQL_TRADE_ALLOWED) &&
      CurrentRecoveryState == RECOVERY_OFF)
   {
      int lowRSI  = IsInRecovery ? (RSILower - 5) : RSILower;
      int highRSI = IsInRecovery ? (RSIUpper + 5) : RSIUpper;

      bool canOpenBuy  = false;
      bool canOpenSell = false;

      if(BuyOrders == 0 &&
         (TypeOrdersPlace == Open_Buy_And_Sell || TypeOrdersPlace == Open__Only_Buy))
      {
         if(price > ma && rsi < lowRSI)
            canOpenBuy = true;
      }

      if(SellOrders == 0 &&
         (TypeOrdersPlace == Open_Buy_And_Sell || TypeOrdersPlace == Open__Only_Sell))
      {
         if(price < ma && rsi > highRSI)
            canOpenSell = true;
      }

      if(TimeCurrent() >= FreezeGridUntil)
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
void UpdateRecoveryState(double currentDrawdown)
{
   if(!UseRecoveryExit || BuyOrders + SellOrders == 0)
   {
      CurrentRecoveryState = RECOVERY_OFF;
      LowestPriceAfterBuy = 0;
      HighestPriceAfterSell = 0;
      return;
   }

   //========================================================
   // COOLDOWN HAS PRIORITY
   // Never reset COOLDOWN to MONITOR while DD is still high.
   //========================================================
   if(CurrentRecoveryState == RECOVERY_COOLDOWN)
   {
      if(TimeCurrent() < FreezeGridUntil)
         return;

      if(currentDrawdown >= RecoveryStartDD)
      {
         CurrentRecoveryState = RECOVERY_ACTIVE;

         PrintFormat(
            "[RECOVERY] Cooldown complete -> ACTIVE | DD=%.2f%% | Grid remains frozen",
            currentDrawdown
         );

         return;
      }

      CurrentRecoveryState = RECOVERY_OFF;
      LowestPriceAfterBuy = 0;
      HighestPriceAfterSell = 0;

      PrintFormat(
         "[RECOVERY] Cooldown complete -> OFF | DD=%.2f%% | Normal grid may resume",
         currentDrawdown
      );

      return;
   }

   //========================================================
   // DD BELOW RECOVERY THRESHOLD
   //========================================================
   if(currentDrawdown < RecoveryStartDD)
   {
      CurrentRecoveryState = RECOVERY_OFF;
      LowestPriceAfterBuy = 0;
      HighestPriceAfterSell = 0;
      return;
   }

   //========================================================
   // DD >= RECOVERY START
   //========================================================
   if(CurrentRecoveryState == RECOVERY_OFF)
   {
      CurrentRecoveryState = RECOVERY_MONITOR;

      PrintFormat(
         "[RECOVERY] ACTIVATED -> MONITOR | DD=%.2f%% | Grid entries frozen",
         currentDrawdown
      );
   }

   //========================================================
   // MONITOR -> ACTIVE
   //========================================================
   if(CurrentRecoveryState == RECOVERY_MONITOR)
   {
      if(BuyOrders >= 2 || SellOrders >= 2)
      {
         CurrentRecoveryState = RECOVERY_ACTIVE;

         PrintFormat(
            "[RECOVERY] MONITOR -> ACTIVE | DD=%.2f%% | BUY=%d SELL=%d",
            currentDrawdown,
            BuyOrders,
            SellOrders
         );
      }

      return;
   }

   //========================================================
   // ACTIVE
   // Keep recovery active while DD remains >= threshold.
   // RecoveryExitEngine() handles the actual reduction.
   //========================================================
   if(CurrentRecoveryState == RECOVERY_ACTIVE)
      return;
}

//================================================================================================//
void ManageExit(bool recovery)
{
   double target = recovery ? (TargetProfitUSD + 2.0) : TargetProfitUSD;

   if(BuyOrders == 0)
      MaxBuyProfitSeen = 0;
   if(SellOrders == 0)
      MaxSellProfitSeen = 0;

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
         if(openTime >= latestSellTime)
         {
            latestSellTime = openTime;
            PriceOpenLastSell = openPrice;
         }
      }
   }

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
bool IsMarketTradeSuccess(uint retcode)
{
   return (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL);
}

//================================================================================================//
ENUM_ORDER_TYPE_FILLING GetSafeFillingMode()
{
   long filling = 0;
   if(!SymbolInfoInteger(SymbolTrade, SYMBOL_FILLING_MODE, filling))
   {
      PrintFormat("[SAFETY] Cannot read SYMBOL_FILLING_MODE for %s", SymbolTrade);
      return ORDER_FILLING_FOK;
   }

   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;

   long execution = 0;
   SymbolInfoInteger(SymbolTrade, SYMBOL_TRADE_EXEMODE, execution);
   if(execution != SYMBOL_TRADE_EXECUTION_MARKET)
      return ORDER_FILLING_RETURN;

   return ORDER_FILLING_FOK;
}

//================================================================================================//
int GetVolumeDigits()
{
   double step = SymbolInfoDouble(SymbolTrade, SYMBOL_VOLUME_STEP);
   int digits = 0;
   while(digits < 8 && MathAbs(step - NormalizeDouble(step, digits)) > 0.00000001)
      digits++;
   return digits;
}

//================================================================================================//
double NormalizeTradeVolume(double requestedVolume)
{
   double minVolume = SymbolInfoDouble(SymbolTrade, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(SymbolTrade, SYMBOL_VOLUME_MAX);
   double step      = SymbolInfoDouble(SymbolTrade, SYMBOL_VOLUME_STEP);

   if(minVolume <= 0 || maxVolume <= 0 || step <= 0)
   {
      PrintFormat("[SAFETY] Invalid volume specification for %s | Min=%.8f Max=%.8f Step=%.8f", SymbolTrade, minVolume, maxVolume, step);
      return 0.0;
   }

   if(requestedVolume < minVolume - 0.00000001)
   {
      PrintFormat("[SAFETY] Requested volume %.8f is below minimum %.8f for %s", requestedVolume, minVolume, SymbolTrade);
      return 0.0;
   }

   double volume = MathMin(requestedVolume, maxVolume);
   volume = MathFloor((volume + 0.0000000001) / step) * step;

   if(volume < minVolume - 0.00000001)
   {
      PrintFormat("[SAFETY] Normalized volume %.8f became below minimum %.8f for %s", volume, minVolume, SymbolTrade);
      return 0.0;
   }

   return NormalizeDouble(volume, GetVolumeDigits());
}

//================================================================================================//
bool IsTradeEnvironmentSafe(ENUM_ORDER_TYPE type, double &price)
{
   if(!SymbolSelect(SymbolTrade, true))
   {
      PrintFormat("[SAFETY] SymbolSelect failed for %s", SymbolTrade);
      return false;
   }

   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(SymbolTrade, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED || tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY)
   {
      PrintFormat("[SAFETY] Trading disabled/close-only for %s | Mode=%d", SymbolTrade, tradeMode);
      return false;
   }

   double bid = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);
   double ask = SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0 || ask < bid)
   {
      PrintFormat("[SAFETY] Invalid market price for %s | Bid=%.8f Ask=%.8f", SymbolTrade, bid, ask);
      return false;
   }

   price = (type == ORDER_TYPE_BUY) ? ask : bid;
   return (price > 0);
}

//================================================================================================//
void ExecuteTrade(ENUM_ORDER_TYPE type)
{
   double price = 0;
   if(!IsTradeEnvironmentSafe(type, price))
      return;

   int c = (type == ORDER_TYPE_BUY) ? BuyOrders : SellOrders;
   double requestedVolume = ManualLotSize * (c + 1);
   double volume = NormalizeTradeVolume(requestedVolume);
   if(volume <= 0)
   {
      PrintFormat("[OPEN] Trade blocked: invalid volume %.8f for %s", requestedVolume, SymbolTrade);
      return;
   }

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = SymbolTrade;
   req.magic = OrdersID;
   req.volume = volume;
   req.type = type;
   req.price = price;
   req.deviation = 10;
   req.type_filling = GetSafeFillingMode();
   req.comment = CommentsOrders;

   ResetLastError();
   if(!OrderSend(req, res))
   {
      PrintFormat("[OPEN] OrderSend failed %s | Symbol=%s | Volume=%.8f | Filling=%d | Error=%d | RetCode=%u | Comment=%s", EnumToString(type), SymbolTrade, volume, req.type_filling, GetLastError(), res.retcode, res.comment);
      return;
   }

   if(!IsMarketTradeSuccess(res.retcode))
   {
      PrintFormat("[OPEN] Trade rejected %s | Symbol=%s | Volume=%.8f | Filling=%d | RetCode=%u | Comment=%s | Order=%I64u | Deal=%I64u", EnumToString(type), SymbolTrade, volume, req.type_filling, res.retcode, res.comment, res.order, res.deal);
      return;
   }

   PrintFormat("[OPEN] Trade executed %s | Symbol=%s | Volume=%.8f | Filling=%d | RetCode=%u | Order=%I64u | Deal=%I64u", EnumToString(type), SymbolTrade, res.volume, req.type_filling, res.retcode, res.order, res.deal);
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

      double volume = NormalizeTradeVolume(PositionGetDouble(POSITION_VOLUME));
      if(volume <= 0)
      {
         PrintFormat("[CLOSE] Invalid close volume for #%I64u", t);
         continue;
      }

      ENUM_ORDER_TYPE closeType = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      double price = 0;
      if(!IsTradeEnvironmentSafe(closeType, price))
      {
         double bid = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);
         double ask = SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);
         if(bid <= 0 || ask <= 0)
            continue;
         price = (closeType == ORDER_TYPE_BUY) ? ask : bid;
      }

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action = TRADE_ACTION_DEAL;
      req.position = t;
      req.symbol = SymbolTrade;
      req.magic = OrdersID;
      req.volume = volume;
      req.type = closeType;
      req.price = price;
      req.deviation = 10;
      req.type_filling = GetSafeFillingMode();

      ResetLastError();
      bool sent = OrderSend(req, res);
      if(!sent || !IsMarketTradeSuccess(res.retcode))
      {
         PrintFormat("[CLOSE] Trade failed #%I64u | Symbol=%s | Volume=%.8f | Filling=%d | Sent=%s | Error=%d | RetCode=%u | Comment=%s", t, SymbolTrade, volume, req.type_filling, sent ? "true" : "false", GetLastError(), res.retcode, res.comment);
         continue;
      }

      PrintFormat("[CLOSE] Trade executed #%I64u | Symbol=%s | Volume=%.8f | Filling=%d | RetCode=%u | Order=%I64u | Deal=%I64u", t, SymbolTrade, res.volume, req.type_filling, res.retcode, res.order, res.deal);
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
   double worstLoss = 0.0;
   double bestVolume = 0.0;
   datetime oldestTime = 0;

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

      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(profit >= 0)
         continue;

      double loss = -profit;
      double volume = PositionGetDouble(POSITION_VOLUME);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

      if(loss > worstLoss + 0.00000001 ||
         (MathAbs(loss - worstLoss) <= 0.00000001 && volume > bestVolume) ||
         (MathAbs(loss - worstLoss) <= 0.00000001 && MathAbs(volume - bestVolume) <= 0.00000001 && (oldestTime == 0 || openTime < oldestTime)))
      {
         worstLoss = loss;
         bestVolume = volume;
         oldestTime = openTime;
         bestTicket = ticket;
      }
   }

   if(bestTicket > 0 && worstLoss < MinRecoveryLossUSD)
      return 0;

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
   ENUM_ORDER_TYPE closeType = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   double volume = NormalizeTradeVolume(PositionGetDouble(POSITION_VOLUME));
   if(volume <= 0)
      return false;

   double bid = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);
   double ask = SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0)
   {
      PrintFormat("[REE] Cannot close #%I64u: invalid Bid/Ask", ticket);
      return false;
   }

   double price = (closeType == ORDER_TYPE_BUY) ? ask : bid;

   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.position = ticket;
   req.symbol = SymbolTrade;
   req.magic = OrdersID;
   req.volume = volume;
   req.type = closeType;
   req.price = price;
   req.deviation = 10;
   req.type_filling = GetSafeFillingMode();

   ResetLastError();
   bool sent = OrderSend(req, res);

   if(sent && IsMarketTradeSuccess(res.retcode))
   {
      LastRecoveryAction = TimeCurrent();
      FreezeGridUntil = TimeCurrent() + RecoveryFreezeSec;
      PrintFormat("[REE] Exposure Reduced #%I64u | Symbol=%s | Volume=%.8f | Filling=%d | RetCode=%u | Order=%I64u | Deal=%I64u", ticket, SymbolTrade, res.volume, req.type_filling, res.retcode, res.order, res.deal);
      return true;
   }

   PrintFormat("[REE] Exposure Reduction Failed #%I64u | Symbol=%s | Volume=%.8f | Filling=%d | Sent=%s | RetCode=%u | Comment=%s | Error=%d", ticket, SymbolTrade, volume, req.type_filling, sent ? "true" : "false", res.retcode, res.comment, GetLastError());
   return false;
}

//================================================================================================//
void RecoveryExitEngine(double currentDrawdown)
{
   if(!UseRecoveryExit || CurrentRecoveryState == RECOVERY_OFF)
      return;

   if(currentDrawdown < RecoveryStartDD)
      return;

   // One successful recovery action establishes the cooldown. Do not allow
   // a second reduction on the same tick, even if both BUY and SELL qualify.
   if((TimeCurrent() - LastRecoveryAction) < RecoveryCooldownSec)
      return;

   double bid = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);
   double ask = SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0)
      return;

   bool survivalMode = (currentDrawdown >= SurvivalDD);

   //================ BUY RECOVERY =================
   if(BuyOrders >= 2 && BuyProfits < 0)
   {
      if(LowestPriceAfterBuy == 0)
         LowestPriceAfterBuy = bid;
      if(bid < LowestPriceAfterBuy)
         LowestPriceAfterBuy = bid;

      double retrace = (bid - LowestPriceAfterBuy) / _Point;

      if(retrace >= RetraceTriggerPoints)
      {
         ulong ticket = FindBestRecoveryPosition(POSITION_TYPE_BUY);

         // In survival mode, allow reduction even when the worst individual
         // loss is below MinRecoveryLossUSD. The basket DD has priority.
         if(ticket == 0 && survivalMode)
         {
            // Find the worst losing BUY without the minimum-loss gate.
            double worstLoss = 0.0;
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
               ulong t = PositionGetTicket(i);
               if(!PositionSelectByTicket(t)) continue;
               if(PositionGetInteger(POSITION_MAGIC) != OrdersID) continue;
               if(PositionGetString(POSITION_SYMBOL) != SymbolTrade) continue;
               if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

               double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
               if(p >= 0) continue;
               double loss = -p;
               if(loss > worstLoss)
               {
                  worstLoss = loss;
                  ticket = t;
               }
            }
         }

         if(ticket > 0 && BuyOrders > 1)
         {
            if(CloseRecoveryPosition(ticket))
            {
               LowestPriceAfterBuy = bid;
               CurrentRecoveryState = RECOVERY_COOLDOWN;
               PrintFormat("[REE] BUY exposure reduced | DD=%.2f%% | Survival=%s | Remaining BUY layers expected <= %d", currentDrawdown, survivalMode ? "ON" : "OFF", BuyOrders - 1);
               return;
            }
         }
      }
   }
   else
   {
      LowestPriceAfterBuy = 0;
   }

   //================ SELL RECOVERY =================
   if(SellOrders >= 2 && SellProfits < 0)
   {
      if(HighestPriceAfterSell == 0)
         HighestPriceAfterSell = ask;
      if(ask > HighestPriceAfterSell)
         HighestPriceAfterSell = ask;

      double retrace = (HighestPriceAfterSell - ask) / _Point;

      if(retrace >= RetraceTriggerPoints)
      {
         ulong ticket = FindBestRecoveryPosition(POSITION_TYPE_SELL);

         if(ticket == 0 && survivalMode)
         {
            double worstLoss = 0.0;
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
               ulong t = PositionGetTicket(i);
               if(!PositionSelectByTicket(t)) continue;
               if(PositionGetInteger(POSITION_MAGIC) != OrdersID) continue;
               if(PositionGetString(POSITION_SYMBOL) != SymbolTrade) continue;
               if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) continue;

               double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
               if(p >= 0) continue;
               double loss = -p;
               if(loss > worstLoss)
               {
                  worstLoss = loss;
                  ticket = t;
               }
            }
         }

         if(ticket > 0 && SellOrders > 1)
         {
            if(CloseRecoveryPosition(ticket))
            {
               HighestPriceAfterSell = ask;
               CurrentRecoveryState = RECOVERY_COOLDOWN;
               PrintFormat("[REE] SELL exposure reduced | DD=%.2f%% | Survival=%s | Remaining SELL layers expected <= %d", currentDrawdown, survivalMode ? "ON" : "OFF", SellOrders - 1);
               return;
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
   string mode = recovery ? "RECOVERY MODE (Aggressive)" : "NORMAL GROWTH";
   string recoveryState = "OFF";
   if(CurrentRecoveryState == RECOVERY_MONITOR) recoveryState = "MONITOR";
   if(CurrentRecoveryState == RECOVERY_ACTIVE) recoveryState = "ACTIVE";
   if(CurrentRecoveryState == RECOVERY_COOLDOWN) recoveryState = "COOLDOWN";

   Comment(
      "======== GRID RECOVERY GRID A New Grid V1 ========\n",
      "Status   : ", (IsTerminated ? "TERMINATED" : "RUNNING"), "\n",
      "Mode     : ", mode, "\n",
      "Recovery : ", recoveryState, "\n",
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
