//================================================================================================//
// GRIDMaster - RECOVERY & PROTECTION EDITION 2026
// v6.017 - PRE-HARD + AGGRESSIVE RECOVERY + EXPOSURE-AWARE PROTECTION
//================================================================================================//
#property strict
#property copyright "Copyright 2026, Jarvis"
#property version   "6.017"

enum Type {Open_Buy_And_Sell, Open__Only_Buy, Open__Only_Sell};
enum RecoveryState { RECOVERY_OFF=0, RECOVERY_MONITOR, RECOVERY_ACTIVE, RECOVERY_COOLDOWN, RECOVERY_SURVIVAL, RECOVERY_PREHARD };

input string SafeParameters       = "||========== SAFETY & RECOVERY ==========||";
input double MaxEquityLossPercent = 15.0;
input double PreHardDD            = 13.5;
input double EmergencyDD         = 14.5;
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

input string Recovery_Settings    = "||========== RECOVERY EXIT ENGINE ==========||";
input bool   UseRecoveryExit      = true;
input double RecoveryStartDD      = 8.0;
input double AggressiveRecoveryDD = 10.0;
input double SurvivalDD           = 12.0;
input double RetraceTriggerPoints = 500.0;
input int    RecoveryCooldownSec  = 180;
input int    RecoveryFreezeSec    = 180;
input double MinRecoveryLossUSD   = 20.0;

input string TradingHourSettings  = "||========== TRADING HOURS ==========||";
input bool   UseTradingHour       = true;
input int    StartHour            = 7;
input int    EndHour              = 22;

string SymbolTrade;
int OrdersID, HandleRSI, HandleMA;
int BuyOrders, SellOrders;
double BuyProfits, SellProfits;
double PriceOpenLastBuy, PriceOpenLastSell;

bool IsTerminated=false;
bool HardProtectionActive=false;
bool RecoveryActionThisTick=false;
datetime FreezeGridUntil=0;
datetime LastRecoveryAction=0;
double HighWaterMark=0;
double InitialBalance=0;
double AdaptiveEquityBase=0;
double LockedProfit=0;
double MaxBuyProfitSeen=0;
double MaxSellProfitSeen=0;
double LowestPriceAfterBuy=0;
double HighestPriceAfterSell=0;
RecoveryState CurrentRecoveryState=RECOVERY_OFF;

bool IsTradingHour()
{
   if(!UseTradingHour) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(StartHour<EndHour) return (dt.hour>=StartHour && dt.hour<EndHour);
   return (dt.hour>=StartHour || dt.hour<EndHour);
}

int OnInit()
{
   SymbolTrade=_Symbol;
   OrdersID=(MagicNumber==0)?101010:MagicNumber;
   HandleRSI=iRSI(SymbolTrade,PERIOD_CURRENT,RSIPeriod,PRICE_CLOSE);
   HandleMA=iMA(SymbolTrade,PERIOD_CURRENT,MAPeriod,0,MODE_SMA,PRICE_CLOSE);
   InitialBalance=AccountInfoDouble(ACCOUNT_BALANCE);
   AdaptiveEquityBase=InitialBalance;
   HighWaterMark=InitialBalance;
   if(HandleRSI==INVALID_HANDLE || HandleMA==INVALID_HANDLE)
   {
      Print("[INIT] Indicator initialization failed");
      return INIT_FAILED;
   }
   PrintFormat("[INIT] GRIDMaster v6.017 | Balance=%.2f | Hard=%.2f%% | PreHard=%.2f%% | Emergency=%.2f%% | AggressiveRecovery=%.2f%%",InitialBalance,MaxEquityLossPercent,PreHardDD,EmergencyDD,AggressiveRecoveryDD);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(HandleRSI!=INVALID_HANDLE) IndicatorRelease(HandleRSI);
   if(HandleMA!=INVALID_HANDLE) IndicatorRelease(HandleMA);
   Comment("");
}

