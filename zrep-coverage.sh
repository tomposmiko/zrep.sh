#!/bin/bash
# Read-only configuration coverage: live source instances versus zrep.conf and ZFS.

zrep_coverage_help() {
    cat <<'HELP'
Usage: zrep-coverage.sh [OPTIONS]
Compare live Incus/LXD inventories with replication configuration and destinations.
Stopped instances are included. No snapshots, replication or repairs are run.

  --config FILE          Default /etc/zrep/zrep.conf
  --hosts-file FILE      Independent source hosts, one hostname per line
  --host HOST            Additional source host (repeatable, e.g. v201.sg.svfx)
  --host-alias OLD=HOST  Explicit equivalent hostname (repeatable, one hop)
  --ignore-host HOST     Exclude a source host (repeatable)
  --ignore-instance NAME Exclude this instance name on all hosts (repeatable)
  --dataset DATASET      Destination root (default tank/zrep)
  --extended-vault      Check the zrep.sh -E host/instance layout
  --ssh EXECUTABLE      Default /usr/bin/ssh
  --zfs EXECUTABLE      Default /usr/sbin/zfs
  --verbose             Report successful coverage too
  -h, --help            Help without SSH or ZFS calls

Hosts in zrep.conf are also queried. Independent hosts detect whole missing
source configurations. Sources need the updated restricted gateway supporting
the read-only 'zrep inventory' request; Puppet is not required on a source.
Exit 0: covered; 1: findings; 2: audit could not run. Healthy runs are silent.
This verifies default-project root-disk configuration, not backup freshness,
custom volumes, snapshot contents or restores. Other projects/storage layouts
are reported as unsupported rather than silently counted as protected.
HELP
}

zrep_coverage_error() {
    printf 'ZREP COVERAGE ERROR: audit could not run\n- reason: %s\n' "$*" >&2
    return 2
}

zrep_coverage_host() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; }
zrep_coverage_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; }
zrep_coverage_dataset() { [[ $1 =~ ^[A-Za-z][A-Za-z0-9_.:-]*(/[A-Za-z0-9][A-Za-z0-9_.:-]*)*$ ]]; }

zrep_coverage_finding() {
    local -n report_findings=$1
    local block=$2 detail
    shift 2
    for detail in "$@"; do block+=$'\n- '"$detail"; done
    report_findings+=("$block")
}

