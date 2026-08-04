#!/bin/sh
# ============================================================
# BGW620 WiFi / PWiFi Health Analyzer V3.5
# Author: Reza Hassani workflow support
# Read-only diagnostics. No config changes are performed.
#
# Major V3.5 additions:
#   - Option 99: Full suite + one LOG + one CSV + upload + XLSX conversion
#   - Memory/System health: free, /proc/meminfo, pidstat/top
#   - Safe NVRAM extraction only, no full nvram dump by default
#   - Backhaul/EasyMesh/MultiAP summary
#   - Fronthaul/Backhaul BSS role scan using wl -i <iface> map
#   - WiFi client distribution from wl -e assoclist
#   - ACS/channel health, cloud channel management, DNS health
# ============================================================

VERSION="V3.5"
TS=`date +%Y%m%d_%H%M%S 2>/dev/null`
[ -z "$TS" ] && TS="manual"
HOSTNAME_RG=`hostname 2>/dev/null`
[ -z "$HOSTNAME_RG" ] && HOSTNAME_RG="dsldevice"
MODEL="BGW620"
CSHELL=""

# Failsafe settings. Edit if your failsafe host/path is different.
FAILSAFE_USER="rh954n"
FAILSAFE_HOST="99.124.173.137"
FAILSAFE_PORT="2245"
FAILSAFE_BASE="/home/rh954n/BGW620"

SERIAL=`nvram show 2>/dev/null | grep '^dev_invt_sn=' | head -1 | cut -d= -f2`
[ -z "$SERIAL" ] && SERIAL=`nvram show 2>/dev/null | grep '^boardnum=' | head -1 | cut -d= -f2`
[ -z "$SERIAL" ] && SERIAL="$HOSTNAME_RG"
SERIAL_SAFE=`echo "$SERIAL" | sed 's/[^A-Za-z0-9._-]/_/g'`

BASE="/tmp/bgw620_health_${SERIAL_SAFE}_${TS}"
LOG="${BASE}.log"
CSV="${BASE}.csv"

csv_escape() {
    echo "$1" | sed 's/"/""/g'
}

csv_row() {
    NOW=`date '+%Y-%m-%d %H:%M:%S' 2>/dev/null`
    F1=`csv_escape "$1"`; F2=`csv_escape "$2"`; F3=`csv_escape "$3"`
    F4=`csv_escape "$4"`; F5=`csv_escape "$5"`; F6=`csv_escape "$6"`
    echo "\"$NOW\",\"$HOSTNAME_RG\",\"$MODEL\",\"$SERIAL_SAFE\",\"$VERSION\",\"$F1\",\"$F2\",\"$F3\",\"$F4\",\"$F5\",\"$F6\"" >> "$CSV"
}

csv_header() {
    echo 'Timestamp,RG_Host,Model,Serial,ScriptVersion,Category,Test,Metric,Value,Result,Notes' > "$CSV"
}

log_line() {
    echo "$1" | tee -a "$LOG"
}

section() {
    log_line ""
    log_line "============================================================"
    log_line "$1"
    log_line "============================================================"
}

find_cshell() {
    if command -v cshell >/dev/null 2>&1; then CSHELL=`command -v cshell`; return 0; fi
    for c in /bin/cshell /usr/bin/cshell /sbin/cshell /usr/sbin/cshell /usr/local/bin/cshell
    do
        if [ -x "$c" ]; then CSHELL="$c"; return 0; fi
    done
    CSHELL=""
    return 1
}

run_cmd() {
    DESC="$1"; shift
    section "$DESC"
    log_line "Command: $*"
    "$@" >> "$LOG" 2>&1
    RC=$?
    if [ "$RC" -eq 0 ]; then
        csv_row "command" "$DESC" "return_code" "$RC" "PASS" "$*"
    else
        csv_row "command" "$DESC" "return_code" "$RC" "WARN" "$*"
    fi
    return "$RC"
}

