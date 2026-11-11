#!/bin/bash
# Incus snapshot retention: preview first; never delete instances or raw ZFS snapshots.

isr_help() {
    cat <<'HELP'
Usage: isr.sh [OPTIONS] (--instance NAME | --all-instances) [PATTERN ...]

Preview Incus-managed snapshots on the local server/member in one project.
PATTERN is a literal substring of the snapshot NAME, never the instance name.
With no patterns, a retention option is required and all snapshot names match,
including manual snapshots. No arguments exit before contacting Incus.

  -h, --help             Show help without contacting Incus
  -p, --project PROJECT  Project (default: default)
  -i, --instance NAME    One local container or VM (no remote: prefixes)
      --all-instances    All instances on the local server/cluster member
      --delete           Execute the displayed plan; default is preview
      --confirm SCOPE    Required for deletion, with an explicit --project
                         SCOPE is PROJECT/INSTANCE or 'PROJECT/*'
      --before DATE      Only snapshots strictly before DATE, using creation time
                         YYYY-MM-DD or YYYY-MM-DD HH:MM[:SS][Z|+HH:MM]
                         Local time unless a timezone is supplied
      --older-than AGE   Protect snapshots newer than AGE (7d, 12h, etc.)
                         Units: s, m, h, d, w; fixed elapsed time
      --keep-at-least N  Keep N newest MATCHING snapshots per instance (default 0)
                         Matching snapshots protected by age/date count too
      --max-delete N     Refuse plans over N snapshots (default 100)
      --incus PATH       Incus executable (default: incus)
  --                     End options

Examples:
  isr.sh --instance chief11 --older-than 14d --keep-at-least 5 zas-daily
  isr.sh --project default --all-instances --before 2026-01-01 --keep-at-least 10
  isr.sh --project default --instance chief11 --older-than 14d \
         --keep-at-least 5 zas-daily --delete --confirm default/chief11

Run locally as an Incus administrator. The restricted syncoid-backup account
cannot run this tool. All date/age/count protections apply together. Creation
times come from Incus, not dates embedded in snapshot names; cutoffs are exclusive.
Manual snapshots are included only when their names/policy match your selection.
Incus CLI aliases/remotes are isolated; --force-local selects the local socket.

The full inventory is validated before deletion and rechecked before every
delete. Stop concurrent snapshot, replication, retention and instance-migration
jobs: these checks cannot eliminate the race between a final read and deletion.
Only 'incus snapshot delete INSTANCE SNAPSHOT' is used, without force flags.
Failures stop the script; earlier deletions cannot be undone by this tool.
Verify required backups/replication bases before removing source snapshots.
HELP
}

isr_error() { printf 'Error: %s\n' "$*" >&2; return 1; }
isr_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; }

