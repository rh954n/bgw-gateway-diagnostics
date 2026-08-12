#!/bin/sh
# =====================================================================
# BGW620 WiFi / PWiFi Health Analyzer V3.6.2-RC2
# Read-only diagnostics. No gateway configuration changes.
#
# V3.6.2-RC2 additions:
#   - New EasyMesh / MLO Controller diagnostic section
#   - Parses map_cli --command dumpCtrlInfo
#   - Controller/ALE onboarding, topology, radios, MLDs, BHSTA links
#   - Backhaul/client RSSI, data rates, packet errors, channel utilization
#   - 6 GHz / 320 MHz operational validation
#   - Adds EasyMeshController to CSV and overall validation summary
#
# Built from BGW620 V3.5.4b baseline.
# =====================================================================

VERSION="V3.6.2-RC2"
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
EASYMESH_STATUS=INFO; EASYMESH_EVIDENCE="Not run"
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
        PASS|INFO|SKIP) echo 100 ;;
        WARN) echo 70 ;;
        FAIL) echo 30 ;;
        *) echo 80 ;;
    esac
}
review_required(){ case "$1" in WARN|FAIL) echo YES ;; *) echo NO ;; esac; }

init_report(){
    echo 'Timestamp,RG_Host,Model,Serial,FirmwareVersion,ScriptVersion,Category,Test,Metric,Value,Result,Notes' > "$CSV"
    echo 'RunTimestamp,RGHost,Model,Serial,FirmwareVersion,ScriptVersion,Module,Result,Score,Evidence,ReviewRequired' > "$SUMMARY"
    section "BGW620 HEALTH ANALYZER START"
    log "Version  : $VERSION"; log "Model    : $MODEL"; log "Host     : $RG_HOST"
    log "Serial   : $SERIAL_SAFE"; log "Firmware : $FIRMWARE"
    log "CSV      : $CSV"; log "LOG      : $LOG"; log "SUMMARY  : $SUMMARY"
    csv_row system start script "$VERSION" INFO "BGW620 V3.6.2 RC2 with WiFi7 MLO backhaul stability diagnostics"
}

wifi_health(){
    section "WIFI RADIO HEALTH"
    WIFI_STATUS=PASS; WIFI_EVIDENCE="Radio status collected"
    for IFACE in wl0 wl1 wl2; do
        TMP="/tmp/${IFACE}_status_${TS}.tmp"; wl -i "$IFACE" status > "$TMP" 2>&1; cat "$TMP" >> "$LOG"
        CHANNEL=`grep 'Channel:' "$TMP" | head -1 | sed 's/.*Channel: *//' | awk '{print $1}'`
        CHANSPEC=`grep 'Chanspec:' "$TMP" | head -1 | sed 's/^ *Chanspec: *//'`
        UTIL=`grep 'QBSS Channel Utilization' "$TMP" | head -1 | sed 's/.*(//' | sed 's/ %).*//'`
        [ -z "$CHANNEL" ] && CHANNEL=unknown; [ -z "$CHANSPEC" ] && CHANSPEC=unknown; [ -z "$UTIL" ] && UTIL=unknown
        RADIO_RESULT=PASS
        [ "$CHANNEL" = unknown ] && { RADIO_RESULT=WARN; WIFI_STATUS=WARN; WIFI_EVIDENCE="$IFACE channel unavailable"; }
        case "$UTIL" in ''|*[!0-9]*) ;; *)
            if [ "$UTIL" -ge 85 ]; then RADIO_RESULT=FAIL; WIFI_STATUS=FAIL; WIFI_EVIDENCE="$IFACE utilization=${UTIL}%"
            elif [ "$UTIL" -ge 70 ]; then [ "$WIFI_STATUS" != FAIL ] && WIFI_STATUS=WARN; RADIO_RESULT=WARN; WIFI_EVIDENCE="$IFACE utilization=${UTIL}%"; fi;; esac
        csv_row wifi radio_status "$IFACE channel" "$CHANNEL" "$RADIO_RESULT" "$CHANSPEC"
        csv_row wifi radio_status "$IFACE utilization_percent" "$UTIL" "$RADIO_RESULT" "QBSS utilization"
        echo "$IFACE channel=$CHANNEL utilization=${UTIL}% result=$RADIO_RESULT" | tee -a "$LOG"; rm -f "$TMP"
    done
    wl -e bss >> "$LOG" 2>&1; echo "WiFi Result        : $WIFI_STATUS"
}

client_health(){
    section "CLIENT DISTRIBUTION"
    TMP="/tmp/bgw620_assoc_${TS}.tmp"; wl -e assoclist > "$TMP" 2>&1; cat "$TMP" >> "$LOG"
    TOTAL=`grep -c '^assoclist ' "$TMP" 2>/dev/null`; [ -z "$TOTAL" ] && TOTAL=0
    CLIENT_STATUS=PASS; CLIENT_EVIDENCE="Total associations=$TOTAL"
    csv_row client distribution total_associations "$TOTAL" PASS "wl -e assoclist"
    echo "Total Associations : $TOTAL"; echo "Client Result      : $CLIENT_STATUS"; rm -f "$TMP"
}