void OnTick()
{
   if(IsTerminated) return;
   RecoveryActionThisTick=false;
   UpdateStatus();

   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   LockedProfit=balance-InitialBalance;
   if(LockedProfit<0) LockedProfit=0;
   AdaptiveEquityBase=InitialBalance+LockedProfit;
   if(balance>HighWaterMark) HighWaterMark=balance;

   double dd=0.0;
   if(AdaptiveEquityBase>0 && equity<AdaptiveEquityBase)
      dd=((AdaptiveEquityBase-equity)/AdaptiveEquityBase)*100.0;
   bool inRecovery=(balance<HighWaterMark);

   // HARD LATCH. Highest priority. No recovery or order placement may run after this point.
   if(dd>=MaxEquityLossPercent) HardProtectionActive=true;

   if(HardProtectionActive)
   {
      PrintFormat("[PROTECTION] HARD LATCH | DD=%.2f%% | BUY=%d SELL=%d | Equity=%.2f",dd,BuyOrders,SellOrders,equity);
      CloseAllOrders();
      UpdateStatus();
      if(BuyOrders==0 && SellOrders==0)
      {
         IsTerminated=true;
         CurrentRecoveryState=RECOVERY_OFF;
         Print("[PROTECTION] HARD COMPLETE | All managed positions closed | EA LOCKED");
      }
      DisplayDashboard(dd,GetRSIValue(),inRecovery);
      return;
   }

   // PRE-HARD: remove new exposure and flatten losing exposure before the hard threshold.
   if(dd>=EmergencyDD)
   {
      CurrentRecoveryState=RECOVERY_PREHARD;
      PrintFormat("[PROTECTION] EMERGENCY REDUCTION | DD=%.2f%% >= %.2f%% | New entries blocked",dd,EmergencyDD);
      CloseAllLosingPositions();
      UpdateStatus();
      if(BuyOrders==0 && SellOrders==0)
      {
         IsTerminated=true;
         Print("[PROTECTION] EMERGENCY COMPLETE | No managed exposure remains | EA LOCKED");
      }
      DisplayDashboard(dd,GetRSIValue(),inRecovery);
      return;
   }

   if(dd>=PreHardDD)
   {
      CurrentRecoveryState=RECOVERY_PREHARD;
      PrintFormat("[PROTECTION] PRE-HARD | DD=%.2f%% >= %.2f%% | New entries blocked | Reducing losing exposure",dd,PreHardDD);
      if((TimeCurrent()-LastRecoveryAction)>=RecoveryCooldownSec)
         ReduceLargestLosingExposure(true);
      DisplayDashboard(dd,GetRSIValue(),inRecovery);
      return;
   }

   UpdateRecoveryState(dd);
   ManageExit(inRecovery);
   UpdateStatus();
   RecoveryExitEngine(dd);
   UpdateStatus();

   if(RecoveryActionThisTick)
   {
      PrintFormat("[ORDER BLOCK] Recovery action this tick | State=%s | FreezeUntil=%s",RecoveryStateText(),TimeToString(FreezeGridUntil,TIME_DATE|TIME_SECONDS));
      DisplayDashboard(dd,GetRSIValue(),inRecovery);
      return;
   }

   // HARD ORDER GATE. This is evaluated immediately before every possible new order.
   bool orderPlacementAllowed=!HardProtectionActive && !IsTerminated &&
      CurrentRecoveryState==RECOVERY_OFF && TimeCurrent()>=FreezeGridUntil &&
      dd<PreHardDD && IsTradingHour() &&
      TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && MQLInfoInteger(MQL_TRADE_ALLOWED);

   double rsi=GetRSIValue();
   double ma=GetMAValue();
   double price=SymbolInfoDouble(SymbolTrade,SYMBOL_BID);

   if(orderPlacementAllowed)
   {
      int lowRSI=inRecovery?(RSILower-5):RSILower;
      int highRSI=inRecovery?(RSIUpper+5):RSIUpper;
      bool canBuy=false,canSell=false;

      if(BuyOrders==0 && (TypeOrdersPlace==Open_Buy_And_Sell || TypeOrdersPlace==Open__Only_Buy))
         if(price>ma && rsi<lowRSI) canBuy=true;
      if(SellOrders==0 && (TypeOrdersPlace==Open_Buy_And_Sell || TypeOrdersPlace==Open__Only_Sell))
         if(price<ma && rsi>highRSI) canSell=true;

      if(BuyOrders>0 && BuyOrders<MaxOrders)
      {
         double gap=PointsForFirstGap*MathPow(GapMultiplier,BuyOrders-1);
         if(SymbolInfoDouble(SymbolTrade,SYMBOL_ASK)<=PriceOpenLastBuy-gap*_Point) canBuy=true;
      }
      if(SellOrders>0 && SellOrders<MaxOrders)
      {
         double gap=PointsForFirstGap*MathPow(GapMultiplier,SellOrders-1);
         if(price>=PriceOpenLastSell+gap*_Point) canSell=true;
      }

      if(canBuy) ExecuteTrade(ORDER_TYPE_BUY);
      if(canSell) ExecuteTrade(ORDER_TYPE_SELL);
   }
   else if(TimeCurrent()<FreezeGridUntil)
      PrintFormat("[ORDER BLOCK] Freeze active until %s",TimeToString(FreezeGridUntil,TIME_DATE|TIME_SECONDS));

   DisplayDashboard(dd,rsi,inRecovery);
}

