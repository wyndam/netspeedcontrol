#!/bin/sh

set -e

export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

TABLE_FAMILY="inet"
TABLE_NAME="netspeedcontrol"
CHAIN_PREROUTING_NAME="prerouting"
CHAIN_NAME="forward"
CHAIN_INPUT_NAME="input"
CONFIG_NAME="netspeedcontrol"
LEASE_FILE="/tmp/dhcp.leases"
STATE_DIR="/var/run/netspeedcontrol"
NFT_BIN="/usr/sbin/nft"
IP_BIN="/sbin/ip"
LOGGER_BIN="/usr/bin/logger"
CONNTRACK_BIN="/usr/sbin/conntrack"
EVENT_LOG_ENABLED="0"
EVENT_LOG_FILE="/tmp/netspeedcontrol-events.log"
EVENT_LOG_MAX_LINES="200"

[ -x "$LOGGER_BIN" ] || LOGGER_BIN="/bin/logger"
[ -x "$CONNTRACK_BIN" ] || CONNTRACK_BIN="/usr/bin/conntrack"
[ -x "$CONNTRACK_BIN" ] || CONNTRACK_BIN=""

. /lib/functions.sh

mkdir -p "$STATE_DIR"

log() {
	"$LOGGER_BIN" -t netspeedcontrol "$*" 2>/dev/null || echo "netspeedcontrol: $*" >&2
}

require_tools() {
	[ -x "$NFT_BIN" ] || {
		log "nft command not found at $NFT_BIN"
		return 1
	}

	[ -x "$IP_BIN" ] || {
		log "ip command not found at $IP_BIN"
		return 1
	}
}

ensure_table() {
	"$NFT_BIN" list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1 && return 0
	"$NFT_BIN" add table "$TABLE_FAMILY" "$TABLE_NAME"
	"$NFT_BIN" add chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING_NAME" "{ type filter hook prerouting priority raw; policy accept; }"
	"$NFT_BIN" add chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" "{ type filter hook forward priority filter; policy accept; }"
	"$NFT_BIN" add chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_INPUT_NAME" "{ type filter hook input priority filter; policy accept; }"
}

flush_rules() {
	if "$NFT_BIN" list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
		"$NFT_BIN" flush chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING_NAME"
		"$NFT_BIN" flush chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME"
		"$NFT_BIN" flush chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_INPUT_NAME"
	fi
}

