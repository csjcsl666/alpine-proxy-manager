#!/bin/sh
# 官方 sing-box release 上的 Client Export 真实客户端验证, 需要网络, 在 Alpine 容器内运行
# 链路: Manager 生成的服务端配置 -> 官方 sing-box 服务端 -> Manager 导出的 sing-box 客户端 JSON -> 官方 sing-box 客户端 -> 目标
# 覆盖 AnyTLS Hysteria2 TUIC 与三种 Shadowsocks (2022 128 位, 2022 256 位, 传统 AEAD)
# Public Endpoint 与内部监听端口不同, 中间由一个 sing-box direct 入站转发, 只模拟 NAT 的端口映射, 不改动任何系统网络
# 负面对照: 错误密码, 去掉 insecure (自签名证书必须被拒绝), 以及导出时嵌入证书代替 insecure 能正常验证并连接
# 全部在 127.0.0.1 上完成, 不开放任何公网端口, 不属于 tests/run.sh
set -eu

VER=${1:-1.13.14}
HERE=$(cd "$(dirname "$0")" && pwd)
case "$VER/$(uname -m)" in
    1.13.14/x86_64) SHA=d5b46de6498427bccfeb87dbafcde4dbefdfe35680020d07d286ad915f0bfb34; ARCH=amd64 ;;
    1.13.14/aarch64) SHA=edec18488af35a93cf8b362063146fdd7b557ef9862710ee77a1f4adb5c70118; ARCH=arm64 ;;
    1.14.2/x86_64) SHA=8f6cb4bcf94d2b33c65d52e0d5b142db29a938336f1ff7267f397ac3758fc297; ARCH=amd64 ;;
    *) echo "没有内置的校验和: $VER $(uname -m)" >&2; exit 1 ;;
esac
ASSET="sing-box-$VER-linux-$ARCH-musl.tar.gz"
URL="https://github.com/SagerNet/sing-box/releases/download/v$VER/$ASSET"
W=$(mktemp -d)
PIDS=
CPID=
cleanup() {
    local p
    for p in $PIDS $CPID; do kill "$p" 2>/dev/null; done
    rm -rf "$W"
}
trap cleanup EXIT

if [ -n "${SMOKE_SB:-}" ]; then
    B=$SMOKE_SB
else
    n=1
    while [ "$n" -le 3 ]; do
        if wget -q -T 60 -O "$W/sb.tgz" "$URL" && [ -s "$W/sb.tgz" ]; then break; fi
        n=$((n + 1))
        sleep 3
    done
    [ -s "$W/sb.tgz" ] || { echo "下载失败: $URL" >&2; exit 1; }
    [ "$(sha256sum "$W/sb.tgz" | awk '{ print $1 }')" = "$SHA" ] || { echo "sha256 不匹配" >&2; exit 1; }
    tar -xzf "$W/sb.tgz" -C "$W" "sing-box-$VER-linux-$ARCH-musl/sing-box"
    rm -f "$W/sb.tgz"
    B="$W/sing-box-$VER-linux-$ARCH-musl/sing-box"
    chmod 755 "$B"
fi
"$B" version | head -n 1 | grep -q "sing-box version $VER" || { echo "自报版本不符" >&2; exit 1; }

"$B" generate tls-keypair apm.local -m 12 > "$W/kp.pem"
awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' "$W/kp.pem" > "$W/key.pem"
awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$W/kp.pem" > "$W/cert.pem"

APM_HOME=$(dirname "$HERE")
export APM_HOME
for m in common environment state core model policy txn report client snell singbox; do
    # shellcheck source=/dev/null
    . "$APM_HOME/lib/$m.sh"
done

TA=24001
UUID=11111111-2222-4333-8444-555555555555
PSK=SmokeClientPasswordNotSecret01234
K16=AAAAAAAAAAAAAAAAAAAAAA==
K32=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
mkdir -p "$W/inst"

