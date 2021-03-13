#!/bin/bash

set -e
set -o pipefail

do_sudo() {
	local cmd_prefix='sudo'
	[ "$(whoami)" != "root" ] || cmd_prefix=''
	$cmd_prefix "$@"
}

gpu_apply() {
	local od_path='pp_od_clk_voltage'
	local opt OPTIND OPTARG
	while getopts ':f:' opt; do
		case ${opt} in
			f)
				od_path="$OPTARG"
				;;
			\?)
				echo "Unknown argument: -$OPTARG" >&2
				return 1
				;;
			:)
				echo "Invalid argument: -$OPTARG requires an argument" >&2
				return 1
				;;
		esac
	done
	shift $((OPTIND - 1))
	if [ ! -e "$od_path" ]; then
		printf 'Failed to find pp_od_clk_voltage at \033[1;36m%s\033[0m\n' "$od_path" >&2
		return 127
	fi
	if [ $# -lt 1 ]; then
		echo 'Usage: gpu_apply [-f /path/to/pp_od_clk_voltage] SETTING...' >&2
		return 1
	fi
	local setting
	for setting; do
		echo "$setting" | do_sudo tee "$od_path" 1> /dev/null
	done
	echo c | do_sudo tee "$od_path" 1> /dev/null
}

get_all_clocks() {
	local clock_name="$1"
	local state='wait'
	local line
	while read line; do
		case "$state" in
			"wait")
				[ $(echo "$line" | awk -F ':' "{ if (\$1 ~ /^$clock_name$/) { print \$0; } }" | wc -l) -ge 1 ] || continue
				state="read"
				;;
			"read")
				if [ $(echo "$line" | grep -E '^[0-9]+:' | wc -l) -lt 1 ]; then
					return 0
				fi
				echo "$line"
				;;
			*)
				printf 'Invalid state: %s\n' "$state" >&2
				return 1
				;;
		esac
	done
	[ "$state" == "read" ] || return 127
}

get_clock() {
	local od_path='pp_od_clk_voltage'
	local opt OPTIND OPTARG
	while getopts ':c:f:' opt; do
		case ${opt} in
			f)
				od_path="$OPTARG"
				;;
			\?)
				echo "Unknown argument: -$OPTARG" >&2
				return 1
				;;
			:)
				echo "Invalid argument: -$OPTARG requires an argument" >&2
				return 1
				;;
		esac
	done
	shift $((OPTIND - 1))
	if [ $# -lt 2 ]; then
		echo 'Usage: get_clock [-f /path/to/pp_od_clk_voltage] CLOCK_NAME INDEX' >&2
		return 1
	fi
	local clock_name="$1"
	local clock_index="$2"
	get_all_clocks "$clock_name" < "$od_path" \
		| awk "{ if (\$1 ~ /^$clock_index:$/) { print \$2; } }" \
		| grep -oE '[0-9]+'
}

filter_cards() {
	local p
	while read p; do
		local card_name="$(basename "$p")"
		[ $(echo "$card_name" | grep -E '^card[0-9]+$' | wc -l) -gt 0 ] || continue
		[ -e "$p/device/pp_od_clk_voltage" ] || continue
		echo "$p/device"
	done
}

log_info() {
	local pattern='[\033[0;32m%s\033[0m]:'
	[ -z "$1" ] || pattern="$pattern $1\\n"
	shift
	printf "$pattern" INFO "$@"
}

log_error() {
	local pattern='[\033[0;31m%s\03[0m]:'
	[ -z "$1" ] || pattern="$pattern $1\\n"
	shift
	printf "$pattern" ERROR "$@"
}

do_confirm() {
	local prompt="${1:-"continue [y/n]? "}"
	local line
	while echo -n "$prompt" && read line; do
		case "$line" in
			"y"|"Y")
				return 0
				;;
			"n"|"N")
				return 1
				;;
			*)
				continue
				;;
		esac
	done
	return 2
}

get_power_limit_file() {
	local device_path="${1:-.}"
	local hwmon_dirs=($(find "$device_path/hwmon" -mindepth 1 -maxdepth 1 -type d,l -name 'hwmon*'))
	local power_limit_file
	local hwmon_dir
	for hwmon_dir in "${hwmon_dirs[@]}"; do
		power_limit_file="$(find "$hwmon_dir" -mindepth 1 -maxdepth 1 -type f -name 'power1_cap' | tr -d '\n')"
		[ -z "$power_limit_file" ] || break
	done
	if [ -z "$power_limit_file" ] || [ ! -e "$power_limit_file" ]; then
		log_error 'failed to find power limit file in \033[1;36m%s\033[0m' "$device_path" >&2
		return 127
	fi
	echo -n "$power_limit_file"
}

get_power_limit() {
	local f="$(get_power_limit_file "$@")"
	local v="$(tr -d '\n' < "$f")"
	v=$((v / 1000000))
	printf '%d' $v
}

