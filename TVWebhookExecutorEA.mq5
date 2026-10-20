#property strict
#property version "1.31"

#include <Trade/Trade.mqh>

input string ServerBaseUrl = "http://127.0.0.1:18080";
input string SecretKey = "test-secret";
input int PollIntervalSeconds = 1;
input int WebRequestTimeoutMs = 5000;
input bool LogSuccessfulWebRequests = false;
input bool LogSignalPipeline = true;
input int MaxSignalAgeSeconds = 60;
input ulong MagicNumber = 26060401;
input int SlippagePoints = 30;
input double FixedRewardRiskRatio = 2.0;
input double MinimumProjectedRealRr = 1.9;
input int MaxEntryDistancePoints = 100;
input int XAUUSD_MaxEntryDistancePoints = -1;
input int MarketTickWaitMilliseconds = 2000;
input bool DemoSafeMode = true;
input double FixedLot = 0.01;
input string SymbolLotLimits = "XAUUSD=0.01,EURJPY=0.15,GBPJPY=0.15,AUDJPY=0.15,CADJPY=0.15,GBPAUD=0.15";
input double MaxEstimatedRiskUsd = 17.15;
input double MaxRiskPercentPerTrade = 3.0;
input double MinimumAllowedVolume = 0.01;
input double MaximumAllowedVolume = 1.00;
input string AllowedSymbols = "XAUUSD,EURJPY,GBPJPY,AUDJPY,CADJPY,GBPAUD";
input int MaxOpenPositionsTotal = 5;
input int MaxOpenPositionsPerSymbol = 1;
input int DailyLossLimitTrades = 3;
input double MaxSpreadForexPoints = 30;
input double MaxSpreadJpyPoints = 30;

input string XAUUSD_Symbol = "XAUUSD";
input double XAUUSD_MaxSpreadPoints = 50;
input double XAUUSD_MaxRiskPercent = 1.0;

input double DefaultMaxSpreadPoints = 50;
input double DefaultMaxRiskPercent = 0.5;
input double DailyLossLimitPercent = 2.0;
input bool SendTradeEventsToServer = true;
input bool MoveToBreakEvenAtOneR = true;
input int BreakEvenOffsetPoints = 0;

CTrade trade;
int current_day_of_year = -1;
double day_start_equity = 0.0;
bool daily_limit_hit = false;

struct Signal
{
   string symbol;
   string side;
   double entry;
   double stop_loss;
   double take_profit;
   double risk_percent;
   double lot;
   string signal_id;
   datetime server_received_time;
   string secret;
};

int OnInit()
{
   PrintFormat("EA_START phase=init_begin version=1.31 symbol=%s period=%s server=%s poll_interval_seconds=%d demo_safe_mode=%s fixed_lot=%s symbol_lot_limits=%s max_estimated_risk_usd=%s max_risk_percent_per_trade=%s allowed_symbols=%s max_positions_total=%d max_positions_per_symbol=%d",
               _Symbol,
               EnumToString((ENUM_TIMEFRAMES)_Period),
               ServerBaseUrl,
               PollIntervalSeconds,
               DemoSafeMode ? "true" : "false",
               DoubleToString(FixedLot, 2),
               SymbolLotLimits,
               DoubleToString(MaxEstimatedRiskUsd, 2),
               DoubleToString(MaxRiskPercentPerTrade, 2),
               AllowedSymbols,
               MaxOpenPositionsTotal,
               MaxOpenPositionsPerSymbol);

   if((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
   {
      Print("POLL_ERROR stage=init reason=v1_1_demo_only_blocked account_is_not_demo");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   ResetDailyStateIfNeeded();
   int timer_seconds = PollIntervalSeconds > 0 ? PollIntervalSeconds : 1;
   if(!EventSetTimer(timer_seconds))
   {
      PrintFormat("POLL_ERROR stage=init reason=event_set_timer_failed last_error=%d", GetLastError());
      return INIT_FAILED;
   }
   PrintFormat("EA_START phase=ready version=1.31 timer_seconds=%d server=%s terminal_trade_allowed=%s mql_trade_allowed=%s account_trade_allowed=%s account_expert_allowed=%s",
               timer_seconds,
               ServerBaseUrl,
               TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ? "true" : "false",
               MQLInfoInteger(MQL_TRADE_ALLOWED) ? "true" : "false",
               AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ? "true" : "false",
               AccountInfoInteger(ACCOUNT_TRADE_EXPERT) ? "true" : "false");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTick()
{
   ResetDailyStateIfNeeded();
   UpdateDailyLossLimit();
   ManageBreakEven();
}

void OnTimer()
{
   PrintFormat("POLL_START server=%s daily_limit_hit=%s", ServerBaseUrl, daily_limit_hit ? "true" : "false");
   ResetDailyStateIfNeeded();
   UpdateDailyLossLimit();
   ManageBreakEven();
   if(daily_limit_hit)
   {
      if(LogSignalPipeline)
         Print("SIGNAL_REJECTED reason=daily_loss_limit_active");
      return;
   }

   Signal signal;
   string raw = "";
   if(!FetchNextSignal(raw))
      return;

   string signal_json = "";
   int extraction_result = ExtractSignalJson(raw, signal_json);
   if(extraction_result == 0)
      return;

   if(extraction_result < 0)
   {
      Print("SIGNAL_REJECTED reason=invalid_signal_wrapper");
      return;
   }

   if(!ParseSignal(signal_json, signal))
   {
      Print("SIGNAL_REJECTED reason=parse_failed");
      LogTrade("REJECT_PARSE", "", "", 0, 0, 0, 0, "Cannot parse signal");
      return;
   }

   PrintFormat("SIGNAL_PARSED signal_id=%s symbol=%s side=%s entry=%s sl=%s tp=%s risk_percent=%s lot=%s",
               signal.signal_id,
               signal.symbol,
               signal.side,
               DoubleToString(signal.entry, 8),
               DoubleToString(signal.stop_loss, 8),
               DoubleToString(signal.take_profit, 8),
               DoubleToString(signal.risk_percent, 4),
               DoubleToString(signal.lot, 4));
   LogTrade("SIGNAL_RECEIVED", signal.signal_id, signal.symbol, signal.entry, signal.stop_loss, signal.take_profit, 0, "Side=" + signal.side);
   PrintFormat("SIGNAL_DISPATCH signal_id=%s symbol=%s forwarding_to=ProcessSignal", signal.signal_id, signal.symbol);
   ProcessSignal(signal);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(!SendTradeEventsToServer || trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal) || (ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != MagicNumber)
      return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   string symbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   double close_result = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
                         HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                         HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   SendTradeEvent("POSITION_CLOSED",
                  symbol,
                  type == DEAL_TYPE_BUY ? "BUY" : "SELL",
                  HistoryDealGetDouble(trans.deal, DEAL_PRICE),
                  0,
                  0,
                  close_result);
}

void ResetDailyStateIfNeeded()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year == current_day_of_year)
      return;

   current_day_of_year = dt.day_of_year;
   day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   daily_limit_hit = false;
}

void UpdateDailyLossLimit()
{
   if(daily_limit_hit)
      return;

   int losing_trades = CountTodayLosingTrades();
   if(DailyLossLimitTrades > 0 && losing_trades >= DailyLossLimitTrades)
   {
      daily_limit_hit = true;
      LogTrade("REJECT_DAILY_LOSS_LIMIT", "", "", 0, 0, 0, 0, "Losing trades today=" + IntegerToString(losing_trades));
      return;
   }

   if(DailyLossLimitPercent <= 0 || day_start_equity <= 0)
      return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double max_loss = day_start_equity * DailyLossLimitPercent / 100.0;
   if(day_start_equity - equity >= max_loss)
   {
      daily_limit_hit = true;
      LogTrade("DAILY_LIMIT_HIT", "", "", 0, 0, 0, 0, "Equity loss reached daily limit");
   }
}

int CountTodayLosingTrades()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime day_start = StructToTime(dt);
   if(!HistorySelect(day_start, TimeCurrent()))
      return 0;

   int losses = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0 || (ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber)
         continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
         continue;
      double result = HistoryDealGetDouble(ticket, DEAL_PROFIT) +
                      HistoryDealGetDouble(ticket, DEAL_SWAP) +
                      HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      if(result < 0)
         losses++;
   }
   return losses;
}

