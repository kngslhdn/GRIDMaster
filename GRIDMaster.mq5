//================================================================================================//
// GRIDMaster - PROFIT PROTECTION / BASKET RECOVERY EDITION 2026
// v7.004 - BASKET EXIT + RECOVERY GOVERNOR FIX
//================================================================================================//
#property strict
#property copyright "Copyright 2026, Jarvis"
#property version   "7.004"

//================================================================================================//
// CORE TYPES
//================================================================================================//
enum Type {Open_Buy_And_Sell, Open__Only_Buy, Open__Only_Sell};
enum ProtectionState {STATE_NORMAL=0,STATE_MONITOR,STATE_REDUCE,STATE_SURVIVAL,STATE_EMERGENCY,STATE_LOCKED};

//================================================================================================//
// SAFETY & PROFIT PROTECTION
//================================================================================================//
input string SafeParameters="||========== SAFETY & PROFIT PROTECTION ==========||";
input double MaxEquityLossPercent=15.0;
input double SoftDDPercent=7.0;
input double ReduceDDPercent=8.5;
input double EmergencyDDPercent=11.5;
input double MaxBasketLossUSD=60.0;
input double MaxTotalExposureLots=0.10;
input bool UseTrailingProfit=true;
input double TrailingStartUSD=6.0;
input double TrailingStopUSD=2.0;

//================================================================================================//
// INDICATORS
//================================================================================================//
input string RSI_Settings="||========== INDICATORS ==========||";
input int MAPeriod=200;
input int RSIPeriod=14;
input int RSIUpper=70;
input int RSILower=30;

//================================================================================================//
// GRID LOGIC
//================================================================================================//
input string Grid_Settings="||========== GRID LOGIC ==========||";
input Type TypeOrdersPlace=Open_Buy_And_Sell;
input double PointsForFirstGap=5000.0;
input double GapMultiplier=1.30;
input double TargetProfitUSD=5.0;
input double ManualLotSize=0.01;
input int MaxOrders=6;
input bool UseProgressiveLots=true;
input double MaxLotMultiplier=4.0;
input int MagicNumber=88888;
input string CommentsOrders="GRID MASTER v7";

//================================================================================================//
// RECOVERY / ANOMALY
//================================================================================================//
input string Recovery_Settings="||========== RECOVERY / ANOMALY ==========||";
input bool UseRecoveryExit=true;
input double RecoveryStartDD=7.0;
input double AggressiveRecoveryDD=8.5;
input double SurvivalDD=10.0;
input int RecoveryCooldownSec=10;
input int RecoveryFreezeSec=20;
input double MinRecoveryLossUSD=15.0;
input double SurvivalBasketLossUSD=45.0;
input int MaxReductionActions=3;
input double AnomalySpreadPoints=500.0;
input double AnomalyJumpPoints=1000.0;
input int AnomalyCooldownSec=60;

//================================================================================================//
// TRADING HOURS
//================================================================================================//
input string TradingHourSettings="||========== TRADING HOURS ==========||";
input bool UseTradingHour=true;
input int StartHour=7;
input int EndHour=22;

//================================================================================================//
// RUNTIME STATE
//================================================================================================//
string SymbolTrade;
int OrdersID,HandleRSI,HandleMA;
int BuyOrders,SellOrders;
double BuyProfits,SellProfits,PriceOpenLastBuy,PriceOpenLastSell;
bool IsTerminated=false,HardProtectionActive=false,RecoveryActionThisTick=false,AnomalyBrakeActive=false;
datetime FreezeGridUntil=0,LastRecoveryAction=0,AnomalyUntil=0,LastLogTime=0;
double InitialBalance=0.0,PeakEquity=0.0,HighWaterMark=0.0;
double MaxBuyProfitSeen=0.0,MaxSellProfitSeen=0.0,MaxBasketProfitSeen=0.0,LastMidPrice=0.0;
int ReductionActions=0;
bool BuyDirectionLocked=false,SellDirectionLocked=false;
ProtectionState CurrentState=STATE_NORMAL;

