#!/bin/bash

# ==============================================================================
# ZIMBRA AUTOMATION CLEANUP SCRIPT (V5 - FINAL ROBUST)
# This script is designed to run locally on the Zimbra server via CRON.
# Refined: Fixed negative ID parsing, robust locking error logs, and aligned logic.
# ==============================================================================

# ---------- CONFIGURATION ----------
THRESHOLD=90        # Process accounts >= 90% usage
DAYS_KEEP=2         # Older than 2 days
LOG_KEEP_DAYS=7     # Keep logs for 7 days

LOG_BASE="/opt/zimbra/.log-zimbra-cleanup"
LOG_FILE="$LOG_BASE/zimbra_cleanup_$(date +%Y%m%d).log"
LOCK_FILE="/tmp/zimbra_auto_cleanup.lock"

ZMPROV="/opt/zimbra/bin/zmprov"
ZMMAILBOX="/opt/zimbra/bin/zmmailbox"

CHECK_DATE=$(date -d "$DAYS_KEEP days ago" "+%m/%d/%Y")

# ---------- 1. PRE-FLIGHT & PERMISSIONS ----------

# A. User Check & Absolute Path Switch
CURRENT_USER=$(id -u -n)
SCRIPT_PATH=$(readlink -f "$0")

# Ensure LOG_BASE exists for potential error logging
[ ! -d "$LOG_BASE" ] && mkdir -p "$LOG_BASE" 2>/dev/null

if [ "$CURRENT_USER" = "root" ]; then
    chown zimbra:zimbra "$LOG_BASE" 2>/dev/null
    # Switch to zimbra user and re-run script
    exec su - zimbra -s /bin/bash -c "\"$SCRIPT_PATH\" \"\$@\"" -- "$@"
elif [ "$CURRENT_USER" != "zimbra" ]; then
    echo "[$(date)] [ERROR] Must be run as 'zimbra' or 'root'. Current: $CURRENT_USER"
    exit 1
fi

# B. Locking
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    ERROR_MSG="[$(date)] [ERROR] Another instance is already running. Exiting."
    echo "$ERROR_MSG"
    # Guaranteed to have LOG_BASE now
    echo "$ERROR_MSG" >> "$LOG_FILE"
    exit 1
fi

# C. Setup Workspace & Housekeeping (Move after lock to avoid deleting active sessions)
# Since we have the lock, any existing auto_tmp_* is an orphan from a crashed/killed run
rm -rf "$LOG_BASE"/auto_tmp_* 2>/dev/null

TMP_DIR="$LOG_BASE/auto_tmp_$$"
mkdir -p "$TMP_DIR"

cleanup_handler() {
    rm -rf "$TMP_DIR"
    # Explicitly close lock FD (though it closes on EXIT anyway)
    exec 200>&-
}
trap cleanup_handler EXIT INT TERM

# ---------- 2. LOGGING PREP ----------
echo "--------------------------------------------------" >> "$LOG_FILE"
echo "[AUTO] RUN START - $(date)" >> "$LOG_FILE"
echo "[AUTO] Threshold: $THRESHOLD% | Before: $CHECK_DATE" >> "$LOG_FILE"
echo "--------------------------------------------------" >> "$LOG_FILE"

# ---------- 3. QUERY DEFINITIONS ----------
QUERY_BISNIS="(subject:\"data penjualan\" OR content:\"data penjualan\" OR subject:\"rekap doc\" OR content:\"rekap doc\" OR subject:\"doc gabungan\" OR content:\"doc gabungan\" OR subject:\"rekap rhpp\" OR content:\"rekap rhpp\" OR subject:\"laporan kasir\" OR content:\"laporan kasir\" OR subject:\"rekap penjualan\" OR content:\"rekap penjualan\") before:\"$CHECK_DATE\""
QUERY_SYSTEM="(subject:\"quota warning\" AND content:\"mailbox size has reached\")"

# ---------- 4. SCAN ACCOUNTS ----------
ACCOUNTS_LIST="$TMP_DIR/accounts.txt"

