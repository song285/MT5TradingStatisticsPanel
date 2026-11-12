#property strict
#property version "2.30"
#property description "账户历史分组统计：逐日、逐周、逐月、逐年表格"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots 0
#include "Include/AccountStatsData.mqh"
#include "Include/AccountStatsUI.mqh"
#include <Canvas/Canvas.mqh>

input group "统计范围（服务器日期，含首尾日）"
input datetime RangeFrom=0;       // 起始日期，0=账户可用历史最早日期
input datetime RangeTo=0;         // 截止日期，0=持续到今天
input bool ShowEmptyPeriods=false;// 显示没有成交、账务或浮盈亏记录的周期
input group "面板与刷新"
input int PanelWidth=1060;        // 首选宽度（96 DPI基准，超出图表时自适应）
input int PanelHeight=640;        // 首选高度（96 DPI基准，超出图表时自适应）
input int RowsPerPage=11;         // 每页显示周期数（1-12）
input int RefreshSeconds=15;      // 历史检查间隔（秒）
input int SampleSeconds=1;        // 浮动盈亏采样间隔（秒）
input int HistorySliceMs=8;       // 每批历史处理预算（毫秒）
input int ReconcileMinutes=60;    // 全历史后台核对间隔（分钟）

#define ASP_COLUMNS 13
#define ASP_TABS 5
string g_tabs[ASP_TABS]={"每日","每周","每月","每年","账户"};
string g_col_names[ASP_COLUMNS]={"日期","手数","最小 / 最大手数","订单次数","盈亏金额","百分比","入金","出金","期末余额","最大浮亏","浮亏比例","最大浮盈","浮盈比例"};
int g_col_widths[ASP_COLUMNS]={184,78,126,76,110,88,100,100,112,108,94,108,94};
string g_prefix="",g_currency="",g_store_file="",g_store_lock="";
string g_from_text="",g_to_text="",g_message="";
int g_tab=0,g_x=16,g_y=28,g_width=1060,g_height=640;
int g_page[4]={0,0,0,0},g_first_col[4]={1,1,1,1};
int g_rows_per_page=10,g_drag_dx=0,g_drag_dy=0;
bool g_minimized=false,g_dragging=false,g_left_down=false;
bool g_scroll_captured=false,g_scroll_previous=true,g_mouse_previous=false;
bool g_view_dirty=true,g_plot_dirty=true,g_store_dirty=false,g_force_history=true;
bool g_history_ok=false;
bool g_events_ready=false;
ulong g_last_refresh_ms=0,g_last_sample_ms=0,g_last_save_ms=0,g_last_full_ms=0,g_last_drag_ms=0;
datetime g_from=0,g_to=0,g_last_day=0,g_history_time=0;
SBucket g_cached_rows[];
int g_cached_offset[4]={0,0,0,0};
int g_cached_count[4]={0,0,0,0};
SStats g_cached_total[4];
double g_cached_low[4],g_cached_high[4];
bool g_cache_valid[4]={false,false,false,false};
bool g_float_dirty=false;
bool g_history_busy=false,g_history_full=false,g_ui_dirty=true;
int g_job_deals=0,g_job_orders=0,g_job_deal=0,g_job_order=0;
datetime g_job_from=0,g_job_to=0;
double g_job_balance=0;
int g_currency_digits=2,g_chart_width=0,g_chart_height=0;
int g_screen_dpi=96,g_account_page=0,g_account_rows=16;
double g_scale=1.0,g_dpi_scale=1.0;
int g_table_top=246,g_curve_top=131,g_curve_height=84,g_curve_width=0,g_curve_old_height=0;
int g_range_info_y=222,g_nav_rows=1,g_date_width=184;
bool g_tiny=false;
CCanvas g_curve;
bool g_curve_ready=false;
color C_BG=C'24,28,34',C_HEAD=C'34,40,48',C_ROW=C'29,34,41',C_BORDER=C'55,64,74';
color C_TEXT=C'224,230,236',C_MUTED=C'149,162,176',C_ACCENT=C'64,190,180';
color C_POS=C'91,204,151',C_NEG=C'240,110,113';

void UpdateCachedFloatViews(const datetime when);
int ViewRowCount();

datetime ServerNow()
  {
   datetime now=TimeTradeServer();
   if(now<=0) now=TimeCurrent();
   return now;
  }

uint HashText(const string s)
  {
   uint h=2166136261;
   for(int i=0;i<StringLen(s);i++) h=(h^(uint)StringGetCharacter(s,i))*16777619;
   return h;
  }

string Name(const string suffix) { return g_prefix+suffix; }
string DateText(const datetime value) { return TimeToString(value,TIME_DATE); }
string Money(const double value)
  {
   return DoubleToString(MathAbs(value)<0.0000001 ? 0 : value,g_currency_digits);
  }
string Lots(const double value)
  {
   // Preserve fractional lots such as 0.001, while keeping ordinary lots compact.
   string text=DoubleToString(value,4);
   while(StringLen(text)>0 && StringSubstr(text,StringLen(text)-1)=="0" &&
         StringLen(text)-StringFind(text,".")>3)
      text=StringSubstr(text,0,StringLen(text)-1);
   return text;
  }
string Pct(const double value) { return DoubleToString(MathAbs(value)<0.000001 ? 0 : value,2)+"%"; }

bool ParseDate(const string text,datetime &value)
  {
   if(text=="" || text=="0" || text=="全部") { value=0; return true; }
   string normalized=text;
   StringReplace(normalized,"-",".");
   if(StringLen(normalized)!=10) return false;
   value=StringToTime(normalized);
   MqlDateTime t;
   if(value<=0 || !TimeToStruct(value,t) || t.year<1970 || t.year>2100) return false;
   value=DayStart(value);
   return DateText(value)==normalized;
  }

bool IsTrade(const ENUM_DEAL_TYPE type) { return type==DEAL_TYPE_BUY || type==DEAL_TYPE_SELL; }
double DealMoney(const ulong ticket)
  {
   return HistoryDealGetDouble(ticket,DEAL_PROFIT)+HistoryDealGetDouble(ticket,DEAL_SWAP)+
          HistoryDealGetDouble(ticket,DEAL_COMMISSION)+HistoryDealGetDouble(ticket,DEAL_FEE);
  }

// Start a snapshot only. Enumeration is sliced across timer events; last good
// ledger and cached pages remain readable while the snapshot is processed.
bool RefreshHistory(const datetime now,const bool force)
  {
   if(g_history_busy) return false;
   if(now<=0) return false;
   bool full=force || !g_history_ok || now<g_history_time;
   datetime from=(full ? 0 : (datetime)MathMax(0,DayStart(g_history_time)-ASP_DAY_SECONDS));
   if(!HistorySelect(from,now))
     { g_message="历史暂不可用，保留上次结果"; g_ui_dirty=true; return false; }
   g_job_from=from; g_job_to=now;
   g_job_balance=AccountInfoDouble(ACCOUNT_BALANCE);
   g_job_deals=HistoryDealsTotal(); g_job_orders=HistoryOrdersTotal();
   g_job_deal=0; g_job_order=0;
   ArrayResize(g_work_days,0);
   g_history_full=full; g_history_busy=true;
   g_message="正在分批核对历史，仍可切页和翻页";
   g_ui_dirty=true;
   return true;
  }