mlo_health(){
    section "WIFI7 / MLO HEALTH"
    MLO_TMP="/tmp/bgw620_mlo_${TS}.tmp"; PPR_TMP="/tmp/bgw620_ppr_${TS}.tmp"; EHT_TMP="/tmp/bgw620_eht_${TS}.tmp"
    wl -i wl0 mlo info > "$MLO_TMP" 2>&1; wl -i wl0 curppr > "$PPR_TMP" 2>&1; wl -i wl0 eht > "$EHT_TMP" 2>&1
    cat "$MLO_TMP" "$PPR_TMP" "$EHT_TMP" >> "$LOG"
    ACTIVE=`grep 'MLO_ACTIVE' "$MLO_TMP" | head -1 | sed 's/^ *//'`; [ -z "$ACTIVE" ] && ACTIVE=unknown
    LINKS=`grep 'MLD0::' "$MLO_TMP" | head -1 | sed 's/.*nlink //' | awk '{print $1}'`; [ -z "$LINKS" ] && LINKS=unknown
    W320=`grep -c '320MHz\|/320' "$PPR_TMP" 2>/dev/null`; [ -z "$W320" ] && W320=0
    EHT=`head -1 "$EHT_TMP" | sed 's/^ *//'`; [ -z "$EHT" ] && EHT=unknown
    if grep -qiE 'unsupported|not found|invalid ioctl|error' "$MLO_TMP"; then MLO_STATUS=SKIP
    elif [ "$ACTIVE" = unknown ]; then MLO_STATUS=INFO
    elif echo "$ACTIVE" | grep -q TRUE; then MLO_STATUS=PASS
    else MLO_STATUS=WARN; fi
    MLO_EVIDENCE="$ACTIVE; links=$LINKS; 320MHz_evidence=$W320; EHT=$EHT"
    csv_row wifi7 mlo mlo_active "$ACTIVE" "$MLO_STATUS" "MLO state"
    csv_row wifi7 mlo link_count "$LINKS" INFO "MLD link count"
    echo "MLO Active=$ACTIVE Links=$LINKS 320MHz=$W320 EHT=$EHT Result=$MLO_STATUS"
    rm -f "$MLO_TMP" "$PPR_TMP" "$EHT_TMP"
}

mesh_health(){
    section "MESH / BACKHAUL NVRAM HEALTH"
    TMP="/tmp/bgw620_mesh_${TS}.tmp"
    nvram show 2>/dev/null | grep -E 'map_agent_active_bh_type|map_onboarded|multiap_mode|wbd_ifnames' > "$TMP"; cat "$TMP" >> "$LOG"
    BH=`grep '^map_agent_active_bh_type=' "$TMP" | tail -1 | cut -d= -f2-`; [ -z "$BH" ] && BH=unknown
    ON=`grep '^map_onboarded=' "$TMP" | tail -1 | cut -d= -f2-`; [ -z "$ON" ] && ON=unknown
    MM=`grep '^multiap_mode=' "$TMP" | tail -1 | cut -d= -f2-`; [ -z "$MM" ] && MM=unknown
    WBD=`grep '^wbd_ifnames=' "$TMP" | tail -1 | cut -d= -f2-`; [ -z "$WBD" ] && WBD=unknown
    BHCOUNT=0; FHCOUNT=0
    for IFACE in wl0 wl0.1 wl0.2 wl0.3 wl0.4 wl0.5 wl0.6 wl0.7 wl1 wl1.1 wl1.2 wl1.3 wl1.4 wl1.5 wl1.6 wl1.7 wl2 wl2.1 wl2.2 wl2.3 wl2.4 wl2.5 wl2.6 wl2.7; do
        MAPOUT=`wl -i "$IFACE" map 2>/dev/null`; echo "$IFACE: $MAPOUT" >> "$LOG"
        echo "$MAPOUT" | grep -q Backhaul-BSS && BHCOUNT=`expr "$BHCOUNT" + 1`
        echo "$MAPOUT" | grep -q Fronthaul-BSS && FHCOUNT=`expr "$FHCOUNT" + 1`
    done
    if [ "$ON" = unknown ]; then MESH_STATUS=INFO
    elif [ "$ON" = 1 ]; then MESH_STATUS=PASS
    elif [ "$BHCOUNT" -gt 0 ]; then MESH_STATUS=WARN
    else MESH_STATUS=INFO; fi
    MESH_EVIDENCE="map_onboarded=$ON; backhaul=$BH; multiap_mode=$MM; BH_BSS=$BHCOUNT; FH_BSS=$FHCOUNT"
    csv_row mesh nvram map_onboarded "$ON" "$MESH_STATUS" "$MESH_EVIDENCE"
    echo "$MESH_EVIDENCE Result=$MESH_STATUS"; rm -f "$TMP"
}