void UpdateRecoveryState(double dd)
{
   if(!UseRecoveryExit || BuyOrders+SellOrders==0)
   {
      CurrentRecoveryState=RECOVERY_OFF;
      LowestPriceAfterBuy=0; HighestPriceAfterSell=0;
      return;
   }
   if(CurrentRecoveryState==RECOVERY_COOLDOWN)
   {
      if(TimeCurrent()<FreezeGridUntil) return;
      CurrentRecoveryState=(dd>=RecoveryStartDD)?RECOVERY_ACTIVE:RECOVERY_OFF;
      return;
   }
   if(dd<RecoveryStartDD)
   {
      CurrentRecoveryState=RECOVERY_OFF;
      LowestPriceAfterBuy=0; HighestPriceAfterSell=0;
      return;
   }
   if(dd>=SurvivalDD) CurrentRecoveryState=RECOVERY_SURVIVAL;
   else if(dd>=AggressiveRecoveryDD) CurrentRecoveryState=RECOVERY_ACTIVE;
   else CurrentRecoveryState=RECOVERY_MONITOR;
}

void ManageExit(bool recovery)
{
   double target=recovery?(TargetProfitUSD+2.0):TargetProfitUSD;
   if(BuyOrders==0) MaxBuyProfitSeen=0;
   if(SellOrders==0) MaxSellProfitSeen=0;

   if(BuyOrders>0)
   {
      if(!UseTrailingProfit)
      {
         if(BuyProfits>=target) CloseOrdersByType(POSITION_TYPE_BUY);
      }
      else
      {
         if(BuyProfits>=TrailingStartUSD && BuyProfits>MaxBuyProfitSeen) MaxBuyProfitSeen=BuyProfits;
         if(MaxBuyProfitSeen>=TrailingStartUSD && BuyProfits<=MaxBuyProfitSeen-TrailingStopUSD) CloseOrdersByType(POSITION_TYPE_BUY);
      }
   }
   if(SellOrders>0)
   {
      if(!UseTrailingProfit)
      {
         if(SellProfits>=target) CloseOrdersByType(POSITION_TYPE_SELL);
      }
      else
      {
         if(SellProfits>=TrailingStartUSD && SellProfits>MaxSellProfitSeen) MaxSellProfitSeen=SellProfits;
         if(MaxSellProfitSeen>=TrailingStartUSD && SellProfits<=MaxSellProfitSeen-TrailingStopUSD) CloseOrdersByType(POSITION_TYPE_SELL);
      }
   }
}