bool FetchNextSignal(string &raw)
{
   string url = ServerBaseUrl + "/next?secret=" + UrlEncode(SecretKey);
   string safe_url = ServerBaseUrl + "/next?secret=***";
   char data[];
   char result[];
   string cookie = NULL;
   string referer = NULL;
   string result_headers = "";
   ArrayResize(data, 0);
   ArrayResize(result, 0);
   ResetLastError();

   PrintFormat("POLL_REQUEST method=GET url=%s timeout_ms=%d", safe_url, WebRequestTimeoutMs);
   int status = WebRequest("GET",
                           url,
                           cookie,
                           referer,
                           WebRequestTimeoutMs,
                           data,
                           0,
                           result,
                           result_headers);
   int last_error = GetLastError();
   raw = CharArrayToString(result, 0, ArraySize(result), CP_UTF8);
   PrintFormat("POLL_RESPONSE method=GET url=%s status=%d last_error=%d",
               safe_url,
               status,
               last_error);

   if(status == -1)
   {
      PrintFormat("POLL_ERROR method=GET url=%s reason=webrequest_failed status=%d last_error=%d",
                  safe_url,
                  status,
                  last_error);
      PrintFormat("WEBREQUEST_ERROR method=GET url=%s status=%d last_error=%d timeout_ms=%d",
                  safe_url,
                  status,
                  last_error,
                  WebRequestTimeoutMs);
      return false;
   }

   if(status != 200)
   {
      PrintFormat("POLL_ERROR method=GET url=%s reason=non_200 status=%d last_error=%d",
                  safe_url,
                  status,
                  last_error);
      PrintFormat("WEBREQUEST_NON_200 method=GET url=%s status=%d last_error=%d timeout_ms=%d",
                  safe_url,
                  status,
                  last_error,
                  WebRequestTimeoutMs);
      return false;
   }

   if(LogSuccessfulWebRequests)
   {
      PrintFormat("WEBREQUEST_OK method=GET url=%s status=%d last_error=%d",
                  safe_url,
                  status,
                  last_error);
   }

   return true;
}

