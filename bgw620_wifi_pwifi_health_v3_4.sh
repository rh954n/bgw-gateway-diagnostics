#!/bin/sh
# BGW620 WiFi / PWiFi / AirTies Health Diagnostics V3.4
# Read-only diagnostics. No envoy-cmd set.
# V3.4 fixes:
# - neighbor_failed 6-20 = WARN, 21+ = FAIL
# - authorized_events is no longer incorrectly marked WARN for disassoc count
# - disassoc_health has its own PASS/WARN row
# - MLO parsing uses MLO_ACTIVE, MLD0:: nlink, and link lines in addition to MLO SCB

TS=`date +%Y%m%d_%H%M%S 2>/dev/null`; [ -z "$TS" ] && TS="manual"
LOG="/tmp/rg_diag_${TS}.log"
CSV="/tmp/rg_diag_${TS}.csv"
HOSTNAME_RG=`hostname 2>/dev/null`; [ -z "$HOSTNAME_RG" ] && HOSTNAME_RG="dsldevice"
MODEL="BGW620"
CSHELL=""
UPLOAD_SERVER="99.124.173.137"
UPLOAD_USER="rh954n"
UPLOAD_PORT="2245"
UPLOAD_DEST="/home/rh954n"

log_line(){ echo "$1" | tee -a "$LOG"; }
csv_header(){ echo "Timestamp,RG_Host,Model,Category,Test,Metric,Value,Result,Notes" > "$CSV"; }
csv_row(){ NOW=`date '+%Y-%m-%d %H:%M:%S' 2>/dev/null`; echo "$NOW,$HOSTNAME_RG,$MODEL,$1,$2,$3,$4,$5,$6" >> "$CSV"; }
find_cshell(){ if command -v cshell >/dev/null 2>&1; then CSHELL=`command -v cshell`; return 0; fi; for c in /bin/cshell /usr/bin/cshell /sbin/cshell /usr/sbin/cshell /usr/local/bin/cshell; do [ -x "$c" ] && CSHELL="$c" && return 0; done; CSHELL=""; return 1; }
run_cmd(){ DESC="$1"; shift; log_line ""; log_line "============================================================"; log_line "$DESC"; log_line "Command: $*"; log_line "============================================================"; "$@" 2>&1 | tee -a "$LOG"; }
run_cshell(){ DESC="$1"; CMD="$2"; find_cshell; if [ -n "$CSHELL" ]; then run_cmd "$DESC" "$CSHELL" -c "$CMD"; else log_line "cshell not found for: $CMD"; csv_row "system" "cshell" "path" "not_found" "SKIP" "cshell not visible"; fi; }

network_quick(){ run_cmd "PING 8.8.8.8" ping -c 20 8.8.8.8; run_cmd "NSLOOKUP www.google.com" nslookup www.google.com; run_cmd "TRACEROUTE www.google.com" traceroute -n www.google.com; }

wifi_clients(){
  TMP="/tmp/bgw620_assoc_${TS}.tmp"; : > "$TMP"
  echo ""; echo "=================================================="; echo " WIFI CLIENTS"; echo "=================================================="
  wl -e assoclist > "$TMP" 2>&1; cat "$TMP" | tee -a "$LOG"
  if grep -qi "not found\|No such file\|Usage" "$TMP" && ! grep -q "^assoclist" "$TMP"; then
    csv_row "wifi" "clients_assoclist" "wl" "command_failed" "SKIP" "wl -e assoclist did not return client data"
  else
    C=`grep -c "^assoclist" "$TMP" 2>/dev/null`; [ -z "$C" ] && C=0
    if [ "$C" -gt 0 ]; then R="PASS"; N="Associated clients found"; else R="WARN"; N="wl ran but no associated clients found"; fi
    csv_row "wifi" "clients_assoclist" "assoc_client_count" "$C" "$R" "$N"
  fi
  run_cshell "IP LAN TABLE" "show ip lan"; rm -f "$TMP"
}