#define SURVIVAL_REENTRY_FREEZE_SEC 120
#define ANOMALY_RESET_RATIO 0.70

//================================================================================================//
// PROTECTION LIMITS
//================================================================================================//
double HardLimit(){double v=MaxEquityLossPercent;if(v<=0)v=15.0;return MathMin(v,15.0);}
double SoftLimit(){double h=HardLimit(),v=SoftDDPercent;if(v<=0)v=h*0.5;return MathMin(MathMax(v,2.0),h-1.0);}
double ReduceLimit(){double h=HardLimit(),v=ReduceDDPercent;if(v<=0)v=h*0.65;return MathMin(MathMax(v,SoftLimit()+0.5),h-1.5);}
double EmergencyLimit(){double h=HardLimit(),v=EmergencyDDPercent;if(v<=0)v=h-2.0;return MathMin(MathMax(v,ReduceLimit()+1.0),h-0.5);}

double ProtectionDD()
{
   double e=AccountInfoDouble(ACCOUNT_EQUITY),a=0.0,b=0.0;
   if(PeakEquity>0&&e<PeakEquity)a=(PeakEquity-e)/PeakEquity*100.0;
   if(InitialBalance>0&&e<InitialBalance)b=(InitialBalance-e)/InitialBalance*100.0;
   return MathMax(a,b);
}

//================================================================================================//
// MARKET HEALTH - HYSTERESIS
//================================================================================================//
bool MarketHealthy()
{
   double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   double ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   if(bid<=0||ask<=0||ask<bid||_Point<=0)return false;

   datetime now=TimeCurrent();
   double spread=(ask-bid)/_Point;
   double mid=(bid+ask)*0.5;

   if(AnomalyBrakeActive)
   {
      LastMidPrice=mid;
      if(now<AnomalyUntil)return false;

      double resetSpread=AnomalySpreadPoints*ANOMALY_RESET_RATIO;
      if(AnomalySpreadPoints>0&&spread>=resetSpread)return false;

      AnomalyBrakeActive=false;
      AnomalyUntil=0;
   }

   bool anomaly=false;
   if(AnomalySpreadPoints>0&&spread>=AnomalySpreadPoints)anomaly=true;
   else if(LastMidPrice>0&&AnomalyJumpPoints>0&&MathAbs(mid-LastMidPrice)/_Point>=AnomalyJumpPoints)anomaly=true;

   LastMidPrice=mid;

   if(anomaly)
   {
      AnomalyBrakeActive=true;
      AnomalyUntil=now+AnomalyCooldownSec;
      return false;
   }

   return true;
}

bool IsTradingHour()
{
   if(!UseTradingHour)return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   if(StartHour<EndHour)return dt.hour>=StartHour&&dt.hour<EndHour;
   return dt.hour>=StartHour||dt.hour<EndHour;
}

//================================================================================================//
// INITIALIZATION
//================================================================================================//
int OnInit()
{
   SymbolTrade=_Symbol;
   OrdersID=(MagicNumber==0)?101010:MagicNumber;
   HandleRSI=iRSI(SymbolTrade,PERIOD_CURRENT,RSIPeriod,PRICE_CLOSE);
   HandleMA=iMA(SymbolTrade,PERIOD_CURRENT,MAPeriod,0,MODE_SMA,PRICE_CLOSE);

   InitialBalance=AccountInfoDouble(ACCOUNT_BALANCE);
   PeakEquity=MathMax(InitialBalance,AccountInfoDouble(ACCOUNT_EQUITY));
   HighWaterMark=InitialBalance;
   ReductionActions=0;
   LastMidPrice=0.0;
   MaxBasketProfitSeen=0.0;
   BuyDirectionLocked=false;
   SellDirectionLocked=false;
   HardProtectionActive=false;
   IsTerminated=false;
   AnomalyBrakeActive=false;
   CurrentState=STATE_NORMAL;

   if(HandleRSI==INVALID_HANDLE||HandleMA==INVALID_HANDLE)
   {
      Print("[INIT] Indicator initialization failed");
      return INIT_FAILED;
   }

   PrintFormat("[INIT] GRIDMaster v7.004 | Balance=%.2f | Hard=%.2f%% | Soft=%.2f%% | Reduce=%.2f%% | Emergency=%.2f%%",
               InitialBalance,HardLimit(),SoftLimit(),ReduceLimit(),EmergencyLimit());
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(HandleRSI!=INVALID_HANDLE)IndicatorRelease(HandleRSI);
   if(HandleMA!=INVALID_HANDLE)IndicatorRelease(HandleMA);
   Comment("");
}

