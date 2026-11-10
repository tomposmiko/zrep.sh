# Source-side SSH access

The sibling Puppet repository installs `pts_only_shell::zrep` automatically
when it manages `pts_users::users::u_syncoid_backup`. It owns the restricted
login shell `/usr/local/sbin/pts-zrep-ssh`, privileged command gateway
`/usr/local/sbin/pts-zrep-source`, SSH account restrictions, key and sudo rule.

The `authorized_keys` example requires those files and the restricted sudo
policy to be installed first. The legacy `only-shell`, `onlyrc.zrep`,
`onlyrules.zrep` and `onlyrules.example` files are retained for historical
reference; the hardened Puppet account does not use them.

Keep zrep's `--no-clone-handling` default: the gateway permits source commands
only inside `tank/{incus,lxd}/{containers,virtual-machines}/<guest>` and their
children, never Incus/LXD image origins. Both source-side container/VM
components and zrep's `incus snapshot create` / `lxc snapshot` requests are
supported. No general shell, dataset deletion or receive is granted.
