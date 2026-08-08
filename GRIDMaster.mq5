//================================================================================================//
// GRIDMaster - PROFIT PROTECTION / BASKET RECOVERY EDITION 2026
// v7.010 - RECOVERY V5 + LOSS GATE + PARTIAL REDUCTION + LOSS BUDGET
//================================================================================================//
#property strict
#property copyright "Copyright 2026, Jarvis"
#property version   "7.010"

enum Type {Open_Buy_And_Sell,Open__Only_Buy,Open__Only_Sell};
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
input double CatastrophicBasketLossUSD=120.0;
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
input string CommentsOrders="GRID MASTER v7.010";

//================================================================================================//
// RECOVERY V5 / ANOMALY
//================================================================================================//
input string Recovery_Settings="||========== RECOVERY V5 / ANOMALY ==========||";
input bool UseRecoveryExit=true;
input double RecoveryStartDD=7.0;
input double AggressiveRecoveryDD=8.5;
input double SurvivalDD=10.0;
input int RecoveryCooldownSec=30;
input int RecoveryFreezeSec=60;
input double MinRecoveryLossUSD=20.0;
input double RecoveryLossTriggerUSD=20.0;
input double RecoveryDistributedLossTriggerUSD=30.0;
input double RecoveryConcentrationRatio=0.50;
input double GrossLossRecoveryTriggerUSD=25.0;
input double RecoveryNetLossTriggerUSD=10.0;
input double RecoveryPartialClosePercent=50.0;
input double RecoveryMaxRealizedLossUSD=5.0;
input double StalePositionHours=72.0;
input double MaxPositionSwapLossUSD=20.0;
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
bool BuyDirectionLocked=false,SellDirectionLocked=false;
datetime FreezeGridUntil=0,LastRecoveryAction=0,AnomalyUntil=0,LastLogTime=0;
double InitialBalance=0.0,PeakEquity=0.0,HighWaterMark=0.0;
double MaxBuyProfitSeen=0.0,MaxSellProfitSeen=0.0,LastMidPrice=0.0;
int ReductionActions=0;
ProtectionState CurrentState=STATE_NORMAL;
#define ANOMALY_RESET_RATIO 0.70

//================================================================================================//
// PROTECTION LIMITS
//================================================================================================//
double HardLimit(){double v=MaxEquityLossPercent;if(v<=0)v=15.0;return MathMin(v,15.0);}
double SoftLimit(){double h=HardLimit(),v=SoftDDPercent;if(v<=0)v=h*0.5;return MathMin(MathMax(v,2.0),h-1.0);}
double ReduceLimit(){double h=HardLimit(),v=ReduceDDPercent;if(v<=0)v=h*0.65;return MathMin(MathMax(v,SoftLimit()+0.5),h-1.5);}
double EmergencyLimit(){double h=HardLimit(),v=EmergencyDDPercent;if(v<=0)v=h-2.0;return MathMin(MathMax(v,ReduceLimit()+1.0),h-0.5);}
double ProtectionDD(){double e=AccountInfoDouble(ACCOUNT_EQUITY),a=0.0,b=0.0;if(PeakEquity>0&&e<PeakEquity)a=(PeakEquity-e)/PeakEquity*100.0;if(InitialBalance>0&&e<InitialBalance)b=(InitialBalance-e)/InitialBalance*100.0;return MathMax(a,b);}

//================================================================================================//
// MARKET HEALTH
//================================================================================================//
bool MarketHealthy(){
   double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID),ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   if(bid<=0||ask<=0||ask<bid||_Point<=0)return false;
   datetime now=TimeCurrent();double spread=(ask-bid)/_Point,mid=(bid+ask)*0.5;
   if(AnomalyBrakeActive){LastMidPrice=mid;if(now<AnomalyUntil)return false;double resetSpread=AnomalySpreadPoints*ANOMALY_RESET_RATIO;if(AnomalySpreadPoints>0&&spread>=resetSpread)return false;AnomalyBrakeActive=false;AnomalyUntil=0;}
   bool anomaly=false;if(AnomalySpreadPoints>0&&spread>=AnomalySpreadPoints)anomaly=true;else if(LastMidPrice>0&&AnomalyJumpPoints>0&&MathAbs(mid-LastMidPrice)/_Point>=AnomalyJumpPoints)anomaly=true;
   LastMidPrice=mid;if(anomaly){AnomalyBrakeActive=true;AnomalyUntil=now+AnomalyCooldownSec;return false;}return true;
}
bool IsTradingHour(){if(!UseTradingHour)return true;MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);if(StartHour<EndHour)return dt.hour>=StartHour&&dt.hour<EndHour;return dt.hour>=StartHour||dt.hour<EndHour;}