//================================================================================================//
// MAIN ENGINE
//================================================================================================//
void OnTick()
{
   if(IsTerminated)return;

   RecoveryActionThisTick=false;
   UpdateStatus();

   double e=AccountInfoDouble(ACCOUNT_EQUITY);
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);

   if(e>PeakEquity)
   {
      PeakEquity=e;
      if(ProtectionDD()<SoftLimit())ReductionActions=0;
   }
   if(bal>HighWaterMark)HighWaterMark=bal;

   double dd=ProtectionDD();
   bool healthy=MarketHealthy();

   if(!healthy&&AnomalyBrakeActive&&LastLogTime!=AnomalyUntil)
   {
      LastLogTime=AnomalyUntil;
      PrintFormat("[ANOMALY] BRAKE | Until=%s",TimeToString(AnomalyUntil,TIME_DATE|TIME_SECONDS));
   }

   // HARD DD: absolute final protection.
   if(dd>=HardLimit())HardProtectionActive=true;

   if(HardProtectionActive)
   {
      CurrentState=STATE_LOCKED;
      CloseAllManaged("HARD-DD");
      UpdateStatus();
      if(BuyOrders==0&&SellOrders==0)
      {
         IsTerminated=true;
         Print("[PROTECTION] HARD LOCK COMPLETE");
      }
      Dashboard(dd);
      return;
   }

   // EMERGENCY DD: close all before the hard boundary whenever possible.
   if(dd>=EmergencyLimit())
   {
      CurrentState=STATE_EMERGENCY;
      CloseAllManaged("EMERGENCY-DD");
      UpdateStatus();
      if(BuyOrders==0&&SellOrders==0)
      {
         IsTerminated=true;
         PrintFormat("[PROTECTION] EMERGENCY COMPLETE | DD=%.2f%%",dd);
      }
      Dashboard(dd);
      return;
   }

   // IMPORTANT: profit management is BASKET based.
   // A profitable BUY must NOT be closed while a losing SELL is still being recovered.
   ManageProfitExit();
   UpdateStatus();

   UpdateDirectionLocks();
   UpdateProtectionState(dd);

   if(UseRecoveryExit)
      RecoveryGovernor(dd);

   UpdateStatus();
   UpdateDirectionLocks();

   if(RecoveryActionThisTick)
   {
      Dashboard(dd);
      return;
   }

   bool allowEntry=!HardProtectionActive&&
                   !IsTerminated&&
                   CurrentState==STATE_NORMAL&&
                   dd<SoftLimit()&&
                   TimeCurrent()>=FreezeGridUntil&&
                   !AnomalyBrakeActive&&
                   healthy&&
                   IsTradingHour()&&
                   TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)&&
                   MQLInfoInteger(MQL_TRADE_ALLOWED);

   if(allowEntry)GridEntryEngine();
   Dashboard(dd);
}

//================================================================================================//
// POSITION STATUS
//================================================================================================//
void UpdateStatus()
{
   BuyOrders=SellOrders=0;
   BuyProfits=SellProfits=0.0;
   PriceOpenLastBuy=PriceOpenLastSell=0.0;

   datetime lb=0,ls=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;

      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      datetime ot=(datetime)PositionGetInteger(POSITION_TIME);
      double op=PositionGetDouble(POSITION_PRICE_OPEN);

      if(type==POSITION_TYPE_BUY)
      {
         BuyOrders++;
         BuyProfits+=p;
         if(ot>=lb){lb=ot;PriceOpenLastBuy=op;}
      }
      else if(type==POSITION_TYPE_SELL)
      {
         SellOrders++;
         SellProfits+=p;
         if(ot>=ls){ls=ot;PriceOpenLastSell=op;}
      }
   }

   double basket=BuyProfits+SellProfits;

   if(BuyOrders==0)MaxBuyProfitSeen=0.0;
   if(SellOrders==0)MaxSellProfitSeen=0.0;
   if(BuyOrders==0&&SellOrders==0)
   {
      MaxBasketProfitSeen=0.0;
      ReductionActions=0;
   }
   else if(basket<0.0&&MaxBasketProfitSeen<0.0)
      MaxBasketProfitSeen=0.0;
}

