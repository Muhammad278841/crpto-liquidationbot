import json
import threading
import time
import requests
from websocket import WebSocketApp
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes

# === НАСТРОЙКИ ===
TELEGRAM_TOKEN = "7334134545:AAEJ-kFl-bmHxUAZsHDW1xmLY62Le0fjZ0E"
CHAT_ID = None  # будет установлен при первом /start
MIN_LIQUIDATION_USD = 50000
MIN_PUMP_PERCENT = 3.0  # памп/дамп от 3% за 5 мин

# Фильтр по монетам (оставь пустым, чтобы отслеживать все)
WATCHLIST = ["BTCUSDT", "ETHUSDT", "SOLUSDT", "XRPUSDT", "DOGEUSDT"]

# Глобальные настройки пользователя
user_settings = {
    "alerts_liquidation": True,
    "alerts_pumpdump": True,
    "exchange_binance": True,
    "exchange_bybit": True,
}

# Отправка сообщения
def send_telegram_message(text, chat_id=None):
    if not chat_id:
        chat_id = CHAT_ID
    if not chat_id:
        return
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"
    payload = {"chat_id": chat_id, "text": text, "parse_mode": "Markdown"}
    try:
        requests.post(url, json=payload)
    except:
        pass

# Форматирование ликвидации
def format_liquidation(symbol, exchange, side):
    emoji = "🟢" if side == "LONG" else "🔴"
    return f"{emoji} {symbol} | {exchange} | {side}"

# Форматирование памп/дамп
def format_pumpdump(symbol, exchange, change_percent, is_pump):
    emoji = "🚀" if is_pump else "💣"
    sign = "+" if is_pump else ""
    return f"{emoji} {symbol} | {exchange} | {sign}{change_percent:.1f}%"

# ================== ЛИКВИДАЦИИ ==================

# Binance
def on_binance_message(ws, message):
    try:
        data = json.loads(message)
        if isinstance(data, list):
            for event in data:
                if isinstance(event, dict):
                    symbol = event.get('symbol', 'N/A')
                    if WATCHLIST and symbol not in WATCHLIST:
                        continue
                    side = "SHORT" if event.get('side') == "SELL" else "LONG"
                    qty = float(event.get('origQty', 0))
                    price = float(event.get('price', 0))
                    usd_value = qty * price
                    if usd_value >= MIN_LIQUIDATION_USD and user_settings["alerts_liquidation"] and user_settings["exchange_binance"]:
                        msg_text = format_liquidation(symbol, "Binance", side)
                        send_telegram_message(msg_text)
    except Exception as e:
        print(f"[BINANCE ERROR] {e}")

def start_binance():
    url = "wss://fstream.binance.com/ws/!forceOrder@arr"
    ws = WebSocketApp(
        url,
        on_message=on_binance_message,
        on_error=lambda ws, err: print(f"[BINANCE ERROR] {err}"),
        on_close=lambda ws, code, msg: (print("[BINANCE] Reconnecting..."), time.sleep(5), start_binance()),
        on_open=lambda ws: print("[BINANCE] Connected")
    )
    ws.run_forever()

# Bybit
def on_bybit_message(ws, message):
    try:
        data = json.loads(message)
        if data.get("op") == "ping":
            ws.send(json.dumps({"op": "pong"}))
            return
        for topic_data in data.get("data", []):
            for item in topic_data.get("list", []):
                symbol = item.get("symbol")
                if WATCHLIST and symbol not in WATCHLIST:
                    continue
                side = "SHORT" if item.get("side") == "Sell" else "LONG"
                qty = float(item.get("qty", 0))
                price = float(item.get("price", 0))
                usd_value = qty * price
                if usd_value >= MIN_LIQUIDATION_USD and user_settings["alerts_liquidation"] and user_settings["exchange_bybit"]:
                    msg_text = format_liquidation(symbol, "Bybit", side)
                    send_telegram_message(msg_text)
    except Exception as e:
        print(f"[BYBIT ERROR] {e}")

👑, [21.09.2025 2:34]
def start_bybit():
    url = "wss://stream.bybit.com/v5/public/linear"
    ws = WebSocketApp(
        url,
        on_message=on_bybit_message,
        on_error=lambda ws, err: print(f"[BYBIT ERROR] {err}"),
        on_close=lambda ws, code, msg: (print("[BYBIT] Reconnecting..."), time.sleep(5), start_bybit()),
        on_open=lambda ws: (
            print("[BYBIT] Connected"),
            ws.send(json.dumps({"op": "subscribe", "args": ["liquidation.linear"]}))
        )
    )
    ws.run_forever()

# ================== ПАМПЫ/ДАМПЫ ==================

price_cache = {}  # { "BTCUSDT_Binance": [цена1, цена2, ...] }

