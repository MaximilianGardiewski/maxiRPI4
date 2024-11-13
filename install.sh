#!/bin/bash

# -------------------------------------------------------------------------------------------------
# Pi-PwnBox-RogueAP 
# https://github.com/koutto/pi-pwnbox-rogueap
# -------------------------------------------------------------------------------------------------
# Install Script - IMPORTANT: EDIT CONFIGURATION BEFORE RUNNING IT !
# -------------------------------------------------------------------------------------------------

# -------------------------------------------------------------------------------------------------
# Configuration: Make sure to have correct values here before running install script
# -------------------------------------------------------------------------------------------------

# Guacamole credentials
GUACAMOLE_PASSWORD="lIAmAggUAcAmOlE"
GUACAMOLE_MYSQL_PASSWORD="lIAmAggUAcAmOlE"

# First WiFi connection (to configure wpa_supplicant)
WIFI_SSID="InMaliIstEsSchön"
WIFI_PASSPHRASE="@HaWo19601957!"

# -------------------------------------------------------------------------------------------------

RED=`tput setaf 1`
GREEN=`tput setaf 2`
BLUE=`tput setaf 4`
YELLOW=`tput setaf 3`
RESET=`tput sgr0`

if [[ $EUID -ne 0 ]]; then
   echo "${RED}[!] This script must be run as root ${RESET}" 
   exit 1
fi

echo "${YELLOW}[!] Make sure to have correct configuration at the beginning of this script before continuing !!"
echo "${YELLOW}[~] Script will pause at the end of each step to allow for manual check of commands outputs (errors?)${RESET}"
echo
read -n 1 -s -r -p "Press any key to continue"

# **Modification Start**
# Get MAC addresses of built-in Ethernet and WiFi interfaces
MAC_ETH0=$(cat /sys/class/net/eth0/address)
MAC_WLAN0=$(cat /sys/class/net/wlan0/address)

# **Detect all T2U Plus adapters (Realtek RTL8812AU)**
# We will collect their MAC addresses and assign predictable names
T2U_PLUS_MACS=()
for iface in $(ls /sys/class/net/); do
    # Check if it's a wireless interface
    if [ -d /sys/class/net/$iface/wireless ]; then
        # Get the driver
        driver=$(basename $(readlink -f /sys/class/net/$iface/device/driver 2>/dev/null))
        if [ "$driver" == "8812au" ]; then
            mac=$(cat /sys/class/net/$iface/address)
            T2U_PLUS_MACS+=($mac)
        fi
    fi
done