//================================================================================================//
// DIRECTION LOCKS
//================================================================================================//
void UpdateDirectionLocks()
{
   if(BuyOrders==0)BuyDirectionLocked=false;
   if(SellOrders==0)SellDirectionLocked=false;
}

void LockDirection(ENUM_POSITION_TYPE type,string reason)
{
   if(type==POSITION_TYPE_BUY)BuyDirectionLocked=true;
   else if(type==POSITION_TYPE_SELL)SellDirectionLocked=true;
   PrintFormat("[LOCK] %s direction LOCKED | reason=%s",EnumToString(type),reason);
}

bool IsDirectionLocked(ENUM_ORDER_TYPE type)
{
   if(type==ORDER_TYPE_BUY)return BuyDirectionLocked;
   if(type==ORDER_TYPE_SELL)return SellDirectionLocked;
   return true;
}

//================================================================================================//
// GRID ENTRY ENGINE
//================================================================================================//
void GridEntryEngine()
{
   double rsi=GetRSIValue();
   double ma=GetMAValue();
   double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   double ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   if(bid<=0||ask<=0||ma<=0)return;

   bool buy=false,sell=false;

   if(BuyOrders==0&&!BuyDirectionLocked&&
      (TypeOrdersPlace==Open_Buy_And_Sell||TypeOrdersPlace==Open__Only_Buy)&&
      bid>ma&&rsi<RSILower)buy=true;

   if(SellOrders==0&&!SellDirectionLocked&&
      (TypeOrdersPlace==Open_Buy_And_Sell||TypeOrdersPlace==Open__Only_Sell)&&
      bid<ma&&rsi>RSIUpper)sell=true;

   if(BuyOrders>0&&!BuyDirectionLocked&&BuyOrders<MaxOrders)
   {
      double gap=PointsForFirstGap*MathPow(GapMultiplier,BuyOrders-1);
      if(ask<=PriceOpenLastBuy-gap*_Point)buy=true;
   }

   if(SellOrders>0&&!SellDirectionLocked&&SellOrders<MaxOrders)
   {
      double gap=PointsForFirstGap*MathPow(GapMultiplier,SellOrders-1);
      if(bid>=PriceOpenLastSell+gap*_Point)sell=true;
   }

   if(buy)ExecuteOpen(ORDER_TYPE_BUY);
   if(sell)ExecuteOpen(ORDER_TYPE_SELL);
}

double GetRSIValue(){double b[];ArraySetAsSeries(b,true);return CopyBuffer(HandleRSI,0,0,1,b)>0?b[0]:50.0;}
double GetMAValue(){double b[];ArraySetAsSeries(b,true);return CopyBuffer(HandleMA,0,0,1,b)>0?b[0]:0.0;}

//================================================================================================//
// TRADE UTILITIES
//================================================================================================//
int VolumeDigits()
{
   double s=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_STEP);
   int d=0;
   while(d<8&&MathAbs(s-NormalizeDouble(s,d))>1e-10)d++;
   return d;
}

double NormalizeVolume(double v)
{
   double min=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MIN);
   double max=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_STEP);
   if(min<=0||max<=0||step<=0||v<min-1e-10)return 0.0;
   v=MathMin(v,max);
   v=MathFloor((v+1e-10)/step)*step;
   return v>=min-1e-10?NormalizeDouble(v,VolumeDigits()):0.0;
}

double TotalExposureLots()
{
   double x=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;
      x+=PositionGetDouble(POSITION_VOLUME);
   }
   return x;
}

