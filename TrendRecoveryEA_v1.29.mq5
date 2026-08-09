#property strict
#property version "1.29"
#property description "TrendRecoveryEA v1.29 - defensive recovery with capped recovery risk and basket-aware exit."
#include <Trade/Trade.mqh>
CTrade trade;

enum TrendDirection { TREND_NONE=0, TREND_BUY=1, TREND_SELL=-1 };
enum CampaignState { CAMPAIGN_IDLE=0, CAMPAIGN_TREND, CAMPAIGN_PROFIT, CAMPAIGN_RECOVERY, CAMPAIGN_EXIT, CAMPAIGN_LOCKED };

//---------- TREND SETTINGS ----------
input ENUM_TIMEFRAMES TrendTimeframe=PERIOD_M15;
input ENUM_TIMEFRAMES HigherTimeframe=PERIOD_H1;
input int FastEMAPeriod=20;
input int SlowEMAPeriod=50;
input int TrendEMAPeriod=200;
input int ADXPeriod=14;
input double MinimumADX=15.0;
input double MaximumATRPoints=0.0;
input bool UseRSIConfirmation=false;
input int RSIPeriod=14;
input double RSIForBuy=50.0;
input double RSIForSell=50.0;
input int ReversalConfirmationBars=2;

//---------- ENTRY SETTINGS ----------
input double InitialLot=0.01;
input double MaxLot=0.10;
input int EntryCooldownSeconds=900;
input int MaximumPositions=1;
input double MinimumEntryDistance=0.0;
input double MaximumSpread=300.0;
input long MagicNumber=26080901;
input int SlippagePoints=30;

//---------- PROFIT / POSITION EXIT ----------
input bool UseInitialSL=true;
input double InitialSL_ATR=1.75;
input bool UseBreakEven=true;
input double BreakEvenStartUSD=6.0;
input double BreakEvenOffsetUSD=0.20;
input bool UseProfitLock=true;
input double ProfitLockStepUSD=3.0;
input double ProfitLockStartUSD=12.0;
input double ProfitLockOffsetUSD=5.0;
input bool UseATRTrailing=true;
input double ATRTrailingMultiplier=1.8;
input double ATRTrailingStartUSD=15.0;

//---------- CAMPAIGN EXIT ----------
input double CampaignProfitTargetUSD=0.0;
input double CampaignProfitTrailStartUSD=10.0;
input double CampaignProfitGivebackUSD=3.0;

//---------- RECOVERY SETTINGS ----------
input bool UseRecovery=true;
input double RecoveryTriggerUSD=5.0;
input double RecoveryMultiplier=1.0;
input double MaxRecoveryLot=0.05;
input int MaxRecoveryPositions=1;
input double RecoveryTargetUSD=1.0;
input double RecoveryMinProfitUSD=0.0;
input double RecoveryMaxLossUSD=12.0;
input double RecoverySL_ATR=1.25;
input double RecoveryMaxLossPerTradeUSD=4.0;
input int RecoveryConfirmationBars=3;
input bool CloseOnStrongReversalIfNoRecovery=true;

//---------- RECOVERY EXIT v1.29 ----------
input double RecoveryLockStartUSD=2.0;
input double RecoveryLockProfitUSD=1.0;
input double RecoveryTrailStartUSD=5.0;
input double RecoveryTrailGivebackUSD=2.0;
input int RecoveryTimeoutMinutes=60;
input double RecoveryMinimumBasketProfitUSD=0.50;
input bool RecoveryCloseOnFailure=true;

//---------- RISK SETTINGS ----------
input double MaxCampaignLossUSD=100.0;
input int MaxCampaignHours=24;
input int MaximumExposurePositions=2;

//---------- EQUITY / DAILY PROTECTION ----------
input double MaxEquityDrawdownPercent=15.0;
input bool ClosePositionsOnEquityProtection=true;
input double MaxDailyLossUSD=0.0;
input double MaxDailyLossPercent=0.0;
input bool ClosePositionsOnDailyProtection=true;