wifi_detail(){
  run_cshell "WIFI SUMMARY" "show wireless"
  for i in wl0 wl1 wl2; do
    run_cmd "wl $i status" wl -i "$i" status
    run_cmd "wl $i bss" wl -i "$i" bss
    hostapd_cli -i "$i" status >/tmp/hostapd_${i}_${TS}.tmp 2>&1
    if [ -s /tmp/hostapd_${i}_${TS}.tmp ]; then log_line ""; log_line "hostapd $i status"; cat /tmp/hostapd_${i}_${TS}.tmp | tee -a "$LOG"; fi
    rm -f /tmp/hostapd_${i}_${TS}.tmp
  done
  csv_row "wifi" "detail" "show_wireless_wl_hostapd" "see_log" "INFO" "Detailed WiFi status collected"
}

acs_mlo_summary(){
  TMP="/tmp/bgw620_acs_mlo_${TS}.tmp"; rm -f "$TMP"
  echo ""; echo "=================================================="; echo " ACS / MLO SUMMARY"; echo "=================================================="; echo "Collecting ACS/MLO data into TMP file: $TMP"
  acs_cli2 -i wl0 -R > "$TMP" 2>&1
  SIZE=`wc -c < "$TMP" 2>/dev/null`; [ -z "$SIZE" ] && SIZE=0
  csv_row "wifi" "acs_mlo_summary" "tmp_file" "$TMP" "INFO" "ACS temporary capture file"
  csv_row "wifi" "acs_mlo_summary" "tmp_size_after_wl0" "$SIZE" "INFO" "ACS wl0 capture size"
  echo "TMP size after wl0 collection: $SIZE bytes"
  if [ "$SIZE" -eq 0 ]; then echo "ERROR: ACS file empty after wl0 collection"; csv_row "wifi" "acs_mlo_summary" "collection_status" "empty_after_wl0" "FAIL" "acs_cli2 wl0 returned no data"; return; fi
  echo "" >> "$TMP"; acs_cli2 -i wl1 -R >> "$TMP" 2>&1
  echo "" >> "$TMP"; acs_cli2 -i wl2 -R >> "$TMP" 2>&1
  echo "" >> "$TMP"; acs_cli2 -i wl0 dump cscore >> "$TMP" 2>&1
  echo "" >> "$TMP"; acs_cli2 -i wl1 dump cscore >> "$TMP" 2>&1
  echo "" >> "$TMP"; acs_cli2 -i wl2 dump cscore >> "$TMP" 2>&1
  echo "" >> "$TMP"; map_cli --command dumpChanSel --payload '{"extended": true}' >> "$TMP" 2>&1
  SIZE=`wc -c < "$TMP" 2>/dev/null`; [ -z "$SIZE" ] && SIZE=0
  csv_row "wifi" "acs_mlo_summary" "tmp_size_bytes" "$SIZE" "PASS" "ACS capture file size"
  echo "" >> "$LOG"; echo "============================================================" >> "$LOG"; echo "ACS / MLO RAW DATA" >> "$LOG"; echo "============================================================" >> "$LOG"; cat "$TMP" >> "$LOG"
  echo "" >> "$LOG"; echo "ACS TMP DEBUG" >> "$LOG"; ls -lh "$TMP" >> "$LOG" 2>&1; head -20 "$TMP" >> "$LOG" 2>&1
  ACSD=`grep -i "acsd version" "$TMP" | head -1 | awk -F: '{print $2}' | sed 's/^ *//'`
  WL0=`grep "ifname: wl0" "$TMP" | head -1 | awk -F'mode:' '{print $2}' | sed 's/^ *//'`
  WL1=`grep "ifname: wl1" "$TMP" | head -1 | awk -F'mode:' '{print $2}' | sed 's/^ *//'`
  WL2=`grep "ifname: wl2" "$TMP" | head -1 | awk -F'mode:' '{print $2}' | sed 's/^ *//'`
  TRIG=`grep "ACS-Trigger" -A2 "$TMP" | tail -1 | awk '{print $3}'`
  CHAN=`grep "ACS-Trigger" -A2 "$TMP" | tail -1 | awk '{print $4}'`
  TCMD=`grep "Total cmd" "$TMP" | head -1 | sed 's/.*Total cmd: *//' | awk -F, '{print $1}' | sed 's/^ *//'`
  VCMD=`grep "Total cmd" "$TMP" | head -1 | sed 's/.*Valid cmd: *//' | sed 's/^ *//'`
  TEVT=`grep "Total events" "$TMP" | head -1 | sed 's/.*Total events: *//' | awk -F, '{print $1}' | sed 's/^ *//'`
  VEVT=`grep "Total events" "$TMP" | head -1 | sed 's/.*Valid events: *//' | sed 's/^ *//'`
  NPSC=`grep -c "Invalid:NON_PSC" "$TMP" 2>/dev/null`; EXCL=`grep -c "Invalid:EXCLUDE" "$TMP" 2>/dev/null`
  [ -z "$ACSD" ] && ACSD="unknown"; [ -z "$WL0" ] && WL0="unknown"; [ -z "$WL1" ] && WL1="unknown"; [ -z "$WL2" ] && WL2="unknown"; [ -z "$TRIG" ] && TRIG="unknown"; [ -z "$CHAN" ] && CHAN="unknown"; [ -z "$TCMD" ] && TCMD="unknown"; [ -z "$VCMD" ] && VCMD="unknown"; [ -z "$TEVT" ] && TEVT="unknown"; [ -z "$VEVT" ] && VEVT="unknown"
  R="PASS"; N="ACSD present and summary collected"; if [ "$WL0" != "auto" ] || [ "$WL1" != "auto" ] || [ "$WL2" != "auto" ]; then R="WARN"; N="One or more radios are not auto"; fi; if [ "$ACSD" = "unknown" ]; then R="WARN"; N="ACSD version not detected"; fi
  echo "ACSD Version      : $ACSD"; echo "wl0/wl1/wl2 Mode  : $WL0 / $WL1 / $WL2"; echo "ACS Trigger       : $TRIG"; echo "Current Chanspec  : $CHAN"; echo "Total/Valid Cmd   : $TCMD / $VCMD"; echo "Total/Valid Events: $TEVT / $VEVT"; echo "Result            : $R"
  csv_row "wifi" "acs_mlo_summary" "acsd_version" "$ACSD" "$R" "$N"
  csv_row "wifi" "acs_mlo_summary" "wl0_mode" "$WL0" "INFO" "Radio mode"
  csv_row "wifi" "acs_mlo_summary" "wl1_mode" "$WL1" "INFO" "Radio mode"
  csv_row "wifi" "acs_mlo_summary" "wl2_mode" "$WL2" "INFO" "Radio mode"
  csv_row "wifi" "acs_mlo_summary" "acs_trigger" "$TRIG" "INFO" "ACS trigger"
  csv_row "wifi" "acs_mlo_summary" "current_chanspec" "$CHAN" "INFO" "Current ACS channel"
  csv_row "wifi" "acs_mlo_summary" "total_cmd" "$TCMD" "INFO" "ACS command count"
  csv_row "wifi" "acs_mlo_summary" "valid_cmd" "$VCMD" "INFO" "ACS valid command count"
  csv_row "wifi" "acs_mlo_summary" "total_events" "$TEVT" "INFO" "ACS event count"
  csv_row "wifi" "acs_mlo_summary" "valid_events" "$VEVT" "INFO" "ACS valid event count"
  csv_row "wifi" "acs_mlo_summary" "non_psc_count" "$NPSC" "INFO" "NON_PSC is informational for 6GHz"
  csv_row "wifi" "acs_mlo_summary" "exclude_candidate_count" "$EXCL" "INFO" "Invalid EXCLUDE candidate count"
}