void UpdateStatus()
{
   BuyOrders=0; SellOrders=0; BuyProfits=0; SellProfits=0; PriceOpenLastBuy=0; PriceOpenLastSell=0;
   datetime latestBuy=0,latestSell=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=OrdersID || PositionGetString(POSITION_SYMBOL)!=SymbolTrade) continue;
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double profit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      datetime openTime=(datetime)PositionGetInteger(POSITION_TIME);
      double openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
      if(type==POSITION_TYPE_BUY)
      {
         BuyOrders++; BuyProfits+=profit;
         if(openTime>=latestBuy){latestBuy=openTime;PriceOpenLastBuy=openPrice;}
      }
      else if(type==POSITION_TYPE_SELL)
      {
         SellOrders++; SellProfits+=profit;
         if(openTime>=latestSell){latestSell=openTime;PriceOpenLastSell=openPrice;}
      }
   }
   if(BuyOrders==0) MaxBuyProfitSeen=0;
   if(SellOrders==0) MaxSellProfitSeen=0;
}

double GetRSIValue()
{
   double b[]; ArraySetAsSeries(b,true);
   return (CopyBuffer(HandleRSI,0,0,1,b)>0)?b[0]:50.0;
}

double GetMAValue()
{
   double b[]; ArraySetAsSeries(b,true);
   return (CopyBuffer(HandleMA,0,0,1,b)>0)?b[0]:0.0;
}

bool IsMarketTradeSuccess(uint retcode)
{
   return retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL;
}

