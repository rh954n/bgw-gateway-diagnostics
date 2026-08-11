#!/bin/sh
# BGW320 Health Analyzer V1.2b RC3
# Author: Reza Hassani
# Purpose: Read-only health collection for BGW320-500 and BGW320-505.
# Compatibility: BusyBox /bin/sh (ash). No Bash-specific syntax.
#
# IMPORTANT:
# - This script does not change configuration, reboot the gateway, reset stats,
#   enable crash collection, or expose Wi-Fi credentials.
# - Run from the Linux shell (#), not from the NOS DEBUG/MAGIC prompt.
# - NOS-only commands such as "show log critical", "show crash", and
#   "show process-restart" are listed as manual follow-up checks.

VERSION="1.2b-RC3"
SCRIPT_NAME="BGW320 Health Analyzer"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export PATH

STAMP=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo unknown)
OUTFILE="${OUTFILE:-/tmp/bgw320_health_${STAMP}.txt}"
CSVFILE="${CSVFILE:-/tmp/bgw320_health_${STAMP}.csv}"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
INFO_COUNT=0
MODEL="Unknown"
FIRMWARE="Unknown"
PLATFORM="Unknown"

# BGW320 shell tool discovery. Some builds execute commands successfully even
# when command -v does not report them.
WL_BIN=""
for C in /bin/wl /usr/bin/wl /sbin/wl /usr/sbin/wl /rom/bin/wl; do
    [ -x "$C" ] && WL_BIN="$C" && break
done
[ -n "$WL_BIN" ] || WL_BIN=$(find /bin /sbin /usr/bin /usr/sbin /rom/bin -name wl -type f 2>/dev/null | head -n 1)

BS_BIN=""
for C in /bin/bs /rom/bin/bs /usr/bin/bs /sbin/bs; do
    [ -x "$C" ] && BS_BIN="$C" && break
done

PFS_BIN=""
for C in /bin/pfs /usr/bin/pfs /sbin/pfs /usr/sbin/pfs /rom/bin/pfs; do
    [ -x "$C" ] && PFS_BIN="$C" && break
done

have() { command -v "$1" >/dev/null 2>&1; }
num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
float_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }' 2>/dev/null; }
float_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }' 2>/dev/null; }
float_le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }' 2>/dev/null; }

line() { printf '%s\n' "------------------------------------------------------------"; }
section() { printf '\n'; line; printf '%s\n' "$1"; line; }

record() {
    status=$1 category=$2 check=$3 value=$4 detail=$5
    case "$status" in
        PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
        WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
        FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
        *) status="INFO"; INFO_COUNT=$((INFO_COUNT + 1)) ;;
    esac
    printf '[%-4s] %-18s %-30s : %s' "$status" "$category" "$check" "$value"
    [ -n "$detail" ] && printf ' (%s)' "$detail"
    printf '\n'
    printf '"%s","%s","%s","%s","%s"\n' "$status" "$category" "$check" "$value" "$detail" >> "$CSVFILE"
}

tr69_value() {
    obj=$1
    have tr69 || return 0
    tr69 get "$obj" 2>/dev/null | awk -v key="$obj" '
        index($0,key)==1 {
            sub(key "[[:space:]]*", "", $0); print; exit
        }'
}

mask_ipv4() {
    echo "$1" | awk -F. 'NF==4 {printf "%s.%s.x.x\n",$1,$2; next} {print}'
}

human_uptime() {
    s=$1
    if num "$s"; then
        d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60))
        printf '%sd %sh %sm' "$d" "$h" "$m"
    else
        printf '%s' "$s"
    fi
}

header() {
    printf '"Status","Category","Check","Value","Detail"\n' > "$CSVFILE"
    printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"
    printf 'Collection time: %s\n' "$(date 2>/dev/null || echo unavailable)"
    printf 'Output: %s\nCSV: %s\n' "$OUTFILE" "$CSVFILE"
    printf 'Tools: wl=%s bs=%s pfs=%s tr69=%s\n' "${WL_BIN:-not-found}" "${BS_BIN:-not-found}" "${PFS_BIN:-not-found}" "$(have tr69 && echo shell-available || echo NOS-only)"
}

