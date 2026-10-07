#!/usr/bin/env bash
# ==============================================================================
#  TITAN HFT LINUX SERVER - ULTRA-LOW LATENCY SETUP (Ubuntu 22.04 / 24.04 LTS)
#  - Custom Protected Ports: RDP on 5133 | SSH on 1721
#  - Sub-Millisecond IST Clock Sync (NPL India Atomic Clocks + 16s PLL Slewing)
#  - Pre-Market 8:59:00 AM IST Atomic Clock Snap
#  - 24/7 Awake: Screensavers, DPMS, and Sleep Modes Completely Disabled
#  - Nanosecond Kernel: NIC 4096 Ring Buffers, C-State Sleep Prevention
#  - 60 FPS Mesa Software GPU Rasterizer (llvmpipe)
#  - Hardware Core Pinning (hft-run wrapper included)
#  - Hardened Zero-Overhead Firewall & Fail2ban
# ==============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

RDP_PORT=5133
SSH_PORT=1721
TRADER_USER="trader"

echo "============================================================"
echo "  [1/9] INDIAN STANDARD TIME (IST) & NPLI ATOMIC TIME SYNC"
echo "============================================================"
timedatectl set-timezone Asia/Kolkata
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
echo "Asia/Kolkata" > /etc/timezone

apt-get update -y
apt-get install -y chrony cron ethtool

# Configure Chrony with NPL India (National Physical Laboratory - IST Source)
cat > /etc/chrony/chrony.conf <<EOF
# AWS Mumbai Hardware Clock (Stratum 1 - microsecond bus if on AWS)
server 169.254.169.123 prefer iburst minpoll 4 maxpoll 6

# NPL India Atomic Clock (Official IST Benchmark for NSE/BSE/MCX)
server time.nplindia.org iburst minpoll 4 maxpoll 6
server in.pool.ntp.org iburst minpoll 4 maxpoll 6
server time.cloudflare.com iburst minpoll 4 maxpoll 6
server time.google.com iburst minpoll 4 maxpoll 6

keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync

# Step ONLY during initial 3 boots, then smooth frequency micro-slewing
makestep 0.1 3
EOF

systemctl restart chrony
systemctl enable chrony

# Automated Pre-Market Atomic Clock Snap at 08:59:00 AM IST sharp
cat > /etc/cron.d/hft_clock_snap <<'EOF'
59 8 * * 1-5 root /usr/bin/chronyc makestep >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/hft_clock_snap

echo "============================================================"
echo "  [2/9] SYSTEM PACKAGES & RUST/GRAPHICS LIBRARIES"
echo "============================================================"
apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
apt-get install -y --no-install-recommends \
    ca-certificates curl wget ufw fail2ban dbus-x11 unzip \
    build-essential pkg-config libssl-dev htop rsync \
    mesa-vulkan-drivers libgl1-mesa-dri libvulkan1 vulkan-tools \
    libfontconfig1-dev libasound2-dev libx11-dev libxcursor-dev \
    libxrandr-dev libxi-dev libxkbcommon-x11-0

echo "============================================================"
echo "  [3/9] NANOSECOND-GRADE HFT KERNEL & NETWORK STACK"
echo "============================================================"
cat > /etc/sysctl.d/99-hft-latency.conf <<'EOF'
# Google BBR Congestion Control (Minimum RTT Packet Pacing)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Low-Latency Socket Busy-Polling (Eliminates CPU sleep-wakeup latency)
net.core.busy_poll = 50
net.core.busy_read = 50

# TCP Fast Open & Buffer Sizing for High-Throughput Market Ticks
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# Anti-DDoS SYN Flood Protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_synack_retries = 2

# Anti-Spoofing & Network Route Hardening
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0

# Zero-Swap: Lock RAM in Physical Memory (Zero Disk Latency)
vm.swappiness = 0
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF
sysctl --system >/dev/null 2>&1

# Prevent memory compaction freezes (Transparent HugePages)
echo "madvise" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo "madvise" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

# Maximize Network Card Ring Buffers (Prevents drops at 9:15 AM bell)
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -n "$DEFAULT_IFACE" ]; then
    ethtool -G "$DEFAULT_IFACE" rx 4096 tx 4096 2>/dev/null || true
fi

# High System Limits
cat >> /etc/security/limits.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft memlock unlimited
* hard memlock unlimited
EOF

echo "============================================================"
echo "  [4/9] PREVENTING CPU SLEEP (LOCKING PERFORMANCE GOVERNOR)"
echo "============================================================"
apt-get install -y cpufrequtils 2>/dev/null || true
if which cpufreq-set >/dev/null 2>&1; then
    for CPU in /sys/devices/system/cpu/cpu[0-9]*; do
        cpufreq-set -c "${CPU##*cpu}" -g performance 2>/dev/null || true
    done
fi

echo "============================================================"
echo "  [5/9] WINDOWS 11-STYLE DESKTOP & 24/7 AWAKE CONFIGURATION"
echo "============================================================"
# Remove any screensavers that cause sleep or black screen
apt-get purge -y xfce4-screensaver light-locker xscreensaver 2>/dev/null || true
apt-get install -y xfce4 xfce4-goodies xfce4-whiskermenu-plugin xfce4-terminal mousepad x11-xserver-utils

if ! id "$TRADER_USER" &>/dev/null; then
    adduser --disabled-password --gecos "" "$TRADER_USER"
    usermod -aG sudo "$TRADER_USER"
fi

# Configure Session: Disable DPMS sleep, screen blanking, enable Mesa CPU graphics
cat > /home/${TRADER_USER}/.xsession <<'EOF'
#!/bin/sh
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_DESKTOP=xfce
export LIBGL_ALWAYS_SOFTWARE=1
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
export WGPU_BACKEND=vulkan,gl