ENUM_ORDER_TYPE_FILLING SafeFilling()
{
   long f=0;
   if(SymbolInfoInteger(SymbolTrade,SYMBOL_FILLING_MODE,f))
   {
      if((f&SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC)return ORDER_FILLING_IOC;
      if((f&SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK)return ORDER_FILLING_FOK;
   }
   long e=0;
   SymbolInfoInteger(SymbolTrade,SYMBOL_TRADE_EXEMODE,e);
   if(e!=SYMBOL_TRADE_EXECUTION_MARKET)return ORDER_FILLING_RETURN;
   return ORDER_FILLING_FOK;
}

bool TradeOK(uint r){return r==TRADE_RETCODE_DONE||r==TRADE_RETCODE_DONE_PARTIAL;}

//================================================================================================//
// OPEN POSITION
//================================================================================================//
void ExecuteOpen(ENUM_ORDER_TYPE type)
{
   double dd=ProtectionDD();
   if(HardProtectionActive||IsTerminated||CurrentState!=STATE_NORMAL||dd>=SoftLimit()||AnomalyBrakeActive||TimeCurrent()<FreezeGridUntil||IsDirectionLocked(type))return;
   if(MaxTotalExposureLots>0&&TotalExposureLots()>=MaxTotalExposureLots-1e-8)return;

   int count=(type==ORDER_TYPE_BUY)?BuyOrders:SellOrders;
   if(count>=MaxOrders)return;

   double mult=UseProgressiveLots?MathMin(count+1.0,MaxLotMultiplier):1.0;
   double reqLot=ManualLotSize*mult;

   if(MaxTotalExposureLots>0)
      reqLot=MathMin(reqLot,MaxTotalExposureLots-TotalExposureLots());

   double vol=NormalizeVolume(reqLot);
   if(vol<=0)return;

   double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   double ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   if(bid<=0||ask<=0||ask<bid)return;

   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL;
   req.symbol=SymbolTrade;
   req.magic=OrdersID;
   req.volume=vol;
   req.type=type;
   req.price=(type==ORDER_TYPE_BUY)?ask:bid;
   req.deviation=20;
   req.type_filling=SafeFilling();
   req.comment=CommentsOrders;

   ResetLastError();
   bool sent=OrderSend(req,res);
   if(!sent||!TradeOK(res.retcode))
   {
      PrintFormat("[OPEN] FAILED | %s | vol=%.4f | rc=%u | %s | err=%d",EnumToString(type),vol,res.retcode,res.comment,GetLastError());
      return;
   }

   PrintFormat("[OPEN] SUCCESS | %s | vol=%.4f | deal=%I64u",EnumToString(type),res.volume,res.deal);
}

//================================================================================================//
// BASKET PROFIT ENGINE - CRITICAL FIX
//================================================================================================//
void ManageProfitExit()
{
   if(BuyOrders+SellOrders==0)return;

   double basketProfit=BuyProfits+SellProfits;

   // PRIMARY EXIT: close the entire basket only when the combined cycle is profitable.
   // This prevents the old behavior where one winning side was closed while the
   // opposite losing side remained open and continued generating large losses.
   if(TargetProfitUSD>0.0&&basketProfit>=TargetProfitUSD)
   {
      PrintFormat("[BASKET-EXIT] TARGET | Basket=%.2f | Target=%.2f | BUY=%.2f | SELL=%.2f",
                  basketProfit,TargetProfitUSD,BuyProfits,SellProfits);
      CloseAllManaged("BASKET-TARGET");
      UpdateStatus();
      return;
   }

   if(!UseTrailingProfit)return;

   // Basket trailing starts only after the whole cycle is positive.
   if(basketProfit>=TrailingStartUSD)
      MaxBasketProfitSeen=MathMax(MaxBasketProfitSeen,basketProfit);

   if(MaxBasketProfitSeen>=TrailingStartUSD&&
      basketProfit>0.0&&
      basketProfit<=MaxBasketProfitSeen-TrailingStopUSD)
   {
      PrintFormat("[BASKET-EXIT] TRAIL | Basket=%.2f | Peak=%.2f | Stop=%.2f",
                  basketProfit,MaxBasketProfitSeen,TrailingStopUSD);
      CloseAllManaged("BASKET-TRAIL");
      UpdateStatus();
   }
}

//================================================================================================//
// PROTECTION STATE
//================================================================================================//
void UpdateProtectionState(double dd)
{
   if(BuyOrders+SellOrders==0)
   {
      CurrentState=STATE_NORMAL;
      ReductionActions=0;
      return;
   }

   if(dd>=EmergencyLimit()){CurrentState=STATE_EMERGENCY;return;}
   if(dd>=SurvivalDD){CurrentState=STATE_SURVIVAL;return;}
   if(dd>=ReduceLimit()){CurrentState=STATE_REDUCE;return;}
   if(dd>=SoftLimit()){CurrentState=STATE_MONITOR;return;}
   CurrentState=STATE_NORMAL;
}

//================================================================================================//
// BASKET LOSS
//================================================================================================//
double BasketLoss(ENUM_POSITION_TYPE type)
{
   double p=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=type)continue;
      p+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }
   return p<0?-p:0;
}

