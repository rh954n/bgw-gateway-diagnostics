#!/bin/sh
# =====================================================================
# BGW620 WiFi / PWiFi Health Analyzer V3.5.4b
# Read-only diagnostics. No gateway configuration changes.
#
# V3.5.4b additions:
#   - BGW620-only naming and scope
#   - Generates health CSV, raw LOG, and validation summary CSV
#   - Option 99 uploads all three files in one /bin/scp operation
#   - Compact module scoring and ReviewRequired field
# =====================================================================

VERSION="V3.5.4b"
MODEL="BGW620"
TS=`date +%Y%m%d_%H%M%S 2>/dev/null`; [ -z "$TS" ] && TS=manual
RG_HOST=`hostname 2>/dev/null`; [ -z "$RG_HOST" ] && RG_HOST=dsldevice

BCEO_USER="rh954n"
BCEO_HOST="99.124.173.137"
BCEO_PORT="2245"
BCEO_DIR="/home/rh954n/BGW620"
SCPBIN="/bin/scp"

SERIAL=`nvram show 2>/dev/null | grep '^dev_invt_sn=' | head -1 | cut -d= -f2-`
[ -z "$SERIAL" ] && SERIAL=`nvram show 2>/dev/null | grep '^boardnum=' | head -1 | cut -d= -f2-`
[ -z "$SERIAL" ] && SERIAL="$RG_HOST"
SERIAL_SAFE=`echo "$SERIAL" | sed 's/[^A-Za-z0-9._-]/_/g'`

FIRMWARE=`nvram show 2>/dev/null | grep '^dev_invt_sw=' | head -1 | cut -d= -f2-`
[ -z "$FIRMWARE" ] && FIRMWARE=`nvram show 2>/dev/null | grep -E '^firmware_version=|^sw_version=' | head -1 | cut -d= -f2-`
[ -z "$FIRMWARE" ] && FIRMWARE="UNKNOWN"

BASE="/tmp/bgw620_health_${SERIAL_SAFE}_${TS}"
CSV="${BASE}.csv"
LOG="${BASE}.log"
SUMMARY="/tmp/bgw620_validation_summary_${SERIAL_SAFE}_${TS}.csv"

WIFI_STATUS=INFO; WIFI_EVIDENCE="Not run"
CLIENT_STATUS=INFO; CLIENT_EVIDENCE="Not run"
MLO_STATUS=INFO; MLO_EVIDENCE="Not run"
MESH_STATUS=INFO; MESH_EVIDENCE="Not run"
ACS_STATUS=INFO; ACS_EVIDENCE="Not run"
CEVENT_STATUS=INFO; CEVENT_EVIDENCE="Not run"
NEIGHBOR_STATUS=INFO; NEIGHBOR_EVIDENCE="Not run"
MEMORY_STATUS=INFO; MEMORY_EVIDENCE="Not run"
DNS_STATUS=INFO; DNS_EVIDENCE="Not run"
STABILITY_STATUS=INFO; STABILITY_EVIDENCE="Not run"
UPLOAD_STATUS=NOT_RUN
OVERALL_STATUS=NOT_RUN; OVERALL_SCORE=0; OVERALL_GRADE=NOT_RUN
REVIEW_MODULES=""

escape_csv(){ echo "$1" | sed 's/"/""/g'; }
log(){ echo "$1" | tee -a "$LOG"; }
section(){ log ""; log "============================================================"; log "$1"; log "============================================================"; }

csv_row(){
    NOW=`date '+%Y-%m-%d %H:%M:%S' 2>/dev/null`
    A=`escape_csv "$1"`; B=`escape_csv "$2"`; C=`escape_csv "$3"`
    D=`escape_csv "$4"`; E=`escape_csv "$5"`; F=`escape_csv "$6"`
    echo "\"$NOW\",\"$RG_HOST\",\"$MODEL\",\"$SERIAL_SAFE\",\"$FIRMWARE\",\"$VERSION\",\"$A\",\"$B\",\"$C\",\"$D\",\"$E\",\"$F\"" >> "$CSV"
}