bridge_health(){
  run_cmd "brctl show" brctl show; run_cmd "brctl showmacs br1" brctl showmacs br1; run_cmd "ip -s link" ip -s link; run_cmd "arp -n" arp -n; run_cmd "ip neigh show" ip neigh show; run_cmd "softnet_stat" cat /proc/net/softnet_stat
  FAILED=`ip neigh show 2>/dev/null | grep -c FAILED`; INCOMPLETE=`ip neigh show 2>/dev/null | grep -c INCOMPLETE`; STALE=`ip neigh show 2>/dev/null | grep -c STALE`; REACHABLE=`ip neigh show 2>/dev/null | grep -c REACHABLE`
  [ -z "$FAILED" ] && FAILED=0; [ -z "$INCOMPLETE" ] && INCOMPLETE=0; [ -z "$STALE" ] && STALE=0; [ -z "$REACHABLE" ] && REACHABLE=0
  if [ "$FAILED" -le 5 ] && [ "$INCOMPLETE" -eq 0 ]; then R="PASS"; N="Normal FAILED/INCOMPLETE neighbor count"; elif [ "$FAILED" -le 20 ]; then R="WARN"; N="Moderate FAILED neighbor count; verify if clients are actually impacted"; else R="FAIL"; N="High FAILED neighbor count"; fi
  csv_row "network" "neighbor_health" "neighbor_failed" "$FAILED" "$R" "$N"
  csv_row "network" "neighbor_health" "neighbor_incomplete" "$INCOMPLETE" "INFO" "INCOMPLETE neighbor count"
  csv_row "network" "neighbor_health" "neighbor_stale" "$STALE" "INFO" "STALE neighbor count"
  csv_row "network" "neighbor_health" "neighbor_reachable" "$REACHABLE" "INFO" "REACHABLE neighbor count"
}