//================================================================================================//
// FIND LARGEST LOSER
//================================================================================================//
ulong LargestLosingTicket()
{
   ulong best=0;
   double bestLoss=0,bestVol=0;
   datetime oldest=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;

      double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(p>=0)continue;

      double loss=-p,vol=PositionGetDouble(POSITION_VOLUME);
      datetime ot=(datetime)PositionGetInteger(POSITION_TIME);

      if(vol>bestVol+1e-8||
         (MathAbs(vol-bestVol)<=1e-8&&loss>bestLoss+1e-8)||
         (MathAbs(vol-bestVol)<=1e-8&&MathAbs(loss-bestLoss)<=1e-8&&(oldest==0||ot<oldest)))
      {
         best=t;
         bestLoss=loss;
         bestVol=vol;
         oldest=ot;
      }
   }
   return best;
}

ulong LargestLosingTicketBySide(ENUM_POSITION_TYPE wantedType)
{
   ulong best=0;
   double bestLoss=0,bestVol=0;
   datetime oldest=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0||!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=wantedType)continue;

      double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(p>=0)continue;

      double loss=-p,vol=PositionGetDouble(POSITION_VOLUME);
      datetime ot=(datetime)PositionGetInteger(POSITION_TIME);

      if(vol>bestVol+1e-8||
         (MathAbs(vol-bestVol)<=1e-8&&loss>bestLoss+1e-8)||
         (MathAbs(vol-bestVol)<=1e-8&&MathAbs(loss-bestLoss)<=1e-8&&(oldest==0||ot<oldest)))
      {
         best=t;
         bestLoss=loss;
         bestVol=vol;
         oldest=ot;
      }
   }
   return best;
}

//================================================================================================//
// RECOVERY FREEZE
//================================================================================================//
void SetRecoveryFreeze()
{
   int freezeSeconds=(int)MathMax(RecoveryFreezeSec,SURVIVAL_REENTRY_FREEZE_SEC);
   FreezeGridUntil=TimeCurrent()+freezeSeconds;
}

