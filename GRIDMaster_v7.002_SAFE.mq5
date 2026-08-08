//================================================================================================//
// GRIDMaster v7.002 - RECOVERY / SURVIVAL FIX
// Safe wrapper around GRIDMaster.mq5
//
// FIXES:
// 1) SURVIVAL no longer closes the entire side at once.
//    It reduces exposure one losing position at a time.
// 2) SURVIVAL is a hard no-entry state until DD recovers.
// 3) Recovery reductions impose a longer re-entry freeze to prevent
//    immediate rebuilding of the same risk.
// 4) Recovery/SURVIVAL is capped by the existing MaxReductionActions budget.
// 5) Anomaly brake now has hysteresis: persistent abnormal spread does not
//    repeatedly create a new 60-second brake/log cycle.
// 6) Existing entry/grid/profit logic is intentionally preserved.
//
// The original GRIDMaster.mq5 remains untouched and is included below.
//================================================================================================//
#property strict
#property copyright "Copyright 2026, Jarvis"
#property version   "7.002"
#property description "GRIDMaster v7.002 - Recovery/Suvival Risk Governor Fix"

// Rename the original functions before inclusion so the wrapper can replace
// only the two logic points identified by the backtest audit.
#define RecoveryGovernor RecoveryGovernor_V7001
#define MarketHealthy    MarketHealthy_V7001
#include "GRIDMaster.mq5"
#undef RecoveryGovernor
#undef MarketHealthy

//================================================================================================//
// SAFETY CONSTANTS
// These are deliberately not input parameters: the existing tester inputs remain
// unchanged, while the protection behavior is made stricter internally.
//================================================================================================//
#define SURVIVAL_REENTRY_FREEZE_SEC 120
#define ANOMALY_RESET_RATIO         0.70

//================================================================================================//
// MARKET HEALTH - HYSTERESIS FIX
// Persistent abnormal spread must first normalize below 70% of the trigger before
// the anomaly latch is released. This prevents repeated BRAKE -> expire -> BRAKE cycles.
//================================================================================================//
bool MarketHealthy()
{
   double bid=SymbolInfoDouble(SymbolTrade,SYMBOL_BID);
   double ask=SymbolInfoDouble(SymbolTrade,SYMBOL_ASK);
   if(bid<=0||ask<=0||ask<bid||_Point<=0)return false;

   datetime now=TimeCurrent();
   double spread=(ask-bid)/_Point;
   double mid=(bid+ask)*0.5;

   // Keep the last price current while the brake is active, but NEVER extend
   // AnomalyUntil on every tick.
   if(AnomalyBrakeActive)
   {
      LastMidPrice=mid;

      if(now<AnomalyUntil)
         return false;

      // Cooldown expired, but the abnormal condition is still present.
      // Keep the latch active silently until the market actually normalizes.
      double resetSpread=AnomalySpreadPoints*ANOMALY_RESET_RATIO;
      if(AnomalySpreadPoints>0 && spread>=resetSpread)
         return false;

      AnomalyBrakeActive=false;
      AnomalyUntil=0;
   }

   bool anomaly=false;
   if(AnomalySpreadPoints>0 && spread>=AnomalySpreadPoints)
      anomaly=true;
   else if(LastMidPrice>0 && AnomalyJumpPoints>0 && MathAbs(mid-LastMidPrice)/_Point>=AnomalyJumpPoints)
      anomaly=true;

   LastMidPrice=mid;

   if(anomaly)
   {
      AnomalyBrakeActive=true;
      AnomalyUntil=now+AnomalyCooldownSec;
      return false;
   }

   return true;
}