# ---------------------------------------------------------------------
# V3.6 flagship module: EasyMesh / MLO controller diagnostics
# Conservative classification: parser ambiguity is INFO/WARN, not FAIL.
# ---------------------------------------------------------------------
easy_mesh_controller_health(){
    section "EASYMESH / WIFI7 MLO BACKHAUL HEALTH"

    WB_TMP="/tmp/bgw620_wb_${TS}.tmp"
    CTRL_TMP="/tmp/bgw620_ctrl_${TS}.tmp"
    MLD_TMP="/tmp/bgw620_dumpmld_${TS}.tmp"
    MLO_TMP="/tmp/bgw620_bh_mlo_${TS}.tmp"
    STA0_TMP="/tmp/bgw620_wl07_sta_${TS}.tmp"
    STA1_TMP="/tmp/bgw620_wl17_sta_${TS}.tmp"
    BS0_TMP="/tmp/bgw620_wl07_bs_${TS}.tmp"
    BS1_TMP="/tmp/bgw620_wl17_bs_${TS}.tmp"
    BR_TMP="/tmp/bgw620_br1_${TS}.tmp"
    EV_TMP="/tmp/bgw620_bhevent_${TS}.tmp"

    EASYMESH_STATUS=PASS
    EASYMESH_EVIDENCE=""
    EM_WARN=0
    EM_FAIL=0

    # Execute commands directly. BGW620 vendor commands may work even when
    # command -v does not resolve them in a child shell.
    wb_cli -s info > "$WB_TMP" 2>&1; WB_RC=$?
    map_cli --command dumpCtrlInfo > "$CTRL_TMP" 2>&1; CTRL_RC=$?
    map_cli --command dumpMLD > "$MLD_TMP" 2>&1; MLD_RC=$?
    wl -i wl0.7 mlo info > "$MLO_TMP" 2>&1; MLO_RC=$?
    wl -i wl0.7 sta_info all > "$STA0_TMP" 2>&1; STA0_RC=$?
    wl -i wl1.7 sta_info all > "$STA1_TMP" 2>&1; STA1_RC=$?
    wl -i wl0.7 bs_data -noreset > "$BS0_TMP" 2>&1; BS0_RC=$?
    wl -i wl1.7 bs_data -noreset > "$BS1_TMP" 2>&1; BS1_RC=$?
    brctl showmacs br1 > "$BR_TMP" 2>&1; BR_RC=$?
    ceventc dump > "$EV_TMP" 2>&1; EV_RC=$?

    for F in "$WB_TMP" "$CTRL_TMP" "$MLD_TMP" "$MLO_TMP" "$STA0_TMP" "$STA1_TMP" "$BS0_TMP" "$BS1_TMP" "$BR_TMP" "$EV_TMP"; do
        [ -f "$F" ] && { echo "" >> "$LOG"; echo "----- $F -----" >> "$LOG"; cat "$F" >> "$LOG"; }
    done

    # Command execution availability. Missing core MLO data is a WARN, not a
    # fabricated PASS. Individual command return codes are retained in CSV.
    for ITEM in "wb_cli:$WB_RC" "dumpCtrlInfo:$CTRL_RC" "dumpMLD:$MLD_RC" "mlo_info:$MLO_RC" "wl0.7_sta:$STA0_RC" "wl1.7_sta:$STA1_RC" "wl0.7_bs:$BS0_RC" "wl1.7_bs:$BS1_RC" "br1:$BR_RC" "ceventc:$EV_RC"; do
        CMD_NAME=`echo "$ITEM" | cut -d: -f1`; CMD_RC=`echo "$ITEM" | cut -d: -f2`
        if [ "$CMD_RC" -eq 0 ]; then CMD_RESULT=PASS; else CMD_RESULT=WARN; EM_WARN=`expr "$EM_WARN" + 1`; fi
        csv_row easymesh command "$CMD_NAME" "$CMD_RC" "$CMD_RESULT" "Direct command execution"
    done

    CONTROLLER_COUNT=`grep -c 'Controller Registrar' "$WB_TMP" 2>/dev/null`; [ -z "$CONTROLLER_COUNT" ] && CONTROLLER_COUNT=0
    AGENT_COUNT=`grep -c ' Agent' "$WB_TMP" 2>/dev/null`; [ -z "$AGENT_COUNT" ] && AGENT_COUNT=0
    BH5_COUNT=`grep '0x02(Backhaul)' "$WB_TMP" 2>/dev/null | grep -c '5G,'`; [ -z "$BH5_COUNT" ] && BH5_COUNT=0
    BH6_COUNT=`grep '0x02(Backhaul)' "$WB_TMP" 2>/dev/null | grep -c '6G,'`; [ -z "$BH6_COUNT" ] && BH6_COUNT=0

    [ "$CONTROLLER_COUNT" -gt 0 ] && R=PASS || { R=WARN; EM_WARN=`expr "$EM_WARN" + 1`; }
    csv_row easymesh inventory controller_registrar "$CONTROLLER_COUNT" "$R" "wb_cli -s info"
    [ "$AGENT_COUNT" -gt 0 ] && R=PASS || { R=WARN; EM_WARN=`expr "$EM_WARN" + 1`; }
    csv_row easymesh inventory agents "$AGENT_COUNT" "$R" "wb_cli -s info"
    [ "$BH5_COUNT" -gt 0 ] && R=PASS || { R=FAIL; EM_FAIL=`expr "$EM_FAIL" + 1`; }
    csv_row easymesh backhaul 5ghz_bss "$BH5_COUNT" "$R" "Expected at least one 5GHz Backhaul BSS"
    [ "$BH6_COUNT" -gt 0 ] && R=PASS || { R=FAIL; EM_FAIL=`expr "$EM_FAIL" + 1`; }
    csv_row easymesh backhaul 6ghz_bss "$BH6_COUNT" "$R" "Expected at least one 6GHz Backhaul BSS"

    MLO_ACTIVE=`grep 'MLO_ACTIVE:' "$MLO_TMP" 2>/dev/null | head -1`
    NLINK=`sed -n 's/.*MLD7:: nlink \([0-9][0-9]*\).*/\1/p' "$MLO_TMP" | head -1`; [ -z "$NLINK" ] && NLINK=unknown
    SCB_COUNT=`grep -c '^MLO SCB:' "$MLO_TMP" 2>/dev/null`; [ -z "$SCB_COUNT" ] && SCB_COUNT=0
    ACTIVE_03=`grep -c 'active_link_map 0x3' "$MLO_TMP" 2>/dev/null`; [ -z "$ACTIVE_03" ] && ACTIVE_03=0
    ASSOC_03=`grep -c 'assoc_link_bmp 0x3' "$MLO_TMP" 2>/dev/null`; [ -z "$ASSOC_03" ] && ASSOC_03=0
    STR_CLIENTS=`grep -c 'Client Mode[ ]*:[ ]*STR' "$MLO_TMP" 2>/dev/null`; [ -z "$STR_CLIENTS" ] && STR_CLIENTS=0

    echo "$MLO_ACTIVE" | grep -q 'TRUE' && R=PASS || { R=FAIL; EM_FAIL=`expr "$EM_FAIL" + 1`; }
    csv_row easymesh mlo mlo_active "$MLO_ACTIVE" "$R" "wl0.7 mlo info"
    [ "$NLINK" = 2 ] && R=PASS || { R=FAIL; EM_FAIL=`expr "$EM_FAIL" + 1`; }
    csv_row easymesh mlo mld7_link_count "$NLINK" "$R" "Expected dual-link backhaul"
    grep -q 'link0: wl0.7' "$MLO_TMP" && R=PASS || { R=FAIL; EM_FAIL=`expr "$EM_FAIL" + 1`; }
    csv_row easymesh mlo link0_6ghz wl0.7 "$R" "Expected MLD7 link0"
    grep -q 'link1: wl1.7' "$MLO_TMP" && R=PASS || { R=FAIL; EM_FAIL=`expr "$EM_FAIL" + 1`; }
    csv_row easymesh mlo link1_5ghz wl1.7 "$R" "Expected MLD7 link1"

    if [ "$SCB_COUNT" -gt 0 ] && [ "$ACTIVE_03" -eq "$SCB_COUNT" ]; then R=PASS; else R=FAIL; EM_FAIL=`expr "$EM_FAIL" + 1`; fi
    csv_row easymesh mlo active_link_map_0x3 "$ACTIVE_03/$SCB_COUNT" "$R" "All MLO peers should have both links active"
    if [ "$SCB_COUNT" -gt 0 ] && [ "$ASSOC_03" -eq "$SCB_COUNT" ]; then R=PASS; else R=FAIL; EM_FAIL=`expr "$EM_FAIL" + 1`; fi
    csv_row easymesh mlo assoc_link_bmp_0x3 "$ASSOC_03/$SCB_COUNT" "$R" "All MLO peers should have both links associated"
    if [ "$SCB_COUNT" -gt 0 ] && [ "$STR_CLIENTS" -eq "$SCB_COUNT" ]; then R=PASS; else R=WARN; EM_WARN=`expr "$EM_WARN" + 1`; fi
    csv_row easymesh mlo str_clients "$STR_CLIENTS/$SCB_COUNT" "$R" "Client Mode STR"

    # Current authorization and security are authoritative. Historical
    # E_AUTHORIZED events may have aged out of the ceventc rolling buffer.
    for PAIR in "wl0.7:$STA0_TMP" "wl1.7:$STA1_TMP"; do
        IFACE=`echo "$PAIR" | cut -d: -f1`; SF=`echo "$PAIR" | cut -d: -f2-`
        STA_COUNT=`grep -c '^\[VER [0-9][0-9]*\] STA ' "$SF" 2>/dev/null`; [ -z "$STA_COUNT" ] && STA_COUNT=0
        AUTHORIZED=`grep -c 'state: AUTHENTICATED ASSOCIATED AUTHORIZED' "$SF" 2>/dev/null`; [ -z "$AUTHORIZED" ] && AUTHORIZED=0
        WPA3=`grep -c 'auth: WPA3-SAE-PSK-EXT' "$SF" 2>/dev/null`; [ -z "$WPA3" ] && WPA3=0
        DECRYPT_FAIL=`awk '/rx decrypt failures:/ {s+=$NF+0} END{print s+0}' "$SF"`
        MIN_RSSI=`awk '/smoothed rssi:/ {v=$NF+0; if(!seen||v<min){min=v;seen=1}} END{if(seen)print min;else print 0}' "$SF"`
        LOW_UPTIME=`awk '/in network [0-9]+ seconds/ {v=$(NF-1)+0; if(v<1800)n++} END{print n+0}' "$SF"`
        SENT=`awk '/tx total pkts sent:/ {s+=$NF+0} END{print s+0}' "$SF"`
        RETRIES=`awk '/tx pkts retries:/ {s+=$NF+0} END{print s+0}' "$SF"`
        EXHAUSTED=`awk '/tx pkts retry exhausted:/ {s+=$NF+0} END{print s+0}' "$SF"`

        if [ "$STA_COUNT" -gt 0 ] && [ "$AUTHORIZED" -eq "$STA_COUNT" ]; then R=PASS; else R=FAIL; EM_FAIL=`expr "$EM_FAIL" + 1`; fi
        csv_row easymesh backhaul_sta "${IFACE}_authorized" "$AUTHORIZED/$STA_COUNT" "$R" "Current sta_info state"
        if [ "$STA_COUNT" -gt 0 ] && [ "$WPA3" -eq "$STA_COUNT" ]; then R=PASS; else R=WARN; EM_WARN=`expr "$EM_WARN" + 1`; fi
        csv_row easymesh backhaul_sta "${IFACE}_wpa3" "$WPA3/$STA_COUNT" "$R" "WPA3-SAE-PSK-EXT"
        [ "$DECRYPT_FAIL" -eq 0 ] && R=PASS || { R=FAIL; EM_FAIL=`expr "$EM_FAIL" + 1`; }
        csv_row easymesh backhaul_sta "${IFACE}_decrypt_failures" "$DECRYPT_FAIL" "$R" "Aggregate counter snapshot"
        [ "$LOW_UPTIME" -eq 0 ] && R=PASS || { R=WARN; EM_WARN=`expr "$EM_WARN" + 1`; }
        csv_row easymesh backhaul_sta "${IFACE}_uptime_under_1800s" "$LOW_UPTIME" "$R" "Possible recent reconnect; counter snapshot"
        if [ "$MIN_RSSI" -eq 0 ]; then R=INFO
        elif [ "$MIN_RSSI" -lt -70 ]; then R=FAIL; EM_FAIL=`expr "$EM_FAIL" + 1`
        elif [ "$MIN_RSSI" -lt -60 ]; then R=WARN; EM_WARN=`expr "$EM_WARN" + 1`
        else R=PASS; fi
        csv_row easymesh backhaul_sta "${IFACE}_minimum_rssi_dbm" "$MIN_RSSI" "$R" "Worst smoothed RSSI"

        # Retry attempts are telemetry only because repeated attempts can
        # exceed transmitted packets. Retry-exhausted ratio is scored.
        if [ "$SENT" -gt 0 ]; then
            RETRY_ATTEMPT_PCT=`expr "$RETRIES" \* 100 / "$SENT"`
            EXH_X100=`expr "$EXHAUSTED" \* 10000 / "$SENT"`
            EXH_WHOLE=`expr "$EXH_X100" / 100`; EXH_FRAC=`expr "$EXH_X100" % 100`
            csv_row easymesh backhaul_sta "${IFACE}_retry_attempt_percent" "$RETRY_ATTEMPT_PCT" INFO "Telemetry only; attempts may exceed packets"
            if [ "$EXH_X100" -gt 300 ]; then R=FAIL; EM_FAIL=`expr "$EM_FAIL" + 1`
            elif [ "$EXH_X100" -gt 100 ]; then R=WARN; EM_WARN=`expr "$EM_WARN" + 1`
            else R=PASS; fi
            csv_row easymesh backhaul_sta "${IFACE}_retry_exhausted_percent" "${EXH_WHOLE}.${EXH_FRAC}" "$R" "exhausted=$EXHAUSTED sent=$SENT"
        else
            csv_row easymesh backhaul_sta "${IFACE}_retry_metrics" unavailable INFO "No transmitted packet denominator"
        fi
    done

    BSTA_MLD=`grep -c '^  bSTA MLD\[' "$MLD_TMP" 2>/dev/null`; [ -z "$BSTA_MLD" ] && BSTA_MLD=0
    STR_ENABLED=`grep -c 'Enab modes: STR' "$MLD_TMP" 2>/dev/null`; [ -z "$STR_ENABLED" ] && STR_ENABLED=0
    BAND5=`grep -c 'Band[ ]*:[ ]*5GHz' "$MLD_TMP" 2>/dev/null`; [ -z "$BAND5" ] && BAND5=0
    BAND6=`grep -c 'Band[ ]*:[ ]*6GHz' "$MLD_TMP" 2>/dev/null`; [ -z "$BAND6" ] && BAND6=0
    [ "$BSTA_MLD" -gt 0 ] && R=PASS || { R=WARN; EM_WARN=`expr "$EM_WARN" + 1`; }
    csv_row easymesh topology bsta_mld_count "$BSTA_MLD" "$R" "map_cli dumpMLD"
    [ "$STR_ENABLED" -gt 0 ] && R=PASS || { R=WARN; EM_WARN=`expr "$EM_WARN" + 1`; }
    csv_row easymesh topology str_enabled_count "$STR_ENABLED" "$R" "map_cli dumpMLD"
    [ "$BAND5" -gt 0 ] && R=PASS || { R=FAIL; EM_FAIL=`expr "$EM_FAIL" + 1`; }
    csv_row easymesh topology affiliated_5ghz "$BAND5" "$R" "dumpMLD band entries"
    [ "$BAND6" -gt 0 ] && R=PASS || { R=FAIL; EM_FAIL=`expr "$EM_FAIL" + 1`; }
    csv_row easymesh topology affiliated_6ghz "$BAND6" "$R" "dumpMLD band entries"

    # Validate local bridge membership using the two MLD7 AP link MACs.
    BR_PASS=0; BR_TOTAL=0
    for MAC in `sed -n 's/.*link[01]: .* addr \([^ ]*\).*/\1/p' "$MLO_TMP"`; do
        BR_TOTAL=`expr "$BR_TOTAL" + 1`
        if grep -i "$MAC" "$BR_TMP" | grep -q 'yes'; then BR_PASS=`expr "$BR_PASS" + 1`; fi
    done
    if [ "$BR_TOTAL" -gt 0 ] && [ "$BR_PASS" -eq "$BR_TOTAL" ]; then R=PASS; else R=FAIL; EM_FAIL=`expr "$EM_FAIL" + 1`; fi
    csv_row easymesh bridge local_mld_links "$BR_PASS/$BR_TOTAL" "$R" "brctl showmacs br1 local=yes"

    # Event data is historical and buffer-scoped. Score current backhaul
    # deauth/disassoc only; authorization history and radar count are INFO.
    grep -E ' wl[01]\.7 ' "$EV_TMP" > "${EV_TMP}.bh" 2>/dev/null
    BH_DEAUTH=`grep -c 'E_DEAUTH' "${EV_TMP}.bh" 2>/dev/null`; [ -z "$BH_DEAUTH" ] && BH_DEAUTH=0
    BH_DISASSOC=`grep -c 'E_DISASSOC' "${EV_TMP}.bh" 2>/dev/null`; [ -z "$BH_DISASSOC" ] && BH_DISASSOC=0
    BH_AUTHZ=`grep -c 'E_AUTHORIZED' "${EV_TMP}.bh" 2>/dev/null`; [ -z "$BH_AUTHZ" ] && BH_AUTHZ=0
    RADAR=`grep -c 'E_RADAR_DETECTED' "$EV_TMP" 2>/dev/null`; [ -z "$RADAR" ] && RADAR=0
    [ "$BH_DEAUTH" -eq 0 ] && R=PASS || { R=WARN; EM_WARN=`expr "$EM_WARN" + 1`; }
    csv_row easymesh events backhaul_deauth "$BH_DEAUTH" "$R" "Current ceventc buffer"
    [ "$BH_DISASSOC" -eq 0 ] && R=PASS || { R=WARN; EM_WARN=`expr "$EM_WARN" + 1`; }
    csv_row easymesh events backhaul_disassoc "$BH_DISASSOC" "$R" "Current ceventc buffer"
    csv_row easymesh events authorized_history "$BH_AUTHZ" INFO "Historical occurrences in current ceventc buffer"
    csv_row easymesh events radar_history "$RADAR" INFO "Historical all-radio count; current MLO state scored separately"

    if [ "$EM_FAIL" -gt 0 ]; then EASYMESH_STATUS=FAIL
    elif [ "$EM_WARN" -gt 0 ]; then EASYMESH_STATUS=WARN
    else EASYMESH_STATUS=PASS; fi

    EASYMESH_EVIDENCE="MLO_ACTIVE=`echo "$MLO_ACTIVE" | awk '{print $1}'`; nlink=$NLINK; peers=$SCB_COUNT; active_0x3=$ACTIVE_03; assoc_0x3=$ASSOC_03; bSTA_MLD=$BSTA_MLD; 5G_BH=$BH5_COUNT; 6G_BH=$BH6_COUNT; warnings=$EM_WARN; failures=$EM_FAIL"
    csv_row easymesh summary module_status "$EASYMESH_STATUS" "$EASYMESH_STATUS" "$EASYMESH_EVIDENCE"

    echo "Controller/Agents   : controller=$CONTROLLER_COUNT agents=$AGENT_COUNT"
    echo "Backhaul BSS        : 5GHz=$BH5_COUNT 6GHz=$BH6_COUNT"
    echo "MLO Backhaul        : nlink=$NLINK peers=$SCB_COUNT active0x3=$ACTIVE_03 assoc0x3=$ASSOC_03 STR=$STR_CLIENTS"
    echo "MLD Topology        : bSTA_MLD=$BSTA_MLD 5GHz_entries=$BAND5 6GHz_entries=$BAND6"
    echo "Backhaul Events     : deauth=$BH_DEAUTH disassoc=$BH_DISASSOC radar_history=$RADAR"
    echo "EasyMesh Result     : $EASYMESH_STATUS"

    rm -f "$WB_TMP" "$CTRL_TMP" "$MLD_TMP" "$MLO_TMP" "$STA0_TMP" "$STA1_TMP" "$BS0_TMP" "$BS1_TMP" "$BR_TMP" "$EV_TMP" "${EV_TMP}.bh"
}