platform_health() {
    section "1. PLATFORM"
    if have tr69; then
        MODEL=$(tr69_value 'InternetGatewayDevice.DeviceInfo.ModelName')
        FIRMWARE=$(tr69_value 'InternetGatewayDevice.DeviceInfo.SoftwareVersion')
        UPTIME=$(tr69_value 'InternetGatewayDevice.DeviceInfo.UpTime')
        [ -n "$MODEL" ] || MODEL="Unknown"
        [ -n "$FIRMWARE" ] || FIRMWARE="Unknown"
        case "$MODEL" in
            *BGW320-500*) PLATFORM="Humax BGW320-500" ;;
            *BGW320-505*) PLATFORM="Nokia BGW320-505" ;;
            *BGW320*) PLATFORM="$MODEL" ;;
            *) PLATFORM="Unknown" ;;
        esac
        case "$MODEL" in *BGW320*) record PASS Platform Model "$MODEL" "$PLATFORM" ;; *) record WARN Platform Model "$MODEL" "BGW320 not confirmed" ;; esac
        [ "$FIRMWARE" != "Unknown" ] && record PASS Platform Firmware "$FIRMWARE" "" || record WARN Platform Firmware Unknown "TR-69 value unavailable"
        [ -n "$UPTIME" ] && record INFO Platform Uptime "$(human_uptime "$UPTIME")" "${UPTIME}s" || record WARN Platform Uptime Unknown "TR-69 value unavailable"
    else
        record INFO Platform TR69 unavailable "NOS DEBUG/MAGIC command; skipped in Linux shell"
    fi

    BOOTINFO=""
    if have tr69; then BOOTINFO=$(tr69 get InternetGatewayDevice.DeviceInfo.X_ATT_BootloaderInfo. 2>/dev/null); fi
    if [ -n "$BOOTINFO" ]; then
        record PASS Platform BootloaderInfo available "readable"
        printf '%s\n' "$BOOTINFO" | sed -E 's/(Password|Key|Passphrase).*/\1 [REDACTED]/I' 2>/dev/null || printf '%s\n' "$BOOTINFO"
    else
        record INFO Platform BootloaderInfo unavailable "object not exposed"
    fi
}

cpu_health() {
    section "2. CPU"
    CPU=""
    if have tr69; then CPU=$(tr69 get InternetGatewayDevice.DeviceInfo.X_0000C5_CPUStatistics. 2>/dev/null); fi
    if [ -n "$CPU" ]; then
        USER=$(printf '%s\n' "$CPU" | awk '/UserModeUtilization/ {print $NF; exit}')
        SYSTEM=$(printf '%s\n' "$CPU" | awk '/SystemModeUtilization/ {print $NF; exit}')
        IDLE=$(printf '%s\n' "$CPU" | awk '/IdleModeUtilization/ {print $NF; exit}')
        PEAK=$(printf '%s\n' "$CPU" | awk '/PeakUtilization/ {print $NF; exit}')
        LOAD=$(printf '%s\n' "$CPU" | awk '/LoadAverage/ {print $(NF-2),$(NF-1),$NF; exit}')
        CURRENT=""
        num "$IDLE" && CURRENT=$((100 - IDLE))
        if num "$CURRENT"; then
            if [ "$CURRENT" -gt 80 ]; then record FAIL CPU Utilization "${CURRENT}%" "idle=${IDLE}%"
            elif [ "$CURRENT" -ge 50 ]; then record WARN CPU Utilization "${CURRENT}%" "idle=${IDLE}%"
            else record PASS CPU Utilization "${CURRENT}%" "user=${USER}% system=${SYSTEM}%"; fi
        else
            record INFO CPU Utilization unavailable "TR-69 format not parsed"
        fi
        [ -n "$LOAD" ] && record INFO CPU "Load average" "$LOAD" "1m 5m 15m"
        [ -n "$PEAK" ] && record INFO CPU "Reported peak" "$PEAK" "vendor value"
    else
        LOAD=$(awk '{print $1,$2,$3}' /proc/loadavg 2>/dev/null)
        [ -n "$LOAD" ] && record INFO CPU "Load average" "$LOAD" "/proc/loadavg fallback" || record WARN CPU Statistics unavailable ""
    fi
}