summary_row(){
    NOW=`date '+%Y-%m-%d %H:%M:%S' 2>/dev/null`
    M=`escape_csv "$1"`; R=`escape_csv "$2"`; EV=`escape_csv "$4"`
    echo "\"$NOW\",\"$RG_HOST\",\"$MODEL\",\"$SERIAL_SAFE\",\"$FIRMWARE\",\"$VERSION\",\"$M\",\"$R\",\"$3\",\"$EV\",\"$5\"" >> "$SUMMARY"
}

status_score(){
    case "$1" in
        PASS) echo 100 ;;
        INFO) echo 90 ;;
        SKIP) echo 80 ;;
        WARN) echo 70 ;;
        FAIL) echo 30 ;;
        *) echo 80 ;;
    esac
}

review_required(){
    case "$1" in WARN|FAIL) echo YES ;; *) echo NO ;; esac
}

init_report(){
    echo 'Timestamp,RG_Host,Model,Serial,FirmwareVersion,ScriptVersion,Category,Test,Metric,Value,Result,Notes' > "$CSV"
    echo 'RunTimestamp,RGHost,Model,Serial,FirmwareVersion,ScriptVersion,Module,Result,Score,Evidence,ReviewRequired' > "$SUMMARY"
    section "BGW620 HEALTH ANALYZER START"
    log "Version  : $VERSION"
    log "Model    : $MODEL"
    log "Host     : $RG_HOST"
    log "Serial   : $SERIAL_SAFE"
    log "Firmware : $FIRMWARE"
    log "CSV      : $CSV"
    log "LOG      : $LOG"
    log "SUMMARY  : $SUMMARY"
    csv_row system start script bgw620_wifi_pwifi_health_v3_5_4a INFO "BGW620-only validation summary release"
}

wifi_health(){
    section "WIFI RADIO HEALTH"
    WIFI_STATUS=PASS; WIFI_EVIDENCE="Radio status collected"
    for IFACE in wl0 wl1 wl2; do
        TMP="/tmp/${IFACE}_status_${TS}.tmp"
        wl -i "$IFACE" status > "$TMP" 2>&1
        cat "$TMP" >> "$LOG"
        CHANNEL=`grep 'Channel:' "$TMP" | head -1 | sed 's/.*Channel: *//' | awk '{print $1}'`
        CHANSPEC=`grep 'Chanspec:' "$TMP" | head -1 | sed 's/^ *Chanspec: *//'`
        UTIL=`grep 'QBSS Channel Utilization' "$TMP" | head -1 | sed 's/.*(//' | sed 's/ %).*//'`
        [ -z "$CHANNEL" ] && CHANNEL=unknown
        [ -z "$CHANSPEC" ] && CHANSPEC=unknown
        [ -z "$UTIL" ] && UTIL=unknown
        RADIO_RESULT=PASS
        if [ "$CHANNEL" = unknown ]; then
            RADIO_RESULT=WARN; WIFI_STATUS=WARN; WIFI_EVIDENCE="$IFACE channel unavailable"
        fi
        case "$UTIL" in
            ''|*[!0-9]*) ;;
            *)
                if [ "$UTIL" -ge 85 ]; then
                    RADIO_RESULT=FAIL; WIFI_STATUS=FAIL; WIFI_EVIDENCE="$IFACE utilization=${UTIL}%"
                elif [ "$UTIL" -ge 70 ]; then
                    [ "$WIFI_STATUS" != FAIL ] && WIFI_STATUS=WARN
                    [ "$RADIO_RESULT" != FAIL ] && RADIO_RESULT=WARN
                    WIFI_EVIDENCE="$IFACE utilization=${UTIL}%"
                fi
                ;;
        esac
        csv_row wifi radio_status "$IFACE channel" "$CHANNEL" "$RADIO_RESULT" "$CHANSPEC"
        csv_row wifi radio_status "$IFACE utilization_percent" "$UTIL" "$RADIO_RESULT" "QBSS utilization"
        echo "$IFACE channel=$CHANNEL utilization=${UTIL}% result=$RADIO_RESULT"
        rm -f "$TMP"
    done
    wl -e bss >> "$LOG" 2>&1
    echo "WiFi Result        : $WIFI_STATUS"
}