ENUM_ORDER_TYPE_FILLING GetSafeFillingMode()
{
   long filling=0;
   if(SymbolInfoInteger(SymbolTrade,SYMBOL_FILLING_MODE,filling))
   {
      if((filling&SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
      if((filling&SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   }
   long execution=0; SymbolInfoInteger(SymbolTrade,SYMBOL_TRADE_EXEMODE,execution);
   if(execution!=SYMBOL_TRADE_EXECUTION_MARKET) return ORDER_FILLING_RETURN;
   return ORDER_FILLING_FOK;
}

int GetVolumeDigits()
{
   double step=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_STEP);
   int d=0;
   while(d<8 && MathAbs(step-NormalizeDouble(step,d))>0.00000001) d++;
   return d;
}

double NormalizeTradeVolume(double requested)
{
   double minV=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MIN);
   double maxV=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_STEP);
   if(minV<=0 || maxV<=0 || step<=0 || requested<minV-1e-10) return 0.0;
   double v=MathMin(requested,maxV);
   v=MathFloor((v+1e-10)/step)*step;
   if(v<minV-1e-10) return 0.0;
   return NormalizeDouble(v,GetVolumeDigits());
}

bool IsTradeEnvironmentSafe(ENUM_ORDER_TYPE type,double &price)
{
   if(!SymbolSelect(SymbolTrade,true)) return false;
   ENUM_SYMBOL_TRADE_MODE mode=(ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(SymbolTrade,SYMBOL_TRADE_MODE);
   if(mode==SYMBOL_TRADE_MODE_DISABLED || mode==SYMBOL_TRADE_MODE_CLOSEONLY) return false;
   double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID),ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   if(bid<=0 || ask<=0 || ask<bid) return false;
   price=(type==ORDER_TYPE_BUY)?ask:bid;
   return price>0;
}

void ExecuteTrade(ENUM_ORDER_TYPE type)
{
   // Final safety gate: protection is rechecked immediately before OrderSend.
   if(HardProtectionActive || IsTerminated || CurrentRecoveryState!=RECOVERY_OFF || TimeCurrent()<FreezeGridUntil) return;
   double price=0; if(!IsTradeEnvironmentSafe(type,price)) return;
   int count=(type==ORDER_TYPE_BUY)?BuyOrders:SellOrders;
   double volume=NormalizeTradeVolume(ManualLotSize*(count+1));
   if(volume<=0) return;
   MqlTradeRequest req={}; MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL; req.symbol=SymbolTrade; req.magic=OrdersID; req.volume=volume; req.type=type; req.price=price; req.deviation=10; req.type_filling=GetSafeFillingMode(); req.comment=CommentsOrders;
   ResetLastError();
   if(!OrderSend(req,res) || !IsMarketTradeSuccess(res.retcode))
   {
      PrintFormat("[OPEN] FAILED | Type=%s | RetCode=%u | Comment=%s | Error=%d",EnumToString(type),res.retcode,res.comment,GetLastError());
      return;
   }
   PrintFormat("[OPEN] SUCCESS | Type=%s | Volume=%.8f | RetCode=%u | Deal=%I64u",EnumToString(type),res.volume,res.retcode,res.deal);
}

bool ClosePositionTicket(ulong ticket)
{
   if(ticket==0 || !PositionSelectByTicket(ticket)) return false;
   if(PositionGetInteger(POSITION_MAGIC)!=OrdersID || PositionGetString(POSITION_SYMBOL)!=SymbolTrade) return false;
   ENUM_POSITION_TYPE ptype=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   ENUM_ORDER_TYPE ctype=(ptype==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
   double volume=NormalizeTradeVolume(PositionGetDouble(POSITION_VOLUME));
   if(volume<=0) return false;
   double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID),ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   if(bid<=0 || ask<=0) return false;
   double price=(ctype==ORDER_TYPE_BUY)?ask:bid;
   MqlTradeRequest req={}; MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL; req.position=ticket; req.symbol=SymbolTrade; req.magic=OrdersID; req.volume=volume; req.type=ctype; req.price=price; req.deviation=10; req.type_filling=GetSafeFillingMode();
   ResetLastError();
   bool sent=OrderSend(req,res);
   if(!sent || !IsMarketTradeSuccess(res.retcode))
   {
      PrintFormat("[CLOSE] FAILED #%I64u | RetCode=%u | Comment=%s | Error=%d",ticket,res.retcode,res.comment,GetLastError());
      return false;
   }
   PrintFormat("[CLOSE] SUCCESS #%I64u | Volume=%.8f | RetCode=%u",ticket,res.volume,res.retcode);
   return true;
}

void CloseOrdersByType(ENUM_POSITION_TYPE type)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=OrdersID || PositionGetString(POSITION_SYMBOL)!=SymbolTrade) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=type) continue;
      ClosePositionTicket(ticket);
   }
}

void CloseAllOrders()
{
   CloseOrdersByType(POSITION_TYPE_BUY);
   CloseOrdersByType(POSITION_TYPE_SELL);
}

void CloseAllLosingPositions()
{
   for(int pass=0;pass<2;pass++)
   {
      bool closed=false;
      ulong ticket=FindLargestLosingPosition();
      if(ticket==0) break;
      if(ClosePositionTicket(ticket)) closed=true;
      if(!closed) break;
   }
}

double GetRecoveryBasketLoss(ENUM_POSITION_TYPE type)
{
   double p=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=OrdersID || PositionGetString(POSITION_SYMBOL)!=SymbolTrade) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=type) continue;
      p+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }
   return p<0?-p:0;
}

double GetRecoveryExposure(ENUM_POSITION_TYPE type)
{
   double e=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=OrdersID || PositionGetString(POSITION_SYMBOL)!=SymbolTrade) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=type) continue;
      e+=PositionGetDouble(POSITION_VOLUME);
   }
   return e;
}

ulong FindLargestLosingPosition()
{
   ulong best=0; double bestVolume=0,bestLoss=0; datetime oldest=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=OrdersID || PositionGetString(POSITION_SYMBOL)!=SymbolTrade) continue;
      double profit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(profit>=0) continue;
      double loss=-profit,volume=PositionGetDouble(POSITION_VOLUME);
      datetime ot=(datetime)PositionGetInteger(POSITION_TIME);
      if(volume>bestVolume+1e-8 || (MathAbs(volume-bestVolume)<=1e-8 && loss>bestLoss+1e-8) || (MathAbs(volume-bestVolume)<=1e-8 && MathAbs(loss-bestLoss)<=1e-8 && (oldest==0 || ot<oldest)))
      {best=t;bestVolume=volume;bestLoss=loss;oldest=ot;}
   }
   return best;
}