bool HistorySlice()
  {
   if(!g_history_busy) return false;
   ulong started=GetTickCount64();
   int processed=0;
   // Hard row cap as well as elapsed budget: bounded even on a slow broker API.
   while(g_job_deal<g_job_deals || g_job_order<g_job_orders)
     {
      if(processed>=2000 || (processed>0 && GetTickCount64()-started>=(ulong)HistorySliceMs)) return false;
      processed++;
      if(g_job_deal<g_job_deals)
        {
         ulong ticket=HistoryDealGetTicket(g_job_deal);
         if(ticket==0) { g_history_busy=false; g_force_history=true; g_message="历史读取中断，保留上次结果"; return false; }
         ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket,DEAL_TYPE);
         AddDealToDays(g_work_days,(datetime)HistoryDealGetInteger(ticket,DEAL_TIME),IsTrade(type),
                       type==DEAL_TYPE_BALANCE,type==DEAL_TYPE_CREDIT,HistoryDealGetDouble(ticket,DEAL_VOLUME),DealMoney(ticket));
         g_job_deal++;
        }
      else
        {
         ulong ticket=HistoryOrderGetTicket(g_job_order);
         if(ticket==0) { g_history_busy=false; g_force_history=true; g_message="订单读取中断，保留上次结果"; return false; }
         if(HistoryOrderGetInteger(ticket,ORDER_STATE)==ORDER_STATE_FILLED)
           {
            ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)HistoryOrderGetInteger(ticket,ORDER_TYPE);
            double volume=HistoryOrderGetDouble(ticket,ORDER_VOLUME_INITIAL);
            datetime when=(datetime)HistoryOrderGetInteger(ticket,ORDER_TIME_DONE);
            if(type<=ORDER_TYPE_CLOSE_BY && volume>0 && when>0) AddOrderToDays(g_work_days,when,volume);
           }
         g_job_order++;
        }
     }
   // Replace the selected days, instead of adding them, so overlapping windows,
   // late records, deleted records and same-second fills cannot double count.
   int prefix=(g_history_full ? 0 : FindDay(g_job_from));
   int count=ArraySize(g_work_days);
   ArrayResize(g_days,prefix+count,512);
   for(int i=0;i<count;i++) g_days[prefix+i]=g_work_days[i];
   ArrayResize(g_work_days,0);
   for(int i=0;i<ArraySize(g_float_days);i++) CopyFloatToLedger(i);
   g_history_balance=g_job_balance;
   g_history_time=g_job_to;
   RebuildDayBalances();
   g_history_ok=true; g_history_busy=false;
   for(int i=0;i<4;i++) g_cache_valid[i]=false;
   g_view_dirty=true; g_plot_dirty=true; g_ui_dirty=true;
   g_message="";
   return true;
  }

void MergeFloatRecord(const SFloatDay &r)
  {
   int pos=FindFloatDay(r.day),n=ArraySize(g_float_days);
   if(pos==n || g_float_days[pos].day!=r.day)
     {
      ArrayResize(g_float_days,n+1,128);
      for(int i=n;i>pos;i--) g_float_days[i]=g_float_days[i-1];
      g_float_days[pos]=r;
     }
   else
     {
      g_float_days[pos].first=(datetime)MathMin(g_float_days[pos].first,r.first);
      g_float_days[pos].last=(datetime)MathMax(g_float_days[pos].last,r.last);
      g_float_days[pos].loss=MathMin(g_float_days[pos].loss,r.loss);
      g_float_days[pos].loss_pct=MathMin(g_float_days[pos].loss_pct,r.loss_pct);
      g_float_days[pos].gain=MathMax(g_float_days[pos].gain,r.gain);
      g_float_days[pos].gain_pct=MathMax(g_float_days[pos].gain_pct,r.gain_pct);
     }
   CopyFloatToLedger(pos);
  }

bool ReadFloatStore()
  {
   if(!FileIsExist(g_store_file)) return true;
   int h=FileOpen(g_store_file,FILE_READ|FILE_BIN|FILE_SHARE_READ);
   if(h==INVALID_HANDLE) return false;
   bool valid=(FileReadInteger(h)==0x41535032);
   int count=FileReadInteger(h);
   valid=valid && count>=0 && count<=100000 && FileSize(h)==8+(ulong)count*sizeof(SFloatDay);
   for(int i=0;valid && i<count;i++)
     {
      SFloatDay r;
      if(FileReadStruct(h,r)!=sizeof(SFloatDay) || r.day<=0 || r.day!=DayStart(r.day) || r.first<r.day ||
         r.last<r.first || r.loss>0 || r.gain<0) { valid=false; break; }
      MergeFloatRecord(r);
     }
   FileClose(h);
   if(!valid) g_message="浮盈亏记录文件异常，原文件保留";
   return valid;
  }

void SaveFloatStore()
  {
   if(!g_store_dirty) return;
   // Account-scoped lock prevents multiple chart instances overwriting peaks.
   if(!GlobalVariableCheck(g_store_lock)) GlobalVariableSet(g_store_lock,0);
   double previous=GlobalVariableGet(g_store_lock),token=(double)TimeLocal()+15;
   if(previous>(double)TimeLocal() || !GlobalVariableSetOnCondition(g_store_lock,token,previous)) return;
   if(ReadFloatStore())
     {
      FolderCreate("AccountStatsPanel");
      string temporary=g_store_file+".tmp";
      int h=FileOpen(temporary,FILE_WRITE|FILE_BIN);
      if(h!=INVALID_HANDLE)
        {
         bool ok=FileWriteInteger(h,0x41535032)>0 && FileWriteInteger(h,ArraySize(g_float_days))>0;
         for(int i=0;ok && i<ArraySize(g_float_days);i++)
            ok=(FileWriteStruct(h,g_float_days[i])==sizeof(SFloatDay));
         FileFlush(h);
         FileClose(h);
         if(ok && FileMove(temporary,0,g_store_file,FILE_REWRITE)) g_store_dirty=false;
         else g_message="浮盈亏记录保存失败，将重试";
        }
      else g_message="浮盈亏记录保存失败，将重试";
     }
   GlobalVariableSetOnCondition(g_store_lock,0,token);
  }

void SampleFloating(const datetime now)
  {
   if(now<=0 || !TerminalInfoInteger(TERMINAL_CONNECTED)) return;
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double floating=AccountInfoDouble(ACCOUNT_EQUITY)-balance-AccountInfoDouble(ACCOUNT_CREDIT);
   int day_count=ArraySize(g_days);
   if(RecordFloating(now,floating,balance))
     {
      g_store_dirty=true;
      g_float_dirty=true;
      if(ArraySize(g_days)!=day_count)
        {
         RebuildDayBalances();
         for(int i=0;i<4;i++) g_cache_valid[i]=false;
         g_view_dirty=true;
        }
      else
         UpdateCachedFloatViews(now);
      g_ui_dirty=true;
     }
  }

