# Source-side SSH access

For hosts without Puppet, build a standalone installer bundle:

```
bash client/build-source-bundle.sh --output /tmp/zrep-source-install.tar.gz
```

The builder reads the gateway from the sibling `puppet` checkout (override with
`--puppet PATH`) and bundles it with the installer, checksums and
[manual deployment instructions](source-install/README.md). It does not deploy
anything. The archive is self-contained; no Puppet checkout is needed on v201.

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