memory_health() {
    section "3. MEMORY"
    MT=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
    MA=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
    SLAB=$(awk '/^Slab:/ {print $2}' /proc/meminfo 2>/dev/null)
    SUNR=$(awk '/^SUnreclaim:/ {print $2}' /proc/meminfo 2>/dev/null)
    if num "$MT" && num "$MA" && [ "$MT" -gt 0 ]; then
        AP=$((MA * 100 / MT))
        if [ "$AP" -lt 10 ]; then record FAIL Memory Available "${AP}%" "${MA}kB/${MT}kB"
        elif [ "$AP" -lt 20 ]; then record WARN Memory Available "${AP}%" "${MA}kB/${MT}kB"
        else record PASS Memory Available "${AP}%" "${MA}kB/${MT}kB"; fi
    else
        record WARN Memory Available unknown "MemAvailable unavailable"
    fi
    if num "$SLAB" && num "$MT" && [ "$MT" -gt 0 ]; then
        SP=$((SLAB * 100 / MT))
        if [ "$SP" -gt 35 ]; then record FAIL Memory Slab "${SP}%" "${SLAB}kB"
        elif [ "$SP" -ge 25 ]; then record WARN Memory Slab "${SP}%" "${SLAB}kB"
        else record PASS Memory Slab "${SP}%" "${SLAB}kB"; fi
        [ -n "$SUNR" ] && record INFO Memory SUnreclaim "${SUNR}kB" "trend across runs"
    fi
    if have pidstat; then
        echo "Top RSS processes:"
        pidstat -r 2>/dev/null | awk 'NF>=9 && $5 ~ /^[0-9]+$/ {print $6,$8,$9}' | sort -nr 2>/dev/null | head -n 8
    else
        ps 2>/dev/null | head -n 5
    fi
}

