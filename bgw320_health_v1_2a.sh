#!/bin/sh
# BGW320 Health Analyzer V1.2a
# Nokia BGW320-505 / Humax BGW320-500
# Read-only parser-cleanup release.

VERSION="1.2a"
TS="$(date +%Y%m%d_%H%M%S 2>/dev/null || echo unknown)"
HOST="$(hostname 2>/dev/null || echo BGW320)"
OUTDIR="${OUTDIR:-/tmp}"
LOG="$OUTDIR/bgw320_health_${HOST}_${TS}.log"
CSV="$OUTDIR/bgw320_health_${HOST}_${TS}.csv"
TMP="/tmp/bgw320_v12a_$$"
PASS=0; WARN=0; FAIL=0; INFO=0
cleanup(){ rm -f "$TMP".* 2>/dev/null; }
trap cleanup EXIT INT TERM
say(){ printf '%s\n' "$*" | tee -a "$LOG"; }
section(){ say ""; say "============================================================"; say "$*"; say "============================================================"; }
q(){ printf '%s' "$1" | tr '\r\n' '  ' | sed 's/"/""/g'; }
record(){ c="$1"; n="$2"; s="$3"; v="$4"; d="$5"; case "$s" in PASS) PASS=$((PASS+1));; WARN) WARN=$((WARN+1));; FAIL) FAIL=$((FAIL+1));; *) s=INFO; INFO=$((INFO+1));; esac; printf '"%s","%s","%s","%s","%s"\n' "$(q "$c")" "$(q "$n")" "$s" "$(q "$v")" "$(q "$d")" >> "$CSV"; say "[$s] $n: $v${d:+ - $d}"; }
has(){ command -v "$1" >/dev/null 2>&1; }
trget(){ has tr69 && tr69 get "$1" 2>/dev/null; }
ubusq(){ has ubus-cli || return 127; printf '%s\nexit\n' "$1" | ubus-cli 2>/dev/null; }
nshq(){ has nsh || return 127; printf '%s\nexit\n' "$1" | nsh 2>/dev/null; }

printf '"Category","Check","Status","Value","Detail"\n' > "$CSV"; : > "$LOG"
say "BGW320 Health Analyzer V$VERSION"; say "Started: $(date)"; say "Mode: READ-ONLY"; say "Log: $LOG"; say "CSV: $CSV"

section "1. PLATFORM, FIRMWARE AND BOOTLOADER"
RAW_IMAGE="$(cat /etc/image_version 2>/dev/null | head -n 1)"
MODEL_RAW="$(trget InternetGatewayDevice.DeviceInfo.ModelName | tail -n 1)"
MODEL="$(printf '%s %s\n' "$MODEL_RAW" "$RAW_IMAGE" | grep -Eo 'BGW320-(500|505)' | head -n 1)"
FW_RAW="$(trget InternetGatewayDevice.DeviceInfo.SoftwareVersion | tail -n 1)"
[ -z "$FW_RAW" ] && has envoy-cmd && FW_RAW="$(envoy-cmd get Device.DeviceInfo.SoftwareVersion 2>/dev/null | tail -n 1)"
FW="$(printf '%s\n' "$FW_RAW" | grep -Eo '[0-9]+([.][0-9A-Za-z_@-]+){1,}' | tail -n 1)"
case "$MODEL $MODEL_RAW $RAW_IMAGE" in *505*|*Nokia*|*NOKIA*) VARIANT=Nokia;; *500*|*Humax*|*HUMAX*) VARIANT=Humax;; *) VARIANT=Unknown;; esac
record Platform Vendor INFO "$VARIANT" ""; record Platform Model INFO "${MODEL:-Unavailable}" "raw=$RAW_IMAGE"; record Platform Firmware INFO "${FW:-Unavailable}" "${FW_RAW:-raw image identity only}"
BOOT="$(trget InternetGatewayDevice.DeviceInfo.X_ATT_BootloaderInfo.)"
if [ -n "$BOOT" ]; then AP=$(printf '%s\n' "$BOOT"|awk '/ActivePartition/{print $NF}'); BV=$(printf '%s\n' "$BOOT"|awk '/BuildVersion/{print $NF}'); BD=$(printf '%s\n' "$BOOT"|awk '/BuildDate/{print $NF}'); record Bootloader Info PASS "partition=$AP version=$BV" "build=$BD"; printf '%s\n' "$BOOT" >> "$LOG"; else record Bootloader Info INFO "Not supported or unavailable" "TR-069 shell getter returned no data"; fi