//================================================================================================//
// RECOVERY GOVERNOR - CRITICAL FIX
//================================================================================================//
void RecoveryGovernor(double dd)
{
   if(BuyOrders+SellOrders==0)return;
   if(TimeCurrent()<FreezeGridUntil)return;
   if((TimeCurrent()-LastRecoveryAction)<RecoveryCooldownSec)return;

   double buyLoss=BasketLoss(POSITION_TYPE_BUY);
   double sellLoss=BasketLoss(POSITION_TYPE_SELL);
   double basketProfit=BuyProfits+SellProfits;
   double basketLoss=(basketProfit<0.0)?-basketProfit:0.0;

   bool active=(dd>=RecoveryStartDD);
   bool aggressive=(dd>=AggressiveRecoveryDD);
   bool survival=(dd>=SurvivalDD);
   bool basketDanger=(basketLoss>=MaxBasketLossUSD);

   // Recovery is intentionally allowed from SOFT DD onward.
   // The previous implementation waited for ReduceDD, leaving a dangerous
   // 7%-8.5% DD zone with no loss-reduction action.
   if(!active&&!basketDanger)return;

   // Never fight a profitable basket. Let BasketExit manage it.
   if(basketProfit>=0.0&&basketLoss<=0.0)return;

   //--------------------------------------------------------------------------------------------//
   // SURVIVAL: one losing position at a time, then freeze.
   //--------------------------------------------------------------------------------------------//
   if(survival)
   {
      CurrentState=STATE_SURVIVAL;

      if(ReductionActions>=MaxReductionActions)return;

      if(buyLoss>=SurvivalBasketLossUSD||sellLoss>=SurvivalBasketLossUSD)
      {
         ENUM_POSITION_TYPE side=(buyLoss>=SurvivalBasketLossUSD&&buyLoss>=sellLoss)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
         if(ReduceLargestLosingSide(side,"SURVIVAL-REDUCE"))return;
      }

      // If total basket loss is already significant, still reduce one loser.
      if(basketLoss>=MinRecoveryLossUSD)
      {
         if(ReduceLargestLoser("SURVIVAL-RECOVERY"))return;
      }
      return;
   }

   //--------------------------------------------------------------------------------------------//
   // REDUCE / RECOVERY: act before emergency, not after it.
   //--------------------------------------------------------------------------------------------//
   if(ReductionActions>=MaxReductionActions)return;

   bool shouldReduce=(basketDanger||
                      dd>=ReduceLimit()||
                      (aggressive&&basketLoss>=MinRecoveryLossUSD)||
                      (dd>=SoftLimit()&&basketLoss>=MinRecoveryLossUSD));

   if(shouldReduce)
   {
      if(ReduceLargestLoser("RECOVERY"))return;
   }
}

//================================================================================================//
// REDUCE ONE SIDE
//================================================================================================//
bool ReduceLargestLosingSide(ENUM_POSITION_TYPE type,string reason)
{
   ulong t=LargestLosingTicketBySide(type);
   if(t==0||!PositionSelectByTicket(t))return false;

   double loss=-(PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP));
   double vol=PositionGetDouble(POSITION_VOLUME);

   if(!ClosePosition(t,reason))return false;

   LockDirection(type,reason);
   ReductionActions++;
   LastRecoveryAction=TimeCurrent();
   SetRecoveryFreeze();
   RecoveryActionThisTick=true;

   PrintFormat("[SURVIVAL] REDUCE | ticket=%I64u | side=%s | lot=%.4f | loss=%.2f | action=%d/%d | freeze=%ds",
               t,EnumToString(type),vol,loss,ReductionActions,MaxReductionActions,
               (int)MathMax(RecoveryFreezeSec,SURVIVAL_REENTRY_FREEZE_SEC));
   return true;
}

//================================================================================================//
// REDUCE LARGEST LOSER
//================================================================================================//
bool ReduceLargestLoser(string reason)
{
   ulong t=LargestLosingTicket();
   if(t==0||!PositionSelectByTicket(t))return false;

   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double loss=-(PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP));
   double vol=PositionGetDouble(POSITION_VOLUME);

   if(!ClosePosition(t,reason))return false;

   LockDirection(type,reason);
   ReductionActions++;
   LastRecoveryAction=TimeCurrent();
   SetRecoveryFreeze();
   RecoveryActionThisTick=true;

   PrintFormat("[REDUCE] %s | ticket=%I64u | side=%s | lot=%.4f | loss=%.2f | action=%d/%d | freeze=%ds",
               reason,t,EnumToString(type),vol,loss,ReductionActions,MaxReductionActions,
               (int)MathMax(RecoveryFreezeSec,SURVIVAL_REENTRY_FREEZE_SEC));
   return true;
}