void ProcessSignal(const Signal &signal)
{
   if(signal.secret != SecretKey)
   {
      LogTrade("REJECT_SECRET", signal.signal_id, signal.symbol, 0, signal.stop_loss, signal.take_profit, 0, "Bad secret");
      return;
   }

   string original_status = "";
   string original_reason = "";
   if(LoadSignalOutcome(signal.signal_id, original_status, original_reason))
   {
      LogTrade("DUPLICATE_OUTCOME_REPLAYED", signal.signal_id, signal.symbol, 0, signal.stop_loss, signal.take_profit, 0, original_status);
      SendSignalAck(signal.signal_id, original_status, original_reason);
      return;
   }
   if(IsDuplicateSignal(signal.signal_id))
   {
      // Legacy seen-only rows and interrupted orders have no proven outcome.
      // Keep the execution guard, but do not falsely ACK them as rejected.
      LogTrade("DUPLICATE_OUTCOME_UNKNOWN", signal.signal_id, signal.symbol, 0, signal.stop_loss, signal.take_profit, 0, "Outcome unavailable");
      return;
   }

   int signal_age = (int)(TimeGMT() - signal.server_received_time);
   if(signal_age > MaxSignalAgeSeconds || signal_age < -MaxSignalAgeSeconds)
   {
      LogTrade("REJECT_SIGNAL_TOO_OLD", signal.signal_id, signal.symbol, 0, signal.stop_loss, signal.take_profit, 0, "Invalid signal age seconds=" + IntegerToString(signal_age));
      RememberSignal(signal.signal_id);
      return;
   }

   string requested_symbol = signal.symbol;
   if(!IsAllowedSymbol(requested_symbol))
   {
      LogTrade("REJECT_NOT_ALLOWED_SYMBOL", signal.signal_id, requested_symbol, 0, signal.stop_loss, signal.take_profit, 0, "Symbol is not allowed");
      RememberSignal(signal.signal_id);
      return;
   }

   string symbol = "";
   if(!ResolveBrokerSymbol(requested_symbol, symbol))
   {
      LogTrade("REJECT_SYMBOL_NOT_FOUND", signal.signal_id, requested_symbol, 0, signal.stop_loss, signal.take_profit, 0, "No matching broker symbol found");
      RememberSignal(signal.signal_id);
      return;
   }
   PrintFormat("SYMBOL_MAPPED signal_id=%s requested=%s broker_symbol=%s", signal.signal_id, requested_symbol, symbol);

   int account_positions = PositionsTotal();
   if(MaxOpenPositionsTotal > 0 && account_positions >= MaxOpenPositionsTotal)
   {
      LogTrade("REJECT_MAX_ACCOUNT_POSITIONS", signal.signal_id, symbol, 0, signal.stop_loss, signal.take_profit, 0, "Open account positions=" + IntegerToString(account_positions));
      RememberSignal(signal.signal_id);
      return;
   }

   int symbol_positions = CountOpenPositionsForFamily(SymbolFamily(symbol));
   if(MaxOpenPositionsPerSymbol > 0 && symbol_positions >= MaxOpenPositionsPerSymbol)
   {
      LogTrade("REJECT_MAX_SYMBOL_POSITIONS", signal.signal_id, symbol, 0, signal.stop_loss, signal.take_profit, 0, "Open symbol positions=" + IntegerToString(symbol_positions));
      RememberSignal(signal.signal_id);
      return;
   }

   MqlTick tick;
   if(!ActivateSymbolAndGetTick(symbol, tick))
   {
      int last_error = GetLastError();
      long trade_mode = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
      long selected = SymbolInfoInteger(symbol, SYMBOL_SELECT);
      long visible = SymbolInfoInteger(symbol, SYMBOL_VISIBLE);
      long synchronized = SymbolIsSynchronized(symbol);
      LogTrade("REJECT_SYMBOL",
               signal.signal_id,
               symbol,
               0,
               signal.stop_loss,
               signal.take_profit,
               0,
               StringFormat("No valid market tick last_error=%d selected=%d visible=%d synchronized=%d trade_mode=%d bid=%s ask=%s",
                            last_error,
                            selected,
                            visible,
                            synchronized,
                            trade_mode,
                            DoubleToString(tick.bid, 8),
                            DoubleToString(tick.ask, 8)));
      RememberSignal(signal.signal_id);
      return;
   }
   PrintFormat("MARKET_TICK_OK signal_id=%s symbol=%s bid=%s ask=%s time_msc=%I64d",
               signal.signal_id,
               symbol,
               DoubleToString(tick.bid, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
               DoubleToString(tick.ask, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
               tick.time_msc);

   double ask = tick.ask;
   double bid = tick.bid;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0)
   {
      LogTrade("REJECT_SYMBOL", signal.signal_id, symbol, 0, signal.stop_loss, signal.take_profit, 0, "Invalid symbol point");
      RememberSignal(signal.signal_id);
      return;
   }

   double spread_points = (ask - bid) / point;
   if(spread_points > MaxSpreadForSymbol(requested_symbol))
   {
      LogTrade("REJECT_SPREAD", signal.signal_id, symbol, 0, signal.stop_loss, signal.take_profit, 0, "Spread points=" + DoubleToString(spread_points, 1));
      RememberSignal(signal.signal_id);
      return;
   }

   ENUM_ORDER_TYPE order_type;
   double price;
   string side = ToUpper(signal.side);
   if(side == "BUY")
   {
      order_type = ORDER_TYPE_BUY;
      price = ask;
      if(signal.stop_loss >= price)
      {
         LogTrade("REJECT_SL", signal.signal_id, symbol, price, signal.stop_loss, signal.take_profit, 0, "BUY SL must be below market price");
         RememberSignal(signal.signal_id);
         return;
      }
      if(signal.take_profit <= price)
      {
         LogTrade("REJECT_TP", signal.signal_id, symbol, price, signal.stop_loss, signal.take_profit, 0, "BUY TP must be above market price");
         RememberSignal(signal.signal_id);
         return;
      }
   }
   else if(side == "SELL")
   {
      order_type = ORDER_TYPE_SELL;
      price = bid;
      if(signal.stop_loss <= price)
      {
         LogTrade("REJECT_SL", signal.signal_id, symbol, price, signal.stop_loss, signal.take_profit, 0, "SELL SL must be above market price");
         RememberSignal(signal.signal_id);
         return;
      }
      if(signal.take_profit >= price)
      {
         LogTrade("REJECT_TP", signal.signal_id, symbol, price, signal.stop_loss, signal.take_profit, 0, "SELL TP must be below market price");
         RememberSignal(signal.signal_id);
         return;
      }
   }
   else
   {
      LogTrade("REJECT_SIDE", signal.signal_id, symbol, 0, signal.stop_loss, signal.take_profit, 0, "Side must be BUY or SELL");
      RememberSignal(signal.signal_id);
      return;
   }

   long stops_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minimum_stop_distance = stops_level * point;
   if(minimum_stop_distance > 0 &&
      (MathAbs(price - signal.stop_loss) < minimum_stop_distance ||
       MathAbs(signal.take_profit - price) < minimum_stop_distance))
   {
      LogTrade("REJECT_STOPS",
               signal.signal_id,
               symbol,
               price,
               signal.stop_loss,
               signal.take_profit,
               0,
               StringFormat("SL or TP below broker minimum stops_level=%d points", stops_level));
      RememberSignal(signal.signal_id);
      return;
   }

   double projected_rr = CalculateRealRewardRisk(order_type, price, signal.stop_loss, signal.take_profit);
   if(MinimumProjectedRealRr > 0 && projected_rr < MinimumProjectedRealRr)
   {
      LogTrade("REJECT_PROJECTED_RR",
               signal.signal_id,
               symbol,
               price,
               signal.stop_loss,
               signal.take_profit,
               0,
               StringFormat("projected_rr=%s minimum_projected_rr=%s planned_entry=%s market_price=%s",
                            DoubleToString(projected_rr, 4),
                            DoubleToString(MinimumProjectedRealRr, 4),
                            DoubleToString(signal.entry, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                            DoubleToString(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS))));
      RememberSignal(signal.signal_id);
      return;
   }

   int entry_distance_limit = MaxEntryDistancePoints;
   if(symbol == XAUUSD_Symbol && XAUUSD_MaxEntryDistancePoints >= 0)
      entry_distance_limit = XAUUSD_MaxEntryDistancePoints;

   double entry_distance_price_diff = MathAbs(price - signal.entry);
   double entry_distance_points = entry_distance_price_diff / point;
   if(signal.entry > 0 && entry_distance_limit >= 0 && entry_distance_points > entry_distance_limit)
   {
      LogTrade("REJECT_ENTRY_DISTANCE",
               signal.signal_id,
               symbol,
               price,
               signal.stop_loss,
               signal.take_profit,
               0,
               StringFormat("Entry=%s entry_distance_points=%.1f entry_distance_limit=%d entry_distance_price_diff=%s",
                            DoubleToString(signal.entry, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                            entry_distance_points,
                            entry_distance_limit,
                            DoubleToString(entry_distance_price_diff, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS))));
      RememberSignal(signal.signal_id);
      return;
   }

   double broker_min = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double broker_max = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double effective_min = MathMax(broker_min, MinimumAllowedVolume);
   double effective_max = MathMin(broker_max, MaximumAllowedVolume);
   double configured_max = ConfiguredLotLimit(requested_symbol);
   double lot_requested = signal.lot;
   if(configured_max <= 0)
   {
      LogTrade("REJECT_VOLUME_CONFIG", signal.signal_id, symbol, price, signal.stop_loss, signal.take_profit, 0, "No lot limit configured for symbol");
      RememberSignal(signal.signal_id);
      return;
   }
   if(lot_requested <= 0 || lot_requested > configured_max + 0.00000001)
   {
      LogTrade("REJECT_VOLUME_LIMIT",
               signal.signal_id,
               symbol,
               price,
               signal.stop_loss,
               signal.take_profit,
               0,
               StringFormat("lot_requested=%s configured_max=%s",
                            DoubleToString(lot_requested, 4),
                            DoubleToString(configured_max, 4)));
      RememberSignal(signal.signal_id);
      return;
   }

   effective_max = MathMin(effective_max, configured_max);
   double volume = step > 0 ? NormalizeVolume(symbol, lot_requested) : 0.0;
   if(MathAbs(volume - lot_requested) > 0.00000001)
      volume = 0.0;
   if(volume < effective_min || volume > effective_max + 0.00000001)
      volume = 0.0;

   if(volume <= 0)
   {
      LogTrade("REJECT_VOLUME",
               signal.signal_id,
               symbol,
               price,
               signal.stop_loss,
               signal.take_profit,
               0,
               StringFormat("Invalid requested lot=%s configured_max=%s broker_min=%s broker_max=%s step=%s",
                            DoubleToString(lot_requested, 4),
                            DoubleToString(configured_max, 4),
                            DoubleToString(broker_min, 4),
                            DoubleToString(broker_max, 4),
                            DoubleToString(step, 4)));
      RememberSignal(signal.signal_id);
      return;
   }

   double estimated_loss = 0.0;
   double estimated_reward = 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   bool risk_calculated = OrderCalcProfit(order_type, symbol, volume, price, signal.stop_loss, estimated_loss);
   bool reward_calculated = OrderCalcProfit(order_type, symbol, volume, price, signal.take_profit, estimated_reward);
   double estimated_risk_account = MathAbs(estimated_loss);
   double estimated_reward_account = MathAbs(estimated_reward);
   double estimated_risk_usd = 0.0;
   double estimated_reward_usd = 0.0;
   bool risk_usd_calculated = ConvertAccountAmountToUsd(estimated_risk_account, true, estimated_risk_usd);
   bool reward_usd_calculated = ConvertAccountAmountToUsd(estimated_reward_account, false, estimated_reward_usd);
   double risk_percent = equity > 0 ? estimated_risk_account / equity * 100.0 : 0.0;
   string account_currency = AccountInfoString(ACCOUNT_CURRENCY);
   string sizing_message = StringFormat("symbol=%s lot_requested=%s lot_final=%s entry=%s sl=%s tp=%s estimated_risk_usd=%s estimated_reward_usd=%s risk_percent=%s max_estimated_risk_usd=%s max_risk_percent=%s account_currency=%s",
                                        requested_symbol,
                                        DoubleToString(lot_requested, 4),
                                        DoubleToString(volume, 4),
                                        DoubleToString(price, 8),
                                        DoubleToString(signal.stop_loss, 8),
                                        DoubleToString(signal.take_profit, 8),
                                        DoubleToString(estimated_risk_usd, 2),
                                        DoubleToString(estimated_reward_usd, 2),
                                        DoubleToString(risk_percent, 4),
                                        DoubleToString(MaxEstimatedRiskUsd, 2),
                                        DoubleToString(MaxRiskPercentPerTrade, 2),
                                        account_currency);
   if(!risk_calculated || !reward_calculated || !risk_usd_calculated || !reward_usd_calculated || equity <= 0)
   {
      Print("SIZING_DECISION ", sizing_message, " decision=rejected reason=REJECT_RISK_CALC");
      LogTrade("REJECT_RISK_CALC", signal.signal_id, symbol, price, signal.stop_loss, signal.take_profit, volume, sizing_message);
      RememberSignal(signal.signal_id);
      return;
   }
   if(MaxEstimatedRiskUsd <= 0 ||
      MaxRiskPercentPerTrade <= 0 ||
      estimated_risk_usd > MaxEstimatedRiskUsd + 0.00000001 ||
      risk_percent > MaxRiskPercentPerTrade + 0.00000001)
   {
      Print("SIZING_DECISION ", sizing_message, " decision=rejected reason=REJECT_RISK_LIMIT");
      LogTrade("REJECT_RISK_LIMIT", signal.signal_id, symbol, price, signal.stop_loss, signal.take_profit, volume, sizing_message);
      RememberSignal(signal.signal_id);
      return;
   }
   Print("SIZING_DECISION ", sizing_message, " decision=accepted");

   if(!TradingIsAllowedForSymbol(symbol, order_type, signal))
   {
      RememberSignal(signal.signal_id);
      return;
   }

   if(!trade.SetTypeFillingBySymbol(symbol))
   {
      LogTrade("REJECT_TRADE", signal.signal_id, symbol, price, signal.stop_loss, signal.take_profit, volume, "Cannot set filling mode");
      RememberSignal(signal.signal_id);
      return;
   }

   if(!RememberSignal(signal.signal_id))
   {
      PrintFormat("SIGNAL_DEFERRED signal_id=%s reason=seen_persistence_failed", signal.signal_id);
      return;
   }
   PrintFormat("SIGNAL_ACCEPTED signal_id=%s requested_symbol=%s broker_symbol=%s spread_points=%s account_positions=%d symbol_positions=%d",
               signal.signal_id,
               requested_symbol,
               symbol,
               DoubleToString(spread_points, 1),
               account_positions,
               symbol_positions);
   ExecuteTrade(signal, symbol, order_type, price, volume);
}

bool ConvertAccountAmountToUsd(double amount, bool conservative, double &amount_usd)
{
   amount_usd = 0.0;
   string currency = ToUpper(AccountInfoString(ACCOUNT_CURRENCY));

   if(currency == "USD")
   {
      amount_usd = amount;
      return true;
   }

   if(currency != "EUR")
      return false;

   string conversion_symbol = "";
   if(!ResolveBrokerSymbol("EURUSD", conversion_symbol))
      return false;

   MqlTick tick;
   if(!ActivateSymbolAndGetTick(conversion_symbol, tick))
      return false;

   double rate = conservative ? tick.ask : tick.bid;
   if(rate <= 0)
      return false;

   amount_usd = amount * rate;
   return true;
}

string SymbolFamily(string symbol)
{
   string upper = ToUpper(symbol);
   if(StringFind(upper, "XAUUSD") >= 0 || StringFind(upper, "GOLD") >= 0)
      return "XAUUSD";
   string forex[] = {"EURUSD","GBPUSD","USDJPY","USDCHF","AUDUSD","USDCAD","EURJPY","GBPJPY","AUDJPY","CADJPY","GBPAUD"};
   for(int i = 0; i < ArraySize(forex); i++)
   {
      if(upper == forex[i] || StringFind(upper, forex[i] + ".") == 0 || upper == forex[i] + "M")
         return forex[i];
   }
   return "";
}

double ConfiguredLotLimit(string symbol)
{
   string family = SymbolFamily(symbol);
   if(family == "")
      return 0.0;

   string entries[];
   int count = StringSplit(SymbolLotLimits, ',', entries);
   for(int i = 0; i < count; i++)
   {
      string entry = entries[i];
      int separator = StringFind(entry, "=");
      if(separator <= 0)
         continue;
      string key = StringSubstr(entry, 0, separator);
      string value = StringSubstr(entry, separator + 1);
      StringTrimLeft(key);
      StringTrimRight(key);
      StringTrimLeft(value);
      StringTrimRight(value);
      if(ToUpper(key) == family)
         return StringToDouble(value);
   }
   return 0.0;
}

int SymbolCandidateScore(string candidate, string requested_symbol, string family)
{
   string upper = ToUpper(candidate);
   string requested_upper = ToUpper(requested_symbol);
   if(upper == requested_upper)
      return 1100;
   if(upper == family + ".RAW")
      return 1000;
   if(upper == family)
      return 950;
   if(upper == family + "M")
      return 900;
   if(family == "XAUUSD" && upper == "GOLD")
      return 925;
   if(StringFind(upper, family) == 0)
      return 850;
   if(family == "XAUUSD" && StringFind(upper, "GOLD") == 0)
      return 825;
   if(StringFind(upper, family) >= 0)
      return 700;
   if(family == "XAUUSD" && StringFind(upper, "GOLD") >= 0)
      return 675;
   return -1;
}

bool ResolveBrokerSymbol(string requested_symbol, string &resolved_symbol)
{
   resolved_symbol = "";
   string family = SymbolFamily(requested_symbol);
   if(family == "")
      return false;

   int best_score = -1;
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
   {
      string candidate = SymbolName(i, false);
      int score = SymbolCandidateScore(candidate, requested_symbol, family);
      if(candidate == _Symbol && SymbolFamily(_Symbol) == family)
         score += 100;
      if(score > best_score)
      {
         best_score = score;
         resolved_symbol = candidate;
      }
   }
   return resolved_symbol != "";
}

int CountOpenPositionsForFamily(string family)
{
   if(family == "")
      return 0;

   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(SymbolFamily(PositionGetString(POSITION_SYMBOL)) == family)
         count++;
   }
   return count;
}

