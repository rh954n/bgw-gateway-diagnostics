#!/bin/sh
# ============================================================
# BGW620 WiFi / PWiFi Health Analyzer V3.5.1
# Read-only diagnostics. No config changes are performed.
# V3.5.1 Fix: SCP-only upload to BCEO. No ssh, no mkdir, no XLSX conversion.
# ============================================================

VERSION="V3.5.1"
TS=`date +%Y%m%d_%H%M%S 2>/dev/null`; [ -z "$TS" ] && TS="manual"
HOSTNAME_RG=`hostname 2>/dev/null`; [ -z "$HOSTNAME_RG" ] && HOSTNAME_RG="dsldevice"
MODEL="BGW620"
BCEO_USER="rh954n"
BCEO_HOST="99.124.173.137"
BCEO_PORT="2245"
BCEO_DIR="/home/rh954n/BGW620"

SERIAL=`nvram show 2>/dev/null | grep '^dev_invt_sn=' | head -1 | cut -d= -f2`
[ -z "$SERIAL" ] && SERIAL=`nvram show 2>/dev/null | grep '^boardnum=' | head -1 | cut -d= -f2`
[ -z "$SERIAL" ] && SERIAL="$HOSTNAME_RG"
SERIAL_SAFE=`echo "$SERIAL" | sed 's/[^A-Za-z0-9._-]/_/g'`
BASE="/tmp/bgw620_health_${SERIAL_SAFE}_${TS}"
CSV="${BASE}.csv"
LOG="${BASE}.log"

esc(){ echo "$1" | sed 's/"/""/g'; }
csv_header(){ echo 'Timestamp,RG_Host,Model,Serial,ScriptVersion,Category,Test,Metric,Value,Result,Notes' > "$CSV"; }
csv_row(){
    NOW=`date '+%Y-%m-%d %H:%M:%S' 2>/dev/null`
    A=`esc "$1"`; B=`esc "$2"`; C=`esc "$3"`; D=`esc "$4"`; E=`esc "$5"`; F=`esc "$6"`
    echo "\"$NOW\",\"$HOSTNAME_RG\",\"$MODEL\",\"$SERIAL_SAFE\",\"$VERSION\",\"$A\",\"$B\",\"$C\",\"$D\",\"$E\",\"$F\"" >> "$CSV"
}
log(){ echo "$1" | tee -a "$LOG"; }
section(){ log ""; log "============================================================"; log "$1"; log "============================================================"; }
exists(){ command -v "$1" >/dev/null 2>&1; }
run_save(){ DESC="$1"; shift; section "$DESC"; log "Command: $*"; "$@" >> "$LOG" 2>&1; RC=$?; csv_row command "$DESC" return_code "$RC" "INFO" "$*"; return $RC; }

init_report(){
    csv_header
    section "BGW620 HEALTH ANALYZER START"
    log "Version : $VERSION"
    log "Host    : $HOSTNAME_RG"
    log "Serial  : $SERIAL_SAFE"
    log "CSV     : $CSV"
    log "LOG     : $LOG"
    csv_row system start script bgw620_wifi_pwifi_health_v3_5_1 INFO "Started BGW620 health analyzer"
}

