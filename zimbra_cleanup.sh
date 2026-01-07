#!/bin/bash

# ==================================================
# ZIMBRA MAILBOX CLEANUP
# SAFE LOOP : CHECK -> DELETE -> CHECK
# LOG HARIAN, NON-INFINITE
# ==================================================

# ---------- CONFIG ----------
DOMAIN="ptmjl.co.id"
DEFAULT_SERVER="192.168.4.5"
DEFAULT_PORT=22
PAGE_SIZE=25
BAR_WIDTH=20

SSH_USER="root"
SSH_KEY="$HOME/.ssh/zimbra_admin"
SSH_PUB_KEY="$HOME/.ssh/zimbra_admin.pub"

# ---------- INPUT ----------
echo "=== ZIMBRA MAILBOX CLEANUP ==="
echo

read -p "Mailbox username (tanpa domain)    : " USERNAME
read -p "Before date (MM/DD/YYYY) [bisnis] : " BEFORE_DATE
read -p "Server IP [$DEFAULT_SERVER]       : " SERVER
read -p "SSH Port [$DEFAULT_PORT]          : " SSH_PORT
read -p "SSH key owner/name (mis: siswo)   : " KEY_NAME

SERVER="${SERVER:-$DEFAULT_SERVER}"
SSH_PORT="${SSH_PORT:-$DEFAULT_PORT}"
MAILBOX="${USERNAME}@${DOMAIN}"

# ---------- VALIDATION ----------
if [ -z "$USERNAME" ] || [ -z "$BEFORE_DATE" ] || [ -z "$KEY_NAME" ]; then
  echo "ERROR: input wajib diisi"
  exit 1
fi

# ---------- SSH KEY ----------
KEY_COMMENT="${KEY_NAME}@$(hostname)"

if [ ! -f "$SSH_KEY" ] || [ ! -f "$SSH_PUB_KEY" ]; then
  ssh-keygen -t ed25519 -f "$SSH_KEY" -C "$KEY_COMMENT" -N ""
fi

ssh -p "$SSH_PORT" -o BatchMode=yes -i "$SSH_KEY" ${SSH_USER}@${SERVER} "echo ok" >/dev/null 2>&1 \
  || ssh-copy-id -p "$SSH_PORT" -i "$SSH_PUB_KEY" ${SSH_USER}@${SERVER}

# ---------- INFO ----------
echo
echo "======================================="
echo " ZIMBRA MAILBOX CLEANUP"
echo "---------------------------------------"
echo " Server : $SERVER:$SSH_PORT"
echo " Akun   : $MAILBOX"
echo " Before : $BEFORE_DATE"
echo "======================================="

read -p "Proceed? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-y}
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && exit 0

# ==================================================
# EXECUTION (REMOTE)
# ==================================================
ssh -tt -p "$SSH_PORT" -i "$SSH_KEY" ${SSH_USER}@${SERVER} "
su - zimbra -c '

# ---------- LOG & TMP ----------
LOG_BASE=\"/opt/zimbra/.log-zimbra-cleanup\"
LOG_FILE=\"\$LOG_BASE/cleanup_\$(date +%Y%m%d).log\"
TMP_DIR=\"\$LOG_BASE/tmp_\$(date +%H%M%S)_\$\$\"
TMP_LIST=\"\$TMP_DIR/list.txt\"

mkdir -p \"\$TMP_DIR\"
mkdir -p \"\$LOG_BASE\"
> \"\$TMP_LIST\"

RUN_START=\$(date +%H:%M:%S)

echo \"==================================================\" >> \"\$LOG_FILE\"
echo \"RUN START - \$RUN_START\" >> \"\$LOG_FILE\"
echo \"==================================================\" >> \"\$LOG_FILE\"
echo \"[INFO] Mailbox : $MAILBOX\" >> \"\$LOG_FILE\"
echo \"[INFO] Host    : \$(hostname)\" >> \"\$LOG_FILE\"
echo \"--------------------------------------------------\" >> \"\$LOG_FILE\"

PAGE_SIZE=$PAGE_SIZE
BAR_WIDTH=$BAR_WIDTH
DELIM=\"|\"