client_health(){
    section "CLIENT DISTRIBUTION"
    TMP="/tmp/bgw620_assoc_${TS}.tmp"
    wl -e assoclist > "$TMP" 2>&1
    cat "$TMP" >> "$LOG"
    TOTAL=`grep -c '^assoclist ' "$TMP" 2>/dev/null`; [ -z "$TOTAL" ] && TOTAL=0
    CLIENT_STATUS=PASS
    CLIENT_EVIDENCE="Total associations=$TOTAL"
    csv_row client distribution total_associations "$TOTAL" PASS "wl -e assoclist"
    awk '/^---/{i=$2;b=$3;c[i]=0;bb[i]=b;o[++n]=i;next}/^assoclist/{c[i]++}END{for(x=1;x<=n;x++)print o[x]","bb[o[x]]","c[o[x]]}' "$TMP" |
    while IFS=, read IFACE BAND COUNT; do
        [ -n "$IFACE" ] && { csv_row client distribution "$IFACE $BAND" "$COUNT" INFO "Associated entries"; echo "$IFACE $BAND associations=$COUNT"; }
    done
    echo "Total Associations : $TOTAL"
    echo "Client Result      : $CLIENT_STATUS"
    rm -f "$TMP"
}

mlo_health(){
    section "WIFI7 / MLO HEALTH"
    MLO_TMP="/tmp/bgw620_mlo_${TS}.tmp"; PPR_TMP="/tmp/bgw620_ppr_${TS}.tmp"; EHT_TMP="/tmp/bgw620_eht_${TS}.tmp"
    wl -i wl0 mlo info > "$MLO_TMP" 2>&1
    wl -i wl0 curppr > "$PPR_TMP" 2>&1
    wl -i wl0 eht > "$EHT_TMP" 2>&1
    cat "$MLO_TMP" "$PPR_TMP" "$EHT_TMP" >> "$LOG"
    ACTIVE=`grep 'MLO_ACTIVE' "$MLO_TMP" | head -1 | sed 's/^ *//'`; [ -z "$ACTIVE" ] && ACTIVE=unknown
    LINKS=`grep 'MLD0::' "$MLO_TMP" | head -1 | sed 's/.*nlink //' | awk '{print $1}'`; [ -z "$LINKS" ] && LINKS=unknown
    W320=`grep -c '320MHz\|/320' "$PPR_TMP" 2>/dev/null`; [ -z "$W320" ] && W320=0
    EHT=`head -1 "$EHT_TMP" | sed 's/^ *//'`; [ -z "$EHT" ] && EHT=unknown
    MLO_STATUS=PASS
    echo "$ACTIVE" | grep -q TRUE || MLO_STATUS=WARN
    MLO_EVIDENCE="$ACTIVE; links=$LINKS; 320MHz_evidence=$W320; EHT=$EHT"
    csv_row wifi7 mlo mlo_active "$ACTIVE" "$MLO_STATUS" "MLO state"
    csv_row wifi7 mlo link_count "$LINKS" INFO "MLD link count"
    csv_row wifi7 mlo width_320_evidence "$W320" INFO "320 MHz evidence"
    csv_row wifi7 mlo eht "$EHT" INFO "EHT value"
    echo "MLO Active=$ACTIVE Links=$LINKS 320MHz=$W320 EHT=$EHT Result=$MLO_STATUS"
    rm -f "$MLO_TMP" "$PPR_TMP" "$EHT_TMP"
}

