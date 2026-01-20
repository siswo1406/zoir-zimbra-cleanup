# ZOIR: Zimbra Operational Insight & Reporting - Cleanup Suite 🚀

![Shell Script](https://img.shields.io/badge/Shell_Script-121011?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Python](https://img.shields.io/badge/Python-3776AB?style=for-the-badge&logo=python&logoColor=white)
![Zimbra](https://img.shields.io/badge/Zimbra-C2185B?style=for-the-badge&logo=zimbra&logoColor=white)

**ZOIR Cleanup Suite** is a high-reliability administration toolkit designed for Zimbra Collaboration Servers. It automates the maintenance of mailbox storage by targeting specific operational emails (reports, automated logs) and system notifications, ensuring high availability and storage efficiency.

---

## 🌟 Key Features

-   **Dual Mode Execution**:
    -   **`[AUTO]` Mode**: Fully automated server-side cleanup via Cron, featuring robust file-locking (`flock`) to prevent concurrent execution conflicts.
    -   **`[REMOTE]` Mode**: Interactive terminal-based management from a workstation, including real-time progress bars and confirmation workflows.
-   **Intelligent Parsing**: Leverages **Python 3** as an embedded JSON parser to extract complete sender metadata (Display Names + Email Addresses) from verbose `zmmailbox` output.
-   **Unified Logging (ZOIR standard)**: All activities are logged into a single, standardized format, ready for ingestion into monitoring dashboards or business intelligence tools.
-   **Comprehensive Auditing**: Every deletion is recorded with unique Message IDs, precise timestamps, and full sender information.
-   **Automation Safety**: Integrated "housekeeping" routines to clean up temporary workspace files and manage log rotation.

---

## 🛠 Technical Stack

-   **Core Engine**: Bash (GNU/Linux)
-   **Data Processing**: Python 3.x (JSON & Timestamp handling)
-   **Communication**: OpenSSH with Key-based authentication
-   **Mail Server API**: Zimbra `zmprov` & `zmmailbox`

---

## 🔍 How It Works

The suite identifies accounts exceeding a defined storage threshold (e.g., 90%). It then scans for and removes items matching specific criteria:
-   **Business Reports**: Messages older than 2 days matching keywords like "data penjualan", "rekap", or "laporan".
-   **System Alerts**: Automatic cleanup of persistent "Mailbox Quota Warning" notifications.
-   **Trash Management**: Automatic emptying of the `/Trash` folder to reclaim space instantly.

---

## 🚀 Getting Started

### Prerequisites

1.  Python 3 installed on the Zimbra server.
2.  SSH Key-based authentication established between your workstation and the server.

### Setup

1.  **Clone the repository**:
    ```bash
    git clone https://github.com/siswo1406/zoir-zimbra-cleanup.git
    cd zoir-zimbra-cleanup
    ```

2.  **Configuration**:
    Edit `zimbra_remote_cleanup.sh` and set your server details:
    ```bash
    SERVER_LOCAL="xxx.xxx.xxx.xxx"  # Change to your Local Zimbra IP
    SERVER_PUBLIC="xxx.xxx.xxx.xxx" # Change to your Public Zimbra IP
    SSH_KEY="~/.ssh/your_private_key"
    ```

3.  **Deploy Auto-Cleanup**:
    Copy `zimbra_auto_cleanup.sh` to `/opt/zimbra/scripts/` on the server and add it to the `zimbra` user's crontab:
    ```bash
    # Run every day at 12:01 PM
    01 12 * * * /opt/zimbra/scripts/zimbra_auto_cleanup.sh > /dev/null 2>&1
    ```

---

## 📂 Unified Logging Output

The suite generates structured logs at `/opt/zimbra/.log-zimbra-cleanup/zimbra_cleanup_YYYYMMDD.log`:
```text
Jan 20 2026 - 19:42:04 [AUTO][PROCESS] user@domain.com (Usage: 96%)
Jan 20 2026 - 19:42:13 [AUTO][DELETE][user@domain.com] ID:-2460 | DATE:Jan 17 2026 | TIME:12:58:47 | SENDER:"NAME" <sender@domain.com> | INFO:REKAP RHPP | STATUS:OK
Jan 20 2026 - 19:30:33 [REMOTE] RUN START - Tue Jan 20 2026
```

---

## ⚖️ License
Distributed under the MIT License. See `LICENSE` for more information.

Developed by **Siswo** | *Zimbra Operational Insight & Reporting (ZOIR) Project*
