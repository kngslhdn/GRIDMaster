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
// RECOVERY BASKET-LOSS REDUCTION FIX
// RECOVERY EXPOSURE REDUCTION FIX
// HARD PROTECTION LATCH FIX
// RECOVERY DIAGNOSTIC LOG FIX
// HIGH-DD RETRACEMENT BYPASS FIX
// SURVIVAL LAST POSITION CLOSE FIX
// EQUITY PROTECTION + RECOVERY + SURVIVAL + ORDER PLACEMENT FIX
//================================================================================================//
#property strict
#property copyright "Copyright 2026, Jarvis"
#property version   "6.016"

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
bool     HardProtectionActive = false;
bool     RecoveryActionThisTick = false;
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
   HardProtectionActive = false;
   RecoveryActionThisTick = false;
   FreezeGridUntil = 0;
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
   if(IsTerminated)
      return;

   RecoveryActionThisTick = false;
   UpdateStatus();

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   LockedProfit = balance - InitialBalance;
   if(LockedProfit < 0) LockedProfit = 0;
   AdaptiveEquityBase = InitialBalance + LockedProfit;
   if(balance > HighWaterMark) HighWaterMark = balance;
   bool IsInRecovery = (balance < HighWaterMark);

   double currentDrawdown = 0;
   if(AdaptiveEquityBase > 0 && equity < AdaptiveEquityBase)
      currentDrawdown = ((AdaptiveEquityBase - equity) / AdaptiveEquityBase) * 100.0;

   // HARD PROTECTION LATCH: once threshold is reached, protection remains active until all managed positions are closed.
   if(currentDrawdown >= MaxEquityLossPercent)
   {
      if(!HardProtectionActive)
      {
         HardProtectionActive = true;
         PrintFormat("[PROTECTION] HARD LATCH ACTIVATED | DD=%.2f%% | Threshold=%.2f%% | BUY=%d SELL=%d | Equity=%.2f | Balance=%.2f", currentDrawdown, MaxEquityLossPercent, BuyOrders, SellOrders, equity, balance);
      }
   }

   if(HardProtectionActive)
   {
      PrintFormat("[PROTECTION] HARD LATCH ACTIVE | DD=%.2f%% | BUY=%d SELL=%d | Equity=%.2f | Balance=%.2f", currentDrawdown, BuyOrders, SellOrders, equity, balance);
      CloseAllOrders();
      UpdateStatus();
      if(BuyOrders == 0 && SellOrders == 0)
      {
         IsTerminated = true;
         CurrentRecoveryState = RECOVERY_OFF;
         Print("[PROTECTION] HARD LATCH COMPLETE | All managed positions closed | EA TERMINATED");
      }
      else
      {
         PrintFormat("[PROTECTION] HARD LATCH RETRY | Remaining BUY=%d SELL=%d", BuyOrders, SellOrders);
      }
      DisplayDashboard(currentDrawdown, GetRSIValue(), IsInRecovery);
      return;
   }

   UpdateRecoveryState(currentDrawdown);
   ManageExit(IsInRecovery);
   RecoveryExitEngine(currentDrawdown);
   UpdateStatus();

   // A successful recovery close must never be followed by a new entry on the same tick.
   if(RecoveryActionThisTick)
   {
      PrintFormat("[ORDER BLOCK] Recovery action executed this tick | FreezeUntil=%s | State=%s", TimeToString(FreezeGridUntil, TIME_DATE|TIME_SECONDS), CurrentRecoveryState == RECOVERY_COOLDOWN ? "COOLDOWN" : "SURVIVAL" );
      DisplayDashboard(currentDrawdown, GetRSIValue(), IsInRecovery);
      return;
   }

   double rsi = GetRSIValue();
   double ma  = GetMAValue();
   double price = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);

   // ORDER PLACEMENT HARD GATE:
   // Hard protection, recovery states and recovery freeze all block NEW orders.
   // Freeze is checked BEFORE initial-entry logic as well as grid-addition logic.
   bool orderPlacementAllowed =
      !HardProtectionActive &&
      !IsTerminated &&
      CurrentRecoveryState == RECOVERY_OFF &&
      TimeCurrent() >= FreezeGridUntil &&
      IsTradingHour() &&
      TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
      MQLInfoInteger(MQL_TRADE_ALLOWED);

   if(orderPlacementAllowed)
   {
      int lowRSI  = IsInRecovery ? (RSILower - 5) : RSILower;
      int highRSI = IsInRecovery ? (RSIUpper + 5) : RSIUpper;
      bool canOpenBuy  = false;
      bool canOpenSell = false;

      if(BuyOrders == 0 && (TypeOrdersPlace == Open_Buy_And_Sell || TypeOrdersPlace == Open__Only_Buy))
         if(price > ma && rsi < lowRSI) canOpenBuy = true;

      if(SellOrders == 0 && (TypeOrdersPlace == Open_Buy_And_Sell || TypeOrdersPlace == Open__Only_Sell))
         if(price < ma && rsi > highRSI) canOpenSell = true;

      if(BuyOrders > 0 && BuyOrders < MaxOrders)
      {
         double gap = PointsForFirstGap * MathPow(GapMultiplier, BuyOrders - 1);
         if(SymbolInfoDouble(SymbolTrade, SYMBOL_ASK) <= PriceOpenLastBuy - (gap * _Point)) canOpenBuy = true;
      }
      if(SellOrders > 0 && SellOrders < MaxOrders)
      {
         double gap = PointsForFirstGap * MathPow(GapMultiplier, SellOrders - 1);
         if(price >= PriceOpenLastSell + (gap * _Point)) canOpenSell = true;
      }

      if(canOpenBuy) ExecuteTrade(ORDER_TYPE_BUY);
      if(canOpenSell) ExecuteTrade(ORDER_TYPE_SELL);
   }
   else if(TimeCurrent() < FreezeGridUntil && CurrentRecoveryState == RECOVERY_OFF)
   {
      PrintFormat("[ORDER BLOCK] Recovery freeze active | Until=%s | DD=%.2f%%", TimeToString(FreezeGridUntil, TIME_DATE|TIME_SECONDS), currentDrawdown);
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

   if(CurrentRecoveryState == RECOVERY_COOLDOWN)
   {
      if(TimeCurrent() < FreezeGridUntil)
         return;
      if(currentDrawdown >= RecoveryStartDD)
      {
         CurrentRecoveryState = RECOVERY_ACTIVE;
         PrintFormat("[RECOVERY] Cooldown complete -> ACTIVE | DD=%.2f%% | BUY=%d SELL=%d", currentDrawdown, BuyOrders, SellOrders);
         return;
      }
      CurrentRecoveryState = RECOVERY_OFF;
      LowestPriceAfterBuy = 0;
      HighestPriceAfterSell = 0;
      PrintFormat("[RECOVERY] Cooldown complete -> OFF | DD=%.2f%%", currentDrawdown);
      return;
   }

   if(currentDrawdown < RecoveryStartDD)
   {
      CurrentRecoveryState = RECOVERY_OFF;
      LowestPriceAfterBuy = 0;
      HighestPriceAfterSell = 0;
      return;
   }

   if(CurrentRecoveryState == RECOVERY_OFF)
   {
      CurrentRecoveryState = RECOVERY_MONITOR;
      PrintFormat("[RECOVERY] ACTIVATED -> MONITOR | DD=%.2f%% | BUY=%d SELL=%d | BasketLoss=%.2f/%.2f", currentDrawdown, BuyOrders, SellOrders, GetRecoveryBasketLoss(POSITION_TYPE_BUY), GetRecoveryBasketLoss(POSITION_TYPE_SELL), MinRecoveryLossUSD);
   }

   if(CurrentRecoveryState == RECOVERY_MONITOR)
   {
      if(BuyOrders >= 2 || SellOrders >= 2)
      {
         CurrentRecoveryState = RECOVERY_ACTIVE;
         PrintFormat("[RECOVERY] MONITOR -> ACTIVE | DD=%.2f%% | BUY=%d SELL=%d | Exposure BUY=%.8f SELL=%.8f", currentDrawdown, BuyOrders, SellOrders, GetRecoveryExposure(POSITION_TYPE_BUY), GetRecoveryExposure(POSITION_TYPE_SELL));
      }
      return;
   }

   if(CurrentRecoveryState == RECOVERY_ACTIVE)
   {
      PrintFormat("[RECOVERY] ACTIVE | DD=%.2f%% | BUY=%d SELL=%d | Exposure BUY=%.8f SELL=%.8f | BasketLoss BUY=%.2f SELL=%.2f", currentDrawdown, BuyOrders, SellOrders, GetRecoveryExposure(POSITION_TYPE_BUY), GetRecoveryExposure(POSITION_TYPE_SELL), GetRecoveryBasketLoss(POSITION_TYPE_BUY), GetRecoveryBasketLoss(POSITION_TYPE_SELL));
      return;
   }
}