mesh_health(){
    section "MESH / BACKHAUL HEALTH"
    TMP="/tmp/bgw620_mesh_${TS}.tmp"
    nvram show 2>/dev/null | grep -E 'map_agent_active_bh_type|map_onboarded|map_onboarded_first_time|multiap_mode|wbd_ifnames|wl[0-2]_band_flag|map_bh|Backhaul' > "$TMP"
    cat "$TMP" >> "$LOG"
    BH=`grep '^map_agent_active_bh_type=' "$TMP" | tail -1 | cut -d= -f2-`; [ -z "$BH" ] && BH=unknown
    ON=`grep '^map_onboarded=' "$TMP" | tail -1 | cut -d= -f2-`; [ -z "$ON" ] && ON=unknown
    MM=`grep '^multiap_mode=' "$TMP" | tail -1 | cut -d= -f2-`; [ -z "$MM" ] && MM=unknown
    WBD=`grep '^wbd_ifnames=' "$TMP" | tail -1 | cut -d= -f2-`; [ -z "$WBD" ] && WBD=unknown
    MESH_STATUS=PASS; [ "$ON" != 1 ] && MESH_STATUS=WARN
    BHCOUNT=0; FHCOUNT=0
    for IFACE in wl0 wl0.1 wl0.2 wl0.3 wl0.4 wl0.5 wl0.6 wl0.7 wl1 wl1.1 wl1.2 wl1.3 wl1.4 wl1.5 wl1.6 wl1.7 wl2 wl2.1 wl2.2 wl2.3 wl2.4 wl2.5 wl2.6 wl2.7; do
        MAPOUT=`wl -i "$IFACE" map 2>/dev/null`; echo "$IFACE: $MAPOUT" >> "$LOG"
        echo "$MAPOUT" | grep -q Backhaul-BSS && { BHCOUNT=`expr "$BHCOUNT" + 1`; csv_row mesh bss_role "$IFACE" Backhaul-BSS PASS "Backhaul BSS"; wl -i "$IFACE" bs_data -noreset >> "$LOG" 2>&1; }
        echo "$MAPOUT" | grep -q Fronthaul-BSS && { FHCOUNT=`expr "$FHCOUNT" + 1`; csv_row mesh bss_role "$IFACE" Fronthaul-BSS INFO "Fronthaul BSS"; }
    done
    MESH_EVIDENCE="map_onboarded=$ON; backhaul=$BH; multiap_mode=$MM; BH_BSS=$BHCOUNT; FH_BSS=$FHCOUNT"
    csv_row mesh nvram backhaul_type "$BH" "$MESH_STATUS" "Active backhaul"
    csv_row mesh nvram map_onboarded "$ON" INFO "EasyMesh onboarded"
    csv_row mesh nvram multiap_mode "$MM" INFO "MultiAP mode"
    csv_row mesh nvram wbd_ifnames "$WBD" INFO "WBD interfaces"
    echo "$MESH_EVIDENCE Result=$MESH_STATUS"
    rm -f "$TMP"
}

acs_health(){
    section "ACS / CLOUD CHANNEL HEALTH"
    ACS_STATUS=INFO; TOTAL_EXCLUDED=0; COMMAND_ERRORS=0
    for IFACE in wl0 wl1 wl2; do
        REC="/tmp/${IFACE}_acs_${TS}.tmp"; SCORE="/tmp/${IFACE}_score_${TS}.tmp"
        acs_cli2 -i "$IFACE" dump acs_record > "$REC" 2>&1 || COMMAND_ERRORS=`expr "$COMMAND_ERRORS" + 1`
        acs_cli2 -i "$IFACE" dump cscore > "$SCORE" 2>&1 || COMMAND_ERRORS=`expr "$COMMAND_ERRORS" + 1`
        cat "$REC" "$SCORE" >> "$LOG"; wl -i "$IFACE" chanim_stats >> "$LOG" 2>&1
        LAST=`awk 'NF>=4&&$1~/^[0-9]/{x=$0}END{print x}' "$REC"`
        TRIGGER=`echo "$LAST" | awk '{print $3}'`; CHANNEL=`echo "$LAST" | awk '{print $4}'`
        [ -z "$TRIGGER" ] && TRIGGER=unknown; [ -z "$CHANNEL" ] && CHANNEL=unknown
        EXCLUDED=`grep -c 'Invalid:EXCLUDE' "$SCORE" 2>/dev/null`; [ -z "$EXCLUDED" ] && EXCLUDED=0
        TOTAL_EXCLUDED=`expr "$TOTAL_EXCLUDED" + "$EXCLUDED"`
        csv_row acs record "$IFACE last_trigger" "$TRIGGER" INFO "Last ACS trigger"
        csv_row acs record "$IFACE last_chanspec" "$CHANNEL" INFO "Last ACS channel"
        csv_row acs score "$IFACE invalid_exclude" "$EXCLUDED" INFO "Excluded candidate count"
        rm -f "$REC" "$SCORE"
    done
    map_cli --command dumpChanSel --payload '{"extended": true}' >> "$LOG" 2>&1 || COMMAND_ERRORS=`expr "$COMMAND_ERRORS" + 1`
    if [ "$COMMAND_ERRORS" -gt 1 ]; then ACS_STATUS=WARN; ACS_EVIDENCE="ACS command errors=$COMMAND_ERRORS"; else ACS_STATUS=INFO; ACS_EVIDENCE="ACS data captured; exclusions=$TOTAL_EXCLUDED"; fi
    echo "$ACS_EVIDENCE Result=$ACS_STATUS"
}