def track_price(symbol, exchange, price):
    key = f"{symbol}_{exchange}"
    if key not in price_cache:
        price_cache[key] = []
    price_cache[key].append(price)
    if len(price_cache[key]) > 10:
        price_cache[key].pop(0)

    if len(price_cache[key]) < 2:
        return

    old_price = price_cache[key][0]
    change_percent = ((price - old_price) / old_price) * 100

    if abs(change_percent) >= MIN_PUMP_PERCENT:
        is_pump = change_percent > 0
        if (is_pump and user_settings["alerts_pumpdump"] and
            ((exchange == "Binance" and user_settings["exchange_binance"]) or
             (exchange == "Bybit" and user_settings["exchange_bybit"]))):
            msg_text = format_pumpdump(symbol, exchange, change_percent, is_pump)
            send_telegram_message(msg_text)

# Binance цены
def on_binance_ticker(ws, message):
    try:
        data = json.loads(message)
        symbol = data.get('s')
        if WATCHLIST and symbol not in WATCHLIST:
            return
        price = float(data.get('c', 0))
        track_price(symbol, "Binance", price)
    except:
        pass

def start_binance_ticker():
    url = "wss://fstream.binance.com/ws/!ticker@arr"
    ws = WebSocketApp(
        url,
        on_message=on_binance_ticker,
        on_error=lambda ws, err: print(f"[BINANCE TICKER ERROR] {err}"),
        on_close=lambda ws, code, msg: (print("[BINANCE TICKER] Reconnecting..."), time.sleep(5), start_binance_ticker()),
        on_open=lambda ws: print("[BINANCE TICKER] Connected")
    )
    ws.run_forever()

# Bybit цены
def on_bybit_ticker(ws, message):
    try:
        data = json.loads(message)
        if data.get("topic") == "tickers":
            for symbol, info in data.get("data", {}).items():
                if WATCHLIST and symbol not in WATCHLIST:
                    continue
                price = float(info.get("lastPrice", 0))
                track_price(symbol, "Bybit", price)
    except:
        pass

def start_bybit_ticker():
    url = "wss://stream.bybit.com/v5/public/linear"
    ws = WebSocketApp(
        url,
        on_message=on_bybit_ticker,
        on_error=lambda ws, err: print(f"[BYBIT TICKER ERROR] {err}"),
        on_close=lambda ws, code, msg: (print("[BYBIT TICKER] Reconnecting..."), time.sleep(5), start_bybit_ticker()),
        on_open=lambda ws: (
            print("[BYBIT TICKER] Connected"),
            ws.send(json.dumps({"op": "subscribe", "args": ["tickers.*"]}))
        )
    )
    ws.run_forever()

# ================== TELEGRAM ИНТЕРФЕЙС ==================

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global CHAT_ID
    CHAT_ID = update.effective_chat.id
    await update.message.reply_text(
        "👋 Привет! Я Crypto Hawk — твой скринер ликвидаций и пампов.\n\n"
        "Нажми на кнопки ниже, чтобы настроить алерты:",
        reply_markup=get_settings_keyboard()
    )

def get_settings_keyboard():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton(f"Ликвидации: {'✅' if user_settings['alerts_liquidation'] else '❌'}", callback_data='toggle_liquidation')],
        [InlineKeyboardButton(f"Пампы/Дампы: {'✅' if user_settings['alerts_pumpdump'] else '❌'}", callback_data='toggle_pumpdump')],

👑, [21.09.2025 2:34]
[InlineKeyboardButton(f"Binance: {'✅' if user_settings['exchange_binance'] else '❌'}", callback_data='toggle_binance')],
        [InlineKeyboardButton(f"Bybit: {'✅' if user_settings['exchange_bybit'] else '❌'}", callback_data='toggle_bybit')],
        [InlineKeyboardButton("Готово ✅", callback_data='done')]
    ])

async def button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()

    if query.data == 'toggle_liquidation':
        user_settings['alerts_liquidation'] = not user_settings['alerts_liquidation']
    elif query.data == 'toggle_pumpdump':
        user_settings['alerts_pumpdump'] = not user_settings['alerts_pumpdump']
    elif query.data == 'toggle_binance':
        user_settings['exchange_binance'] = not user_settings['exchange_binance']
    elif query.data == 'toggle_bybit':
        user_settings['exchange_bybit'] = not user_settings['exchange_bybit']
    elif query.data == 'done':
        await query.edit_message_text("✅ Настройки сохранены! Бот работает.")
        return

    await query.edit_message_reply_markup(reply_markup=get_settings_keyboard())

# ================== ЗАПУСК ==================

def run_telegram_bot():
    application = Application.builder().token(TELEGRAM_TOKEN).build()
    application.add_handler(CommandHandler("start", start))
    application.add_handler(CallbackQueryHandler(button))
    application.run_polling()

if name == "main":
    print("🚀 Запуск Crypto Hawk...")
    print("Подключение к биржам...")

    # Запуск WebSocket в фоне
    threading.Thread(target=start_binance, daemon=True).start()
    threading.Thread(target=start_bybit, daemon=True).start()
    threading.Thread(target=start_binance_ticker, daemon=True).start()
    threading.Thread(target=start_bybit_ticker, daemon=True).start()

    # Запуск Telegram-бота
    run_telegram_bot()