$ZMPROV gqu localhost | awk -v limit="$THRESHOLD" '
{
  u = $1; quota = $2; used = $3;
  if (quota > 0) {
    p = (used / quota) * 100;
    if (p >= limit) printf "%s|%d\n", u, p;
  }
}' > "$ACCOUNTS_LIST"

COUNT_ACCOUNTS=$(wc -l < "$ACCOUNTS_LIST")

if [ "$COUNT_ACCOUNTS" -eq 0 ]; then
    echo "$(date '+%b %d %Y - %H:%M:%S') [INFO] No accounts over threshold. Done." >> "$LOG_FILE"
    exit 0
fi

# ---------- 5. MAIN PROCESSING LOOP ----------
while IFS="|" read -r MAILBOX PERCENT; do
    echo "$(date '+%b %d %Y - %H:%M:%S') [AUTO][PROCESS] $MAILBOX (Usage: $PERCENT%)" >> "$LOG_FILE"
    
    # --- A. Empty Trash ---
    if $ZMMAILBOX -z -m "$MAILBOX" ef /Trash > /dev/null 2>&1; then
        echo "   [AUTO][TRASH] OK" >> "$LOG_FILE"
    else
        echo "   [AUTO][TRASH] SKIPPED (empty or error)" >> "$LOG_FILE"
    fi

    # --- B. Business Cleanup ---
    TOTAL_DELETED=0
    TOTAL_FAILED=0
    SEARCH_STATUS="OK"
    
    while true; do
        RAW_SEARCH="$TMP_DIR/search_raw.txt"
        if ! $ZMMAILBOX -z -m "$MAILBOX" s -l 50 -v "$QUERY_BISNIS" > "$RAW_SEARCH" 2>&1; then
            echo "$(date '+%b %d %Y - %H:%M:%S') [AUTO][ERROR] zmmailbox search failed for $MAILBOX" >> "$LOG_FILE"
            SEARCH_STATUS="ERROR"
            break
        fi

        # Parse results - Using Python to handle JSON output correctly (now looking for "hits")
        python3 -c '
import sys, json, datetime
try:
    raw = sys.stdin.read()
    # Strip any potential progress messages before the JSON
    json_start = raw.find("{")
    if json_start != -1:
        data = json.loads(raw[json_start:])
        # Check for "hits" (standard for search) or "messages"
        items = data.get("hits", data.get("messages", []))
        for msg in items:
            id = msg.get("id", "")
            dt = datetime.datetime.fromtimestamp(msg.get("date", 0)/1000.0)
            d_str = dt.strftime("%b %d %Y")
            t_str = dt.strftime("%H:%M:%S")
            # Get sender from "recipients" where type is "f" (from)
            sender = next((r.get("fullAddressQuoted", r.get("address", "")) for r in msg.get("recipients", []) if r.get("type") == "f"), "")
            subj = msg.get("subject", "")
            print(f"{id}|{d_str}|{t_str}|{sender}|{subj}")
except Exception:
    pass
