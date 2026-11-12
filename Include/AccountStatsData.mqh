// Calendar buckets and balance ledger. No chart, account access or trading calls.
#define ASP_DAY_SECONDS 86400

struct SStats
  {
   double lots;
   long orders;
   double min_lot;
   double max_lot;
   double profit;
   double deposits;
   double withdrawals;
   double delta;
   double opening;
   double balance;
   double loss;
   double loss_pct;
   double gain;
   double gain_pct;
   bool sampled;
  };

struct SDay
  {
   datetime day;
   SStats data;
   bool activity;
  };

struct SBucket
  {
   datetime start;
   datetime end;
   SStats data;
  };

// Numeric fields only, for FileReadStruct / FileWriteStruct.
struct SFloatDay
  {
   datetime day;
   datetime first;
   datetime last;
   double loss;
   double loss_pct;
   double gain;
   double gain_pct;
  };

SDay g_days[];
SDay g_work_days[];
SBucket g_rows[]; // chronological; the table displays these in reverse order
SFloatDay g_float_days[];
SStats g_total;
datetime g_effective_from=0;
datetime g_effective_to=0;
double g_history_balance=0;

void EmptyStats(SStats &s)
  {
   ZeroMemory(s);
  }

datetime DayStart(const datetime value)
  {
   MqlDateTime t;
   if(!TimeToStruct(value,t)) return value-(value%ASP_DAY_SECONDS);
   t.hour=0;
   t.min=0;
   t.sec=0;
   return StructToTime(t);
  }

datetime BucketStart(const datetime value,const int tab)
  {
   datetime day=DayStart(value);
   if(tab==0) return day;
   MqlDateTime t;
   TimeToStruct(day,t);
   if(tab==1) return day-((t.day_of_week+6)%7)*ASP_DAY_SECONDS;
   t.day=1;
   if(tab==3) t.mon=1;
   return StructToTime(t);
  }

datetime NextBucket(const datetime start,const int tab)
  {
   if(tab==0) return start+ASP_DAY_SECONDS;
   if(tab==1) return start+7*ASP_DAY_SECONDS;
   MqlDateTime t;
   TimeToStruct(start,t);
   if(tab==2)
     {
      t.mon++;
      if(t.mon>12) { t.mon=1; t.year++; }
     }
   else t.year++;
   return StructToTime(t);
  }

int FindDay(const datetime day)
  {
   int lo=0,hi=ArraySize(g_days);
   while(lo<hi)
     {
      int mid=(lo+hi)/2;
      if(g_days[mid].day<day) lo=mid+1;
      else hi=mid;
     }
   return lo;
  }

int EnsureLedgerDay(SDay &days[],const datetime value)
  {
   int n=ArraySize(days);
   if(n>0 && value>=days[n-1].day && value<days[n-1].day+ASP_DAY_SECONDS) return n-1;
   datetime day=DayStart(value);
   // History is normally returned chronologically. Appending avoids a binary
   // search and a tail move for every deal/order in a large account history.
   if(n>0)
     {
      datetime last=days[n-1].day;
      if(day==last) return n-1;
      if(day>last)
        {
         ArrayResize(days,n+1,512);
         days[n].day=day;
         days[n].activity=false;
         EmptyStats(days[n].data);
         return n;
        }
     }
   int pos=0,hi=n;
   while(pos<hi)
     {
      int mid=(pos+hi)/2;
      if(days[mid].day<day) pos=mid+1;
      else hi=mid;
     }
   if(pos<n && days[pos].day==day) return pos;
   ArrayResize(days,n+1,512);
   for(int i=n;i>pos;i--) days[i]=days[i-1];
   days[pos].day=day;
   days[pos].activity=false;
   EmptyStats(days[pos].data);
   return pos;
  }

int EnsureDay(const datetime value) { return EnsureLedgerDay(g_days,value); }

void RebuildDayBalances()
  {
   double running=g_history_balance;
   for(int i=ArraySize(g_days)-1;i>=0;i--)
     {
      g_days[i].data.balance=running;
      running-=g_days[i].data.delta;
      g_days[i].data.opening=running;
     }
  }

void AddMinMax(SStats &s,const double minimum,const double maximum)
  {
   if(minimum>0 && (s.min_lot<=0 || minimum<s.min_lot)) s.min_lot=minimum;
   if(maximum>s.max_lot) s.max_lot=maximum;
  }

void AddStats(SStats &dest,const SStats &src)
  {
   dest.lots+=src.lots;
   dest.orders+=src.orders;
   dest.profit+=src.profit;
   dest.deposits+=src.deposits;
   dest.withdrawals+=src.withdrawals;
   dest.delta+=src.delta;
   AddMinMax(dest,src.min_lot,src.max_lot);
   if(src.sampled)
     {
      dest.sampled=true;
      dest.loss=MathMin(dest.loss,src.loss);
      dest.loss_pct=MathMin(dest.loss_pct,src.loss_pct);
      dest.gain=MathMax(dest.gain,src.gain);
      dest.gain_pct=MathMax(dest.gain_pct,src.gain_pct);
     }
  }