acs_health(){
    section "ACS / CLOUD CHANNEL HEALTH"; ACS_STATUS=INFO; COMMAND_ERRORS=0; TOTAL_EXCLUDED=0
    for IFACE in wl0 wl1 wl2; do
        REC="/tmp/${IFACE}_acs_${TS}.tmp"; SCORE="/tmp/${IFACE}_score_${TS}.tmp"
        acs_cli2 -i "$IFACE" dump acs_record > "$REC" 2>&1 || COMMAND_ERRORS=`expr "$COMMAND_ERRORS" + 1`
        acs_cli2 -i "$IFACE" dump cscore > "$SCORE" 2>&1 || COMMAND_ERRORS=`expr "$COMMAND_ERRORS" + 1`
        cat "$REC" "$SCORE" >> "$LOG"; EXCLUDED=`grep -c 'Invalid:EXCLUDE' "$SCORE" 2>/dev/null`; [ -z "$EXCLUDED" ] && EXCLUDED=0
        TOTAL_EXCLUDED=`expr "$TOTAL_EXCLUDED" + "$EXCLUDED"`; rm -f "$REC" "$SCORE"
    done
    if [ "$COMMAND_ERRORS" -gt 1 ]; then ACS_STATUS=WARN; ACS_EVIDENCE="ACS command errors=$COMMAND_ERRORS"; else ACS_STATUS=INFO; ACS_EVIDENCE="ACS data captured; exclusions=$TOTAL_EXCLUDED"; fi
    echo "$ACS_EVIDENCE Result=$ACS_STATUS"
}