//================================================================================================//
// INITIALIZATION
//================================================================================================//
int OnInit(){
   SymbolTrade=_Symbol;OrdersID=(MagicNumber==0)?101010:MagicNumber;
   HandleRSI=iRSI(SymbolTrade,PERIOD_CURRENT,RSIPeriod,PRICE_CLOSE);HandleMA=iMA(SymbolTrade,PERIOD_CURRENT,MAPeriod,0,MODE_SMA,PRICE_CLOSE);
   InitialBalance=AccountInfoDouble(ACCOUNT_BALANCE);PeakEquity=MathMax(InitialBalance,AccountInfoDouble(ACCOUNT_EQUITY));HighWaterMark=InitialBalance;
   ReductionActions=0;LastMidPrice=0.0;BuyDirectionLocked=false;SellDirectionLocked=false;HardProtectionActive=false;IsTerminated=false;AnomalyBrakeActive=false;CurrentState=STATE_NORMAL;
   if(HandleRSI==INVALID_HANDLE||HandleMA==INVALID_HANDLE){Print("[INIT] Indicator initialization failed");return INIT_FAILED;}
   PrintFormat("[INIT] GRIDMaster v7.010 | Balance=%.2f | Hard=%.2f%% | Soft=%.2f%% | Reduce=%.2f%% | Emergency=%.2f%%",InitialBalance,HardLimit(),SoftLimit(),ReduceLimit(),EmergencyLimit());
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){if(HandleRSI!=INVALID_HANDLE)IndicatorRelease(HandleRSI);if(HandleMA!=INVALID_HANDLE)IndicatorRelease(HandleMA);Comment("");}

//================================================================================================//
// MAIN ENGINE
//================================================================================================//
void OnTick(){
   if(IsTerminated)return;RecoveryActionThisTick=false;UpdateStatus();
   double e=AccountInfoDouble(ACCOUNT_EQUITY),bal=AccountInfoDouble(ACCOUNT_BALANCE);if(e>PeakEquity)PeakEquity=e;if(bal>HighWaterMark)HighWaterMark=bal;
   double dd=ProtectionDD();bool healthy=MarketHealthy();
   if(!healthy&&AnomalyBrakeActive&&LastLogTime!=AnomalyUntil){LastLogTime=AnomalyUntil;PrintFormat("[ANOMALY] BRAKE | Until=%s",TimeToString(AnomalyUntil,TIME_DATE|TIME_SECONDS));}
   if(dd>=HardLimit())HardProtectionActive=true;
   if(HardProtectionActive){CurrentState=STATE_LOCKED;CloseAllManaged("HARD-DD");UpdateStatus();if(BuyOrders==0&&SellOrders==0){IsTerminated=true;Print("[PROTECTION] HARD LOCK COMPLETE");}Dashboard(dd);return;}

   double netBasket=BuyProfits+SellProfits;double netLoss=(netBasket<0.0)?-netBasket:0.0;double grossLoss=GrossLosingExposure();
   bool maxGrid=(BuyOrders>=MaxOrders||SellOrders>=MaxOrders);
   if((MaxBasketLossUSD>0&&netLoss>=MaxBasketLossUSD)||(maxGrid&&CatastrophicBasketLossUSD>0&&grossLoss>=CatastrophicBasketLossUSD)){
      CurrentState=STATE_EMERGENCY;CloseAllManaged("MAX-BASKET-LOSS");UpdateStatus();if(BuyOrders==0&&SellOrders==0){IsTerminated=true;PrintFormat("[PROTECTION] BASKET EXIT | DD=%.2f%% | NetLoss=%.2f | GrossLoss=%.2f",dd,netLoss,grossLoss);}Dashboard(dd);return;
   }
   if(dd>=EmergencyLimit()){CurrentState=STATE_EMERGENCY;CloseAllManaged("EMERGENCY-DD");UpdateStatus();if(BuyOrders==0&&SellOrders==0){IsTerminated=true;PrintFormat("[PROTECTION] EMERGENCY COMPLETE | DD=%.2f%%",dd);}Dashboard(dd);return;}

   ManageProfitExit();UpdateStatus();UpdateDirectionLocks();UpdateProtectionState(dd);
   if(UseRecoveryExit){RiskRecoveryV4(dd);if(!RecoveryActionThisTick)RecoveryGovernor(dd);}
   UpdateStatus();UpdateDirectionLocks();
   if(RecoveryActionThisTick){Dashboard(dd);return;}
   bool allowEntry=!HardProtectionActive&&!IsTerminated&&CurrentState==STATE_NORMAL&&dd<SoftLimit()&&TimeCurrent()>=FreezeGridUntil&&!AnomalyBrakeActive&&healthy&&IsTradingHour()&&TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)&&MQLInfoInteger(MQL_TRADE_ALLOWED);
   if(allowEntry)GridEntryEngine();Dashboard(dd);
}