//================================================================================================//
void ManageExit(bool recovery)
{
   double target = recovery ? (TargetProfitUSD + 2.0) : TargetProfitUSD;
   if(BuyOrders == 0) MaxBuyProfitSeen = 0;
   if(SellOrders == 0) MaxSellProfitSeen = 0;

   if(BuyOrders > 0)
   {
      if(!UseTrailingProfit)
      {
         if(BuyProfits >= target) CloseOrdersByType(POSITION_TYPE_BUY);
      }
      else
      {
         if(BuyProfits >= TrailingStartUSD && BuyProfits > MaxBuyProfitSeen) MaxBuyProfitSeen = BuyProfits;
         if(MaxBuyProfitSeen >= TrailingStartUSD && BuyProfits <= MaxBuyProfitSeen - TrailingStopUSD) CloseOrdersByType(POSITION_TYPE_BUY);
      }
   }

   if(SellOrders > 0)
   {
      if(!UseTrailingProfit)
      {
         if(SellProfits >= target) CloseOrdersByType(POSITION_TYPE_SELL);
      }
      else
      {
         if(SellProfits >= TrailingStartUSD && SellProfits > MaxSellProfitSeen) MaxSellProfitSeen = SellProfits;
         if(MaxSellProfitSeen >= TrailingStartUSD && SellProfits <= MaxSellProfitSeen - TrailingStopUSD) CloseOrdersByType(POSITION_TYPE_SELL);
      }
   }
}