wan_lan_health() {
    section "4. WAN / LAN / IPv6"
    IFOUT=$(ifconfig 2>/dev/null)
    WAN4=$(printf '%s\n' "$IFOUT" | awk '/^eth0\.0 /{f=1;next} f&&/inet addr:/{sub(/.*inet addr:/,""); sub(/[[:space:]].*/,""); print; exit} /^$/{f=0}')
    WAN6=$(printf '%s\n' "$IFOUT" | awk '/^eth0\.0 /{f=1;next} f&&/inet6 addr:/{if($0 !~ /fe80:/){sub(/.*inet6 addr:[[:space:]]*/,""); sub(/[[:space:]].*/,""); print; exit}} /^$/{f=0}')
    LAN6=$(printf '%s\n' "$IFOUT" | awk '/^br1 /{f=1;next} f&&/inet6 addr:/{if($0 !~ /fe80:/){sub(/.*inet6 addr:[[:space:]]*/,""); sub(/[[:space:]].*/,""); print; exit}} /^$/{f=0}')
    [ -n "$WAN4" ] && record PASS WAN IPv4 "$(mask_ipv4 "$WAN4")" "address present" || record WARN WAN IPv4 unavailable "eth0.0 not parsed"
    [ -n "$WAN6" ] && record PASS WAN IPv6 present "global /128 found" || record WARN WAN IPv6 unavailable ""
    [ -n "$LAN6" ] && record PASS LAN "IPv6 delegated prefix" present "br1 global /64 found" || record WARN LAN "IPv6 delegated prefix" unavailable ""

    if [ -r /proc/sys/net/netfilter/nf_conntrack_count ] && [ -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
        CC=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
        CM=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
        if num "$CC" && num "$CM" && [ "$CM" -gt 0 ]; then
            CP=$((CC * 100 / CM))
            if [ "$CP" -ge 90 ]; then record FAIL LAN Conntrack "${CC}/${CM}" "${CP}%"
            elif [ "$CP" -ge 70 ]; then record WARN LAN Conntrack "${CC}/${CM}" "${CP}%"
            else record PASS LAN Conntrack "${CC}/${CM}" "${CP}%"; fi
        fi
    fi
}

process_health() {
    section "5. PROCESS / STABILITY"
    ZLIST=$(for F in /proc/[0-9]*/stat; do
        [ -r "$F" ] || continue
        awk '$3 == "Z" {print $1, $2}' "$F" 2>/dev/null
    done)
    ZC=$(printf '%s\n' "$ZLIST" | awk 'NF{c++} END{print c+0}')
    if num "$ZC"; then
        if [ "$ZC" -gt 2 ]; then record FAIL Process Zombies "$ZC" "$ZLIST"
        elif [ "$ZC" -gt 0 ]; then record WARN Process Zombies "$ZC" "$ZLIST"
        else record PASS Process Zombies 0 ""; fi
    fi
    for P in sdb cwmp ip-manager unbound multiap_control easymesh_helper; do
        if ps 2>/dev/null | grep "$P" | grep -v grep >/dev/null 2>&1; then record PASS Process "$P" running ""; else record WARN Process "$P" not-found "may be platform/feature dependent"; fi
    done

    if [ -r /var/etc/crash_stats ]; then
        CS=$(wc -c < /var/etc/crash_stats 2>/dev/null)
        CSD=$(cat /var/etc/crash_stats 2>/dev/null | tr '\n' ' ' | cut -c1-160)
        if [ -z "$CSD" ] || echo "$CSD" | grep -Eq '(^|[^0-9])0([^0-9]|$)|none|None'; then
            record PASS Stability crash_stats present "${CS:-0} bytes; no confirmed crash"
        else
            record INFO Stability crash_stats present "${CS:-0} bytes; inspect: $CSD"
        fi
    else
        record INFO Stability crash_stats unavailable ""
    fi
    if [ -n "$PFS_BIN" ] && "$PFS_BIN" -l 2>/dev/null | grep -q '/var/etc/coresavereboot'; then record PASS Stability coresavereboot present "persistent entry"; else record INFO Stability coresavereboot not-listed ""; fi
}

reboot_health() {
    section "6. REBOOT HISTORY"
    RC=$(tr69_value 'InternetGatewayDevice.DeviceInfo.X_ATT_RebootCounter')
    [ -n "$RC" ] && record INFO Stability RebootCounter "$RC" "vendor counter" || record INFO Stability RebootCounter unavailable ""
    RH=$(tr69_value 'InternetGatewayDevice.DeviceInfo.X_ATT_RebootHistory')
    if [ -n "$RH" ]; then
        record PASS Stability RebootHistory available "raw codes retained"
        echo "$RH" | awk -F, '{for(i=1;i+1<=NF;i+=2) printf "  code=%s time=%s\n",$i,$(i+1)}'
    else
        record INFO Stability RebootHistory unavailable ""
    fi
    if [ -r /data/system/reboothistory.txt ]; then
        record PASS Stability "Local reboot history" readable "/data/system/reboothistory.txt"
        grep ',' /data/system/reboothistory.txt 2>/dev/null | tail -n 10 | while IFS=',' read -r ts event rest; do
            case "$ts" in
                ''|*[!0-9]*) ds="INVALID_TIMESTAMP" ;;
                *) ds=$(date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null); [ -n "$ds" ] || ds="$ts" ;;
            esac
            printf '  %s,%s\n' "$ds" "$event"
        done
    else
        record INFO Stability "Local reboot history" unavailable ""
    fi
}