//================================================================================================//
// POSITION STATUS
//================================================================================================//
void UpdateStatus(){
   BuyOrders=SellOrders=0;BuyProfits=SellProfits=0.0;PriceOpenLastBuy=PriceOpenLastSell=0.0;datetime lb=0,ls=0;
   for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);datetime ot=(datetime)PositionGetInteger(POSITION_TIME);double op=PositionGetDouble(POSITION_PRICE_OPEN);if(type==POSITION_TYPE_BUY){BuyOrders++;BuyProfits+=p;if(ot>=lb){lb=ot;PriceOpenLastBuy=op;}}else{SellOrders++;SellProfits+=p;if(ot>=ls){ls=ot;PriceOpenLastSell=op;}}}
   if(BuyOrders==0)MaxBuyProfitSeen=0.0;if(SellOrders==0)MaxSellProfitSeen=0.0;if(BuyOrders==0&&SellOrders==0){ReductionActions=0;BuyDirectionLocked=false;SellDirectionLocked=false;}
}

//================================================================================================//
// DIRECTION LOCKS
//================================================================================================//
void UpdateDirectionLocks(){if(BuyOrders==0)BuyDirectionLocked=false;if(SellOrders==0)SellDirectionLocked=false;}
void LockDirection(ENUM_POSITION_TYPE type,string reason){if(type==POSITION_TYPE_BUY)BuyDirectionLocked=true;else SellDirectionLocked=true;PrintFormat("[LOCK] %s direction LOCKED | reason=%s",EnumToString(type),reason);}
bool IsDirectionLocked(ENUM_ORDER_TYPE type){if(type==ORDER_TYPE_BUY)return BuyDirectionLocked;if(type==ORDER_TYPE_SELL)return SellDirectionLocked;return true;}

//================================================================================================//
// GRID ENTRY ENGINE
//================================================================================================//
void GridEntryEngine(){
   double rsi=GetRSIValue(),ma=GetMAValue(),bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID),ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);if(bid<=0||ask<=0||ma<=0)return;bool buy=false,sell=false;
   if(BuyOrders==0&&!BuyDirectionLocked&&(TypeOrdersPlace==Open_Buy_And_Sell||TypeOrdersPlace==Open__Only_Buy)&&bid>ma&&rsi<RSILower)buy=true;
   if(SellOrders==0&&!SellDirectionLocked&&(TypeOrdersPlace==Open_Buy_And_Sell||TypeOrdersPlace==Open__Only_Sell)&&bid<ma&&rsi>RSIUpper)sell=true;
   if(BuyOrders>0&&!BuyDirectionLocked&&BuyOrders<MaxOrders){double gap=PointsForFirstGap*MathPow(GapMultiplier,BuyOrders-1);if(ask<=PriceOpenLastBuy-gap*_Point)buy=true;}
   if(SellOrders>0&&!SellDirectionLocked&&SellOrders<MaxOrders){double gap=PointsForFirstGap*MathPow(GapMultiplier,SellOrders-1);if(bid>=PriceOpenLastSell+gap*_Point)sell=true;}
   if(buy)ExecuteOpen(ORDER_TYPE_BUY);if(sell)ExecuteOpen(ORDER_TYPE_SELL);
}
double GetRSIValue(){double b[];ArraySetAsSeries(b,true);return CopyBuffer(HandleRSI,0,0,1,b)>0?b[0]:50.0;}
double GetMAValue(){double b[];ArraySetAsSeries(b,true);return CopyBuffer(HandleMA,0,0,1,b)>0?b[0]:0.0;}