log_auth_health(){
  TMP="/tmp/bgw620_auth_${TS}.tmp"; : > "$TMP"
  for f in /var/log/system.log /var/log/system.log.1 /var/log/system.log.2 /var/log/system.log.3 /var/log/system.log.4; do [ -f "$f" ] && grep -iE "authentication failed|auth fail|deauth|disassoc|WLC_SCB_DEAUTHORIZE|MIC failure|wrong password|handshake failed|SAE failed|wl_cfg80211.*ERROR" "$f" >> "$TMP" 2>/dev/null; done
  dmesg 2>/dev/null | grep -iE "authentication failed|auth fail|deauth|disassoc|WLC_SCB_DEAUTHORIZE|MIC failure|wrong password|handshake failed|SAE failed|wl_cfg80211.*ERROR" >> "$TMP"
  C=`wc -l < "$TMP" | tr -d ' '`; [ -z "$C" ] && C=0
  if [ "$C" -gt 0 ]; then cat "$TMP" | tee -a "$LOG"; csv_row "wifi" "auth_drop_log_check" "warn_keyword_count" "$C" "WARN" "Specific auth or deauth keywords found"; else csv_row "wifi" "auth_drop_log_check" "warn_keyword_count" "$C" "PASS" "No specific auth or deauth keywords found"; fi
  rm -f "$TMP"
}

