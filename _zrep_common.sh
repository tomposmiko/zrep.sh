#!/bin/bash
# shellcheck disable=SC1091,SC2034
. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

ARGS_SYNCOID=()
DATASET_ZREP="tank/zrep"
DIR_CONFIG="/etc/zrep"
FILE_CONFIG="$DIR_CONFIG/zrep.conf"
FREQ="daily"
SSH_OPTS=()

f_validate_config_path() {
    [[ -f "$FILE_CONFIG" && -r "$FILE_CONFIG" ]] || fc_say_fail "Cannot read config: '$FILE_CONFIG'"
}

f_validate_freq() {
    [[ "$FREQ" =~ ^(hourly|daily|weekly|monthly)$ ]] || fc_say_fail "Invalid frequency: '$FREQ'"
}

# Parse the whole inventory before running any commands. Reject collisions in
# the default guest-only destination layout, even when selecting one source.
f_read_sources() {
    f_validate_config_path
    SOURCES=()
    local line host guest kind extra
    local -A seen=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        IFS=: read -r host guest kind extra <<< "$line"
        [[ "$line" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*:[A-Za-z0-9][A-Za-z0-9.-]*:(incus-ct|incus-kvm|lxd-ct|lxd-kvm)$ ]] || fc_say_fail "Invalid source: '$line'"
        local key="$guest"
        [[ "${HOST_IN_PATH:-0}" == 1 ]] && key="$host/$guest"
        [[ ! -v "seen[$key]" ]] || fc_say_fail "Duplicate destination: '$key'"
        seen[$key]=1
        SOURCES+=("$line")
    done < "$FILE_CONFIG"
    ((${#SOURCES[@]})) || fc_say_fail "No sources configured"
}