section "2. CPU AND MEMORY"
MEM="$(ubusq 'Device.DeviceInfo.MemoryStatus.?')"; MU=$(printf '%s\n' "$MEM"|awk -F= '/MemoryMonitor.MemUtilization=/{gsub(/"/,"",$2);print $2;exit}')
if [ -n "$MU" ]; then [ "$MU" -lt 80 ] && S=PASS || { [ "$MU" -lt 90 ] && S=WARN || S=FAIL; }; record System Memory "$S" "${MU}%" "native monitor"; else MT=$(awk '/^MemTotal:/{print $2}' /proc/meminfo); MA=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo); [ -n "$MA" ] || MA=$(awk '/^MemFree:|^Buffers:|^Cached:/{s+=$2} END{print s+0}' /proc/meminfo); U=$(( (MT-MA)*100/MT )); [ "$U" -lt 80 ] && S=PASS || S=WARN; record System Memory "$S" "${U}%" "/proc/meminfo fallback"; fi
CPU="$(ubusq 'Device.DeviceInfo.ProcessStatus.CPU.1.?')"; CU=$(printf '%s\n' "$CPU"|awk -F= '/CPU.1.CPUUtilization=/{print $2;exit}'); ID=$(printf '%s\n' "$CPU"|awk -F= '/IdleModeUtilization=/{print $2;exit}')
if [ -n "$CU" ]; then [ "$CU" -lt 70 ] && S=PASS || { [ "$CU" -lt 85 ] && S=WARN || S=FAIL; }; record System CPU "$S" "${CU}%" "idle=${ID:-?}% native monitor"; else LOAD=$(awk '{print $1}' /proc/loadavg); record System CPU INFO "load1=$LOAD" "native object unavailable; load fallback"; fi
printf '%s\n%s\n' "$MEM" "$CPU" >> "$LOG"