bool ActivateSymbolAndGetTick(string symbol, MqlTick &tick)
{
   ZeroMemory(tick);
   ResetLastError();
   bool selected = SymbolSelect(symbol, true);
   int select_error = GetLastError();
   PrintFormat("SYMBOL_SELECTED symbol=%s success=%s last_error=%d selected=%d visible=%d synchronized=%s",
               symbol,
               selected ? "true" : "false",
               select_error,
               SymbolInfoInteger(symbol, SYMBOL_SELECT),
               SymbolInfoInteger(symbol, SYMBOL_VISIBLE),
               SymbolIsSynchronized(symbol) ? "true" : "false");
   if(!selected)
      return false;

   uint started = GetTickCount();
   int wait_ms = MathMax(MarketTickWaitMilliseconds, 0);
   do
   {
      ResetLastError();
      if(SymbolInfoTick(symbol, tick) && tick.bid > 0 && tick.ask > 0)
         return true;
      if((int)(GetTickCount() - started) >= wait_ms)
         break;
      Sleep(100);
   }
   while(!IsStopped());

   PrintFormat("MARKET_TICK_FAILED symbol=%s last_error=%d bid=%s ask=%s last=%s time_msc=%I64d selected=%d synchronized=%s",
               symbol,
               GetLastError(),
               DoubleToString(tick.bid, 8),
               DoubleToString(tick.ask, 8),
               DoubleToString(tick.last, 8),
               tick.time_msc,
               SymbolInfoInteger(symbol, SYMBOL_SELECT),
               SymbolIsSynchronized(symbol) ? "true" : "false");
   return false;
}