# Convert an Incus RFC3339 timestamp to nanoseconds without overflowing on
# malformed/future dates. NOW is captured before building the deletion plan.
isr_timestamp() {
    local value=$1 parsed seconds fraction
    [[ $value =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$ ]] || { isr_error "Invalid snapshot creation timestamp: $value"; return 1; }
    if ! { parsed=$(date -d "$value" '+%s %N'); }; then isr_error "Invalid snapshot creation date: $value"; return 1; fi
    read -r seconds fraction <<< "$parsed"
    [[ $seconds =~ ^[0-9]{1,12}$ && $fraction =~ ^[0-9]{9}$ ]] || { isr_error "Unsupported snapshot creation time: $value"; return 1; }
    seconds=$((10#$seconds)); fraction=$((10#$fraction))
    (( seconds <= now_seconds )) || { isr_error "Future snapshot creation time: $value"; return 1; }
    parsed=$((seconds * 1000000000 + fraction))
    (( parsed <= now_ns )) || { isr_error "Future snapshot creation time: $value"; return 1; }
    printf '%s\n' "$parsed"
}

# Helpers use the main function's local client/scope/clock, never user shell text.
isr_instances() {
    local -n result_rows=$1
    local info json rows
    # The server identity is global; Incus rejects --project with raw query.
    if ! { info=$("$incus" --force-local query /1.0); }; then isr_error 'Cannot query the local Incus server'; return 1; fi
    if ! { jq -e '.environment | type == "object" and (.server_clustered | type == "boolean") and (.server_name | type == "string" and length > 0)' >/dev/null <<< "$info"; }; then isr_error 'Invalid local Incus server identity'; return 1; fi
    server_state=$(jq -c '.environment | [.server_name, .server_clustered]' <<< "$info")
    if ! { json=$("${client[@]}" list --format=json); }; then isr_error "Cannot list instances in project $project"; return 1; fi
    if ! { jq -e --arg project "$project" --argjson server "$info" '
        type == "array" and all(
            (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*$")) and
            (.type == "container" or .type == "virtual-machine") and
            (.created_at | type == "string" and length > 0 and (test("[\\x00-\\x1f\\x7f]") | not)) and
            ((.project // $project) == $project) and
            (if $server.environment.server_clustered then (.location | type == "string" and length > 0) else true end)) and
        (length == (unique_by(.name) | length))
    ' >/dev/null <<< "$json"; }; then isr_error 'Invalid, duplicate or out-of-project instance inventory'; return 1; fi
    rows=$(jq -r --arg instance "$instance" --argjson server "$info" '
        [.[] | select((($server.environment.server_clustered | not) or .location == $server.environment.server_name) and ($instance == "" or .name == $instance))] |
        sort_by(.name)[] | [.name, .type, .created_at, (.location // "")] | @tsv
    ' <<< "$json")
    if [[ -n $instance && -z $rows ]]; then isr_error "Instance $instance is absent from the local member/project"; return 1; fi
    # Output through the caller's nameref.
    # shellcheck disable=SC2034
    result_rows=$rows
}

isr_snapshots() {
    local owner=$1
    local -n result_snapshots=$2
    local json rows name created ns
    local -a normalized=()
    if ! { json=$("${client[@]}" snapshot list "$owner" --format=json); }; then isr_error "Cannot list snapshots for $owner"; return 1; fi
    if ! { jq -e 'type == "array" and all(
        (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_.:-]*$")) and
        (.created_at | type == "string" and (test("[\\x00-\\x1f\\x7f]") | not))) and
        (length == (unique_by(.name) | length))' >/dev/null <<< "$json"; }; then isr_error "Invalid snapshot inventory for $owner"; return 1; fi
    rows=$(jq -r 'sort_by(.name)[] | [.name, .created_at] | @tsv' <<< "$json")
    while IFS=$'\t' read -r name created; do
        [[ -n $name ]] || continue
        if ! { ns=$(isr_timestamp "$created"); }; then return 1; fi
        normalized+=("$name"$'\t'"$ns"$'\t'"$created")
    done <<< "$rows"
    # Output through the caller's nameref.
    # shellcheck disable=SC2034
    result_snapshots=$(printf '%s\n' "${normalized[@]}")
}

isr_main() {
    local project=default project_explicit=false instance='' all_instances=false delete=false confirm='' incus=incus
    local before='' older_than='' keep=0 max_delete=100 retention=false option value scope
    local now_seconds fraction now_ns cutoff_ns seconds amount multiplier age_cutoff parsed
    local server_state initial_server instances current_instances owner row snapshot ns created matched key rank ranked current removed=0 work cleanup
    local -a patterns=() client=() candidates=() plan=() remaining=()
    local -A baselines=() created_at=() ranks=() affected=()
    while (( $# )); do
        option=$1
        case $option in
            -h|--help) isr_help; return 0 ;;
            --delete) delete=true; shift; continue ;;
            --all-instances) all_instances=true; shift; continue ;;
            -p|--project|-i|--instance|--confirm|--before|--older-than|--keep-at-least|--max-delete|--incus)
                if (( $# < 2 )) || [[ -z $2 ]]; then isr_error "Missing value for $option"; return 1; fi
                value=$2; shift 2 ;;
            --) shift; patterns+=("$@"); break ;;
            -*) isr_error "Unknown option: $option (use --help)"; return 1 ;;
            *) patterns+=("$1"); shift; continue ;;
        esac
        case $option in
            -p|--project) project=$value; project_explicit=true ;;
            -i|--instance)
                if [[ -n $instance ]]; then isr_error 'Specify only one --instance'; return 1; fi
                instance=$value ;;
            --confirm) confirm=$value ;;
            --before) before=$value; retention=true ;;
            --older-than) older_than=$value; retention=true ;;
            --keep-at-least) keep=$value; retention=true ;;
            --max-delete) max_delete=$value ;;
            --incus) incus=$value ;;
        esac
    done
    if [[ ( -z $instance && $all_instances == false ) || ( -n $instance && $all_instances == true ) ]]; then isr_help >&2; isr_error 'Specify either --instance NAME or --all-instances'; return 1; fi
    if (( ${#patterns[@]} == 0 )) && [[ $retention == false ]]; then isr_error 'Specify a literal snapshot-name pattern or a retention option'; return 1; fi
    if ! { isr_name "$project"; } || { [[ -n $instance ]] && ! isr_name "$instance"; }; then isr_error 'Invalid project/instance name; remote prefixes and paths are not accepted'; return 1; fi
    for value in "${patterns[@]}"; do
        [[ ${#value} -ge 3 && $value =~ ^[A-Za-z0-9_.:-]+$ && $value =~ [A-Za-z0-9] ]] || { isr_error "Unsafe literal pattern: $value"; return 1; }
    done
    scope=$project/${instance:-*}
    if [[ $delete == true ]]; then
        if [[ $project_explicit == false || $confirm != "$scope" ]]; then isr_error "Deletion requires --project $project and --confirm '$scope'"; return 1; fi
    elif [[ -n $confirm ]]; then isr_error '--confirm requires --delete'; return 1; fi
    [[ $keep =~ ^[0-9]{1,7}$ && $max_delete =~ ^[0-9]{1,7}$ ]] || { isr_error 'Invalid count/delete limit'; return 1; }
    keep=$((10#$keep)); max_delete=$((10#$max_delete))
    (( keep <= 1000000 && max_delete >= 1 && max_delete <= 1000000 )) || { isr_error 'Counts must be at most 1000000; --max-delete must be positive'; return 1; }
    if ! { parsed=$(date '+%s %N'); }; then return 1; fi
    read -r now_seconds fraction <<< "$parsed"
    now_ns=$((now_seconds * 1000000000 + 10#$fraction)); cutoff_ns=$now_ns
    if [[ -n $before ]]; then
        [[ $before =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([T\ ][0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:[0-9]{2})?)?$ ]] || { isr_error 'Invalid --before date format'; return 1; }
        if ! { seconds=$(date -d "$before" +%s); }; then isr_error 'Invalid --before date'; return 1; fi
        (( seconds >= 0 && seconds <= now_seconds )) || { isr_error '--before must be between the Unix epoch and now'; return 1; }
        cutoff_ns=$((seconds * 1000000000))
    fi
    if [[ -n $older_than ]]; then
        [[ $older_than =~ ^([0-9]{1,7})([smhdw])$ ]] || { isr_error 'Invalid --older-than age (use 7d or 12h)'; return 1; }
        amount=$((10#${BASH_REMATCH[1]})); value=${BASH_REMATCH[2]}
        (( amount > 0 )) || { isr_error '--older-than must be positive'; return 1; }
        case $value in s) multiplier=1;; m) multiplier=60;; h) multiplier=3600;; d) multiplier=86400;; w) multiplier=604800;; esac
        seconds=$((now_seconds - amount * multiplier))
        (( seconds >= 0 )) || { isr_error '--older-than extends before the Unix epoch'; return 1; }
        age_cutoff=$((seconds * 1000000000 + 10#$fraction))
        if (( age_cutoff < cutoff_ns )); then cutoff_ns=$age_cutoff; fi
    fi
    # Alias expansion happens before Incus handles --force-local. An isolated
    # client config prevents user/global aliases from rewriting our commands.
    if ! { work=$(mktemp -d); }; then return 1; fi
    printf -v cleanup 'rm -rf -- %q' "$work"
    # Capture the safely quoted path before this function's locals go away.
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    local -x INCUS_CONF="$work/config" INCUS_GLOBAL_CONF="$work/global" INCUS_CACHE="$work/cache"
    mkdir "$INCUS_CONF" "$INCUS_GLOBAL_CONF" "$INCUS_CACHE"
    client=("$incus" --force-local --project "$project")
    if ! { isr_instances instances; }; then return 1; fi
    initial_server=$server_state
    while IFS=$'\t' read -r owner row; do
        [[ -n $owner ]] || continue
        if ! { isr_snapshots "$owner" current; }; then return 1; fi
        baselines[$owner]=$current
        while IFS=$'\t' read -r snapshot ns created; do
            [[ -n $snapshot ]] || continue
            key=$owner/$snapshot; created_at[$key]=$created
            matched=false
            if (( ${#patterns[@]} == 0 )); then matched=true; fi
            for value in "${patterns[@]}"; do [[ $snapshot != *"$value"* ]] || matched=true; done
            if [[ $matched == true ]]; then candidates+=("$owner"$'\t'"$snapshot"$'\t'"$ns"); fi
        done <<< "$current"
    done <<< "$instances"
    ranked=$(printf '%s\n' "${candidates[@]}" | LC_ALL=C sort -t $'\t' -k3,3nr -k1,1 -k2,2)
    while IFS=$'\t' read -r owner snapshot ns; do
        [[ -n $owner ]] || continue
        rank=$((${ranks[$owner]:-0} + 1)); ranks[$owner]=$rank
        if (( rank > keep )) && { [[ $retention == false ]] || (( ns < cutoff_ns )); }; then
            plan+=("$owner/$snapshot"); affected[$owner]=1
        fi
    done <<< "$ranked"
    printf 'Server: %s\nScope: %s (local member only)\nSelected snapshots: %s\n' "$(jq -r '.[0]' <<< "$initial_server")" "$scope" "${#plan[@]}"
    printf 'Keep newest matching snapshots per instance: %s\n' "$keep"
    if [[ $retention == true ]]; then printf 'Creation cutoff (exclusive epoch seconds): %s.%09d\n' "$((cutoff_ns / 1000000000))" "$((cutoff_ns % 1000000000))"; fi
    if (( ${#plan[@]} )); then
        for key in "${plan[@]}"; do printf '  %s  (created %s)\n' "$key" "${created_at[$key]}"; done
    fi
    (( ${#plan[@]} <= max_delete )) || { isr_error "Plan exceeds --max-delete $max_delete; narrow selection or explicitly raise the limit"; return 1; }
    if (( ${#plan[@]} == 0 )); then printf 'No matching snapshots.\n'; return 0; fi
    if [[ $delete == false ]]; then
        printf "DRY RUN: nothing deleted. To execute, add --project %s --delete --confirm '%s'\n" "$project" "$scope"
        return 0
    fi
    # Validate all affected instances before the first delete, avoiding partial
    # deletion when a later instance's inventory already changed or is unreadable.
    if ! { isr_instances current_instances; }; then return 1; fi
    [[ $server_state == "$initial_server" && $current_instances == "$instances" ]] || { isr_error 'Instance/server inventory changed; preview again'; return 1; }
    for owner in "${!affected[@]}"; do
        if ! { isr_snapshots "$owner" current; }; then return 1; fi
        [[ $current == "${baselines[$owner]}" ]] || { isr_error "Snapshot inventory changed for $owner; preview again"; return 1; }
    done
    for key in "${plan[@]}"; do
        owner=${key%%/*}; snapshot=${key#*/}
        if ! { isr_instances current_instances; }; then return 1; fi
        [[ $server_state == "$initial_server" && $current_instances == "$instances" ]] || { isr_error 'Instance/server inventory changed; stopping'; return 1; }
        if ! { isr_snapshots "$owner" current; }; then return 1; fi
        [[ $current == "${baselines[$owner]}" ]] || { isr_error "Snapshot inventory changed for $owner; stopping"; return 1; }
        printf 'Deleting %s/%s\n' "$project" "$key"
        if ! { "${client[@]}" snapshot delete "$owner" "$snapshot"; }; then isr_error "Snapshot deletion failed for $key; stopping"; return 1; fi
        removed=$((removed + 1)); remaining=()
        while IFS= read -r row; do
            [[ -z $row || ${row%%$'\t'*} == "$snapshot" ]] || remaining+=("$row")
        done <<< "${baselines[$owner]}"
        baselines[$owner]=$(printf '%s\n' "${remaining[@]}")
    done
    printf 'Deleted %s snapshot(s).\n' "$removed"
    return 0
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    isr_main "$@"
fi