cevent_health(){
    section "CEVENTC AUTH / DROP HEALTH"
    TMP="/tmp/bgw620_cevent_${TS}.tmp"
    ceventc dump > "$TMP" 2>&1
    cat "$TMP" >> "$LOG"
    AUTH=`grep -c 'E_AUTH/' "$TMP" 2>/dev/null`; ASSOC=`grep -c 'E_ASSOC/' "$TMP" 2>/dev/null`; AUTHZ=`grep -c E_AUTHORIZED "$TMP" 2>/dev/null`
    DISASSOC=`grep -c E_DISASSOC "$TMP" 2>/dev/null`; DEAUTH=`grep -c 'DEAUTH\|E_DEAUTH' "$TMP" 2>/dev/null`; SAE=`grep -c SAE_AUTH "$TMP" 2>/dev/null`
    CEVENT_STATUS=PASS
    [ "$DISASSOC" -gt 30 ] && CEVENT_STATUS=WARN
    [ "$DISASSOC" -gt 100 ] && CEVENT_STATUS=FAIL
    CEVENT_EVIDENCE="Auth=$AUTH; Assoc=$ASSOC; Authorized=$AUTHZ; Disassoc=$DISASSOC; Deauth=$DEAUTH; SAE=$SAE"
    csv_row cevent auth_drop auth "$AUTH" INFO "Authentication events"
    csv_row cevent auth_drop associated "$ASSOC" INFO "Association events"
    csv_row cevent auth_drop authorized "$AUTHZ" INFO "Authorization events"
    csv_row cevent auth_drop disassoc "$DISASSOC" "$CEVENT_STATUS" "Disassociation events"
    csv_row cevent auth_drop deauth "$DEAUTH" INFO "Deauthentication events"
    csv_row cevent auth_drop sae "$SAE" INFO "SAE events"
    echo "$CEVENT_EVIDENCE Result=$CEVENT_STATUS"
    rm -f "$TMP"
}

neighbor_health(){
    section "NEIGHBOR HEALTH"
    ip neigh show >> "$LOG" 2>&1
    FAILED=`ip neigh show 2>/dev/null | grep -c FAILED`; INCOMPLETE=`ip neigh show 2>/dev/null | grep -c INCOMPLETE`
    REACHABLE=`ip neigh show 2>/dev/null | grep -c REACHABLE`; STALE=`ip neigh show 2>/dev/null | grep -c STALE`
    NEIGHBOR_STATUS=PASS
    [ "$FAILED" -gt 15 ] && NEIGHBOR_STATUS=WARN
    [ "$FAILED" -gt 30 ] && NEIGHBOR_STATUS=FAIL
    NEIGHBOR_EVIDENCE="Failed=$FAILED; Incomplete=$INCOMPLETE; Reachable=$REACHABLE; Stale=$STALE"
    csv_row network neighbor failed "$FAILED" "$NEIGHBOR_STATUS" "Failed neighbors"
    csv_row network neighbor incomplete "$INCOMPLETE" INFO "Incomplete neighbors"
    csv_row network neighbor reachable "$REACHABLE" INFO "Reachable neighbors"
    echo "$NEIGHBOR_EVIDENCE Result=$NEIGHBOR_STATUS"
}