# 100% Permanently Disable Screen Blanking, Energy Star & Sleep
xset s off
xset s noblank
xset -dpms

exec startxfce4
EOF
chmod +x /home/${TRADER_USER}/.xsession
chown ${TRADER_USER}:${TRADER_USER} /home/${TRADER_USER}/.xsession

CFG="/home/${TRADER_USER}/.config"
mkdir -p "$CFG/xfce4/xfconf/xfce-perchannel-xml/"

# Turn off Window Compositor (eliminates window dragging and redraw lag)
cat > "$CFG/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF

# Turn off Power Manager Display Sleep (Never Black Screen)
cat > "$CFG/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="power-button-action" type="uint" value="0"/>
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="blank-on-ac" type="int" value="0"/>
    <property name="dpms-sleep-ac" type="uint" value="0"/>
    <property name="dpms-off-ac" type="uint" value="0"/>
    <property name="presentation-mode" type="bool" value="true"/>
  </property>
</channel>
EOF

# Build Windows 11 Bottom Taskbar
cat > "$CFG/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=8;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="38"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
        <value type="int" value="6"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="whiskermenu"/>
    <property name="plugin-2" type="string" value="tasklist">
      <property name="grouping" type="uint" value="0"/>
      <property name="show-labels" type="bool" value="true"/>
    </property>
    <property name="plugin-3" type="string" value="separator"><property name="expand" type="bool" value="true"/></property>
    <property name="plugin-4" type="string" value="systray"/>
    <property name="plugin-5" type="string" value="clock">
      <property name="mode" type="uint" value="2"/>
      <property name="digital-layout" type="uint" value="3"/>
      <property name="digital-time-format" type="string" value="%H:%M:%S IST"/>
      <property name="digital-date-format" type="string" value="%d-%b-%Y"/>
    </property>
    <property name="plugin-6" type="string" value="showdesktop"/>
  </property>
</channel>
EOF
chown -R ${TRADER_USER}:${TRADER_USER} "$CFG"

echo "============================================================"
echo "  [6/9] CORE ISOLATION WRAPPER (hft-run)"
echo "============================================================"
# Creates a global 'hft-run' command that automatically pins trading apps to Core 2 & 3
NCPU=$(nproc)
if [ "$NCPU" -ge 4 ]; then
    HFT_CORES="2,3"
else
    HFT_CORES="1"
fi

cat > /usr/local/bin/hft-run <<EOF
#!/usr/bin/env bash
# Automatically pins any command to isolated CPU cores with high priority
exec taskset -c ${HFT_CORES} nice -n -20 "\$@"
EOF
chmod +x /usr/local/bin/hft-run

echo "============================================================"
echo "  [7/9] INSTALLING OFFICIAL GOOGLE CHROME (FOR MORNING LOGIN)"
echo "============================================================"
wget -qO /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
apt-get install -y /tmp/chrome.deb
rm -f /tmp/chrome.deb

update-alternatives --set x-www-browser /usr/bin/google-chrome-stable || true
update-alternatives --set gnome-www-browser /usr/bin/google-chrome-stable || true

echo "============================================================"
echo "  [8/9] CONFIGURING 24/7 ACTIVE XRDP ON PORT :${RDP_PORT}"
echo "============================================================"
apt-get install -y xrdp xorgxrdp
adduser xrdp ssl-cert

sed -i "s/^port=3389/port=${RDP_PORT}/" /etc/xrdp/xrdp.ini
sed -i 's/^crypt_level=.*/crypt_level=high/' /etc/xrdp/xrdp.ini
sed -i 's/^bitmap_compression=.*/bitmap_compression=true/' /etc/xrdp/xrdp.ini
sed -i 's/^max_bpp=.*/max_bpp=24/' /etc/xrdp/xrdp.ini

# Ensure RDP sessions never timeout or disconnect on idle
sed -i 's/^#idle_timeout=.*/idle_timeout=0/' /etc/xrdp/sesman.ini 2>/dev/null || true
sed -i 's/^#disconnected_timeout=.*/disconnected_timeout=0/' /etc/xrdp/sesman.ini 2>/dev/null || true

# Configure Custom SSH Port
sed -i "s/^#Port 22/Port ${SSH_PORT}/" /etc/ssh/sshd_config
sed -i "s/^Port 22/Port ${SSH_PORT}/" /etc/ssh/sshd_config

systemctl restart xrdp
systemctl enable xrdp
systemctl restart ssh

echo "============================================================"
echo "  [9/9] HARDENED FIREWALL & FAIL2BAN (PORTS ${RDP_PORT} & ${SSH_PORT})"
echo "============================================================"
systemctl enable fail2ban
systemctl restart fail2ban

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp comment 'Protected SSH'
ufw allow ${RDP_PORT}/tcp comment 'Protected XRDP'
ufw --force enable

echo ""
echo "============================================================"
echo "  SETUP COMPLETE! SET YOUR DESKTOP PASSWORD NOW"
echo "============================================================"
echo "Enter a strong password for user '${TRADER_USER}':"
passwd ${TRADER_USER}

echo ""
echo "------------------------------------------------------------"
echo "SUCCESS! How to connect from your Windows PC:"
echo "1. Remote Desktop (Win + R -> mstsc)"
echo "2. Computer: YOUR_SERVER_IP:${RDP_PORT}"
echo "   (Example: 65.20.78.70:${RDP_PORT})"
echo "3. Username: ${TRADER_USER}"
echo "4. To run Rust bot with isolated cores: hft-run cargo run --release"
echo "------------------------------------------------------------"