//---------- SESSION / EXECUTION ----------
input bool UseTradingSession=true;
input int TradingStartHour=13;
input int TradingEndHour=23;
input bool UseEquityScaling=false;
input double BaseEquity=1500.0;
input double BaseLot=0.01;
input bool RequireHedgingAccountForRecovery=true;
input bool UseNewBarForEntry=true;
input bool EnableLogging=true;
input bool LogTrendChanges=true;

int hFastEMA=-1,hSlowEMA=-1,hTrendEMA=-1,hHTFEMA=-1,hADX=-1,hATR=-1,hRSI=-1;
datetime g_lastEntryTime=0,g_lastBarTime=0,g_recoveryStartTime=0;
TrendDirection g_lastTrend=TREND_NONE;
CampaignState g_state=CAMPAIGN_IDLE;
bool g_closePending=false;
double g_campaignPeakProfit=0.0;
bool g_campaignPeakActive=false;
int g_recoveryAttempts=0;
double g_recoveryPeakProfit=0.0;
bool g_recoveryPeakActive=false;

string GVPeak(){return "TRENDREC_PEAK_"+(string)MagicNumber+"_"+_Symbol;}
string GVDaily(){return "TRENDREC_DAYEQ_"+(string)MagicNumber+"_"+_Symbol;}
string GVDay(){return "TRENDREC_DAY_"+(string)MagicNumber+"_"+_Symbol;}
void Log(string s){if(EnableLogging)Print("[TrendRecoveryEA] ",s);}
int VolumeDigits(){double x=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);int d=0;while(d<8&&MathAbs(x-MathRound(x))>1e-10){x*=10.0;d++;}return d;}
double NormalizeLot(double lot){double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);if(mn<=0||mx<=0||st<=0)return 0;lot=MathMin(lot,MathMin(mx,MaxLot));lot=MathMax(lot,mn);lot=MathFloor(lot/st+1e-9)*st;if(lot<mn)lot=mn;return NormalizeDouble(lot,VolumeDigits());}
double NormalizePrice(double p){return NormalizeDouble(p,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));}
double MinStopDistance(){long a=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),b=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);return (double)MathMax(a,b)*_Point;}
bool TradeSucceeded(){uint r=trade.ResultRetcode();return r==TRADE_RETCODE_DONE||r==TRADE_RETCODE_DONE_PARTIAL||r==TRADE_RETCODE_PLACED;}
bool IsHedgingAccount(){return (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;}
bool IsSpreadAcceptable(){if(MaximumSpread<=0)return true;MqlTick t;if(!SymbolInfoTick(_Symbol,t))return false;return (t.ask-t.bid)/_Point<=MaximumSpread;}
bool IsTradingSession(){if(!UseTradingSession)return true;MqlDateTime d;TimeToStruct(TimeTradeServer(),d);if(TradingStartHour==TradingEndHour)return true;if(TradingStartHour<TradingEndHour)return d.hour>=TradingStartHour&&d.hour<TradingEndHour;return d.hour>=TradingStartHour||d.hour<TradingEndHour;}
bool IsNewBar(){datetime t=iTime(_Symbol,TrendTimeframe,0);if(t<=0)return false;if(t!=g_lastBarTime){g_lastBarTime=t;return true;}return false;}
bool Buf(int h,int b,int sh,double &v){if(h<0)return false;double x[1];if(CopyBuffer(h,b,sh,1,x)!=1)return false;v=x[0];return true;}
bool GetATR(double &v){return Buf(hATR,0,1,v);}

TrendDirection DetectTrend(){double f,s,tr,ht,a,atr,r;if(!Buf(hFastEMA,0,1,f)||!Buf(hSlowEMA,0,1,s)||!Buf(hTrendEMA,0,1,tr)||!Buf(hHTFEMA,0,1,ht)||!Buf(hADX,0,1,a)||!GetATR(atr))return TREND_NONE;double c=iClose(_Symbol,TrendTimeframe,1);if(c<=0||a<MinimumADX)return TREND_NONE;if(MaximumATRPoints>0&&atr/_Point>MaximumATRPoints)return TREND_NONE;bool buy=f>s&&c>tr&&c>ht,sell=f<s&&c<tr&&c<ht;if(UseRSIConfirmation){if(!Buf(hRSI,0,1,r))return TREND_NONE;buy=buy&&r>=RSIForBuy;sell=sell&&r<=RSIForSell;}if(buy)return TREND_BUY;if(sell)return TREND_SELL;return TREND_NONE;}
bool ConfirmTrend(TrendDirection dir){int n=MathMax(1,ReversalConfirmationBars);for(int sh=1;sh<=n;sh++){double f,s,tr,ht,a,atr,r;if(!Buf(hFastEMA,0,sh,f)||!Buf(hSlowEMA,0,sh,s)||!Buf(hTrendEMA,0,sh,tr)||!Buf(hHTFEMA,0,sh,ht)||!Buf(hADX,0,sh,a)||!Buf(hATR,0,sh,atr))return false;double c=iClose(_Symbol,TrendTimeframe,sh);if(c<=0||a<MinimumADX)return false;if(MaximumATRPoints>0&&atr/_Point>MaximumATRPoints)return false;bool ok=(dir==TREND_BUY)?f>s&&c>tr&&c>ht:f<s&&c<tr&&c<ht;if(UseRSIConfirmation){if(!Buf(hRSI,0,sh,r))return false;ok=ok&&((dir==TREND_BUY)?r>=RSIForBuy:r<=RSIForSell);}if(!ok)return false;}return true;}
bool ConfirmReversal(TrendDirection dir){int n=MathMax(2,RecoveryConfirmationBars);for(int sh=1;sh<=n;sh++){double f,atr;if(!Buf(hFastEMA,0,sh,f)||!Buf(hATR,0,sh,atr))return false;if(MaximumATRPoints>0&&atr/_Point>MaximumATRPoints)return false;double c=iClose(_Symbol,TrendTimeframe,sh),o=iOpen(_Symbol,TrendTimeframe,sh);if(c<=0||o<=0)return false;bool directional=(dir==TREND_BUY)?c>o:c<o;bool fastSide=(dir==TREND_BUY)?c>f:c<f;if(!directional||!fastSide)return false;}double f1,f2,f3;if(!Buf(hFastEMA,0,1,f1)||!Buf(hFastEMA,0,2,f2)||!Buf(hFastEMA,0,3,f3))return false;bool slopeOK=(dir==TREND_BUY)?f1>=f2&&f2>=f3:f1<=f2&&f2<=f3;if(!slopeOK)return false;if(UseRSIConfirmation){double r;if(!Buf(hRSI,0,1,r))return false;if(dir==TREND_BUY&&r<RSIForBuy)return false;if(dir==TREND_SELL&&r>RSIForSell)return false;}return true;}

int CountPositions(){int n=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)==_Symbol&&(long)PositionGetInteger(POSITION_MAGIC)==MagicNumber)n++;}return n;}
int CountRecoveryPositions(){int n=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;if(StringFind(PositionGetString(POSITION_COMMENT),"RECOVERY")>=0)n++;}return n;}
double BasketProfit(){double p=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;p+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);}return p;}
double NormalProfit(){double p=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;if(StringFind(PositionGetString(POSITION_COMMENT),"RECOVERY")>=0)continue;p+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);}return p;}
double RecoveryProfit(){double p=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;if(StringFind(PositionGetString(POSITION_COMMENT),"RECOVERY")<0)continue;p+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);}return p;}
TrendDirection OriginalDirection(){for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;if(StringFind(PositionGetString(POSITION_COMMENT),"RECOVERY")>=0)continue;ENUM_POSITION_TYPE ty=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);if(ty==POSITION_TYPE_BUY)return TREND_BUY;if(ty==POSITION_TYPE_SELL)return TREND_SELL;}return TREND_NONE;}
datetime CampaignStart(){datetime x=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;datetime p=(datetime)PositionGetInteger(POSITION_TIME);if(x==0||p<x)x=p;}return x;}