QUERY_BISNIS=\"(subject:\\\"data penjualan\\\" OR content:\\\"data penjualan\\\" OR \
subject:\\\"rekap doc\\\" OR content:\\\"rekap doc\\\" OR \
subject:\\\"rekap rhpp\\\" OR content:\\\"rekap rhpp\\\" OR \
subject:\\\"laporan kasir\\\" OR content:\\\"laporan kasir\\\" OR \
subject:\\\"rekap penjualan\\\" OR content:\\\"rekap penjualan\\\") before:\\\"$BEFORE_DATE\\\"\"

QUERY_SYSTEM=\"(subject:\\\"quota warning\\\" AND content:\\\"mailbox size has reached\\\")\"

# ---------- FUNCTION ----------
draw_bar() {
  local c=\$1 t=\$2
  local f=\$(( c * BAR_WIDTH / t ))
  local e=\$(( BAR_WIDTH - f ))
  printf \"\\r[DELETE] [%s%s] %d/%d\" \
    \"\$(printf \"%*s\" \$f | tr \" \" \"#\")\" \
    \"\$(printf \"%*s\" \$e | tr \" \" \"-\")\" \
    \"\$c\" \"\$t\"
}

# ---------- LOOP CLEANUP ----------
TOTAL_DELETED=0
TOTAL_FAILED=0

while true; do
  > \"\$TMP_LIST\"

  zmmailbox -z -m $MAILBOX s -l \$PAGE_SIZE \"\$QUERY_BISNIS\" \
    | awk \"NR>4 {print \\\$2 \\\"|\\\" substr(\\\$0, index(\\\$0, \\\$4))}\" \
    | grep -E \"^-?[0-9]+\\|\" >> \"\$TMP_LIST\"

  COUNT=\$(wc -l < \"\$TMP_LIST\")

  [ \"\$COUNT\" -eq 0 ] && break

  echo \"[CHECK] Found \$COUNT email(s)\" | tee -a \"\$LOG_FILE\"

  CUR=0
  while IFS=\"\$DELIM\" read -r ID SUBJECT; do
    CUR=\$((CUR + 1))
    if zmmailbox -z -m $MAILBOX dc \"\$ID\"; then
      echo \"[DELETE] id \$ID | subject \$SUBJECT | OK\" >> \"\$LOG_FILE\"
      TOTAL_DELETED=\$((TOTAL_DELETED + 1))
    else
      echo \"[DELETE] id \$ID | subject \$SUBJECT | FAILED\" >> \"\$LOG_FILE\"
      TOTAL_FAILED=\$((TOTAL_FAILED + 1))
    fi
    draw_bar \"\$CUR\" \"\$COUNT\"
  done < \"\$TMP_LIST\"

  echo
done

# ---------- SYSTEM MAIL ----------
> \"\$TMP_LIST\"
zmmailbox -z -m $MAILBOX s -l 1000 \"\$QUERY_SYSTEM\" \
  | awk \"NR>4 {print \\\$2 \\\"|\\\" substr(\\\$0, index(\\\$0, \\\$4))}\" \
  | grep -E \"^-?[0-9]+\\|\" >> \"\$TMP_LIST\"

SYS_COUNT=\$(wc -l < \"\$TMP_LIST\")

if [ \"\$SYS_COUNT\" -gt 0 ]; then
  echo \"[CHECK][SYSTEM] Found \$SYS_COUNT email(s)\" | tee -a \"\$LOG_FILE\"
  while IFS=\"\$DELIM\" read -r ID SUBJECT; do
    zmmailbox -z -m $MAILBOX dc \"\$ID\" \
      && echo \"[DELETE][SYSTEM] id \$ID | OK\" >> \"\$LOG_FILE\" \
      || echo \"[DELETE][SYSTEM] id \$ID | FAILED\" >> \"\$LOG_FILE\"
  done < \"\$TMP_LIST\"
fi

# ---------- SUMMARY ----------
echo \"--------------------------------------------------\" >> \"\$LOG_FILE\"
echo \"[SUMMARY] Deleted : \$TOTAL_DELETED\" >> \"\$LOG_FILE\"
echo \"[SUMMARY] Failed  : \$TOTAL_FAILED\" >> \"\$LOG_FILE\"
echo \"RUN END - \$(date +%H:%M:%S)\" >> \"\$LOG_FILE\"
echo \"==================================================\" >> \"\$LOG_FILE\"

rm -rf \"\$TMP_DIR\"
'
"

echo "=== DONE ==="