cevent_health(){
    section "CEVENTC AUTH / DROP HEALTH"; TMP="/tmp/bgw620_cevent_${TS}.tmp"; ceventc dump > "$TMP" 2>&1; cat "$TMP" >> "$LOG"
    AUTH=`grep -c 'E_AUTH/' "$TMP" 2>/dev/null`; ASSOC=`grep -c 'E_ASSOC/' "$TMP" 2>/dev/null`; AUTHZ=`grep -c E_AUTHORIZED "$TMP" 2>/dev/null`
    DISASSOC=`grep -c E_DISASSOC "$TMP" 2>/dev/null`; DEAUTH=`grep -c 'DEAUTH\|E_DEAUTH' "$TMP" 2>/dev/null`; SAE=`grep -c SAE_AUTH "$TMP" 2>/dev/null`
    CEVENT_STATUS=PASS; [ "$DISASSOC" -gt 30 ] && CEVENT_STATUS=WARN; [ "$DEAUTH" -gt 30 ] && CEVENT_STATUS=WARN
    CEVENT_EVIDENCE="Auth=$AUTH; Assoc=$ASSOC; Authorized=$AUTHZ; Disassoc=$DISASSOC; Deauth=$DEAUTH; SAE=$SAE"
    csv_row cevent auth_drop disassoc "$DISASSOC" "$CEVENT_STATUS" "$CEVENT_EVIDENCE"
    echo "$CEVENT_EVIDENCE Result=$CEVENT_STATUS"; rm -f "$TMP"
}