memory_health(){
    section "SYSTEM / MEMORY HEALTH"
    MT_KB=`awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null`; MA_KB=`awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null`
    MF_KB=`awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null`; SUN_KB=`awk '/^SUnreclaim:/{print $2}' /proc/meminfo 2>/dev/null`
    [ -z "$MT_KB" ] && MT_KB=0; [ -z "$MA_KB" ] && MA_KB=0; [ -z "$MF_KB" ] && MF_KB=0; [ -z "$SUN_KB" ] && SUN_KB=0
    MT_MB=`awk -v v="$MT_KB" 'BEGIN{printf "%d",v/1024}'`; MA_MB=`awk -v v="$MA_KB" 'BEGIN{printf "%d",v/1024}'`
    MF_MB=`awk -v v="$MF_KB" 'BEGIN{printf "%d",v/1024}'`; SUN_MB=`awk -v v="$SUN_KB" 'BEGIN{printf "%d",v/1024}'`
    MEMORY_STATUS=PASS
    [ "$MA_MB" -lt 500 ] && MEMORY_STATUS=WARN
    [ "$MA_MB" -lt 250 ] && MEMORY_STATUS=FAIL
    MEMORY_EVIDENCE="Total=${MT_MB}MB; Available=${MA_MB}MB; Free=${MF_MB}MB; SUnreclaim=${SUN_MB}MB"
    csv_row memory meminfo mem_total_mb "$MT_MB" INFO "MemTotal converted from kB"
    csv_row memory meminfo mem_available_mb "$MA_MB" "$MEMORY_STATUS" "MemAvailable converted from kB"
    csv_row memory meminfo mem_free_mb "$MF_MB" INFO "MemFree converted from kB"
    csv_row memory meminfo sunreclaim_mb "$SUN_MB" INFO "SUnreclaim converted from kB"
    cat /proc/meminfo >> "$LOG" 2>&1
    echo "$MEMORY_EVIDENCE Result=$MEMORY_STATUS"
}

dns_health(){
    section "DNS / NAT HEALTH"
    if [ -x /bin/nslookup ] || [ -x /usr/bin/nslookup ]; then
        nslookup att.com >> "$LOG" 2>&1
        if [ "$?" -eq 0 ]; then DNS_STATUS=PASS; DNS_EVIDENCE="att.com resolution succeeded"; else DNS_STATUS=WARN; DNS_EVIDENCE="att.com resolution failed"; fi
    else
        DNS_STATUS=SKIP; DNS_EVIDENCE="nslookup unavailable"
    fi
    csv_row dns resolution att.com "$DNS_STATUS" "$DNS_STATUS" "$DNS_EVIDENCE"
    echo "$DNS_EVIDENCE Result=$DNS_STATUS"
}

stability_health(){
    section "STABILITY / CRASH HEALTH"
    CAPTURED=0
    for CMD in "show process-restart" "show hbmon" "show crash" "show crashlog" "show kfm crash"; do
        if [ -x /bin/cshell ] || [ -x /usr/bin/cshell ]; then
            cshell -c "$CMD" >> "$LOG" 2>&1; CAPTURED=`expr "$CAPTURED" + 1`
            csv_row stability cshell "$CMD" captured INFO "Saved to log"
        fi
    done
    [ -r /data/system/reboothistory.txt ] && cat /data/system/reboothistory.txt >> "$LOG"
    dmesg | grep -iE 'oom|out of memory|segfault|panic|watchdog|crash|dhd|wl.*error|error' >> "$LOG" 2>&1
    if [ "$CAPTURED" -gt 0 ]; then STABILITY_STATUS=PASS; STABILITY_EVIDENCE="$CAPTURED stability commands collected successfully"; else STABILITY_STATUS=SKIP; STABILITY_EVIDENCE="cshell stability commands unavailable"; fi
    echo "$STABILITY_EVIDENCE Result=$STABILITY_STATUS"
}

