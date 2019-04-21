#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echoerr() {
    printf "%s\n" "$*" >&2
}

if [ "$1" == "-c" ] ; then
    shift
fi

if [ "$1" == "exit" ] ; then
    eval $@
fi

if [ "$1" == "echo -n" ] ; then
    eval $@
    exit $?
fi

if echo "$@" |grep -q -E "^sudo zfs list -o name,origin -t filesystem,volume -Hr '[A-Za-Z0-9/-]+'$" ; then
    eval $@
    exit $?
fi

if echo "$@" |grep -q -E "sudo zfs get -H syncoid:sync '[A-Za-Z0-9/-]+'$" ; then
    eval $@
    exit $?
fi

if echo "$@" |grep -q -E "^sudo zfs get -Hpd 1 -t snapshot guid,creation '[A-Za-Z0-9/-]+'$" ; then
    eval $@
    exit $?
fi

# syncoid meta snapshot format: <filesystem>@syncoid_<hostname>_YYYY-mm-dd:HH:mm:ss
if echo "$@" |grep -q -E "^sudo zfs snapshot '[A-Za-Z0-9/-]+'@syncoid_[A-Za-Z0-9/.-]+_20[0-9:-]{17}$" ; then
    eval $@
    exit $?
fi

# syncoid meta snapshot format: <filesystem>@syncoid_<hostname>_YYYY-mm-dd:HH:mm:ss
#if echo "$@" |grep -q -E "^sudo zfs destroy '[A-Za-Z0-9/-]+'@syncoid_[A-Za-Z0-9/.-]+_20[0-9:-]{17}$" ; then
if echo "$@" | grep -q -E "^(sudo zfs destroy '[A-Za-Z0-9/-]+'@syncoid_[A-Za-Z0-9/.-]+_20[0-9:-]{17}(\; )?)+" ; then
    eval $@
    exit $?
fi

# sudo zfs snapshot 'tank/lxd/containers/signer'@syncoid_backup11_2019-04-21:19:58:32
if echo "$@" |grep -q -E "sudo zfs snapshot '[A-Za-Z0-9/-]+'@'syncoid_[A-Za-Z0-9/.-]+_20[0-9:-]{17}$" ; then
    eval $@
    exit $?
fi

if echo "$@" |grep -q -E "^sudo zfs send -I '[A-Za-Z0-9/-]+'@'syncoid_[A-Za-Z0-9/.-]+_20[0-9:-]{17}' '[A-Za-Z0-9/-]+'@'syncoid_[A-Za-Z0-9/.-]+_20[0-9:-]{17}' | lzop | mbuffer -q -s 128k -m 16M 2>/dev/null$" ; then
    eval $@
    exit $?
fi

# lxd
if echo "$@" |grep -q -E "^lxc snapshot [A-Za-Z0-9/-]+ zas-20[0-9-]+$" ; then
    eval $@
    exit $?
fi

# kvm, lxc
if echo "$@" |grep -q -E "^zfs snapshot -r [A-Za-Z0-9/-]+@zas-20[0-9-]+$" ; then
    eval $@
    exit $?
fi

if [ "$@" ]; then
    echoerr "!!! WARNING !!!"
    echoerr "!!! UNKNWON zrep command sent to remote !!!"
    echoerr "command: $@"
    exit 1
fi

#eval $@