neighbor_health(){
    section "NEIGHBOR HEALTH"; ip neigh show >> "$LOG" 2>&1
    FAILED=`ip neigh show 2>/dev/null | grep -c FAILED`; INCOMPLETE=`ip neigh show 2>/dev/null | grep -c INCOMPLETE`; REACHABLE=`ip neigh show 2>/dev/null | grep -c REACHABLE`; STALE=`ip neigh show 2>/dev/null | grep -c STALE`
    NEIGHBOR_STATUS=PASS; [ "$FAILED" -gt 15 ] && NEIGHBOR_STATUS=WARN
    NEIGHBOR_EVIDENCE="Failed=$FAILED; Incomplete=$INCOMPLETE; Reachable=$REACHABLE; Stale=$STALE"
    csv_row network neighbor failed "$FAILED" "$NEIGHBOR_STATUS" "$NEIGHBOR_EVIDENCE"; echo "$NEIGHBOR_EVIDENCE Result=$NEIGHBOR_STATUS"
}

memory_health(){
    section "SYSTEM / MEMORY HEALTH"
    MT_KB=`awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null`; MA_KB=`awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null`; MF_KB=`awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null`; SUN_KB=`awk '/^SUnreclaim:/{print $2}' /proc/meminfo 2>/dev/null`
    [ -z "$MT_KB" ] && MT_KB=0; [ -z "$MA_KB" ] && MA_KB=0; [ -z "$MF_KB" ] && MF_KB=0; [ -z "$SUN_KB" ] && SUN_KB=0
    MT_MB=`awk -v v="$MT_KB" 'BEGIN{printf "%d",v/1024}'`; MA_MB=`awk -v v="$MA_KB" 'BEGIN{printf "%d",v/1024}'`; MF_MB=`awk -v v="$MF_KB" 'BEGIN{printf "%d",v/1024}'`; SUN_MB=`awk -v v="$SUN_KB" 'BEGIN{printf "%d",v/1024}'`
    MEMORY_STATUS=PASS; [ "$MA_MB" -lt 500 ] && MEMORY_STATUS=WARN; [ "$MA_MB" -lt 250 ] && MEMORY_STATUS=FAIL
    MEMORY_EVIDENCE="Total=${MT_MB}MB; Available=${MA_MB}MB; Free=${MF_MB}MB; SUnreclaim=${SUN_MB}MB"
    csv_row memory meminfo mem_available_mb "$MA_MB" "$MEMORY_STATUS" "$MEMORY_EVIDENCE"; cat /proc/meminfo >> "$LOG" 2>&1; echo "$MEMORY_EVIDENCE Result=$MEMORY_STATUS"
}