//================================================================================================//
// FIND LARGEST LOSING POSITION ON ONE SIDE
// Priority is exposure volume first, then dollar loss. This is intentional:
// Survival should remove the largest exposure with the smallest practical
// realized-loss hit, rather than flattening the entire basket.
//================================================================================================//
ulong LargestLosingTicketBySide(ENUM_POSITION_TYPE wantedType)
{
   ulong best=0;
   double bestLoss=0.0;
   double bestVol=0.0;
   datetime oldest=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0||!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=OrdersID||PositionGetString(POSITION_SYMBOL)!=SymbolTrade)continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=wantedType)continue;

      double p=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(p>=0)continue;

      double loss=-p;
      double vol=PositionGetDouble(POSITION_VOLUME);
      datetime ot=(datetime)PositionGetInteger(POSITION_TIME);

      if(vol>bestVol+1e-8 ||
         (MathAbs(vol-bestVol)<=1e-8 && loss>bestLoss+1e-8) ||
         (MathAbs(vol-bestVol)<=1e-8 && MathAbs(loss-bestLoss)<=1e-8 && (oldest==0||ot<oldest)))
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
// REDUCE ONE SIDE ONLY
//================================================================================================//
bool ReduceLargestLosingSide(ENUM_POSITION_TYPE type,string reason)
{
   ulong ticket=LargestLosingTicketBySide(type);
   if(ticket==0||!PositionSelectByTicket(ticket))return false;

   double loss=-(PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP));
   double vol=PositionGetDouble(POSITION_VOLUME);

   if(!ClosePosition(ticket,reason))return false;

   ReductionActions++;
   LastRecoveryAction=TimeCurrent();

   // Critical fix: recovery must NOT immediately rebuild the same exposure.
   // Use at least 120 seconds even if RecoveryFreezeSec is configured lower.
   int freezeSeconds=(int)MathMax(RecoveryFreezeSec,SURVIVAL_REENTRY_FREEZE_SEC);
   FreezeGridUntil=TimeCurrent()+freezeSeconds;
   RecoveryActionThisTick=true;

   PrintFormat("[SURVIVAL] REDUCE | ticket=%I64u | side=%s | lot=%.4f | loss=%.2f | action=%d/%d | freeze=%ds",
               ticket,EnumToString(type),vol,loss,ReductionActions,MaxReductionActions,freezeSeconds);
   return true;
}

//================================================================================================//
// RECOVERY GOVERNOR - v7.002 FIX
//================================================================================================//
void RecoveryGovernor(double dd)
{
   if(BuyOrders+SellOrders==0)
      return;

   if(TimeCurrent()<FreezeGridUntil)
      return;

   if((TimeCurrent()-LastRecoveryAction)<RecoveryCooldownSec)
      return;

   double buyLoss=BasketLoss(POSITION_TYPE_BUY);
   double sellLoss=BasketLoss(POSITION_TYPE_SELL);

   bool active=(dd>=RecoveryStartDD);
   bool aggressive=(dd>=AggressiveRecoveryDD);
   bool survival=(dd>=SurvivalDD);

   //--------------------------------------------------------------------------------------------//
   // SURVIVAL MODE
   // NEVER flatten the entire side just because the basket exceeds $45.
   // Remove ONE losing position, then freeze new entries and reassess.
   //--------------------------------------------------------------------------------------------//
   if(survival)
   {
      CurrentState=STATE_SURVIVAL;

      // Existing MaxReductionActions becomes the survival/recovery loss budget.
      // Once exhausted, NO further discretionary reduction is performed here.
      if(ReductionActions>=MaxReductionActions)
         return;

      if(buyLoss>=SurvivalBasketLossUSD || sellLoss>=SurvivalBasketLossUSD)
      {
         ENUM_POSITION_TYPE side;
         if(buyLoss>=SurvivalBasketLossUSD && buyLoss>=sellLoss)
            side=POSITION_TYPE_BUY;
         else
            side=POSITION_TYPE_SELL;

         if(ReduceLargestLosingSide(side,"SURVIVAL-REDUCE"))
            return;
      }

      // Stay in SURVIVAL even when the basket is below the trigger.
      // New entries remain blocked by OnTick because CurrentState != NORMAL.
      return;
   }

   //--------------------------------------------------------------------------------------------//
   // NORMAL RECOVERY
   // Keep the existing reduction mechanism, but impose a longer re-entry freeze.
   //--------------------------------------------------------------------------------------------//
   bool danger=(buyLoss>=MaxBasketLossUSD || sellLoss>=MaxBasketLossUSD);

   if((danger||active) && (aggressive||danger) && ReductionActions<MaxReductionActions)
   {
      if(ReduceLargestLoser("RECOVERY"))
      {
         int freezeSeconds=(int)MathMax(RecoveryFreezeSec,SURVIVAL_REENTRY_FREEZE_SEC);
         FreezeGridUntil=TimeCurrent()+freezeSeconds;
         return;
      }
   }

   if(dd>=SoftLimit() &&
      (buyLoss>=MinRecoveryLossUSD || sellLoss>=MinRecoveryLossUSD) &&
      ReductionActions<MaxReductionActions)
   {
      if(ReduceLargestLoser("SOFT-DD"))
      {
         int freezeSeconds=(int)MathMax(RecoveryFreezeSec,SURVIVAL_REENTRY_FREEZE_SEC);
         FreezeGridUntil=TimeCurrent()+freezeSeconds;
         return;
      }
   }
}

//================================================================================================//
// END
//================================================================================================//
