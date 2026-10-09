# graftcp (patched) for Alpine Proxy Manager

This directory is the complete corresponding source offer for the `graftcp` binary that
Alpine Proxy Manager downloads when the Snell SOCKS5 egress or the Snell destination
restriction feature is enabled

graftcp is licensed under the GNU General Public License version 3 or (at your option) any
later version, see `COPYING` in this directory
The Alpine Proxy Manager shell scripts are separate programs, they only start `graftcp` as
an external process, so this directory's license does not extend to them

## Upstream

- Project: graftcp
- Author and copyright holder: Hmgle (mingang.he) <dustgle@gmail.com>, 2016, 2018-2026
- Repository: https://github.com/hmgle/graftcp
- Version: tag `v0.8.3`, commit `825cf6d3b9ec043defe8e598eb218eccc1a3eaf3`
- Upstream license text: `COPYING` (copied unchanged from the upstream tag)

## Modification

- Patch: `0001-exact-endpoint-exemption.patch`, applies to `graftcp.c` only, 122 added lines
- Date of modification: 2026-10-09
- Modified by: csjcsl for Alpine Proxy Manager (https://github.com/csjcsl666/alpine-proxy-manager)
- Version string of the build: `v0.8.3-apm1`

What the patch adds

- `GRAFTCP_DIRECT_ENDPOINTS`, an environment variable listing exact `tcp|udp:IPv4:port`
  endpoints that are never redirected to the proxy, protocol, address and port must all match
- `GRAFTCP_LOOPBACK_UDP_COMM`, the process name (comm) of a local resolver whose UDP replies to
  `127.0.0.0/8` are not redirected, the replies of a local resolver cannot be listed by port
- both variables are removed from the environment before the traced program starts, a malformed
  value stops graftcp with an error instead of being ignored
- nothing else changes, without these variables graftcp behaves exactly like upstream v0.8.3

Why

graftcp can only exempt whole addresses (`--blackip-file`), and `--not-ignore-local` redirects all
loopback connections. Alpine Proxy Manager runs a private resolver on `127.0.0.53:53` that the Snell
server must reach directly. Exempting the whole address `127.0.0.53` would let a client reach any
wildcard-bound local service through that address. The patch exempts only `127.0.0.53` port 53

## Reproducible build

`build.sh` builds the binary inside an Alpine container, it needs Docker or Podman and network access

```
sh third_party/graftcp/build.sh OUTPUT_DIR
```

It clones the upstream tag, checks the commit id, applies the patch, builds a static musl binary with
the Alpine toolchain, and writes `graftcp-v0.8.3-apm1-linux-x86_64` and its SHA256 into `OUTPUT_DIR`
The Go modules are pinned by upstream `go.sum`
The Alpine release, compiler versions and the resulting SHA256 of every published binary are recorded in
`BUILDINFO` and in the GitHub Release notes

## Corresponding source

- The patch and build script in this directory, together with the upstream tag above, are the
  corresponding source of the published binary
- The binary is published as the GitHub Release `graftcp-v0.8.3-apm1` of this repository
  (https://github.com/csjcsl666/alpine-proxy-manager/releases/tag/graftcp-v0.8.3-apm1), which also attaches
  `graftcp-v0.8.3-apm1-source.tar.gz` (the full patched source tree), the patch, `COPYING`,
  `THIRD_PARTY_LICENSES.txt`, `BUILDINFO` and the SHA256, so the source is available at the same place as the binary
- That Release is not marked as the latest release, so it does not affect the update check of Alpine Proxy Manager
- Third party components linked into the binary and their licenses: `THIRD_PARTY_LICENSES.txt`