memory_health(){
    section "SYSTEM / MEMORY HEALTH"
    if exists free; then
        free -m >> "$LOG" 2>&1
        LINE=`free -m 2>/dev/null | awk '/^Mem:/ {print}'`
        MT=`echo "$LINE"|awk '{print $2}'`; MU=`echo "$LINE"|awk '{print $3}'`; MF=`echo "$LINE"|awk '{print $4}'`; BC=`echo "$LINE"|awk '{print $6}'`; MA=`echo "$LINE"|awk '{print $7}'`
        [ -z "$MA" ] && MA=0
        R=PASS; N="Available memory healthy"
        if [ "$MA" -lt 250 ]; then R=FAIL; N="Available memory below 250 MB"; elif [ "$MA" -lt 500 ]; then R=WARN; N="Available memory below 500 MB"; fi
        csv_row memory free_m mem_total_mb "$MT" INFO "Total RAM"
        csv_row memory free_m mem_used_mb "$MU" INFO "Used RAM"
        csv_row memory free_m mem_free_mb "$MF" INFO "Free RAM"
        csv_row memory free_m buff_cache_mb "$BC" INFO "Buffer/cache RAM"
        csv_row memory free_m mem_available_mb "$MA" "$R" "$N"
    else csv_row memory free_m status free_not_found SKIP "free command missing"; fi

    if [ -r /proc/meminfo ]; then
        cat /proc/meminfo >> "$LOG" 2>&1
        for key in MemAvailable MemFree Slab SUnreclaim CmaFree; do
            KB=`awk -v k="$key:" '$1==k {print $2}' /proc/meminfo 2>/dev/null`; [ -z "$KB" ] && KB=0
            MB=`awk -v k="$KB" 'BEGIN{printf "%d", k/1024}'`
            RES=INFO; NOTE="/proc/meminfo value"
            if [ "$key" = "SUnreclaim" ]; then RES=PASS; NOTE="Kernel unreclaimable slab"; [ "$MB" -gt 700 ] && RES=FAIL; [ "$MB" -gt 400 ] && [ "$RES" != FAIL ] && RES=WARN; fi
            csv_row memory proc_meminfo "$key" "${MB} MB" "$RES" "$NOTE"
        done
    fi

    section "TOP MEMORY PROCESS SAMPLE"
    if exists pidstat; then
        pidstat -ruh >> "$LOG" 2>&1
        pidstat -ruh 2>/dev/null | awk 'NR>2 && $14 ~ /^[0-9.]+$/ && $14 >= 2 {print $15","$14}' | while IFS=, read P M; do [ -n "$P" ] && csv_row memory pidstat "$P" "$M%" INFO "Process using >=2 percent memory"; done
    else
        top -b -n1 2>/dev/null | head -40 >> "$LOG" 2>&1
        csv_row memory top status captured INFO "top -b -n1 head -40 saved to log"
    fi
}

safe_backhaul(){
    section "BACKHAUL / EASYMESH SAFE NVRAM"
    TMP=/tmp/bgw620_nvram_safe_$TS.tmp
    nvram show 2>/dev/null | grep -E "map_agent_active_bh_type|map_onboarded|multiap_mode|wbd_ifnames|wl[0-2]_band_flag|map_bh|Backhaul" > "$TMP" 2>/dev/null
    cat "$TMP" >> "$LOG" 2>&1
    BH=`grep '^map_agent_active_bh_type=' "$TMP"|tail -1|cut -d= -f2`; [ -z "$BH" ] && BH=unknown
    ON=`grep '^map_onboarded=' "$TMP"|tail -1|cut -d= -f2`; [ -z "$ON" ] && ON=unknown
    MM=`grep '^multiap_mode=' "$TMP"|tail -1|cut -d= -f2`; [ -z "$MM" ] && MM=unknown
    WBD=`grep '^wbd_ifnames=' "$TMP"|tail -1|cut -d= -f2-`; [ -z "$WBD" ] && WBD=unknown
    R=PASS; N="Backhaul/EasyMesh data collected"; [ "$ON" != 1 ] && R=WARN && N="map_onboarded not 1 or unknown"
    csv_row backhaul safe_nvram backhaul_type "$BH" "$R" "$N"
    csv_row backhaul safe_nvram map_onboarded "$ON" INFO "EasyMesh onboarded flag"
    csv_row backhaul safe_nvram multiap_mode "$MM" INFO "MultiAP mode"
    csv_row backhaul safe_nvram wbd_ifnames "$WBD" INFO "WBD interfaces"
    for i in 0 1 2; do V=`grep "^wl${i}_band_flag=" "$TMP"|tail -1|cut -d= -f2`; csv_row backhaul safe_nvram "wl${i}_band_flag" "$V" INFO "Radio band flag"; done
    rm -f "$TMP"
}

wifi_distribution(){
    section "WIFI CLIENT DISTRIBUTION"
    TMP=/tmp/bgw620_assoc_$TS.tmp
    wl -e assoclist > "$TMP" 2>&1
    cat "$TMP" >> "$LOG"
    TOTAL=`grep -c '^assoclist ' "$TMP" 2>/dev/null`; [ -z "$TOTAL" ] && TOTAL=0
    csv_row wifi client_distribution total_assoc_clients "$TOTAL" INFO "Total clients from wl -e assoclist"
    awk '/^---/ {iface=$2; band=$3; count[iface]=0; b[iface]=band; order[++n]=iface; next} /^assoclist/ {count[iface]++} END {for(i=1;i<=n;i++) print order[i]","b[order[i]]","count[order[i]]}' "$TMP" | while IFS=, read I B C; do [ -n "$I" ] && csv_row wifi client_distribution "$I $B" "$C" INFO "Associated clients"; done
    rm -f "$TMP"
}

