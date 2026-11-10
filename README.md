# zrep.sh

Pull Incus/LXD snapshots with syncoid. Requires Bash 4.3+, GNU tools,
OpenZFS, SSH, syncoid and a source-side account able to create snapshots and
run the scoped ZFS commands. Configuration defaults to `/etc/zrep/zrep.conf`:

```
host-a:container-a:incus-ct
host-b:vm-b:incus-kvm
```

Supported types are `incus-ct`, `incus-kvm`, `lxd-ct`, and `lxd-kvm`.
Blank lines and full-line comments are ignored. Exactly three fields are
required. Source pools remain `tank/incus` and `tank/lxd`. The former example
fourth field `:external` was never implemented and is now explicitly rejected.

```
zrep.sh -s container-a -f daily
zrep.sh -s host-b:vm-b:incus-kvm -f weekly
zrep.sh --list vm-b
zrep-all.sh -f daily
```

The destination root `tank/zrep` must already exist. Containers replicate to
`tank/zrep/<guest>`. VMs replicate configuration and disk separately to
`tank/zrep/<guest>/<guest>` and `tank/zrep/<guest>/<guest>.block`. Guest names
must be unique across the config to prevent different hosts sharing a target.
`zrep.sh -E` inserts a source hostname beneath the root; batch mode retains the
default layout. List mode never creates datasets.

Snapshot names remain `zas-<frequency>-YYYY-MM-DD--HH`; Incus/LXD normally
exposes these in ZFS with a `snapshot-` prefix. Snapshot creation must succeed
before any transfer. An existing snapshot with the same hourly name will now
cause an explicit failure instead of silently replicating older evidence;
review/remove that snapshot through Incus/LXD before retrying in the same hour.
Concurrent runs against the same destination are not supported; serialize
scheduler invocations (for example with `flock`). The batch command continues
after job failures and exits nonzero if any job failed. This changes the former
always-success exit status; notification wrappers should handle it accordingly.

## Retention and checks

`zrep-gc.sh [-f] [-s literal-substring] DATASET KEEP` defaults to dry run.
`KEEP` is a nonnegative count (at most nine digits) or a `YYYY-MM-DD` cutoff
in the local timezone. Counts retain the newest matching snapshots per dataset;
cutoffs remove matching snapshots strictly older than local midnight. A full
dataset path selects that exact subtree. A short name selects matching path
components beneath `tank`. Filters are literal, not regular expressions.
ZFS inventory failures abort. Inspect dry-run output before using `-f`.

`zrep-check.sh --noop -d 2 -w 8` checks leaf datasets beneath `tank/zrep`.
`--noop` does not require Slack credentials. Notifications read
`/etc/slack-notification.conf` only when needed. Puppet's backup metrics provide
a configuration-based inventory and detect an entirely missing guest; the
legacy checker only sees existing datasets and cannot detect that case.

## Puppet integration

The sibling Puppet repository owns:

- `pts_only_shell`: the source-side `only-shell` executable and `.onlyrules`.
  Keep `client/onlyrules.zrep` synchronized with its managed rule file. These
  rules allow Incus snapshot creation and ZFS access to container and VM paths
  beneath `tank/incus` and `tank/lxd`, including `.block` datasets.
- `pts_users::users::u_syncoid_backup`: account/key and sudo privileges. The
  sudo entry must name `syncoid-backup`, the account zrep actually uses.
- `pts_metrics::backups`: reads the same three-field config and default
  destination layout. VM freshness requires matching daily snapshots in both
  configuration and `.block` datasets. Extended vaults are not supported by the
  metrics collector and fail collection explicitly.

Puppet currently installs a key without a forced-command restriction and puts
this account in `sudo`. Installing `.onlyrules` alone does not restrict SSH.
`client/authorized_keys` illustrates a forced-command configuration; enabling
it requires validating actual syncoid commands on the deployed version first.
This review does not automatically restrict the deployed key or group access.
The standalone `syncoid-shell` is an older alternative and is not what Puppet
installs; its rules do not cover the current replication command set.

`zsr.sh` and `lxdsr.sh` are legacy source snapshot helpers, not the retention
interface above. `lxdsr.sh` currently only lists snapshots and does not invoke
its deletion function; its unused function also contains old helper names.
Use the reviewed retention interface rather than relying on these helpers.

## Validation

```
python3 -m unittest discover -s tests -v
shellcheck -x zrep.sh zrep-all.sh zrep-gc.sh zrep-check.sh _common.sh _zrep_common.sh
```

Tests use isolated command mocks and never contact hosts or modify ZFS.
The Puppet repository additionally tests SSH rule acceptance/rejection, backup
metrics, account ordering and the generated sudo rule. Actual source-side
syncoid compatibility and restoreability require testing in the deployed
environment; these tests do not establish either.