bool TradingIsAllowedForSymbol(string symbol, ENUM_ORDER_TYPE order_type, const Signal &signal)
{
   string reason = "";
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      reason = "terminal_algo_trading_disabled";
   else if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      reason = "ea_live_trading_disabled";
   else if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      reason = "account_trade_disabled";
   else if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      reason = "account_expert_trading_disabled";

   ENUM_SYMBOL_TRADE_MODE trade_mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(reason == "" && trade_mode == SYMBOL_TRADE_MODE_DISABLED)
      reason = "symbol_trade_disabled";
   else if(reason == "" && trade_mode == SYMBOL_TRADE_MODE_CLOSEONLY)
      reason = "symbol_close_only";
   else if(reason == "" && order_type == ORDER_TYPE_BUY && trade_mode == SYMBOL_TRADE_MODE_SHORTONLY)
      reason = "symbol_short_only";
   else if(reason == "" && order_type == ORDER_TYPE_SELL && trade_mode == SYMBOL_TRADE_MODE_LONGONLY)
      reason = "symbol_long_only";

   if(reason == "")
      return true;

   PrintFormat("ORDER_FAILED signal_id=%s symbol=%s reason=%s trade_mode=%d terminal_trade_allowed=%d mql_trade_allowed=%d account_trade_allowed=%d account_expert_allowed=%d",
               signal.signal_id,
               symbol,
               reason,
               trade_mode,
               TerminalInfoInteger(TERMINAL_TRADE_ALLOWED),
               MQLInfoInteger(MQL_TRADE_ALLOWED),
               AccountInfoInteger(ACCOUNT_TRADE_ALLOWED),
               AccountInfoInteger(ACCOUNT_TRADE_EXPERT));
   LogTrade("REJECT_TRADE", signal.signal_id, symbol, 0, signal.stop_loss, signal.take_profit, 0, reason);
   return false;
}

bool ExecuteTrade(const Signal &signal, string symbol, ENUM_ORDER_TYPE order_type, double price, double volume)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   PrintFormat("ORDER_REQUEST signal_id=%s symbol=%s side=%s volume=%s market_price=%s sl=%s tp=%s",
               signal.signal_id,
               symbol,
               signal.side,
               DoubleToString(volume, 4),
               DoubleToString(price, digits),
               DoubleToString(signal.stop_loss, digits),
               DoubleToString(signal.take_profit, digits));

   string trade_comment = StringSubstr(signal.signal_id, 0, 31);
   ResetLastError();
   bool sent = order_type == ORDER_TYPE_BUY
               ? trade.Buy(volume, symbol, 0, signal.stop_loss, signal.take_profit, trade_comment)
               : trade.Sell(volume, symbol, 0, signal.stop_loss, signal.take_profit, trade_comment);
   int last_error = GetLastError();
   uint retcode = trade.ResultRetcode();
   bool accepted = sent && (retcode == TRADE_RETCODE_DONE ||
                            retcode == TRADE_RETCODE_DONE_PARTIAL ||
                            retcode == TRADE_RETCODE_PLACED);

   if(!accepted)
   {
      PrintFormat("ORDER_FAILED signal_id=%s symbol=%s sent=%s last_error=%d retcode=%d description=%s broker_comment=%s",
                  signal.signal_id,
                  symbol,
                  sent ? "true" : "false",
                  last_error,
                  retcode,
                  trade.ResultRetcodeDescription(),
                  trade.ResultComment());
      LogTrade("REJECT_TRADE",
               signal.signal_id,
               symbol,
               price,
               signal.stop_loss,
               signal.take_profit,
               volume,
               StringFormat("last_error=%d retcode=%d %s broker_comment=%s",
                            last_error,
                            retcode,
                            trade.ResultRetcodeDescription(),
                            trade.ResultComment()));
      LogTrade("ORDER_FAILED",
               signal.signal_id,
               symbol,
               price,
               signal.stop_loss,
               signal.take_profit,
               volume,
               StringFormat("last_error=%d retcode=%d", last_error, retcode));
      return false;
   }

   if(!RememberSignalOutcome(signal.signal_id, "executed", "order_accepted"))
      PrintFormat("OUTCOME_PERSIST_FAILED signal_id=%s status=executed", signal.signal_id);
   PrintFormat("ORDER_SENT signal_id=%s symbol=%s retcode=%d order=%I64u deal=%I64u broker_comment=%s",
               signal.signal_id,
               symbol,
               retcode,
               trade.ResultOrder(),
               trade.ResultDeal(),
               trade.ResultComment());
   LogTrade("ORDER_SENT",
            signal.signal_id,
            symbol,
            price,
            signal.stop_loss,
            signal.take_profit,
            volume,
            "Order accepted by broker");
      LogTrade("OPENED",
            signal.signal_id,
            symbol,
            price,
            signal.stop_loss,
            signal.take_profit,
            volume,
            "Order=" + IntegerToString((long)trade.ResultOrder()) + " Deal=" + IntegerToString((long)trade.ResultDeal()));

   if(PositionSelect(symbol))
   {
      RepairTpToFixedRr(signal, symbol, order_type);
      PrintFormat("POSITION_OPENED signal_id=%s symbol=%s ticket=%I64u volume=%s open_price=%s sl=%s tp=%s",
                  signal.signal_id,
                  symbol,
                  PositionGetInteger(POSITION_TICKET),
                  DoubleToString(PositionGetDouble(POSITION_VOLUME), 4),
                  DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), digits),
                  DoubleToString(PositionGetDouble(POSITION_SL), digits),
                  DoubleToString(PositionGetDouble(POSITION_TP), digits));
      SendTradeEvent("POSITION_OPENED",
                     symbol,
                     signal.side,
                     PositionGetDouble(POSITION_PRICE_OPEN),
                     PositionGetDouble(POSITION_SL),
                     PositionGetDouble(POSITION_TP),
                     0);
   }
   else
   {
      PrintFormat("ORDER_SENT signal_id=%s symbol=%s position_not_yet_visible=true", signal.signal_id, symbol);
      LogTrade("TP_RR_REPAIR_SKIPPED",
               signal.signal_id,
               symbol,
               price,
               signal.stop_loss,
               signal.take_profit,
               volume,
               "position_not_found_after_order_acceptance");
   }
   SendSignalAck(signal.signal_id, "executed", "order_accepted");
   return true;
}

double SymbolPriceTickSize(string symbol)
{
   double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0)
      tick_size = SymbolInfoDouble(symbol, SYMBOL_POINT);
   return tick_size;
}