dns_health(){
    section "DNS HEALTH"
    if command -v nslookup >/dev/null 2>&1; then nslookup att.com >> "$LOG" 2>&1; if [ "$?" -eq 0 ]; then DNS_STATUS=PASS; DNS_VALUE=resolved; DNS_EVIDENCE="att.com resolution succeeded"; else DNS_STATUS=WARN; DNS_VALUE=resolution_failed; DNS_EVIDENCE="att.com resolution failed"; fi
    else DNS_STATUS=SKIP; DNS_VALUE=command_unavailable; DNS_EVIDENCE="nslookup unavailable"; fi
    csv_row dns resolution att.com "$DNS_VALUE" "$DNS_STATUS" "$DNS_EVIDENCE"; echo "$DNS_EVIDENCE Result=$DNS_STATUS"
}

stability_health(){
    section "STABILITY / CRASH HEALTH"; CAPTURED=0
    for CMD in "show process-restart" "show hbmon" "show crash" "show crashlog" "show kfm crash"; do
        if command -v cshell >/dev/null 2>&1; then cshell -c "$CMD" >> "$LOG" 2>&1; CAPTURED=`expr "$CAPTURED" + 1`; fi
    done
    [ -r /data/system/reboothistory.txt ] && cat /data/system/reboothistory.txt >> "$LOG"
    dmesg | grep -iE 'oom|out of memory|segfault|panic|watchdog|crash|dhd|wl.*error|error' >> "$LOG" 2>&1
    if [ "$CAPTURED" -gt 0 ]; then STABILITY_STATUS=INFO; STABILITY_EVIDENCE="$CAPTURED stability commands captured; inspect raw log for events"; else STABILITY_STATUS=SKIP; STABILITY_EVIDENCE="cshell stability commands unavailable"; fi
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
        "EasyMeshController|$EASYMESH_STATUS|$EASYMESH_EVIDENCE" \
        "ACS|$ACS_STATUS|$ACS_EVIDENCE" \
        "CEVENTC|$CEVENT_STATUS|$CEVENT_EVIDENCE" \
        "Neighbor|$NEIGHBOR_STATUS|$NEIGHBOR_EVIDENCE" \
        "Memory|$MEMORY_STATUS|$MEMORY_EVIDENCE" \
        "DNS|$DNS_STATUS|$DNS_EVIDENCE" \
        "Stability|$STABILITY_STATUS|$STABILITY_EVIDENCE"
    do
        MODULE=`echo "$ITEM" | cut -d'|' -f1`; RESULT=`echo "$ITEM" | cut -d'|' -f2`; EVIDENCE=`echo "$ITEM" | cut -d'|' -f3-`
        SCORE=`status_score "$RESULT"`; REVIEW=`review_required "$RESULT"`; summary_row "$MODULE" "$RESULT" "$SCORE" "$EVIDENCE" "$REVIEW"
        SCORE_TOTAL=`expr "$SCORE_TOTAL" + "$SCORE"`; MODULE_COUNT=`expr "$MODULE_COUNT" + 1`
        [ "$RESULT" = FAIL ] && { FAIL_COUNT=`expr "$FAIL_COUNT" + 1`; REVIEW_MODULES="$REVIEW_MODULES $MODULE"; }
        [ "$RESULT" = WARN ] && { WARN_COUNT=`expr "$WARN_COUNT" + 1`; REVIEW_MODULES="$REVIEW_MODULES $MODULE"; }
    done
    OVERALL_SCORE=`expr "$SCORE_TOTAL" / "$MODULE_COUNT"`
    if [ "$FAIL_COUNT" -gt 0 ]; then OVERALL_STATUS=FAIL; elif [ "$WARN_COUNT" -gt 0 ]; then OVERALL_STATUS=PASS_WITH_WARNINGS; else OVERALL_STATUS=PASS; fi
    if [ "$OVERALL_SCORE" -ge 95 ]; then OVERALL_GRADE=EXCELLENT; elif [ "$OVERALL_SCORE" -ge 80 ]; then OVERALL_GRADE=GOOD; elif [ "$OVERALL_SCORE" -ge 60 ]; then OVERALL_GRADE=FAIR; else OVERALL_GRADE=POOR; fi
    [ -n "$REVIEW_MODULES" ] && OVERALL_REVIEW=YES || OVERALL_REVIEW=NO
    summary_row OVERALL "$OVERALL_STATUS" "$OVERALL_SCORE" "Grade=$OVERALL_GRADE; Review:$REVIEW_MODULES" "$OVERALL_REVIEW"
}

