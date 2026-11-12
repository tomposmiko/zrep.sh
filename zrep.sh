#!/bin/bash
# shellcheck disable=SC1091
# Resolve installed symlinks before finding the adjacent helpers and child job.
# Enable strict mode before loading helpers so a missing file cannot run a job.
set -euo pipefail
SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname -- "$SCRIPT_PATH")
. "$SCRIPT_DIR/_zrep_common.sh"

HOST_IN_PATH=0
LIST_SNAPSHOTS=false
PARAM_SOURCE=""
QUIET=false
DEBUG=false
SOURCE_SET=false

f_usage() {
    echo "Usage: $0 (-s|--source SOURCE | -l|--list SOURCE) [-c|--conf FILE]"
    echo "       [-f|--freq hourly|daily|weekly|monthly] [-b|--bwlimit LIMIT]"
    echo "       [-E|--extended-vault] [-q|--quiet | --debug]"
    exit 1
}

while (($#)); do
    case "$1" in
        -c|--conf|-s|--source|-l|--list|-f|--freq|-b|--bwlimit)
            (($# >= 2)) || fc_say_fail "Missing argument for '$1'"
            fc_check_arg "$2" "$1"
            case "$1" in
                -c|--conf) FILE_CONFIG="$2" ;;
                -f|--freq) FREQ="$2" ;;
                -b|--bwlimit) ARGS_SYNCOID+=("--target-bwlimit=$2") ;;
                *)
                    [[ "$SOURCE_SET" == false ]] || fc_say_fail "Specify exactly one source or list option"
                    SOURCE_SET=true
                    PARAM_SOURCE="$2"
                    [[ "$1" != -l && "$1" != --list ]] || LIST_SNAPSHOTS=true
                    ;;
            esac
            shift 2 ;;
        -E|--extended-vault) HOST_IN_PATH=1; shift ;;
        -q|--quiet) QUIET=true; ARGS_SYNCOID+=(--quiet); shift ;;
        --debug) DEBUG=true; ARGS_SYNCOID+=(--debug); shift ;;
        *) f_usage ;;
    esac
done
[[ "$SOURCE_SET" == true ]] || f_usage
[[ "$QUIET" == false || "$DEBUG" == false ]] || fc_say_fail "Quiet and debug are mutually exclusive"
f_validate_freq
f_read_sources

matches=()
for source_line in "${SOURCES[@]}"; do
    IFS=: read -r _ guest _ <<< "$source_line"
    if [[ "$PARAM_SOURCE" == "$source_line" || "$PARAM_SOURCE" == "$guest" ]]; then
        matches+=("$source_line")
    fi