void EnsureObject(const string suffix,const ENUM_OBJECT type)
  {
   UiEnsure(Name(suffix),type);
  }
int UiPx(const int logical) { return (int)MathRound(logical*g_scale); }
int UiFont(const int size) { return (int)MathMax(1,MathRound(size*g_scale/g_dpi_scale)); }
string FitLabel(const string id,const string text,const int width,const int size)
  {
   if(width<=0 || text=="") return text;
   int i=UiFind(Name(id));
   if(i<0) return text;
   int pixel_width=UiPx(width),font=UiFont(size);
   if(g_ui_objects[i].fit_full==text && g_ui_objects[i].fit_width==pixel_width &&
      g_ui_objects[i].fit_font==font && g_ui_objects[i].fit_dpi==g_screen_dpi)
      return g_ui_objects[i].fit_text;
   uint w=0,h=0;
   string result=text;
   if(TextSetFont("Microsoft YaHei UI",-font*10,0) && TextGetSize(text,w,h) && (int)w>pixel_width)
     {
      int lo=0,hi=StringLen(text);
      while(lo<hi)
        {
         int mid=(lo+hi+1)/2;
         if(TextGetSize(StringSubstr(text,0,mid)+"...",w,h) && (int)w<=pixel_width) lo=mid;
         else hi=mid-1;
        }
      result=(lo>0 ? StringSubstr(text,0,lo)+"..." : "-");
     }
   g_ui_objects[i].fit_full=text; g_ui_objects[i].fit_text=result;
   g_ui_objects[i].fit_width=pixel_width; g_ui_objects[i].fit_font=font; g_ui_objects[i].fit_dpi=g_screen_dpi;
   return result;
  }