bool EquityLocked(){if(MaxEquityDrawdownPercent<=0)return false;double e=AccountInfoDouble(ACCOUNT_EQUITY),p=GlobalVariableGet(GVPeak());if(p<=0){p=e;GlobalVariableSet(GVPeak(),p);}if(e>p){p=e;GlobalVariableSet(GVPeak(),p);}return p>0&&(p-e)/p*100.0>=MaxEquityDrawdownPercent;}
void DailyState(){MqlDateTime d;TimeToStruct(TimeTradeServer(),d);long day=(long)d.year*10000+(long)d.mon*100+d.day;if(GlobalVariableGet(GVDay())!=(double)day){GlobalVariableSet(GVDay(),(double)day);GlobalVariableSet(GVDaily(),AccountInfoDouble(ACCOUNT_EQUITY));}}
bool DailyLocked(){DailyState();double s=GlobalVariableGet(GVDaily());if(s<=0)return false;double loss=s-AccountInfoDouble(ACCOUNT_EQUITY);return (MaxDailyLossUSD>0&&loss>=MaxDailyLossUSD)||(MaxDailyLossPercent>0&&loss/s*100.0>=MaxDailyLossPercent);}

bool CloseCampaign(){bool ok=true;bool locked=(g_state==CAMPAIGN_LOCKED);g_state=CAMPAIGN_EXIT;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;trade.SetExpertMagicNumber(MagicNumber);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);bool sent=trade.PositionClose(t);if(!sent||!TradeSucceeded()){ok=false;Log("Close failed ticket="+(string)t+" retcode="+(string)trade.ResultRetcode()+" "+trade.ResultRetcodeDescription());}}g_closePending=CountPositions()>0;if(!g_closePending&&ok){g_state=locked?CAMPAIGN_LOCKED:CAMPAIGN_IDLE;g_campaignPeakProfit=0;g_campaignPeakActive=false;g_recoveryAttempts=0;g_recoveryStartTime=0;g_recoveryPeakProfit=0;g_recoveryPeakActive=false;}return ok;}
void RiskEngine(){if(EquityLocked()){g_state=CAMPAIGN_LOCKED;if(ClosePositionsOnEquityProtection&&CountPositions()>0)CloseCampaign();return;}if(DailyLocked()){g_state=CAMPAIGN_LOCKED;if(ClosePositionsOnDailyProtection&&CountPositions()>0)CloseCampaign();return;}if(MaxCampaignLossUSD>0&&BasketProfit()<=-MaxCampaignLossUSD){CloseCampaign();return;}if(MaxCampaignHours>0&&CountPositions()>0){datetime s=CampaignStart();if(s>0&&TimeCurrent()-s>=MaxCampaignHours*3600)CloseCampaign();}}

