//+------------------------------------------------------------------+
//|                                           GoldenBreak.mq5         |
//|  Konsep: Donchian Channel Breakout + ADX Trend Filter             |
//|  Risk Management: Fixed Fractional (% equity per trade)           |
//|  Prinsip: SATU posisi per waktu, TIDAK ADA averaging/grid/martingale |
//+------------------------------------------------------------------+
#property copyright "Dibuat bersama Claude - untuk belajar & eksperimen"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//================== INPUT PARAMETERS ==================
input group "=== Donchian Breakout ==="
input int    DonchianPeriod   = 20;     // Jumlah candle untuk hitung highest/lowest
input double BreakoutBufferATR = 0.2;   // Buffer breakout (x ATR) biar hindari false breakout tipis
input bool   AllowLong         = true;  // Izinkan sinyal BUY (matikan kalau mau short-only)
input bool   AllowShort        = true;  // Izinkan sinyal SELL (matikan kalau mau long-only)

input group "=== Trend Filter (ADX) ==="
input int    ADXPeriod        = 14;     // Periode ADX
input double ADXThreshold     = 22.0;   // Minimal ADX supaya dianggap trending

input group "=== Stop Loss / Take Profit ==="
input int    ATRPeriod        = 14;     // Periode ATR untuk SL
input double ATR_SL_Multiplier = 2.0;   // SL = sekian x ATR dari harga entry
input double RiskRewardRatio  = 1.5;    // TP = SL_distance x rasio ini

enum ENUM_TRAILING_MODE
{
   TRAIL_PIPS,               // Trailing berbasis jarak poin tetap
   TRAIL_PERCENT_OF_TARGET   // Trailing berbasis % dari jarak target (SL->TP awal)
};

input group "=== Trailing Stop (BARU) ==="
input bool   UseTrailingStop        = false;  // Enable/disable trailing stop -- default OFF, tidak ganggu behavior sekarang
input ENUM_TRAILING_MODE TrailingMode = TRAIL_PIPS; // Pilih basis perhitungan trailing
input double TrailingStartPips      = 300;    // [mode PIPS] Profit (poin) sebelum trailing mulai aktif
input double TrailingStepPips       = 150;    // [mode PIPS] Jarak SL trailing di belakang harga (poin)
input double TrailingStartPercent   = 50.0;   // [mode PERCENT_OF_TARGET] % dari jarak target (SL->TP awal) sebelum trailing aktif
input double TrailingStepPercent    = 25.0;   // [mode PERCENT_OF_TARGET] Jarak SL trailing = sekian % dari jarak target

input group "=== Risk Management (PALING PENTING) ==="
input double RiskPercent      = 1.0;    // Risiko per trade, % dari equity (0.5-1% disarankan)

input group "=== Risk Cap (BARU) ==="
input bool   UseMaxRiskCap    = true;   // Batasi $ risk per trade maksimal -- biar compounding tidak "kebablasan" pas equity sudah besar
input double MaxRiskMoneyCap  = 500.0;  // Risk per trade TIDAK AKAN melebihi angka ini ($), walau equity sudah jauh lebih besar dari awal

input group "=== Fixed Lot Mode (BARU) ==="
input bool   UseFixedLot      = false;  // true = pakai lot TETAP, abaikan RiskPercent & MaxRiskMoneyCap sepenuhnya
input double FixedLotSize     = 0.01;   // Lot tetap, dipakai kalau UseFixedLot=true
input double MaxLotSize       = 10.0;   // Hard cap lot, safety net kalau perhitungan meleset

input group "=== Exit Tambahan ==="
input bool   UseTimeExit      = true;   // Aktifkan time-based exit
input int    MaxBarsInTrade   = 48;     // Tutup posisi kalau sudah sekian candle tanpa progres berarti

input group "=== General ==="
input int    MagicNumber      = 20260727;
input string TradeComment     = "GoldenBreak";

input group "=== Dashboard ==="
input bool   ShowDashboard    = true;   // Tampilkan panel info di chart
input int    DashboardX       = 15;     // Posisi X panel (pixel dari kiri)
input int    DashboardY       = 25;     // Posisi Y panel (pixel dari atas)