# Check if we found three T2U Plus adapters
if [ ${#T2U_PLUS_MACS[@]} -ne 3 ]; then
    echo "${RED}[!] Exactly three T2U Plus adapters must be connected. Found ${#T2U_PLUS_MACS[@]}.${RESET}"
    exit 1
fi

echo "${GREEN}[+] Found T2U Plus adapters with MACs:${RESET}"
for mac in "${T2U_PLUS_MACS[@]}"; do
    echo "    $mac"
done

# **Disable MAC address randomization for these adapters**
# Create a configuration file for NetworkManager (even though we disable it later, it's good practice)
mkdir -p /etc/NetworkManager/conf.d/
cat > /etc/NetworkManager/conf.d/100-disable-wifi-mac-randomization.conf <<EOF
[connection]
wifi.mac-address-randomization=1

[device]
wifi.scan-rand-mac-address=no
EOF
# **Modification End**

echo "${YELLOW}[~] Add Kali rolling repository in /etc/apt/sources.list${RESET}"
# ... (Rest of the script remains the same until we reach the udev rules)

# -------------------------------------------------------------------------------------------------
# Networking configuration (with persistent interfaces naming)

echo "${YELLOW}[~] Ensure Network Interface names are persistent and predictable... ${RESET}"
echo "${YELLOW}eth0 => Ethernet${RESET}"
echo "${YELLOW}wlan0 => Built-in Wi-Fi interface${RESET}"
echo "${YELLOW}wlx[MAC] => T2U Plus adapters (Realtek RTL8812AU)${RESET}"
echo

# **Modification Start**
# Create udev rules to assign predictable names based on MAC addresses
# Back up existing rules
if [ -f /etc/udev/rules.d/70-persistent-net.rules ]; then
    mv /etc/udev/rules.d/70-persistent-net.rules /etc/udev/rules.d/70-persistent-net.rules.old
fi

# Generate new udev rules
cat > /etc/udev/rules.d/70-persistent-net.rules <<EOF
# Persistent rules for Ethernet and built-in Wi-Fi
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="$MAC_ETH0", NAME="eth0"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="$MAC_WLAN0", NAME="wlan0"

# Persistent rules for T2U Plus adapters
EOF

# Assign names wlx<MAC> to T2U Plus adapters
for mac in "${T2U_PLUS_MACS[@]}"; do
    iface_name="wlx${mac//:/}"
    echo "SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"?*\", ATTR{address}==\"$mac\", NAME=\"$iface_name\"" >> /etc/udev/rules.d/70-persistent-net.rules
done

# Reload udev rules
udevadm control --reload-rules
udevadm trigger

# **Modification End**

echo "${YELLOW}[~] Configure network interfaces${RESET}"
mv /etc/network/interfaces /etc/network/interfaces.old

# **Modification Start**
# Generate /etc/network/interfaces with all T2U Plus adapters
cat > /etc/network/interfaces <<EOF

auto lo
iface lo inet loopback

# Automatic connection to network via eth0 if Ethernet connected
auto eth0
allow-hotplug eth0
iface eth0 inet dhcp

# wlan0: Built-in WiFi interface
auto wlan0
allow-hotplug wlan0
iface wlan0 inet dhcp
wpa-conf /etc/wpa_supplicant.conf

EOF

# Configure the first T2U Plus adapter for the pwnbox access point
# The rest can be configured as needed
first_adapter="wlx${T2U_PLUS_MACS[0]//:/}"
cat >> /etc/network/interfaces <<EOF

# First T2U Plus adapter used for pwnbox access point
allow-hotplug $first_adapter
iface $first_adapter inet static
  address 10.0.0.1
  netmask 255.255.255.0
  up route add -net 10.0.0.0 netmask 255.255.255.0 gw 10.0.0.1

EOF

# The remaining adapters can be configured for other purposes
for ((i=1; i<${#T2U_PLUS_MACS[@]}; i++)); do
    adapter="wlx${T2U_PLUS_MACS[i]//:/}"
    cat >> /etc/network/interfaces <<EOF

# T2U Plus adapter $((i+1)) configured for manual use
allow-hotplug $adapter
iface $adapter inet manual

EOF
done

# **Modification End**

wpa_passphrase "${WIFI_SSID}" "${WIFI_PASSPHRASE}" >> /etc/wpa_supplicant.conf
read -n 1 -s -r -p "Press any key to continue"

# Continue with the rest of the script, ensuring that we reference the correct adapter names
# For example, when configuring dnsmasq and hostapd, use $first_adapter

# -------------------------------------------------------------------------------------------------
# Setup AP at boot for pwnbox access via WiFi

echo "${YELLOW}[~] Setup AP at boot for pwnbox access via WiFi...${RESET}"

echo "${YELLOW}[~] Configure dnsmasq...${RESET}"
mv /etc/dnsmasq.conf /etc/dnsmasq.conf.old
cat > /etc/dnsmasq.conf <<EOF

interface=$first_adapter
dhcp-authoritative
dhcp-range=10.0.0.2,10.0.0.30,255.255.255.0,12h
dhcp-option=3,10.0.0.1
dhcp-option=6,10.0.0.1
server=8.8.8.8
log-queries
log-dhcp
listen-address=10.0.0.1
bind-interfaces

EOF

echo "${YELLOW}[~] Configure hostapd...${RESET}"
mv /etc/hostapd/hostapd.conf /etc/hostapd.conf.old
cat > /etc/hostapd/hostapd.conf <<EOF

interface=$first_adapter
driver=nl80211
ssid=PWNBOX_ADMIN
hw_mode=g
channel=11
macaddr_acl=0
ignore_broadcast_ssid=1 # hidden SSID
auth_algs=1
wpa=2
wpa_passphrase=Koutto!PwnB0x!
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
wpa_group_rekey=86400
ieee80211n=1
wme_enabled=1

EOF

# Continue with the rest of the script...

# **Ensure Re4son Kernel is not overwritten**
# We've already adjusted the upgrade commands to avoid `dist-upgrade`, which could update the kernel.

# Finish the script with the rest of the components.

updatedb

echo "${GREEN}[+] Install script finished. Now Reboot!"
echo
