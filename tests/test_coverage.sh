#!/bin/bash
# Tests are invoked by name in isolated Bash processes.
# shellcheck disable=SC2329
set -euo pipefail
CHECKER=${ZREP_COVERAGE_SCRIPT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/zrep-coverage.sh}
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

setup_fixture() {
    CASE_DIR=$WORK/$1
    mkdir -p "$CASE_DIR"
    printf '%s\n' 'v102:ct-1:incus-ct' > "$CASE_DIR/config"
    printf 'tank/zrep\tfilesystem\ntank/zrep/ct-1\tfilesystem\n' > "$CASE_DIR/listing"
    jq -n --argjson now "$(date +%s)" '{version:1, generated_at:$now, platforms:["incus"], instances:[{platform:"incus", project:"default", name:"ct-1", type:"container", pool:"default", driver:"zfs", source:"tank/incus"}]}' > "$CASE_DIR/v102.json"
    cat > "$CASE_DIR/ssh" <<'SSH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$@" >> "${0%/*}/ssh.args"
host=''
for arg in "$@"; do [[ $arg != syncoid-backup@* ]] || host=${arg#*@}; done
[[ ${!#} == 'zrep inventory' && -n $host && ! -f ${0%/*}/fail-$host ]] || exit 1
cat "${0%/*}/$host.json"
SSH
    cat > "$CASE_DIR/zfs" <<'ZFS'
#!/bin/bash
printf '%s\n' "$@" > "${0%/*}/zfs.args"
cat "${0%/*}/listing"
ZFS
    chmod +x "$CASE_DIR/ssh" "$CASE_DIR/zfs"
}

run_check() {
    local expected=$1 fragment=$2 status
    shift 2
    if OUTPUT=$(bash "$CHECKER" --config "$CASE_DIR/config" --ssh "$CASE_DIR/ssh" --zfs "$CASE_DIR/zfs" "$@" 2>&1); then status=0; else status=$?; fi
    if [[ $status != "$expected" || ( -n $fragment && $OUTPUT != *"$fragment"* ) ]]; then
        printf 'Expected exit %s containing %s; got %s: %s\n' "$expected" "$fragment" "$status" "$OUTPUT" >&2
        return 1
    fi
}

healthy() {
    local before
    before=$(stat -c '%s:%y' "$CASE_DIR/config")
    run_check 0 ''
    [[ -z $OUTPUT && $before == "$(stat -c '%s:%y' "$CASE_DIR/config")" ]]
    [[ $(cat "$CASE_DIR/zfs.args") == $'list\n-H\n-r\n-t\nfilesystem,volume\n-o\nname,type\ntank/zrep' ]]
    [[ $(tail -n 2 "$CASE_DIR/ssh.args") == $'syncoid-backup@v102\nzrep inventory' ]]
}
new_instance() {
    jq '.instances += [.instances[0] | .name="new-ct"]' "$CASE_DIR/v102.json" > "$CASE_DIR/new.json"
    mv "$CASE_DIR/new.json" "$CASE_DIR/v102.json"
    run_check 1 'v102/new-ct: missing replication configuration'
    [[ $OUTPUT == *$'- expected entry: v102:new-ct:incus-ct'* ]]
    [[ $OUTPUT != *'new-ct: missing or invalid backup dataset'* ]]
    [[ $OUTPUT == 'ZREP COVERAGE FAILED: 1 problem(s), 2 expected instance(s) checked'* ]]
    printf '%s\n' 'v102:new-ct:incus-ct' >> "$CASE_DIR/config"
    run_check 1 'v102/new-ct: missing or invalid backup dataset'
    printf 'tank/zrep/new-ct\tfilesystem\n' >> "$CASE_DIR/listing"
    run_check 0 ''
}
unmanaged_source() {
    jq '.platforms=["lxd"] | .instances[0] |= (.platform="lxd" | .name="external-vm" | .type="virtual-machine" | .source="tank/lxd")' "$CASE_DIR/v102.json" > "$CASE_DIR/v201.sg.svfx.json"
    printf '%s\n' v102 v201.sg.svfx > "$CASE_DIR/hosts"
    run_check 1 'v201.sg.svfx/external-vm: missing replication configuration' --hosts-file "$CASE_DIR/hosts"
    [[ $OUTPUT == *'- expected entry: v201.sg.svfx:external-vm:lxd-kvm'* && $OUTPUT != *'v201.sg.svfx/external-vm: missing or invalid backup dataset'* ]]
    printf '%s\n' 'v201.sg.svfx:external-vm:lxd-kvm' >> "$CASE_DIR/config"
    run_check 1 'v201.sg.svfx/external-vm: missing or invalid backup dataset' --hosts-file "$CASE_DIR/hosts"
    printf 'tank/zrep/external-vm\tfilesystem\ntank/zrep/external-vm/external-vm\tfilesystem\ntank/zrep/external-vm/external-vm.block\tvolume\n' >> "$CASE_DIR/listing"
    run_check 0 '' --hosts-file "$CASE_DIR/hosts"
}
missing_vm_component() {
    printf '%s\n' 'v102:ct-1:incus-kvm' > "$CASE_DIR/config"
    jq '.instances[0].type="virtual-machine"' "$CASE_DIR/v102.json" > "$CASE_DIR/new.json"
    mv "$CASE_DIR/new.json" "$CASE_DIR/v102.json"
    printf 'tank/zrep/ct-1/ct-1\tfilesystem\n' >> "$CASE_DIR/listing"
    run_check 1 'ct-1.block (volume); actual: missing'
    printf 'tank/zrep/ct-1/ct-1.block\tfilesystem\n' >> "$CASE_DIR/listing"
    run_check 1 'ct-1.block (volume); actual: filesystem'
    sed -i 's/ct-1.block\tfilesystem/ct-1.block\tvolume/' "$CASE_DIR/listing"
    run_check 0 ''
}
wrong_type() {
    printf '%s\n' 'v102:ct-1:lxd-ct' > "$CASE_DIR/config"
    run_check 1 'v102/ct-1: incorrect replication type'
    [[ $OUTPUT == *'- expected type: incus-ct'* ]]
}
source_unavailable() {
    touch "$CASE_DIR/fail-v102"
    run_check 1 'v102: source inventory unavailable'
    [[ $OUTPUT != *'configured instance missing'* ]]
}
empty_source() {
    jq '.instances=[]' "$CASE_DIR/v102.json" > "$CASE_DIR/v201.json"
    run_check 0 '' --host v201
    jq '.instances=[]' "$CASE_DIR/v102.json" > "$CASE_DIR/new.json"
    mv "$CASE_DIR/new.json" "$CASE_DIR/v102.json"
    run_check 1 'v102/ct-1: configured instance missing'
    : > "$CASE_DIR/config"
    run_check 0 '0 expected instance(s)' --host v201 --verbose
}
invalid_inventory() {
    local expression
    for expression in '.version=2' '.generated_at-=1000' '.generated_at+=1000' '.instances += .instances' '.instances[0].name=null' '.instances[0].source="bad\npath"'; do
        jq "$expression" "$CASE_DIR/v102.json" > "$CASE_DIR/v201.json"
        run_check 1 'v201: invalid source inventory' --host v201
    done
    printf 'not JSON\n' > "$CASE_DIR/v201.json"
    run_check 1 'v201: invalid source inventory' --host v201
}
unsupported_project_storage() {
    jq '.instances[0].project="customer"' "$CASE_DIR/v102.json" > "$CASE_DIR/v201.json"
    run_check 1 'v201/customer/ct-1: unsupported project' --host v201
    jq '.instances[0].source="other/pool"' "$CASE_DIR/v102.json" > "$CASE_DIR/v201.json"
    run_check 1 'v201/ct-1: unsupported source storage' --host v201
    jq '.instances[0].driver="dir"' "$CASE_DIR/v102.json" > "$CASE_DIR/v201.json"
    run_check 1 'v201/ct-1: unsupported source storage' --host v201
}
aliases_and_exclusions() {
    cp "$CASE_DIR/v102.json" "$CASE_DIR/source.example.json"
    run_check 0 '' --host source.example --host-alias source.example=v102
    [[ $(grep -c '^syncoid-backup@v102$' "$CASE_DIR/ssh.args") == 1 ]]
    run_check 2 'directly to canonical' --host-alias a=b --host-alias b=c
    run_check 1 'no hosts checked' --ignore-host v102
    run_check 0 '' --host offline --ignore-host offline
    printf '%s\n' 'v102:obsolete:incus-ct' >> "$CASE_DIR/config"
    run_check 0 '' --ignore-instance obsolete
    jq '.instances[0].name="new-ct"' "$CASE_DIR/v102.json" > "$CASE_DIR/v201.json"
    run_check 0 '' --host v201 --ignore-instance new-ct --ignore-instance obsolete
}
configuration_errors() {
    printf '%s\n' 'v201:ct-1:incus-ct' >> "$CASE_DIR/config"
    cp "$CASE_DIR/v102.json" "$CASE_DIR/v201.json"
    run_check 1 'destination collision'
    printf '%s\n' 'v102:bad:unknown' >> "$CASE_DIR/config"
    run_check 1 'invalid replication configuration'
    rm "$CASE_DIR/config"
    run_check 2 'cannot read replication configuration'
}
host_inventory_errors() {
    run_check 2 'cannot read source host inventory' --hosts-file "$CASE_DIR/hosts"
    : > "$CASE_DIR/hosts"
    run_check 2 'empty source host inventory' --hosts-file "$CASE_DIR/hosts"
    printf 'v102;id\n' > "$CASE_DIR/hosts"
    run_check 2 'invalid source host' --hosts-file "$CASE_DIR/hosts"
    [[ ! -e $CASE_DIR/ssh.args ]]
}
extended_layout() {
    printf 'tank/zrep\tfilesystem\ntank/zrep/v102/ct-1\tfilesystem\n' > "$CASE_DIR/listing"
    run_check 0 '' --extended-vault
    run_check 1 'missing or invalid backup dataset'
    cp "$CASE_DIR/v102.json" "$CASE_DIR/source.example.json"
    run_check 0 '' --extended-vault --host-alias v102=source.example
}
zfs_errors() {
    printf 'tank/zrep\tfilesystem\ntank/zrep\tfilesystem\n' > "$CASE_DIR/listing"
    run_check 2 'unexpected destination ZFS inventory'
    printf '#!/bin/bash\nexit 1\n' > "$CASE_DIR/zfs"
    run_check 2 'cannot read destination ZFS inventory'
}
help_source_safety() {
    bash "$CHECKER" --help > "$CASE_DIR/help"
    [[ ! -e $CASE_DIR/ssh.args && ! -e $CASE_DIR/zfs.args ]]
    bash -c 'set +e +u; set +o pipefail; before=$-; source "$1"; [[ $- == "$before" ]]; [[ $(set -o | grep pipefail) == *off ]]' _ "$CHECKER"
    run_check 2 'unknown argument' --unknown
    run_check 2 'invalid hostname' --host 'v201;id'
    run_check 2 'missing value' --host
}

FAILED=0
for TEST in healthy new_instance unmanaged_source missing_vm_component wrong_type source_unavailable empty_source invalid_inventory unsupported_project_storage aliases_and_exclusions configuration_errors host_inventory_errors extended_layout zfs_errors help_source_safety; do
    setup_fixture "$TEST"
    export CHECKER CASE_DIR
    if bash -euo pipefail -c "$(declare -f); $TEST"; then printf 'ok - zrep coverage %s\n' "$TEST"
    else printf 'not ok - zrep coverage %s\n' "$TEST" >&2; FAILED=1; fi
done
exit "$FAILED"