ceventc_auth_summary(){
  TMP="/tmp/ceventc_${TS}.txt"; echo ""; echo "=================================================="; echo " CEVENTC AUTHENTICATION SUMMARY"; echo "=================================================="
  ceventc dump > "$TMP" 2>&1; cat "$TMP" >> "$LOG"
  AUTH=`grep -c "E_AUTH/" "$TMP" 2>/dev/null`; ASSOC=`grep -c "E_ASSOC/" "$TMP" 2>/dev/null`; ASSOC_IND=`grep -c "E_ASSOC_IND" "$TMP" 2>/dev/null`; AUTHZ=`grep -c "E_AUTHORIZED" "$TMP" 2>/dev/null`; DIS=`grep -c "E_DISASSOC" "$TMP" 2>/dev/null`; REASSOC=`grep -c "E_REASSOC" "$TMP" 2>/dev/null`; SAE=`grep -c "SAE_AUTH" "$TMP" 2>/dev/null`; M1=`grep -c "M1_TX" "$TMP" 2>/dev/null`; M2=`grep -c "M2_RX" "$TMP" 2>/dev/null`; M3=`grep -c "M3_TX" "$TMP" 2>/dev/null`; M4=`grep -c "M4_RX" "$TMP" 2>/dev/null`; DRX=`grep -c "DHCP_RX" "$TMP" 2>/dev/null`; DTX=`grep -c "DHCP_TX" "$TMP" 2>/dev/null`
  for v in AUTH ASSOC ASSOC_IND AUTHZ DIS REASSOC SAE M1 M2 M3 M4 DRX DTX; do eval '[ -z "$'$v'" ] && '$v'=0'; done
  DIS_R="PASS"; DIS_N="Normal disassociation event count"; [ "$DIS" -gt 30 ] && DIS_R="WARN" && DIS_N="High disassociation event count"
  AUTH_R="PASS"; AUTH_N="Authorization events present"; [ "$AUTHZ" -eq 0 ] && [ "$AUTH" -gt 0 ] && AUTH_R="WARN" && AUTH_N="Authentication events seen but no E_AUTHORIZED event found"
  echo "Auth Events        : $AUTH"; echo "Assoc Events       : $ASSOC"; echo "Authorized Events  : $AUTHZ"; echo "Disassoc Events    : $DIS"; echo "Disassoc Health    : $DIS_R"; echo "SAE Events         : $SAE"; echo "M1/M2/M3/M4        : $M1/$M2/$M3/$M4"; echo "DHCP RX/TX         : $DRX/$DTX"
  csv_row "wifi" "ceventc_auth_summary" "auth_events" "$AUTH" "INFO" "E_AUTH count"
  csv_row "wifi" "ceventc_auth_summary" "assoc_events" "$ASSOC" "INFO" "E_ASSOC count"
  csv_row "wifi" "ceventc_auth_summary" "assoc_ind_events" "$ASSOC_IND" "INFO" "E_ASSOC_IND count"
  csv_row "wifi" "ceventc_auth_summary" "authorized_events" "$AUTHZ" "$AUTH_R" "$AUTH_N"
  csv_row "wifi" "ceventc_auth_summary" "disassoc_events" "$DIS" "INFO" "E_DISASSOC count"
  csv_row "wifi" "ceventc_auth_summary" "disassoc_health" "$DIS" "$DIS_R" "$DIS_N"
  csv_row "wifi" "ceventc_auth_summary" "reassoc_events" "$REASSOC" "INFO" "E_REASSOC count"
  csv_row "wifi" "ceventc_auth_summary" "sae_events" "$SAE" "INFO" "SAE_AUTH count"
  csv_row "wifi" "ceventc_auth_summary" "m1_m2_m3_m4" "$M1/$M2/$M3/$M4" "INFO" "4-way handshake counts"
  csv_row "wifi" "ceventc_auth_summary" "dhcp_rx_tx" "$DRX/$DTX" "INFO" "DHCP event counts"
  rm -f "$TMP"
}

ceventc_recent_events(){ TMP="/tmp/ceventc_${TS}.txt"; echo ""; echo "=================================================="; echo " RECENT AUTH / DEAUTH EVENTS"; echo "=================================================="; ceventc dump > "$TMP" 2>&1; grep -E "E_AUTH|E_ASSOC|E_REASSOC|E_DISASSOC|E_AUTHORIZED|SAE_AUTH|M1_TX|M2_RX|M3_TX|M4_RX|DHCP_RX|DHCP_TX" "$TMP" | tail -50; echo ""; echo "Displayed last 50 authentication-related events. Full ceventc dump saved to LOG."; cat "$TMP" >> "$LOG"; csv_row "wifi" "ceventc_recent_events" "recent_auth_events" "see_log" "INFO" "Displayed last 50 auth and deauth events"; rm -f "$TMP"; }