# 实例 内部端口 -> 公共端口 (转发), 主机名与 IPv4 各有
i=0
: > "$W/map"
mkinst() { # ID TYPE EXTRA...
    local id t port pub host
    id=$1; t=$2; shift 2
    i=$((i + 1))
    port=$((22000 + i))
    pub=$((32000 + i))
    host=127.0.0.1
    [ "$id" != AnyTLS-01 ] || host=localhost
    {
        printf 'id=%s\nname=%s\ntype=%s\nenabled=true\nlisten=127.0.0.1\nlisten_port=%s\n' "$id" "$id" "$t" "$port"
        printf 'public.host=%s\npublic.port=%s\n' "$host" "$pub"
        printf '%s\n' "$@"
        if [ "$t" != shadowsocks ]; then
            printf 'tls.mode=self-signed\ntls.server_name=apm.local\ntls.certificate_path=%s\ntls.key_path=%s\n' "$W/cert.pem" "$W/key.pem"
        fi
    } > "$W/inst/$id.conf"
    printf '%s %s %s\n' "$id" "$port" "$pub" >> "$W/map"
}
mkinst AnyTLS-01 anytls "credential.password=$PSK"
mkinst Hysteria2-01 hysteria2 "credential.password=$PSK"
mkinst TUIC-01 tuic "credential.uuid=$UUID" "credential.password=$PSK" "transport.congestion_control=bbr"
mkinst Shadowsocks-01 shadowsocks "credential.method=2022-blake3-aes-128-gcm" "credential.password=$K16" "transport.type=tcp+udp"
mkinst Shadowsocks-02 shadowsocks "credential.method=2022-blake3-aes-256-gcm" "credential.password=$K32" "transport.type=tcp+udp"
mkinst Shadowsocks-03 shadowsocks "credential.method=aes-256-gcm" "credential.password=$PSK" "transport.type=tcp+udp"
for f in "$W"/inst/*.conf; do
    sb_instance_validate "$f" || { echo "实例无效: $f" >&2; exit 1; }
done

sb_generate_config "$W/inst" > "$W/server.json"
"$B" check -c "$W/server.json"
echo "Manager 生成的服务端配置 check 通过 $VER"

# NAT 端口映射模拟: 公共端口 -> 内部端口, 只在 127.0.0.1 上, 同时转发 TCP 与 UDP
{
    printf '{"log":{"level":"error"},"inbounds":['
    sep=
    while read -r id port pub; do
        printf '%s{"type":"direct","tag":"fw-%s","listen":"127.0.0.1","listen_port":%s,"override_address":"127.0.0.1","override_port":%s}' "$sep" "$id" "$pub" "$port"
        sep=,
    done < "$W/map"
    printf '],"outbounds":[{"type":"direct","tag":"direct"}]}\n'
} > "$W/fw.json"
"$B" check -c "$W/fw.json"

: > "$W/hitA"
cat > "$W/hA.sh" <<EOH
#!/bin/sh
read -r l
printf '%s\n' "\$l" >> "$W/hitA"
printf 'HTTP/1.0 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\nTARGET_A\n'
EOH
chmod 755 "$W/hA.sh"
nc -lk -p "$TA" -s 127.0.0.1 -e "$W/hA.sh" > /dev/null 2>&1 &
PIDS="$!"
"$B" run -c "$W/server.json" > "$W/server.log" 2>&1 &
PIDS="$PIDS $!"
"$B" run -c "$W/fw.json" > "$W/fw.log" 2>&1 &
PIDS="$PIDS $!"
sleep 4

fail=0
# 经客户端的 mixed 入站 (HTTP 代理) 请求目标 A, 带唯一标记
probe() { # 标记
    http_proxy="http://127.0.0.1:2080" timeout 15 wget -q -T 12 -O - "http://127.0.0.1:$TA/$1" 2>/dev/null || true
}
start_client() { # JSON
    "$B" run -c "$1" > "$W/client.log" 2>&1 &
    CPID=$!
    local n
    n=0
    while [ "$n" -lt 20 ]; do
        nc -z 127.0.0.1 2080 2>/dev/null && return 0
        sleep 1
        n=$((n + 1))
    done
    return 1
}
stop_client() {
    kill "$CPID" 2>/dev/null || true
    sleep 1
    CPID=
}
hits() { grep -c "$1" "$W/hitA" || true; }
run_case() { # 名称 JSON ok|fail 说明
    local got h
    "$B" check -c "$2" || { echo "FAIL $1 客户端配置 check 失败: $4"; fail=1; return; }
    start_client "$2" || { echo "FAIL $1 客户端没有启动: $4"; fail=1; stop_client; return; }
    got=$(probe "P-$1-$$")
    h=$(hits "P-$1-$$")
    stop_client
    if [ "$3" = ok ]; then
        if [ "$got" = TARGET_A ] && [ "$h" -ge 1 ]; then echo "PASS $1 $4"; else echo "FAIL $1 期望成功 实际 [$got] 目标收到 $h 次: $4"; fail=1; fi
    else
        if [ -z "$got" ] && [ "$h" -eq 0 ]; then echo "PASS $1 $4"; else echo "FAIL $1 期望失败 实际 [$got] 目标收到 $h 次: $4"; fail=1; fi
    fi
}

export_json() { # ID 额外参数... > 输出文件
    local id
    id=$1; shift
    _cx_load_sb "$W/inst/$id.conf" || return 1
    case ${1:-} in
        embed) _cx_r_singbox no yes ;;
        *) _cx_r_singbox no no ;;
    esac
}

while read -r id port pub; do
    export_json "$id" > "$W/c-$id.json"
    run_case "$id" "$W/c-$id.json" ok "导出的配置连接成功 (公共端口 $pub 转发到内部端口 $port)"
    case $id in
        AnyTLS-01|Hysteria2-01|TUIC-01)
            export_json "$id" embed > "$W/e-$id.json"
            grep -q insecure "$W/e-$id.json" && { echo "FAIL $id 嵌入证书的配置仍含 insecure"; fail=1; }
            run_case "$id-embed" "$W/e-$id.json" ok "嵌入证书并校验服务端证书 (没有 insecure)"
            grep -v '"insecure"' "$W/c-$id.json" | sed 's/"server_name": "apm.local",\{0,1\}/"server_name": "apm.local"/' > "$W/n-$id.json"
            run_case "$id-noinsecure" "$W/n-$id.json" fail "自签名证书在没有 insecure 也没有嵌入证书时必须被拒绝"
            ;;
    esac
    # 错误密码对照: 把密码或密钥的第一个字符换掉, 仍然是有效格式
    pw=$(sed -n 's/^ *"password": "\(.*\)",\{0,1\}$/\1/p' "$W/c-$id.json" | head -n 1)
    first=$(printf '%s' "$pw" | cut -c1)
    [ "$first" = A ] && alt=B || alt=A
    wrong="$alt$(printf '%s' "$pw" | cut -c2-)"
    sed "s|\"password\": \"$pw\"|\"password\": \"$wrong\"|" "$W/c-$id.json" > "$W/w-$id.json"
    run_case "$id-wrongpw" "$W/w-$id.json" fail "错误凭据必须被拒绝"
done < "$W/map"

# 导出不得含服务端私钥与路径
for f in "$W"/c-*.json "$W"/e-*.json; do
    if grep -q 'PRIVATE KEY\|key.pem' "$f"; then echo "FAIL $f 含有私钥信息"; fail=1; fi
done
# 服务端与转发日志没有泄漏凭据到日志以外的位置不检查, 只确认客户端日志不含密码
if grep -q "$PSK" "$W/client.log" 2>/dev/null; then echo "FAIL 客户端日志泄漏了密码"; fail=1; fi

kill -0 "$(echo "$PIDS" | awk '{ print $2 }')" 2>/dev/null || { echo "FAIL sing-box 服务端进程已退出"; fail=1; }
if [ "$fail" -eq 0 ]; then echo "全部通过 sing-box $VER"; else echo "存在失败"; exit 1; fi