double NormalizePriceForSymbol(string symbol, double price_value)
{
   return NormalizeDouble(price_value, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
}

double RoundTpToExecutableTick(string symbol, ENUM_ORDER_TYPE order_type, double raw_tp)
{
   double tick_size = SymbolPriceTickSize(symbol);
   if(tick_size <= 0)
      return NormalizePriceForSymbol(symbol, raw_tp);

   double ticks = raw_tp / tick_size;
   double rounded = order_type == ORDER_TYPE_BUY
                    ? MathCeil(ticks - 0.00000001) * tick_size
                    : MathFloor(ticks + 0.00000001) * tick_size;
   return NormalizePriceForSymbol(symbol, rounded);
}

double CalculateRealRewardRisk(ENUM_ORDER_TYPE order_type, double open_price, double sl, double tp)
{
   double risk = 0.0;
   double reward = 0.0;
   if(order_type == ORDER_TYPE_BUY)
   {
      risk = open_price - sl;
      reward = tp - open_price;
   }
   else if(order_type == ORDER_TYPE_SELL)
   {
      risk = sl - open_price;
      reward = open_price - tp;
   }

   if(risk <= 0 || reward <= 0)
      return -1.0;
   return reward / risk;
}

bool TpRespectsBrokerDistance(string symbol, ENUM_ORDER_TYPE order_type, double tp, string &reason)
{
   reason = "";
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0)
   {
      reason = "invalid_symbol_point";
      return false;
   }

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick) || tick.bid <= 0 || tick.ask <= 0)
   {
      reason = "no_valid_market_tick";
      return false;
   }

   long stops_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minimum_distance = MathMax(stops_level, freeze_level) * point;
   if(minimum_distance <= 0)
      return true;

   double actual_distance = order_type == ORDER_TYPE_BUY ? tp - tick.bid : tick.ask - tp;
   if(actual_distance + 0.00000001 < minimum_distance)
   {
      reason = StringFormat("tp_below_broker_distance stops_level=%d freeze_level=%d minimum_distance=%s actual_distance=%s bid=%s ask=%s",
                            stops_level,
                            freeze_level,
                            DoubleToString(minimum_distance, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                            DoubleToString(actual_distance, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                            DoubleToString(tick.bid, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                            DoubleToString(tick.ask, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)));
      return false;
   }

   return true;
}

double CalculateFixedRrTp(string symbol, ENUM_ORDER_TYPE order_type, double open_price, double sl)
{
   double risk = 0.0;
   double raw_tp = 0.0;
   if(order_type == ORDER_TYPE_BUY)
   {
      risk = open_price - sl;
      raw_tp = open_price + FixedRewardRiskRatio * risk;
   }
   else if(order_type == ORDER_TYPE_SELL)
   {
      risk = sl - open_price;
      raw_tp = open_price - FixedRewardRiskRatio * risk;
   }

   if(risk <= 0 || FixedRewardRiskRatio <= 0)
      return 0.0;
   return RoundTpToExecutableTick(symbol, order_type, raw_tp);
}

bool RepairTpToFixedRr(const Signal &signal, string symbol, ENUM_ORDER_TYPE order_type)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(!PositionSelect(symbol))
   {
      PrintFormat("TP_RR_REPAIR_SKIPPED signal_id=%s symbol=%s reason=position_not_found", signal.signal_id, symbol);
      LogTrade("TP_RR_REPAIR_SKIPPED", signal.signal_id, symbol, signal.entry, signal.stop_loss, signal.take_profit, 0, "position_not_found");
      return false;
   }

   ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   double actual_open = PositionGetDouble(POSITION_PRICE_OPEN);
   double current_sl = PositionGetDouble(POSITION_SL);
   double current_tp = PositionGetDouble(POSITION_TP);
   double old_rr = CalculateRealRewardRisk(order_type, actual_open, current_sl, current_tp);
   double new_tp = CalculateFixedRrTp(symbol, order_type, actual_open, current_sl);
   double new_rr = CalculateRealRewardRisk(order_type, actual_open, current_sl, new_tp);

   PrintFormat("TP_RR_REPAIR_CHECK signal_id=%s symbol=%s side=%s ticket=%I64u planned_entry=%s actual_open=%s sl=%s old_tp=%s new_tp=%s old_real_rr=%s new_real_rr=%s fixed_rr=%s",
               signal.signal_id,
               symbol,
               signal.side,
               ticket,
               DoubleToString(signal.entry, digits),
               DoubleToString(actual_open, digits),
               DoubleToString(current_sl, digits),
               DoubleToString(current_tp, digits),
               DoubleToString(new_tp, digits),
               DoubleToString(old_rr, 4),
               DoubleToString(new_rr, 4),
               DoubleToString(FixedRewardRiskRatio, 4));

   LogTrade("TP_RR_REPAIR_CHECK",
            signal.signal_id,
            symbol,
            actual_open,
            current_sl,
            current_tp,
            PositionGetDouble(POSITION_VOLUME),
            StringFormat("planned_entry=%s old_tp=%s new_tp=%s old_real_rr=%s new_real_rr=%s",
                         DoubleToString(signal.entry, digits),
                         DoubleToString(current_tp, digits),
                         DoubleToString(new_tp, digits),
                         DoubleToString(old_rr, 4),
                         DoubleToString(new_rr, 4)));

   if(new_tp <= 0 || new_rr + 0.00000001 < FixedRewardRiskRatio)
   {
      string invalid_reason = StringFormat("invalid_repaired_tp new_tp=%s new_real_rr=%s fixed_rr=%s",
                                           DoubleToString(new_tp, digits),
                                           DoubleToString(new_rr, 4),
                                           DoubleToString(FixedRewardRiskRatio, 4));
      PrintFormat("TP_RR_REPAIR_FAILED signal_id=%s symbol=%s reason=%s", signal.signal_id, symbol, invalid_reason);
      LogTrade("TP_RR_REPAIR_FAILED", signal.signal_id, symbol, actual_open, current_sl, current_tp, PositionGetDouble(POSITION_VOLUME), invalid_reason);
      return false;
   }

   string broker_reason = "";
   if(!TpRespectsBrokerDistance(symbol, order_type, new_tp, broker_reason))
   {
      PrintFormat("TP_RR_REPAIR_FAILED signal_id=%s symbol=%s reason=%s", signal.signal_id, symbol, broker_reason);
      LogTrade("TP_RR_REPAIR_FAILED", signal.signal_id, symbol, actual_open, current_sl, current_tp, PositionGetDouble(POSITION_VOLUME), broker_reason);
      return false;
   }

   double tick_size = SymbolPriceTickSize(symbol);
   double epsilon = tick_size > 0 ? tick_size / 2.0 : SymbolInfoDouble(symbol, SYMBOL_POINT) / 2.0;
   if(MathAbs(current_tp - new_tp) <= epsilon)
   {
      string skip_reason = StringFormat("tp_already_fixed old_tp=%s new_tp=%s real_rr=%s",
                                        DoubleToString(current_tp, digits),
                                        DoubleToString(new_tp, digits),
                                        DoubleToString(old_rr, 4));
      PrintFormat("TP_RR_REPAIR_SKIPPED signal_id=%s symbol=%s reason=%s", signal.signal_id, symbol, skip_reason);
      LogTrade("TP_RR_REPAIR_SKIPPED", signal.signal_id, symbol, actual_open, current_sl, current_tp, PositionGetDouble(POSITION_VOLUME), skip_reason);
      return true;
   }

   ResetLastError();
   bool modified = trade.PositionModify(ticket, current_sl, new_tp);
   int last_error = GetLastError();
   uint retcode = trade.ResultRetcode();
   if(!modified || retcode != TRADE_RETCODE_DONE)
   {
      string failed_reason = StringFormat("position_modify_failed last_error=%d retcode=%d description=%s broker_comment=%s old_tp=%s new_tp=%s",
                                          last_error,
                                          retcode,
                                          trade.ResultRetcodeDescription(),
                                          trade.ResultComment(),
                                          DoubleToString(current_tp, digits),
                                          DoubleToString(new_tp, digits));
      PrintFormat("TP_RR_REPAIR_FAILED signal_id=%s symbol=%s reason=%s", signal.signal_id, symbol, failed_reason);
      LogTrade("TP_RR_REPAIR_FAILED", signal.signal_id, symbol, actual_open, current_sl, current_tp, PositionGetDouble(POSITION_VOLUME), failed_reason);
      return false;
   }

   double final_tp = new_tp;
   double final_volume = PositionGetDouble(POSITION_VOLUME);
   if(PositionSelect(symbol))
   {
      final_tp = PositionGetDouble(POSITION_TP);
      final_volume = PositionGetDouble(POSITION_VOLUME);
   }
   double final_rr = CalculateRealRewardRisk(order_type, actual_open, current_sl, final_tp);
   string success_message = StringFormat("planned_entry=%s actual_open=%s sl_unchanged=%s old_tp=%s new_tp=%s old_real_rr=%s new_real_rr=%s retcode=%d broker_comment=%s",
                                         DoubleToString(signal.entry, digits),
                                         DoubleToString(actual_open, digits),
                                         DoubleToString(current_sl, digits),
                                         DoubleToString(current_tp, digits),
                                         DoubleToString(final_tp, digits),
                                         DoubleToString(old_rr, 4),
                                         DoubleToString(final_rr, 4),
                                         retcode,
                                         trade.ResultComment());
   PrintFormat("TP_RR_REPAIR_MODIFIED signal_id=%s symbol=%s %s", signal.signal_id, symbol, success_message);
   LogTrade("TP_RR_REPAIR_MODIFIED", signal.signal_id, symbol, actual_open, current_sl, final_tp, final_volume, success_message);
   return true;
}