void Rect(const string id,const int x,const int y,const int w,const int h,const color fill,const color border)
  {
   EnsureObject(id,OBJ_RECTANGLE_LABEL);
   string n=Name(id);
   UiSetInt(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   UiSetInt(0,n,OBJPROP_XDISTANCE,UiPx(x));
   UiSetInt(0,n,OBJPROP_YDISTANCE,UiPx(y));
   UiSetInt(0,n,OBJPROP_XSIZE,UiPx(w));
   UiSetInt(0,n,OBJPROP_YSIZE,UiPx(h));
   UiSetInt(0,n,OBJPROP_BGCOLOR,fill);
   UiSetInt(0,n,OBJPROP_COLOR,border);
   UiSetInt(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   UiSetInt(0,n,OBJPROP_BACK,false);
   UiSetInt(0,n,OBJPROP_SELECTABLE,false);
   UiSetInt(0,n,OBJPROP_HIDDEN,true);
   UiSetInt(0,n,OBJPROP_ZORDER,0);
  }
void Label(const string id,const string text,const int x,const int y,const color ink,const int size=9,const bool right=false,const int max_width=0)
  {
   EnsureObject(id,OBJ_LABEL);
   string n=Name(id);
   UiSetInt(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   UiSetInt(0,n,OBJPROP_ANCHOR,right ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
   UiSetInt(0,n,OBJPROP_XDISTANCE,UiPx(x));
   UiSetInt(0,n,OBJPROP_YDISTANCE,UiPx(y));
   UiSetInt(0,n,OBJPROP_COLOR,ink);
   UiSetInt(0,n,OBJPROP_FONTSIZE,UiFont(size));
   UiSetString(0,n,OBJPROP_FONT,"Microsoft YaHei UI");
   UiSetString(0,n,OBJPROP_TEXT,FitLabel(id,text,max_width,size));
   UiSetString(0,n,OBJPROP_TOOLTIP,text);
   UiSetInt(0,n,OBJPROP_SELECTABLE,false);
   UiSetInt(0,n,OBJPROP_HIDDEN,true);
   UiSetInt(0,n,OBJPROP_BACK,false);
   UiSetInt(0,n,OBJPROP_ZORDER,2);
  }
void Button(const string id,const string text,const int x,const int y,const int w,const string tip="")
  {
   EnsureObject(id,OBJ_BUTTON);
   string n=Name(id);
   UiSetInt(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   UiSetInt(0,n,OBJPROP_XDISTANCE,UiPx(x));
   UiSetInt(0,n,OBJPROP_YDISTANCE,UiPx(y));
   UiSetInt(0,n,OBJPROP_XSIZE,UiPx(w));
   UiSetInt(0,n,OBJPROP_YSIZE,UiPx(25));
   bool selected=(g_tab<5 && id=="body.tab."+IntegerToString(g_tab));
   bool enabled=true;
   if(g_tab<4)
     {
      int pages=(int)MathMax(1,(ViewRowCount()+g_rows_per_page-1)/g_rows_per_page);
      if(id=="body.first" || id=="body.prev") enabled=g_page[g_tab]>0;
      if(id=="body.next" || id=="body.last") enabled=g_page[g_tab]<pages-1;
     }
   else if(g_tab==4)
     {
      int pages=(16+g_account_rows-1)/g_account_rows;
      if(id=="body.account.prev") enabled=g_account_page>0;
      if(id=="body.account.next") enabled=g_account_page<pages-1;
     }
   UiSetInt(0,n,OBJPROP_COLOR,selected ? C_BG : enabled ? C_TEXT : C_MUTED);
   UiSetInt(0,n,OBJPROP_BGCOLOR,selected ? C_ACCENT : enabled ? C_HEAD : C_BG);
   UiSetInt(0,n,OBJPROP_BORDER_COLOR,C_BORDER);
   UiSetInt(0,n,OBJPROP_FONTSIZE,UiFont(9));
   UiSetString(0,n,OBJPROP_FONT,"Microsoft YaHei UI");
   UiSetString(0,n,OBJPROP_TEXT,text);
   UiSetString(0,n,OBJPROP_TOOLTIP,tip=="" ? text : tip);
   UiSetInt(0,n,OBJPROP_SELECTABLE,false);
   UiSetInt(0,n,OBJPROP_HIDDEN,true);
   UiSetInt(0,n,OBJPROP_ZORDER,10);
   UiSetInt(0,n,OBJPROP_STATE,false);
  }
void ButtonEnabled(const string id,const bool enabled)
  {
   string n=Name(id);
   if(!UiExists(n)) return;
   UiSetInt(0,n,OBJPROP_BGCOLOR,enabled ? C_HEAD : C_BG);
   UiSetInt(0,n,OBJPROP_COLOR,enabled ? C_TEXT : C_MUTED);
   UiSetInt(0,n,OBJPROP_STATE,false);
  }
void Edit(const string id,const string text,const int x,const int y,const int w)
  {
   bool fresh=!UiExists(Name(id));
   EnsureObject(id,OBJ_EDIT);
   string n=Name(id);
   UiSetInt(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   UiSetInt(0,n,OBJPROP_XDISTANCE,UiPx(x));
   UiSetInt(0,n,OBJPROP_YDISTANCE,UiPx(y));
   UiSetInt(0,n,OBJPROP_XSIZE,UiPx(w));
   UiSetInt(0,n,OBJPROP_YSIZE,UiPx(25));
   UiSetInt(0,n,OBJPROP_COLOR,C_TEXT);
   UiSetInt(0,n,OBJPROP_BGCOLOR,C_BG);
   UiSetInt(0,n,OBJPROP_BORDER_COLOR,C_BORDER);
   UiSetInt(0,n,OBJPROP_FONTSIZE,UiFont(9));
   UiSetString(0,n,OBJPROP_FONT,"Microsoft YaHei UI");
   UiSetInt(0,n,OBJPROP_ALIGN,ALIGN_CENTER);
   UiSetInt(0,n,OBJPROP_READONLY,false);
   UiSetInt(0,n,OBJPROP_SELECTABLE,false);
   UiSetInt(0,n,OBJPROP_HIDDEN,true);
   UiSetInt(0,n,OBJPROP_ZORDER,11);
   if(fresh) UiSetString(0,n,OBJPROP_TEXT,text);
  }

void CaptureScroll(const bool capture)
  {
   if(capture && !g_scroll_captured)
     {
      g_scroll_previous=ChartGetInteger(0,CHART_MOUSE_SCROLL)!=0;
      ChartSetInteger(0,CHART_MOUSE_SCROLL,false);
      g_scroll_captured=true;
     }
   else if(!capture && g_scroll_captured)
     {
      ChartSetInteger(0,CHART_MOUSE_SCROLL,g_scroll_previous);
      g_scroll_captured=false;
     }
  }
void ReadEdits()
  {
   if(UiExists(Name("body.from"))) g_from_text=ObjectGetString(0,Name("body.from"),OBJPROP_TEXT);
   if(UiExists(Name("body.to"))) g_to_text=ObjectGetString(0,Name("body.to"),OBJPROP_TEXT);
  }
void ClearBody()
  {
   ReadEdits();
   // Sweep at the end of the next frame. Retain table cells and the bitmap
   // for reuse across tab/column changes instead of deleting/recreating them.
   g_plot_dirty=true;
  }
void ClearTabVisuals() { ReadEdits(); g_plot_dirty=true; }

int CacheFindBucket(const int tab,const datetime start)
  {
   int lo=0,hi=g_cached_count[tab];
   while(lo<hi)
     {
      int mid=(lo+hi)/2;
      if(g_cached_rows[g_cached_offset[tab]+mid].start<start) lo=mid+1;
      else hi=mid;
     }
   return (lo<g_cached_count[tab] && g_cached_rows[g_cached_offset[tab]+lo].start==start) ? lo : -1;
  }

void UpdateCachedFloatViews(const datetime when)
  {
   if(DayStart(when)<g_effective_from || DayStart(when)>g_effective_to) return;
   int day=FindDay(DayStart(when));
   if(day<0 || day>=ArraySize(g_days)) return;
   for(int tab=0;tab<4;tab++)
     {
      if(!g_cache_valid[tab]) continue;
      int row=CacheFindBucket(tab,BucketStart(when,tab));
      if(row<0) continue;
      SStats dst=g_cached_rows[g_cached_offset[tab]+row].data;
      SStats src=g_days[day].data;
      dst.sampled=true;
      dst.loss=MathMin(dst.loss,src.loss);
      dst.loss_pct=MathMin(dst.loss_pct,src.loss_pct);
      dst.gain=MathMax(dst.gain,src.gain);
      dst.gain_pct=MathMax(dst.gain_pct,src.gain_pct);
      g_cached_rows[g_cached_offset[tab]+row].data=dst;
      g_cached_total[tab].sampled=true;
      g_cached_total[tab].loss=MathMin(g_cached_total[tab].loss,src.loss);
      g_cached_total[tab].loss_pct=MathMin(g_cached_total[tab].loss_pct,src.loss_pct);
      g_cached_total[tab].gain=MathMax(g_cached_total[tab].gain,src.gain);
      g_cached_total[tab].gain_pct=MathMax(g_cached_total[tab].gain_pct,src.gain_pct);
     }
  }

int ViewRowCount()
  {
   if(g_tab<4 && g_cache_valid[g_tab]) return g_cached_count[g_tab];
   return ArraySize(g_rows);
  }

SStats ViewTotal()
  {
   if(g_tab<4 && g_cache_valid[g_tab]) return g_cached_total[g_tab];
   return g_total;
  }
void ConfigureLayout()
  {
   double previous_scale=g_scale;
   int previous_width=g_width,previous_height=g_height,previous_rows=g_rows_per_page;
   g_dpi_scale=MathMax(0.75,(double)g_screen_dpi/96.0);
   int cw=(g_chart_width>0 ? g_chart_width : PanelWidth),ch=(g_chart_height>0 ? g_chart_height : PanelHeight);
   int margin=(cw<400 || ch<300 ? 2 : 8);
   int available_w=(int)MathMax(1,cw-2*margin),available_h=(int)MathMax(1,ch-2*margin);
   g_tiny=(available_w<270 || available_h<200);
   // Prefer readable DPI-sized controls; only reduce their scale when even a
   // compact 360x330 layout cannot fit. Never stretch to the whole chart.
   g_scale=MathMax(0.05,MathMin(g_dpi_scale,MathMin((double)available_w/360.0,(double)available_h/330.0)));
   g_width=(int)MathMin(g_minimized ? 300 : PanelWidth,MathFloor(available_w/g_scale));
   g_height=(g_minimized || g_tiny ? 38 : (int)MathMin(PanelHeight,MathFloor(available_h/g_scale)));
   g_nav_rows=(g_width<900 ? 2 : 1);
   g_curve_height=(g_height>=520 ? 84 : g_height>=440 ? 50 : 0);
   g_curve_top=131;
   g_range_info_y=(g_curve_height>0 ? g_curve_top+g_curve_height+7 : 116);
   g_table_top=g_range_info_y+24;
   int footer=28+(g_nav_rows*31)+24+8;
   g_rows_per_page=(int)MathMax(1,MathMin(RowsPerPage,(g_height-g_table_top-28-footer)/24));
   g_account_rows=(int)MathMax(1,MathMin(16,(g_height-106-62)/25));
   g_account_page=(int)MathMin(g_account_page,(16-1)/g_account_rows);
   g_date_width=(g_width<600 ? 146 : 184);
   if(previous_rows>0 && previous_rows!=g_rows_per_page)
      for(int t=0;t<4;t++) g_page[t]=g_page[t]*previous_rows/g_rows_per_page;
   // Position, font sizes and hit testing use the same logical-to-pixel scale.
   int logical_cw=(int)MathFloor(cw/g_scale),logical_ch=(int)MathFloor(ch/g_scale);
   g_x=(int)MathMax(0,MathMin(g_x,MathMax(0,logical_cw-g_width)));
   g_y=(int)MathMax(0,MathMin(g_y,MathMax(0,logical_ch-g_height)));
   if(previous_scale!=g_scale || previous_width!=g_width || previous_height!=g_height) g_plot_dirty=true;
  }

string PeriodLabel(const SBucket &row)
  {
   if(g_tab==0) return DateText(row.start);
   if(g_tab==1) return DateText(row.start)+(g_width<600 ? "~"+StringSubstr(DateText(row.end-1),5,5) : " - "+DateText(row.end-1));
   if(g_tab==2) return StringSubstr(DateText(row.start),0,7);
   return StringSubstr(DateText(row.start),0,4);
  }
string CellText(const SStats &s,const int col)
  {
   double pct=0;
   if(col==1) return Lots(s.lots);
   if(col==2) return s.orders>0 ? Lots(s.min_lot)+" / "+Lots(s.max_lot) : "--";
   if(col==3) return IntegerToString(s.orders);
   if(col==4) return Money(s.profit);
   if(col==5) return StatsReturn(s,pct) ? Pct(pct) : "--";
   if(col==6) return Money(s.deposits);
   if(col==7) return Money(s.withdrawals);
   if(col==8) return Money(s.balance);
   if(!s.sampled) return "--";
   if(col==9) return Money(s.loss);
   if(col==10) return Pct(s.loss_pct);
   if(col==11) return Money(s.gain);
   return Pct(s.gain_pct);
  }
color CellColor(const SStats &s,const int col)
  {
   if(col==4 || col==5) return s.profit>=0 ? C_POS : C_NEG;
   if(col>=9) return !s.sampled ? C_MUTED : (col<=10 ? C_NEG : C_POS);
   return C_TEXT;
  }
int LastVisibleColumn()
  {
   int used=g_date_width,last=g_first_col[g_tab]-1;
   for(int c=g_first_col[g_tab];c<ASP_COLUMNS;c++)
     {
      if(used+g_col_widths[c]>g_width-28) break;
      used+=g_col_widths[c]; last=c;
     }
   return last;
  }
void TableLine(const int slot,const int y,const string date,const SStats &s,const bool blank,const bool total=false)
  {
   string id="body.line."+IntegerToString(slot)+".";
   Rect(id+"bg",g_x+12,y,g_width-24,24,total ? C_HEAD : (slot%2==0 ? C_ROW : C_BG),total ? C_BORDER : (slot%2==0 ? C_ROW : C_BG));
   int left=g_x+16;
   Label(id+"0",blank ? "-" : date,left+3,y+4,total ? C_ACCENT : (blank ? C_MUTED : C_TEXT),9,false,g_date_width-8);
   left+=g_date_width;
   for(int c=g_first_col[g_tab];c<=LastVisibleColumn();c++)
     {
      Label(id+IntegerToString(c),blank ? "-" : CellText(s,c),left+g_col_widths[c]-8,y+4,blank ? C_MUTED : CellColor(s,c),9,true,g_col_widths[c]-16);
      left+=g_col_widths[c];
     }
  }

void DrawCurve()
  {
   if(g_curve_height<=0) return;
   int x=UiPx(g_x+16),y=UiPx(g_y+g_curve_top),w=UiPx(g_width-32),h=UiPx(g_curve_height);
   if(g_curve_ready && (w!=g_curve_width || h!=g_curve_old_height))
     {
      g_curve.Destroy(); g_curve_ready=false; UiDelete(Name("body.curve"));
     }
   if(!g_curve_ready)
     {
      g_curve_ready=g_curve.CreateBitmapLabel(0,0,Name("body.curve"),x,y,w,h,COLOR_FORMAT_ARGB_NORMALIZE);
      g_curve_width=w; g_curve_old_height=h;
      g_plot_dirty=true;
      if(g_curve_ready) UiAdopt(Name("body.curve"));
      UiSetInt(0,Name("body.curve"),OBJPROP_SELECTABLE,false);
      UiSetInt(0,Name("body.curve"),OBJPROP_HIDDEN,true);
     }
   if(g_curve_ready) UiAdopt(Name("body.curve"));
   UiSetInt(0,Name("body.curve"),OBJPROP_XDISTANCE,x);
   UiSetInt(0,Name("body.curve"),OBJPROP_YDISTANCE,y);
   if(!g_curve_ready || !g_plot_dirty) return;
   g_curve.Erase(ColorToARGB(C_BG));
   g_curve.Line(0,h-1,w-1,h-1,ColorToARGB(C_BORDER));
   g_curve.Line(0,0,0,h-1,ColorToARGB(C_BORDER));
   int n=ViewRowCount();
   if(n>0)
     {
      double low=g_cached_low[g_tab],high=g_cached_high[g_tab];
      double span=high-low;
      if(span<=0) span=1;
      int last_x=0,last_y=h/2;
      int step=(int)MathMax(1,n/(w-12));
      for(int i=0;i<n;i+=step)
        {
         int px=(n==1 ? 5 : 5+(int)((double)(w-12)*i/(n-1)));
         double balance=(g_cache_valid[g_tab] ? g_cached_rows[g_cached_offset[g_tab]+i].data.balance : g_rows[i].data.balance);
         int py=(high==low ? h/2 : 6+(int)((high-balance)/span*(h-14)));
         if(i>0) g_curve.Line(last_x,last_y,px,py,ColorToARGB(C_ACCENT));
         last_x=px; last_y=py;
        }
      double final_balance=(g_cache_valid[g_tab] ? g_cached_rows[g_cached_offset[g_tab]+n-1].data.balance : g_rows[n-1].data.balance);
      int final_y=(high==low ? h/2 : 6+(int)((high-final_balance)/span*(h-14)));
      g_curve.Line(last_x,last_y,w-6,final_y,ColorToARGB(C_ACCENT));
     }
   g_curve.Update();
   g_ui_wrote=true;
   g_plot_dirty=false;
  }

void DrawStats()
  {
   int y=g_y+80;
   if(g_width>=600)
     {
      Label("body.range.label","范围",g_x+16,y+5,C_MUTED);
      Edit("body.from",g_from_text,g_x+57,y,116);
      Label("body.range.sep","至",g_x+182,y+5,C_MUTED);
      Edit("body.to",g_to_text,g_x+206,y,116);
      Button("body.apply","应用",g_x+334,y,54,"格式 YYYY.MM.DD；留空=全部历史 / 到今天");
      Button("body.all","全部",g_x+395,y,54,"全部历史");
     }
   else
     {
      Edit("body.from",g_from_text,g_x+16,y,96);
      Label("body.range.sep","至",g_x+119,y+5,C_MUTED);
      Edit("body.to",g_to_text,g_x+140,y,96);
      Button("body.apply","应用",g_x+244,y,46);
      Button("body.all","全部",g_x+298,y,46);
     }
   if(g_width>=720) Label("body.units",g_currency+"  |  余额走势",g_x+g_width-18,y+5,C_MUTED,9,true);
   DrawCurve();
   string range=DateText(g_effective_from)+" - "+DateText(g_effective_to)+"  |  "+IntegerToString(ViewRowCount())+" 个周期";
   Label("body.range.actual",range,g_x+16,g_y+g_range_info_y,C_MUTED,8,false,g_width-32);
   int top=g_y+g_table_top;
   Rect("body.columns.bg",g_x+12,top,g_width-24,28,C_HEAD,C_BORDER);
   string date_heading=(g_tab==0 ? "日期" : g_tab==1 ? "周（周一至周日）" : g_tab==2 ? "月份" : "年份");
   Label("body.columns.0",date_heading,g_x+19,top+6,C_MUTED,9,false,g_date_width-8);
   int left=g_x+16+g_date_width;
   for(int c=g_first_col[g_tab];c<=LastVisibleColumn();c++)
     {
      Label("body.columns."+IntegerToString(c),g_col_names[c],left+g_col_widths[c]-8,top+6,C_MUTED,9,true,g_col_widths[c]-16);
      left+=g_col_widths[c];
     }
   int n=ViewRowCount(),pages=(int)MathMax(1,(n+g_rows_per_page-1)/g_rows_per_page);
   g_page[g_tab]=(int)MathMin(g_page[g_tab],pages-1);
   SStats empty;
   EmptyStats(empty);
   for(int slot=0;slot<g_rows_per_page;slot++)
     {
      int index=n-1-g_page[g_tab]*g_rows_per_page-slot;
      if(index>=0)
        {
         SBucket row=(g_cache_valid[g_tab] ? g_cached_rows[g_cached_offset[g_tab]+index] : g_rows[index]);
         TableLine(slot,top+28+slot*24,PeriodLabel(row),row.data,false);
        }
      else TableLine(slot,top+28+slot*24,"-",empty,true);
     }
   int total_y=top+28+g_rows_per_page*24+4;
   SStats total=ViewTotal();
   TableLine(1000,total_y,"合计（全部筛选范围）",total,false,true);
   int nav_y=total_y+34;
   bool narrow=g_width<600;
   Button("body.first",narrow ? "|<" : "首页",g_x+16,nav_y,narrow ? 32 : 48,"首页");
   Button("body.prev",narrow ? "<" : "上一页",g_x+(narrow ? 54 : 70),nav_y,narrow ? 32 : 62,"上一页");
   int page_x=(narrow ? 94 : 142),next_x=(narrow ? g_width-86 : 230),last_x=(narrow ? g_width-48 : 298);
   int page_width=next_x-page_x-8;
   Label("body.page",IntegerToString(g_page[g_tab]+1)+" / "+IntegerToString(pages)+" 页",g_x+page_x,nav_y+5,C_TEXT,8,false,page_width);
   Button("body.next",narrow ? ">" : "下一页",g_x+next_x,nav_y,narrow ? 32 : 62,"下一页");
   Button("body.last",narrow ? ">|" : "末页",g_x+last_x,nav_y,narrow ? 32 : 48,"末页");
   ButtonEnabled("body.first",g_page[g_tab]>0);
   ButtonEnabled("body.prev",g_page[g_tab]>0);
   ButtonEnabled("body.next",g_page[g_tab]<pages-1);
   ButtonEnabled("body.last",g_page[g_tab]<pages-1);
   int col_y=(g_nav_rows==1 ? nav_y : nav_y+31);
   int info_x=(g_nav_rows==1 ? 370 : 16);
   int col_x=g_width-202;
   string page_info=(narrow ? "共 "+IntegerToString(n)+"条 / 每页"+IntegerToString(g_rows_per_page) :
                            "共 "+IntegerToString(n)+" 个周期 · 每页 "+IntegerToString(g_rows_per_page)+" 条");
   Label("body.page.info",page_info,g_x+info_x,col_y+5,C_MUTED,8,false,col_x-info_x-8);
   Button("body.col.prev","< 列",g_x+col_x,col_y,48);
   Button("body.col.next","列 >",g_x+col_x+54,col_y,48);
   Label("body.col.info",IntegerToString(g_first_col[g_tab])+"-"+IntegerToString(LastVisibleColumn())+"/12",g_x+g_width-16,col_y+5,C_MUTED,8,true,82);
   string note=(g_message!="" ? g_message : !g_history_ok ? "正在读取账户历史…" : n==0 ? "此范围内没有记录" : "浮盈亏峰值：仅已采样时段，-- 为未记录；合计余额为期末余额");
   Label("body.note",note,g_x+16,g_y+g_height-22,C_MUTED,8,false,g_width-32);
  }

void AccountRow(const int row,const string label,const string value)
  {
   if(row<g_account_page*g_account_rows || row>=(g_account_page+1)*g_account_rows) return;
   int slot=row-g_account_page*g_account_rows;
   int y=g_y+106+slot*25;
   int value_x=(g_width<600 ? 160 : 234);
   Rect("body.account.bg."+IntegerToString(row),g_x+12,y,g_width-24,25,slot%2!=0 ? C_BG : C_ROW,slot%2!=0 ? C_BG : C_ROW);
   Label("body.account.k."+IntegerToString(row),label,g_x+22,y+5,C_MUTED,9,false,value_x-30);
   Label("body.account.v."+IntegerToString(row),value,g_x+value_x,y+5,C_TEXT,9,false,g_width-value_x-22);
  }
void DrawAccount(const datetime now)
  {
   long mode=AccountInfoInteger(ACCOUNT_MARGIN_MODE),trade=AccountInfoInteger(ACCOUNT_TRADE_MODE);
   string margin=(mode==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING ? "对冲" : mode==ACCOUNT_MARGIN_MODE_EXCHANGE ? "交易所" : "净额");
   string type=(trade==ACCOUNT_TRADE_MODE_REAL ? "实盘" : trade==ACCOUNT_TRADE_MODE_CONTEST ? "竞赛" : "模拟");
   string stop_unit=(AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE)==ACCOUNT_STOPOUT_MODE_PERCENT ? "%" : " "+g_currency);
   bool expert=AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)!=0 && AccountInfoInteger(ACCOUNT_TRADE_EXPERT)!=0 &&
               TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)!=0;
   Label("body.account.title","账户与经纪商  /  "+_Symbol,g_x+22,g_y+83,C_ACCENT,10,false,g_width-44);
   AccountRow(0,"MT5 路径",TerminalInfoString(TERMINAL_PATH));
   AccountRow(1,"账户 / 服务器",IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))+" / "+AccountInfoString(ACCOUNT_SERVER));
   AccountRow(2,"经纪商",AccountInfoString(ACCOUNT_COMPANY));
   AccountRow(3,"账户类型 / 持仓模式",type+" / "+margin);
   AccountRow(4,"杠杆 / 币种","1:"+IntegerToString(AccountInfoInteger(ACCOUNT_LEVERAGE))+" / "+g_currency);
   AccountRow(5,"最小 / 最大手数 / 步长",Lots(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN))+" / "+Lots(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX))+" / "+Lots(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)));
   AccountRow(6,"余额 / 净值",Money(AccountInfoDouble(ACCOUNT_BALANCE))+" / "+Money(AccountInfoDouble(ACCOUNT_EQUITY)));
   AccountRow(7,"已用 / 可用保证金",Money(AccountInfoDouble(ACCOUNT_MARGIN))+" / "+Money(AccountInfoDouble(ACCOUNT_MARGIN_FREE)));
   AccountRow(8,"保证金比例 / 强平线",Pct(AccountInfoDouble(ACCOUNT_MARGIN_LEVEL))+" / "+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_SO_SO),2)+stop_unit);
   AccountRow(9,"当前浮动盈亏",Money(AccountInfoDouble(ACCOUNT_EQUITY)-AccountInfoDouble(ACCOUNT_BALANCE)-AccountInfoDouble(ACCOUNT_CREDIT)));
   AccountRow(10,"挂单上限 / 对锁",IntegerToString(AccountInfoInteger(ACCOUNT_LIMIT_ORDERS))+" / "+(AccountInfoInteger(ACCOUNT_HEDGE_ALLOWED) ? "允许" : "不允许"));
   AccountRow(11,"点差 / 最小挂单距离",IntegerToString(SymbolInfoInteger(_Symbol,SYMBOL_SPREAD))+" 点 / "+IntegerToString(SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL))+" 点");
   AccountRow(12,"EA 自动交易权限",expert ? "允许" : "禁止");
   AccountRow(13,"服务器时间",TimeToString(now,TIME_DATE|TIME_SECONDS));
   AccountRow(14,"本地 / GMT",TimeToString(TimeLocal(),TIME_DATE|TIME_SECONDS)+" / "+TimeToString(TimeGMT(),TIME_DATE|TIME_SECONDS));
   AccountRow(15,"ECN", "MT5 无统一可查询标志");
   int nav_y=g_y+g_height-44,pages=(16+g_account_rows-1)/g_account_rows;
   Button("body.account.prev","上一页",g_x+16,nav_y,64);
   Button("body.account.next","下一页",g_x+g_width-80,nav_y,64);
   Label("body.account.page",IntegerToString(g_account_page+1)+" / "+IntegerToString(pages)+" 页",g_x+96,nav_y+5,C_MUTED,9,false,g_width-192);
  }

