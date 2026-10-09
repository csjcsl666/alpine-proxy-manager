# anytls-socks-gateway

AnyTLS inbound listeners, each forwarding TCP connections to one fixed SOCKS5 upstream
Used by the AnyTLS Gateway Core of Alpine Proxy Manager

- Scope: TCP only, no routing, no DNS, no UDP handling, no log files, no management interface
- License: GPL-3.0-or-later (links github.com/sagernet/sing and github.com/sagernet/sing-anytls, both GPL-3.0-or-later, Copyright (C) 2022 nekohasekai), see `COPYING` and `THIRD_PARTY_LICENSES.txt`
- Author of this program: csjcsl, 2026, rebuilt from the original single-file gateway that ran on a 64 MiB container
- Dependencies are pinned by `go.mod` and `go.sum`, sing-anytls at commit cec2d74334be of 2026-09-04
- The binary is published as the GitHub Release `anytls-gateway-v0.1.0` of https://github.com/csjcsl666/alpine-proxy-manager together with this source (`anytls-socks-gateway-v0.1.0-source.tar.gz`) and the SHA256

## Reproduce

```
sh third_party/anytls-gateway/build.sh OUTPUT_DIR
```

The build uses a fixed directory, `-trimpath` and an empty build id, two independent builds give the same SHA256

## Configuration

JSON with `tls.cert_file`, `tls.key_file` and a non-empty list `listeners`, each with `listen`, `password` and `socks5.server`, `socks5.username`, `socks5.password`
Unknown fields are rejected, `-check` validates the file and the TLS files and exits, `-version` prints the version
Recommended environment `GOMEMLIMIT=16MiB GOGC=50`
