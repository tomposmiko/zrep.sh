#!/bin/bash
# Tests run by name in isolated Bash processes; Incus is always a fixture.
# shellcheck disable=SC2329
set -euo pipefail
SCRIPT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/isr.sh
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

setup_fixture() {
    CASE_DIR=$WORK/$1
    mkdir -p "$CASE_DIR"
    printf '%s\n' '{"environment":{"server_name":"v201","server_clustered":false}}' > "$CASE_DIR/server.json"
    printf '%s\n' '[{"name":"ct-1","type":"container","project":"default","created_at":"2019-01-01T00:00:00Z","location":"none"}]' > "$CASE_DIR/instances.json"
    printf '%s\n' '[{"name":"old.one","created_at":"2020-01-01T00:00:00Z"},{"name":"old.two","created_at":"2020-01-02T00:00:00Z"},{"name":"manual-new","created_at":"2020-01-03T00:00:00Z"}]' > "$CASE_DIR/ct-1.json"
    cat > "$CASE_DIR/incus" <<'INCUS'
#!/bin/bash
set -euo pipefail
dir=${0%/*}
[[ -n ${INCUS_CONF:-} && -n ${INCUS_GLOBAL_CONF:-} && -n ${INCUS_CACHE:-} ]] || exit 94
printf '%s\n' "$INCUS_CONF" "$INCUS_GLOBAL_CONF" "$INCUS_CACHE" > "$dir/client-environment"
jq -nc --args '$ARGS.positional' -- "$@" >> "$dir/calls"
if [[ ${2:-} == query ]]; then
    [[ $# == 3 && $1 == --force-local && $3 == /1.0 ]] || exit 95
    cat "$dir/server.json"
    exit 0
fi
[[ $# -ge 4 && $1 == --force-local && $2 == --project ]] || exit 90
shift 3
case "$1 $2" in
    # Real Incus rejects --project with query, despite listing it in global help.
    'query /1.0') printf 'Error: --project cannot be used with the query command\n' >&2; exit 1 ;;
    'list --format=json')
        count=0; [[ ! -f $dir/list-count ]] || read -r count < "$dir/list-count"
        count=$((count + 1)); printf '%s\n' "$count" > "$dir/list-count"
        if [[ -f $dir/replace-instance && $count == 3 ]]; then
            jq '.[0].created_at="2021-01-01T00:00:00Z"' "$dir/instances.json" > "$dir/new"
            mv "$dir/new" "$dir/instances.json"
        fi
        cat "$dir/instances.json" ;;
    'snapshot list')
        [[ $# == 4 && $4 == --format=json ]] || exit 91
        guest=$3
        count=0; [[ ! -f $dir/snap-count-$guest ]] || read -r count < "$dir/snap-count-$guest"
        count=$((count + 1)); printf '%s\n' "$count" > "$dir/snap-count-$guest"
        if [[ -f $dir/change-at-$count ]]; then
            jq '.[0].created_at="2021-01-01T00:00:00Z"' "$dir/$guest.json" > "$dir/new"
            mv "$dir/new" "$dir/$guest.json"
        fi
        cat "$dir/$guest.json" ;;
    'snapshot delete')
        [[ $# == 4 ]] || exit 92
        guest=$3; snapshot=$4
        printf '%s/%s\n' "$guest" "$snapshot" >> "$dir/deleted"
        [[ ! -f $dir/fail-delete ]] || exit 7
        jq --arg snapshot "$snapshot" '[.[] | select(.name != $snapshot)]' "$dir/$guest.json" > "$dir/new"
        mv "$dir/new" "$dir/$guest.json"
        if [[ -f $dir/remove-protected ]]; then
            jq '[.[] | select(.name != "manual-new")]' "$dir/$guest.json" > "$dir/new"
            mv "$dir/new" "$dir/$guest.json"
        fi ;;
    *) exit 93 ;;
esac
INCUS
    chmod +x "$CASE_DIR/incus"
}

run_check() {
    local expected=$1 fragment=$2 status
    shift 2
    if OUTPUT=$(bash "$SCRIPT" --incus "$CASE_DIR/incus" "$@" 2>&1); then status=0; else status=$?; fi
    if [[ $status != "$expected" || ( -n $fragment && $OUTPUT != *"$fragment"* ) ]]; then
        printf 'Expected status=%s text=%s; got status=%s: %s\n' "$expected" "$fragment" "$status" "$OUTPUT" >&2
        return 1
    fi
}
no_deletes() { [[ ! -s $CASE_DIR/deleted ]]; }

invalid_arguments() {
    run_check 1 'Specify either'
    run_check 1 'retention option' --instance ct-1
    run_check 1 'retention option' --all-instances
    run_check 1 'Specify either' --all-instances --instance ct-1 old
    run_check 1 'Invalid project/instance' --instance remote:ct-1 old
    run_check 1 'Invalid project/instance' --project '../default' --instance ct-1 old
    run_check 1 'Unsafe literal pattern' --instance ct-1 '.*'
    run_check 1 'Unsafe literal pattern' --instance ct-1 '..'
    run_check 1 'Unknown option' --bad
    run_check 1 'Missing value' --instance
    [[ ! -e $CASE_DIR/calls ]]
}
confirmation_required() {
    run_check 1 'Deletion requires' --instance ct-1 old --delete --confirm default/ct-1
    run_check 1 'Deletion requires' --project default --instance ct-1 old --delete --confirm other/ct-1
    run_check 1 'requires --delete' --project default --instance ct-1 old --confirm default/ct-1
    run_check 1 'Deletion requires' --project default --all-instances old --delete --confirm default/ct-1
    [[ ! -e $CASE_DIR/calls ]]
}
invalid_retention() {
    local value
    for value in 0d -1d 1month 10000000d; do run_check 1 '' --instance ct-1 --older-than "$value"; done
    for value in tomorrow 2020-02-30 2999-01-01 '2020-01-01;id'; do run_check 1 '' --instance ct-1 --before "$value"; done
    for value in -1 abc 1000001; do run_check 1 '' --instance ct-1 --keep-at-least "$value"; done
    run_check 1 '' --instance ct-1 old --max-delete 0
    [[ ! -e $CASE_DIR/calls ]]
}
preview_literal_patterns() {
    run_check 0 'DRY RUN' --instance ct-1 old.one
    [[ $OUTPUT == *'Selected snapshots: 1'* && $OUTPUT == *ct-1/old.one* && $OUTPUT != *ct-1/old.two* ]]
    no_deletes
    run_check 0 'Selected snapshots: 2' --instance ct-1 old.one old.two
    no_deletes
    run_check 0 'No matching snapshots' --instance ct-1 ct-1
}
manual_names_and_no_patterns() {
    run_check 0 'Selected snapshots: 2' --instance ct-1 --keep-at-least 1
    [[ $OUTPUT != *'  ct-1/manual-new'* ]]
    no_deletes
    run_check 0 'Selected snapshots: 3' --instance ct-1 --before 2021-01-01
    [[ $OUTPUT == *'  ct-1/manual-new'* ]]
    run_check 0 'Selected snapshots: 3' --instance ct-1 --older-than 7d
}
exclusive_creation_cutoff() {
    run_check 0 'Selected snapshots: 1' --instance ct-1 --before 2020-01-02T00:00:00Z
    [[ $OUTPUT == *'  ct-1/old.one'* && $OUTPUT != *'  ct-1/old.two'* ]]
    # Name dates are ignored; use the actual creation timestamp.
    printf '%s\n' '[{"name":"zas-daily-2099-01-01","created_at":"2020-01-01T00:00:00Z"}]' > "$CASE_DIR/ct-1.json"
    run_check 0 'Selected snapshots: 1' --instance ct-1 --before 2021-01-01 zas-daily
}
timezone_and_combined_policies() {
    run_check 0 'Selected snapshots: 1' --instance ct-1 --before 2020-01-02T02:00:00+02:00
    run_check 0 'Selected snapshots: 1' --instance ct-1 --before 2020-01-02 --older-than 7d
    run_check 0 'Selected snapshots: 0' --instance ct-1 --before 2020-01-02 --keep-at-least 3
}
keep_matches_only() {
    run_check 0 'Selected snapshots: 1' --instance ct-1 --keep-at-least 1 old
    [[ $OUTPUT == *'  ct-1/old.one'* && $OUTPUT != *'  ct-1/old.two'* && $OUTPUT != *'  ct-1/manual-new'* ]]
}
nanosecond_order() {
    printf '%s\n' '[{"name":"aaa","created_at":"2020-01-01T00:00:00.999999999Z"},{"name":"zzz","created_at":"2020-01-01T00:00:00.000000001Z"}]' > "$CASE_DIR/ct-1.json"
    run_check 0 'Selected snapshots: 1' --instance ct-1 --keep-at-least 1
    [[ $OUTPUT == *'  ct-1/zzz'* && $OUTPUT != *'  ct-1/aaa'* ]]
}
vm_and_container_scope() {
    jq '. += [.[0] | .name="vm-1" | .type="virtual-machine"]' "$CASE_DIR/instances.json" > "$CASE_DIR/new"
    mv "$CASE_DIR/new" "$CASE_DIR/instances.json"
    cp "$CASE_DIR/ct-1.json" "$CASE_DIR/vm-1.json"
    run_check 0 'Selected snapshots: 4' --all-instances --keep-at-least 1
    no_deletes
    run_check 0 'Deleted 4 snapshot(s)' --project default --all-instances --keep-at-least 1 --delete --confirm 'default/*'
    [[ $(wc -l < "$CASE_DIR/deleted") == 4 ]]
    [[ $(jq -r '.[0].name' "$CASE_DIR/ct-1.json") == manual-new && $(jq -r '.[0].name' "$CASE_DIR/vm-1.json") == manual-new ]]
    jq -se 'all(.[0] == "--force-local" and (if .[1] == "query" then . == ["--force-local", "query", "/1.0"] else .[1] == "--project" and .[2] == "default" and .[3] != "delete" end))' "$CASE_DIR/calls" > /dev/null
}
non_default_project() {
    jq '.[0].project="customer"' "$CASE_DIR/instances.json" > "$CASE_DIR/new"
    mv "$CASE_DIR/new" "$CASE_DIR/instances.json"
    run_check 0 'Deleted 1 snapshot(s)' --project customer --instance ct-1 old.one --delete --confirm customer/ct-1
    [[ $(cat "$CASE_DIR/deleted") == ct-1/old.one ]]
    jq -se 'all(if .[1] == "query" then . == ["--force-local", "query", "/1.0"] else .[1] == "--project" and .[2] == "customer" end)' "$CASE_DIR/calls" > /dev/null
}
cluster_local_only() {
    printf '%s\n' '{"environment":{"server_name":"v201","server_clustered":true}}' > "$CASE_DIR/server.json"
    jq '.[0].location="v201" | . += [.[0] | .name="remote-vm" | .type="virtual-machine" | .location="other-member"]' "$CASE_DIR/instances.json" > "$CASE_DIR/new"
    mv "$CASE_DIR/new" "$CASE_DIR/instances.json"
    run_check 0 'Selected snapshots: 2' --all-instances --keep-at-least 1
    [[ ! -e $CASE_DIR/snap-count-remote-vm ]]
    run_check 1 'absent from the local member' --instance remote-vm --older-than 7d
    no_deletes
}
max_delete_limit() {
    run_check 1 'exceeds --max-delete' --project default --instance ct-1 --keep-at-least 0 --delete --confirm default/ct-1 --max-delete 2
    no_deletes
    run_check 0 'Deleted 3 snapshot(s)' --project default --instance ct-1 --keep-at-least 0 --delete --confirm default/ct-1 --max-delete 3
}
invalid_snapshot_metadata() {
    local json
    for json in 'not-json' '[{"name":"ct-1/snapshot","created_at":"2020-01-01T00:00:00Z"}]' '[{"name":"--force","created_at":"2020-01-01T00:00:00Z"}]' '[{"name":"bad","created_at":"tomorrow"}]' '[{"name":"bad","created_at":"2999-01-01T00:00:00Z"}]' '[{"name":"bad","created_at":"0001-01-01T00:00:00Z"}]'; do
        printf '%s\n' "$json" > "$CASE_DIR/ct-1.json"
        run_check 1 '' --project default --instance ct-1 --older-than 7d --delete --confirm default/ct-1
        no_deletes
    done
    printf '%s\n' '[{"name":"same","created_at":"2020-01-01T00:00:00Z"},{"name":"same","created_at":"2020-01-02T00:00:00Z"}]' > "$CASE_DIR/ct-1.json"
    run_check 1 'Invalid snapshot inventory' --project default --instance ct-1 --older-than 7d --delete --confirm default/ct-1
    no_deletes
}
validate_all_before_deletion() {
    jq '. += [.[0] | .name="zz-vm" | .type="virtual-machine"]' "$CASE_DIR/instances.json" > "$CASE_DIR/new"
    mv "$CASE_DIR/new" "$CASE_DIR/instances.json"
    printf 'not-json\n' > "$CASE_DIR/zz-vm.json"
    run_check 1 'Invalid snapshot inventory for zz-vm' --project default --all-instances --older-than 7d --delete --confirm 'default/*'
    no_deletes
}
snapshot_changes_abort() {
    touch "$CASE_DIR/change-at-2"
    run_check 1 'Snapshot inventory changed' --project default --instance ct-1 old --delete --confirm default/ct-1
    no_deletes
}
last_moment_changes_abort() {
    touch "$CASE_DIR/change-at-3"
    run_check 1 'Snapshot inventory changed' --project default --instance ct-1 old --delete --confirm default/ct-1
    no_deletes
}
instance_recreation_aborts() {
    touch "$CASE_DIR/replace-instance"
    run_check 1 'Instance/server inventory changed' --project default --instance ct-1 old --delete --confirm default/ct-1
    no_deletes
}
stop_on_failed_delete() {
    touch "$CASE_DIR/fail-delete"
    run_check 1 'Snapshot deletion failed' --project default --instance ct-1 old --delete --confirm default/ct-1
    [[ $(wc -l < "$CASE_DIR/deleted") == 1 && $(jq length "$CASE_DIR/ct-1.json") == 3 ]]
}
protected_snapshot_removed_aborts() {
    touch "$CASE_DIR/remove-protected"
    run_check 1 'Snapshot inventory changed' --project default --instance ct-1 --keep-at-least 1 --delete --confirm default/ct-1
    [[ $(wc -l < "$CASE_DIR/deleted") == 1 ]]
}
empty_and_unknown_instances() {
    printf '[]\n' > "$CASE_DIR/ct-1.json"
    run_check 0 'No matching snapshots' --project default --instance ct-1 old --delete --confirm default/ct-1
    no_deletes
    run_check 1 'absent from the local member' --instance unknown old
    printf '[]\n' > "$CASE_DIR/instances.json"
    run_check 0 'No matching snapshots' --all-instances --older-than 7d
}
instance_scope_metadata_validation() {
    jq '.[0].project="other"' "$CASE_DIR/instances.json" > "$CASE_DIR/new"
    mv "$CASE_DIR/new" "$CASE_DIR/instances.json"
    run_check 1 'out-of-project' --project default --instance ct-1 old --delete --confirm default/ct-1
    no_deletes
}
isolated_client_configuration() {
    mkdir -p "$CASE_DIR/hostile-config" "$CASE_DIR/hostile-global" "$CASE_DIR/hostile-cache"
    printf 'aliases:\n  snapshot delete: delete --force\n' > "$CASE_DIR/hostile-config/config.yml"
    INCUS_CONF="$CASE_DIR/hostile-config" INCUS_GLOBAL_CONF="$CASE_DIR/hostile-global" INCUS_CACHE="$CASE_DIR/hostile-cache" run_check 0 'Deleted 1 snapshot(s)' --project default --instance ct-1 old.one --delete --confirm default/ct-1
    if grep -q 'hostile-' "$CASE_DIR/client-environment"; then return 1; fi
    while IFS= read -r directory; do [[ ! -e $directory ]]; done < "$CASE_DIR/client-environment"
    [[ $(cat "$CASE_DIR/deleted") == ct-1/old.one ]]
}
help_and_source_safety() {
    run_check 0 'Usage:' --help
    [[ ! -e $CASE_DIR/calls ]]
    bash -c 'set +e +u; set +o pipefail; before=$-; source "$1"; [[ $- == "$before" ]]; [[ $(set -o | grep pipefail) == *off ]]' _ "$SCRIPT"
}

FAILED=0
for TEST in invalid_arguments confirmation_required invalid_retention preview_literal_patterns manual_names_and_no_patterns exclusive_creation_cutoff timezone_and_combined_policies keep_matches_only nanosecond_order vm_and_container_scope non_default_project cluster_local_only max_delete_limit invalid_snapshot_metadata validate_all_before_deletion snapshot_changes_abort last_moment_changes_abort instance_recreation_aborts stop_on_failed_delete protected_snapshot_removed_aborts empty_and_unknown_instances instance_scope_metadata_validation isolated_client_configuration help_and_source_safety; do
    setup_fixture "$TEST"
    export SCRIPT CASE_DIR
    if TZ=UTC bash -euo pipefail -c "$(declare -f); $TEST"; then printf 'ok - isr %s\n' "$TEST"
    else printf 'not ok - isr %s\n' "$TEST" >&2; FAILED=1; fi
done
exit "$FAILED"