radio_band() {
    case "$1" in wl2) echo "2.4 GHz" ;; wl0) echo "5 GHz Low / platform mapped" ;; wl1) echo "5 GHz High / mesh backhaul" ;; *) echo unknown ;; esac
}

wifi_radio() {
    R=$1 BAND=$(radio_band "$1")
    echo "Radio $R ($BAND)"
    ISUP=$("$WL_BIN" -i "$R" isup 2>/dev/null | tail -n 1)
    BSS=$("$WL_BIN" -i "$R" bss 2>/dev/null | tail -n 1)
    STATUS=$("$WL_BIN" -i "$R" status 2>/dev/null)
    CHAN=$(printf '%s\n' "$STATUS" | awk '/Channel:/ {for(i=1;i<=NF;i++) if($i=="Channel:"){print $(i+1);exit}}')
    NOISE=$(printf '%s\n' "$STATUS" | awk '/noise:/ {for(i=1;i<=NF;i++) if($i=="noise:"){print $(i+1);exit}}')
    UTIL=$(printf '%s\n' "$STATUS" | awk -F'[()%]' '/QBSS Channel Utilization/ {gsub(/ /,"",$2); print $2; exit}')
    HE=$("$WL_BIN" -i "$R" he 2>/dev/null | awk 'NR==1{print $1}')
    TXC=$("$WL_BIN" -i "$R" hw_txchain 2>/dev/null | awk 'NR==1{print $1}')
    RXC=$("$WL_BIN" -i "$R" hw_rxchain 2>/dev/null | awk 'NR==1{print $1}')

    [ "$ISUP" = "1" ] && record PASS WiFi "$R radio" UP "$BAND" || record WARN WiFi "$R radio" "state=$ISUP" "$BAND"
    if [ "$BSS" = "up" ]; then record PASS WiFi "$R BSS" up ""
    elif [ "$R" = "wl1" ]; then record INFO WiFi "$R BSS" "$BSS" "not failure when WDS backhaul is active"
    else record WARN WiFi "$R BSS" "$BSS" ""; fi
    [ -n "$CHAN" ] && record INFO WiFi "$R channel" "$CHAN" ""
    if echo "$NOISE" | grep -Eq '^-?[0-9]+$'; then
        if [ "$NOISE" -le -90 ]; then record PASS WiFi "$R noise" "${NOISE} dBm" ""
        elif [ "$NOISE" -le -85 ]; then record WARN WiFi "$R noise" "${NOISE} dBm" ""
        else record FAIL WiFi "$R noise" "${NOISE} dBm" ""; fi
    fi
    if num "$UTIL"; then
        if [ "$UTIL" -gt 75 ]; then record FAIL WiFi "$R utilization" "${UTIL}%" "QBSS"
        elif [ "$UTIL" -ge 50 ]; then record WARN WiFi "$R utilization" "${UTIL}%" "QBSS"
        else record PASS WiFi "$R utilization" "${UTIL}%" "QBSS"; fi
    fi
    [ "$HE" = "1" ] && record PASS WiFi "$R HE/11ax" enabled "" || record INFO WiFi "$R HE/11ax" "$HE" ""
    [ "$TXC" = "15" ] && [ "$RXC" = "15" ] && record PASS WiFi "$R chains" "4x4" "tx=0xf rx=0xf" || record INFO WiFi "$R chains" "tx=$TXC rx=$RXC" ""

    WC=$("$WL_BIN" -i "$R" wme_counters 2>/dev/null)
    TXF=$(printf '%s\n' "$WC" | awk '/AC_BE: tx frames:/ {for(i=1;i<=NF;i++) if($i=="frames:"){print $(i+1); exit}}')
    FAILF=$(printf '%s\n' "$WC" | awk '/AC_BE: tx frames:/ {for(i=1;i<=NF;i++) if($i=="failed" && $(i+1)=="frames:"){print $(i+2); exit}}')
    if num "$TXF" && num "$FAILF" && [ "$TXF" -gt 0 ]; then
        RATE=$(awk -v f="$FAILF" -v t="$TXF" 'BEGIN {printf "%.2f",f*100/t}')
        if float_gt "$RATE" 5; then record FAIL WiFi "$R WMM fail rate" "${RATE}%" "$FAILF/$TXF"
        elif float_ge "$RATE" 1; then record WARN WiFi "$R WMM fail rate" "${RATE}%" "$FAILF/$TXF"
        else record PASS WiFi "$R WMM fail rate" "${RATE}%" "$FAILF/$TXF"; fi
    fi
}