void RebuildView(const datetime now)
  {
   ArrayResize(g_cached_rows,0);
   for(int tab=0;tab<4;tab++)
     {
      BuildBuckets(tab,g_from,g_to,now,ShowEmptyPeriods);
      int count=ArraySize(g_rows);
      g_cached_offset[tab]=ArraySize(g_cached_rows);
      g_cached_count[tab]=count;
      ArrayResize(g_cached_rows,g_cached_offset[tab]+count,1024);
      g_cached_low[tab]=(count>0 ? g_rows[0].data.balance : 0);
      g_cached_high[tab]=g_cached_low[tab];
      for(int i=0;i<count;i++)
        {
         g_cached_rows[g_cached_offset[tab]+i]=g_rows[i];
         g_cached_low[tab]=MathMin(g_cached_low[tab],g_rows[i].data.balance);
         g_cached_high[tab]=MathMax(g_cached_high[tab],g_rows[i].data.balance);
        }
      g_cached_total[tab]=g_total;
      g_cache_valid[tab]=true;
     }
   g_plot_dirty=true;
   g_float_dirty=false;
   g_view_dirty=false;
   g_ui_dirty=true;
  }
void RenderPanel(const datetime now)
  {
   ConfigureLayout();
   if(g_view_dirty) RebuildView(now);
   g_ui_frame++;
   g_ui_wrote=false;
   Rect("panel",g_x,g_y,g_width,g_height,C_BG,C_BORDER);
   Rect("header",g_x,g_y,g_width,38,C_HEAD,C_HEAD);
   Label("title",g_tiny ? "窗口过小，请增大图表" : "账户交易统计",g_x+16,g_y+9,C_TEXT,11,false,g_width-130);
   Button("refresh","R",g_x+g_width-98,g_y+6,25,"重新核对全部历史");
   Button("min","-",g_x+g_width-67,g_y+6,25,"最小化为标题栏");
   Button("restore","+",g_x+g_width-36,g_y+6,25,"恢复固定宽高；展开时保持不变");
   if(!g_minimized && !g_tiny)
     {
      int tab_width=(g_width-24)/5;
      for(int i=0;i<5;i++)
        {
         string id="body.tab."+IntegerToString(i);
         Button(id,g_tabs[i],g_x+12+i*tab_width,g_y+43,tab_width-4);
         UiSetInt(0,Name(id),OBJPROP_BGCOLOR,i==g_tab ? C_ACCENT : C_HEAD);
         UiSetInt(0,Name(id),OBJPROP_COLOR,i==g_tab ? C_BG : C_TEXT);
        }
      if(g_tab<4) DrawStats();
      else DrawAccount(now);
     }
   UiSweepBody(Name("body."));
   if(g_tab==4 || g_minimized || g_tiny || g_curve_height<=0)
     {
      if(g_curve_ready) { g_curve.Destroy(); g_curve_ready=false; }
     }
   if(g_ui_wrote) ChartRedraw(0);
   g_ui_dirty=false;
   g_float_dirty=false;
  }