//================================================================================================//
// TRADE UTILITIES
//================================================================================================//
int VolumeDigits(){double s=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_STEP);int d=0;while(d<8&&MathAbs(s-NormalizeDouble(s,d))>1e-10)d++;return d;}
double NormalizeVolume(double v){double min=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MIN),max=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MAX),step=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_STEP);if(min<=0||max<=0||step<=0||v<min-1e-10)return 0.0;v=MathMin(v,max);v=MathFloor((v+1e-10)/step)*step;return v>=min-1e-10?NormalizeDouble(v,VolumeDigits()):0.0;}
double TotalExposureLots(){double x=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;x+=PositionGetDouble(POSITION_VOLUME);}return x;}
double GrossLosingExposure(){double x=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);if(p<0)x+=-p;}return x;}
ENUM_ORDER_TYPE_FILLING SafeFilling(){long f=0;if(SymbolInfoInteger(SymbolTrade,SYMBOL_FILLING_MODE,f)){if((f&SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC)return ORDER_FILLING_IOC;if((f&SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK)return ORDER_FILLING_FOK;}long e=0;SymbolInfoInteger(SymbolTrade,SYMBOL_TRADE_EXEMODE,e);if(e!=SYMBOL_TRADE_EXECUTION_MARKET)return ORDER_FILLING_RETURN;return ORDER_FILLING_FOK;}
bool TradeOK(uint r){return r==TRADE_RETCODE_DONE||r==TRADE_RETCODE_DONE_PARTIAL;}

//================================================================================================//
// OPEN POSITION
//================================================================================================//
void ExecuteOpen(ENUM_ORDER_TYPE type){
   double dd=ProtectionDD();if(HardProtectionActive||IsTerminated||CurrentState!=STATE_NORMAL||dd>=SoftLimit()||AnomalyBrakeActive||TimeCurrent()<FreezeGridUntil||IsDirectionLocked(type))return;
   if(MaxTotalExposureLots>0&&TotalExposureLots()>=MaxTotalExposureLots-1e-8)return;int count=(type==ORDER_TYPE_BUY)?BuyOrders:SellOrders;if(count>=MaxOrders)return;
   double mult=UseProgressiveLots?MathMin(count+1.0,MaxLotMultiplier):1.0;double reqLot=ManualLotSize*mult;if(MaxTotalExposureLots>0)reqLot=MathMin(reqLot,MaxTotalExposureLots-TotalExposureLots());double vol=NormalizeVolume(reqLot);if(vol<=0)return;
   double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID),ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);if(bid<=0||ask<=0||ask<bid)return;
   MqlTradeRequest req={};MqlTradeResult res={};req.action=TRADE_ACTION_DEAL;req.symbol=SymbolTrade;req.magic=OrdersID;req.volume=vol;req.type=type;req.price=(type==ORDER_TYPE_BUY)?ask:bid;req.deviation=20;req.type_filling=SafeFilling();req.comment=CommentsOrders;
   ResetLastError();bool sent=OrderSend(req,res);if(!sent||!TradeOK(res.retcode)){PrintFormat("[OPEN] FAILED | %s | vol=%.4f | rc=%u | %s | err=%d",EnumToString(type),vol,res.retcode,res.comment,GetLastError());return;}PrintFormat("[OPEN] SUCCESS | %s | vol=%.4f | deal=%I64u",EnumToString(type),res.volume,res.deal);
}

