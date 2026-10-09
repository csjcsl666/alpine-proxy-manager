#!/bin/sh
# Snell 网络功能的 CI 端到端测试, 在 Alpine 容器里运行
#   docker run --rm --cap-add SYS_PTRACE --cap-add SYS_ADMIN --security-opt seccomp=unconfined \
#     --security-opt apparmor=unconfined -v "$PWD:/src:ro" alpine:3.24 sh /src/tests/e2e/ci-net.sh
# 做的事
#   1 从 third_party/graftcp 的补丁和上游标签构建 graftcp (与发布的二进制同一个构建脚本)
#   2 下载官方 Snell v6 (由 proxy-manager 安装) 与官方 sing-box 1.14.2 (只作客户端与上游), 核对 sha256
#   3 真实 OpenRC 与 supervise-daemon, 依次运行 net_access.sh 与 net_egress.sh
# 其中包含原先的回环绕过回归: 空名单加 127.0.0.53 上的通配 TCP UDP 服务, 目标必须零命中
# shellcheck disable=SC2086,SC2015 # 测试脚本里 A && B || C 用来记录通过或失败
set -eu

SRC=${SRC:-/src}
W=/tmp/apm-ci-net
mkdir -p "$W/out" "$W/dl" /srv/dl

apk add --no-cache openssl openrc python3 gcompat libstdc++ libgcc unzip wget tinyproxy unbound git go gcc musl-dev make linux-headers patch >/dev/null

echo '== 构建补丁版 graftcp'
sh "$SRC/third_party/graftcp/build-inner.sh" "$W/out"
GC=$W/out/graftcp-v0.8.3-apm1-linux-x86_64
cp "$GC" /srv/dl/
GC_SHA=$(awk '{ print $1 }' "$GC.sha256")
echo "graftcp sha256 $GC_SHA"

echo '== 构建 AnyTLS Gateway'
sh "$SRC/third_party/anytls-gateway/build-inner.sh" "$W/gwout"
GW_BIN=$W/gwout/anytls-socks-gateway-v0.1.0-linux-x86_64
echo "gateway sha256 $(awk '{ print $1 }' "$GW_BIN.sha256")"

echo '== 下载官方 sing-box 1.14.2'
SB_SHA=8f6cb4bcf94d2b33c65d52e0d5b142db29a938336f1ff7267f397ac3758fc297
n=1
while [ "$n" -le 3 ]; do
    wget -q -T 60 -O "$W/sb.tgz" "https://github.com/SagerNet/sing-box/releases/download/v1.14.2/sing-box-1.14.2-linux-amd64-musl.tar.gz" && [ -s "$W/sb.tgz" ] && break
    n=$((n + 1)); sleep 3
done
[ "$(sha256sum "$W/sb.tgz" | awk '{ print $1 }')" = "$SB_SHA" ] || { echo "sing-box sha256 不匹配" >&2; exit 1; }
tar -xzf "$W/sb.tgz" -C "$W" sing-box-1.14.2-linux-amd64-musl/sing-box
SB_BIN=/usr/local/bin/sing-box-official
cp "$W/sing-box-1.14.2-linux-amd64-musl/sing-box" "$SB_BIN"
chmod 755 "$SB_BIN"
"$SB_BIN" version | head -n 1

echo '== 环境: OpenRC, 回环, 本地下载源'
# 容器里没有 init: 让 OpenRC 认为已经在某个运行级别, 并用空实现代替会改主机名和网络的 networking
mkdir -p /run/openrc
touch /run/openrc/softlevel
cat > /etc/init.d/networking <<'EOF'
#!/sbin/openrc-run
start() { return 0; }
stop() { return 0; }
EOF
chmod 755 /etc/init.d/networking
ip link set lo up 2>/dev/null || true
(cd /srv/dl && python3 -m http.server 8099 --bind 127.0.0.1 >/dev/null 2>&1 &)
sleep 1

echo '== 安装 Manager 与官方 Snell v6'
mkdir -p /usr/local/lib/alpine-proxy-manager
cp -r "$SRC" /usr/local/lib/alpine-proxy-manager/current
ln -sf /usr/local/lib/alpine-proxy-manager/current/bin/proxy-manager /usr/local/bin/proxy-manager
printf 'FakePskNotSecret0123456789abcdefgh\n' | proxy-manager snell install --port 8388 --psk-stdin
rc-service snell status

export APM_SNN_URL=http://127.0.0.1:8099/graftcp-v0.8.3-apm1-linux-x86_64
export APM_SNN_SHA256=$GC_SHA
export SB_BIN
export E2E_DIR=$W/run
rc=0
echo "== gw_behavior.sh"
GW_BIN=$GW_BIN sh "$SRC/tests/e2e/gw_behavior.sh" || rc=1
for s in net_access.sh net_egress.sh; do
    echo "== $s"
    sh "$SRC/tests/e2e/$s" || rc=1
done
exit "$rc"