wifi_health() {
    section "7. WI-FI"
    if [ -z "$WL_BIN" ]; then record INFO WiFi wl unavailable "binary not found in known paths"; return; fi
    for R in wl0 wl1 wl2; do wifi_radio "$R"; done
    VER=$("$WL_BIN" -i wl1 ver 2>/dev/null | tail -n 2 | tr '\n' ' ')
    [ -n "$VER" ] && record INFO WiFi "Driver version" "$VER" "wl1"
    MU=$("$WL_BIN" -i wl1 muinfo 2>/dev/null)
    if printf '%s\n' "$MU" | grep -q 'feature is ON'; then record PASS WiFi MU-MIMO enabled "wl1"; else record INFO WiFi MU-MIMO unavailable ""; fi
    RADAR=$("$WL_BIN" -i wl1 radar 2>/dev/null | head -n 1)
    [ "$RADAR" = "1" ] && record PASS WiFi DFS/Radar enabled "wl1" || record INFO WiFi DFS/Radar "$RADAR" "wl1"
}

mesh_health() {
    section "8. EASYMESH"
    WDS=$(ifconfig 2>/dev/null | awk '/^wds[0-9]/{print $1}')
    WC=$(printf '%s\n' "$WDS" | awk 'NF{c++} END{print c+0}')
    [ "$WC" -gt 0 ] && record PASS Mesh "WDS interfaces" "$WC" "" || record WARN Mesh "WDS interfaces" 0 ""
    TRAFFIC=$(ifconfig 2>/dev/null | awk '/^wds[0-9]/{f=1} f&&/RX packets:/{sub(/.*RX packets:/,""); sub(/[[:space:]].*/,""); if($1+0>0)t=1; f=0} END{print t+0}')
    [ "$TRAFFIC" = "1" ] && record PASS Mesh "WDS traffic" present "" || record WARN Mesh "WDS traffic" none ""
    BRIDGE_OK=0
    if have brctl && brctl show 2>/dev/null | grep -E 'wds[^[:space:]]*\.100' >/dev/null 2>&1; then BRIDGE_OK=1; fi
    if ls /sys/class/net/br1/brif/wds*.100 >/dev/null 2>&1; then BRIDGE_OK=1; fi
    [ "$BRIDGE_OK" -eq 1 ] && record PASS Mesh "Bridge membership" present "VLAN 100 WDS" || record WARN Mesh "Bridge membership" not-found "brctl/sysfs"

    HOSTS=$(ps 2>/dev/null | grep -E 'multiap_control|easymesh_helper|air-map' | grep -v grep | wc -l)
    [ "$HOSTS" -gt 0 ] && record PASS Mesh Services "$HOSTS" "EasyMesh processes" || record WARN Mesh Services 0 ""
}