//================================================================================================//
// PROFIT ENGINE - BASKET ONLY
//================================================================================================//
void ManageProfitExit(){
   double basket=BuyProfits+SellProfits;
   if(basket>=TargetProfitUSD){CloseAllManaged("BASKET-TARGET");UpdateStatus();return;}
   if(!UseTrailingProfit)return;
   if(basket>=TrailingStartUSD){}
   if(BuyOrders>0&&BuyProfits>=TrailingStartUSD)MaxBuyProfitSeen=MathMax(MaxBuyProfitSeen,BuyProfits);
   if(SellOrders>0&&SellProfits>=TrailingStartUSD)MaxSellProfitSeen=MathMax(MaxSellProfitSeen,SellProfits);
   if(BuyOrders>0&&MaxBuyProfitSeen>=TrailingStartUSD&&BuyProfits>0&&BuyProfits<=MaxBuyProfitSeen-TrailingStopUSD){CloseSide(POSITION_TYPE_BUY,"BUY-TRAIL");UpdateStatus();}
   if(SellOrders>0&&MaxSellProfitSeen>=TrailingStartUSD&&SellProfits>0&&SellProfits<=MaxSellProfitSeen-TrailingStopUSD){CloseSide(POSITION_TYPE_SELL,"SELL-TRAIL");UpdateStatus();}
}

//================================================================================================//
// PROTECTION STATE
//================================================================================================//
void UpdateProtectionState(double dd){if(BuyOrders+SellOrders==0){CurrentState=STATE_NORMAL;ReductionActions=0;return;}if(dd>=EmergencyLimit()){CurrentState=STATE_EMERGENCY;return;}if(dd>=ReduceLimit()){CurrentState=STATE_REDUCE;return;}if(dd>=SoftLimit()){CurrentState=STATE_MONITOR;return;}CurrentState=STATE_NORMAL;}

//================================================================================================//
// RECOVERY V5 - GROSS LOSS / NET LOSS GATE / PARTIAL REDUCTION / LOSS BUDGET
//================================================================================================//
void RiskRecoveryV4(double dd){
   if(BuyOrders+SellOrders==0||TimeCurrent()<FreezeGridUntil||(TimeCurrent()-LastRecoveryAction)<RecoveryCooldownSec||ReductionActions>=MaxReductionActions)return;
   double basket=BuyProfits+SellProfits;double netLoss=(basket<0.0)?-basket:0.0;if(netLoss<RecoveryNetLossTriggerUSD)return;
   double gross=0.0,worstLoss=0.0,worstSwap=0.0;datetime oldest=0;ulong worstTicket=0;
   for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;double p=PositionGetDouble(POSITION_PROFIT),sw=PositionGetDouble(POSITION_SWAP),net=p+sw;datetime ot=(datetime)PositionGetInteger(POSITION_TIME);if(net<0){double loss=-net;gross+=loss;if(loss>worstLoss){worstLoss=loss;worstSwap=sw;worstTicket=t;}if(oldest==0||ot<oldest)oldest=ot;}}
   if(worstTicket==0)return;
   double concentration=(gross>0.0)?worstLoss/gross:0.0;double age=(oldest>0)?(double)(TimeCurrent()-oldest)/3600.0:0.0;bool ddGate=(dd>=RecoveryStartDD);bool grossTrigger=(GrossLossRecoveryTriggerUSD>0&&gross>=GrossLossRecoveryTriggerUSD);bool staleTrigger=(StalePositionHours>0&&age>=StalePositionHours);bool swapTrigger=(MaxPositionSwapLossUSD>0&&worstSwap<=-MaxPositionSwapLossUSD);bool concentrated=(concentration>=RecoveryConcentrationRatio);
   bool trigger=(ddGate&&(grossTrigger||concentrated))||(staleTrigger&&netLoss>=RecoveryNetLossTriggerUSD)||(swapTrigger&&netLoss>=RecoveryNetLossTriggerUSD);if(!trigger)return;
   string reason=staleTrigger?"RECOVERY-STALE":(swapTrigger?"RECOVERY-SWAP":"RECOVERY-GROSS");
   if(ReduceLargestLoser(reason))PrintFormat("[RECOVERY V5] %s | net=%.2f | gross=%.2f | worst=%.2f | concentration=%.1f%% | age=%.1fh | swap=%.2f | DD=%.2f%%",reason,netLoss,gross,worstLoss,concentration*100.0,age,worstSwap,dd);
}