bool HasDistance(TrendDirection d){if(MinimumEntryDistance<=0)return true;MqlTick t;if(!SymbolInfoTick(_Symbol,t))return false;double p=d==TREND_BUY?t.ask:t.bid;for(int i=PositionsTotal()-1;i>=0;i--){ulong x=PositionGetTicket(i);if(x==0||!PositionSelectByTicket(x))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;if(MathAbs(p-PositionGetDouble(POSITION_PRICE_OPEN))<MinimumEntryDistance)return false;}return true;}
bool CanOpen(TrendDirection d){if(d==TREND_NONE||g_state==CAMPAIGN_LOCKED||g_closePending)return false;if(EquityLocked()||DailyLocked()||!IsTradingSession()||!IsSpreadAcceptable())return false;if(CountPositions()>=MaximumPositions)return false;if(MaximumExposurePositions>0&&CountPositions()>=MaximumExposurePositions)return false;if(g_lastEntryTime>0&&TimeCurrent()-g_lastEntryTime<EntryCooldownSeconds)return false;return HasDistance(d)&&ConfirmTrend(d);}
double EntryLot(){return NormalizeLot(UseEquityScaling&&BaseEquity>0?BaseLot*AccountInfoDouble(ACCOUNT_EQUITY)/BaseEquity:InitialLot);}
double MoneyDistance(double money,double vol){if(money<=0||vol<=0)return 0;double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);if(tv<=0||ts<=0)return 0;return money/(tv*vol)*ts;}
bool ValidSL(ENUM_POSITION_TYPE ty,double sl){MqlTick t;if(!SymbolInfoTick(_Symbol,t))return false;double d=MinStopDistance();return ty==POSITION_TYPE_BUY?sl<=t.bid-d:sl>=t.ask+d;}
bool ModifySL(ulong ticket,double sl){if(!PositionSelectByTicket(ticket))return false;ENUM_POSITION_TYPE ty=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);double old=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP);sl=NormalizePrice(sl);if(!ValidSL(ty,sl))return false;if(ty==POSITION_TYPE_BUY&&old>0&&sl<=old+_Point)return false;if(ty==POSITION_TYPE_SELL&&old>0&&sl>=old-_Point)return false;trade.SetExpertMagicNumber(MagicNumber);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);return trade.PositionModify(ticket,sl,tp)&&TradeSucceeded();}