clear_all() {
	flush_state_conntrack
	if "$NFT_BIN" list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
		"$NFT_BIN" delete table "$TABLE_FAMILY" "$TABLE_NAME"
	fi
	rm -f "$STATE_DIR"/* 2>/dev/null || true
}

normalize_mac() {
	echo "$1" | tr '[:lower:]' '[:upper:]'
}

resolve_ipv4_from_mac() {
	local mac ip
	mac="$(normalize_mac "$1")"

	if [ -f "$LEASE_FILE" ]; then
		ip="$(awk -v target="$mac" 'toupper($2) == target { print $3; exit }' "$LEASE_FILE")"
		[ -n "$ip" ] && {
			echo "$ip"
			return 0
		}
	fi

	"$IP_BIN" neigh show 2>/dev/null | awk -v target="$mac" '
		toupper($0) ~ toupper(target) {
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
					print $i
					exit
				}
			}
		}
	'
}

resolve_ipv6_from_mac() {
	local mac
	mac="$(normalize_mac "$1")"

	"$IP_BIN" -6 neigh show 2>/dev/null | awk -v target="$mac" '
		toupper($0) ~ toupper(target) {
			addr = $1
			if (addr ~ /^fe80:/ || addr ~ /^ff/) {
				next
			}
			if (!(addr in seen)) {
				print addr
				seen[addr] = 1
			}
		}
	'
}

rate_to_nft_bytes() {
	local rate kbytes
	rate="${1:-0}"

	case "$rate" in
		''|*[!0-9]*)
			echo ""
			return 1
		;;
	esac

	[ "$rate" -le 0 ] && {
		echo ""
		return 1
	}

	kbytes=$(( (rate + 7) / 8 ))
	[ "$kbytes" -le 0 ] && kbytes=1
	echo "$kbytes kbytes/second"
}

is_weekday_match() {
	local rule_days current_day token
	rule_days="${1:-}"
	current_day="$(date +%u)"

	[ -z "$rule_days" ] && return 0

	for token in $rule_days; do
		[ "$token" = "$current_day" ] && return 0
	done

	return 1
}

is_time_match() {
	local start stop now
	start="${1:-00:00}"
	stop="${2:-23:59}"
	now="$(date +%H:%M)"

	if [ "$start" = "$stop" ]; then
		return 0
	fi

	if [ "$start" \< "$stop" ]; then
		[ "$now" \> "$start" ] || [ "$now" = "$start" ] || return 1
		[ "$now" \< "$stop" ] && return 0
		[ "$now" = "$stop" ] && return 1
		return 1
	fi

	[ "$now" \> "$start" ] || [ "$now" = "$start" ] && return 0
	[ "$now" \< "$stop" ] && return 0
	return 1
}

is_rule_active() {
	is_weekday_match "$1" || return 1
	is_time_match "$2" "$3"
}

trim_event_log() {
	[ -f "$EVENT_LOG_FILE" ] || return 0
	tail -n "$EVENT_LOG_MAX_LINES" "$EVENT_LOG_FILE" > "$EVENT_LOG_FILE.tmp" 2>/dev/null || return 0
	mv "$EVENT_LOG_FILE.tmp" "$EVENT_LOG_FILE"
}

sum_addr_stats() {
	local table_dump addr
	table_dump="$1"
	addr="$2"

	printf '%s\n' "$table_dump" | awk -v target="$addr" '
		index($0, target) > 0 {
			if (match($0, /packets [0-9]+/)) {
				p += substr($0, RSTART + 8, RLENGTH - 8) + 0
			}
			if (match($0, /bytes [0-9]+/)) {
				b += substr($0, RSTART + 6, RLENGTH - 6) + 0
			}
		}
		END {
			print (p + 0) " " (b + 0)
		}
	'
}

log_event_line() {
	local line
	line="$1"

	[ -n "$line" ] || return 0
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line" >> "$EVENT_LOG_FILE"
	trim_event_log
}

flush_conntrack_addr() {
	local family addr
	family="$1"
	addr="$2"

	[ -n "$CONNTRACK_BIN" ] || return 0
	[ -n "$addr" ] || return 0

	"$CONNTRACK_BIN" -D -f "$family" -s "$addr" >/dev/null 2>&1 || true
	"$CONNTRACK_BIN" -D -f "$family" -d "$addr" >/dev/null 2>&1 || true
}

flush_state_conntrack() {
	local file line

	[ -d "$STATE_DIR" ] || return 0

	for file in "$STATE_DIR"/*.ip; do
		[ -f "$file" ] || continue
		line="$(cat "$file" 2>/dev/null)"
		flush_conntrack_addr ipv4 "$line"
	done

	for file in "$STATE_DIR"/*.ip6; do
		[ -f "$file" ] || continue
		while IFS= read -r line; do
			flush_conntrack_addr ipv6 "$line"
		done < "$file"
	done
}

collect_event_logs() {
	local table_dump name_file section name mac mode ipv4 stats packets bytes ip6 first_ip addr

	[ "$EVENT_LOG_ENABLED" = "1" ] || return 0
	"$NFT_BIN" list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1 || return 0

	table_dump="$("$NFT_BIN" list table "$TABLE_FAMILY" "$TABLE_NAME" 2>/dev/null || true)"
	[ -n "$table_dump" ] || return 0

	for name_file in "$STATE_DIR"/*.name; do
		[ -f "$name_file" ] || continue

		section="${name_file##*/}"
		section="${section%.name}"
		name="$(cat "$STATE_DIR/$section.name" 2>/dev/null)"
		mac="$(cat "$STATE_DIR/$section.mac" 2>/dev/null)"
		mode="$(cat "$STATE_DIR/$section.mode" 2>/dev/null)"
		ipv4="$(cat "$STATE_DIR/$section.ip" 2>/dev/null)"
		packets=0
		bytes=0
		first_ip="$ipv4"

		if [ -n "$ipv4" ]; then
			stats="$(sum_addr_stats "$table_dump" "$ipv4")"
			packets=$((packets + ${stats%% *}))
			bytes=$((bytes + ${stats##* }))
		fi

		if [ -f "$STATE_DIR/$section.ip6" ]; then
			while IFS= read -r ip6; do
				[ -n "$ip6" ] || continue
				[ -n "$first_ip" ] || first_ip="$ip6"
				stats="$(sum_addr_stats "$table_dump" "$ip6")"
				packets=$((packets + ${stats%% *}))
				bytes=$((bytes + ${stats##* }))
			done < "$STATE_DIR/$section.ip6"
		fi

		[ "$packets" -gt 0 ] || [ "$bytes" -gt 0 ] || continue

		if [ "$mode" = "limit" ]; then
			log_event_line "设备【${name:-未命名设备}】（MAC：${mac:-未知}，地址：${first_ip:-未知}）流量超出限制，已处理 ${packets} 个数据包 / ${bytes} 字节。"
		else
			log_event_line "设备【${name:-未命名设备}】（MAC：${mac:-未知}，地址：${first_ip:-未知}）尝试上网，已拦截 ${packets} 个数据包 / ${bytes} 字节。"
		fi
	done
}

append_block_rule() {
	local ip name
	ip="$1"
	name="$2"

	"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING_NAME" ip saddr "$ip" counter drop
	"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip saddr "$ip" counter drop
	"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip daddr "$ip" counter drop
	"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_INPUT_NAME" ip saddr "$ip" meta l4proto { tcp, udp } counter drop
}

append_block_rule6() {
	local ip6 name
	ip6="$1"
	name="$2"

	"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING_NAME" ip6 saddr "$ip6" counter drop
	"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip6 saddr "$ip6" counter drop
	"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip6 daddr "$ip6" counter drop
	"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_INPUT_NAME" ip6 saddr "$ip6" meta l4proto { tcp, udp } counter drop
}

append_limit_rule() {
	local ip name up_rate down_rate
	ip="$1"
	name="$2"
	up_rate="$3"
	down_rate="$4"

	if [ -n "$up_rate" ]; then
		"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip saddr "$ip" limit rate over "$up_rate" counter drop
	fi

	if [ -n "$down_rate" ]; then
		"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip daddr "$ip" limit rate over "$down_rate" counter drop
	fi
}

append_limit_rule6() {
	local ip6 name up_rate down_rate
	ip6="$1"
	name="$2"
	up_rate="$3"
	down_rate="$4"

	if [ -n "$up_rate" ]; then
		"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip6 saddr "$ip6" limit rate over "$up_rate" counter drop
	fi

	if [ -n "$down_rate" ]; then
		"$NFT_BIN" add rule "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_NAME" ip6 daddr "$ip6" limit rate over "$down_rate" counter drop
	fi
}

handle_rule() {
	local section enabled name ip mac mode weekdays start_time stop_time up_kbit down_kbit resolved_ip resolved_ip6 ip6_list up_rate down_rate has_any
	section="$1"

	config_get enabled "$section" enabled "0"
	[ "$enabled" = "1" ] || return 0

	config_get name "$section" name "$section"
	config_get ip "$section" ip ""
	config_get mac "$section" mac ""
	config_get mode "$section" mode "block"
	config_get weekdays "$section" weekdays ""
	config_get start_time "$section" start_time "00:00"
	config_get stop_time "$section" stop_time "23:59"
	config_get up_kbit "$section" up_kbit "0"
	config_get down_kbit "$section" down_kbit "0"

	is_rule_active "$weekdays" "$start_time" "$stop_time" || return 0

	resolved_ip=""
	resolved_ip6=""
	ip6_list=""
	if [ -n "$mac" ]; then
		resolved_ip="$(resolve_ipv4_from_mac "$mac" || true)"
		[ -n "$resolved_ip" ] || resolved_ip="$ip"
		ip6_list="$(resolve_ipv6_from_mac "$mac" || true)"
		if [ -z "$resolved_ip" ] && [ -z "$ip6_list" ]; then
			log "skip rule [$name]: unable to resolve IP address from MAC $mac"
			return 0
		fi
	elif [ -n "$ip" ]; then
		resolved_ip="$ip"
	else
		log "skip rule [$name]: missing MAC address"
		return 0
	fi

	has_any=0

	if [ -n "$resolved_ip" ]; then
		echo "$resolved_ip" > "$STATE_DIR/$section.ip"
		has_any=1
	else
		rm -f "$STATE_DIR/$section.ip" 2>/dev/null || true
	fi

	if [ -n "$ip6_list" ]; then
		printf '%s\n' "$ip6_list" > "$STATE_DIR/$section.ip6"
		has_any=1
	else
		rm -f "$STATE_DIR/$section.ip6" 2>/dev/null || true
	fi

	[ "$has_any" -eq 1 ] || return 0
	printf '%s\n' "$name" > "$STATE_DIR/$section.name"
	printf '%s\n' "$(normalize_mac "$mac")" > "$STATE_DIR/$section.mac"
	printf '%s\n' "$mode" > "$STATE_DIR/$section.mode"

	case "$mode" in
		block)
			[ -n "$resolved_ip" ] && append_block_rule "$resolved_ip" "$name"
			for resolved_ip6 in $ip6_list; do
				append_block_rule6 "$resolved_ip6" "$name"
			done
		;;
		limit)
			up_rate="$(rate_to_nft_bytes "$up_kbit" || true)"
			down_rate="$(rate_to_nft_bytes "$down_kbit" || true)"
			if [ -z "$up_rate" ] && [ -z "$down_rate" ]; then
				log "skip rule [$name]: no valid rate configured"
				return 0
			fi
			[ -n "$resolved_ip" ] && append_limit_rule "$resolved_ip" "$name" "$up_rate" "$down_rate"
			for resolved_ip6 in $ip6_list; do
				append_limit_rule6 "$resolved_ip6" "$name" "$up_rate" "$down_rate"
			done
		;;
		*)
			log "skip rule [$name]: unsupported mode $mode"
		;;
	esac
}

apply_rules() {
	local enabled

	require_tools || return 1

	config_load "$CONFIG_NAME"
	config_get enabled globals enabled "1"
	config_get EVENT_LOG_ENABLED globals log_enabled "0"

	if [ "$enabled" != "1" ]; then
		clear_all
		return 0
	fi

	collect_event_logs
	ensure_table
	flush_rules
	rm -f "$STATE_DIR"/* 2>/dev/null || true
	config_foreach handle_rule rule
	flush_state_conntrack
}

run_apply() {
	local rc

	set +e
	apply_rules
	rc="$?"
	set -e

	if [ "$rc" -ne 0 ]; then
		log "apply failed with code $rc"
	fi

	return "$rc"
}

daemon_loop() {
	while true; do
		run_apply || true
		sleep 60
	done
}

case "${1:-apply}" in
	apply)
		run_apply
	;;
	clear)
		clear_all
	;;
	daemon)
		daemon_loop
	;;
	*)
		echo "Usage: $0 {apply|clear|daemon}" >&2
		exit 1
	;;
esac