//================================================================================================//
void UpdateStatus()
{
   BuyOrders = 0; SellOrders = 0; BuyProfits = 0; SellProfits = 0; PriceOpenLastBuy = 0; PriceOpenLastSell = 0;
   datetime latestBuyTime = 0, latestSellTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != OrdersID) continue;
      if(PositionGetString(POSITION_SYMBOL) != SymbolTrade) continue;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(type == POSITION_TYPE_BUY)
      {
         BuyOrders++; BuyProfits += p;
         if(openTime >= latestBuyTime) { latestBuyTime = openTime; PriceOpenLastBuy = openPrice; }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         SellOrders++; SellProfits += p;
         if(openTime >= latestSellTime) { latestSellTime = openTime; PriceOpenLastSell = openPrice; }
      }
   }
   if(BuyOrders == 0) MaxBuyProfitSeen = 0;
   if(SellOrders == 0) MaxSellProfitSeen = 0;
}

//================================================================================================//
double GetRSIValue()
{
   double b[]; ArraySetAsSeries(b, true);
   return (CopyBuffer(HandleRSI, 0, 0, 1, b) > 0) ? b[0] : 50.0;
}

//================================================================================================//
double GetMAValue()
{
   double b[]; ArraySetAsSeries(b, true);
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
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   long execution = 0;
   SymbolInfoInteger(SymbolTrade, SYMBOL_TRADE_EXEMODE, execution);
   if(execution != SYMBOL_TRADE_EXECUTION_MARKET) return ORDER_FILLING_RETURN;
   return ORDER_FILLING_FOK;
}

