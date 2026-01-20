# Zimbra Mailbox Cleanup Suite
==========================

Kumpulan script untuk membersihkan email lama di Zimbra secara otomatis maupun manual dengan filter khusus (data penjualan/laporan) dan pesan sistem "quota warning". Dirancang untuk menjaga ketersediaan storage mailbox agar tidak melebihi kuota.

## 🛠 Daftar Script

### 1. `zimbra_auto_cleanup.sh` (Otomatis/Cron)
Script utama yang dirancang untuk berjalan di server Zimbra melalui Cron. Sangat stabil dan memiliki fitur pengamanan tingkat tinggi.
- **Fitur**: Anti-overlap (Locking), Automatical Log Rotation (7 hari), Detailed Audit Logs, Auto-switch user (root to zimbra), Trap cleanup.
- **Cara Pakai**:
  1. Letakkan di server Zimbra (contoh: `/opt/zimbra/scripts/`).
  2. Berikan izin: `chown zimbra:zimbra zimbra_auto_cleanup.sh && chmod +x zimbra_auto_cleanup.sh`.
  3. Tambah ke crontab user zimbra: `00 01 * * * /opt/zimbra/scripts/zimbra_auto_cleanup.sh > /dev/null 2>&1`.

### 2. `zimbra_remote_cleanup.sh` (Manual/Interaktif)
Script interaktif untuk dijalankan dari laptop/PC admin. Berguna untuk pembersihan massal secara manual atau backup jika script auto gagal.
- **Fitur**: Pilihan server (Local/Public), Progress Bar, Konfirmasi sebelum eksekusi, Audit detail per-ID.
- **Cara Pakai**:
  1. Pastikan SSH Key sudah setup.
  2. Jalankan: `./zimbra_remote_cleanup.sh`.
  3. Pilih koneksi server dan konfirmasi eksekusi.

## 🔑 Keamanan & SSH Key Setup (Penting)
Agar script bisa berjalan tanpa mengetik password (terutama untuk `zimbra_remote_cleanup.sh`), ikuti langkah setup key ini untuk tim admin/junior:

1.  **Generate Private & Public Key** (di laptop admin):
    ```bash
    ssh-keygen -t ed25519 -f ~/.ssh/zimbra_admin -C "admin_name@ptmjl"
    ```
    *Gunakan passphrase kosong jika ingin benar-benar otomatis.*

2.  **Copy Public Key ke Server Zimbra**:
    ```bash
    ssh-copy-id -i ~/.ssh/zimbra_admin.pub root@103.135.1.51
    ```
    *Masukkan password root server sekali ini saja.*

3.  **Verifikasi Akses**:
    ```bash
    ssh -i ~/.ssh/zimbra_admin root@103.135.1.51 "echo 'Koneksi Sukses'"
    ```

## 🔍 Cara Kerja
Script akan melakukan scanning terhadap akun yang penggunaan storage-nya `>= 90%` (default), kemudian menghapus email:
...
- **Bisnis**: Subject/content berisi kata kunci (penjualan, rekap doc, laporan kasir, dll) yang berumur **lebih dari 2 hari**.
- **Sistem**: Email pemberitahuan kuota (*quota warning*).
- **Sampah**: Mengosongkan folder `/Trash` secara otomatis.

## 📂 Lokasi Penting di Server (ZOIR Ready)
- **Log Histori**: `/opt/zimbra/.log-zimbra-cleanup/`
  - `zimbra_cleanup_YYYYMMDD.log`: Log gabungan dari semua aktivitas cleanup.
- **Identifikasi Log**:
  - `[AUTO]`: Baris log ini dihasilkan oleh script cron otomatis (`zimbra_auto_cleanup.sh`).
  - `[REMOTE]`: Baris log ini dihasilkan oleh script manual dari laptop (`zimbra_remote_cleanup.sh`).
- **Temporary Workspace**: `/opt/zimbra/.log-zimbra-cleanup/tmp_*` (Dibersihkan otomatis).

## ⚠️ Catatan Keamanan
- Script hanya menghapus isi email dalam folder tertentu berdasarkan kriteria. **Akun user tidak akan dihapus.**
- Dilengkapi dengan *parsing* ID negatif untuk memastikan item di shared folder/drafts tetap bisa dibersihkan.
- Disarankan melakukan pengecekan log secara berkala.