run_cshell() {
    DESC="$1"; CMD="$2"
    find_cshell
    if [ -n "$CSHELL" ]; then
        run_cmd "$DESC" "$CSHELL" -c "$CMD"
    else
        section "$DESC"
        log_line "cshell not found for: $CMD"
        csv_row "stability" "$DESC" "cshell" "not_found" "SKIP" "$CMD"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

init_report() {
    csv_header
    section "BGW620 HEALTH ANALYZER START"
    log_line "Script Version : $VERSION"
    log_line "Timestamp      : $TS"
    log_line "Host           : $HOSTNAME_RG"
    log_line "Serial         : $SERIAL_SAFE"
    log_line "CSV            : $CSV"
    log_line "LOG            : $LOG"
    csv_row "system" "start" "script" "bgw620_wifi_pwifi_health_v3_5" "INFO" "Started BGW620 health analyzer"
}

print_paths() {
    echo ""
    echo "CSV=$CSV"
    echo "LOG=$LOG"
    echo "SERIAL=$SERIAL_SAFE"
}

memory_health() {
    section "SYSTEM / MEMORY HEALTH"

    if command_exists free; then
        free -m >> "$LOG" 2>&1
        MEM_LINE=`free -m 2>/dev/null | awk '/^Mem:/ {print $0}'`
        MT=`echo "$MEM_LINE" | awk '{print $2}'`
        MU=`echo "$MEM_LINE" | awk '{print $3}'`
        MF=`echo "$MEM_LINE" | awk '{print $4}'`
        MB=`echo "$MEM_LINE" | awk '{print $6}'`
        MA=`echo "$MEM_LINE" | awk '{print $7}'`
        [ -z "$MT" ] && MT=0; [ -z "$MU" ] && MU=0; [ -z "$MF" ] && MF=0; [ -z "$MB" ] && MB=0; [ -z "$MA" ] && MA=0
        R="PASS"; N="Available memory is healthy"
        if [ "$MA" -lt 250 ]; then R="FAIL"; N="Available memory below 250 MB"; elif [ "$MA" -lt 500 ]; then R="WARN"; N="Available memory below 500 MB"; fi
        csv_row "memory" "free_m" "mem_total_mb" "$MT" "INFO" "Total RAM"
        csv_row "memory" "free_m" "mem_used_mb" "$MU" "INFO" "Used RAM"
        csv_row "memory" "free_m" "mem_free_mb" "$MF" "INFO" "Free RAM"
        csv_row "memory" "free_m" "buff_cache_mb" "$MB" "INFO" "Buffer/cache RAM"
        csv_row "memory" "free_m" "mem_available_mb" "$MA" "$R" "$N"
    else
        csv_row "memory" "free_m" "status" "free_not_found" "SKIP" "free command missing"
    fi

    if [ -r /proc/meminfo ]; then
        cat /proc/meminfo >> "$LOG" 2>&1
        SLAB_KB=`awk '/^Slab:/ {print $2}' /proc/meminfo 2>/dev/null`
        SUN_KB=`awk '/^SUnreclaim:/ {print $2}' /proc/meminfo 2>/dev/null`
        CMA_KB=`awk '/^CmaFree:/ {print $2}' /proc/meminfo 2>/dev/null`
        MEMAV_KB=`awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null`
        [ -z "$SLAB_KB" ] && SLAB_KB=0; [ -z "$SUN_KB" ] && SUN_KB=0; [ -z "$CMA_KB" ] && CMA_KB=0; [ -z "$MEMAV_KB" ] && MEMAV_KB=0
        SLAB_MB=`awk -v k="$SLAB_KB" 'BEGIN {printf "%d", k/1024}'`
        SUN_MB=`awk -v k="$SUN_KB" 'BEGIN {printf "%d", k/1024}'`
        CMA_MB=`awk -v k="$CMA_KB" 'BEGIN {printf "%d", k/1024}'`
        MAV_MB=`awk -v k="$MEMAV_KB" 'BEGIN {printf "%d", k/1024}'`
        SUN_R="PASS"; SUN_N="SUnreclaim below warning threshold"
        if [ "$SUN_MB" -gt 700 ]; then SUN_R="FAIL"; SUN_N="SUnreclaim above 700 MB"; elif [ "$SUN_MB" -gt 400 ]; then SUN_R="WARN"; SUN_N="SUnreclaim above 400 MB"; fi
        csv_row "memory" "proc_meminfo" "mem_available_mb" "$MAV_MB" "INFO" "MemAvailable from /proc/meminfo"
        csv_row "memory" "proc_meminfo" "slab_mb" "$SLAB_MB" "INFO" "Kernel slab memory"
        csv_row "memory" "proc_meminfo" "sunreclaim_mb" "$SUN_MB" "$SUN_R" "$SUN_N"
        csv_row "memory" "proc_meminfo" "cma_free_mb" "$CMA_MB" "INFO" "CMA free memory"
    fi

    if command_exists pidstat; then
        section "TOP MEMORY PROCESSES BY PIDSTAT"
        pidstat -ruh >> "$LOG" 2>&1
        pidstat -ruh 2>/dev/null | awk 'NR>2 && $14 ~ /^[0-9.]+$/ && $14 >= 2 {print $15","$14}' | while IFS=, read P M
        do
            [ -n "$P" ] && csv_row "memory" "pidstat" "$P" "$M%" "INFO" "Process using >=2 percent memory"
        done
    else
        section "TOP MEMORY PROCESSES BY TOP"
        top -b -n1 2>/dev/null | head -40 >> "$LOG" 2>&1
        csv_row "memory" "top" "status" "captured" "INFO" "top -b -n1 head -40 saved to log"
    fi
}

safe_nvram_backhaul_health() {
    section "BACKHAUL / EASYMESH SAFE NVRAM HEALTH"
    TMP="/tmp/bgw620_nvram_safe_${TS}.tmp"
    nvram show 2>/dev/null | grep -E "map_agent_active_bh_type|map_onboarded|multiap_mode|wbd_ifnames|wl[0-2]_band_flag|map_bh|Backhaul" > "$TMP" 2>/dev/null
    cat "$TMP" >> "$LOG" 2>&1

    BH=`grep '^map_agent_active_bh_type=' "$TMP" | tail -1 | cut -d= -f2`
    ONB=`grep '^map_onboarded=' "$TMP" | tail -1 | cut -d= -f2`
    ONB1=`grep '^map_onboarded_first_time=' "$TMP" | tail -1 | cut -d= -f2`
    MMODE=`grep '^multiap_mode=' "$TMP" | tail -1 | cut -d= -f2`
    WBD=`grep '^wbd_ifnames=' "$TMP" | tail -1 | cut -d= -f2-`
    WL0BF=`grep '^wl0_band_flag=' "$TMP" | tail -1 | cut -d= -f2`
    WL1BF=`grep '^wl1_band_flag=' "$TMP" | tail -1 | cut -d= -f2`
    WL2BF=`grep '^wl2_band_flag=' "$TMP" | tail -1 | cut -d= -f2`
    BHSSID=`grep -E 'Backhaul|map_bh_ssid' "$TMP" | head -1 | cut -d= -f2-`

    [ -z "$BH" ] && BH="unknown"
    [ -z "$ONB" ] && ONB="unknown"
    [ -z "$ONB1" ] && ONB1="unknown"
    [ -z "$MMODE" ] && MMODE="unknown"
    [ -z "$WBD" ] && WBD="unknown"

    BR="PASS"; BN="Backhaul/EasyMesh data collected"
    if [ "$ONB" != "1" ]; then BR="WARN"; BN="map_onboarded is not 1 or unknown"; fi

    csv_row "backhaul" "safe_nvram" "backhaul_type" "$BH" "$BR" "$BN"
    csv_row "backhaul" "safe_nvram" "map_onboarded" "$ONB" "INFO" "EasyMesh onboarded flag"
    csv_row "backhaul" "safe_nvram" "map_onboarded_first_time" "$ONB1" "INFO" "Initial onboarded flag"
    csv_row "backhaul" "safe_nvram" "multiap_mode" "$MMODE" "INFO" "MultiAP mode"
    csv_row "backhaul" "safe_nvram" "wbd_ifnames" "$WBD" "INFO" "WBD managed interfaces"
    csv_row "backhaul" "safe_nvram" "wl0_band_flag" "$WL0BF" "INFO" "Radio band flag"
    csv_row "backhaul" "safe_nvram" "wl1_band_flag" "$WL1BF" "INFO" "Radio band flag"
    csv_row "backhaul" "safe_nvram" "wl2_band_flag" "$WL2BF" "INFO" "Radio band flag"
    [ -n "$BHSSID" ] && csv_row "backhaul" "safe_nvram" "backhaul_ssid" "$BHSSID" "INFO" "Backhaul SSID from safe NVRAM grep"
    rm -f "$TMP"
}

wifi_client_distribution() {
    section "WIFI CLIENT DISTRIBUTION"
    TMP="/tmp/bgw620_assoc_${TS}.tmp"
    wl -e assoclist > "$TMP" 2>&1
    cat "$TMP" >> "$LOG"

    TOTAL=`grep -c '^assoclist ' "$TMP" 2>/dev/null`
    [ -z "$TOTAL" ] && TOTAL=0
    csv_row "wifi" "client_distribution" "total_assoc_clients" "$TOTAL" "INFO" "Total clients from wl -e assoclist"

    awk '
    /^---/ {iface=$2; band=$3; count[iface]=0; b[iface]=band; seen[iface]=1; order[++n]=iface; next}
    /^assoclist/ {count[iface]++}
    END {for (i=1;i<=n;i++) print order[i] "," b[order[i]] "," count[order[i]]}
    ' "$TMP" | while IFS=, read IFACE BAND CNT
    do
        [ -n "$IFACE" ] && csv_row "wifi" "client_distribution" "$IFACE $BAND" "$CNT" "INFO" "Associated client count per interface"
    done
    rm -f "$TMP"
}

wifi_detail_health() {
    section "WIFI DETAIL HEALTH"
    for i in wl0 wl1 wl2
    do
        ST="/tmp/bgw620_${i}_status_${TS}.tmp"
        wl -i "$i" status > "$ST" 2>&1
        cat "$ST" >> "$LOG"
        CH=`grep 'Channel:' "$ST" | head -1 | sed 's/.*Channel: *//' | awk '{print $1}'`
        CS=`grep 'Chanspec:' "$ST" | head -1 | sed 's/^ *Chanspec: *//'`
        UTIL=`grep 'QBSS Channel Utilization' "$ST" | head -1 | sed 's/.*(//' | sed 's/ %).*//'`
        SSID=`grep '^SSID:' "$ST" | head -1 | sed 's/^SSID: *//' | tr -d '"'`
        [ -z "$CH" ] && CH="unknown"; [ -z "$CS" ] && CS="unknown"; [ -z "$UTIL" ] && UTIL="unknown"; [ -z "$SSID" ] && SSID="unknown"
        csv_row "wifi" "radio_status" "$i channel" "$CH" "INFO" "Radio channel"
        csv_row "wifi" "radio_status" "$i chanspec" "$CS" "INFO" "Radio chanspec"
        csv_row "wifi" "radio_status" "$i utilization_percent" "$UTIL" "INFO" "QBSS channel utilization"
        csv_row "wifi" "radio_status" "$i ssid" "$SSID" "INFO" "SSID from wl status"
        rm -f "$ST"
    done
    run_cmd "wl -e bss" wl -e bss
}

bss_role_scan() {
    section "FRONTHAUL / BACKHAUL BSS ROLE SCAN"
    IFACES="wl0 wl0.1 wl0.2 wl0.3 wl0.4 wl0.5 wl0.6 wl0.7 wl1 wl1.1 wl1.2 wl1.3 wl1.4 wl1.5 wl1.6 wl1.7 wl2 wl2.1 wl2.2 wl2.3 wl2.4 wl2.5 wl2.6 wl2.7"
    for IF in $IFACES
    do
        OUT=`wl -i "$IF" map 2>/dev/null`
        if echo "$OUT" | grep -q 'Backhaul-BSS'; then
            csv_row "backhaul" "bss_role_scan" "$IF" "Backhaul-BSS" "PASS" "wl map returned Backhaul-BSS"
            echo "$IF: $OUT" >> "$LOG"
            wl -i "$IF" bs_data -noreset >> "$LOG" 2>&1
            BHCLIENTS=`wl -i "$IF" bs_data -noreset 2>/dev/null | grep -c '^[0-9A-Fa-f][0-9A-Fa-f]:'`
            csv_row "backhaul" "backhaul_bs_data" "$IF station_count" "$BHCLIENTS" "INFO" "Backhaul station count from bs_data"
        elif echo "$OUT" | grep -q 'Fronthaul-BSS'; then
            csv_row "backhaul" "bss_role_scan" "$IF" "Fronthaul-BSS" "INFO" "wl map returned Fronthaul-BSS"
            echo "$IF: $OUT" >> "$LOG"
        fi
    done
}

wifi7_mlo_health() {
    section "WIFI7 / MLO HEALTH"
    MLO="/tmp/bgw620_mlo_${TS}.tmp"
    CUR="/tmp/bgw620_curppr_${TS}.tmp"
    EHT="/tmp/bgw620_eht_${TS}.tmp"
    wl -i wl0 mlo info > "$MLO" 2>&1
    wl -i wl0 curppr > "$CUR" 2>&1
    wl -i wl0 eht > "$EHT" 2>&1
    cat "$MLO" "$CUR" "$EHT" >> "$LOG" 2>&1
    MLO_ACTIVE=`grep 'MLO_ACTIVE' "$MLO" | head -1 | sed 's/^ *//'`
    MLD_LINKS=`grep 'MLD0::' "$MLO" | head -1 | sed 's/.*nlink //' | awk '{print $1}'`
    [ -z "$MLD_LINKS" ] && MLD_LINKS=`wl -i wl0 mld_nlinks 2>/dev/null | head -1 | sed 's/^ *//'`
    CUR_CHAN=`grep 'Current channel:' "$CUR" | head -1 | awk -F: '{print $2}' | sed 's/^ *//'`
    W320=`grep -c '320MHz\|/320' "$CUR" 2>/dev/null`
    EHTVAL=`cat "$EHT" | head -1 | sed 's/^ *//'`
    ACTIVE_LINKS=`grep -c 'link[0-9]:' "$MLO" 2>/dev/null`
    [ -z "$MLO_ACTIVE" ] && MLO_ACTIVE="unknown"; [ -z "$MLD_LINKS" ] && MLD_LINKS="unknown"; [ -z "$CUR_CHAN" ] && CUR_CHAN="unknown"; [ -z "$W320" ] && W320=0; [ -z "$EHTVAL" ] && EHTVAL="unknown"; [ -z "$ACTIVE_LINKS" ] && ACTIVE_LINKS=0
    R="PASS"; N="WiFi7 MLO data collected"
    if ! echo "$MLO_ACTIVE" | grep -q 'TRUE'; then R="WARN"; N="MLO active not TRUE"; fi
    if [ "$W320" -eq 0 ]; then R="WARN"; N="320MHz evidence not detected"; fi
    csv_row "wifi7" "mlo_health" "mlo_active" "$MLO_ACTIVE" "$R" "$N"
    csv_row "wifi7" "mlo_health" "mld_links" "$MLD_LINKS" "INFO" "MLO link count"
    csv_row "wifi7" "mlo_health" "active_link_count" "$ACTIVE_LINKS" "INFO" "MLO info link lines"
    csv_row "wifi7" "mlo_health" "current_chanspec" "$CUR_CHAN" "INFO" "Current channel from curppr"
    csv_row "wifi7" "mlo_health" "width_320_evidence_count" "$W320" "INFO" "320MHz evidence count"
    csv_row "wifi7" "mlo_health" "eht" "$EHTVAL" "INFO" "EHT value"
    rm -f "$MLO" "$CUR" "$EHT"
}

acs_channel_health() {
    section "ACS / CHANNEL HEALTH"
    for i in wl0 wl1 wl2
    do
        REC="/tmp/bgw620_${i}_acs_record_${TS}.tmp"
        CS="/tmp/bgw620_${i}_cscore_${TS}.tmp"
        CH="/tmp/bgw620_${i}_chanim_${TS}.tmp"
        acs_cli2 -i "$i" dump acs_record > "$REC" 2>&1
        acs_cli2 -i "$i" dump cscore > "$CS" 2>&1
        wl -i "$i" chanim_stats > "$CH" 2>&1
        cat "$REC" "$CS" "$CH" >> "$LOG" 2>&1
        LAST=`awk 'NF>=4 && $1 ~ /^[0-9]/ {line=$0} END {print line}' "$REC"`
        LTRIG=`echo "$LAST" | awk '{print $3}'`
        LCHAN=`echo "$LAST" | awk '{print $4}'`
        IOCTL=`grep -c 'IOCTL' "$REC" 2>/dev/null`
        NONACS=`grep -c 'NONACS' "$REC" 2>/dev/null`
        EXC=`grep -c 'Invalid:EXCLUDE' "$CS" 2>/dev/null`
        [ -z "$LTRIG" ] && LTRIG="unknown"; [ -z "$LCHAN" ] && LCHAN="unknown"; [ -z "$IOCTL" ] && IOCTL=0; [ -z "$NONACS" ] && NONACS=0; [ -z "$EXC" ] && EXC=0
        csv_row "acs" "acs_record" "$i last_trigger" "$LTRIG" "INFO" "Last ACS trigger"
        csv_row "acs" "acs_record" "$i last_chanspec" "$LCHAN" "INFO" "Last ACS chanspec"
        csv_row "acs" "acs_record" "$i ioctl_count" "$IOCTL" "INFO" "IOCTL trigger count"
        csv_row "acs" "acs_record" "$i nonacs_count" "$NONACS" "INFO" "NONACS trigger count"
        csv_row "acs" "cscore" "$i invalid_exclude_count" "$EXC" "INFO" "Invalid EXCLUDE count"
        rm -f "$REC" "$CS" "$CH"
    done

    section "MAP CLI CHANNEL SELECTION"
    map_cli --command dumpChanSel --payload '{"extended": true}' >> "$LOG" 2>&1
    csv_row "acs" "map_cli" "dumpChanSel" "captured" "INFO" "Full dumpChanSel saved to log"
}

cloud_channel_health() {
    section "CLOUD CHANNEL MANAGEMENT HEALTH"
    if command_exists eco_envoy; then
        eco_envoy -c get Device.WiFi.Radio.*.X_ATT_ChannelSelectInuse >> "$LOG" 2>&1
        eco_envoy -c get Device.WiFi.MultiAP.APDevice.*.Radio.*.X_ATT_CloudChannelManagementEnable >> "$LOG" 2>&1
        eco_envoy -c get Device.WiFi.X_ATT_CloudChannelManagement_ExtenderEnable >> "$LOG" 2>&1
        csv_row "acs" "cloud_channel" "eco_envoy_status" "captured" "INFO" "Cloud channel management data saved to log"
    else
        csv_row "acs" "cloud_channel" "eco_envoy_status" "not_found" "SKIP" "eco_envoy not available"
    fi
    if command_exists envoy-cmd; then
        envoy-cmd get Device.WiFi.X_ATT_AFC. >> "$LOG" 2>&1
        csv_row "acs" "afc" "afc_status" "captured" "INFO" "AFC status saved to log"
    fi
}

ceventc_auth_health() {
    section "CEVENTC AUTHENTICATION / DROP HEALTH"
    TMP="/tmp/bgw620_ceventc_${TS}.tmp"
    ceventc dump > "$TMP" 2>&1
    cat "$TMP" >> "$LOG"
    AUTH=`grep -c 'E_AUTH/' "$TMP" 2>/dev/null`
    ASSOC=`grep -c 'E_ASSOC/' "$TMP" 2>/dev/null`
    AUTHZ=`grep -c 'E_AUTHORIZED' "$TMP" 2>/dev/null`
    DIS=`grep -c 'E_DISASSOC' "$TMP" 2>/dev/null`
    DEAUTH=`grep -c 'DEAUTH\|E_DEAUTH' "$TMP" 2>/dev/null`
    SAE=`grep -c 'SAE_AUTH' "$TMP" 2>/dev/null`
    M1=`grep -c 'M1_TX' "$TMP" 2>/dev/null`
    M2=`grep -c 'M2_RX' "$TMP" 2>/dev/null`
    M3=`grep -c 'M3_TX' "$TMP" 2>/dev/null`
    M4=`grep -c 'M4_RX' "$TMP" 2>/dev/null`
    [ -z "$AUTH" ] && AUTH=0; [ -z "$ASSOC" ] && ASSOC=0; [ -z "$AUTHZ" ] && AUTHZ=0; [ -z "$DIS" ] && DIS=0; [ -z "$DEAUTH" ] && DEAUTH=0; [ -z "$SAE" ] && SAE=0
    DIS_R="PASS"; DIS_N="Normal disassociation event count"
    if [ "$DIS" -gt 30 ]; then DIS_R="WARN"; DIS_N="High disassociation event count"; fi
    csv_row "ceventc" "auth_drop" "auth_events" "$AUTH" "INFO" "E_AUTH count"
    csv_row "ceventc" "auth_drop" "assoc_events" "$ASSOC" "INFO" "E_ASSOC count"
    csv_row "ceventc" "auth_drop" "authorized_events" "$AUTHZ" "PASS" "E_AUTHORIZED count"
    csv_row "ceventc" "auth_drop" "disassoc_events" "$DIS" "INFO" "E_DISASSOC count"
    csv_row "ceventc" "auth_drop" "disassoc_health" "$DIS" "$DIS_R" "$DIS_N"
    csv_row "ceventc" "auth_drop" "deauth_events" "$DEAUTH" "INFO" "DEAUTH count"
    csv_row "ceventc" "auth_drop" "sae_events" "$SAE" "INFO" "SAE_AUTH count"
    csv_row "ceventc" "auth_drop" "m1_m2_m3_m4" "$M1/$M2/$M3/$M4" "INFO" "4-way handshake counts"
    rm -f "$TMP"
}

neighbor_health() {
    section "NEIGHBOR HEALTH"
    ip neigh show >> "$LOG" 2>&1
    FAILED=`ip neigh show 2>/dev/null | grep -c FAILED`
    INCOMPLETE=`ip neigh show 2>/dev/null | grep -c INCOMPLETE`
    REACHABLE=`ip neigh show 2>/dev/null | grep -c REACHABLE`
    STALE=`ip neigh show 2>/dev/null | grep -c STALE`
    [ -z "$FAILED" ] && FAILED=0; [ -z "$INCOMPLETE" ] && INCOMPLETE=0; [ -z "$REACHABLE" ] && REACHABLE=0; [ -z "$STALE" ] && STALE=0
    R="PASS"; N="Normal FAILED neighbor count"
    if [ "$FAILED" -gt 20 ]; then R="FAIL"; N="High FAILED neighbor count"; elif [ "$FAILED" -gt 5 ]; then R="WARN"; N="Moderate FAILED neighbor count"; fi
    csv_row "network" "neighbor" "failed" "$FAILED" "$R" "$N"
    csv_row "network" "neighbor" "incomplete" "$INCOMPLETE" "INFO" "INCOMPLETE neighbor count"
    csv_row "network" "neighbor" "reachable" "$REACHABLE" "INFO" "REACHABLE neighbor count"
    csv_row "network" "neighbor" "stale" "$STALE" "INFO" "STALE neighbor count"
}

dns_health() {
    section "DNS / NETWORK HEALTH"
    if [ -r /etc/resolv.conf ]; then
        cat /etc/resolv.conf >> "$LOG" 2>&1
        DNS1=`awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null`
        [ -n "$DNS1" ] && csv_row "dns" "config" "primary_dns" "$DNS1" "INFO" "Primary nameserver from resolv.conf"
    fi
    if command_exists nslookup; then
        nslookup att.com >> "$LOG" 2>&1
        if nslookup att.com >/tmp/bgw620_dns_${TS}.tmp 2>&1; then
            csv_row "dns" "resolution" "att.com" "resolved" "PASS" "nslookup att.com succeeded"
        else
            csv_row "dns" "resolution" "att.com" "failed" "WARN" "nslookup att.com failed"
        fi
        cat /tmp/bgw620_dns_${TS}.tmp >> "$LOG" 2>&1
        rm -f /tmp/bgw620_dns_${TS}.tmp
    else
        csv_row "dns" "resolution" "nslookup" "not_found" "SKIP" "nslookup not available"
    fi
    if command_exists tr69; then
        tr69 get InternetGatewayDevice.Firewall.X_ATT_ICMPErrorResponseSuppress >> "$LOG" 2>&1
        ICMP=`tr69 get InternetGatewayDevice.Firewall.X_ATT_ICMPErrorResponseSuppress 2>/dev/null | awk '{print $NF}' | tail -1`
        [ -z "$ICMP" ] && ICMP="unknown"
        csv_row "dns" "icmp_suppression" "X_ATT_ICMPErrorResponseSuppress" "$ICMP" "INFO" "ICMP error response suppression state"
        tr69 get InternetGatewayDevice.X_ATT_NAT.MaxSessionsExceeded >> "$LOG" 2>&1
        NAT=`tr69 get InternetGatewayDevice.X_ATT_NAT.MaxSessionsExceeded 2>/dev/null | awk '{print $NF}' | tail -1`
        [ -z "$NAT" ] && NAT="unknown"
        NR="PASS"; NN="NAT max sessions not exceeded"
        if [ "$NAT" != "0" ] && [ "$NAT" != "unknown" ]; then NR="WARN"; NN="NAT max sessions exceeded counter is non-zero"; fi
        csv_row "network" "nat" "MaxSessionsExceeded" "$NAT" "$NR" "$NN"
    else
        csv_row "dns" "icmp_suppression" "tr69" "not_found" "SKIP" "tr69 not available"
    fi
}

stability_health() {
    section "STABILITY HEALTH"
    run_cshell "show process-restart" "show process-restart"
    run_cshell "show hbmon" "show hbmon"
    run_cshell "show crash" "show crash"
    run_cshell "show crashlog" "show crashlog"
    run_cshell "show kfm crash" "show kfm crash"
    if [ -r /data/system/reboothistory.txt ]; then
        section "REBOOT HISTORY"
        cat /data/system/reboothistory.txt >> "$LOG" 2>&1
        csv_row "stability" "reboot_history" "file" "/data/system/reboothistory.txt" "INFO" "Reboot history saved to log"
    else
        csv_row "stability" "reboot_history" "file" "not_found" "SKIP" "No reboothistory.txt"
    fi
    dmesg | grep -iE 'oom|out of memory|segfault|panic|watchdog|crash|dhd|wl.*error|error' >> "$LOG" 2>&1
    csv_row "stability" "dmesg_filtered" "status" "captured" "INFO" "Filtered dmesg saved to log"
}

client_lookup() {
    echo ""
    echo -n "Enter client MAC to lookup: "
    read CMAC
    [ -z "$CMAC" ] && echo "No MAC entered." && return
    section "CLIENT LOOKUP $CMAC"
    cshell -c "show ip lan" 2>/dev/null | grep -i "$CMAC" >> "$LOG" 2>&1
    ceventc -m "$CMAC" dump >> "$LOG" 2>&1
    csv_row "client" "lookup" "mac" "$CMAC" "INFO" "show ip lan and ceventc -m output saved to log"
}

overall_health() {
    section "OVERALL HEALTH SUMMARY"
    WARN=`grep -c ',"WARN",' "$CSV" 2>/dev/null`
    FAIL=`grep -c ',"FAIL",' "$CSV" 2>/dev/null`
    [ -z "$WARN" ] && WARN=0; [ -z "$FAIL" ] && FAIL=0
    OVERALL="PASS"
    if [ "$FAIL" -gt 0 ]; then OVERALL="FAIL"; elif [ "$WARN" -gt 0 ]; then OVERALL="PASS_WITH_WARNINGS"; fi
    log_line "WARN rows: $WARN"
    log_line "FAIL rows: $FAIL"
    log_line "Overall : $OVERALL"
    csv_row "summary" "overall" "warn_count" "$WARN" "INFO" "Total WARN rows"
    csv_row "summary" "overall" "fail_count" "$FAIL" "INFO" "Total FAIL rows"
    csv_row "summary" "overall" "overall_health" "$OVERALL" "$OVERALL" "Overall health result"
}

upload_and_convert() {
    section "UPLOAD TO FAILSAFE"
    REMOTE_DIR="$FAILSAFE_BASE/$SERIAL_SAFE"
    log_line "Failsafe target: $FAILSAFE_USER@$FAILSAFE_HOST:$REMOTE_DIR"

    ssh -p "$FAILSAFE_PORT" "$FAILSAFE_USER@$FAILSAFE_HOST" "mkdir -p '$REMOTE_DIR'" >> "$LOG" 2>&1
    if [ "$?" -ne 0 ]; then
        csv_row "upload" "failsafe" "mkdir" "failed" "FAIL" "$REMOTE_DIR"
        log_line "Failed to create remote directory."
        return 1
    fi

    scp -P "$FAILSAFE_PORT" "$LOG" "$CSV" "$FAILSAFE_USER@$FAILSAFE_HOST:$REMOTE_DIR/" >> "$LOG" 2>&1
    if [ "$?" -eq 0 ]; then
        csv_row "upload" "failsafe" "upload_status" "uploaded" "PASS" "$REMOTE_DIR"
        log_line "Upload completed."
    else
        csv_row "upload" "failsafe" "upload_status" "failed" "FAIL" "$REMOTE_DIR"
        log_line "Upload failed."
        return 1
    fi

    CSV_NAME=`basename "$CSV"`
    XLSX_NAME=`echo "$CSV_NAME" | sed 's/\.csv$/.xlsx/'`

    section "XLSX CONVERSION ON FAILSAFE"
    ssh -p "$FAILSAFE_PORT" "$FAILSAFE_USER@$FAILSAFE_HOST" "cat > '$REMOTE_DIR/csv_to_xlsx.py' << 'PYEOF'
import csv, sys
try:
    from openpyxl import Workbook
    from openpyxl.styles import Font, PatternFill, Alignment
    from openpyxl.utils import get_column_letter
except Exception as e:
    print('OPENPYXL_IMPORT_ERROR:', e)
    sys.exit(2)

csv_file = sys.argv[1]
xlsx_file = sys.argv[2]
wb = Workbook()
ws = wb.active
ws.title = 'BGW620 Health'
with open(csv_file, newline='', encoding='utf-8', errors='replace') as f:
    for row in csv.reader(f):
        ws.append(row)
header_fill = PatternFill(start_color='1F4E78', end_color='1F4E78', fill_type='solid')
header_font = Font(color='FFFFFF', bold=True)
for cell in ws[1]:
    cell.fill = header_fill
    cell.font = header_font
    cell.alignment = Alignment(horizontal='center')
headers = [c.value for c in ws[1]]
result_col = None
for idx, h in enumerate(headers, start=1):
    if h and str(h).lower() == 'result':
        result_col = idx
        break
fills = {
    'PASS': PatternFill(start_color='C6EFCE', end_color='C6EFCE', fill_type='solid'),
    'WARN': PatternFill(start_color='FFEB9C', end_color='FFEB9C', fill_type='solid'),
    'FAIL': PatternFill(start_color='FFC7CE', end_color='FFC7CE', fill_type='solid'),
    'INFO': PatternFill(start_color='D9EAF7', end_color='D9EAF7', fill_type='solid'),
    'SKIP': PatternFill(start_color='E7E6E6', end_color='E7E6E6', fill_type='solid'),
}
if result_col:
    for r in range(2, ws.max_row + 1):
        c = ws.cell(row=r, column=result_col)
        v = str(c.value).upper() if c.value else ''
        if v in fills:
            c.fill = fills[v]
ws.freeze_panes = 'A2'
ws.auto_filter.ref = ws.dimensions
for col in range(1, ws.max_column + 1):
    max_len = 0
    for cell in ws[get_column_letter(col)]:
        if cell.value is not None:
            max_len = max(max_len, len(str(cell.value)))
    ws.column_dimensions[get_column_letter(col)].width = min(max_len + 2, 60)
wb.save(xlsx_file)
PYEOF
python3 '$REMOTE_DIR/csv_to_xlsx.py' '$REMOTE_DIR/$CSV_NAME' '$REMOTE_DIR/$XLSX_NAME'" >> "$LOG" 2>&1

    if [ "$?" -eq 0 ]; then
        csv_row "upload" "xlsx_conversion" "xlsx_file" "$XLSX_NAME" "PASS" "$REMOTE_DIR/$XLSX_NAME"
        log_line "XLSX created: $REMOTE_DIR/$XLSX_NAME"
        scp -P "$FAILSAFE_PORT" "$CSV" "$FAILSAFE_USER@$FAILSAFE_HOST:$REMOTE_DIR/" >> "$LOG" 2>&1
    else
        csv_row "upload" "xlsx_conversion" "xlsx_file" "failed" "WARN" "CSV uploaded but XLSX conversion failed. Check python3/openpyxl on failsafe."
        log_line "XLSX conversion failed. CSV and LOG are still uploaded."
    fi

    echo ""
    echo "Remote directory: $REMOTE_DIR"
    echo "CSV: $REMOTE_DIR/$CSV_NAME"
    echo "LOG: $REMOTE_DIR/`basename "$LOG"`"
    echo "XLSX: $REMOTE_DIR/$XLSX_NAME"
}

full_suite_no_upload() {
    wifi_detail_health
    wifi_client_distribution
    wifi7_mlo_health
    safe_nvram_backhaul_health
    bss_role_scan
    acs_channel_health
    cloud_channel_health
    ceventc_auth_health
    neighbor_health
    memory_health
    dns_health
    stability_health
    overall_health
}

option99_full_upload() {
    full_suite_no_upload
    upload_and_convert
    section "BGW620 HEALTH SUITE COMPLETE"
    log_line "CSV: $CSV"
    log_line "LOG: $LOG"
    log_line "Serial: $SERIAL_SAFE"
    echo ""
    echo "============================================================"
    echo " BGW620 HEALTH SUITE COMPLETE"
    echo "============================================================"
    echo "Serial : $SERIAL_SAFE"
    echo "CSV    : $CSV"
    echo "LOG    : $LOG"
    echo "Remote : $FAILSAFE_BASE/$SERIAL_SAFE"
    echo "============================================================"
}

show_menu() {
    echo ""
    echo "============================================================"
    echo " BGW620 WiFi/PWiFi Health Analyzer $VERSION"
    echo "============================================================"
    echo " 1) Full Health Suite (no upload)"
    echo " 2) WiFi Health Only"
    echo " 3) Client Distribution Only"
    echo " 4) WiFi7 / MLO Health Only"
    echo " 5) Backhaul / EasyMesh / BSS Role Health Only"
    echo " 6) ACS / Channel / Cloud Management Health Only"
    echo " 7) CEVENTC Auth / Drop Health Only"
    echo " 8) Neighbor Health Only"
    echo " 9) System / Memory Health Only"
    echo "10) DNS / NAT Health Only"
    echo "11) Stability / Crash / Reboot Health Only"
    echo "12) Client Lookup by MAC"
    echo "13) Upload Current CSV/LOG + Convert XLSX"
    echo "14) Print Current File Paths"
    echo "99) Full Suite + One CSV + One LOG + Upload + XLSX"
    echo " 0) Exit"
    echo "============================================================"
    echo -n "Select option: "
}

init_report
while true
 do
    show_menu
    read OPT
    case "$OPT" in
        1) full_suite_no_upload ;;
        2) wifi_detail_health ;;
        3) wifi_client_distribution ;;
        4) wifi7_mlo_health ;;
        5) safe_nvram_backhaul_health; bss_role_scan ;;
        6) acs_channel_health; cloud_channel_health ;;
        7) ceventc_auth_health ;;
        8) neighbor_health ;;
        9) memory_health ;;
        10) dns_health ;;
        11) stability_health ;;
        12) client_lookup ;;
        13) upload_and_convert ;;
        14) print_paths ;;
        99) option99_full_upload ;;
        0|q|Q) print_paths; exit 0 ;;
        *) echo "Invalid option" ;;
    esac
 done