bulk_data_health(){ TMP="/tmp/bulk_data_${TS}.tmp"; : > "$TMP"; grep -ih "BULK DATA: report sending failed" /var/log/system.log* > "$TMP" 2>/dev/null; C=`wc -l < "$TMP" | tr -d ' '`; [ -z "$C" ] && C=0; FIRST=`head -1 "$TMP" 2>/dev/null | sed 's/,/ /g'`; LAST=`tail -1 "$TMP" 2>/dev/null | sed 's/,/ /g'`; if [ "$C" -eq 0 ]; then R="PASS"; N="No Bulk Data timeout failures"; elif [ "$C" -le 5 ]; then R="WARN"; N="Some Bulk Data timeout failures"; else R="FAIL"; N="Repeated Bulk Data timeout failures"; fi; cat "$TMP" | tee -a "$LOG"; csv_row "eco" "bulk_data_health" "failure_count" "$C" "$R" "$N"; csv_row "eco" "bulk_data_health" "first_timeout" "$FIRST" "INFO" "First Bulk Data timeout"; csv_row "eco" "bulk_data_health" "last_timeout" "$LAST" "INFO" "Last Bulk Data timeout"; rm -f "$TMP"; }

stomp_reboot_health(){ echo ""; echo "=================================================="; echo " STOMP / REBOOT HEALTH"; echo "=================================================="; echo ""; echo "[STOMP STATUS]"; envoy-cmd get Device.STOMP. 2>&1 | tee -a "$LOG"; echo ""; echo "[REBOOT COUNTER]"; envoy-cmd get Device.DeviceInfo.X_ATT_RebootCounter 2>&1 | tee -a "$LOG"; echo ""; echo "[REBOOT HISTORY]"; envoy-cmd get Device.DeviceInfo.X_ATT_RebootHistory 2>&1 | tee -a "$LOG"; csv_row "eco" "stomp_status" "Device.STOMP" "see_log" "INFO" "Collected via envoy-cmd get"; csv_row "eco" "reboot_counter" "Device.DeviceInfo.X_ATT_RebootCounter" "see_log" "INFO" "Collected via envoy-cmd get"; csv_row "eco" "reboot_history" "Device.DeviceInfo.X_ATT_RebootHistory" "see_log" "INFO" "Collected via envoy-cmd get"; }

airties_process_health(){ TMP="/tmp/airties_proc_${TS}.tmp"; ps 2>/dev/null | grep -E "air-|multiap|map-|domos|qos" | grep -v grep | tee "$TMP" | tee -a "$LOG"; C=`wc -l < "$TMP" | tr -d ' '`; [ -z "$C" ] && C=0; if [ "$C" -gt 0 ]; then csv_row "pwifi" "airties_process_health" "process_count" "$C" "PASS" "AirTies/PWiFi processes found"; else csv_row "pwifi" "airties_process_health" "process_count" "$C" "WARN" "No AirTies/PWiFi process names found"; fi; rm -f "$TMP"; }

crash_signature_analysis(){ TMP="/tmp/crash_sig_${TS}.tmp"; : > "$TMP"; run_cshell "CRITICAL LOG" "show log criticallog"; dmesg 2>/dev/null | grep -iE "core dump|sig -6|sig -7|sig -11|segfault|killed because of sig|air-detector|air-qos|air-journal|air-dpi|air-map-qos|multiap" >> "$TMP"; for f in /var/log/system.log /var/log/system.log.1 /var/log/system.log.2 /var/log/system.log.3 /var/log/system.log.4; do [ -f "$f" ] && grep -iE "core dump|sig -6|sig -7|sig -11|segfault|killed because of sig|air-detector|air-qos|air-journal|air-dpi|air-map-qos|multiap" "$f" >> "$TMP" 2>/dev/null; done; C=`wc -l < "$TMP" | tr -d ' '`; [ -z "$C" ] && C=0; if [ "$C" -gt 0 ]; then cat "$TMP" | tee -a "$LOG"; csv_row "pwifi" "crash_signature_analysis" "signature_count" "$C" "WARN" "Crash/signature keywords found"; else csv_row "pwifi" "crash_signature_analysis" "signature_count" "$C" "PASS" "No crash signatures found"; fi; rm -f "$TMP"; }