wifi_status(){
    section "WIFI RADIO STATUS"
    for IF in wl0 wl1 wl2; do
        TMP=/tmp/${IF}_status_$TS.tmp
        wl -i "$IF" status > "$TMP" 2>&1; cat "$TMP" >> "$LOG"
        CH=`grep 'Channel:' "$TMP"|head -1|sed 's/.*Channel: *//'|awk '{print $1}'`; [ -z "$CH" ] && CH=unknown
        CS=`grep 'Chanspec:' "$TMP"|head -1|sed 's/^ *Chanspec: *//'`; [ -z "$CS" ] && CS=unknown
        U=`grep 'QBSS Channel Utilization' "$TMP"|head -1|sed 's/.*(//'|sed 's/ %).*//'`; [ -z "$U" ] && U=unknown
        csv_row wifi radio_status "$IF channel" "$CH" INFO "Radio channel"
        csv_row wifi radio_status "$IF chanspec" "$CS" INFO "Radio chanspec"
        csv_row wifi radio_status "$IF utilization_percent" "$U" INFO "QBSS utilization"
        rm -f "$TMP"
    done
    run_save "wl -e bss" wl -e bss
}

bss_role_scan(){
    section "FRONTHAUL / BACKHAUL BSS ROLE SCAN"
    for IF in wl0 wl0.1 wl0.2 wl0.3 wl0.4 wl0.5 wl0.6 wl0.7 wl1 wl1.1 wl1.2 wl1.3 wl1.4 wl1.5 wl1.6 wl1.7 wl2 wl2.1 wl2.2 wl2.3 wl2.4 wl2.5 wl2.6 wl2.7; do
        OUT=`wl -i "$IF" map 2>/dev/null`
        echo "$IF: $OUT" >> "$LOG"
        echo "$OUT"|grep -q 'Backhaul-BSS' && { csv_row backhaul bss_role_scan "$IF" Backhaul-BSS PASS "Backhaul BSS detected"; wl -i "$IF" bs_data -noreset >> "$LOG" 2>&1; continue; }
        echo "$OUT"|grep -q 'Fronthaul-BSS' && csv_row backhaul bss_role_scan "$IF" Fronthaul-BSS INFO "Fronthaul BSS detected"
    done
}

wifi7_mlo(){
    section "WIFI7 / MLO HEALTH"
    TMP=/tmp/bgw620_mlo_$TS.tmp; CUR=/tmp/bgw620_curppr_$TS.tmp; EHT=/tmp/bgw620_eht_$TS.tmp
    wl -i wl0 mlo info > "$TMP" 2>&1; wl -i wl0 curppr > "$CUR" 2>&1; wl -i wl0 eht > "$EHT" 2>&1
    cat "$TMP" "$CUR" "$EHT" >> "$LOG" 2>&1
    MLO=`grep 'MLO_ACTIVE' "$TMP"|head -1|sed 's/^ *//'`; [ -z "$MLO" ] && MLO=unknown
    LINKS=`grep 'MLD0::' "$TMP"|head -1|sed 's/.*nlink //'|awk '{print $1}'`; [ -z "$LINKS" ] && LINKS=unknown
    CURC=`grep 'Current channel:' "$CUR"|head -1|awk -F: '{print $2}'|sed 's/^ *//'`; [ -z "$CURC" ] && CURC=unknown
    W320=`grep -c '320MHz\|/320' "$CUR" 2>/dev/null`; [ -z "$W320" ] && W320=0
    EHTV=`head -1 "$EHT"|sed 's/^ *//'`; [ -z "$EHTV" ] && EHTV=unknown
    R=PASS; N="WiFi7 data collected"; echo "$MLO"|grep -q TRUE || R=WARN; [ "$W320" -eq 0 ] && R=WARN
    csv_row wifi7 mlo_health mlo_active "$MLO" "$R" "$N"
    csv_row wifi7 mlo_health mld_links "$LINKS" INFO "MLO link count"
    csv_row wifi7 mlo_health current_chanspec "$CURC" INFO "Current channel from curppr"
    csv_row wifi7 mlo_health width_320_evidence_count "$W320" INFO "320MHz evidence count"
    csv_row wifi7 mlo_health eht "$EHTV" INFO "EHT value"
    rm -f "$TMP" "$CUR" "$EHT"
}