//================================================================================================//
// CLOSE ENGINE
//================================================================================================//
void CloseSide(ENUM_POSITION_TYPE type,string reason)
{
   for(int pass=0;pass<10;pass++)
   {
      bool found=false,changed=false;

      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong t=PositionGetTicket(i);
         if(!PositionSelectByTicket(t))continue;
         if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=type)continue;

         found=true;
         if(ClosePosition(t,reason))changed=true;
      }

      if(!found||!changed)break;
   }
}

void CloseAllManaged(string reason)
{
   CloseSide(POSITION_TYPE_BUY,reason);
   CloseSide(POSITION_TYPE_SELL,reason);
}

bool ClosePosition(ulong ticket,string reason)
{
   if(ticket==0||!PositionSelectByTicket(ticket))return false;
   if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)return false;

   ENUM_POSITION_TYPE ptype=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   ENUM_ORDER_TYPE type=(ptype==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
   double vol=PositionGetDouble(POSITION_VOLUME);
   if(vol<=0)return false;

   double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   double ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   if(bid<=0||ask<=0)return false;

   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL;
   req.position=ticket;
   req.symbol=SymbolTrade;
   req.magic=OrdersID;
   req.volume=vol;
   req.type=type;
   req.price=(type==ORDER_TYPE_BUY)?ask:bid;
   req.deviation=30;
   req.type_filling=SafeFilling();
   req.comment=reason;

   ResetLastError();
   bool sent=OrderSend(req,res);
   if(!sent||!TradeOK(res.retcode))
   {
      PrintFormat("[CLOSE] FAILED | ticket=%I64u | %s | rc=%u | %s | err=%d",ticket,reason,res.retcode,res.comment,GetLastError());
      return false;
   }

   PrintFormat("[CLOSE] SUCCESS | ticket=%I64u | %s | volume=%.4f | rc=%u",ticket,reason,res.volume,res.retcode);
   return true;
}

//================================================================================================//
// DASHBOARD
//================================================================================================//
string StateText()
{
   if(CurrentState==STATE_MONITOR)return "MONITOR";
   if(CurrentState==STATE_REDUCE)return "REDUCE";
   if(CurrentState==STATE_SURVIVAL)return "SURVIVAL";
   if(CurrentState==STATE_EMERGENCY)return "EMERGENCY";
   if(CurrentState==STATE_LOCKED)return "LOCKED";
   return "NORMAL";
}

void Dashboard(double dd)
{
   double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   double ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   double spread=0;
   if(bid>0&&ask>0&&_Point>0)spread=(ask-bid)/_Point;

   double basket=BuyProfits+SellProfits;

   Comment(
      "======== GRIDMaster v7.004 ========\n",
      "Status: ",(IsTerminated?"LOCKED":"RUNNING"),"\n",
      "State: ",StateText(),"\n",
      "DD: ",DoubleToString(dd,2),"%\n",
      "Peak: ",DoubleToString(PeakEquity,2),"\n",
      "Hard: ",DoubleToString(HardLimit(),2),"% | Soft: ",DoubleToString(SoftLimit(),2),"%\n",
      "Reduce: ",DoubleToString(ReduceLimit(),2),"% | Emergency: ",DoubleToString(EmergencyLimit(),2),"%\n",
      "Exposure: ",DoubleToString(TotalExposureLots(),2)," lots | Spread: ",DoubleToString(spread,1)," pts\n",
      "BUY LOCK: ",(BuyDirectionLocked?"YES":"NO")," | SELL LOCK: ",(SellDirectionLocked?"YES":"NO"),"\n",
      "Anomaly: ",(AnomalyBrakeActive?"BRAKE":"OK")," | Freeze: ",TimeToString(FreezeGridUntil,TIME_SECONDS),"\n",
      "BUY: ",BuyOrders," | ",DoubleToString(BuyProfits,2),"\n",
      "SELL: ",SellOrders," | ",DoubleToString(SellProfits,2),"\n",
      "BASKET: ",DoubleToString(basket,2)," | PEAK: ",DoubleToString(MaxBasketProfitSeen,2),"\n",
      "REDUCTIONS: ",ReductionActions,"/",MaxReductionActions,"\n",
      "=================================="
   );
}
//================================================================================================//
// END
//================================================================================================//