bool SendTradeEvent(string event_name, string symbol, string side, double price, double sl, double tp, double result_value)
{
   if(!SendTradeEventsToServer)
      return false;

   string url = ServerBaseUrl + "/trade-event";
   string body = StringFormat("{\"secret\":\"%s\",\"event\":\"%s\",\"symbol\":\"%s\",\"side\":\"%s\",\"price\":%s,\"sl\":%s,\"tp\":%s,\"result\":%s}",
                              SecretKey,
                              event_name,
                              symbol,
                              side,
                              DoubleToString(price, 8),
                              DoubleToString(sl, 8),
                              DoubleToString(tp, 8),
                              DoubleToString(result_value, 2));
   char data[];
   char response[];
   string response_headers = "";
   StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(ArraySize(data) > 0)
      ArrayResize(data, ArraySize(data) - 1);
   ResetLastError();
   int status = WebRequest("POST",
                           url,
                           "Content-Type: application/json\r\n",
                           WebRequestTimeoutMs,
                           data,
                           response,
                           response_headers);
   if(status != 200)
   {
      PrintFormat("TRADE_EVENT_FAILED event=%s symbol=%s status=%d last_error=%d",
                  event_name,
                  symbol,
                  status,
                  GetLastError());
      return false;
   }
   PrintFormat("TRADE_EVENT_SENT event=%s symbol=%s", event_name, symbol);
   return true;
}

bool SendSignalAck(string signal_id, string status_name, string reason)
{
   if(signal_id == "")
      return false;

   string stored_status = "";
   string stored_reason = "";
   if(LoadSignalOutcome(signal_id, stored_status, stored_reason))
   {
      if(stored_status != status_name)
      {
         PrintFormat("SIGNAL_ACK_CONFLICT signal_id=%s stored=%s requested=%s", signal_id, stored_status, status_name);
         return false;
      }
      reason = stored_reason;
   }
   else if(!RememberSignalOutcome(signal_id, status_name, reason))
      PrintFormat("OUTCOME_PERSIST_FAILED signal_id=%s status=%s", signal_id, status_name);

   string url = ServerBaseUrl + "/ack";
   string safe_signal_id = JsonEscapeText(signal_id);
   string safe_status = JsonEscapeText(status_name);
   string safe_reason = JsonEscapeText(reason);
   string body = StringFormat("{\"secret\":\"%s\",\"signal_id\":\"%s\",\"status\":\"%s\",\"reason\":\"%s\"}",
                              SecretKey,
                              safe_signal_id,
                              safe_status,
                              safe_reason);
   char data[];
   char response[];
   string response_headers = "";
   StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(ArraySize(data) > 0)
      ArrayResize(data, ArraySize(data) - 1);
   ResetLastError();
   int http_status = WebRequest("POST",
                                url,
                                "Content-Type: application/json\r\n",
                                WebRequestTimeoutMs,
                                data,
                                response,
                                response_headers);
   if(http_status != 200)
   {
      PrintFormat("SIGNAL_ACK_FAILED signal_id=%s status=%s http_status=%d last_error=%d",
                  signal_id,
                  status_name,
                  http_status,
                  GetLastError());
      return false;
   }
   PrintFormat("SIGNAL_ACK_SENT signal_id=%s status=%s reason=%s",
               signal_id,
               status_name,
               reason);
   return true;
}

string JsonEscapeText(string value)
{
   string out = value;
   StringReplace(out, "\\", "\\\\");
   StringReplace(out, "\"", "\\\"");
   StringReplace(out, "\r", "\\r");
   StringReplace(out, "\n", "\\n");
   StringReplace(out, "\t", "\\t");
   return out;
}

double NormalizeVolume(string symbol, double volume)
{
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   int digits = 0;
   double s = step;
   while(s < 1.0 && digits < 8)
   {
      s *= 10.0;
      digits++;
   }
   return NormalizeDouble(volume, digits);
}

void ManageBreakEven()
{
   if(!MoveToBreakEvenAtOneR)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long type = PositionGetInteger(POSITION_TYPE);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

      if(sl <= 0 || point <= 0)
         continue;

      double one_r = MathAbs(open_price - sl);
      if(one_r <= 0)
         continue;

      if(type == POSITION_TYPE_BUY)
      {
         double be_sl = open_price + BreakEvenOffsetPoints * point;
         if(bid >= open_price + one_r && sl < be_sl)
         {
            if(trade.PositionModify(ticket, be_sl, tp) && trade.ResultRetcode() == TRADE_RETCODE_DONE)
               LogTrade("BE_MOVED", "", symbol, open_price, be_sl, tp, PositionGetDouble(POSITION_VOLUME), "BUY break even");
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double be_sl = open_price - BreakEvenOffsetPoints * point;
         if(ask <= open_price - one_r && (sl > be_sl || sl == 0))
         {
            if(trade.PositionModify(ticket, be_sl, tp) && trade.ResultRetcode() == TRADE_RETCODE_DONE)
               LogTrade("BE_MOVED", "", symbol, open_price, be_sl, tp, PositionGetDouble(POSITION_VOLUME), "SELL break even");
         }
      }
   }
}

double MaxSpreadForSymbol(string symbol)
{
   string family = SymbolFamily(symbol);
   if(family == "XAUUSD")
      return XAUUSD_MaxSpreadPoints;
   if(family == "USDJPY" || family == "EURJPY" || family == "GBPJPY" ||
      family == "AUDJPY" || family == "CADJPY")
      return MaxSpreadJpyPoints;
   if(family == "EURUSD" || family == "GBPUSD" || family == "USDCHF" ||
      family == "AUDUSD" || family == "USDCAD" || family == "GBPAUD")
      return MaxSpreadForexPoints;
   return DefaultMaxSpreadPoints;
}

bool IsAllowedSymbol(string symbol)
{
   string family = SymbolFamily(symbol);
   if(family == "")
      return false;

   string allowed[];
   ushort separator = StringGetCharacter(",", 0);
   int count = StringSplit(AllowedSymbols, separator, allowed);
   for(int i = 0; i < count; i++)
   {
      if(SymbolFamily(allowed[i]) == family)
         return true;
   }
   return false;
}

double MaxRiskForSymbol(string symbol)
{
   string family = SymbolFamily(symbol);
   if(family == "XAUUSD")
      return XAUUSD_MaxRiskPercent;
   return DefaultMaxRiskPercent;
}

int ExtractSignalJson(string raw, string &signal_json)
{
   signal_json = "";
   string pattern = "\"signal\"";
   int key_pos = StringFind(raw, pattern);
   if(key_pos < 0)
      return -1;

   int colon_pos = StringFind(raw, ":", key_pos + StringLen(pattern));
   if(colon_pos < 0)
      return -1;

   int value_pos = colon_pos + 1;
   while(value_pos < StringLen(raw))
   {
      ushort ch = StringGetCharacter(raw, value_pos);
      if(ch != ' ' && ch != '\r' && ch != '\n' && ch != '\t')
         break;
      value_pos++;
   }

   if(StringSubstr(raw, value_pos, 4) == "null")
      return 0;

   if(value_pos >= StringLen(raw) || StringGetCharacter(raw, value_pos) != '{')
      return -1;

   int depth = 0;
   bool in_string = false;
   bool escaped = false;
   for(int i = value_pos; i < StringLen(raw); i++)
   {
      ushort ch = StringGetCharacter(raw, i);
      if(in_string)
      {
         if(escaped)
         {
            escaped = false;
            continue;
         }
         if(ch == '\\')
         {
            escaped = true;
            continue;
         }
         if(ch == '"')
            in_string = false;
         continue;
      }

      if(ch == '"')
      {
         in_string = true;
         continue;
      }
      if(ch == '{')
         depth++;
      else if(ch == '}')
      {
         depth--;
         if(depth == 0)
         {
            signal_json = StringSubstr(raw, value_pos, i - value_pos + 1);
            return 1;
         }
      }
   }

   return -1;
}