acs_health(){
    section "ACS / CHANNEL HEALTH"
    for IF in wl0 wl1 wl2; do
        REC=/tmp/${IF}_acs_$TS.tmp; CS=/tmp/${IF}_cscore_$TS.tmp; CH=/tmp/${IF}_chanim_$TS.tmp
        acs_cli2 -i "$IF" dump acs_record > "$REC" 2>&1; acs_cli2 -i "$IF" dump cscore > "$CS" 2>&1; wl -i "$IF" chanim_stats > "$CH" 2>&1
        cat "$REC" "$CS" "$CH" >> "$LOG" 2>&1
        LAST=`awk 'NF>=4 && $1 ~ /^[0-9]/ {line=$0} END{print line}' "$REC"`
        TR=`echo "$LAST"|awk '{print $3}'`; [ -z "$TR" ] && TR=unknown
        LC=`echo "$LAST"|awk '{print $4}'`; [ -z "$LC" ] && LC=unknown
        IO=`grep -c IOCTL "$REC" 2>/dev/null`; NO=`grep -c NONACS "$REC" 2>/dev/null`; EX=`grep -c 'Invalid:EXCLUDE' "$CS" 2>/dev/null`
        csv_row acs acs_record "$IF last_trigger" "$TR" INFO "Last ACS trigger"
        csv_row acs acs_record "$IF last_chanspec" "$LC" INFO "Last ACS chanspec"
        csv_row acs acs_record "$IF ioctl_count" "$IO" INFO "IOCTL count"
        csv_row acs acs_record "$IF nonacs_count" "$NO" INFO "NONACS count"
        csv_row acs cscore "$IF invalid_exclude_count" "$EX" INFO "Invalid EXCLUDE count"
        rm -f "$REC" "$CS" "$CH"
    done
    map_cli --command dumpChanSel --payload '{"extended": true}' >> "$LOG" 2>&1
    csv_row acs map_cli dumpChanSel captured INFO "Full dumpChanSel saved to log"
}

cloud_channel(){
    section "CLOUD CHANNEL MANAGEMENT"
    if exists eco_envoy; then
        eco_envoy -c get Device.WiFi.Radio.*.X_ATT_ChannelSelectInuse >> "$LOG" 2>&1
        eco_envoy -c get Device.WiFi.MultiAP.APDevice.*.Radio.*.X_ATT_CloudChannelManagementEnable >> "$LOG" 2>&1
        eco_envoy -c get Device.WiFi.X_ATT_CloudChannelManagement_ExtenderEnable >> "$LOG" 2>&1
        csv_row acs cloud_channel eco_envoy_status captured INFO "Cloud channel data saved to log"
    else csv_row acs cloud_channel eco_envoy_status not_found SKIP "eco_envoy not available"; fi
    exists envoy-cmd && { envoy-cmd get Device.WiFi.X_ATT_AFC. >> "$LOG" 2>&1; csv_row acs afc afc_status captured INFO "AFC status saved to log"; }
}

ceventc_health(){
    section "CEVENTC AUTH / DROP HEALTH"
    TMP=/tmp/bgw620_ceventc_$TS.tmp; ceventc dump > "$TMP" 2>&1; cat "$TMP" >> "$LOG"
    AUTH=`grep -c 'E_AUTH/' "$TMP" 2>/dev/null`; ASSOC=`grep -c 'E_ASSOC/' "$TMP" 2>/dev/null`; AUTHZ=`grep -c 'E_AUTHORIZED' "$TMP" 2>/dev/null`; DIS=`grep -c 'E_DISASSOC' "$TMP" 2>/dev/null`; DE=`grep -c 'DEAUTH\|E_DEAUTH' "$TMP" 2>/dev/null`; SAE=`grep -c SAE_AUTH "$TMP" 2>/dev/null`
    [ -z "$DIS" ] && DIS=0; R=PASS; N="Normal disassociation count"; [ "$DIS" -gt 30 ] && R=WARN && N="High disassociation count"
    csv_row ceventc auth_drop auth_events "$AUTH" INFO "E_AUTH count"
    csv_row ceventc auth_drop assoc_events "$ASSOC" INFO "E_ASSOC count"
    csv_row ceventc auth_drop authorized_events "$AUTHZ" PASS "E_AUTHORIZED count"
    csv_row ceventc auth_drop disassoc_events "$DIS" INFO "E_DISASSOC count"
    csv_row ceventc auth_drop disassoc_health "$DIS" "$R" "$N"
    csv_row ceventc auth_drop deauth_events "$DE" INFO "DEAUTH count"
    csv_row ceventc auth_drop sae_events "$SAE" INFO "SAE_AUTH count"
    rm -f "$TMP"
}

