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

# Cleanup Criteria
THRESHOLD=90        # Process accounts >= 90% quota usage
DAYS_KEEP=2        # Delete emails older than X days
LOG_KEEP_DAYS=7    # Keep logs for 7 days

# Logger
LOG_LOCAL="$HOME/zimbra_remote_cleanup.log"

# ==================================================

# Calculate Date
BEFORE_DATE=$(date -d "$DAYS_KEEP days ago" "+%m/%d/%Y")

echo "=== ZIMBRA REMOTE CLEANUP ==="
echo "Select Server Connection:"
echo "1) LOCAL  ($SERVER_LOCAL)"
echo "2) PUBLIC ($SERVER_PUBLIC)"
echo "-----------------------------"
read -n 1 -r -p "Choice [1/2]: " CHOICE
echo # Newline after input

case "$CHOICE" in
  1)
    SERVER="$SERVER_LOCAL"
    ;;
  2)
    SERVER="$SERVER_PUBLIC"
    ;;
  *)
    echo "Invalid choice. Exiting."
    exit 1
    ;;
esac

echo
echo "Target    : $SERVER"
echo "Threshold : $THRESHOLD%"
echo "Before    : $BEFORE_DATE"
echo "-----------------------------"

# Start without asking again (since they just selected the server)
# or keeps the confirmation? The user asked to "select ip ... without enter".
# I'll keep the confirmation for safety but minimal.

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
    if ! zmmailbox -z -m \$MAILBOX s -l 50 \"\$QUERY_BISNIS\" > \"\$TMP_DIR/raw_search.txt\" 2>&1; then
       echo \"   [ERROR] zmmailbox search failed for \$MAILBOX\" | tee -a \"\$LOG_FILE\"
       break
    fi
    
    # Check if empty or no results
    if grep -q \"No results found\" \"\$TMP_DIR/raw_search.txt\"; then
       break
    fi

    grep -E \"^[[:space:]]*-?[0-9]+\.\" \"\$TMP_DIR/raw_search.txt\" | tr -s \" \" | awk '\''{ 
      # Robustly find ID: it is the first field that looks like a number (can be -)
      id = (\$2 ~ /^-?[0-9]+\$/) ? \$2 : \$3;
      # Folder is 1 col after ID, Sender is 1 col after Folder
      s_idx = (id == \$2) ? 4 : 5;
      date = \$(NF-1); time = \$NF; 
      sender = \$s_idx;
      subject = \"\"; for(i=s_idx+1; i<=(NF-2); i++) subject = subject (subject==\"\"?\"\":\" \") \$i;
      printf \"%s|%s|%s|%s|%s\\n\", id, date, time, sender, subject;
    }'\'' > \"\$TMP_LIST\"
      
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
         echo \"\$(date '+%b %d %Y - %H:%M:%S') [DELETE][\$MAILBOX] ID:\$DISPLAY_ID | DATE: \$DATE | TIME: \$TIME | SENDER: \$SENDER | INFO: \$SUBJECT | STATUS:OK\" >> \"\$LOG_FILE\"
         TOTAL_DELETED=\$((TOTAL_DELETED + 1))
      else
         echo \"\$(date '+%b %d %Y - %H:%M:%S') [DELETE][\$MAILBOX] ID:\$DISPLAY_ID | DATE: \$DATE | TIME: \$TIME | SENDER: \$SENDER | INFO: \$SUBJECT | STATUS:FAILED\" >> \"\$LOG_FILE\"
      fi
      draw_bar \"\$CUR_MSG\" \"\$COUNT\"
    done < \"\$TMP_LIST\"
    echo # Newline after bar
  done
  echo \"   [SUMMARY] Business Items -> Deleted: \$TOTAL_DELETED | Search: OK\" >> \"\$LOG_FILE\"

  # SYSTEM MAILS
  > \"\$TMP_LIST\"
  if zmmailbox -z -m \$MAILBOX s -l 500 \"\$QUERY_SYSTEM\" > \"\$TMP_DIR/raw_sys.txt\" 2>&1; then
    grep -E \"^[[:space:]]*-?[0-9]+\.\" \"\$TMP_DIR/raw_sys.txt\" | tr -s \" \" | awk '\''{ 
      id = (\$2 ~ /^-?[0-9]+\$/) ? \$2 : \$3;
      s_idx = (id == \$2) ? 4 : 5;
      date = \$(NF-1); time = \$NF; 
      sender = \$s_idx;
      subject = \"\"; for(i=s_idx+1; i<=(NF-2); i++) subject = subject (subject==\"\"?\"\":\" \") \$i;
      printf \"%s|%s|%s|%s|%s\\n\", id, date, time, sender, subject;
    }'\'' > \"\$TMP_LIST\"

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
           echo \"\$(date '+%b %d %Y - %H:%M:%S') [DELETE][SYSTEM][\$MAILBOX] ID:\$DISPLAY_ID | DATE: \$DATE | TIME: \$TIME | SENDER: \$SENDER | INFO: \$SUBJECT | STATUS:OK\" >> \"\$LOG_FILE\"
           TOTAL_SYS_DEL=\$((TOTAL_SYS_DEL + 1))
        else
           echo \"\$(date '+%b %d %Y - %H:%M:%S') [DELETE][SYSTEM][\$MAILBOX] ID:\$DISPLAY_ID | DATE: \$DATE | TIME: \$TIME | SENDER: \$SENDER | INFO: \$SUBJECT | STATUS:FAILED\" >> \"\$LOG_FILE\"
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
