#!/bin/bash

# ==================================================
# ZIMBRA REMOTE CLEANUP (RUN FROM LAPTOP)
# ==================================================

# ---------- CONFIG ----------

# Server Options
SERVER_LOCAL="192.168.4.5"
SERVER_PUBLIC="103.135.1.51" # IP Public Server Zimbra

SSH_PORT=22
SSH_USER="root"
SSH_KEY="$HOME/.ssh/zimbra_admin"

# Cleanup Options
THRESHOLD=90        # Process accounts >= 90% usage
BEFORE_DATE=$(date -d "2 days ago" "+%m/%d/%Y")
LOG_KEEP_DAYS=7     # Keep logs for 7 days

# ---------- 0. PRE-FLIGHT ----------

# Ensure ssh key exists
if [ ! -f "$SSH_KEY" ]; then
  echo "[ERROR] SSH Key not found: $SSH_KEY"
  exit 1
fi

# Select Server
echo "Select Zimbra Server:"
echo "1) LOCAL  ($SERVER_LOCAL)"
echo "2) PUBLIC ($SERVER_PUBLIC)"
read -p "Option [1-2]: " SERVER_OPT
if [ "$SERVER_OPT" == "2" ]; then
  SERVER=$SERVER_PUBLIC
else
  SERVER=$SERVER_LOCAL
fi

LOG_LOCAL="remote_run_$(date +%Y%m%d).log"

echo "-----------------------------"
echo "Target Server : $SERVER"
echo "Threshold     : $THRESHOLD%"
echo "Before Date   : $BEFORE_DATE"
echo "-----------------------------"

echo "[LOCAL] Connecting to $SERVER..." | tee -a "$LOG_LOCAL"

# Wrapper to execute logic on remote server
# We inject local variables directly into the command string to avoid 'su -' environment clearing issues
ssh -tt -p "$SSH_PORT" -i "$SSH_KEY" ${SSH_USER}@${SERVER} "
su - zimbra -c '
# Values injected from local laptop shell
THRESHOLD=$THRESHOLD
CHECK_DATE=\"$BEFORE_DATE\"
LOG_KEEP_DAYS=$LOG_KEEP_DAYS

# Inherited or dynamic
LOG_BASE=\"/opt/zimbra/.log-zimbra-cleanup\"
LOG_FILE=\"\$LOG_BASE/remote_cleanup_\$(date +%Y%m%d).log\"
LOCK_FILE=\"/tmp/zimbra_remote_cleanup.lock\"

# Locking - ensure single instance on server
exec 200>\"\$LOCK_FILE\"
if ! flock -n 200; then
  echo \"[REMOTE] [ERROR] Another remote cleanup instance is already running on server.\"
  exit 1
fi
rm -rf \"\$LOG_BASE\"/tmp_remote_* 2>/dev/null

TMP_DIR=\"\$LOG_BASE/tmp_remote_\$(date +%H%M%S)_\$\$\"
ACCOUNTS_LIST=\"\$TMP_DIR/accounts_over_quota.txt\"
TMP_LIST=\"\$TMP_DIR/msg_list.txt\"

mkdir -p \"\$TMP_DIR\"
mkdir -p \"\$LOG_BASE\"

# Trap Functions
on_cancel() {
  echo \"[ABORT] User cancelled execution at \$(date)\" >> \"\$LOG_FILE\"
  cleanup
  exit 1
}

cleanup() {
  rm -rf \"\$TMP_DIR\"
  # Close lock
  exec 200>&-
}

trap cleanup EXIT
trap on_cancel INT TERM HUP

# Auto-clean old temp folders (older than 1 day) from previous aborted runs
find \"\$LOG_BASE\" -maxdepth 1 -type d -name \"tmp_remote_*\" -mtime +0 -exec rm -rf {} + 2>/dev/null

echo \"--------------------------------------------------\" >> \"\$LOG_FILE\"
echo \"REMOTE RUN START - \$(date)\" >> \"\$LOG_FILE\"
echo \"Threshold: \$THRESHOLD%\" >> \"\$LOG_FILE\"
echo \"Before: \$CHECK_DATE\" >> \"\$LOG_FILE\"
echo \"--------------------------------------------------\" >> \"\$LOG_FILE\"