generate_validation_summary(){
    echo 'RunTimestamp,RGHost,Model,Serial,FirmwareVersion,ScriptVersion,Module,Result,Score,Evidence,ReviewRequired' > "$SUMMARY"
    SCORE_TOTAL=0; MODULE_COUNT=0; FAIL_COUNT=0; WARN_COUNT=0; REVIEW_MODULES=""
    for ITEM in \
        "WiFi|$WIFI_STATUS|$WIFI_EVIDENCE" \
        "Clients|$CLIENT_STATUS|$CLIENT_EVIDENCE" \
        "MLO|$MLO_STATUS|$MLO_EVIDENCE" \
        "Mesh|$MESH_STATUS|$MESH_EVIDENCE" \
        "ACS|$ACS_STATUS|$ACS_EVIDENCE" \
        "CEVENTC|$CEVENT_STATUS|$CEVENT_EVIDENCE" \
        "Neighbor|$NEIGHBOR_STATUS|$NEIGHBOR_EVIDENCE" \
        "Memory|$MEMORY_STATUS|$MEMORY_EVIDENCE" \
        "DNS_NAT|$DNS_STATUS|$DNS_EVIDENCE" \
        "Stability|$STABILITY_STATUS|$STABILITY_EVIDENCE"
    do
        MODULE=`echo "$ITEM" | cut -d'|' -f1`
        RESULT=`echo "$ITEM" | cut -d'|' -f2`
        EVIDENCE=`echo "$ITEM" | cut -d'|' -f3-`
        SCORE=`status_score "$RESULT"`
        REVIEW=`review_required "$RESULT"`
        summary_row "$MODULE" "$RESULT" "$SCORE" "$EVIDENCE" "$REVIEW"
        SCORE_TOTAL=`expr "$SCORE_TOTAL" + "$SCORE"`; MODULE_COUNT=`expr "$MODULE_COUNT" + 1`
        [ "$RESULT" = FAIL ] && { FAIL_COUNT=`expr "$FAIL_COUNT" + 1`; REVIEW_MODULES="$REVIEW_MODULES $MODULE"; }
        [ "$RESULT" = WARN ] && { WARN_COUNT=`expr "$WARN_COUNT" + 1`; REVIEW_MODULES="$REVIEW_MODULES $MODULE"; }
    done
    OVERALL_SCORE=`expr "$SCORE_TOTAL" / "$MODULE_COUNT"`
    if [ "$FAIL_COUNT" -gt 0 ]; then OVERALL_STATUS=FAIL; elif [ "$WARN_COUNT" -gt 0 ]; then OVERALL_STATUS=PASS_WITH_WARNINGS; else OVERALL_STATUS=PASS; fi
    if [ "$OVERALL_SCORE" -ge 95 ]; then OVERALL_GRADE=EXCELLENT; elif [ "$OVERALL_SCORE" -ge 80 ]; then OVERALL_GRADE=GOOD; elif [ "$OVERALL_SCORE" -ge 60 ]; then OVERALL_GRADE=FAIR; else OVERALL_GRADE=POOR; fi
    if [ -n "$REVIEW_MODULES" ]; then OVERALL_REVIEW=YES; OVERALL_EVIDENCE="Grade=$OVERALL_GRADE; Review:$REVIEW_MODULES"; else OVERALL_REVIEW=NO; OVERALL_EVIDENCE="Grade=$OVERALL_GRADE; No WARN or FAIL modules"; fi
    summary_row OVERALL "$OVERALL_STATUS" "$OVERALL_SCORE" "$OVERALL_EVIDENCE" "$OVERALL_REVIEW"
}