//================================================================================================//
// LEGACY RECOVERY GOVERNOR - DD / BASKET TRIGGER
//================================================================================================//
void RecoveryGovernor(double dd){
   if(BuyOrders+SellOrders==0||TimeCurrent()<FreezeGridUntil||(TimeCurrent()-LastRecoveryAction)<RecoveryCooldownSec||ReductionActions>=MaxReductionActions)return;
   double basket=BuyProfits+SellProfits;double netLoss=(basket<0.0)?-basket:0.0;if(netLoss<RecoveryNetLossTriggerUSD)return;
   double bl=BasketLoss(POSITION_TYPE_BUY),sl=BasketLoss(POSITION_TYPE_SELL);bool active=dd>=RecoveryStartDD,aggressive=dd>=AggressiveRecoveryDD,survival=dd>=SurvivalDD;
   if(survival){CurrentState=STATE_SURVIVAL;if(bl>=SurvivalBasketLossUSD&&bl>=sl&&BuyOrders>0){if(CloseSide(POSITION_TYPE_BUY,"SURVIVAL-BUY")){RecoveryActionThisTick=true;SetFreeze();return;}}if(sl>=SurvivalBasketLossUSD&&sl>bl&&SellOrders>0){if(CloseSide(POSITION_TYPE_SELL,"SURVIVAL-SELL")){RecoveryActionThisTick=true;SetFreeze();return;}}}
   if((active||aggressive)&&(aggressive||bl>=RecoveryLossTriggerUSD||sl>=RecoveryLossTriggerUSD)){if(ReduceLargestLoser("RECOVERY-DD"))return;}
   if(bl+sl>=RecoveryDistributedLossTriggerUSD&&bl+sl>=MinRecoveryLossUSD){if(ReduceLargestLoser("RECOVERY-DISTRIBUTED"))return;}
}
double BasketLoss(ENUM_POSITION_TYPE type){double p=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=type)continue;p+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);}return p<0?-p:0;}

//================================================================================================//
// REDUCE / CLOSE ENGINE
//================================================================================================//
ulong LargestLosingTicket(){ulong best=0;double bestLoss=0;double bestVol=0;datetime oldest=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);if(p>=0)continue;double loss=-p,vol=PositionGetDouble(POSITION_VOLUME);datetime ot=(datetime)PositionGetInteger(POSITION_TIME);if(vol>bestVol+1e-8||(MathAbs(vol-bestVol)<=1e-8&&loss>bestLoss+1e-8)||(MathAbs(vol-bestVol)<=1e-8&&MathAbs(loss-bestLoss)<=1e-8&&(oldest==0||ot<oldest))){best=t;bestLoss=loss;bestVol=vol;oldest=ot;}}return best;}
double RecoveryAllowedCloseVolume(ulong ticket,double loss,double vol){double minVol=SymbolInfoDouble(SymbolTrade,SYMBOL_VOLUME_MIN);if(minVol<=0||vol<=0)return 0.0;double pct=RecoveryPartialClosePercent;if(pct<=0.0)pct=50.0;if(pct>100.0)pct=100.0;double closeVol=NormalizeVolume(vol*pct/100.0);if(closeVol<=0.0)return 0.0;if(closeVol>=vol-1e-8&&RecoveryMaxRealizedLossUSD>0.0&&loss>RecoveryMaxRealizedLossUSD){closeVol=NormalizeVolume(vol-minVol);if(closeVol<=0.0)return 0.0;}if(RecoveryMaxRealizedLossUSD>0.0&&loss>0.0){double budgetRatio=RecoveryMaxRealizedLossUSD/loss;if(budgetRatio<1.0){double budgetVol=NormalizeVolume(vol*budgetRatio);if(budgetVol>0.0)closeVol=MathMin(closeVol,budgetVol);}}closeVol=NormalizeVolume(closeVol);if(closeVol>=vol-1e-8&&vol>minVol)closeVol=NormalizeVolume(vol-minVol);if(closeVol<minVol-1e-8)return 0.0;return closeVol;}
bool ReduceLargestLoser(string reason){ulong t=LargestLosingTicket();if(t==0||!PositionSelectByTicket(t))return false;ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);double net=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);double loss=-net;double vol=PositionGetDouble(POSITION_VOLUME);double closeVol=RecoveryAllowedCloseVolume(t,loss,vol);if(closeVol<=0.0)return false;double basket=BuyProfits+SellProfits;if(basket>=-RecoveryNetLossTriggerUSD)return false;if(!ClosePosition(t,reason,closeVol))return false;ReductionActions++;LastRecoveryAction=TimeCurrent();FreezeGridUntil=TimeCurrent()+RecoveryFreezeSec;LockDirection(type,reason);RecoveryActionThisTick=true;PrintFormat("[REDUCE] %s | ticket=%I64u | side=%s | lot=%.4f/%.4f | loss=%.2f | action=%d/%d",reason,t,EnumToString(type),closeVol,vol,loss,ReductionActions,MaxReductionActions);return true;}
void SetFreeze(){FreezeGridUntil=TimeCurrent()+RecoveryFreezeSec;}