bool ApplyRange(const bool all)
  {
   ReadEdits();
   datetime from=0,to=0;
   if(!all && (!ParseDate(g_from_text,from) || !ParseDate(g_to_text,to)))
     { g_message="日期格式应为 YYYY.MM.DD，留空表示不限制"; return false; }
   datetime now=ServerNow();
   if((from>0 && to>0 && from>to) || from>DayStart(now))
     { g_message="起始日期不能晚于截止日期或今天"; return false; }
   g_from=from; g_to=to;
   ClearBody();
   g_from_text=(from==0 ? "" : DateText(from));
   g_to_text=(to==0 ? "" : DateText(to));
   UiInvalidateText(Name("body.from")); UiInvalidateText(Name("body.to"));
   UiSetString(0,Name("body.from"),OBJPROP_TEXT,g_from_text);
   UiSetString(0,Name("body.to"),OBJPROP_TEXT,g_to_text);
   for(int i=0;i<4;i++) g_page[i]=0;
   g_message="";
   g_view_dirty=true;
   return true;
  }

int OnInit()
  {
   if(PanelWidth<900 || PanelWidth>2400 || PanelHeight<620 || PanelHeight>1200 ||
      RowsPerPage<1 || RowsPerPage>12 || HistorySliceMs<1 || HistorySliceMs>30 || ReconcileMinutes<10 ||
      RefreshSeconds<1 || SampleSeconds<1)
      return INIT_PARAMETERS_INCORRECT;
   g_prefix="ASP2."+IntegerToString(ChartID())+"."+IntegerToString(GetTickCount64())+".";
   g_currency=AccountInfoString(ACCOUNT_CURRENCY);
   g_currency_digits=(int)MathMax(0,MathMin(6,AccountInfoInteger(ACCOUNT_CURRENCY_DIGITS)));
   g_chart_width=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
   g_chart_height=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS);
   g_screen_dpi=(int)MathMax(72,TerminalInfoInteger(TERMINAL_SCREEN_DPI));
   g_from=RangeFrom; g_to=RangeTo;
   g_from_text=(g_from==0 ? "" : DateText(g_from));
   g_to_text=(g_to==0 ? "" : DateText(g_to));
   if(g_from>0 && g_to>0 && DayStart(g_from)>DayStart(g_to)) return INIT_PARAMETERS_INCORRECT;
   string account=IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))+"_"+IntegerToString((long)HashText(AccountInfoString(ACCOUNT_SERVER)));
   g_store_file="AccountStatsPanel\\daily_"+account+".bin";
   g_store_lock="ASP2.L."+account;
   ReadFloatStore();
   g_mouse_previous=ChartGetInteger(0,CHART_EVENT_MOUSE_MOVE)!=0;
   ChartSetInteger(0,CHART_EVENT_MOUSE_MOVE,true);
   g_events_ready=true;
   datetime now=ServerNow();
   g_force_history=true; // Start after the panel exists.
   SampleFloating(now);
   g_last_day=DayStart(now);
   g_last_refresh_ms=g_last_sample_ms=g_last_save_ms=g_last_full_ms=GetTickCount64();
   if(!EventSetMillisecondTimer(50)) return INIT_FAILED;
   RenderPanel(now);
   return INIT_SUCCEEDED;
  }
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_prefix=="") return;
   SaveFloatStore();
   CaptureScroll(false);
   if(g_events_ready) ChartSetInteger(0,CHART_EVENT_MOUSE_MOVE,g_mouse_previous);
   if(g_curve_ready) g_curve.Destroy();
   ObjectsDeleteAll(0,g_prefix);
   ChartRedraw(0);
  }