print_validation_summary(){
    echo ""; echo "============================================================"; echo " BGW620 VALIDATION SUMMARY"; echo "============================================================"
    printf '%-18s %s\n' WiFi "$WIFI_STATUS"; printf '%-18s %s\n' Clients "$CLIENT_STATUS"; printf '%-18s %s\n' MLO "$MLO_STATUS"
    printf '%-18s %s\n' Mesh "$MESH_STATUS"; printf '%-18s %s\n' ACS "$ACS_STATUS"; printf '%-18s %s\n' CEVENTC "$CEVENT_STATUS"
    printf '%-18s %s\n' Neighbor "$NEIGHBOR_STATUS"; printf '%-18s %s\n' Memory "$MEMORY_STATUS"; printf '%-18s %s\n' DNS_NAT "$DNS_STATUS"
    printf '%-18s %s\n' Stability "$STABILITY_STATUS"
    echo ""; printf '%-18s %s\n' "Overall Score" "$OVERALL_SCORE/100"; printf '%-18s %s\n' "Overall Grade" "$OVERALL_GRADE"; printf '%-18s %s\n' "Overall Status" "$OVERALL_STATUS"
    if [ -n "$REVIEW_MODULES" ]; then echo "Review Required:"; for MOD in $REVIEW_MODULES; do echo "  $MOD"; done; else echo "Review Required: None"; fi
    echo ""; echo "Health CSV : $CSV"; echo "Health LOG : $LOG"; echo "Summary CSV: $SUMMARY"; echo "============================================================"
}

upload_results(){
    section "UPLOAD RESULTS TO BCEO"
    if [ ! -x "$SCPBIN" ]; then UPLOAD_STATUS=FAIL; echo "ERROR: $SCPBIN missing"; return 1; fi
    echo "Uploading health CSV, raw LOG, and validation summary."
    echo "Enter BCEO password when prompted."
    "$SCPBIN" -P "$BCEO_PORT" "$CSV" "$LOG" "$SUMMARY" "$BCEO_USER@$BCEO_HOST:$BCEO_DIR/"
    RC=$?
    if [ "$RC" -eq 0 ]; then UPLOAD_STATUS=PASS; echo "Upload Complete"; else UPLOAD_STATUS=FAIL; echo "Upload Failed, return code $RC"; fi
    return "$RC"
}

full_suite(){ wifi_health; client_health; mlo_health; mesh_health; acs_health; cevent_health; neighbor_health; memory_health; dns_health; stability_health; generate_validation_summary; print_validation_summary; }
option99(){ full_suite; upload_results; echo "Upload Status      : $UPLOAD_STATUS"; }
print_paths(){ echo "CSV=$CSV"; echo "LOG=$LOG"; echo "SUMMARY=$SUMMARY"; echo "SERIAL=$SERIAL_SAFE"; }

menu(){
    echo ""; echo "============================================================"; echo " BGW620 WiFi/PWiFi Health Analyzer $VERSION"; echo "============================================================"
    echo " 1) Full Health Suite (no upload)"; echo " 2) WiFi Health"; echo " 3) Client Distribution"; echo " 4) WiFi7 / MLO Health"
    echo " 5) Mesh / Backhaul Health"; echo " 6) ACS / Cloud Channel Health"; echo " 7) CEVENTC Auth / Drop Health"; echo " 8) Neighbor Health"
    echo " 9) System / Memory Health"; echo "10) DNS / NAT Health"; echo "11) Stability / Crash / Reboot Health"
    echo "13) Upload Current CSV/LOG/Summary to BCEO"; echo "14) Print Current File Paths"
    echo "99) Full Suite + Validation Summary + 3-File SCP Upload"; echo " 0) Exit"; echo "============================================================"; echo -n "Select option: "
}

init_report
while true; do
    menu; read OPT
    case "$OPT" in
        1) full_suite;; 2) wifi_health;; 3) client_health;; 4) mlo_health;; 5) mesh_health;; 6) acs_health;; 7) cevent_health;; 8) neighbor_health;;
        9) memory_health;; 10) dns_health;; 11) stability_health;; 13) generate_validation_summary; upload_results;; 14) print_paths;; 99) option99;;
        0|q|Q) print_paths; exit 0;; *) echo "Invalid option";;
    esac
done
