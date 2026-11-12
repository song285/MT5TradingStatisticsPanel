// Cache properties in the indicator thread. ObjectFind/ObjectGet are synchronous
// chart-queue barriers; routine rendering must not call them per table cell.
#define ASP_UI_CAPACITY 512
#define ASP_UI_HASH 1024
struct SUiObject
  {
   string name;
   int type;
   bool alive;
   int frame;
   uint mask;
   long values[24];
   string texts[3];
   uint text_mask;
   string fit_full,fit_text;
   int fit_width,fit_font,fit_dpi;
  };
SUiObject g_ui_objects[ASP_UI_CAPACITY];
int g_ui_hash[ASP_UI_HASH];
int g_ui_count=0,g_ui_frame=0,g_ui_last=-1;
bool g_ui_wrote=false;

int UiFind(const string name,const bool create=false)
  {
   if(g_ui_last>=0 && g_ui_objects[g_ui_last].name==name) return g_ui_last;
   uint hash=2166136261;
   for(int c=0;c<StringLen(name);c++) hash=(hash^(uint)StringGetCharacter(name,c))*16777619;
   int slot=(int)(hash%ASP_UI_HASH);
   for(int probe=0;probe<ASP_UI_HASH;probe++)
     {
      int index=g_ui_hash[slot]-1;
      if(index<0)
        {
         if(!create || g_ui_count>=ASP_UI_CAPACITY) return -1;
         index=g_ui_count++;
         g_ui_objects[index].name=name;
         g_ui_hash[slot]=index+1;
         g_ui_last=index;
         return index;
        }
      if(g_ui_objects[index].name==name) { g_ui_last=index; return index; }
      slot=(slot+1)%ASP_UI_HASH;
     }
   return -1;
  }
bool UiExists(const string name)
  {
   int index=UiFind(name);
   return index>=0 && g_ui_objects[index].alive;
  }
void UiAdopt(const string name)
  {
   int i=UiFind(name,true);
   if(i<0) return;
   if(!g_ui_objects[i].alive)
     {
      g_ui_objects[i].alive=true;
      g_ui_objects[i].type=OBJ_BITMAP_LABEL;
      g_ui_objects[i].mask=0;
      g_ui_objects[i].text_mask=0;
     }
   g_ui_objects[i].frame=g_ui_frame;
  }
bool UiEnsure(const string name,const ENUM_OBJECT type)
  {
   int index=UiFind(name,true);
   if(index<0) return false;
   g_ui_objects[index].frame=g_ui_frame;
   if(g_ui_objects[index].alive) return true;
   if(!ObjectCreate(0,name,type,0,0,0)) return false;
   g_ui_objects[index].alive=true;
   g_ui_objects[index].type=(int)type;
   g_ui_objects[index].mask=0;
   g_ui_objects[index].text_mask=0;
   g_ui_wrote=true;
   return true;
  }
int UiIntSlot(const ENUM_OBJECT_PROPERTY_INTEGER prop)
  {
   switch(prop)
     {
      case OBJPROP_CORNER:return 0;
      case OBJPROP_ANCHOR:return 1;
      case OBJPROP_XDISTANCE:return 2;
      case OBJPROP_YDISTANCE:return 3;
      case OBJPROP_XSIZE:return 4;
      case OBJPROP_YSIZE:return 5;
      case OBJPROP_BGCOLOR:return 6;
      case OBJPROP_COLOR:return 7;
      case OBJPROP_BORDER_TYPE:return 8;
      case OBJPROP_BORDER_COLOR:return 9;
      case OBJPROP_BACK:return 10;
      case OBJPROP_SELECTABLE:return 11;
      case OBJPROP_HIDDEN:return 12;
      case OBJPROP_ZORDER:return 13;
      case OBJPROP_FONTSIZE:return 14;
      case OBJPROP_STATE:return 15;
      case OBJPROP_ALIGN:return 16;
      case OBJPROP_READONLY:return 17;
     }
   return -1;
  }
bool UiSetInt(const long chart,const string name,const ENUM_OBJECT_PROPERTY_INTEGER prop,const long value)
  {
   int i=UiFind(name),slot=UiIntSlot(prop);
   if(i<0 || slot<0) return ObjectSetInteger(chart,name,prop,value);
   uint bit=(uint)1<<slot;
   if((g_ui_objects[i].mask&bit)!=0 && g_ui_objects[i].values[slot]==value) return true;
   if(!ObjectSetInteger(chart,name,prop,value)) return false;
   g_ui_objects[i].mask|=bit;
   g_ui_objects[i].values[slot]=value;
   g_ui_wrote=true;
   return true;
  }
bool UiSetString(const long chart,const string name,const ENUM_OBJECT_PROPERTY_STRING prop,const string value)
  {
   int i=UiFind(name),slot=(prop==OBJPROP_TEXT ? 0 : prop==OBJPROP_FONT ? 1 : 2);
   if(i<0) return ObjectSetString(chart,name,prop,value);
   uint bit=(uint)1<<slot;
   if((g_ui_objects[i].text_mask&bit)!=0 && g_ui_objects[i].texts[slot]==value) return true;
   if(!ObjectSetString(chart,name,prop,value)) return false;
   g_ui_objects[i].text_mask|=bit;
   g_ui_objects[i].texts[slot]=value;
   g_ui_wrote=true;
   return true;
  }
void UiInvalidateText(const string name)
  {
   int i=UiFind(name);
   if(i>=0) g_ui_objects[i].text_mask&=~(uint)1;
  }
void UiReleaseButton(const string name)
  {
   int i=UiFind(name);
   if(i<0 || g_ui_objects[i].type!=(int)OBJ_BUTTON) return;
   g_ui_objects[i].mask&=~((uint)1<<15);
   UiSetInt(0,name,OBJPROP_STATE,false);
  }
void UiDelete(const string name)
  {
   int i=UiFind(name);
   if(i<0 || !g_ui_objects[i].alive) return;
   ObjectDelete(0,name);
   g_ui_objects[i].alive=false;
   g_ui_wrote=true;
  }
void UiSweepBody(const string prefix)
  {
   for(int i=0;i<g_ui_count;i++)
      if(g_ui_objects[i].alive && g_ui_objects[i].frame!=g_ui_frame &&
         StringFind(g_ui_objects[i].name,prefix)==0) UiDelete(g_ui_objects[i].name);
  }