input group "=== News Filter (Economic Calendar) ==="
input bool   UseNewsFilter       = true;    // Aktifkan filter berita high-impact
input string NewsCurrencyFilter  = "USD";   // Currency yang dipantau (USD relevan untuk XAUUSD)
input ENUM_CALENDAR_EVENT_IMPORTANCE MinNewsImportance = CALENDAR_IMPORTANCE_HIGH; // Minimal level kepentingan berita
input int    MinutesBeforeNews   = 60;      // Blokir entry baru X menit SEBELUM berita high-impact
input int    MinutesAfterNews    = 60;      // Blokir entry baru X menit SETELAH berita (biarkan volatilitas reda)
input bool   CloseBeforeNews     = false;   // Kalau true: paksa tutup posisi terbuka begitu masuk window blackout

//================== GLOBAL HANDLES ==================
int adxHandle;
int atrHandle;
datetime lastBarTime = 0;

// Cache status news blackout supaya nggak query calendar API tiap tick (cukup tiap beberapa menit)
bool     newsBlackoutCache = false;
string   newsBlackoutName  = "";
datetime newsBlackoutUntil = 0;
datetime lastNewsCheck     = 0;

//+------------------------------------------------------------------+
//| Cek apakah waktu SEKARANG berada dalam window blackout berita     |
//| high-impact (MinutesBeforeNews sebelum s/d MinutesAfterNews       |
//| sesudah event). Pakai MQL5 Economic Calendar API bawaan --        |
//| jalan di live/demo maupun Strategy Tester (data historis)         |
//+------------------------------------------------------------------+
bool IsNewsBlackout(string &newsNameOut)
{
   if(!UseNewsFilter) return false;

   datetime now = TimeCurrent();

   // Cache 5 menit sekali supaya nggak query calendar API tiap tick (lumayan berat)
   if(now - lastNewsCheck < 300 && lastNewsCheck != 0)
   {
      newsNameOut = newsBlackoutName;
      return newsBlackoutCache;
   }
   lastNewsCheck = now;

   datetime from = now - MinutesAfterNews * 60;
   datetime to   = now + MinutesBeforeNews * 60;

   MqlCalendarValue values[];
   int total = CalendarValueHistory(values, from, to, NULL, NewsCurrencyFilter);

   for(int i = 0; i < total; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      if(ev.importance < MinNewsImportance) continue;

      // Event ini high-impact dan waktu event-nya ada di window [from, to] relatif ke 'now'
      newsBlackoutCache = true;
      newsBlackoutName  = ev.name + " (" + TimeToString(values[i].time, TIME_DATE|TIME_MINUTES) + ")";
      newsNameOut = newsBlackoutName;
      return true;
   }

   newsBlackoutCache = false;
   newsBlackoutName  = "";
   newsNameOut = "";
   return false;
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   adxHandle = iADX(_Symbol, PERIOD_CURRENT, ADXPeriod);
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);

   if(adxHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Gagal membuat indicator handle. Cek periode/symbol.");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   DB_Create();
   DB_Update();

   Print("GoldenBreak initialized. Risk per trade: ", RiskPercent, "% | Donchian: ", DonchianPeriod, " | ADX threshold: ", ADXThreshold);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(adxHandle);
   IndicatorRelease(atrHandle);
   DB_Delete();
}

//================== DASHBOARD ==================
#define DB_PREFIX "BTEA_"
#define DB_LINES  11
#define DB_LINE_HEIGHT 16
#define DB_WIDTH  260

string dbLineNames[DB_LINES] = {
   "title","symbol","status","adx","atr",
   "position","floating","equity","risk","news","updated"
};

//+------------------------------------------------------------------+
//| Bikin 1 label text di chart                                       |
//+------------------------------------------------------------------+
void DB_CreateLabel(string name, int x, int y, string text, color clr, int fontSize=9)
{
   string fullName = DB_PREFIX + name;
   if(ObjectFind(0, fullName) < 0)
      ObjectCreate(0, fullName, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, fullName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, fullName, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, fullName, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, fullName, OBJPROP_TEXT, text);
   ObjectSetString(0, fullName, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, fullName, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, fullName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, fullName, OBJPROP_BACK, false);
   ObjectSetInteger(0, fullName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, fullName, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Bikin background panel (rectangle)                                |
//+------------------------------------------------------------------+
void DB_CreateBackground()
{
   string name = DB_PREFIX + "bg";
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, DashboardX - 8);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, DashboardY - 8);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, DB_WIDTH);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, DB_LINES * DB_LINE_HEIGHT + 10);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'20,20,20');
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrDimGray);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Bikin semua elemen panel (dipanggil sekali di OnInit)             |
//+------------------------------------------------------------------+
void DB_Create()
{
   if(!ShowDashboard) return;
   DB_CreateBackground();
   for(int i = 0; i < DB_LINES; i++)
      DB_CreateLabel(dbLineNames[i], DashboardX, DashboardY + i * DB_LINE_HEIGHT, "", clrWhite);
}