# ---------- 1. IDENTIFY FULL ACCOUNTS ----------
echo \"[REMOTE] Scanning accounts over \$THRESHOLD% quota...\"

# zmprov gqu localhost format: user@domain quota_bytes used_bytes
zmprov gqu localhost | awk -v limit=\"\$THRESHOLD\" '\''
BEGIN { count = 0; }
{
  u = \$1;
  quota = \$2;
  used = \$3;

  if (quota > 0) {
    percent = (used / quota) * 100;
    if (percent >= limit) {
      printf \"%d|%s\\n\", percent, u;
    }
  }
}
'\'' | sort -nr > \"\$TMP_DIR/raw_list.txt\"

# Extract just emails for processing
cut -d \"|\" -f2 \"\$TMP_DIR/raw_list.txt\" > \"\$ACCOUNTS_LIST\"

COUNT_ACCOUNTS=\$(wc -l < \"\$ACCOUNTS_LIST\")

if [ \"\$COUNT_ACCOUNTS\" -eq 0 ]; then
  echo \"[REMOTE] No accounts to clean.\"
  rm -rf \"\$TMP_DIR\"
  exit 0
fi

echo \"[REMOTE] Found \$COUNT_ACCOUNTS account(s) to process:\"
echo \"--------------------------------------------------\"
echo \"USAGE  | ACCOUNT\"
echo \"--------------------------------------------------\"
awk -F \"|\" '\''{ printf \"%3d%%   | %s\\n\", \$1, \$2 }'\'' \"\$TMP_DIR/raw_list.txt\" | head -n 20
[ \"\$COUNT_ACCOUNTS\" -gt 20 ] && echo \"... and \$((COUNT_ACCOUNTS - 20)) more.\"
echo \"--------------------------------------------------\"

# ---------- CONFIRMATION ----------
echo
echo \"[WARNING] ACTION: DELETE EMAILS inside these \$COUNT_ACCOUNTS accounts.\"
echo \"Target Emails : Containing keywords (e.g. \\\"data penjualan\\\")\"
echo \"Condition     : OLDER THAN \$CHECK_DATE\"
echo \"NOTE          : The ACCOUNTS themselves will NOT be deleted.\"
echo
read -p \"Are you sure you want to proceed? [Y/n]: \" CONFIRM
CONFIRM=\${CONFIRM:-y}
if [[ ! \"\$CONFIRM\" =~ ^[Yy]$ ]]; then
  echo \"Cancelled.\"
  rm -rf \"\$TMP_DIR\"
  exit 0
fi
echo

# ---------- KEYWORDS QUERY ----------
QUERY_BISNIS=\"(subject:\\\"data penjualan\\\" OR content:\\\"data penjualan\\\" OR subject:\\\"rekap doc\\\" OR content:\\\"rekap doc\\\" OR subject:\\\"doc gabungan\\\" OR content:\\\"doc gabungan\\\" OR subject:\\\"rekap rhpp\\\" OR content:\\\"rekap rhpp\\\" OR subject:\\\"laporan kasir\\\" OR content:\\\"laporan kasir\\\" OR subject:\\\"rekap penjualan\\\" OR content:\\\"rekap penjualan\\\") before:\\\"\$CHECK_DATE\\\"\"

QUERY_SYSTEM=\"(subject:\\\"quota warning\\\" AND content:\\\"mailbox size has reached\\\")\"

DELIM=\"|\"

# ---------- HELPER ----------
draw_bar() {
  local c=\$1 t=\$2
  local w=20
  local f=\$(( c * w / t ))
  local e=\$(( w - f ))
  # Use printf \\r to overwrite line
  printf \"\\r   [DELETE] [%s%s] %d/%d\" \
    \"\$(printf \"%*s\" \$f | tr \" \" \"#\")\" \
    \"\$(printf \"%*s\" \$e | tr \" \" \"-\")\" \
    \"\$c\" \"\$t\"
}

# ---------- 2. LOOP PROCESS ----------
CURRENT_ACC=0
while read -r MAILBOX; do
  CURRENT_ACC=\$((CURRENT_ACC + 1))
  echo \"[REMOTE] (\$CURRENT_ACC/\$COUNT_ACCOUNTS) Processing: \$MAILBOX\"
  
  TOTAL_DELETED=0
  
  # ---------- 0. EMPTY TRASH ----------
  echo \"   [TRASH] Emptying /Trash folder...\"
  if zmmailbox -z -m \$MAILBOX ef /Trash > /dev/null 2>&1; then
     echo \"[TRASH][\$MAILBOX] Status: OK\" >> \"\$LOG_FILE\"
  else
     echo \"[TRASH][\$MAILBOX] Status: FAILED/EMPTY\" >> \"\$LOG_FILE\"
  fi
  
  while true; do
    > \"\$TMP_LIST\"
    
    # Search: Save RAW output to file first
    if ! zmmailbox -z -m \$MAILBOX s -l 50 -v \"\$QUERY_BISNIS\" > \"\$TMP_DIR/raw_search.txt\" 2>&1; then
       echo \"   [ERROR] zmmailbox search failed for \$MAILBOX\" | tee -a \"\$LOG_FILE\"
       break
    fi
    
    # Parse results - Using Python to handle JSON output correctly
    python3 -c '\''
import sys, json, datetime
try:
    raw = sys.stdin.read()
    json_start = raw.find(\"{\")
    if json_start != -1:
        data = json.loads(raw[json_start:])
        items = data.get(\"hits\", data.get(\"messages\", []))
        for msg in items:
            id = msg.get(\"id\", \"\")
            dt = datetime.datetime.fromtimestamp(msg.get(\"date\", 0)/1000.0)
            d_str = dt.strftime(\"%b %d %Y\")
            t_str = dt.strftime(\"%H:%M:%S\")
            sender = next((r.get(\"fullAddressQuoted\", r.get(\"address\", \"\")) for r in msg.get(\"recipients\", []) if r.get(\"type\") == \"f\"), \"\")
            subj = msg.get(\"subject\", \"\")
            print(f\"{id}|{d_str}|{t_str}|{sender}|{subj}\")
except Exception:
    pass
'\'' < \"\$TMP_DIR/raw_search.txt\" > \"\$TMP_LIST\"
      
    COUNT=\$(wc -l < \"\$TMP_LIST\")
    [ \"\$COUNT\" -eq 0 ] && break

    echo \"   Found \$COUNT email(s)...\"
    CUR_MSG=0
    
    # Execute Delete
    while IFS=\"|\" read -r ID DATE TIME SENDER SUBJECT; do
      CUR_MSG=\$((CUR_MSG + 1))
      DISPLAY_ID=\${ID#-} # Strip leading minus for display
      
      # DELETE ITEM
      if zmmailbox -z -m \$MAILBOX dc \"\$ID\"; then
         echo \"\$(date '\''+%b %d %Y - %H:%M:%S'\'') [DELETE][\$MAILBOX] ID:\$DISPLAY_ID | DATE: \$DATE | TIME: \$TIME | SENDER: \$SENDER | INFO: \$SUBJECT | STATUS:OK\" >> \"\$LOG_FILE\"
         TOTAL_DELETED=\$((TOTAL_DELETED + 1))
      else
         echo \"\$(date '\''+%b %d %Y - %H:%M:%S'\'') [DELETE][\$MAILBOX] ID:\$DISPLAY_ID | DATE: \$DATE | TIME: \$TIME | SENDER: \$SENDER | INFO: \$SUBJECT | STATUS:FAILED\" >> \"\$LOG_FILE\"
      fi
      draw_bar \"\$CUR_MSG\" \"\$COUNT\"
    done < \"\$TMP_LIST\"
    echo # Newline after bar
  done
  echo \"   [SUMMARY] Business Items -> Deleted: \$TOTAL_DELETED | Search: OK\" >> \"\$LOG_FILE\"

  # SYSTEM MAILS
  > \"\$TMP_LIST\"
  if zmmailbox -z -m \$MAILBOX s -l 500 -v \"\$QUERY_SYSTEM\" > \"\$TMP_DIR/raw_sys.txt\" 2>&1; then
    # Parse system alerts
    python3 -c '\''
import sys, json, datetime
try:
    raw = sys.stdin.read()
    json_start = raw.find(\"{\")
    if json_start != -1:
        data = json.loads(raw[json_start:])
        items = data.get(\"hits\", data.get(\"messages\", []))
        for msg in items:
            id = msg.get(\"id\", \"\")
            dt = datetime.datetime.fromtimestamp(msg.get(\"date\", 0)/1000.0)
            d_str = dt.strftime(\"%b %d %Y\")
            t_str = dt.strftime(\"%H:%M:%S\")
            sender = next((r.get(\"fullAddressQuoted\", r.get(\"address\", \"\")) for r in msg.get(\"recipients\", []) if r.get(\"type\") == \"f\"), \"\")
            subj = msg.get(\"subject\", \"\")
            print(f\"{id}|{d_str}|{t_str}|{sender}|{subj}\")
except Exception:
    pass
'\'' < \"\$TMP_DIR/raw_sys.txt\" > \"\$TMP_LIST\"

    SYS_COUNT=\$(wc -l < \"\$TMP_LIST\")
    if [ \"\$SYS_COUNT\" -gt 0 ]; then
      echo \"   [SYSTEM] Found \$SYS_COUNT notification(s)...\"
      CUR_SYS=0
      TOTAL_SYS_DEL=0
      TOTAL_SYS_FAIL=0
      while IFS=\"|\" read -r ID DATE TIME SENDER SUBJECT; do
        CUR_SYS=\$((CUR_SYS + 1))
        DISPLAY_ID=\${ID#-}
        
        if zmmailbox -z -m \$MAILBOX dc \"\$ID\"; then
           echo \"\$(date '\''+%b %d %Y - %H:%M:%S'\'') [DELETE][SYSTEM][\$MAILBOX] ID:\$DISPLAY_ID | DATE: \$DATE | TIME: \$TIME | SENDER: \$SENDER | INFO: \$SUBJECT | STATUS:OK\" >> \"\$LOG_FILE\"
           TOTAL_SYS_DEL=\$((TOTAL_SYS_DEL + 1))
        else
           echo \"\$(date '\''+%b %d %Y - %H:%M:%S'\'') [DELETE][SYSTEM][\$MAILBOX] ID:\$DISPLAY_ID | DATE: \$DATE | TIME: \$TIME | SENDER: \$SENDER | INFO: \$SUBJECT | STATUS:FAILED\" >> \"\$LOG_FILE\"
           TOTAL_SYS_FAIL=\$((TOTAL_SYS_FAIL + 1))
        fi
        draw_bar \"\$CUR_SYS\" \"\$SYS_COUNT\"
      done < \"\$TMP_LIST\"
      echo
      echo \"   -> System Deleted: \$TOTAL_SYS_DEL | Failed: \$TOTAL_SYS_FAIL\"
      echo \"   [SUMMARY] System Alerts  -> Deleted: \$TOTAL_SYS_DEL | Failed: \$TOTAL_SYS_FAIL | Search: OK\" >> \"\$LOG_FILE\"
    else
      echo \"   [SYSTEM] No alerts found\"
      echo \"   [SUMMARY] System Alerts  -> No alerts found\" >> \"\$LOG_FILE\"
    fi
  else
    echo \"   [SYSTEM] Search FAILED for \$MAILBOX\" | tee -a \"\$LOG_FILE\"
    echo \"   [SUMMARY] System Alerts  -> Search: FAILED\" >> \"\$LOG_FILE\"
  fi

  echo \"   -> Deleted Total: \$TOTAL_DELETED items\"
  echo \"[REMOTE] \$MAILBOX | Deleted: \$TOTAL_DELETED\" >> \"\$LOG_FILE\"

done < \"\$ACCOUNTS_LIST\"

# Rotate ALL logs (auto, remote, and manual) in the base directory
find \"\$LOG_BASE\" -name \"*.log\" -mtime +\$LOG_KEEP_DAYS -delete

rm -rf \"\$TMP_DIR\"
'
"

echo "=== DONE ==="