dpi_health() {
    section "9. DPI"
    SIG=$(tr69_value 'InternetGatewayDevice.IP.X_0000C5_DPI.CurrentSignatureFileVersion')
    [ -n "$SIG" ] && record PASS DPI "Signature version" "$SIG" "" || record WARN DPI "Signature version" unavailable ""
    if [ -r /proc/dpi/stats ]; then
        DS=$(cat /proc/dpi/stats 2>/dev/null)
        ERR=$(printf '%s\n' "$DS" | awk -F: '/engine errors/ {gsub(/[[:space:]]/,"",$2);print $2;exit}')
        SCAN=$(printf '%s\n' "$DS" | awk -F: '/packets scanned/ {gsub(/[[:space:]]/,"",$2);print $2;exit}')
        DEV=$(printf '%s\n' "$DS" | awk -F: '/devices identified/ {gsub(/[[:space:]]/,"",$2);print $2;exit}')
        [ "$ERR" = "0" ] && record PASS DPI "Engine errors" 0 "packets_scanned=$SCAN" || record FAIL DPI "Engine errors" "${ERR:-unknown}" ""
        [ -n "$DEV" ] && record INFO DPI "Devices identified" "$DEV" "classification is advisory"
    else
        record WARN DPI "Runtime stats" unavailable "/proc/dpi/stats"
    fi
    PFS=""; [ -n "$PFS_BIN" ] && PFS=$("$PFS_BIN" -l 2>/dev/null)
    printf '%s\n' "$PFS" | grep -q '/var/etc/hostdb.gz' && record PASS DPI hostdb present "" || record INFO DPI hostdb not-listed ""
    printf '%s\n' "$PFS" | grep -q '/var/etc/jdndb.gz' && record PASS DPI jdndb present "" || record INFO DPI jdndb not-listed ""
}

fpm_health() {
    section "10. FPM / PACKET BUFFER"
    if [ -z "$BS_BIN" ]; then record INFO FPM bs unavailable "binary not found in known paths"; return; fi
    for R in 0 1 2; do
        RX=$("$BS_BIN" /Driver/rdd/pdgc "$R" 2>/dev/null | awk -F= '/Rx FPM buffers in use/ {gsub(/[[:space:]]/,"",$2);print $2;exit}')
        DROPS=$("$BS_BIN" /Driver/rdd/pddc "$R" 2>/dev/null | awk -F= '/FPM congestion/ {gsub(/[[:space:]]/,"",$2);s+=$2} END{print s+0}')
        [ -n "$RX" ] && record INFO FPM "Radio $R Rx buffers" "$RX" "track across runs"
        if num "$DROPS"; then [ "$DROPS" -eq 0 ] && record PASS FPM "Radio $R congestion drops" 0 "" || record WARN FPM "Radio $R congestion drops" "$DROPS" ""; fi
    done
}