//+------------------------------------------------------------------+
//| Hapus semua object panel (dipanggil di OnDeinit)                  |
//+------------------------------------------------------------------+
void DB_Delete()
{
   ObjectsDeleteAll(0, DB_PREFIX);
}

//+------------------------------------------------------------------+
//| Update isi panel dengan kondisi EA terkini                        |
//+------------------------------------------------------------------+
void DB_Update()
{
   if(!ShowDashboard) return;

   double adx = 0, atr = 0, highest = 0, lowest = 0;
   bool adxOk = GetADX(adx);
   bool atrOk = GetATR(atr);

   // --- Judul & symbol ---
   DB_CreateLabel("title", DashboardX, DashboardY + 0*DB_LINE_HEIGHT,
                  "GoldenBreak", clrDeepSkyBlue, 10);
   DB_CreateLabel("symbol", DashboardX, DashboardY + 1*DB_LINE_HEIGHT,
                  _Symbol + "  " + EnumToString((ENUM_TIMEFRAMES)_Period), clrSilver);

   // --- Status market: trending / ranging berdasarkan ADX ---
   string statusText = "Status  : (menunggu data)";
   color  statusClr  = clrGray;
   if(adxOk)
   {
      if(adx >= ADXThreshold)
      {
         statusText = "Status  : TRENDING (aktif cari sinyal)";
         statusClr  = clrLimeGreen;
      }
      else
      {
         statusText = "Status  : RANGING (EA standby)";
         statusClr  = clrOrange;
      }
   }
   DB_CreateLabel("status", DashboardX, DashboardY + 2*DB_LINE_HEIGHT, statusText, statusClr);

   // --- Nilai ADX & ATR ---
   string adxText = adxOk ? StringFormat("ADX     : %.1f  (min %.1f)", adx, ADXThreshold) : "ADX     : n/a";
   DB_CreateLabel("adx", DashboardX, DashboardY + 3*DB_LINE_HEIGHT, adxText, clrSilver);

   string atrText = atrOk ? StringFormat("ATR     : %s", DoubleToString(atr, _Digits)) : "ATR     : n/a";
   DB_CreateLabel("atr", DashboardX, DashboardY + 4*DB_LINE_HEIGHT, atrText, clrSilver);

   // --- Info posisi terbuka (kalau ada) ---
   string posText = "Posisi  : NONE";
   string floatText = "Floating: -";
   color  posClr = clrGray;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      string typeStr = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      posClr = (profit >= 0) ? clrLimeGreen : clrTomato;

      posText = StringFormat("Posisi  : %s %.2f lot", typeStr, vol);
      floatText = StringFormat("Floating: %s %.2f", (profit >= 0 ? "+" : ""), profit);
      break; // cuma 1 posisi per prinsip EA ini
   }
   DB_CreateLabel("position", DashboardX, DashboardY + 5*DB_LINE_HEIGHT, posText, clrSilver);
   DB_CreateLabel("floating", DashboardX, DashboardY + 6*DB_LINE_HEIGHT, floatText, posClr);

   // --- Equity & risk per trade ---
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (RiskPercent / 100.0);
   bool isCapped = false;
   if(UseMaxRiskCap && riskMoney > MaxRiskMoneyCap)
   {
      riskMoney = MaxRiskMoneyCap;
      isCapped = true;
   }
   string currency = AccountInfoString(ACCOUNT_CURRENCY);

   string eqText = StringFormat("Equity  : %.2f %s", equity, currency);
   DB_CreateLabel("equity", DashboardX, DashboardY + 7*DB_LINE_HEIGHT, eqText, clrSilver);

   string riskText;
   color riskColor;
   if(UseFixedLot)
   {
      riskText = StringFormat("Lot Mode: FIXED %.2f lot", FixedLotSize);
      riskColor = clrAqua;
   }
   else
   {
      riskText = StringFormat("Risk/trd: %.2f %s (%.1f%%)%s", riskMoney, currency, RiskPercent,
                               isCapped ? " [CAPPED]" : "");
      riskColor = isCapped ? clrOrange : clrKhaki;
   }
   DB_CreateLabel("risk", DashboardX, DashboardY + 8*DB_LINE_HEIGHT, riskText, riskColor);

   // --- Status news blackout ---
   string newsName;
   bool blackout = IsNewsBlackout(newsName);
   string newsText = blackout ? ("News    : BLACKOUT - " + newsName) : "News    : Clear (aman entry)";
   color  newsClr  = blackout ? clrTomato : clrDimGray;
   DB_CreateLabel("news", DashboardX, DashboardY + 9*DB_LINE_HEIGHT, newsText, newsClr, 8);

   string updText = "Update  : " + TimeToString(TimeCurrent(), TIME_SECONDS);
   DB_CreateLabel("updated", DashboardX, DashboardY + 10*DB_LINE_HEIGHT, updText, clrDimGray, 8);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Cek apakah ada posisi terbuka milik EA ini di symbol ini          |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Ambil nilai ADX main line terbaru (candle sudah closed)           |