//================================================================================================//
int GetVolumeDigits()
{
   double step = SymbolInfoDouble(SymbolTrade, SYMBOL_VOLUME_STEP);
   int digits = 0;
   while(digits < 8 && MathAbs(step - NormalizeDouble(step, digits)) > 0.00000001) digits++;
   return digits;
}

//================================================================================================//
double NormalizeTradeVolume(double requestedVolume)
{
   double minVolume = SymbolInfoDouble(SymbolTrade, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(SymbolTrade, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(SymbolTrade, SYMBOL_VOLUME_STEP);
   if(minVolume <= 0 || maxVolume <= 0 || step <= 0) return 0.0;
   if(requestedVolume < minVolume - 0.00000001) return 0.0;
   double volume = MathMin(requestedVolume, maxVolume);
   volume = MathFloor((volume + 0.0000000001) / step) * step;
   if(volume < minVolume - 0.00000001) return 0.0;
   return NormalizeDouble(volume, GetVolumeDigits());
}

//================================================================================================//
bool IsTradeEnvironmentSafe(ENUM_ORDER_TYPE type, double &price)
{
   if(!SymbolSelect(SymbolTrade, true)) return false;
   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(SymbolTrade, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED || tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY) return false;
   double bid = SymbolInfoDouble(SymbolTrade, SYMBOL_BID);
   double ask = SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0 || ask < bid) return false;
   price = (type == ORDER_TYPE_BUY) ? ask : bid;
   return (price > 0);
}

//================================================================================================//
void ExecuteTrade(ENUM_ORDER_TYPE type)
{
   double price = 0;
   if(!IsTradeEnvironmentSafe(type, price)) return;
   int c = (type == ORDER_TYPE_BUY) ? BuyOrders : SellOrders;
   double requestedVolume = ManualLotSize * (c + 1);
   double volume = NormalizeTradeVolume(requestedVolume);
   if(volume <= 0) return;
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL; req.symbol = SymbolTrade; req.magic = OrdersID; req.volume = volume; req.type = type; req.price = price; req.deviation = 10; req.type_filling = GetSafeFillingMode(); req.comment = CommentsOrders;
   ResetLastError();
   if(!OrderSend(req, res)) return;
   if(!IsMarketTradeSuccess(res.retcode)) return;
   PrintFormat("[OPEN] Trade executed %s | Symbol=%s | Volume=%.8f | RetCode=%u | Order=%I64u | Deal=%I64u", EnumToString(type), SymbolTrade, res.volume, res.retcode, res.order, res.deal);
}

//================================================================================================//
void CloseOrdersByType(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != OrdersID) continue;
      if(PositionGetString(POSITION_SYMBOL) != SymbolTrade) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      double volume = NormalizeTradeVolume(PositionGetDouble(POSITION_VOLUME));
      if(volume <= 0) continue;
      ENUM_ORDER_TYPE closeType = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      double price = 0;
      if(!IsTradeEnvironmentSafe(closeType, price))
      {
         double bid = SymbolInfoDouble(SymbolTrade, SYMBOL_BID), ask = SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);
         if(bid <= 0 || ask <= 0) continue;
         price = (closeType == ORDER_TYPE_BUY) ? ask : bid;
      }
      MqlTradeRequest req = {}; MqlTradeResult res = {};
      req.action = TRADE_ACTION_DEAL; req.position = t; req.symbol = SymbolTrade; req.magic = OrdersID; req.volume = volume; req.type = closeType; req.price = price; req.deviation = 10; req.type_filling = GetSafeFillingMode();
      ResetLastError();
      bool sent = OrderSend(req, res);
      if(!sent || !IsMarketTradeSuccess(res.retcode))
      {
         PrintFormat("[CLOSE] Trade failed #%I64u | RetCode=%u | Comment=%s | Error=%d", t, res.retcode, res.comment, GetLastError());
         continue;
      }
      PrintFormat("[CLOSE] Trade executed #%I64u | Volume=%.8f | RetCode=%u", t, res.volume, res.retcode);
   }
}

