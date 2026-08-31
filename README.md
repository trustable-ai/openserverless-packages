# Apache OpenServerless Packages

Builds the `openserverless` Debian package: a self-contained, offline-installable
bundle of [k3s](https://k3s.io) with Apache OpenServerless already deployed into
it.

The package is not built from sources. Instead, a clean machine is used as a
mould: k3s is installed, OpenServerless is deployed on top of it, the resulting
cluster is trimmed and stopped, and the entire on-disk state — binaries, systemd
units and the whole `/var/lib/rancher/k3s` tree — is tarred straight from its
real location into a `.deb`. Installing that package on a target machine restores
a cluster that is already up and configured, with no image pulls and no network
access required.

Because the payload is a snapshot of a live k3s installation, **builds must run
on a disposable machine** (a CI runner or a throwaway VM). The scripts install
system packages, create a `trustable` user and take over k3s on the host.

## Layout

| File | Role |
| --- | --- |
| [env](env) | Version inputs: `OPS_BRANCH` and the olaris repo, sourced by every script |
| [setup.sh](setup.sh) | Installs build dependencies, the `trustable` user and the `ops` CLI |
| [prepare.sh](prepare.sh) | Installs k3s, deploys OpenServerless onto it, trims and stops it |
| [package.sh](package.sh) | Assembles the `.deb` from the prepared machine state |
| [publish.sh](publish.sh) | Uploads the `.deb` to S3 and records it in the GitHub release |
| [.github/workflows/build.yml](.github/workflows/build.yml) | Runs all four, for amd64 and arm64 |

Build output goes to `../dist` — a sibling of this directory, not inside it.

## Build

Run the scripts in order on a disposable Debian/Ubuntu machine:

```bash
./setup.sh          # dependencies, trustable user, ops CLI
./prepare.sh        # install k3s + deploy OpenServerless (slow)
sudo -E ./package.sh
```

This produces, in `../dist`:

- `openserverless_<version>_<arch>.deb`
- `version.txt` — the version string, so later steps need not re-derive it

`package.sh --test` builds a much smaller package that bundles only the k3s
control plane (`/var/lib/rancher/k3s/server`) and skips the data tree. It is for
validating the install flow quickly, not for release.

### Versioning

The version is derived from `ops -info`, as the ops branch plus the first six
characters of the olaris commit hash — for example `0.1.0+f7613c`. It is written
to `../dist/version.txt` by `package.sh` and read back by `publish.sh`.

## Publish

```bash
S3_ENDPOINT=... S3_ZONE=... S3_KEY=... S3_SECRET=... ./publish.sh
```

`publish.sh` uploads `../dist/openserverless_<version>_<arch>.deb` to the
`openserverless` bucket, publicly served from
<https://openserverless.nuvolaris.download>, then adds a link to the notes of the
`v<version>` GitHub release, creating the release if it does not yet exist.

The amd64 and arm64 jobs publish to the same release tag concurrently, so the
notes are updated additively: each run replaces only the line for its own
architecture and preserves the other's, retrying if a concurrent write wins the
race. Without `GH_TOKEN`/`GITHUB_TOKEN` the upload still runs and the release
step is skipped.

The workflow expects four repository secrets: `S3_ENDPOINT`, `S3_ZONE`, `S3_KEY`
and `S3_SECRET`.

## CI

`Build` is a manual workflow (`workflow_dispatch`) with an `arch` input of
`all` (default), `amd` or `arm`. Each architecture runs the full
setup → prepare → package → publish chain on its own runner, and the two jobs
converge on a single `v<version>` release carrying both `.deb` files.

## Installing

```bash
sudo apt install ./openserverless_<version>_<arch>.deb
```

The package refuses to install if OpenServerless is already installed, if another
k3s installation exists at `/var/lib/rancher/k3s`, or if port 80 is in use — it
bundles its own k3s and cannot coexist with another one. On success it creates
the `trustable` user, installs a firewall drop-in restricting ports 80/443/6443
to non-external traffic, and starts k3s.

The platform is then reachable locally at <http://trustable.miniops.me>, or over
an SSH tunnel for a remote host:

```bash
ssh -L <port>:127.0.0.1:80 <your-server>
# then browse http://trustable.miniops.me:<port>
```

Removal (`apt-get remove`) stops k3s and wipes `/var/lib/rancher/k3s` but leaves
user data under `/home/trustable`; `apt-get purge openserverless` removes that
too.