//+------------------------------------------------------------------+
bool GetADX(double &adxValue)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(adxHandle, 0, 1, 1, buf) <= 0) return false; // shift 1 = candle terakhir yang sudah closed
   adxValue = buf[0];
   return true;
}

//+------------------------------------------------------------------+
//| Ambil nilai ATR terbaru (candle sudah closed)                     |
//+------------------------------------------------------------------+
bool GetATR(double &atrValue)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, buf) <= 0) return false;
   atrValue = buf[0];
   return true;
}

//+------------------------------------------------------------------+
//| Hitung highest high & lowest low N candle SEBELUM candle sinyal   |
//| PENTING: mulai dari shift 2, BUKAN shift 1 -- karena shift 1      |
//| adalah candle sinyal itu sendiri (yang closenya mau kita cek).    |
//| Kalau shift 1 ikut dihitung, candle itu dibandingkan dengan       |
//| dirinya sendiri dan breakout jadi mustahil terdeteksi (bug lama). |
//+------------------------------------------------------------------+
bool GetDonchianChannel(double &highest, double &lowest)
{
   int highIdx = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, DonchianPeriod, 2);
   int lowIdx  = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, DonchianPeriod, 2);
   if(highIdx < 0 || lowIdx < 0) return false;

   highest = iHigh(_Symbol, PERIOD_CURRENT, highIdx);
   lowest  = iLow(_Symbol, PERIOD_CURRENT, lowIdx);
   return true;
}

//+------------------------------------------------------------------+
//| Hitung lot size berdasarkan % risk dari equity dan jarak SL       |
//| INI JANTUNG dari risk management -- lot BUKAN fixed, tapi         |
//| menyesuaikan otomatis ke equity & volatilitas market saat itu     |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePrice)
{
   // BARU: mode fixed lot -- kalau aktif, abaikan semua logic risk% & cap
   // di bawah, langsung pakai angka tetap. Cocok buat yang mau kontrol lot
   // manual penuh, atau buat testing/komparasi terhadap mode risk%-based.
   if(UseFixedLot)
   {
      double fLot = FixedLotSize;
      double fLotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double fMinLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double fMaxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

      fLot = MathRound(fLot / fLotStep) * fLotStep;
      fLot = MathMax(fLot, fMinLot);
      fLot = MathMin(fLot, fMaxLot);
      return fLot;
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (RiskPercent / 100.0);

   // FIX/BARU: cap $ risk maksimal per trade. Tanpa ini, compounding murni
   // (risk % dari equity) bikin nominal $ risk terus membesar seiring
   // equity naik -- di equity yang jauh lebih besar dari modal awal, risk
   // per trade bisa jadi berkali-kali lipat dari niat awal (contoh nyata:
   // equity $10rb -> $180rb di risk 3%, risk per trade dari $300 jadi
   // $5.400). Cap ini memotong riskMoney di angka tetap begitu equity
   // sudah cukup besar, sementara growth di equity kecil-menengah tetap
   // proporsional (compounding tetap jalan sampai batas cap tercapai).
   if(UseMaxRiskCap && riskMoney > MaxRiskMoneyCap)
   {
      riskMoney = MaxRiskMoneyCap;
   }

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0)
   {
      Print("ERROR: tickValue/tickSize invalid untuk ", _Symbol);
      return 0;
   }

   // Berapa "value" per 1.0 lot untuk jarak SL yang dihitung
   double valuePerLot = (slDistancePrice / tickSize) * tickValue;
   if(valuePerLot <= 0) return 0;

   double lot = riskMoney / valuePerLot;

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lot = MathFloor(lot / lotStep) * lotStep;

   // PENTING: kalau lot hasil hitungan risk% lebih kecil dari minimum
   // broker, JANGAN dipaksa naik ke minLot -- itu artinya minLot broker
   // sudah mewakili risiko lebih besar dari RiskPercent yang diminta.
   // Lebih baik SKIP trade ini daripada diam-diam over-risk.
   if(lot < minLot)
   {
      double actualRiskIfMinLot = valuePerLot * minLot;
      double actualRiskPercent  = (actualRiskIfMinLot / equity) * 100.0;
      Print("Skip entry: lot dibutuhkan (", DoubleToString(lot,4),
            ") di bawah minimum broker (", minLot,
            "). Kalau dipaksa minLot, risiko jadi ~", DoubleToString(actualRiskPercent,2),
            "% bukan ", RiskPercent, "%. Modal saat ini mungkin terlalu kecil untuk symbol ini.");
      return 0;
   }

   lot = MathMin(lot, MathMin(maxLot, MaxLotSize)); // hard cap safety
   return lot;
}

