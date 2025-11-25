#!/bin/bash

set -e

. "$(dirname "$(readlink /proc/$$/fd/255 2>/dev/null)")/_common.sh"

. "$(dirname "$(readlink /proc/$$/fd/255 2>/dev/null)")/_zrep_common.sh"

DATE=$(date +"%Y-%m-%d--%H")
HOST_IN_PATH=0
LIST_SNAPSHOTS="false"

f_list_snapshots() {
    if [ "$LIST_SNAPSHOTS" == "true" ]; then
        zfs list -t all -r "${DATASET_ZREP}/${VM_NAME}"

        exit $?
    fi
}

f_process_args() {
    # Exit if no arguments
    (( $# )) || f_usage

    local param

    while [ "$#" -gt "0" ]; do
        case "$1" in
            -c|--conf)
                param=$2
                fc_check_arg "$param" "config file"
                FILE_CONFIG="$param"
                shift 2
                ;;

            -s|--source)
                param="$2"
                fc_check_arg "$param" "source definition"
                PARAM_SOURCE="$param"
                shift 2
                ;;

            -f|--freq)
                param="$2"
                fc_check_arg "$param" "frequency"
                FREQ="$param"
                shift 2
                ;;

            -b|--bwlimit)
                param="$2"
                fc_check_arg "$param" "bandwidth limit"
                ARGS_SYNCOID+=("--target-bwlimit=${param}")
                shift 2
                ;;

            -E|--extended-vault)
                HOST_IN_PATH=1
                shift 1
                ;;

            -l|--list)
                param="$2"
                fc_check_arg "$param" "source definition"
                PARAM_SOURCE="$param"
                LIST_SNAPSHOTS="true"
                shift 2
                ;;

            -q|--quiet)
                ARGS_SYNCOID+=("--quiet")
                shift 1
                ;;

            --debug)
                ARGS_SYNCOID+=("--debug")
                shift 1
                ;;

            *)
                f_usage
                ;;
        esac
    done
}

f_process_source_line() {
    local IFS

    IFS=":"

    # shellcheck disable=SC2086
    set $FULL_SOURCE_LINE

    SOURCE_HOST="$1"
    VM_NAME="$2"
    VIRT_TYPE="$3"
}

f_create_snapshot() {
    case "$VIRT_TYPE" in
        lxd-*)
            ssh -o BatchMode=yes "syncoid-backup@${SOURCE_HOST}" lxc snapshot "$VM_NAME" zas-"${FREQ}-${DATE}" || true
        ;;

        incus-*)
            ssh -o BatchMode=yes "syncoid-backup@${SOURCE_HOST}" incus snapshot create "$VM_NAME" zas-"${FREQ}-${DATE}" < /dev/null || true
        ;;

        *)
            fc_say_fail "Unknown virtualization type: '$VIRT_TYPE'"

            exit 1
        ;;
    esac
}

f_pull_snapshot_ct() {
    syncoid -r "${SSH_OPTS[@]}" "${ARGS_SYNCOID[@]}" "syncoid-backup@${SOURCE_HOST}:${REMOTE_ZFS_PATH}/${VM_NAME}" "${DATASET_ZREP}/${VM_NAME}"
}

f_pull_snapshot_incus_kvm() {
    if ( ! zfs list -Hpo written "${DATASET_ZREP}/${VM_NAME}" &> /dev/null ); then
        zfs create "${DATASET_ZREP}/${VM_NAME}"
    fi

    syncoid -r "${SSH_OPTS[@]}" "${ARGS_SYNCOID[@]}" "syncoid-backup@${SOURCE_HOST}:${REMOTE_ZFS_PATH}/${VM_NAME}" "${DATASET_ZREP}/${VM_NAME}/${VM_NAME}"

    syncoid -r "${SSH_OPTS[@]}" "${ARGS_SYNCOID[@]}" "syncoid-backup@${SOURCE_HOST}:${REMOTE_ZFS_PATH}/${VM_NAME}.block" "${DATASET_ZREP}/${VM_NAME}/${VM_NAME}.block"
}

f_pull_snapshots() {
    case "$VIRT_TYPE" in
        lxd-*|incus-ct)
            f_pull_snapshot_ct
        ;;

        incus-kvm)
            f_pull_snapshot_incus_kvm
        ;;

        *)
            echo "Unknown virtualization type: '$VIRT_TYPE'"

            exit 1
        ;;
    esac
}

