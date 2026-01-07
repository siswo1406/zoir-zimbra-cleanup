Zimbra Mailbox Cleanup
======================

Script interaktif untuk membersihkan email lama di Zimbra dengan pola pencarian khusus (data penjualan/laporan) dan pesan sistem "quota warning". Proses berjalan aman dengan loop cek -> hapus -> cek serta pencatatan log.

Fitur
- Generate/cek SSH key otomatis (`~/.ssh/zimbra_admin`) dan copy ke server target.
- Menanyakan input penting: username mailbox (tanpa domain), batas tanggal, IP/port server, dan pemilik key.
- Pencarian bertahap dengan progress bar; penghapusan berhenti otomatis jika tidak ada lagi hasil.
- Log harian tersimpan di `/opt/zimbra/.log-zimbra-cleanup/cleanup_YYYYMMDD.log`.

Prasyarat
- Akses SSH ke server Zimbra sebagai `root` (untuk `su - zimbra`).
- Zimbra CLI tersedia di server (perintah `zmmailbox`).
- Jalankan dari mesin yang punya akses jaringan ke server target.
- Disarankan shell dengan Oh My Zsh + plugin `zsh-autosuggestions` dan `zsh-syntax-highlighting` agar input lebih nyaman.

Setup Repo
- Clone langsung: `git clone https://git.ptmjl.co.id/MIS/zimbra_cleanup_script.git && cd zimbra-cleanup-script`.

Cara Pakai
1) Pastikan skrip bisa dieksekusi: `chmod +x zimbra_cleanup.sh`.
2) Jalankan: `./zimbra_cleanup.sh`.
3) Isi prompt:
   - `Mailbox username`: hanya nama user (domain default `ptmjl.co.id`).
   - `Before date`: format `MM/DD/YYYY`, mengikuti timezone server.
   - `Server IP` dan `SSH Port`: kosongkan untuk default `192.168.4.5:22`.
   - `SSH key owner/name`: nama untuk komentar key (misal `siswo`).
4) Konfirmasi `Proceed? [Y/n]` untuk memulai eksekusi di server.

Query yang dipakai
- Bisnis: subject/content berisi kata kunci penjualan/laporan sebelum tanggal batas.
- Sistem: email quota warning (`subject:"quota warning"` dan `content:"mailbox size has reached"`).

Lokasi penting
- Log: `/opt/zimbra/.log-zimbra-cleanup/cleanup_YYYYMMDD.log`.
- Temp folder sementara: `/opt/zimbra/.log-zimbra-cleanup/tmp_*` (dibersihkan otomatis).

Catatan
- Skrip berhenti jika tidak ada lagi hasil pada batch berikutnya.
- Jalankan di jam non-produksi untuk meminimalkan dampak pengguna.