wifi7_mlo_health(){
  MLO="/tmp/bgw620_mlo_${TS}.tmp"; CUR="/tmp/bgw620_curppr_${TS}.tmp"; EHT="/tmp/bgw620_eht_${TS}.tmp"; CH="/tmp/bgw620_chanspec_${TS}.tmp"
  echo ""; echo "=================================================="; echo " WIFI7 / MLO HEALTH"; echo "=================================================="
  wl -i wl0 mlo info > "$MLO" 2>&1; wl -i wl0 curppr > "$CUR" 2>&1; wl -i wl0 eht > "$EHT" 2>&1; wl -i wl0 chanspec > "$CH" 2>&1
  echo "" >> "$LOG"; echo "============================================================" >> "$LOG"; echo "WIFI7 / MLO RAW DATA" >> "$LOG"; echo "============================================================" >> "$LOG"; cat "$MLO" "$CUR" "$EHT" "$CH" >> "$LOG"
  MLO_ACTIVE=`grep "MLO_ACTIVE" "$MLO" | head -1 | sed 's/^ *//'`
  MLD_LINKS=`grep "MLD0::" "$MLO" | head -1 | sed 's/.*nlink //' | awk '{print $1}'`
  [ -z "$MLD_LINKS" ] && MLD_LINKS=`wl -i wl0 mld_nlinks 2>/dev/null | head -1 | sed 's/^ *//'`
  CUR_CHAN=`grep "Current channel:" "$CUR" | head -1 | awk -F: '{print $2}' | sed 's/^ *//'`
  [ -z "$CUR_CHAN" ] && CUR_CHAN=`cat "$CH" | head -1 | sed 's/^ *//'`
  W320=`grep -c "320MHz\|/320" "$CUR" 2>/dev/null`; EHTVAL=`cat "$EHT" | head -1 | sed 's/^ *//'`
  MLO_SCB=`grep -c "MLO SCB" "$MLO" 2>/dev/null`; MLD0_COUNT=`grep -c "MLD0::" "$MLO" 2>/dev/null`; ACTIVE_LINKS=`grep -c "link[0-9]:" "$MLO" 2>/dev/null`
  [ -z "$MLO_ACTIVE" ] && MLO_ACTIVE="unknown"; [ -z "$MLD_LINKS" ] && MLD_LINKS="unknown"; [ -z "$CUR_CHAN" ] && CUR_CHAN="unknown"; [ -z "$W320" ] && W320=0; [ -z "$MLO_SCB" ] && MLO_SCB=0; [ -z "$MLD0_COUNT" ] && MLD0_COUNT=0; [ -z "$ACTIVE_LINKS" ] && ACTIVE_LINKS=0; [ -z "$EHTVAL" ] && EHTVAL="unknown"
  R="PASS"; N="WiFi7 MLO data collected"; if ! echo "$MLO_ACTIVE" | grep -q "TRUE"; then R="WARN"; N="MLO active not TRUE"; fi; if [ "$W320" -eq 0 ]; then R="WARN"; N="320MHz evidence not detected"; fi
  echo "MLO Active       : $MLO_ACTIVE"; echo "MLD Links        : $MLD_LINKS"; echo "Current Chanspec : $CUR_CHAN"; echo "320 MHz Evidence : $W320"; echo "MLO SCB Count    : $MLO_SCB"; echo "MLD0 Count       : $MLD0_COUNT"; echo "Active Link Count: $ACTIVE_LINKS"; echo "EHT              : $EHTVAL"; echo "Result           : $R"
  csv_row "wifi7" "wifi7_mlo_health" "mlo_active" "$MLO_ACTIVE" "$R" "$N"
  csv_row "wifi7" "wifi7_mlo_health" "mld_links" "$MLD_LINKS" "INFO" "MLO link count parsed from MLD0 or mld_nlinks"
  csv_row "wifi7" "wifi7_mlo_health" "current_chanspec" "$CUR_CHAN" "INFO" "Current chanspec"
  csv_row "wifi7" "wifi7_mlo_health" "width_320_evidence_count" "$W320" "INFO" "320MHz evidence count"
  csv_row "wifi7" "wifi7_mlo_health" "mlo_scb_count" "$MLO_SCB" "INFO" "Literal MLO SCB count if present"
  csv_row "wifi7" "wifi7_mlo_health" "mld0_count" "$MLD0_COUNT" "INFO" "MLD0 line count"
  csv_row "wifi7" "wifi7_mlo_health" "active_link_count" "$ACTIVE_LINKS" "INFO" "Number of link lines in mlo info"
  csv_row "wifi7" "wifi7_mlo_health" "eht" "$EHTVAL" "INFO" "EHT value"
}