bool OpenTrade(TrendDirection d,string comment,double lot,double slMult){MqlTick t;if(!SymbolInfoTick(_Symbol,t))return false;double atr;if(!GetATR(atr))return false;double p=d==TREND_BUY?t.ask:t.bid,sl=0;if(slMult>0){double dist=MathMax(atr*slMult,MinStopDistance());sl=NormalizePrice(d==TREND_BUY?p-dist:p+dist);}trade.SetExpertMagicNumber(MagicNumber);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);bool sent=d==TREND_BUY?trade.Buy(lot,_Symbol,0,sl,0,comment):trade.Sell(lot,_Symbol,0,sl,0,comment);return sent&&TradeSucceeded();}
bool OpenRecoveryTrade(TrendDirection d,double lot){MqlTick t;if(!SymbolInfoTick(_Symbol,t))return false;double atr;if(!GetATR(atr))return false;double atrDist=MathMax(atr*RecoverySL_ATR,MinStopDistance());double riskDist=MoneyDistance(RecoveryMaxLossPerTradeUSD,lot);double dist=atrDist;if(RecoveryMaxLossPerTradeUSD>0&&riskDist>0)dist=MathMin(atrDist,MathMax(riskDist,MinStopDistance()));double p=d==TREND_BUY?t.ask:t.bid;double sl=NormalizePrice(d==TREND_BUY?p-dist:p+dist);trade.SetExpertMagicNumber(MagicNumber);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);bool sent=d==TREND_BUY?trade.Buy(lot,_Symbol,0,sl,0,"RECOVERY BUY"):trade.Sell(lot,_Symbol,0,sl,0,"RECOVERY SELL");if(sent&&TradeSucceeded()){g_recoveryStartTime=TimeCurrent();return true;}return false;}

void PositionProtection(ulong ticket){if(!PositionSelectByTicket(ticket))return;ENUM_POSITION_TYPE ty=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);double profit=PositionGetDouble(POSITION_PROFIT),open=PositionGetDouble(POSITION_PRICE_OPEN),vol=PositionGetDouble(POSITION_VOLUME),sl=0;if(UseATRTrailing&&profit>=ATRTrailingStartUSD){double atr;MqlTick t;if(GetATR(atr)&&SymbolInfoTick(_Symbol,t))sl=ty==POSITION_TYPE_BUY?t.bid-atr*ATRTrailingMultiplier:t.ask+atr*ATRTrailingMultiplier;}else if(UseProfitLock&&profit>=ProfitLockStartUSD&&ProfitLockStepUSD>0){int n=(int)MathFloor((profit-ProfitLockStartUSD)/ProfitLockStepUSD)+1;double locked=ProfitLockOffsetUSD+(n-1)*ProfitLockStepUSD,dist=MoneyDistance(locked,vol);if(dist>0)sl=ty==POSITION_TYPE_BUY?open+dist:open-dist;}else if(UseBreakEven&&profit>=BreakEvenStartUSD){double dist=MoneyDistance(BreakEvenOffsetUSD,vol);if(dist>0)sl=ty==POSITION_TYPE_BUY?open+dist:open-dist;}if(sl>0)ModifySL(ticket,sl);}
void ProfitEngine(){for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;PositionProtection(t);}}