bool ParseSignal(string raw, Signal &signal)
{
   signal.symbol = JsonString(raw, "symbol");
   signal.side = JsonString(raw, "side");
   signal.entry = JsonNumber(raw, "entry");
   signal.stop_loss = JsonNumber(raw, "stop_loss");
   signal.take_profit = JsonNumber(raw, "take_profit");
   signal.risk_percent = JsonNumber(raw, "risk_percent");
   signal.lot = JsonNumber(raw, "lot");
   signal.signal_id = JsonString(raw, "signal_id");
   signal.server_received_time = ParseTimestamp(JsonString(raw, "server_received_time"));
   signal.secret = JsonString(raw, "secret");

   return signal.symbol != "" &&
          signal.side != "" &&
           signal.entry >= 0 &&
          signal.stop_loss > 0 &&
          signal.take_profit > 0 &&
          signal.risk_percent > 0 &&
          signal.signal_id != "" &&
          signal.server_received_time > 0 &&
          signal.secret != "";
}

string JsonString(string json, string key)
{
   string pattern = "\"" + key + "\"";
   int p = StringFind(json, pattern);
   if(p < 0)
      return "";
   p = StringFind(json, ":", p + StringLen(pattern));
   if(p < 0)
      return "";
   p = StringFind(json, "\"", p + 1);
   if(p < 0)
      return "";
   int end = StringFind(json, "\"", p + 1);
   if(end < 0)
      return "";
   return StringSubstr(json, p + 1, end - p - 1);
}

double JsonNumber(string json, string key)
{
   string pattern = "\"" + key + "\"";
   int p = StringFind(json, pattern);
   if(p < 0)
      return 0.0;
   p = StringFind(json, ":", p + StringLen(pattern));
   if(p < 0)
      return 0.0;
   p++;
   while(p < StringLen(json) && StringGetCharacter(json, p) == ' ')
      p++;

   int end = p;
   while(end < StringLen(json))
   {
      ushort ch = StringGetCharacter(json, end);
      if((ch >= '0' && ch <= '9') || ch == '.' || ch == '-')
         end++;
      else
         break;
   }
   return StringToDouble(StringSubstr(json, p, end - p));
}

datetime ParseTimestamp(string value)
{
   string ts = value;
   StringReplace(ts, "T", " ");
   StringReplace(ts, "Z", "");
   int dot = StringFind(ts, ".");
   if(dot >= 0)
      ts = StringSubstr(ts, 0, dot);
   StringReplace(ts, "-", ".");
   return StringToTime(ts);
}

string EncodeOutcomeReason(string reason)
{
   string encoded = "";
   for(int i = 0; i < StringLen(reason); i++)
      encoded += StringFormat("%04X", (int)StringGetCharacter(reason, i));
   return encoded;
}

bool DecodeOutcomeReason(string encoded, string &reason)
{
   reason = "";
   if(StringLen(encoded) % 4 != 0)
      return false;
   for(int i = 0; i < StringLen(encoded); i += 4)
   {
      int code = 0;
      for(int j = 0; j < 4; j++)
      {
         int digit = StringFind("0123456789ABCDEF", StringSubstr(encoded, i + j, 1));
         if(digit < 0)
            return false;
         code = code * 16 + digit;
      }
      reason += ShortToString((ushort)code);
   }
   return true;
}

bool LoadSignalOutcome(string signal_id, string &status_name, string &reason)
{
   // Terminal outcomes live beside the legacy seen-ID execution guard.
   status_name = "";
   reason = "";
   if(signal_id == "")
      return false;

   int handle = FileOpen("TVWebhookExecutorEA_outcomes.csv", FILE_READ | FILE_CSV);
   if(handle == INVALID_HANDLE)
      return false;

   bool found = false;
   while(!FileIsEnding(handle))
   {
      string id = FileReadString(handle);
      string saved_status = FileReadString(handle);
      string saved_reason_hex = FileReadString(handle);
      if(id == signal_id && (saved_status == "executed" || saved_status == "rejected" || saved_status == "failed"))
      {
         string saved_reason = "";
         if(DecodeOutcomeReason(saved_reason_hex, saved_reason))
         {
            status_name = saved_status;
            reason = saved_reason;
            found = true;
         }
      }
   }
   FileClose(handle);
   return found;
}

bool RememberSignalOutcome(string signal_id, string status_name, string reason)
{
   if(signal_id == "")
      return false;

   string existing_status = "";
   string existing_reason = "";
   if(LoadSignalOutcome(signal_id, existing_status, existing_reason))
      return existing_status == status_name;

   int handle = FileOpen("TVWebhookExecutorEA_outcomes.csv", FILE_READ | FILE_WRITE | FILE_CSV);
   if(handle == INVALID_HANDLE)
      handle = FileOpen("TVWebhookExecutorEA_outcomes.csv", FILE_WRITE | FILE_CSV);
   if(handle == INVALID_HANDLE)
      return false;

   FileSeek(handle, 0, SEEK_END);
   uint written = FileWrite(handle, signal_id, status_name, EncodeOutcomeReason(reason));
   FileFlush(handle);
   FileClose(handle);
   return written > 0;
}

bool IsDuplicateSignal(string signal_id)
{
   int handle = FileOpen("TVWebhookExecutorEA_seen.csv", FILE_READ | FILE_CSV);
   if(handle == INVALID_HANDLE)
      return false;

   while(!FileIsEnding(handle))
   {
      string id = FileReadString(handle);
      if(id == signal_id)
      {
         FileClose(handle);
         return true;
      }
   }
   FileClose(handle);
   return false;
}

bool RememberSignal(string signal_id)
{
   if(signal_id == "")
      return false;
   if(IsDuplicateSignal(signal_id))
      return false;

   int handle = FileOpen("TVWebhookExecutorEA_seen.csv", FILE_READ | FILE_WRITE | FILE_CSV);
   if(handle == INVALID_HANDLE)
      handle = FileOpen("TVWebhookExecutorEA_seen.csv", FILE_WRITE | FILE_CSV);
   if(handle == INVALID_HANDLE)
      return false;

   FileSeek(handle, 0, SEEK_END);
   uint written = FileWrite(handle, signal_id);
   FileFlush(handle);
   FileClose(handle);
   return written > 0;
}

void LogTrade(string event_name, string signal_id, string symbol, double price, double sl, double tp, double volume, string message)
{
   if(StringFind(event_name, "REJECT_") == 0)
   {
      PrintFormat("SIGNAL_REJECTED reason=%s signal_id=%s symbol=%s message=%s", event_name, signal_id, symbol, message);
      if(signal_id != "")
         SendSignalAck(signal_id, "rejected", event_name + ":" + message);
   }

   int handle = FileOpen("TVWebhookExecutorEA_trades.csv", FILE_READ | FILE_WRITE | FILE_CSV);
   if(handle == INVALID_HANDLE)
      handle = FileOpen("TVWebhookExecutorEA_trades.csv", FILE_WRITE | FILE_CSV);
   if(handle == INVALID_HANDLE)
   {
      Print(event_name, " ", signal_id, " ", message);
      return;
   }

   if(FileSize(handle) == 0)
      FileWrite(handle, "time", "event", "signal_id", "symbol", "price", "sl", "tp", "volume", "message");

   int digits = _Digits;
   if(symbol != "" && SymbolSelect(symbol, true))
      digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             event_name,
             signal_id,
             symbol,
             DoubleToString(price, digits),
             DoubleToString(sl, digits),
             DoubleToString(tp, digits),
             DoubleToString(volume, 2),
             message);
   FileClose(handle);
   Print(event_name, " signal=", signal_id, " symbol=", symbol, " ", message);
}

string ToUpper(string value)
{
   string out = value;
   StringToUpper(out);
   return out;
}

string UrlEncode(string value)
{
   string out = "";
   for(int i = 0; i < StringLen(value); i++)
   {
      ushort ch = StringGetCharacter(value, i);
      if((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.' || ch == '~')
         out += ShortToString(ch);
      else
         out += "%" + StringFormat("%02X", ch);
   }
   return out;
}