section "3. PROCESS HEALTH"
PM="$(ubusq 'ProcessMonitor.Test.*.Health?')"; PT=$(printf '%s\n' "$PM"|grep -c 'Health='); PB=$(printf '%s\n' "$PM"|grep -c 'Health="Bad"')
if [ "$PT" -gt 0 ]; then PG=$((PT-PB)); [ "$PB" -eq 0 ] && S=PASS || { [ "$PB" -le 3 ] && S=WARN || S=FAIL; }; record ProcessMonitor Tests "$S" "$PG good / $PB bad" "$PT total"; printf '%s\n' "$PM"|grep 'Health="Bad"' >> "$LOG"; else record ProcessMonitor Tests INFO "Not supported or unavailable" "native query returned no test rows"; fi
PSOUT="$(ps -www 2>/dev/null || ps w 2>/dev/null || ps)"
for x in 'wl0_hapd:WiFi wl0 hostapd' 'wl1_hapd:WiFi wl1 hostapd' 'wl2_hapd:WiFi wl2 hostapd' 'acsd2:Auto channel service' 'wbd_slave:EasyMesh WBD agent' 'unbound:Unbound DNS' 'tr181-dns:TR181 DNS manager' 'cloud-comm:Cloud communication' 'cwmp:CWMP' 'ip-manager:IP manager' 'wan-manager:WAN manager' 'wan-healthcheck-manager:WAN healthcheck' 'ieee8021x-manager:802.1X manager' 'multiap_controller:MultiAP controller' 'air-steer-ng-daemon:Mesh steering'; do p=${x%%:*}; n=${x#*:}; printf '%s\n' "$PSOUT"|grep -v grep|grep -q "$p" && record Process "$n" PASS Running "$p" || record Process "$n" WARN Missing "$p"; done
ZC=$(top -bn1 2>/dev/null|awk '$4=="Z"{n++} END{print n+0}'); [ "$ZC" -eq 0 ] && S=PASS || { [ "$ZC" -le 2 ] && S=WARN || S=FAIL; }; record Process Zombies "$S" "$ZC" "top parser"; top -bn1 2>/dev/null|awk '$4=="Z"' >> "$LOG"

section "4. WIFI, HOSTAPD, RF AND MESH"
[ "$VARIANT" = Nokia ] && MAP='wl2=2.4G wl0=5G-low wl1=5G-high' || MAP='wl0=2.4G wl2=5G-low wl1=5G-high'; record WiFi Mapping INFO "$MAP" "$VARIANT"
HCLI=$(command -v hostapd_cli 2>/dev/null); [ -z "$HCLI" ] && [ -x /usr/sbin/hostapd_cli ] && HCLI=/usr/sbin/hostapd_cli
BH=$(wl -i wl1.3 map 2>/dev/null|tail -n 1); MESH=0; printf '%s\n' "$BH"|grep -q '0x2' && MESH=1
for r in wl0 wl1 wl2; do B=$(wl -i "$r" bss 2>&1); HK=""; [ -n "$HCLI" ] && HK=$($HCLI -i "$r" ping_kernel 2>&1)
 if printf '%s' "$B"|grep -qi '^up'; then record WiFi "$r BSS" PASS up ""; elif [ "$r" = wl1 ] && [ "$MESH" -eq 1 ] && printf '%s' "$HK"|grep -q '^OK' && printf '%s\n' "$PSOUT"|grep -q wbd_slave; then record WiFi "$r BSS" PASS down "EasyMesh backhaul mode active on wl1.3"; else record WiFi "$r BSS" FAIL "$(q "$B")" ""; fi
 if [ -n "$HCLI" ]; then printf '%s' "$HK"|grep -q '^OK' && record WiFi "$r kernel binding" PASS OK "" || record WiFi "$r kernel binding" FAIL "$(q "$HK")" ""; else record WiFi "$r kernel binding" INFO "Not supported or unavailable" "hostapd_cli missing"; fi
 CS=$(wl -i "$r" chanim_stats 2>/dev/null); ROW=$(printf '%s\n' "$CS"|awk '/^[0-9]+\//{x=$0} END{print x}'); [ -z "$ROW" ] && ROW=$(printf '%s\n' "$CS"|tail -n 1); if [ -n "$ROW" ]; then record WiFi "$r RF" INFO "channel=$(echo "$ROW"|awk '{print $1}') txop=$(echo "$ROW"|awk '{print $8}') noise=$(echo "$ROW"|awk '{print $13}') busy=$(echo "$ROW"|awk '{print $15}')" chanim_stats; fi; printf '%s\n' "$CS" >> "$LOG"
done
[ "$MESH" -eq 1 ] && record Mesh Backhaul PASS "$BH" "0x2 confirmed" || record Mesh Backhaul WARN "${BH:-Unavailable}" "0x2 expected when active"
WLSTAT=$(wl -i wl1 status 2>/dev/null); record WiFi "wl1 status" INFO "$(printf '%s\n' "$WLSTAT"|grep -E 'Channel:|noise:|QBSS Channel'|tr '\n' ' ')" ""; printf '%s\n' "$WLSTAT" >> "$LOG"

section "5. NETWORK AND CLIENT INVENTORY"
if has brctl; then BR=$(brctl show 2>/dev/null); SRC=brctl; elif has bridge; then BR=$(bridge link 2>/dev/null); SRC=bridge; else BR=$(ip link 2>/dev/null); SRC='ip link'; fi
WC=$(printf '%s\n' "$BR"|grep -Eo 'wl[0-2](\.[0-3])?'|sort -u|wc -l); record Network "WiFi interfaces" INFO "$WC" "$SRC"; printf '%s\n' "$BR" >> "$LOG"
for r in wl0 wl1 wl2; do C=$(wl -i "$r" assoclist 2>/dev/null|grep -c '^assoclist'); record Client "$r clients" INFO "$C" ""; done
for i in 1 5 9; do O=$(trget InternetGatewayDevice.LANDevice.1.WLANConfiguration.$i.IEEE11iAuthenticationMode); M=$(printf '%s\n' "$O"|awk 'NF{print $NF}'|tail -n 1); case "$M" in *X_ATT_PSKandSAEAuthentication*) record Security "WLAN $i auth" WARN "$M" "WPA2/WPA3 mixed";; '') record Security "WLAN $i auth" INFO "Not supported or unavailable" "object-path dependent";; *) record Security "WLAN $i auth" PASS "$M" "";; esac; done