zrep_coverage_main() {
    local config=/etc/zrep/zrep.conf hosts_file='' root=tank/zrep ssh=/usr/bin/ssh zfs=/usr/sbin/zfs extended=false verbose=false
    local option value old new host config_host guest kind line number=0 listing name actual_type extra json now rows platform project pool driver source expected_kind key vault label source_path checked=0 visited=0
    local -a host_values=() ignored_values=() findings=() components=() missing=()
    local -A aliases=() hosts=() ignored_hosts=() ignored_instances=() configured=() configured_vaults=() config_destinations=() present=() discovered=() connected=() destinations=()
    while (( $# )); do
        option=$1
        case $option in
            -h|--help) zrep_coverage_help; return 0 ;;
            --verbose) verbose=true; shift; continue ;;
            --extended-vault) extended=true; shift; continue ;;
            --config|--hosts-file|--host|--host-alias|--ignore-host|--ignore-instance|--dataset|--ssh|--zfs)
                if (( $# < 2 )) || [[ -z $2 ]]; then zrep_coverage_error "missing value for $option"; return 2; fi
                value=$2; shift 2 ;;
            *) zrep_coverage_error "unknown argument: $option (see --help)"; return 2 ;;
        esac
        case $option in
            --config) config=$value ;;
            --hosts-file) hosts_file=$value ;;
            --dataset) root=$value ;;
            --ssh) ssh=$value ;;
            --zfs) zfs=$value ;;
            --host|--ignore-host)
                if ! { zrep_coverage_host "$value"; }; then zrep_coverage_error "invalid hostname: $value"; return 2; fi
                if [[ $option == --host ]]; then host_values+=("${value,,}"); else ignored_values+=("${value,,}"); fi ;;
            --ignore-instance)
                if ! { zrep_coverage_name "$value"; }; then zrep_coverage_error "invalid instance name: $value"; return 2; fi
                ignored_instances[$value]=1 ;;
            --host-alias)
                old=${value%%=*}; new=${value#*=}; old=${old,,}; new=${new,,}
                if [[ $value != *=* || $old == "$new" ]] || ! { zrep_coverage_host "$old" && zrep_coverage_host "$new"; }; then zrep_coverage_error "invalid host alias: $value"; return 2; fi
                if [[ -n ${aliases[$old]+x} ]]; then zrep_coverage_error "duplicate host alias: $old"; return 2; fi
                aliases[$old]=$new ;;
        esac
    done
    for old in "${!aliases[@]}"; do
        new=${aliases[$old]}
        if [[ -n ${aliases[$new]+x} ]]; then zrep_coverage_error 'host aliases must point directly to canonical hosts'; return 2; fi
    done
    for host in "${ignored_values[@]}"; do ignored_hosts[${aliases[$host]:-$host}]=1; done
    if ! { zrep_coverage_dataset "$root"; }; then zrep_coverage_error 'invalid destination dataset'; return 2; fi
    if [[ ! -f $config || ! -r $config ]]; then zrep_coverage_error "cannot read replication configuration: $config"; return 2; fi
    if [[ -n $hosts_file ]]; then
        if [[ ! -f $hosts_file || ! -r $hosts_file ]]; then zrep_coverage_error "cannot read source host inventory: $hosts_file"; return 2; fi
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}
            [[ -z $line || $line == \#* ]] && continue
            if ! { zrep_coverage_host "$line"; }; then zrep_coverage_error "invalid source host in $hosts_file"; return 2; fi
            host_values+=("${line,,}")
        done < "$hosts_file"
        if (( ${#host_values[@]} == 0 )); then zrep_coverage_error "empty source host inventory: $hosts_file"; return 2; fi
    fi
    while IFS= read -r line || [[ -n $line ]]; do
        number=$((number + 1))
        line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}
        [[ -z $line || $line == \#* ]] && continue
        if [[ ! $line =~ ^([A-Za-z0-9][A-Za-z0-9.-]*):([A-Za-z0-9][A-Za-z0-9.-]*):(incus-ct|incus-kvm|lxd-ct|lxd-kvm)$ ]]; then
            zrep_coverage_finding findings "$config:$number: invalid replication configuration" "reason: expected host:instance:incus-ct|incus-kvm|lxd-ct|lxd-kvm"
            continue
        fi
        config_host=${BASH_REMATCH[1]}; host=${config_host,,}; guest=${BASH_REMATCH[2]}; kind=${BASH_REMATCH[3]}; host=${aliases[$host]:-$host}
        host_values+=("$host"); key=$host:$guest
        vault=$root/$guest
        if [[ $extended == true ]]; then vault=$root/$config_host/$guest; fi
        if [[ -n ${config_destinations[$vault]+x} ]]; then
            zrep_coverage_finding findings "$config:$number: destination collision" "configured source: $line" "conflicting source: ${config_destinations[$vault]}" "vault dataset: $vault"
        fi
        config_destinations[$vault]=$line
        if [[ -n ${configured[$key]+x} ]]; then
            zrep_coverage_finding findings "$config:$number: duplicate source configuration" "configured source: $line" "reason: multiple entries identify the same canonical host/instance"
        fi
        configured[$key]=$kind
        configured_vaults[$key]=$vault
    done < "$config"
    for host in "${host_values[@]}"; do hosts[${aliases[$host]:-$host}]=1; done
    if (( ${#hosts[@]} == 0 )); then zrep_coverage_error 'no source hosts to query; configure independent source hosts'; return 2; fi
    if ! { listing=$(timeout 60 "$zfs" list -H -r -t filesystem,volume -o name,type "$root"); }; then zrep_coverage_error 'cannot read destination ZFS inventory'; return 2; fi
    while IFS=$'\t' read -r name actual_type extra; do
        if ! { zrep_coverage_dataset "$name"; } || [[ ( $name != "$root" && $name != "$root/"* ) || -n ${present[$name]+x} || -n $extra || ( $actual_type != filesystem && $actual_type != volume ) ]]; then zrep_coverage_error 'unexpected destination ZFS inventory'; return 2; fi
        present[$name]=$actual_type
    done <<< "$listing"
    if [[ ${present[$root]:-} != filesystem ]]; then zrep_coverage_error 'destination root is not a ZFS filesystem'; return 2; fi
    # Stable report order makes the combined daily email/Slack report easier to scan.
    listing=$(printf '%s\n' "${!hosts[@]}" | LC_ALL=C sort)
    while IFS= read -r host; do
        [[ -n ${ignored_hosts[$host]+x} ]] && continue
        visited=$((visited + 1))
        if ! { json=$(timeout 60 "$ssh" -o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 -o StrictHostKeyChecking=yes -- "syncoid-backup@$host" 'zrep inventory' </dev/null 2>/dev/null); }; then
            zrep_coverage_finding findings "$host: source inventory unavailable" "reason: SSH or the read-only inventory request failed" "action: verify connectivity and install the updated source gateway"
            continue
        fi
        now=$(date +%s)
        if ! { jq -e --argjson now "$now" '
            def field: type == "string" and length > 0 and (test("[\\x00-\\x1f\\x7f]") | not);
            type == "object" and .version == 1 and
            (.generated_at | type == "number" and floor == . and . > 0 and . <= $now + 300 and $now - . <= 600) and
            (.platforms | type == "array" and length > 0 and all(. == "incus" or . == "lxd")) and
            (.instances | type == "array" and all(
                (.platform == "incus" or .platform == "lxd") and
                ([.project, .name, .type, .pool, .driver, .source] | all(field)))) and
            ([.instances[] | [.platform, .project, .name]] | length == (unique | length)) and
            ([.instances[].platform] - .platforms | length == 0)
        ' >/dev/null 2>&1 <<< "$json"; }; then
            zrep_coverage_finding findings "$host: invalid source inventory" "reason: malformed, duplicate or stale instance metadata" "action: install/check the updated source gateway"
            continue
        fi
        connected[$host]=1
        rows=$(jq -r '.instances | sort_by(.platform, .project, .name)[] | [.platform, .project, .name, .type, .pool, .driver, .source] | @tsv' <<< "$json")
        while IFS=$'\t' read -r platform project guest kind pool driver source; do
            [[ -n $platform ]] || continue
            [[ -n ${ignored_instances[$guest]+x} ]] && continue
            checked=$((checked + 1)); label=$host/$guest
            if [[ $project != default ]]; then
                zrep_coverage_finding findings "$host/$project/$guest: unsupported project" "reason: zrep.sh snapshots only the default project" "storage pool: $pool"
                continue
            fi
            if ! { zrep_coverage_name "$guest"; } || [[ $kind != container && $kind != virtual-machine ]]; then
                zrep_coverage_finding findings "$label: unsupported instance" "instance type: $kind" "reason: identity/type is unsupported by zrep.sh"
                continue
            fi
            if [[ $kind == container ]]; then expected_kind=$platform-ct; source_path=tank/$platform/containers/$guest
            else expected_kind=$platform-kvm; source_path=tank/$platform/virtual-machines/$guest; fi
            key=$host:$guest; discovered[$key]=$expected_kind
            vault=$root/$guest
            if [[ $extended == true ]]; then vault=$root/$host/$guest; fi
            vault=${configured_vaults[$key]:-$vault}
            if [[ -n ${destinations[$vault]+x} && ${destinations[$vault]} != "$key:$expected_kind" ]]; then
                zrep_coverage_finding findings "$label: destination collision" "server path: $host:$source_path" "vault dataset: $vault" "conflicting source: ${destinations[$vault]}"
            fi
            destinations[$vault]=$key:$expected_kind
            if [[ $driver != zfs || $source != "tank/$platform" ]]; then
                zrep_coverage_finding findings "$label: unsupported source storage" "storage pool: $pool" "storage driver: $driver" "pool source: $source" "required source root: tank/$platform"
            fi
            if [[ -z ${configured[$key]+x} ]]; then
                zrep_coverage_finding findings "$label: missing replication configuration" "server path: $host:$source_path" "config file: $config" "expected entry: $host:$guest:$expected_kind"
                continue
            elif [[ ${configured[$key]} != "$expected_kind" ]]; then
                zrep_coverage_finding findings "$label: incorrect replication type" "configured type: ${configured[$key]}" "expected type: $expected_kind" "config file: $config"
            fi
            components=("$vault:filesystem")
            if [[ $kind == virtual-machine ]]; then components+=("$vault/$guest:filesystem" "$vault/$guest.block:volume"); fi
            missing=()
            for value in "${components[@]}"; do
                name=${value%:*}; actual_type=${value##*:}
                if [[ ${present[$name]:-} != "$actual_type" ]]; then missing+=("expected dataset: $name ($actual_type); actual: ${present[$name]:-missing}"); fi
            done
            if (( ${#missing[@]} )); then
                zrep_coverage_finding findings "$label: missing or invalid backup dataset" "server path: $host:$source_path" "vault dataset: $vault" "${missing[@]}"
            fi
        done <<< "$rows"
    done <<< "$listing"
    for key in "${!configured[@]}"; do
        host=${key%%:*}; guest=${key#*:}
        [[ -n ${ignored_hosts[$host]+x} || -n ${ignored_instances[$guest]+x} || -z ${connected[$host]+x} ]] && continue
        if [[ -z ${discovered[$key]+x} ]]; then zrep_coverage_finding findings "$host/$guest: configured instance missing" "config file: $config" "configured type: ${configured[$key]}" "reason: no matching default-project instance in the live source inventory"; fi
    done
    if (( visited == 0 )); then zrep_coverage_finding findings 'source inventory: no hosts checked' 'reason: every source host was excluded'; fi
    if (( ${#findings[@]} )); then
        printf 'ZREP COVERAGE FAILED: %s problem(s), %s expected instance(s) checked\n' "${#findings[@]}" "$checked"
        printf '\n%s\n' "${findings[@]}"
        return 1
    fi
    if [[ $verbose == true ]]; then printf 'ZREP coverage OK: %s expected instance(s) configured across %s source host(s)\n' "$checked" "$visited"; fi
    return 0
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    zrep_coverage_main "$@"
fi