int OnCalculate(const int rates_total,const int prev_calculated,const datetime &time[],const double &open[],
                const double &high[],const double &low[],const double &close[],const long &tick_volume[],const long &volume[],const int &spread[])
  {
   return rates_total;
  }
void OnTimer()
  {
   datetime now=ServerNow();
   ulong ms=GetTickCount64();
   static ulong last_dpi_ms=0;
   if(ms-last_dpi_ms>=1000)
     {
      int dpi=(int)MathMax(72,TerminalInfoInteger(TERMINAL_SCREEN_DPI));
      if(dpi!=g_screen_dpi) { g_screen_dpi=dpi; g_ui_dirty=true; }
      last_dpi_ms=ms;
     }
   if(g_last_day!=DayStart(now)) { g_last_day=DayStart(now); g_view_dirty=true; g_plot_dirty=true; }
   if(ms-g_last_sample_ms>=(ulong)SampleSeconds*1000) { SampleFloating(now); g_last_sample_ms=ms; }
   bool reconcile=ms-g_last_full_ms>=(ulong)ReconcileMinutes*60000;
   if(!g_history_busy && (g_force_history || reconcile || ms-g_last_refresh_ms>=(ulong)RefreshSeconds*1000))
     {
      bool full=g_force_history || reconcile;
      if(RefreshHistory(now,full)) { g_force_history=false; if(full) g_last_full_ms=ms; }
      g_last_refresh_ms=ms;
     }
   if(g_history_busy) HistorySlice();
   if(ms-g_last_save_ms>=30000 && !g_history_busy) { SaveFloatStore(); g_last_save_ms=ms; }
   static ulong last_account_ms=0,last_progress_ms=0;
   bool account_due=g_tab==4 && ms-last_account_ms>=1000;
   bool progress_due=g_history_busy && ms-last_progress_ms>=1000;
   if(!g_minimized && (g_view_dirty || g_ui_dirty || g_float_dirty || account_due || progress_due))
     {
      if(progress_due)
        {
         g_message="核对历史 "+IntegerToString(g_job_deal+g_job_order)+" / "+IntegerToString(g_job_deals+g_job_orders)+"；仍可切页翻页";
         last_progress_ms=ms;
        }
      RenderPanel(now);
      if(account_due) last_account_ms=ms;
     }
  }
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id==CHARTEVENT_CHART_CHANGE)
     {
      int width=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS),height=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS);
      int dpi=(int)MathMax(72,TerminalInfoInteger(TERMINAL_SCREEN_DPI));
      if(width==g_chart_width && height==g_chart_height && dpi==g_screen_dpi) return;
      g_screen_dpi=dpi;
      g_chart_width=width; g_chart_height=height;
      RenderPanel(ServerNow()); return;
     }
   if(id==CHARTEVENT_MOUSE_MOVE)
     {
      int mx=(int)MathRound((double)lparam/g_scale),my=(int)MathRound(dparam/g_scale);
      bool down=((uint)StringToInteger(sparam)&1)!=0,pressed=down && !g_left_down;
      g_left_down=down;
      if(g_dragging)
        {
         ulong ms=GetTickCount64();
         if(!down || ms-g_last_drag_ms>=30)
           {
            g_x=mx-g_drag_dx; g_y=my-g_drag_dy; g_last_drag_ms=ms;
            RenderPanel(ServerNow());
           }
         if(!down) { g_dragging=false; CaptureScroll(false); }
         return;
        }
      bool inside=mx>=g_x && mx<g_x+g_width && my>=g_y && my<g_y+g_height;
      CaptureScroll(inside);
      if(pressed && mx>=g_x && mx<g_x+g_width-112 && my>=g_y && my<g_y+38)
        { g_dragging=true; g_drag_dx=mx-g_x; g_drag_dy=my-g_y; g_last_drag_ms=0; }
      return;
     }
   if(id!=CHARTEVENT_OBJECT_CLICK || StringFind(sparam,g_prefix)!=0) return;
   UiReleaseButton(sparam);
   if(sparam==Name("min"))
     {
      if(!g_minimized) { ClearBody(); g_minimized=true; }
     }
   else if(sparam==Name("restore"))
     {
      if(!g_minimized) return; // + never changes an already expanded window
      g_minimized=false;
     }
   else if(sparam==Name("refresh")) { g_force_history=true; g_message="正在重新核对历史…"; }
   else if(sparam==Name("body.account.prev")) g_account_page=(int)MathMax(0,g_account_page-1);
   else if(sparam==Name("body.account.next")) g_account_page=(int)MathMin((16-1)/g_account_rows,g_account_page+1);
   else if(sparam==Name("body.apply")) ApplyRange(false);
   else if(sparam==Name("body.all")) ApplyRange(true);
   else if(sparam==Name("body.first") && g_tab<4) g_page[g_tab]=0;
   else if(sparam==Name("body.prev") && g_tab<4) g_page[g_tab]=(int)MathMax(0,g_page[g_tab]-1);
   else if(sparam==Name("body.next") && g_tab<4) g_page[g_tab]++;
   else if(sparam==Name("body.last") && g_tab<4) g_page[g_tab]=(int)MathMax(0,(ViewRowCount()-1)/g_rows_per_page);
   else if(sparam==Name("body.col.prev") && g_tab<4)
     { if(g_first_col[g_tab]>1) { ClearBody(); g_first_col[g_tab]--; } }
   else if(sparam==Name("body.col.next") && g_tab<4)
     { if(LastVisibleColumn()<ASP_COLUMNS-1) { ClearBody(); g_first_col[g_tab]++; } }
   else
     {
      bool tab_click=false;
      for(int t=0;t<5;t++)
         if(sparam==Name("body.tab."+IntegerToString(t)))
           {
            tab_click=true;
      if(t!=g_tab)
        {
         ClearTabVisuals();
         g_tab=t;
         g_view_dirty=(t<4 && !g_cache_valid[t]);
         g_plot_dirty=true;
        }
            break;
           }
      if(!tab_click) return; // title/label clicks must not cancel mouse dragging
     }
   g_dragging=false;
   RenderPanel(ServerNow());
  }