bool CloseSide(ENUM_POSITION_TYPE type,string reason){bool any=false;for(int pass=0;pass<10;pass++){bool found=false,changed=false;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=type)continue;found=true;if(ClosePosition(t,reason)){changed=true;any=true;}}if(!found||!changed)break;}return any;}
void CloseAllManaged(string reason){for(int pass=0;pass<12;pass++){bool found=false,changed=false;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;found=true;double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);if(p<0&&ClosePosition(t,reason)){changed=true;continue;}}if(!found)break;if(!changed){for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;if(ClosePosition(t,reason))changed=true;}}if(!changed)break;}}
bool ClosePosition(ulong ticket,string reason,double requestedVolume=0.0){
   if(ticket==0||!PositionSelectByTicket(ticket))return false;if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)return false;
   ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);ENUM_ORDER_TYPE type=(pt==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;double posVol=PositionGetDouble(POSITION_VOLUME);double vol=(requestedVolume>0.0)?NormalizeVolume(requestedVolume):posVol;if(vol<=0||vol>posVol+1e-8)return false;
   double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID),ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);if(bid<=0||ask<=0)return false;
   MqlTradeRequest req={};MqlTradeResult res={};req.action=TRADE_ACTION_DEAL;req.position=ticket;req.symbol=SymbolTrade;req.magic=OrdersID;req.volume=vol;req.type=type;req.price=(type==ORDER_TYPE_BUY)?ask:bid;req.deviation=30;req.type_filling=SafeFilling();req.comment=reason;
   ResetLastError();bool sent=OrderSend(req,res);if(!sent||!TradeOK(res.retcode)){PrintFormat("[CLOSE] FAILED | ticket=%I64u | %s | rc=%u | %s | err=%d",ticket,reason,res.retcode,res.comment,GetLastError());return false;}PrintFormat("[CLOSE] SUCCESS | ticket=%I64u | %s | volume=%.4f | rc=%u",ticket,reason,res.volume,res.retcode);return true;
}

//================================================================================================//
// DASHBOARD
//================================================================================================//
string StateText(){if(CurrentState==STATE_MONITOR)return "MONITOR";if(CurrentState==STATE_REDUCE)return "REDUCE";if(CurrentState==STATE_SURVIVAL)return "SURVIVAL";if(CurrentState==STATE_EMERGENCY)return "EMERGENCY";if(CurrentState==STATE_LOCKED)return "LOCKED";return "NORMAL";}
void Dashboard(double dd){double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID),ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK),spread=0;if(bid>0&&ask>0&&_Point>0)spread=(ask-bid)/_Point;Comment("======== GRIDMaster v7.010 ========\n","Status: ",(IsTerminated?"LOCKED":"RUNNING"),"\n","State: ",StateText(),"\n","DD: ",DoubleToString(dd,2),"%\n","Hard: ",DoubleToString(HardLimit(),2),"% | Soft: ",DoubleToString(SoftLimit(),2),"%\n","Reduce: ",DoubleToString(ReduceLimit(),2),"% | Emergency: ",DoubleToString(EmergencyLimit(),2),"%\n","Exposure: ",DoubleToString(TotalExposureLots(),2)," lots | GrossLoss: ",DoubleToString(GrossLosingExposure(),2),"\n","Spread: ",DoubleToString(spread,1)," pts | Anomaly: ",(AnomalyBrakeActive?"BRAKE":"OK"),"\n","BUY: ",BuyOrders," | ",DoubleToString(BuyProfits,2),"\n","SELL: ",SellOrders," | ",DoubleToString(SellProfits,2),"\n","==================================");}