void EntryEngine(TrendDirection d){if(g_state==CAMPAIGN_LOCKED||g_closePending||CountPositions()>0||d==TREND_NONE)return;if(CanOpen(d)){double lot=EntryLot();if(lot>0&&OpenTrade(d,"TREND "+(d==TREND_BUY?"BUY":"SELL"),lot,UseInitialSL?InitialSL_ATR:0)){g_lastEntryTime=TimeCurrent();g_state=CAMPAIGN_TREND;g_campaignPeakProfit=BasketProfit();g_campaignPeakActive=true;}}}

bool StartRecovery(TrendDirection rev){if(!UseRecovery||rev==TREND_NONE)return false;if(g_recoveryAttempts>=1)return false;if(CountRecoveryPositions()>=MaxRecoveryPositions)return false;if(RequireHedgingAccountForRecovery&&!IsHedgingAccount()){if(CloseOnStrongReversalIfNoRecovery)CloseCampaign();return false;}TrendDirection orig=OriginalDirection();if(orig==TREND_NONE||rev==orig)return false;double normal=NormalProfit();if(normal>=0||MathAbs(normal)<RecoveryTriggerUSD)return false;if(MaximumExposurePositions>0&&CountPositions()>=MaximumExposurePositions)return false;if(MaximumExposurePositions>0&&MaximumExposurePositions<2)return false;if(!IsSpreadAcceptable())return false;if(!ConfirmReversal(rev))return false;double baseLot=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;if(StringFind(PositionGetString(POSITION_COMMENT),"RECOVERY")>=0)continue;baseLot+=PositionGetDouble(POSITION_VOLUME);}if(baseLot<=0)return false;double lot=NormalizeLot(MathMin(baseLot*RecoveryMultiplier,MaxRecoveryLot));if(lot<=0)return false;if(OpenRecoveryTrade(rev,lot)){g_recoveryAttempts=1;g_state=CAMPAIGN_RECOVERY;Log("Recovery opened with capped risk lot="+DoubleToString(lot,2));return true;}return false;}
void ReversalEngine(){TrendDirection orig=OriginalDirection();if(orig==TREND_NONE)return;if(NormalProfit()>-RecoveryTriggerUSD)return;TrendDirection rev=orig==TREND_BUY?TREND_SELL:TREND_BUY;if(!ConfirmReversal(rev))return;if(UseRecovery&&StartRecovery(rev))return;if(!UseRecovery&&CloseOnStrongReversalIfNoRecovery)CloseCampaign();}

bool CampaignExit(){if(CountPositions()<=0){g_campaignPeakProfit=0;g_campaignPeakActive=false;return false;}double p=BasketProfit();if(!g_campaignPeakActive){g_campaignPeakProfit=p;g_campaignPeakActive=true;}if(p>g_campaignPeakProfit)g_campaignPeakProfit=p;if(CampaignProfitTargetUSD>0&&p>=CampaignProfitTargetUSD){CloseCampaign();return true;}if(CampaignProfitTrailStartUSD>0&&CampaignProfitGivebackUSD>0&&g_campaignPeakProfit>=CampaignProfitTrailStartUSD&&(g_campaignPeakProfit-p)>=CampaignProfitGivebackUSD&&p>0){CloseCampaign();return true;}return false;}