neighbor_health(){
    section "NEIGHBOR HEALTH"
    ip neigh show >> "$LOG" 2>&1
    F=`ip neigh show 2>/dev/null|grep -c FAILED`; I=`ip neigh show 2>/dev/null|grep -c INCOMPLETE`; RCH=`ip neigh show 2>/dev/null|grep -c REACHABLE`; ST=`ip neigh show 2>/dev/null|grep -c STALE`
    RES=PASS; NOTE="Normal failed neighbor count"; [ "$F" -gt 20 ] && RES=FAIL && NOTE="High failed neighbor count"; [ "$F" -gt 5 ] && [ "$RES" != FAIL ] && RES=WARN && NOTE="Moderate failed neighbor count"
    csv_row network neighbor failed "$F" "$RES" "$NOTE"
    csv_row network neighbor incomplete "$I" INFO "INCOMPLETE neighbor count"
    csv_row network neighbor reachable "$RCH" INFO "REACHABLE neighbor count"
    csv_row network neighbor stale "$ST" INFO "STALE neighbor count"
}

dns_health(){
    section "DNS / NAT HEALTH"
    [ -r /etc/resolv.conf ] && { cat /etc/resolv.conf >> "$LOG"; DNS=`awk '/^nameserver/{print $2;exit}' /etc/resolv.conf`; [ -n "$DNS" ] && csv_row dns config primary_dns "$DNS" INFO "Primary DNS"; }
    if exists nslookup; then nslookup att.com >> "$LOG" 2>&1 && csv_row dns resolution att.com resolved PASS "nslookup succeeded" || csv_row dns resolution att.com failed WARN "nslookup failed"; else csv_row dns resolution nslookup not_found SKIP "nslookup unavailable"; fi
    if exists tr69; then
        IC=`tr69 get InternetGatewayDevice.Firewall.X_ATT_ICMPErrorResponseSuppress 2>/dev/null|awk '{print $NF}'|tail -1`; [ -z "$IC" ] && IC=unknown
        NAT=`tr69 get InternetGatewayDevice.X_ATT_NAT.MaxSessionsExceeded 2>/dev/null|awk '{print $NF}'|tail -1`; [ -z "$NAT" ] && NAT=unknown
        csv_row dns icmp_suppression X_ATT_ICMPErrorResponseSuppress "$IC" INFO "ICMP suppression state"
        NR=PASS; NN="NAT max sessions not exceeded"; [ "$NAT" != 0 ] && [ "$NAT" != unknown ] && NR=WARN && NN="NAT max sessions counter non-zero"
        csv_row network nat MaxSessionsExceeded "$NAT" "$NR" "$NN"
    else csv_row dns icmp_suppression tr69 not_found SKIP "tr69 unavailable"; fi
}

stability_health(){
    section "STABILITY / CRASH HEALTH"
    for CMD in "show process-restart" "show hbmon" "show crash" "show crashlog" "show kfm crash"; do
        if exists cshell; then cshell -c "$CMD" >> "$LOG" 2>&1; csv_row stability cshell "$CMD" captured INFO "Saved to log"; else csv_row stability cshell "$CMD" skipped SKIP "cshell not found"; fi
    done
    [ -r /data/system/reboothistory.txt ] && { cat /data/system/reboothistory.txt >> "$LOG" 2>&1; csv_row stability reboot_history file captured INFO "Saved to log"; } || csv_row stability reboot_history file not_found SKIP "No reboot history"
    dmesg | grep -iE 'oom|out of memory|segfault|panic|watchdog|crash|dhd|wl.*error|error' >> "$LOG" 2>&1
    csv_row stability dmesg_filtered status captured INFO "Filtered dmesg saved to log"
}

client_lookup(){
    echo -n "Enter client MAC to lookup: "; read MAC; [ -z "$MAC" ] && return
    section "CLIENT LOOKUP $MAC"
    exists cshell && cshell -c "show ip lan" 2>/dev/null | grep -i "$MAC" >> "$LOG"
    ceventc -m "$MAC" dump >> "$LOG" 2>&1
    csv_row client lookup mac "$MAC" INFO "Client lookup saved to log"
}