//================================================================================================//
void CloseAllOrders()
{
   CloseOrdersByType(POSITION_TYPE_BUY);
   CloseOrdersByType(POSITION_TYPE_SELL);
}

//================================================================================================//
double GetRecoveryBasketLoss(ENUM_POSITION_TYPE type)
{
   double basketProfit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != OrdersID) continue;
      if(PositionGetString(POSITION_SYMBOL) != SymbolTrade) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      basketProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return (basketProfit < 0.0) ? -basketProfit : 0.0;
}

//================================================================================================//
double GetRecoveryExposure(ENUM_POSITION_TYPE type)
{
   double exposure = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != OrdersID) continue;
      if(PositionGetString(POSITION_SYMBOL) != SymbolTrade) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      exposure += PositionGetDouble(POSITION_VOLUME);
   }
   return exposure;
}

//================================================================================================//
ulong FindBestRecoveryPosition(ENUM_POSITION_TYPE type, bool allowBelowMinLoss)
{
   ulong bestTicket = 0;
   double bestExposure = 0.0, bestLoss = 0.0;
   datetime oldestTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != OrdersID) continue;
      if(PositionGetString(POSITION_SYMBOL) != SymbolTrade) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(profit >= 0) continue;
      double loss = -profit;
      double volume = PositionGetDouble(POSITION_VOLUME);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(volume > bestExposure + 0.00000001 || (MathAbs(volume - bestExposure) <= 0.00000001 && loss > bestLoss + 0.00000001) || (MathAbs(volume - bestExposure) <= 0.00000001 && MathAbs(loss - bestLoss) <= 0.00000001 && (oldestTime == 0 || openTime < oldestTime)))
      {
         bestExposure = volume; bestLoss = loss; oldestTime = openTime; bestTicket = ticket;
      }
   }
   if(bestTicket > 0 && bestLoss < MinRecoveryLossUSD && !allowBelowMinLoss) return 0;
   return bestTicket;
}

//================================================================================================//
bool CloseRecoveryPosition(ulong ticket)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket)) return false;
   if(PositionGetInteger(POSITION_MAGIC) != OrdersID || PositionGetString(POSITION_SYMBOL) != SymbolTrade) return false;
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   ENUM_ORDER_TYPE closeType = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   double volume = NormalizeTradeVolume(PositionGetDouble(POSITION_VOLUME));
   if(volume <= 0) return false;
   double exposureBefore = GetRecoveryExposure(type);
   double bid = SymbolInfoDouble(SymbolTrade, SYMBOL_BID), ask = SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return false;
   double price = (closeType == ORDER_TYPE_BUY) ? ask : bid;
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL; req.position = ticket; req.symbol = SymbolTrade; req.magic = OrdersID; req.volume = volume; req.type = closeType; req.price = price; req.deviation = 10; req.type_filling = GetSafeFillingMode();
   ResetLastError();
   bool sent = OrderSend(req, res);
   if(sent && IsMarketTradeSuccess(res.retcode))
   {
      LastRecoveryAction = TimeCurrent();
      FreezeGridUntil = TimeCurrent() + RecoveryFreezeSec;
      RecoveryActionThisTick = true;
      double exposureAfter = GetRecoveryExposure(type);
      double exposureReduced = exposureBefore - exposureAfter;
      PrintFormat("[REE] Exposure Reduced #%I64u | Side=%s | Requested=%.8f | ActualReduced=%.8f | Exposure %.8f -> %.8f | RetCode=%u", ticket, EnumToString(type), volume, exposureReduced, exposureBefore, exposureAfter, res.retcode);
      if(exposureReduced <= 0.00000001) PrintFormat("[REE] WARNING: trade reported success but exposure did not decrease | Ticket=#%I64u", ticket);
      return true;
   }
   PrintFormat("[REE] Exposure Reduction Failed #%I64u | Sent=%s | RetCode=%u | Comment=%s | Error=%d", ticket, sent ? "true" : "false", res.retcode, res.comment, GetLastError());
   return false;
}