' < "$RAW_SEARCH" > "$TMP_DIR/msg_list.txt"

        MSG_COUNT=$(wc -l < "$TMP_DIR/msg_list.txt")
        [ "$MSG_COUNT" -eq 0 ] && break

        while IFS="|" read -r ID DATE TIME SENDER SUBJ; do
            if $ZMMAILBOX -z -m "$MAILBOX" dc "$ID" > /dev/null 2>&1; then
                echo "$(date '+%b %d %Y - %H:%M:%S') [AUTO][DELETE][$MAILBOX] ID:$ID | DATE:$DATE | TIME:$TIME | SENDER:$SENDER | INFO:$SUBJ | STATUS:OK" >> "$LOG_FILE"
                TOTAL_DELETED=$((TOTAL_DELETED + 1))
            else
                echo "$(date '+%b %d %Y - %H:%M:%S') [AUTO][DELETE][$MAILBOX] ID:$ID | DATE:$DATE | TIME:$TIME | SENDER:$SENDER | INFO:$SUBJ | STATUS:FAILED" >> "$LOG_FILE"
                TOTAL_FAILED=$((TOTAL_FAILED + 1))
            fi
        done < "$TMP_DIR/msg_list.txt"
    done
    echo "   [AUTO][SUMMARY] Business Items -> Deleted: $TOTAL_DELETED | Failed: $TOTAL_FAILED | Search: $SEARCH_STATUS" >> "$LOG_FILE"

    # --- C. System Cleanup (Detailed Audit) ---
    TOTAL_SYS_DEL=0
    TOTAL_SYS_FAIL=0
    SYS_SEARCH_ST="OK"
    
    SYS_RAW="$TMP_DIR/sys_raw.txt"
    if $ZMMAILBOX -z -m "$MAILBOX" s -l 100 -v "$QUERY_SYSTEM" > "$SYS_RAW" 2>&1; then
        # Parse results - Using Python to handle JSON output correctly
        python3 -c '
import sys, json, datetime
try:
    raw = sys.stdin.read()
    json_start = raw.find("{")
    if json_start != -1:
        data = json.loads(raw[json_start:])
        items = data.get("hits", data.get("messages", []))
        for msg in items:
            id = msg.get("id", "")
            dt = datetime.datetime.fromtimestamp(msg.get("date", 0)/1000.0)
            d_str = dt.strftime("%b %d %Y")
            t_str = dt.strftime("%H:%M:%S")
            sender = next((r.get("fullAddressQuoted", r.get("address", "")) for r in msg.get("recipients", []) if r.get("type") == "f"), "")
            subj = msg.get("subject", "")
            print(f"{id}|{d_str}|{t_str}|{sender}|{subj}")
except Exception:
    pass
' < "$SYS_RAW" > "$TMP_DIR/sys_list.txt"
        
        while IFS="|" read -r ID DATE TIME SENDER SUBJ; do
            if $ZMMAILBOX -z -m "$MAILBOX" dc "$ID" > /dev/null 2>&1; then
                echo "$(date '+%b %d %Y - %H:%M:%S') [AUTO][DELETE][SYSTEM][$MAILBOX] ID:$ID | DATE:$DATE | TIME:$TIME | SENDER:$SENDER | INFO:$SUBJ | STATUS:OK" >> "$LOG_FILE"
                TOTAL_SYS_DEL=$((TOTAL_SYS_DEL + 1))
            else
                echo "$(date '+%b %d %Y - %H:%M:%S') [AUTO][DELETE][SYSTEM][$MAILBOX] ID:$ID | DATE:$DATE | TIME:$TIME | SENDER:$SENDER | INFO:$SUBJ | STATUS:FAILED" >> "$LOG_FILE"
                TOTAL_SYS_FAIL=$((TOTAL_SYS_FAIL + 1))
            fi
        done < "$TMP_DIR/sys_list.txt"
        if [ "$(wc -l < "$TMP_DIR/sys_list.txt")" -eq 0 ]; then
             echo "   [AUTO][SYSTEM] No alerts found" >> "$LOG_FILE"
        fi
    else
        echo "   [AUTO][SYSTEM] Search FAILED for $MAILBOX" >> "$LOG_FILE"
        SYS_SEARCH_ST="FAILED"
    fi
    echo "   [AUTO][SUMMARY] System Alerts  -> Deleted: $TOTAL_SYS_DEL | Failed: $TOTAL_SYS_FAIL | Search: $SYS_SEARCH_ST" >> "$LOG_FILE"

done < "$ACCOUNTS_LIST"

# ---------- 6. CLEANUP & ROTATION ----------
echo "--------------------------------------------------" >> "$LOG_FILE"
echo "[AUTO] RUN END - $(date)" >> "$LOG_FILE"
echo "--------------------------------------------------" >> "$LOG_FILE"

find "$LOG_BASE" -name "*.log" -mtime +$LOG_KEEP_DAYS -delete