logs_health() {
    section "11. SHELL-ACCESSIBLE LOG ANALYSIS"
    SRC=""
    for F in /var/log/messages /var/log/system.log /tmp/messages; do [ -r "$F" ] && SRC="$SRC $F"; done
    if [ -n "$SRC" ]; then
        TMPLOG="/tmp/bgw320_recent_log_$$"
        cat $SRC 2>/dev/null | tail -n 1000 > "$TMPLOG"
        PM=$(grep -Eic 'too many reboots|reboot.*suppressed|pm_execute_action_reboot' "$TMPLOG" 2>/dev/null)
        FW=$(grep -Eic 'mod-fwi-swupdate|firmware controller|deviceinfo-manager_config.odl' "$TMPLOG" 2>/dev/null)
        DNS=$(grep -Eic 'Failed to update DNS datamodel' "$TMPLOG" 2>/dev/null)
        TMPFS=$(grep -Eic 'tmpfs_download|tmpfs_temp_partition|/downloads//.metadata' "$TMPLOG" 2>/dev/null)
        FATAL=$(grep -Eic 'kernel panic|segfault|out of memory|watchdog.*reset' "$TMPLOG" 2>/dev/null)
        [ "$PM" -gt 0 ] && record FAIL Logs "Reboot suppression events" "$PM" "recent 1000 lines" || record PASS Logs "Reboot suppression events" 0 "recent 1000 lines"
        [ "$FW" -gt 0 ] && record WARN Logs "Firmware/DeviceInfo errors" "$FW" "recent 1000 lines" || record PASS Logs "Firmware/DeviceInfo errors" 0 ""
        [ "$DNS" -gt 0 ] && record WARN Logs "DNS datamodel errors" "$DNS" "recent 1000 lines" || record PASS Logs "DNS datamodel errors" 0 ""
        [ "$TMPFS" -gt 0 ] && record WARN Logs "tmpfs/download errors" "$TMPFS" "recent 1000 lines" || record PASS Logs "tmpfs/download errors" 0 ""
        [ "$FATAL" -gt 0 ] && record FAIL Logs "Fatal kernel patterns" "$FATAL" "recent 1000 lines" || record PASS Logs "Fatal kernel patterns" 0 ""
        echo "Recent unique matching lines (redacted):"
        grep -Ei 'too many reboots|mod-fwi-swupdate|deviceinfo-manager_config.odl|DNS datamodel|tmpfs_download|kernel panic|segfault|out of memory|watchdog.*reset' "$TMPLOG" 2>/dev/null |
          sed -E 's/^[0-9TZ:.-]+[[:space:]]+//; s/([0-9]{1,3}\.){3}[0-9]{1,3}/[IP-REDACTED]/g; s/([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}/[MAC-REDACTED]/g' |
          sort -u | tail -n 20
        rm -f "$TMPLOG"
    else
        record INFO Logs "System log files" unavailable "use NOS manual checks"
    fi
    CRASH=$(dmesg 2>/dev/null | grep -Eic 'panic|oops|segfault|watchdog|out of memory|oom')
    [ "$CRASH" -gt 0 ] && record WARN Logs "Kernel critical patterns" "$CRASH" "dmesg" || record PASS Logs "Kernel critical patterns" 0 "dmesg"
    echo "Manual NOS CLI follow-up: show log critical; show log system; show crash; show kfm crash; show crashlog; show process-restart"
}
summary() {
    section "12. HEALTH SUMMARY"
    if [ "$FAIL_COUNT" -gt 0 ]; then OVERALL="FAIL"
    elif [ "$WARN_COUNT" -gt 0 ]; then OVERALL="WARN"
    else OVERALL="PASS"; fi
    printf 'Platform : %s\nModel    : %s\nFirmware : %s\n' "$PLATFORM" "$MODEL" "$FIRMWARE"
    printf 'PASS=%s WARN=%s FAIL=%s INFO=%s\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$INFO_COUNT"
    printf 'OVERALL=%s\n' "$OVERALL"
    printf 'Reports: %s  %s\n' "$OUTFILE" "$CSVFILE"
}

run_full() {
    platform_health
    cpu_health
    memory_health
    wan_lan_health
    process_health
    reboot_health
    wifi_health
    mesh_health
    dpi_health
    fpm_health
    logs_health
    summary
}

usage() {
    echo "Usage: $0 [full|platform|cpu|memory|network|process|reboot|wifi|mesh|dpi|fpm|logs]"
    echo "Default: full"
}

main() {
    mode=${1:-full}
    header
    case "$mode" in
        full) run_full ;;
        platform) platform_health; summary ;;
        cpu) cpu_health; summary ;;
        memory) memory_health; summary ;;
        network) wan_lan_health; summary ;;
        process) process_health; summary ;;
        reboot) reboot_health; summary ;;
        wifi) wifi_health; summary ;;
        mesh) mesh_health; summary ;;
        dpi) dpi_health; summary ;;
        fpm) fpm_health; summary ;;
        logs) logs_health; summary ;;
        -h|--help|help) usage ;;
        *) usage; exit 2 ;;
    esac
}

# Capture console output and save a text report when tee is available.
if have tee; then
    main "$@" 2>&1 | tee "$OUTFILE"
else
    main "$@" > "$OUTFILE" 2>&1
    cat "$OUTFILE"
fi