//================================================================================================//
void RecoveryExitEngine(double currentDrawdown)
{
   if(!UseRecoveryExit || CurrentRecoveryState == RECOVERY_OFF) return;
   if(currentDrawdown < RecoveryStartDD) return;
   if((TimeCurrent() - LastRecoveryAction) < RecoveryCooldownSec) return;

   double bid = SymbolInfoDouble(SymbolTrade, SYMBOL_BID), ask = SymbolInfoDouble(SymbolTrade, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return;

   bool survivalMode = (currentDrawdown >= SurvivalDD);

   PrintFormat("[RECOVERY] EVALUATE | DD=%.2f%% | State=%s | BUY=%d SELL=%d | Exposure BUY=%.8f SELL=%.8f | BasketLoss BUY=%.2f SELL=%.2f | Survival=%s", currentDrawdown, CurrentRecoveryState == RECOVERY_ACTIVE ? "ACTIVE" : "MONITOR", BuyOrders, SellOrders, GetRecoveryExposure(POSITION_TYPE_BUY), GetRecoveryExposure(POSITION_TYPE_SELL), GetRecoveryBasketLoss(POSITION_TYPE_BUY), GetRecoveryBasketLoss(POSITION_TYPE_SELL), survivalMode ? "ON" : "OFF");

   if(BuyOrders >= 1 && BuyProfits < 0)
   {
      double retrace = 0.0;
      bool reductionTrigger = false;
      bool lastPositionSurvival = (survivalMode && BuyOrders == 1);

      if(survivalMode)
      {
         reductionTrigger = true;
         if(lastPositionSurvival)
            PrintFormat("[RECOVERY] BUY LAST POSITION SURVIVAL CLOSE | DD=%.2f%% >= SurvivalDD=%.2f%% | Retracement BYPASSED | Loss=%.2f", currentDrawdown, SurvivalDD, -BuyProfits);
         else
            PrintFormat("[RECOVERY] BUY SURVIVAL REDUCE | DD=%.2f%% >= SurvivalDD=%.2f%% | Retracement BYPASSED | BasketLoss=%.2f | WorstProfit=%.2f", currentDrawdown, SurvivalDD, GetRecoveryBasketLoss(POSITION_TYPE_BUY), BuyProfits);
      }
      else
      {
         if(BuyOrders >= 2)
         {
            if(LowestPriceAfterBuy == 0) LowestPriceAfterBuy = bid;
            if(bid < LowestPriceAfterBuy) LowestPriceAfterBuy = bid;
            retrace = (bid - LowestPriceAfterBuy) / _Point;
            reductionTrigger = (retrace >= RetraceTriggerPoints);
            PrintFormat("[RECOVERY] BUY CHECK | Retrace=%.1f/%g | Lowest=%.5f | BasketLoss=%.2f | WorstProfit=%.2f", retrace, RetraceTriggerPoints, LowestPriceAfterBuy, GetRecoveryBasketLoss(POSITION_TYPE_BUY), BuyProfits);
         }
         else
         {
            LowestPriceAfterBuy = 0;
            PrintFormat("[RECOVERY] BUY SINGLE POSITION | DD=%.2f%% | Survival=OFF | Waiting for SurvivalDD=%.2f%%", currentDrawdown, SurvivalDD);
         }
      }

      if(reductionTrigger)
      {
         double basketLoss = GetRecoveryBasketLoss(POSITION_TYPE_BUY);
         bool allowBelowMinLoss = survivalMode || (basketLoss >= MinRecoveryLossUSD);
         ulong ticket = FindBestRecoveryPosition(POSITION_TYPE_BUY, allowBelowMinLoss);
         bool canClose = (ticket > 0 && (BuyOrders > 1 || lastPositionSurvival));
         if(canClose)
         {
            double exposureBefore = GetRecoveryExposure(POSITION_TYPE_BUY);
            if(CloseRecoveryPosition(ticket))
            {
               LowestPriceAfterBuy = bid;
               if(lastPositionSurvival)
               {
                  CurrentRecoveryState = RECOVERY_COOLDOWN;
                  PrintFormat("[RECOVERY] BUY LAST POSITION CLOSED | DD=%.2f%% | Loss=%.2f | Exposure %.8f -> %.8f | Survival=ON | New entries blocked until %s", currentDrawdown, -BuyProfits, exposureBefore, GetRecoveryExposure(POSITION_TYPE_BUY), TimeToString(FreezeGridUntil, TIME_DATE|TIME_SECONDS));
               }
               else
               {
                  CurrentRecoveryState = RECOVERY_COOLDOWN;
                  PrintFormat("[RECOVERY] BUY REDUCED | DD=%.2f%% | Retrace=%s | BasketLoss=%.2f | Exposure %.8f -> %.8f | Survival=%s | MinLossGate=%s", currentDrawdown, survivalMode ? "BYPASSED" : DoubleToString(retrace, 1), basketLoss, exposureBefore, GetRecoveryExposure(POSITION_TYPE_BUY), survivalMode ? "ON" : "OFF", allowBelowMinLoss ? "BYPASSED" : "ACTIVE");
               }
               return;
            }
         }
         else PrintFormat("[RECOVERY] BUY NO REDUCTION | EligibleTicket=%I64u | BasketLoss=%.2f | MinGate=%s | Survival=%s | LastPosition=%s", ticket, basketLoss, allowBelowMinLoss ? "BYPASSED" : "ACTIVE", survivalMode ? "ON" : "OFF", lastPositionSurvival ? "YES" : "NO");
      }
   }
   else LowestPriceAfterBuy = 0;

   if(SellOrders >= 1 && SellProfits < 0)
   {
      double retrace = 0.0;
      bool reductionTrigger = false;
      bool lastPositionSurvival = (survivalMode && SellOrders == 1);

      if(survivalMode)
      {
         reductionTrigger = true;
         if(lastPositionSurvival)
            PrintFormat("[RECOVERY] SELL LAST POSITION SURVIVAL CLOSE | DD=%.2f%% >= SurvivalDD=%.2f%% | Retracement BYPASSED | Loss=%.2f", currentDrawdown, SurvivalDD, -SellProfits);
         else
            PrintFormat("[RECOVERY] SELL SURVIVAL REDUCE | DD=%.2f%% >= SurvivalDD=%.2f%% | Retracement BYPASSED | BasketLoss=%.2f | WorstProfit=%.2f", currentDrawdown, SurvivalDD, GetRecoveryBasketLoss(POSITION_TYPE_SELL), SellProfits);
      }
      else
      {
         if(SellOrders >= 2)
         {
            if(HighestPriceAfterSell == 0) HighestPriceAfterSell = ask;
            if(ask > HighestPriceAfterSell) HighestPriceAfterSell = ask;
            retrace = (HighestPriceAfterSell - ask) / _Point;
            reductionTrigger = (retrace >= RetraceTriggerPoints);
            PrintFormat("[RECOVERY] SELL CHECK | Retrace=%.1f/%g | Highest=%.5f | BasketLoss=%.2f | WorstProfit=%.2f", retrace, RetraceTriggerPoints, HighestPriceAfterSell, GetRecoveryBasketLoss(POSITION_TYPE_SELL), SellProfits);
         }
         else
         {
            HighestPriceAfterSell = 0;
            PrintFormat("[RECOVERY] SELL SINGLE POSITION | DD=%.2f%% | Survival=OFF | Waiting for SurvivalDD=%.2f%%", currentDrawdown, SurvivalDD);
         }
      }

      if(reductionTrigger)
      {
         double basketLoss = GetRecoveryBasketLoss(POSITION_TYPE_SELL);
         bool allowBelowMinLoss = survivalMode || (basketLoss >= MinRecoveryLossUSD);
         ulong ticket = FindBestRecoveryPosition(POSITION_TYPE_SELL, allowBelowMinLoss);
         bool canClose = (ticket > 0 && (SellOrders > 1 || lastPositionSurvival));
         if(canClose)
         {
            double exposureBefore = GetRecoveryExposure(POSITION_TYPE_SELL);
            if(CloseRecoveryPosition(ticket))
            {
               HighestPriceAfterSell = ask;
               if(lastPositionSurvival)
               {
                  CurrentRecoveryState = RECOVERY_COOLDOWN;
                  PrintFormat("[RECOVERY] SELL LAST POSITION CLOSED | DD=%.2f%% | Loss=%.2f | Exposure %.8f -> %.8f | Survival=ON | New entries blocked until %s", currentDrawdown, -SellProfits, exposureBefore, GetRecoveryExposure(POSITION_TYPE_SELL), TimeToString(FreezeGridUntil, TIME_DATE|TIME_SECONDS));
               }
               else
               {
                  CurrentRecoveryState = RECOVERY_COOLDOWN;
                  PrintFormat("[RECOVERY] SELL REDUCED | DD=%.2f%% | Retrace=%s | BasketLoss=%.2f | Exposure %.8f -> %.8f | Survival=%s | MinLossGate=%s", currentDrawdown, survivalMode ? "BYPASSED" : DoubleToString(retrace, 1), basketLoss, exposureBefore, GetRecoveryExposure(POSITION_TYPE_SELL), survivalMode ? "ON" : "OFF", allowBelowMinLoss ? "BYPASSED" : "ACTIVE");
               }
               return;
            }
         }
         else PrintFormat("[RECOVERY] SELL NO REDUCTION | EligibleTicket=%I64u | BasketLoss=%.2f | MinGate=%s | Survival=%s | LastPosition=%s", ticket, basketLoss, allowBelowMinLoss ? "BYPASSED" : "ACTIVE", survivalMode ? "ON" : "OFF", lastPositionSurvival ? "YES" : "NO");
      }
   }
   else HighestPriceAfterSell = 0;
}

//================================================================================================//
void DisplayDashboard(double dd, double rsi, bool recovery)
{
   string mode = recovery ? "RECOVERY MODE (Aggressive)" : "NORMAL GROWTH";
   string recoveryState = "OFF";
   if(CurrentRecoveryState == RECOVERY_MONITOR) recoveryState = "MONITOR";
   if(CurrentRecoveryState == RECOVERY_ACTIVE) recoveryState = "ACTIVE";
   if(CurrentRecoveryState == RECOVERY_COOLDOWN) recoveryState = "COOLDOWN";
   Comment("======== GRID RECOVERY GRID A New Grid V1 ========\n", "Status : ", (IsTerminated ? "TERMINATED" : "RUNNING"), "\n", "Mode : ", mode, "\n", "Recovery : ", recoveryState, "\n", "Drawdown : ", DoubleToString(dd, 2), "%\n", "Adaptive Base : ", DoubleToString(AdaptiveEquityBase, 2), "\n", "Locked Profit : ", DoubleToString(LockedProfit, 2), "\n", "RSI (14) : ", DoubleToString(rsi, 2), "\n", "----------------------------------\n", "Buy Lapis: ", BuyOrders, " | Profit: ", DoubleToString(BuyProfits, 2), "\n", "Sell Lapis: ", SellOrders, " | Profit: ", DoubleToString(SellProfits, 2), "\n", "==================================");
}
//================================================================================================//