//+------------------------------------------------------------------+
//| Time-based exit: tutup posisi kalau sudah kelamaan tanpa progres  |
//+------------------------------------------------------------------+
void CheckTimeExit()
{
   if(!UseTimeExit) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      int barsSinceOpen = iBarShift(_Symbol, PERIOD_CURRENT, openTime, false);

      if(barsSinceOpen >= MaxBarsInTrade)
      {
         Print("Time exit tercapai (", barsSinceOpen, " bars). Menutup posisi #", ticket);
         trade.PositionClose(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Cek & eksekusi sinyal entry breakout                              |
//+------------------------------------------------------------------+
void CheckEntrySignal()
{
   // --- FILTER 0: Jangan entry kalau lagi dalam window news blackout ---
   string newsName;
   if(IsNewsBlackout(newsName))
   {
      Print("Skip entry: news blackout aktif -- ", newsName);
      return;
   }

   double adx, atr, highest, lowest;
   if(!GetADX(adx)) return;
   if(!GetATR(atr)) return;
   if(!GetDonchianChannel(highest, lowest)) return;

   // --- FILTER 1: Market harus trending ---
   if(adx < ADXThreshold)
      return; // market ranging/choppy, EA diam

   double closePrice = iClose(_Symbol, PERIOD_CURRENT, 1); // candle terakhir yang sudah closed
   double buffer = BreakoutBufferATR * atr;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // --- SINYAL BUY: close di atas highest + buffer ---
   if(closePrice > highest + buffer)
   {
      if(!AllowLong)
      {
         Print("Sinyal BUY terdeteksi tapi AllowLong=false, skip.");
         return;
      }

      double slDistance = ATR_SL_Multiplier * atr;
      double sl = ask - slDistance;
      double tp = ask + (slDistance * RiskRewardRatio);
      double lot = CalculateLotSize(slDistance);

      if(lot <= 0) { Print("Lot size invalid, skip entry BUY."); return; }

      if(trade.Buy(lot, _Symbol, ask, sl, tp, TradeComment))
         Print("BUY dibuka. Lot=", lot, " SL=", sl, " TP=", tp, " ADX=", adx);
      else
         Print("BUY gagal: ", trade.ResultRetcodeDescription());
      return;
   }

   // --- SINYAL SELL: close di bawah lowest - buffer ---
   if(closePrice < lowest - buffer)
   {
      if(!AllowShort)
      {
         Print("Sinyal SELL terdeteksi tapi AllowShort=false, skip.");
         return;
      }

      double slDistance = ATR_SL_Multiplier * atr;
      double sl = bid + slDistance;
      double tp = bid - (slDistance * RiskRewardRatio);
      double lot = CalculateLotSize(slDistance);

      if(lot <= 0) { Print("Lot size invalid, skip entry SELL."); return; }

      if(trade.Sell(lot, _Symbol, bid, sl, tp, TradeComment))
         Print("SELL dibuka. Lot=", lot, " SL=", sl, " TP=", tp, " ADX=", adx);
      else
         Print("SELL gagal: ", trade.ResultRetcodeDescription());
      return;
   }
}


//+------------------------------------------------------------------+
//| Kalau CloseBeforeNews aktif, paksa tutup posisi begitu masuk       |
//| window blackout berita (opsional, default OFF -- default-nya EA   |
//| cuma nolak entry BARU, posisi yang sudah terbuka tetap dibiarkan  |
//| jalan sesuai SL/TP aslinya kecuali fitur ini diaktifkan manual)   |
//+------------------------------------------------------------------+
void CheckNewsForceClose()
{
   if(!UseNewsFilter || !CloseBeforeNews) return;
   if(!HasOpenPosition()) return;

   string newsName;
   if(IsNewsBlackout(newsName))
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

         Print("CloseBeforeNews aktif -- menutup posisi #", ticket, " karena: ", newsName);
         trade.PositionClose(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Trailing stop (BARU) -- support 2 mode:                            |
//| - TRAIL_PIPS: jarak start/step trailing dalam poin tetap           |
//| - TRAIL_PERCENT_OF_TARGET: jarak dihitung dari % jarak SL->TP awal |
//|   (targetDistance dibaca live dari POSITION_TP - POSITION_PRICE_OPEN, |
//|   nggak perlu nyimpen state terpisah karena TP EA ini nggak pernah |
//|   diubah setelah entry).                                           |
//| SL cuma di-ratchet ke arah yang menguntungkan (nggak pernah        |
//| dilonggarin balik), dan dijaga tetap respect batas minimum broker. |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(!UseTrailingStop) return;
   if(!HasOpenPosition()) return;

   long stopLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist = MathMax((double)stopLevelPts, 5.0) * _Point * 1.2; // buffer 20% dari batas broker

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL   = PositionGetDouble(POSITION_SL);
      double tp           = PositionGetDouble(POSITION_TP);

      double targetDistance = MathAbs(tp - entryPrice);
      if(targetDistance <= 0) continue; // TP nggak valid, skip (seharusnya tidak terjadi di EA ini)

      double startDistance, stepDistance;
      if(TrailingMode == TRAIL_PIPS)
      {
         startDistance = TrailingStartPips * _Point;
         stepDistance  = TrailingStepPips  * _Point;
      }
      else // TRAIL_PERCENT_OF_TARGET
      {
         startDistance = targetDistance * (TrailingStartPercent / 100.0);
         stepDistance  = targetDistance * (TrailingStepPercent  / 100.0);
      }

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double currentPrice = (type == POSITION_TYPE_BUY) ? bid : ask;

      double profitDistance = (type == POSITION_TYPE_BUY) ? (currentPrice - entryPrice) : (entryPrice - currentPrice);
      if(profitDistance < startDistance) continue; // belum cukup profit buat mulai trailing

      if(type == POSITION_TYPE_BUY)
      {
         double newSL = NormalizeDouble(currentPrice - stepDistance, _Digits);
         // Ratchet: cuma naikin SL (lebih dekat ke harga/lebih menguntungkan), jangan pernah turunin balik.
         // Juga jangan taruh SL lebih dekat dari batas minimum broker ke harga saat ini.
         if((currentSL == 0 || newSL > currentSL) && (currentPrice - newSL) >= minStopDist)
         {
            if(trade.PositionModify(ticket, newSL, tp))
               Print("Trailing SL BUY #", ticket, " -> ", newSL);
         }
      }
      else
      {
         double newSL = NormalizeDouble(currentPrice + stepDistance, _Digits);
         if((currentSL == 0 || newSL < currentSL) && (newSL - currentPrice) >= minStopDist)
         {
            if(trade.PositionModify(ticket, newSL, tp))
               Print("Trailing SL SELL #", ticket, " -> ", newSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Hanya proses logic sekali per candle baru (bukan tiap tick)
   // supaya konsisten dengan basis indikator "candle closed"
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime)
   {
      // Tetap cek time-exit, trailing, & news force-close tiap tick supaya presisi, tapi entry cuma per bar baru
      CheckTimeExit();
      ManageTrailingStop();
      CheckNewsForceClose();
      DB_Update();
      return;
   }
   lastBarTime = currentBarTime;

   CheckTimeExit();
   ManageTrailingStop();
   CheckNewsForceClose();

   // PRINSIP UTAMA: satu posisi per waktu, tidak ada averaging/nambah posisi
   if(!HasOpenPosition())
      CheckEntrySignal();

   DB_Update();
}
//+------------------------------------------------------------------+