void ResetRecoveryState(){g_recoveryPeakProfit=0;g_recoveryPeakActive=false;g_recoveryStartTime=0;}
void RecoveryProfitLock(){if(RecoveryLockStartUSD<=0||RecoveryLockProfitUSD<=0)return;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;if(StringFind(PositionGetString(POSITION_COMMENT),"RECOVERY")<0)continue;double profit=PositionGetDouble(POSITION_PROFIT);if(profit<RecoveryLockStartUSD)continue;ENUM_POSITION_TYPE ty=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);double vol=PositionGetDouble(POSITION_VOLUME),open=PositionGetDouble(POSITION_PRICE_OPEN),dist=MoneyDistance(RecoveryLockProfitUSD,vol);if(dist<=0)continue;double sl=ty==POSITION_TYPE_BUY?open+dist:open-dist;MqlTick tick;if(!SymbolInfoTick(_Symbol,tick))continue;double md=MinStopDistance();sl=ty==POSITION_TYPE_BUY?MathMin(sl,tick.bid-md):MathMax(sl,tick.ask+md);ModifySL(t,NormalizePrice(sl));}}
void RecoveryProfitTrail(double recoveryProfit){if(RecoveryTrailStartUSD<=0||RecoveryTrailGivebackUSD<=0||recoveryProfit<RecoveryTrailStartUSD)return;if(!g_recoveryPeakActive){g_recoveryPeakProfit=recoveryProfit;g_recoveryPeakActive=true;}if(recoveryProfit>g_recoveryPeakProfit)g_recoveryPeakProfit=recoveryProfit;double locked=g_recoveryPeakProfit-RecoveryTrailGivebackUSD;if(locked<=0)return;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;if(StringFind(PositionGetString(POSITION_COMMENT),"RECOVERY")<0)continue;ENUM_POSITION_TYPE ty=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);double vol=PositionGetDouble(POSITION_VOLUME),open=PositionGetDouble(POSITION_PRICE_OPEN),dist=MoneyDistance(locked,vol);if(dist<=0)continue;double sl=ty==POSITION_TYPE_BUY?open+dist:open-dist;MqlTick tick;if(!SymbolInfoTick(_Symbol,tick))continue;double md=MinStopDistance();sl=ty==POSITION_TYPE_BUY?MathMin(sl,tick.bid-md):MathMax(sl,tick.ask+md);ModifySL(t,NormalizePrice(sl));}}

void RecoveryTimeoutExit(double normal,double recovery,double basket){if(!RecoveryCloseOnFailure||RecoveryTimeoutMinutes<=0||g_recoveryStartTime<=0)return;if(TimeCurrent()-g_recoveryStartTime<RecoveryTimeoutMinutes*60)return;if(recovery>=RecoveryTargetUSD)return;if(basket>=RecoveryMinimumBasketProfitUSD)return;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;if(StringFind(PositionGetString(POSITION_COMMENT),"RECOVERY")<0)continue;trade.SetExpertMagicNumber(MagicNumber);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);bool sent=trade.PositionClose(t);if(sent&&TradeSucceeded())Log("Recovery timeout: recovery leg closed; original position left under normal protection.");}ResetRecoveryState();g_state=CountPositions()>0?CAMPAIGN_TREND:CAMPAIGN_IDLE;}

void RecoveryEngine(){if(CountRecoveryPositions()<=0){ResetRecoveryState();return;}g_state=CAMPAIGN_RECOVERY;double recovery=RecoveryProfit(),normal=NormalProfit(),basket=normal+recovery;if(!g_recoveryPeakActive){g_recoveryPeakProfit=recovery;g_recoveryPeakActive=true;}if(recovery>g_recoveryPeakProfit)g_recoveryPeakProfit=recovery;if(RecoveryMaxLossUSD>0&&recovery<=-RecoveryMaxLossUSD){for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t==0||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(long)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;if(StringFind(PositionGetString(POSITION_COMMENT),"RECOVERY")<0)continue;trade.SetExpertMagicNumber(MagicNumber);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);trade.PositionClose(t);}ResetRecoveryState();return;}if(RecoveryTargetUSD>0&&recovery>=RecoveryTargetUSD&&basket>=RecoveryMinimumBasketProfitUSD){CloseCampaign();return;}RecoveryProfitLock();RecoveryProfitTrail(recovery);RecoveryTimeoutExit(normal,recovery,basket);}