done
((${#matches[@]} == 1)) || fc_say_fail "Exactly one source must match '$PARAM_SOURCE'; found ${#matches[@]}"
IFS=: read -r SOURCE_HOST VM_NAME VIRT_TYPE <<< "${matches[0]}"
[[ "$(zfs get type -H -o value "$DATASET_ZREP")" == filesystem ]] || fc_say_fail "Missing root dataset: '$DATASET_ZREP'"
if ((HOST_IN_PATH)); then
    DATASET_ZREP="$DATASET_ZREP/$SOURCE_HOST"
    # Listing must remain read-only.
    if [[ "$LIST_SNAPSHOTS" == false ]] && ! zfs list -H -o name "$DATASET_ZREP" >/dev/null 2>&1; then
        zfs create "$DATASET_ZREP"
    fi
fi
if [[ "$LIST_SNAPSHOTS" == true ]]; then
    zfs list -t all -r "$DATASET_ZREP/$VM_NAME"
    exit 0
fi

f_existing_source_snapshot() {
    local source_dataset=$1 rows name property value
    if ! rows=$(ssh -o BatchMode=yes "syncoid-backup@$SOURCE_HOST" \
        sudo zfs get -Hpd 1 -t snapshot guid,creation "$source_dataset" </dev/null); then
        return 1
    fi
    while IFS=$'\t' read -r name property value _; do
        if [[ "$name" == "$source_dataset@snapshot-$SNAPSHOT_NAME" && "$property" == guid && "$value" =~ ^[0-9]+$ ]]; then
            return 0
        fi
    done <<< "$rows"
    return 1
}

# Compare identity, not names: migration can recreate identically named snapshots.
f_snapshot_guids() {
    local source_dataset=$1 rows=$2 name property value origin extra
    local -A snapshots=() guids=()
    while IFS=$'\t' read -r name property value origin extra; do
        [[ -n "$name" ]] || continue
        [[ "$name" == "$source_dataset@"?* && "$property" =~ ^(guid|creation)$ &&
           "$value" =~ ^[0-9]+$ && "$origin" == - && -z "$extra" ]] || return 1
        snapshots[$name]=1
        if [[ "$property" == guid ]]; then
            guids[$name]=1
            printf '%s\n' "$value"
        fi
    done <<< "$rows"
    for name in "${!snapshots[@]}"; do
        [[ -n ${guids[$name]:-} ]] || return 1
    done
    return 0
}

f_diagnose_replication_failure() {
    local source_dataset=$1 target_dataset=$2 source_rows target_rows source_guids target_guids guid
    local -A source_ids=()
    printf 'Replication failed: %s/%s\n- source dataset: %s:%s\n- backup dataset: %s\n' \
        "$SOURCE_HOST" "$VM_NAME" "$SOURCE_HOST" "$source_dataset" "$target_dataset" >&2
    if ! source_rows=$(ssh -o BatchMode=yes "syncoid-backup@$SOURCE_HOST" \
        sudo zfs get -Hpd 1 -t snapshot guid,creation "$source_dataset" </dev/null); then
        printf '%s\n' '- common snapshot check: unavailable (source snapshot query failed)' >&2
        return
    fi
    if ! target_rows=$(zfs get -Hpd 1 -t snapshot guid,creation "$target_dataset"); then
        printf '%s\n' '- common snapshot check: unavailable (backup snapshot query failed)' >&2
        return
    fi
    if ! source_guids=$(f_snapshot_guids "$source_dataset" "$source_rows") ||
       ! target_guids=$(f_snapshot_guids "$target_dataset" "$target_rows"); then
        printf '%s\n' '- common snapshot check: unavailable (invalid snapshot metadata)' >&2
        return
    fi
    while IFS= read -r guid; do
        [[ -z "$guid" ]] || source_ids[$guid]=1
    done <<< "$source_guids"
    while IFS= read -r guid; do
        if [[ -n "$guid" && -n ${source_ids[$guid]:-} ]]; then
            printf '%s\n' '- common snapshots: found matching GUIDs; see the syncoid error above' >&2
            return
        fi
    done <<< "$target_guids"
    printf '%s\n' '- common snapshots: none (no matching snapshot GUIDs)' \
        '- incremental base: no shared snapshot; source bookmarks were not checked' >&2
}

f_replicate() {
    local source_dataset=$1 target_dataset=$2 status
    if syncoid -r "${SSH_OPTS[@]}" "${ARGS_SYNCOID[@]}" "syncoid-backup@$SOURCE_HOST:$source_dataset" "$target_dataset"; then
        return 0
    else
        status=$?
    fi
    # Diagnostic failures must not replace syncoid's original failure status.
    f_diagnose_replication_failure "$source_dataset" "$target_dataset" || true
    return "$status"
}

DATE=$(date +%Y-%m-%d--%H)
SNAPSHOT_NAME="zas-$FREQ-$DATE"
platform=${VIRT_TYPE%-*}
snapshot_command=(incus snapshot create)
[[ "$platform" != lxd ]] || snapshot_command=(lxc snapshot)
if ! ssh -o BatchMode=yes "syncoid-backup@$SOURCE_HOST" "${snapshot_command[@]}" "$VM_NAME" "$SNAPSHOT_NAME" </dev/null; then
    source_datasets=("tank/$platform/containers/$VM_NAME")
    if [[ "$VIRT_TYPE" == *-kvm ]]; then
        source_datasets=("tank/$platform/virtual-machines/$VM_NAME" "tank/$platform/virtual-machines/$VM_NAME.block")
    fi
    for source_dataset in "${source_datasets[@]}"; do
        f_existing_source_snapshot "$source_dataset" || \
            fc_say_fail "Snapshot creation failed and existing snapshot could not be verified: '$source_dataset@snapshot-$SNAPSHOT_NAME'"
    done
    printf 'Warning: snapshot creation failed; verified existing %s on all source datasets, continuing replication.\n' "$SNAPSHOT_NAME" >&2
fi
case "$VIRT_TYPE" in
    *-ct)
        f_replicate "tank/$platform/containers/$VM_NAME" "$DATASET_ZREP/$VM_NAME"
        ;;
    *-kvm)
        if ! zfs list -H -o name "$DATASET_ZREP/$VM_NAME" >/dev/null 2>&1; then
            zfs create "$DATASET_ZREP/$VM_NAME"
        fi
        for suffix in '' .block; do
            f_replicate "tank/$platform/virtual-machines/$VM_NAME$suffix" "$DATASET_ZREP/$VM_NAME/$VM_NAME$suffix"
        done
        ;;
esac