section "6. DNS"
UC=$(command -v unbound-control 2>/dev/null); [ -z "$UC" ] && [ -x /usr/sbin/unbound-control ] && UC=/usr/sbin/unbound-control
if [ -n "$UC" ] && [ -r /etc/unbound/unbound.conf ]; then $UC -c /etc/unbound/unbound.conf stats > "$TMP.us" 2>&1; [ $? -eq 0 ] && record DNS Unbound PASS Responsive "$UC" || record DNS Unbound WARN Failed ""; $UC -c /etc/unbound/unbound.conf dump_cache > "$TMP.cache" 2>/dev/null; [ $? -eq 0 ] && record DNS "Cache dump" INFO "$(wc -c < "$TMP.cache") bytes" "$(wc -l < "$TMP.cache") lines, textual not RAM"; else record DNS Unbound INFO "Not supported or unavailable" ""; fi
DST=$(trget InternetGatewayDevice.IP.X_ATT_DNSStats.); [ -n "$DST" ] && { record DNS Statistics INFO "$(printf '%s\n' "$DST"|awk '/TotalQueries|CacheHits|CacheMisses/{printf $NF" "}')" ""; printf '%s\n' "$DST" >> "$LOG"; } || record DNS Statistics INFO "Not supported or unavailable" ""
OK=0; TOT=0; for n in www.foxnews.com www.google.com amazon.com www.cnn.com foxnews.com netflix.com; do TOT=$((TOT+1)); nslookup "$n" >/dev/null 2>&1 && OK=$((OK+1)); done; [ "$OK" -eq "$TOT" ] && S=PASS || { [ "$OK" -gt 0 ] && S=WARN || S=FAIL; }; record DNS Resolution "$S" "$OK/$TOT" ""

section "7. WAN, 802.1X AND GPON"
I8=$(ubusq 'IEEE8021x.?'); PAE=$(printf '%s\n' "$I8"|awk -F= '/PAEState=/{gsub(/"/,"",$2);print $2;exit}'); FC=$(printf '%s\n' "$I8"|awk -F= '/FailureCnt=/{print $2;exit}'); [ "$PAE" = AUTHENTICATED ] && [ "${FC:-0}" -eq 0 ] 2>/dev/null && record WAN 802.1X PASS "$PAE" "failures=${FC:-0}" || record WAN 802.1X INFO "${PAE:-Not supported or unavailable}" "failures=${FC:-?}"
W=$(nshq 'sdump conn[2]'); ST=$(printf '%s\n' "$W"|awk -F= '/\.state/{gsub(/ /,"",$2);print $2;exit}'); HS=$(printf '%s\n' "$W"|awk -F= '/health-status/{gsub(/ /,"",$2);print $2;exit}'); [ "$ST" = up ] && [ "$HS" = up ] && record WAN Connection PASS "state=$ST health=$HS" "" || record WAN Connection INFO "state=${ST:-?} health=${HS:-?}" "nsh automation unavailable or no data"; printf '%s\n' "$W" >> "$LOG"
P1=$(pspctl dump RdpaWanType 2>/dev/null|tail -n 1); P2=$(scratchpadctl dump RdpaWanType 2>/dev/null|tail -n 1); [ -n "$P1" ] && [ "$P1" = "$P2" ] && record Optical "WAN type" PASS "$P1" "sources agree" || record Optical "WAN type" WARN "psp=$P1 scratch=$P2" ""