set_power_limit() {
	local device_path='.'
	local opt OPTIND OPTARG
	while getopts ':d:' opt; do
		case ${opt} in
			d)
				device_path="$OPTARG"
				;;
			\?)
				echo "Unknown argument: -$OPTARG" >&2
				return 1
				;;
			:)
				echo "Invalid argument: -$OPTARG requires an argument" >&2
				return 1
				;;
		esac
	done
	shift $((OPTIND - 1))
	if [ $# -lt 1 ] || [ $(echo "$1" | grep -E '^[0-9]+$' | wc -l) -lt 1 ]; then
		echo 'Usage: set_power_limit [-d DEVICE_PATH] POWER_LIMIT' >&2
		return 1
	fi
	local power_limit="$1"
	power_limit=$((power_limit * 1000000))
	local power_limit_file="$(get_power_limit_file "$device_path")"
	local original_power_limit="$(tr -d '\n' < "$power_limit_file")"
	original_power_limit=$((original_power_limit / 1000000))
	log_info 'original power limit: %d' $original_power_limit >&2
	log_info 'using power limit: %d (raw value: %d)' $((power_limit / 1000000)) $power_limit >&2
	if [ $should_confirm -ne 0 ]; then
		if ! do_confirm; then
			echo -e '[\033[0;32mINFO\033[0m: Skipping setting power limit due to user non-confirmation'
			return 0
		fi
	fi
	echo "$power_limit" | do_sudo tee "$power_limit_file" 1> /dev/null
}

print_flags() {
	while [ $# -ge 2 ]; do
		printf '\t%c - %s\n' $1 "$2"
		shift 2
	done
}

cards=($(find /sys/class/drm -mindepth 1 -maxdepth 1 -type d,l -name 'card*' | sort -u | filter_cards))

print_usage() {
	local invocation="${1:-amd-vr-clocks.sh}"
	printf 'Usage: %s [-d /path/to/device] [-i DEVICE_INDEX] [-v] [-y] [-p POWER_LIMIT_IN_WATTS] [-s SCALE_PERCENT] [-r] [-h]\n\n'
	echo 'Flags:'
	local device_path_help='device_path'
	if [ ${#cards[@]} -ge 1 ]; then
		device_path_help="$device_path_help (default: ${cards[0]})"
	fi
	local scale_help='percentage to scale sclk_max when deriving sclk_min'
	[ -z "$scale" ] || scale_help="$scale_help (default: $scale)"
	print_flags \
		d "$device_path_help" \
		i 'device index' \
		v 'increase output verbosity' \
		y 'do not ask for confirmation' \
		p 'power limit to set (default: none)' \
		s "$scale_help" \
		r 'reset clocks to original settings instead of setting VR mode' \
		h 'print this help text and exit'
}

verbosity=0
scale=85
should_confirm=1
reset_mode=0
while getopts ':d:i:s:vyp:rh' opt; do
	case ${opt} in
		d)
			device_path="$OPTARG"
			;;
		i)
			device_path="$(printf '/sys/class/drm/card%d/device' $OPTARG)"
			;;
		v)
			verbosity=$((verbosity + 1))
			;;
		y)
			should_confirm=0
			;;
		p)
			power_limit=$OPTARG
			;;
		r)
			reset_mode=1
			;;
		s)
			scale=$OPTARG
			;;
		h)
			print_usage
			exit $?
			;;
		\?)
			echo "Unknown argument: -$OPTARG" >&2
			exit 1
			;;
		:)
			echo "Invalid argument: -$OPTARG requires an argument" >&2
			exit 1
			;;
	esac
done
shift $((OPTIND - 1))

[ $verbosity -lt 3 ] || set -x

if [ -z "$device_path" ]; then
	if [ ${#cards[@]} -lt 1 ]; then
		echo 'Unable to find any cards, and no device path specified' >&2
		exit 1
	fi
	device_path="${cards[0]}"
fi

if [ $scale -lt 0 ] || [ $scale -gt 100 ]; then
	log_error 'Invalid scale: 0 < %d < 100\n' $scale >&2
	return 1
fi

[ $verbosity -lt 0 ] || log_info 'using device at path \033[1;36m%s\033[0m' "$device_path" >&2
pushd "$device_path" 1> /dev/null

if [ $reset_mode -ne 0 ]; then
	log_info 'device clocks will be reset to original state'
	if [ $should_confirm -ne 0 ] && ! do_confirm; then
		echo 'Exiting due to user non-confirmation'
		exit 0
	fi
	gpu_apply 'r'
else
	log_info 'using scale factor: %d%%' $scale >&2
	sclk_min="$(get_clock OD_SCLK 0)"
	sclk_max="$(get_clock OD_SCLK 1)"
	log_info 'original sclk_min: %d' $sclk_min >&2
	log_info 'original sclk_max: %d' $sclk_max >&2
	sclk_min=$((sclk_max * scale))
	sclk_min=$((sclk_min / 100))
	sclk_min="$(echo "$sclk_min" | grep -oE '[0-9]+' | tr -d '\n')"
	log_info 'new sclk_min: %d' $sclk_min >&2
	if [ $should_confirm -ne 0 ]; then
		if ! do_confirm; then
			echo 'Exiting due to user non-confirmation'
			exit 0
		fi
	fi
	gpu_apply "s 0 $sclk_min"
fi
[ -z "$power_limit" ] || set_power_limit "$power_limit"
cat pp_od_clk_voltage
printf 'final power_limit: %d\n' $(get_power_limit .)
