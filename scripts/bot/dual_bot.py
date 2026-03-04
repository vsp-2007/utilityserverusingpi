import os
import asyncio
import json
import logging
import psutil
import subprocess
import socket
from datetime import datetime
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes, filters

# --- CONFIGURATION ---
ADMIN_TOKEN = os.getenv("TELEGRAM_ADMIN_TOKEN")
ADMIN_CHAT_ID = os.getenv("TELEGRAM_ADMIN_CHAT_ID")
USER_BOT_TOKEN = os.getenv("TELEGRAM_USER_TOKEN")

BROADCAST_LIST_FILE = "/opt/pi-server-bot/broadcast_list.json"

# --- SHARED STATE ---
# Stores: request_id -> {"chat_id": int, "duration": str, "requester_name": str}
pending_disable_requests = {}
request_counter = 1

# --- LOGGING ---
logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s", level=logging.INFO
)
logger = logging.getLogger(__name__)

# --- HELPERS ---

async def async_run_command(command, shell=False):
    """Run a shell command asynchronously."""
    try:
        if shell:
            proc = await asyncio.create_subprocess_shell(
                command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
        else:
            proc = await asyncio.create_subprocess_exec(
                *command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
        stdout, stderr = await proc.communicate()
        return stdout.decode().strip(), stderr.decode().strip(), proc.returncode
    except Exception as e:
        logger.error(f"Async command failed: {e}")
        return "", str(e), 1

async def get_system_stats():
    """Generates the DAILY SYSTEM REPORT format."""
    # Hostname & IP
    hostname = socket.gethostname()
    ip = subprocess.getoutput("hostname -I | awk '{print $1}'")
    
    # Uptime
    uptime = subprocess.getoutput("uptime -p")
    
    # Temp
    try:
        temp = subprocess.getoutput("vcgencmd measure_temp").replace("temp=", "")
    except:
        temp = "N/A"

    # RAM
    mem = psutil.virtual_memory()
    ram_usage = f"{mem.used // 1024 // 1024}Mi / {mem.total // 1024 // 1024}Gi"
    
    # Disk
    disk = psutil.disk_usage('/')
    disk_free_gb = round(disk.free / (1024**3), 1)
    disk_usage = f"{disk.percent}% Used ({disk_free_gb}G Free)"

    # Service Health
    services = {
        "prometheus": "prometheus",
        "node_exporter": "node_exporter",
        "alertmanager": "alertmanager",
        "grafana-server": "grafana-server",
        "pihole-FTL": "pihole-FTL",
        "smbd": "smbd"
    }
    
    service_status_lines = []
    for name, service in services.items():
        # Async check
        _, _, code = await async_run_command(["systemctl", "is-active", "--quiet", service])
        is_active = (code == 0)
        icon = "✅" if is_active else "❌"
        service_status_lines.append(f"{icon} {name}")

    report = (
        f"📊 DAILY SYSTEM REPORT 📊\n\n"
        f"System Status: Optimal\n"
        f"Hostname: {hostname}\n"
        f"IP: {ip}\n"
        f"Uptime: {uptime}\n"
        f"Temp: {temp}\n"
        f"RAM: {ram_usage}\n"
        f"Disk: {disk_usage}\n\n"
        f"Service Health:\n\n" +
        "\n".join(service_status_lines)
    )
    return report

async def get_pihole_stats():
    """Fetches real-time stats from Pi-hole API."""
    try:
        # pihole -c -j returns a compact JSON summary
        stdout, stderr, code = await async_run_command(["pihole", "-c", "-j"])
        if code != 0:
            raise Exception(stderr)
            
        stats = json.loads(stdout)
        
        # Mapping keys to readable labels
        summary = (
            f"🛡️ **Pi-hole Status** 🛡️\n\n"
            f"Queries Today: {stats.get('dns_queries_today', 'N/A')}\n"
            f"Ads Blocked: {stats.get('ads_blocked_today', 'N/A')}\n"
            f"Percentage: {stats.get('ads_percentage_today', 'N/A')}%\n"
            f"Domains on List: {stats.get('domains_being_blocked', 'N/A')}\n"
            f"Status: {'Active ✅' if stats.get('status') == 'enabled' else 'Disabled ❌'}"
        )
        return summary
    except Exception as e:
        logger.error(f"Failed to fetch Pi-hole stats: {e}")
        return f"❌ Error retrieving stats: {e}"

def load_broadcast_list():
    if not os.path.exists(BROADCAST_LIST_FILE):
        return []
    try:
        with open(BROADCAST_LIST_FILE, 'r') as f:
            return json.load(f)
    except:
        return []

def save_broadcast_list(chat_ids):
    # Ensure directory exists
    os.makedirs(os.path.dirname(BROADCAST_LIST_FILE), exist_ok=True)
    with open(BROADCAST_LIST_FILE, 'w') as f:
        json.dump(list(set(chat_ids)), f)

# --- USER BOT HANDLERS ---

async def user_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Register the user/group for broadcasts and say hello."""
    chat_id = update.effective_chat.id
    existing_list = load_broadcast_list()
    if chat_id not in existing_list:
        existing_list.append(chat_id)
        save_broadcast_list(existing_list)
        logger.info(f"New User Bot subscriber: {chat_id}")
    
    await update.message.reply_text("👋 Hello! I am the Status Bot. Type /status to see the system report.")

async def user_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Send the Daily System Report."""
    # Ensure sender is in broadcast list (just in case they missed /start)
    chat_id = update.effective_chat.id
    existing_list = load_broadcast_list()
    if chat_id not in existing_list:
        existing_list.append(chat_id)
        save_broadcast_list(existing_list)

    report = await get_system_stats()
    await update.message.reply_text(report)

async def shared_pihole_stats(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Available on both Admin and User bots."""
    stats = await get_pihole_stats()
    await update.message.reply_text(stats, parse_mode="Markdown")

async def user_pdr(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Pi-hole Disable Request (User Bot)."""
    global request_counter
    chat_id = update.effective_chat.id
    username = update.effective_user.first_name
    duration = context.args[0] if context.args else "5m"
    
    req_id = request_counter
    request_counter += 1
    
    pending_disable_requests[req_id] = {
        "chat_id": chat_id,
        "duration": duration,
        "requester_name": username
    }
    
    await update.message.reply_text(f"⏳ Request #{req_id} sent to Admin for approval (Disable Pi-hole for {duration}).")
    
    # Notify Admin Bot
    # Since they share the same tokens/env, we can just send via the Admin Bot's token
    from telegram import Bot
    admin_bot_sender = Bot(token=ADMIN_TOKEN)
    admin_msg = (
        f"🚨 **DISABLE REQUEST** 🚨\n\n"
        f"ID: #{req_id}\n"
        f"User: {username}\n"
        f"Duration: {duration}\n\n"
        f"Use `/approve {req_id}` or `/deny {req_id}`"
    )
    try:
        await admin_bot_sender.send_message(chat_id=ADMIN_CHAT_ID, text=admin_msg, parse_mode="Markdown")
    except Exception as e:
        logger.error(f"Failed to notify Admin: {e}")
        # Inform user of failure
        await update.message.reply_text(f"⚠️ Warning: Could not forward request to Admin Bot.\nError: {e}")

# --- ADMIN BOT HANDLERS ---

async def admin_check(update: Update):
    """Middleware to check if sender is the Admin."""
    if str(update.effective_chat.id) != str(ADMIN_CHAT_ID):
        logger.warning(f"Unauthorized access attempt by {update.effective_chat.id}")
        return False
    return True

async def admin_reboot(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not await admin_check(update): return
    await update.message.reply_text("⚠️ Rebooting system in 5 seconds...")
    await asyncio.sleep(5)
    subprocess.run(["sudo", "reboot"])

async def admin_restart_service(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not await admin_check(update): return
    if not context.args:
        await update.message.reply_text("Usage: /restart <service_name>")
        return
    
    service_name = context.args[0]
    await update.message.reply_text(f"🔄 Restarting {service_name}...")
    
    _, _, code = await async_run_command(["sudo", "systemctl", "restart", service_name])
    
    if code == 0:
        await update.message.reply_text(f"✅ {service_name} restarted successfully.")
    else:
        await update.message.reply_text(f"❌ Failed to restart {service_name}.")

async def admin_pihole(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not await admin_check(update): return
    if not context.args or context.args[0] not in ["enable", "disable"]:
        await update.message.reply_text("Usage: /pihole <enable|disable> [time]")
        return
    
    cmd = context.args[0]
    full_cmd = ["pihole", cmd]
    if len(context.args) > 1:
        full_cmd.append(context.args[1]) # Duration for disable

    await update.message.reply_text(f"🛡️ Running pihole {cmd}...")
    
    stdout, _, _ = await async_run_command(full_cmd)
    await update.message.reply_text(f"Output:\n{stdout}")

async def admin_approve_request(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not await admin_check(update): return
    if not context.args:
        await update.message.reply_text("Usage: /approve <req_id>")
        return
    
    try:
        req_id = int(context.args[0].replace("#", ""))
    except ValueError:
        await update.message.reply_text("Invalid Request ID.")
        return

    req = pending_disable_requests.pop(req_id, None)
    if not req:
        await update.message.reply_text("Request not found or already handled.")
        return

    # Execute Pi-hole disable
    duration = req["duration"]
    await async_run_command(["pihole", "disable", duration])
    
    await update.message.reply_text(f"✅ Approved Request #{req_id}. Pi-hole disabled for {duration}.")
    
    # Notify User back via User Bot
    from telegram import Bot
    user_bot_sender = Bot(token=USER_BOT_TOKEN)
    try:
        await user_bot_sender.send_message(
            chat_id=req["chat_id"], 
            text=f"✅ Your request to disable Pi-hole for {duration} was **APPROVED** by Admin."
        )
    except Exception as e:
        logger.error(f"Failed to notify User {req['chat_id']}: {e}")

async def admin_deny_request(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not await admin_check(update): return
    if not context.args:
        await update.message.reply_text("Usage: /deny <req_id>")
        return
    
    try:
        req_id = int(context.args[0].replace("#", ""))
    except ValueError:
        await update.message.reply_text("Invalid Request ID.")
        return

    req = pending_disable_requests.pop(req_id, None)
    if not req:
        await update.message.reply_text("Request not found or already handled.")
        return

    await update.message.reply_text(f"❌ Denied Request #{req_id}.")
    
    # Notify User
    from telegram import Bot
    user_bot_sender = Bot(token=USER_BOT_TOKEN)
    try:
        await user_bot_sender.send_message(
            chat_id=req["chat_id"], 
            text=f"❌ Your request to disable Pi-hole was **DENIED** by Admin."
        )
    except Exception as e:
        logger.error(f"Failed to notify User {req['chat_id']}: {e}")

async def admin_pdr(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Shortcut for Admin to disable Pi-hole temporarily (Default: 5m)."""
    if not await admin_check(update): return
    
    duration = context.args[0] if context.args else "5m"
    
    await update.message.reply_text(f"⏳ Disabling Pi-hole for {duration}...")
    
    # Reuse admin_pihole logic or just run it directly
    full_cmd = ["pihole", "disable", duration]
    stdout, stderr, code = await async_run_command(full_cmd)
    
    if code == 0:
        await update.message.reply_text(f"✅ Pi-hole disabled for {duration}.")
    else:
        await update.message.reply_text(f"❌ Failed: {stdout} {stderr}")

async def admin_check_system(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Trigger a local Wazuh scan (Syscheck/Rootcheck/SCA)."""
    if not await admin_check(update): return

    # Check if wazuh-manager is installed and active
    _, _, code = await async_run_command(["systemctl", "is-active", "--quiet", "wazuh-manager"])
    if code != 0:
        await update.message.reply_text("❌ Wazuh Manager is not installed or not running.")
        return

    await update.message.reply_text("⏳ Initiating system security check (Syscheck & Rootcheck)... \nI'll report back when the scan finishes.")
    
    # Force run all agent modules locally
    # agent_control -r -a restarts the agent processes, which by default runs syscheck/rootcheck on start
    _, stderr, code = await async_run_command(["sudo", "/var/ossec/bin/agent_control", "-r", "-a"])
    
    if code != 0:
        await update.message.reply_text(f"⚠️ Failed to trigger scan: {stderr}")

async def admin_announce(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not await admin_check(update): return
    message_text = " ".join(context.args)
    if not message_text:
        await update.message.reply_text("Usage: /announce <message>")
        return

    # Trigger USER bot to broadcast
    # Since they are in the same loop, we can access the user_bot application if we passed it.
    # But cleaner is to just use the token separately or use a shared context.
    # Here, we will use the shared broadcast list and a separate simpler broadcast call.
    
    subscribers = load_broadcast_list()
    count = 0
    
    # We need the user_bot instance. 
    # In this design, we'll return a special signal or just instantiate a temporary bot instance to send?
    # Better: The main loop constructs both. We can inject the user_bot app into the admin bot context 
    # OR we can just use the token to send via API.
    
    # Let's use the context.bot_data to store the reference to the user bot if possible,
    # or just easier: use the User Bot Token to create a one-off sender.
    
    from telegram import Bot
    user_bot_sender = Bot(token=USER_BOT_TOKEN)
    
    formatted_msg = f"📢 **ANNOUNCEMENT** 📢\n\n{message_text}"
    
    for chat_id in subscribers:
        try:
            await user_bot_sender.send_message(chat_id=chat_id, text=formatted_msg, parse_mode="Markdown")
            count += 1
        except Exception as e:
            logger.error(f"Failed to send to {chat_id}: {e}")
            
    await update.message.reply_text(f"✅ Announcement sent to {count} subscribers.")


# --- MAIN ---

async def main():
    if not ADMIN_TOKEN or not USER_BOT_TOKEN:
        logger.error("Error: Missing Bot Tokens.")
        return

    # 1. Setup User Bot
    user_app = Application.builder().token(USER_BOT_TOKEN).build()
    user_app.add_handler(CommandHandler("start", user_start))
    user_app.add_handler(CommandHandler("status", user_status))
    user_app.add_handler(CommandHandler("pihole_stats", shared_pihole_stats))
    user_app.add_handler(CommandHandler("pdr", user_pdr))
    # Implicit: It captures chat_ids on interactions

    # 2. Setup Admin Bot
    admin_app = Application.builder().token(ADMIN_TOKEN).build()
    admin_app.add_handler(CommandHandler("reboot", admin_reboot))
    admin_app.add_handler(CommandHandler("restart", admin_restart_service))
    admin_app.add_handler(CommandHandler("pihole", admin_pihole))
    admin_app.add_handler(CommandHandler("pihole_stats", shared_pihole_stats))
    # FIX: Add status handler to Admin Bot too
    admin_app.add_handler(CommandHandler("status", user_status))
    admin_app.add_handler(CommandHandler("approve", admin_approve_request))
    admin_app.add_handler(CommandHandler("deny", admin_deny_request))
    admin_app.add_handler(CommandHandler("announce", admin_announce))
    admin_app.add_handler(CommandHandler("pdr", admin_pdr))
    admin_app.add_handler(CommandHandler("check", admin_check_system))

    # 3. Run Both
    async with user_app:
        await user_app.start()
        await user_app.updater.start_polling()
        
        async with admin_app:
            await admin_app.start()
            await admin_app.updater.start_polling()
            
            # Keep alive
            logger.info("🤖 Dual Bots Started...")
            await asyncio.Future()  # Run forever

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