overall_health(){ echo ""; echo "=================================================="; echo " OVERALL HEALTH SUMMARY"; echo "=================================================="; W=`grep -c ",WARN," "$CSV" 2>/dev/null`; F=`grep -c ",FAIL," "$CSV" 2>/dev/null`; [ -z "$W" ] && W=0; [ -z "$F" ] && F=0; if [ "$F" -gt 0 ]; then O="FAIL"; elif [ "$W" -gt 0 ]; then O="PASS_WITH_WARNINGS"; else O="PASS"; fi; echo "WARN rows : $W"; echo "FAIL rows : $F"; echo "Overall   : $O"; csv_row "summary" "overall_health" "warn_count" "$W" "INFO" "Total WARN rows"; csv_row "summary" "overall_health" "fail_count" "$F" "INFO" "Total FAIL rows"; csv_row "summary" "overall_health" "overall" "$O" "$O" "Overall health result"; }

wifi_health(){ wifi_detail; wifi_clients; ceventc_auth_summary; log_auth_health; acs_mlo_summary; bridge_health; wifi7_mlo_health; }
full_suite(){ network_quick; wifi_health; airties_process_health; crash_signature_analysis; bulk_data_health; stomp_reboot_health; overall_health; }
upload_results(){ echo ""; echo "CSV: $CSV"; echo "LOG: $LOG"; echo -n "Upload to lab server? (y/n): "; read UPLOAD; case "$UPLOAD" in y|Y|yes|YES|Yes) scp -P "$UPLOAD_PORT" "$CSV" "$LOG" ${UPLOAD_USER}@${UPLOAD_SERVER}:${UPLOAD_DEST}/ ;; *) echo "Upload skipped." ;; esac; }

csv_header; find_cshell; log_line "BGW620 diagnostics V3.4 started $TS"; run_cshell "MODEL SUMMARY" "show summary"; csv_row "system" "start" "script" "bgw620_wifi_pwifi_health_v3_4" "INFO" "BGW620 V3.4 started"
while true; do
  echo ""; echo "=================================================="; echo " BGW620 WiFi / PWiFi / AirTies Health V3.4"; echo "=================================================="
  echo "1) Full suite"; echo "2) WiFi health"; echo "3) WiFi clients"; echo "4) ACS/MLO summary with TMP validation"; echo "5) Bridge / Neighbor health"; echo "6) PWiFi/AirTies process health"; echo "7) Crash signature analysis"; echo "8) STOMP/Reboot health"; echo "9) Bulk Data health"; echo "10) ceventc Authentication Summary"; echo "11) ceventc Recent Auth/Deauth Events"; echo "12) WiFi detail"; echo "13) WiFi7 / MLO Health"; echo "14) Overall Health Summary"; echo "P) Print paths"; echo "Q) Quit/upload"; echo ""; echo -n "Select option: "; read OPT
  case "$OPT" in 1) full_suite ;; 2) wifi_health ;; 3) wifi_clients ;; 4) acs_mlo_summary ;; 5) bridge_health ;; 6) airties_process_health ;; 7) crash_signature_analysis ;; 8) stomp_reboot_health ;; 9) bulk_data_health ;; 10) ceventc_auth_summary ;; 11) ceventc_recent_events ;; 12) wifi_detail ;; 13) wifi7_mlo_health ;; 14) overall_health ;; p|P) echo "CSV=$CSV"; echo "LOG=$LOG"; echo "CSHELL=$CSHELL" ;; q|Q) upload_results; exit 0 ;; *) echo "Invalid option" ;; esac
done