f_set_hostname_in_path() {
    if [ "$HOST_IN_PATH" -eq 1 ]; then
        DATASET_ZREP="${DATASET_ZREP}/${SOURCE_HOST}"

        local dataset_type

        dataset_type=$( zfs get type -H -o value "$DATASET_ZREP" 2> /dev/null || true )

        if [ ! "$dataset_type" == "filesystem" ];
        then
            fc_say_info "Creating destination path: ${DATASET_ZREP}"

            if ( ! zfs create "${DATASET_ZREP}" ); then
                fc_say_fail "Cannot create path: ${DATASET_ZREP}!"
            fi
        fi
    fi
}

f_set_remote_zfs_path() {
    case "$VIRT_TYPE" in
        lxd-ct)
            REMOTE_ZFS_PATH="lxd/containers"
        ;;

        incus-ct)
            REMOTE_ZFS_PATH="incus/containers"
        ;;

        incus-kvm)
            REMOTE_ZFS_PATH="incus/virtual-machines"
        ;;

        lxd-kvm)
            REMOTE_ZFS_PATH="lxd/virtual-machines"
        ;;

        *)
            say "Unknown VIRT_TYPE: ${VIRT_TYPE}"

            exit 1
        ;;
    esac

    export REMOTE_ZFS_PATH="tank/${REMOTE_ZFS_PATH}"
}

f_usage() {
    echo "Usage:"
    echo "    $0 -s <source> [-c <config file>] [--bwlimit <limit>] [--quiet|--debug] [--force]"
    echo
    echo "        -c                <config file>"
    echo "        -s|--source       <source host>:<VM>:<lxc|incus-ct|incus-kvm|lxd-ct|lxd-kvm>"
    echo "        -f|--freq         hourly|daily|weekly|monthly"
    echo "        -b|--bwlimit      <limit k|m|g|t>"
    echo "        -q|--quiet"
    echo "        --debug"
    echo "        --force"
    echo

    exit 1
}

f_validate_dataset_zrep() {
    local dataset_type

    dataset_type=$( zfs get type -H -o value "$DATASET_ZREP" 2> /dev/null )

    if [ ! "$dataset_type" == "filesystem" ]; then
        fc_say_fail "Missing root dataset: ('$DATASET_ZREP')"
    fi
}

f_validate_debug_quiet() {
    fc_check_arg "${@}" "full parameter list"

    if [[ "${*}" =~ --debug ]] && [[ "${*}" =~ --quiet|-q ]]; then
        fc_say_fail "The '--debug' and the '-q|--quiet' switches are mutually exclusive"
    fi
}

f_validate_number_of_sources() {
    fc_check_arg "$1" "source entry to check"

    number_of_sources=$( grep -v ^\# "$FILE_CONFIG" | grep -c "$1" )

        if [ "$number_of_sources" -eq 1 ]; then
            FULL_SOURCE_LINE=$( grep "$1" "$FILE_CONFIG" )
        else
            echo "Exactly one source entry must exist, but '${number_of_sources}' were found."

            exit 1
        fi
    }

    f_validate_source_format() {
        # Is the source parameter a short or a full one?
        if ( echo "$PARAM_SOURCE" | grep -qE "^[A-Za-z0-9\.-]+:[A-Za-z0-9\.-]+:(incus-ct|incus-kvm|lxc|lxd-ct|lxd-kvm)$" ); then
            f_validate_number_of_sources "$PARAM_SOURCE"
        elif ( echo "$PARAM_SOURCE" | grep -qE "^[A-Za-z0-9\.-]+$" ); then
            f_validate_number_of_sources ":$PARAM_SOURCE:"
        else
            fc_say_fail "Wrong format of the source parameter"
        fi
    }

    f_validate_source_list() {
        fc_check_arg "${@}" "full list parameter list"

        if [[ "${*}" =~ --list|-l ]] && [[ "${*}" =~ --source|-s ]]; then
            fc_say_fail "The '-s|--source' and the '-l|--list' switches are mutually exclusive"
        fi
    }

    f_process_args "${@}"
    f_validate_dataset_zrep
    f_validate_debug_quiet "${@}"
    f_validate_freq
    f_validate_source_format
    f_process_source_line
    f_set_hostname_in_path
    f_set_remote_zfs_path
    f_list_snapshots
    f_create_snapshot
    f_pull_snapshots