void AddDealToDays(SDay &days[],const datetime when,const bool trade,const bool cash,const bool credit,
                  const double volume,const double money)
  {
   int i=EnsureLedgerDay(days,when);
   days[i].activity=true;
   if(trade) days[i].data.lots+=volume;
   if(credit) return; // Credit belongs to ACCOUNT_CREDIT, not ACCOUNT_BALANCE.
   days[i].data.delta+=money;
   if(cash)
     {
      if(money>=0) days[i].data.deposits+=money;
      else days[i].data.withdrawals-=money;
     }
   else days[i].data.profit+=money;
  }

void AddOrderToDays(SDay &days[],const datetime when,const double volume)
  {
   int i=EnsureLedgerDay(days,when);
   days[i].activity=true;
   days[i].data.orders++;
   AddMinMax(days[i].data,volume,volume);
  }

void AddLedgerDeal(const datetime when,const bool trade,const bool cash,const bool credit,
                   const double volume,const double money)
  { AddDealToDays(g_days,when,trade,cash,credit,volume,money); }
void AddLedgerOrder(const datetime when,const double volume)
  { AddOrderToDays(g_days,when,volume); }

int FindFloatDay(const datetime value)
  {
   datetime day=DayStart(value);
   int lo=0,hi=ArraySize(g_float_days);
   while(lo<hi)
     {
      int mid=(lo+hi)/2;
      if(g_float_days[mid].day<day) lo=mid+1;
      else hi=mid;
     }
   return lo;
  }

void CopyFloatToLedger(const int pos)
  {
   int d=EnsureDay(g_float_days[pos].day);
   g_days[d].data.sampled=true;
   g_days[d].data.loss=g_float_days[pos].loss;
   g_days[d].data.loss_pct=g_float_days[pos].loss_pct;
   g_days[d].data.gain=g_float_days[pos].gain;
   g_days[d].data.gain_pct=g_float_days[pos].gain_pct;
  }

bool RecordFloating(const datetime when,const double floating,const double balance)
  {
   int pos=FindFloatDay(when),n=ArraySize(g_float_days);
   bool fresh=(pos>=n || g_float_days[pos].day!=DayStart(when));
   if(fresh)
     {
      ArrayResize(g_float_days,n+1,128);
      for(int i=n;i>pos;i--) g_float_days[i]=g_float_days[i-1];
      ZeroMemory(g_float_days[pos]);
      g_float_days[pos].day=DayStart(when);
      g_float_days[pos].first=when;
     }
   double pct=(balance>0 ? floating/balance*100.0 : 0);
   bool changed=fresh || floating<g_float_days[pos].loss || floating>g_float_days[pos].gain ||
                pct<g_float_days[pos].loss_pct || pct>g_float_days[pos].gain_pct;
   g_float_days[pos].last=when;
   g_float_days[pos].loss=MathMin(g_float_days[pos].loss,floating);
   g_float_days[pos].loss_pct=MathMin(g_float_days[pos].loss_pct,pct);
   g_float_days[pos].gain=MathMax(g_float_days[pos].gain,floating);
   g_float_days[pos].gain_pct=MathMax(g_float_days[pos].gain_pct,pct);
   if(changed) CopyFloatToLedger(pos);
   return changed;
  }

// Opening balance + deposits is a cash-flow-adjusted denominator. Percentages
// are recalculated for each bucket and the whole range, never summed.
bool StatsReturn(const SStats &s,double &value)
  {
   double base=s.opening+s.deposits;
   value=(base>0 ? s.profit/base*100.0 : 0);
   return base>0;
  }

void BuildBuckets(const int tab,const datetime requested_from,const datetime requested_to,
                  const datetime now,const bool show_empty)
  {
   ArrayResize(g_rows,0);
   EmptyStats(g_total);
   datetime today=DayStart(now);
   int n=ArraySize(g_days);
   g_effective_from=(requested_from>0 ? DayStart(requested_from) : (n>0 ? g_days[0].day : today));
   g_effective_to=(requested_to>0 ? (datetime)MathMin(DayStart(requested_to),today) : today);
   int d=FindDay(g_effective_from);
   double running=(d<n ? g_days[d].data.opening : g_history_balance);
   g_total.opening=running;
   g_total.balance=running;
   if(g_effective_from>g_effective_to) return;
   datetime stop=g_effective_to+ASP_DAY_SECONDS;
   for(datetime key=BucketStart(g_effective_from,tab);key<stop;key=NextBucket(key,tab))
     {
      datetime end=NextBucket(key,tab);
      SBucket row;
      row.start=key;
      row.end=end;
      EmptyStats(row.data);
      row.data.opening=running;
      bool activity=false;
      while(d<n && g_days[d].day<end && g_days[d].day<stop)
        {
         AddStats(row.data,g_days[d].data);
         activity=activity || g_days[d].activity || g_days[d].data.sampled;
         running+=g_days[d].data.delta;
         d++;
        }
      row.data.balance=running;
      AddStats(g_total,row.data);
      if(activity || show_empty)
        {
         int count=ArraySize(g_rows);
         ArrayResize(g_rows,count+1,256);
         g_rows[count]=row;
        }
     }
   g_total.balance=running;
  }