ulong FindBestRecoveryPosition(ENUM_POSITION_TYPE type,bool allowBelowMinLoss)
{
   ulong best=0; double bestVolume=0,bestLoss=0; datetime oldest=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=OrdersID || PositionGetString(POSITION_SYMBOL)!=SymbolTrade) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=type) continue;
      double profit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(profit>=0) continue;
      double loss=-profit,volume=PositionGetDouble(POSITION_VOLUME); datetime ot=(datetime)PositionGetInteger(POSITION_TIME);
      if(volume>bestVolume+1e-8 || (MathAbs(volume-bestVolume)<=1e-8 && loss>bestLoss+1e-8) || (MathAbs(volume-bestVolume)<=1e-8 && MathAbs(loss-bestLoss)<=1e-8 && (oldest==0 || ot<oldest)))
      {best=t;bestVolume=volume;bestLoss=loss;oldest=ot;}
   }
   if(best>0 && bestLoss<MinRecoveryLossUSD && !allowBelowMinLoss) return 0;
   return best;
}

bool ReduceLargestLosingExposure(bool preHard)
{
   ulong ticket=FindLargestLosingPosition();
   if(ticket==0) return false;
   double before=0; ENUM_POSITION_TYPE type=POSITION_TYPE_BUY;
   if(PositionSelectByTicket(ticket))
   {
      type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      before=GetRecoveryExposure(type);
   }
   bool ok=ClosePositionTicket(ticket);
   if(ok)
   {
      LastRecoveryAction=TimeCurrent();
      FreezeGridUntil=TimeCurrent()+RecoveryFreezeSec;
      RecoveryActionThisTick=true;
      double after=GetRecoveryExposure(type);
      PrintFormat("[PROTECTION] %s REDUCE | Ticket=#%I64u | Exposure %.8f -> %.8f | Reduced=%.8f | Freeze=%ds",preHard?"PRE-HARD":"RECOVERY",ticket,before,after,before-after,RecoveryFreezeSec);
   }
   return ok;
}