overall(){
    section "OVERALL HEALTH SUMMARY"
    W=`grep -c ',"WARN",' "$CSV" 2>/dev/null`; F=`grep -c ',"FAIL",' "$CSV" 2>/dev/null`; [ -z "$W" ] && W=0; [ -z "$F" ] && F=0
    O=PASS; [ "$F" -gt 0 ] && O=FAIL; [ "$F" -eq 0 ] && [ "$W" -gt 0 ] && O=PASS_WITH_WARNINGS
    log "WARN rows: $W"; log "FAIL rows: $F"; log "Overall : $O"
    csv_row summary overall warn_count "$W" INFO "Total WARN rows"
    csv_row summary overall fail_count "$F" INFO "Total FAIL rows"
    csv_row summary overall overall_health "$O" "$O" "Overall result"
}

upload_bceo(){
    section "UPLOAD TO BCEO USING SCP ONLY"
    CSVN=`basename "$CSV"`; LOGN=`basename "$LOG"`
    log "Target: $BCEO_USER@$BCEO_HOST:$BCEO_DIR/"
    log "No ssh/mkdir. No XLSX conversion. Enter BCEO password if prompted."
    if ! exists scp; then csv_row upload bceo_scp scp_binary not_found FAIL "scp missing"; echo "scp not found"; return 1; fi
    echo ""; echo "Uploading CSV: $CSVN"; echo "Enter BCEO password when prompted."
    scp -P "$BCEO_PORT" "$CSV" "$BCEO_USER@$BCEO_HOST:$BCEO_DIR/"; CRC=$?
    [ "$CRC" -eq 0 ] && csv_row upload bceo_scp csv_upload "$CSVN" PASS "$BCEO_DIR/$CSVN" || csv_row upload bceo_scp csv_upload "$CSVN" FAIL "scp rc=$CRC"
    echo ""; echo "Uploading LOG: $LOGN"; echo "Enter BCEO password when prompted."
    scp -P "$BCEO_PORT" "$LOG" "$BCEO_USER@$BCEO_HOST:$BCEO_DIR/"; LRC=$?
    [ "$LRC" -eq 0 ] && csv_row upload bceo_scp log_upload "$LOGN" PASS "$BCEO_DIR/$LOGN" || csv_row upload bceo_scp log_upload "$LOGN" FAIL "scp rc=$LRC"
    if [ "$CRC" -eq 0 ] && [ "$LRC" -eq 0 ]; then echo "Upload Complete: $BCEO_DIR/"; csv_row upload bceo_scp overall_upload uploaded PASS "$BCEO_DIR/"; else echo "Upload had errors: CSV_RC=$CRC LOG_RC=$LRC"; csv_row upload bceo_scp overall_upload failed FAIL "CSV_RC=$CRC LOG_RC=$LRC"; fi
    echo "XLSX conversion skipped. Open CSV in Excel on laptop and Save As .xlsx."
    csv_row upload xlsx_conversion status skipped SKIP "No server package install; Excel conversion on laptop"
}

full_suite(){ wifi_status; wifi_distribution; wifi7_mlo; safe_backhaul; bss_role_scan; acs_health; cloud_channel; ceventc_health; neighbor_health; memory_health; dns_health; stability_health; overall; }
option99(){ full_suite; upload_bceo; section "BGW620 HEALTH SUITE COMPLETE"; log "CSV: $CSV"; log "LOG: $LOG"; echo ""; echo "COMPLETE"; echo "CSV=$CSV"; echo "LOG=$LOG"; echo "BCEO=$BCEO_DIR/"; }
paths(){ echo ""; echo "CSV=$CSV"; echo "LOG=$LOG"; echo "SERIAL=$SERIAL_SAFE"; }
menu(){
    echo ""; echo "============================================================"; echo " BGW620 WiFi/PWiFi Health Analyzer $VERSION"; echo "============================================================"
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
    echo "13) Upload Current CSV/LOG to BCEO"
    echo "14) Print Current File Paths"
    echo "99) Full Suite + One CSV + One LOG + SCP Upload"
    echo " 0) Exit"
    echo "============================================================"; echo -n "Select option: "
}

init_report
while true; do
    menu; read OPT
    case "$OPT" in
        1) full_suite;; 2) wifi_status;; 3) wifi_distribution;; 4) wifi7_mlo;; 5) safe_backhaul; bss_role_scan;; 6) acs_health; cloud_channel;; 7) ceventc_health;; 8) neighbor_health;; 9) memory_health;; 10) dns_health;; 11) stability_health;; 12) client_lookup;; 13) upload_bceo;; 14) paths;; 99) option99;; 0|q|Q) paths; exit 0;; *) echo "Invalid option";;
    esac
done