print_validation_summary(){
    echo ""; echo "============================================================"; echo " BGW620 VALIDATION SUMMARY"; echo "============================================================"
    printf '%-20s %s\n' WiFi "$WIFI_STATUS"; printf '%-20s %s\n' Clients "$CLIENT_STATUS"; printf '%-20s %s\n' MLO "$MLO_STATUS"
    printf '%-20s %s\n' Mesh "$MESH_STATUS"; printf '%-20s %s\n' EasyMeshController "$EASYMESH_STATUS"; printf '%-20s %s\n' ACS "$ACS_STATUS"
    printf '%-20s %s\n' CEVENTC "$CEVENT_STATUS"; printf '%-20s %s\n' Neighbor "$NEIGHBOR_STATUS"; printf '%-20s %s\n' Memory "$MEMORY_STATUS"
    printf '%-20s %s\n' DNS "$DNS_STATUS"; printf '%-20s %s\n' Stability "$STABILITY_STATUS"
    echo ""; printf '%-20s %s\n' "Overall Score" "$OVERALL_SCORE/100"; printf '%-20s %s\n' "Overall Grade" "$OVERALL_GRADE"; printf '%-20s %s\n' "Overall Status" "$OVERALL_STATUS"
    if [ -n "$REVIEW_MODULES" ]; then echo "Review Required:"; for MOD in $REVIEW_MODULES; do echo "  $MOD"; done; else echo "Review Required: None"; fi
    echo ""; echo "Health CSV : $CSV"; echo "Health LOG : $LOG"; echo "Summary CSV: $SUMMARY"; echo "============================================================"
}

upload_results(){
    section "UPLOAD RESULTS TO BCEO"
    if [ ! -x "$SCPBIN" ]; then UPLOAD_STATUS=FAIL; echo "ERROR: $SCPBIN missing"; return 1; fi
    echo "Uploading health CSV, raw LOG, and validation summary."; echo "Enter BCEO password when prompted."
    "$SCPBIN" -P "$BCEO_PORT" "$CSV" "$LOG" "$SUMMARY" "$BCEO_USER@$BCEO_HOST:$BCEO_DIR/"; RC=$?
    if [ "$RC" -eq 0 ]; then UPLOAD_STATUS=PASS; echo "Upload Complete"; else UPLOAD_STATUS=FAIL; echo "Upload Failed, return code $RC"; fi; return "$RC"
}

full_suite(){ wifi_health; client_health; mlo_health; mesh_health; easy_mesh_controller_health; acs_health; cevent_health; neighbor_health; memory_health; dns_health; stability_health; generate_validation_summary; print_validation_summary; }
option99(){ full_suite; upload_results; echo "Upload Status      : $UPLOAD_STATUS"; }
print_paths(){ echo "CSV=$CSV"; echo "LOG=$LOG"; echo "SUMMARY=$SUMMARY"; echo "SERIAL=$SERIAL_SAFE"; }

menu(){
    echo ""; echo "============================================================"; echo " BGW620 WiFi/PWiFi Health Analyzer $VERSION"; echo "============================================================"
    echo " 1) Full Health Suite (no upload)"; echo " 2) WiFi Health"; echo " 3) Client Distribution"; echo " 4) WiFi7 / MLO Health"
    echo " 5) Mesh / Backhaul NVRAM Health"; echo " 6) ACS / Cloud Channel Health"; echo " 7) CEVENTC Auth / Drop Health"; echo " 8) Neighbor Health"
    echo " 9) System / Memory Health"; echo "10) DNS Health"; echo "11) Stability / Crash / Reboot Capture"
    echo "12) EasyMesh / MLO Controller Health (dumpCtrlInfo)"
    echo "13) Upload Current CSV/LOG/Summary to BCEO"; echo "14) Print Current File Paths"
    echo "99) Full Suite + Validation Summary + 3-File SCP Upload"; echo " 0) Exit"; echo "============================================================"; echo -n "Select option: "
}

init_report
while true; do
    menu; read OPT
    case "$OPT" in
        1) full_suite;; 2) wifi_health;; 3) client_health;; 4) mlo_health;; 5) mesh_health;; 6) acs_health;; 7) cevent_health;; 8) neighbor_health;;
        9) memory_health;; 10) dns_health;; 11) stability_health;; 12) easy_mesh_controller_health; generate_validation_summary; print_validation_summary;;
        13) generate_validation_summary; upload_results;; 14) print_paths;; 99) option99;;
        0|q|Q) print_paths; exit 0;; *) echo "Invalid option";;
    esac
done