void RecoveryExitEngine(double dd)
{
   if(!UseRecoveryExit || CurrentRecoveryState==RECOVERY_OFF || dd<RecoveryStartDD) return;
   if((TimeCurrent()-LastRecoveryAction)<RecoveryCooldownSec) return;
   if(BuyOrders+SellOrders==0) return;

   bool survival=(dd>=SurvivalDD);
   bool aggressive=(dd>=AggressiveRecoveryDD);
   bool allowBelowMin=(aggressive||survival);

   // At 10% DD we deliberately remove retracement dependency. At 12% we force survival reduction.
   if(aggressive)
   {
      PrintFormat("[RECOVERY] AGGRESSIVE | DD=%.2f%% | Survival=%s | Exposure BUY=%.8f SELL=%.8f | BasketLoss BUY=%.2f SELL=%.2f",dd,survival?"ON":"OFF",GetRecoveryExposure(POSITION_TYPE_BUY),GetRecoveryExposure(POSITION_TYPE_SELL),GetRecoveryBasketLoss(POSITION_TYPE_BUY),GetRecoveryBasketLoss(POSITION_TYPE_SELL));
      if(ReduceLargestLosingExposure(false))
      {
         CurrentRecoveryState=survival?RECOVERY_SURVIVAL:RECOVERY_COOLDOWN;
         return;
      }
      return;
   }

   // Normal 8-10% recovery retains retracement logic, but still uses exposure-aware selection.
   double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID),ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   if(bid<=0 || ask<=0) return;

   if(BuyOrders>=2 && BuyProfits<0)
   {
      if(LowestPriceAfterBuy==0) LowestPriceAfterBuy=bid;
      if(bid<LowestPriceAfterBuy) LowestPriceAfterBuy=bid;
      double retrace=(bid-LowestPriceAfterBuy)/_Point;
      double basket=GetRecoveryBasketLoss(POSITION_TYPE_BUY);
      if(retrace>=RetraceTriggerPoints && (basket>=MinRecoveryLossUSD || allowBelowMin))
      {
         ulong t=FindBestRecoveryPosition(POSITION_TYPE_BUY,allowBelowMin);
         if(t>0 && ReduceSpecificRecoveryPosition(t)) return;
      }
   }
   else LowestPriceAfterBuy=0;

   if(SellOrders>=2 && SellProfits<0)
   {
      if(HighestPriceAfterSell==0) HighestPriceAfterSell=ask;
      if(ask>HighestPriceAfterSell) HighestPriceAfterSell=ask;
      double retrace=(HighestPriceAfterSell-ask)/_Point;
      double basket=GetRecoveryBasketLoss(POSITION_TYPE_SELL);
      if(retrace>=RetraceTriggerPoints && (basket>=MinRecoveryLossUSD || allowBelowMin))
      {
         ulong t=FindBestRecoveryPosition(POSITION_TYPE_SELL,allowBelowMin);
         if(t>0 && ReduceSpecificRecoveryPosition(t)) return;
      }
   }
   else HighestPriceAfterSell=0;
}

bool ReduceSpecificRecoveryPosition(ulong ticket)
{
   if(ticket==0 || !PositionSelectByTicket(ticket)) return false;
   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double before=GetRecoveryExposure(type);
   if(!ClosePositionTicket(ticket)) return false;
   LastRecoveryAction=TimeCurrent();
   FreezeGridUntil=TimeCurrent()+RecoveryFreezeSec;
   RecoveryActionThisTick=true;
   double after=GetRecoveryExposure(type);
   PrintFormat("[RECOVERY] EXPOSURE REDUCED | Ticket=#%I64u | Side=%s | %.8f -> %.8f | Reduced=%.8f | Freeze=%ds",ticket,EnumToString(type),before,after,before-after,RecoveryFreezeSec);
   CurrentRecoveryState=RECOVERY_COOLDOWN;
   return true;
}

string RecoveryStateText()
{
   if(CurrentRecoveryState==RECOVERY_MONITOR) return "MONITOR";
   if(CurrentRecoveryState==RECOVERY_ACTIVE) return "ACTIVE";
   if(CurrentRecoveryState==RECOVERY_COOLDOWN) return "COOLDOWN";
   if(CurrentRecoveryState==RECOVERY_SURVIVAL) return "SURVIVAL";
   if(CurrentRecoveryState==RECOVERY_PREHARD) return "PRE-HARD";
   return "OFF";
}

void DisplayDashboard(double dd,double rsi,bool recovery)
{
   Comment("======== GRIDMaster v6.017 ========\n",
      "Status : ",(IsTerminated?"LOCKED":"RUNNING"),"\n",
      "Recovery : ",RecoveryStateText(),"\n",
      "Drawdown : ",DoubleToString(dd,2),"%\n",
      "PreHard : ",DoubleToString(PreHardDD,2),"% | Emergency : ",DoubleToString(EmergencyDD,2),"%\n",
      "Hard : ",DoubleToString(MaxEquityLossPercent,2),"%\n",
      "Freeze : ",TimeToString(FreezeGridUntil,TIME_DATE|TIME_SECONDS),"\n",
      "RSI : ",DoubleToString(rsi,2),"\n",
      "BUY : ",BuyOrders," | Profit: ",DoubleToString(BuyProfits,2),"\n",
      "SELL: ",SellOrders," | Profit: ",DoubleToString(SellProfits,2),"\n",
      "==================================");
}
//================================================================================================//