void ManagePositions(){if(CountPositions()<=0){g_campaignPeakProfit=0;g_campaignPeakActive=false;ResetRecoveryState();if(!g_closePending&&g_state!=CAMPAIGN_LOCKED){g_state=CAMPAIGN_IDLE;g_recoveryAttempts=0;}return;}if(CampaignExit())return;if(CountRecoveryPositions()>0){RecoveryEngine();if(CountPositions()>0)ProfitEngine();return;}ReversalEngine();if(CountPositions()<=0)return;ProfitEngine();g_state=BasketProfit()>0?CAMPAIGN_PROFIT:CAMPAIGN_TREND;}
void TrendLog(TrendDirection d){if(!LogTrendChanges||d==g_lastTrend)return;Log("Trend="+(d==TREND_BUY?"BUY":d==TREND_SELL?"SELL":"NONE"));g_lastTrend=d;}

int OnInit(){trade.SetExpertMagicNumber(MagicNumber);trade.SetDeviationInPoints(SlippagePoints);trade.SetTypeFillingBySymbol(_Symbol);hFastEMA=iMA(_Symbol,TrendTimeframe,FastEMAPeriod,0,MODE_EMA,PRICE_CLOSE);hSlowEMA=iMA(_Symbol,TrendTimeframe,SlowEMAPeriod,0,MODE_EMA,PRICE_CLOSE);hTrendEMA=iMA(_Symbol,TrendTimeframe,TrendEMAPeriod,0,MODE_EMA,PRICE_CLOSE);hHTFEMA=iMA(_Symbol,HigherTimeframe,TrendEMAPeriod,0,MODE_EMA,PRICE_CLOSE);hADX=iADX(_Symbol,TrendTimeframe,ADXPeriod);hATR=iATR(_Symbol,TrendTimeframe,14);hRSI=iRSI(_Symbol,TrendTimeframe,RSIPeriod,PRICE_CLOSE);if(hFastEMA<0||hSlowEMA<0||hTrendEMA<0||hHTFEMA<0||hADX<0||hATR<0||hRSI<0)return INIT_FAILED;double e=AccountInfoDouble(ACCOUNT_EQUITY);if(!GlobalVariableCheck(GVPeak())||GlobalVariableGet(GVPeak())<=0)GlobalVariableSet(GVPeak(),e);DailyState();int n=CountPositions();g_state=n>0?(CountRecoveryPositions()>0?CAMPAIGN_RECOVERY:CAMPAIGN_TREND):CAMPAIGN_IDLE;if(n>0){g_campaignPeakProfit=BasketProfit();g_campaignPeakActive=true;}return INIT_SUCCEEDED;}
void OnDeinit(const int reason){if(hFastEMA>=0)IndicatorRelease(hFastEMA);if(hSlowEMA>=0)IndicatorRelease(hSlowEMA);if(hTrendEMA>=0)IndicatorRelease(hTrendEMA);if(hHTFEMA>=0)IndicatorRelease(hHTFEMA);if(hADX>=0)IndicatorRelease(hADX);if(hATR>=0)IndicatorRelease(hATR);if(hRSI>=0)IndicatorRelease(hRSI);}
void OnTick(){DailyState();if(g_closePending){if(CountPositions()==0){g_closePending=false;if(g_state!=CAMPAIGN_LOCKED)g_state=CAMPAIGN_IDLE;}else{ProfitEngine();return;}}TrendDirection trend=DetectTrend();TrendLog(trend);RiskEngine();if(g_state==CAMPAIGN_EXIT||g_closePending){if(CountPositions()==0&&g_state!=CAMPAIGN_LOCKED)g_state=CAMPAIGN_IDLE;return;}ManagePositions();if(g_state==CAMPAIGN_LOCKED||g_closePending)return;if(UseNewBarForEntry&&!IsNewBar())return;EntryEngine(trend);}