section "8. CONFIGURATION AUDIT"
FW=$(trget InternetGatewayDevice.Firewall.Enable|awk 'NF{print $NF}'|tail -n 1); [ -z "$FW" ] && record Firewall Enabled INFO "Not supported or unavailable" "" || { [ "$FW" = 1 ] && record Firewall Enabled PASS 1 "" || record Firewall Enabled WARN "$FW" "expected 1"; }
PT=$(trget InternetGatewayDevice.LANDevice.1.LANHostConfigManagement.UseAllocatedWAN|awk 'NF{print $NF}'|tail -n 1); case "$PT" in Passthrough|X_0000C5_DefaultServer) record Firewall Passthrough WARN "$PT" "advanced mode";; '') record Firewall Passthrough INFO "Not supported or unavailable" "";; *) record Firewall Passthrough PASS "$PT" "";; esac
PME=$(trget InternetGatewayDevice.WANDevice.1.WANConnectionDevice.1.WANIPConnection.2.PortMappingNumberOfEntries|awk 'NF{print $NF}'|tail -n 1); [ -z "$PME" ] && record Firewall "Port mappings" INFO "Not supported or unavailable" "" || { [ "$PME" -eq 0 ] 2>/dev/null && record Firewall "Port mappings" PASS 0 "" || record Firewall "Port mappings" INFO "$PME" configured; }
for x in 'GFS1:InternetGatewayDevice.X_0000C5_GlobalPacketFilter.FilterSet.1.RuleNumberOfEntries:15' 'GFS2:InternetGatewayDevice.X_0000C5_GlobalPacketFilter.FilterSet.2.RuleNumberOfEntries:5' 'QoS1:InternetGatewayDevice.X_0000C5_PacketFilter.FilterSet.1.RuleNumberOfEntries:4' 'QoS2:InternetGatewayDevice.X_0000C5_PacketFilter.FilterSet.2.RuleNumberOfEntries:49' 'QoS4:InternetGatewayDevice.X_0000C5_PacketFilter.FilterSet.4.RuleNumberOfEntries:1'; do L=${x%%:*}; R=${x#*:}; PATHX=${R%:*}; E=${x##*:}; V=$(trget "$PATHX"|awk 'NF{print $NF}'|tail -n 1); [ -z "$V" ] && record Firewall "$L rules" INFO "Not supported or unavailable" "expected $E" || { [ "$V" = "$E" ] && record Firewall "$L rules" PASS "$V" "expected $E" || record Firewall "$L rules" WARN "$V" "expected $E"; }; done

section "9. FASTPATH, SLOWPATH, CONNTRACK AND QUEUES"
if [ -r /proc/fcache/stats/fhw ]; then F=$(cat /proc/fcache/stats/fhw); AF=$(printf '%s\n' "$F"|awk -F= '/Activation Failure/{gsub(/ /,"",$2);print $2}'); RF=$(printf '%s\n' "$F"|awk -F= '/Refresh Failure/{gsub(/ /,"",$2);print $2}'); [ "${AF:-0}" -eq 0 ] && [ "${RF:-0}" -eq 0 ] && S=PASS || S=WARN; record Traffic Acceleration "$S" "activation_fail=${AF:-?} refresh_fail=${RF:-?}" ""; printf '%s\n' "$F" >> "$LOG"; else record Traffic Acceleration INFO "Not supported or unavailable" ""; fi
if [ -r /proc/fcache/stats/slow_path ]; then SP=$(cat /proc/fcache/stats/slow_path); T=$(printf '%s\n' "$SP"|awk -F'[ =]' '/IPv4 RX stats/{for(i=1;i<=NF;i++)if($i~/total/){print $(i+1);exit}}'); A=$(printf '%s\n' "$SP"|grep -Eo 'accel_bypass=[0-9]+'|head -n1|cut -d= -f2); R=0; [ -n "$T" ] && [ "$T" -gt 0 ] && R=$((A*100/T)); [ "$R" -lt 50 ] && S=PASS || { [ "$R" -lt 85 ] && S=WARN || S=FAIL; }; record Traffic "Acceleration bypass" "$S" "$R%" "bypass=${A:-0} total=${T:-0}"; printf '%s\n' "$SP" >> "$LOG"; else record Traffic SlowPath INFO "Not supported or unavailable" ""; fi
if [ -r /proc/net/nf_conntrack ]; then UR=$(grep -c '\[UNREPLIED\]' /proc/net/nf_conntrack); LG=$(awk '/\[UNREPLIED\]/{for(i=1;i<=NF;i++)if($i~/^packets=/){split($i,a,"=");if(a[2]>1000000){n++;break}}}END{print n+0}' /proc/net/nf_conntrack); [ "$LG" -eq 0 ] && S=PASS || S=WARN; record Traffic UNREPLIED "$S" "$UR total / $LG large" ">1M packets"; fi
if has bs; then bs /b/e egress_tm > "$TMP.tm" 2>&1; D=$(grep -Eo 'discarded=\{packets=[0-9]+' "$TMP.tm"|awk -F= '{s+=$3}END{print s+0}'); [ "$D" -eq 0 ] && S=PASS || S=WARN; record Traffic "Queue discards" "$S" "$D" ""; cat "$TMP.tm" >> "$LOG"; else record Traffic Queues INFO "Not supported or unavailable" "bs missing from PATH"; fi

section "10. LED, REBOOT AND CRASH"
LED=$(trget InternetGatewayDevice.DeviceInfo.X_0000C5_LEDStatus.); LC=$(printf '%s\n' "$LED"|awk '/LED.3.ColorName/{print $NF}'); LP=$(printf '%s\n' "$LED"|awk '/LED.3.Pattern/{print $NF}'); if [ -z "$LC" ]; then record LED Main INFO "Not supported or unavailable" ""; elif [ "$LC" = White ] && [ "$LP" = Solid ]; then record LED Main PASS "$LC/$LP" Normal; else record LED Main WARN "$LC/$LP" ""; fi
RF=/data/system/reboothistory.txt; if [ -r "$RF" ]; then record Recovery Reboots PASS Found "$RF"; grep ',' "$RF"|while IFS=',' read -r ep ev rest; do case "$ep" in *[!0-9]*|'') ds=INVALID;; *) ds=$(date -d "@$ep" '+%Y-%m-%d %H:%M:%S' 2>/dev/null); [ -z "$ds" ] && ds=$(date -r "$ep" '+%Y-%m-%d %H:%M:%S' 2>/dev/null);; esac; echo "$ds,$ev${rest:+,$rest}" >> "$LOG"; done; else record Recovery Reboots WARN Missing "$RF"; fi
for d in /data/faults /data/oops /data/crashdump /data/core_dump_folder; do [ -d "$d" ] || continue; N=$(find "$d" -type f 2>/dev/null|wc -l); [ "$N" -eq 0 ] && S=PASS || S=WARN; record Recovery "$d" "$S" "$N" files; done

section "11. FINAL ASSESSMENT"
SC=$((PASS+WARN+FAIL)); [ "$SC" -gt 0 ] && SCORE=$((PASS*100/SC)) || SCORE=0
if [ "$FAIL" -gt 0 ]; then OVERALL=FAIL; elif [ "$WARN" -gt 0 ]; then OVERALL='PASS WITH OBSERVATIONS'; else OVERALL=PASS; fi
say "PASS=$PASS WARN=$WARN FAIL=$FAIL INFO=$INFO"; say "PASS RATE=$SCORE%"; say "OVERALL=$OVERALL"; say "Generated: $LOG"; say "Generated: $CSV"
printf '"Summary","Overall","%s","%s%%","PASS=%s WARN=%s FAIL=%s INFO=%s"\n' "$OVERALL" "$SCORE" "$PASS" "$WARN" "$FAIL" "$INFO" >> "$CSV"
exit 0
