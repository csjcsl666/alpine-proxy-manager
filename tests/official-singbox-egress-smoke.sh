#!/bin/sh
# 官方 sing-box release 上的 Server SOCKS Egress 真实流量验证, 需要网络, 在 Alpine 容器内运行
# 用 Manager 自己的生成器为四种协议各生成四个实例:
#   01 绑定带认证的 SOCKS Profile    02 绑定带认证的 SOCKS Profile 并只允许目标 A
#   03 DIRECT                        04 绑定无认证的 SOCKS Profile
# 真实运行官方 sing-box 服务端, 两个独立的临时 SOCKS5 服务器 (一个带认证, 一个无认证) 与目标 A 和 B,
# 再用第二个 sing-box 作为客户端经每个入站连接目标, 并用 SOCKS 服务器自己的日志证明流量确实经过它
# 然后验证 认证错误 Profile 被禁用 SOCKS 服务器停止 三种故障下都不会回落 DIRECT 目标不会收到任何请求
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
SRVPID=
SOCKSPID=
cleanup() {
    local p
    for p in $PIDS $SRVPID $SOCKSPID; do kill "$p" 2>/dev/null; done
    rm -rf "$W"
}
trap cleanup EXIT

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
"$B" version | head -n 1 | grep -q "sing-box version $VER" || { echo "自报版本不符" >&2; exit 1; }

"$B" generate tls-keypair apm.local -m 12 > "$W/kp.pem"
awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' "$W/kp.pem" > "$W/key.pem"
awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$W/kp.pem" > "$W/cert.pem"

APM_HOME=$(dirname "$HERE")
export APM_HOME
for m in common environment state core model policy txn report snell singbox; do
    # shellcheck source=/dev/null
    . "$APM_HOME/lib/$m.sh"
done

TA=24001
TB=24002
SOCKS_AUTH=26001
SOCKS_NOAUTH=26002
SUSER=smokeuser
SPASS=SmokeSocksPasswordNotSecret0123
UUID=11111111-2222-4333-8444-555555555555
PSK=SmokeEgressPasswordNotSecret012345
K16=AAAAAAAAAAAAAAAAAAAAAA==
mkdir -p "$W/inst" "$W/inst.socks"
for pf in "SOCKS-01 $SOCKS_AUTH $SUSER $SPASS" "SOCKS-02 $SOCKS_NOAUTH"; do
    # shellcheck disable=SC2086
    set -- $pf
    {
        printf 'name=%s\nhost=127.0.0.1\nport=%s\nenabled=true\n' "$1" "$2"
        if [ -n "${3:-}" ]; then printf 'username=%s\npassword=%s\n' "$3" "$4"; fi
    } > "$W/inst.socks/$1.conf"
done

port=22000
cport=23000
: > "$W/cli.in"
: > "$W/cli.out"
: > "$W/cli.rt"
: > "$W/map"
for t in anytls hysteria2 tuic shadowsocks; do
    case $t in anytls) P=AnyTLS ;; hysteria2) P=Hysteria2 ;; tuic) P=TUIC ;; shadowsocks) P=Shadowsocks ;; esac
    for k in 01 02 03 04; do
        id=$P-$k
        port=$((port + 1))
        {
            printf 'id=%s\nname=%s\ntype=%s\nenabled=true\nlisten=127.0.0.1\nlisten_port=%s\n' "$id" "$id" "$t" "$port"
            case $t in
                tuic) printf 'credential.uuid=%s\ncredential.password=%s\n' "$UUID" "$PSK" ;;
                shadowsocks) printf 'credential.method=2022-blake3-aes-128-gcm\ncredential.password=%s\ntransport.type=tcp+udp\n' "$K16" ;;
                *) printf 'credential.password=%s\n' "$PSK" ;;
            esac
            if [ "$t" != shadowsocks ]; then
                printf 'tls.mode=self-signed\ntls.server_name=apm.local\ntls.certificate_path=%s\ntls.key_path=%s\n' "$W/cert.pem" "$W/key.pem"
            fi
            case $k in
                01) printf 'egress_socks=SOCKS-01\n' ;;
                02) printf 'egress_socks=SOCKS-01\nrelay_access.enabled=true\nrelay_access.mode=allowlist\nrelay_access.default_action=reject\nrelay_access.destination.1=127.0.0.1:%s\n' "$TA" ;;
                04) printf 'egress_socks=SOCKS-02\n' ;;
            esac
        } > "$W/inst/$id.conf"
        case $t in
            anytls) ob="{\"type\":\"anytls\",\"tag\":\"o-$id\",\"server\":\"127.0.0.1\",\"server_port\":$port,\"password\":\"$PSK\",\"tls\":{\"enabled\":true,\"insecure\":true,\"server_name\":\"apm.local\"}}" ;;
            hysteria2) ob="{\"type\":\"hysteria2\",\"tag\":\"o-$id\",\"server\":\"127.0.0.1\",\"server_port\":$port,\"password\":\"$PSK\",\"tls\":{\"enabled\":true,\"insecure\":true,\"server_name\":\"apm.local\"}}" ;;
            tuic) ob="{\"type\":\"tuic\",\"tag\":\"o-$id\",\"server\":\"127.0.0.1\",\"server_port\":$port,\"uuid\":\"$UUID\",\"password\":\"$PSK\",\"tls\":{\"enabled\":true,\"insecure\":true,\"server_name\":\"apm.local\"}}" ;;
            shadowsocks) ob="{\"type\":\"shadowsocks\",\"tag\":\"o-$id\",\"server\":\"127.0.0.1\",\"server_port\":$port,\"method\":\"2022-blake3-aes-128-gcm\",\"password\":\"$K16\"}" ;;
        esac
        printf '%s,' "$ob" >> "$W/cli.out"
        for tgt in A B; do
            cport=$((cport + 1))
            [ "$tgt" = A ] && tp=$TA || tp=$TB
            printf '{"type":"direct","tag":"i-%s-%s","listen":"127.0.0.1","listen_port":%s,"override_address":"127.0.0.1","override_port":%s},' "$id" "$tgt" "$cport" "$tp" >> "$W/cli.in"
            printf '{"inbound":["i-%s-%s"],"action":"route","outbound":"o-%s"},' "$id" "$tgt" "$id" >> "$W/cli.rt"
            printf '%s %s %s\n' "$id" "$tgt" "$cport" >> "$W/map"
        done
    done
done

gen_server() {
    sb_generate_config "$W/inst" > "$W/server.json"
    "$B" check -c "$W/server.json"
}
gen_server
grep -q '"type": "socks"' "$W/server.json" || { echo "生成的配置没有 SOCKS 出站" >&2; exit 1; }
[ "$(grep -c '"type": "socks"' "$W/server.json")" = 2 ] || { echo "SOCKS 出站数量不对" >&2; exit 1; }
echo "Manager 生成的四协议十六实例配置含两个 SOCKS 出站 check 通过 $VER"
{
    printf '{"log":{"level":"error"},"inbounds":['
    sed 's/,$//' "$W/cli.in"
    printf '],"outbounds":['
    cat "$W/cli.out"
    printf '{"type":"direct","tag":"direct"}],"route":{"rules":['
    sed 's/,$//' "$W/cli.rt"
    printf ']}}\n'
} > "$W/client.json"
"$B" check -c "$W/client.json"

# 两个独立的临时 SOCKS5 服务器, 日志级别 info 记录每个入站连接的目标
cat > "$W/socks-auth.json" <<EOC
{"log":{"level":"info"},"inbounds":[{"type":"socks","tag":"s","listen":"127.0.0.1","listen_port":$SOCKS_AUTH,"users":[{"username":"$SUSER","password":"$SPASS"}]}],"outbounds":[{"type":"direct","tag":"direct"}]}
EOC
cat > "$W/socks-noauth.json" <<EOC
{"log":{"level":"info"},"inbounds":[{"type":"socks","tag":"s","listen":"127.0.0.1","listen_port":$SOCKS_NOAUTH}],"outbounds":[{"type":"direct","tag":"direct"}]}
EOC
"$B" run -c "$W/socks-auth.json" > "$W/socks-auth.log" 2>&1 &
SOCKSPID=$!
"$B" run -c "$W/socks-noauth.json" > "$W/socks-noauth.log" 2>&1 &
PIDS="$!"

: > "$W/hitA"
: > "$W/hitB"
# 目标: 每个连接读一行请求, 记录下来, 再回应目标名, nc -lk 对每个连接 fork 一个处理脚本, 可以并发
for tg in A B; do
    cat > "$W/h$tg.sh" <<EOH
#!/bin/sh
read -r l
printf '%s\n' "\$l" >> "$W/hit$tg"
echo TARGET_$tg
EOH
    chmod 755 "$W/h$tg.sh"
done
nc -lk -p "$TA" -s 127.0.0.1 -e "$W/hA.sh" > /dev/null 2>&1 &
PIDS="$PIDS $!"
nc -lk -p "$TB" -s 127.0.0.1 -e "$W/hB.sh" > /dev/null 2>&1 &
PIDS="$PIDS $!"
sleep 1
start_server() {
    "$B" run -c "$W/server.json" > "$W/server.log" 2>&1 &
    SRVPID=$!
    sleep 3
}
start_server
"$B" run -c "$W/client.json" > "$W/client.log" 2>&1 &
PIDS="$PIDS $!"
sleep 4

fail=0
# probe 阶段: 并行对每个 实例 目标 发送带唯一标记的请求, 结果写入文件
probe_all() { # 阶段名
    rm -rf "$W/res"
    mkdir -p "$W/res"
    while read -r id tgt cp; do
        (
            got=$( (printf 'P-%s-%s-%s\n' "$id" "$tgt" "$1"; sleep 2) | nc -w 5 127.0.0.1 "$cp" 2>/dev/null | head -c 20 || true)
            printf '%s' "$got" > "$W/res/$id.$tgt"
        ) &
    done < "$W/map"
    wait_probes
    sleep 2
}
wait_probes() {
    local i
    i=0
    while [ "$i" -lt 40 ]; do
        [ "$(ls "$W/res" | wc -l | tr -d ' ')" -ge "$(wc -l < "$W/map" | tr -d ' ')" ] && return 0
        sleep 1
        i=$((i + 1))
    done
}
expect() { # 阶段 实例 目标 ok|fail 说明
    local got tag hit r
    got=$(cat "$W/res/$2.$3" 2>/dev/null || true)
    tag=TARGET_$3
    case $3 in A) hit=$(grep -c "P-$2-A-$1" "$W/hitA" || true) ;; B) hit=$(grep -c "P-$2-B-$1" "$W/hitB" || true) ;; esac
    if [ "$4" = ok ]; then
        if [ "$got" = "$tag" ] && [ "$hit" -ge 1 ]; then r=PASS; else r=FAIL; fail=1; fi
    else
        if [ -z "$got" ] && [ "$hit" -eq 0 ]; then r=PASS; else r=FAIL; fail=1; fi
    fi
    printf '%s %-16s 目标 %s 期望 %-4s 实际 [%s] 目标收到 %s 次  %s\n' "$r" "$2" "$3" "$4" "$got" "$hit" "$5"
}
sock_hits() { # 日志 目标端口
    grep -c "inbound connection to 127.0.0.1:$2" "$1" 2>/dev/null || true
}
all_ids() { for t in AnyTLS Hysteria2 TUIC Shadowsocks; do for k in 01 02 03 04; do printf '%s-%s ' "$t" "$k"; done; done; }

echo "== 阶段 1 正常"
probe_all p1
AH_A=$(sock_hits "$W/socks-auth.log" "$TA")
AH_B=$(sock_hits "$W/socks-auth.log" "$TB")
NH_A=$(sock_hits "$W/socks-noauth.log" "$TA")
NH_B=$(sock_hits "$W/socks-noauth.log" "$TB")
for t in AnyTLS Hysteria2 TUIC Shadowsocks; do
    expect p1 "$t-01" A ok "SOCKS 不限制"
    expect p1 "$t-01" B ok "SOCKS 不限制"
    expect p1 "$t-02" A ok "SOCKS 加 allowlist 的允许目标"
    expect p1 "$t-02" B fail "SOCKS 加 allowlist 的未允许目标被拒绝"
    expect p1 "$t-03" A ok "DIRECT"
    expect p1 "$t-03" B ok "DIRECT"
    expect p1 "$t-04" A ok "无认证 SOCKS"
    expect p1 "$t-04" B ok "无认证 SOCKS"
done
# 证据: 带认证的 SOCKS 服务器收到 01 与 02 的 A (4 加 4) 与 01 的 B (4), 无认证的收到 04 的 A 与 B (各 4)
echo "带认证 SOCKS 服务器收到的目标 A $AH_A 次 目标 B $AH_B 次 (期望至少 8 与 4)"
echo "无认证 SOCKS 服务器收到的目标 A $NH_A 次 目标 B $NH_B 次 (期望至少 4 与 4)"
{ [ "$AH_A" -ge 8 ] && [ "$AH_B" -ge 4 ] && [ "$NH_A" -ge 4 ] && [ "$NH_B" -ge 4 ]; } || { echo "FAIL SOCKS 服务器日志没有证明流量经过它" >&2; fail=1; }
# 02 的未允许目标 B 与 03 的 DIRECT 没有进入 SOCKS 服务器: B 在带认证服务器上只有 01 的 4 次
[ "$AH_B" -le 4 ] || { echo "FAIL 被 allowlist 拒绝的目标 B 出现在 SOCKS 服务器上" >&2; fail=1; }
grep -q "$SPASS" "$W/socks-auth.log" "$W/server.log" "$W/client.log" 2>/dev/null && { echo "FAIL 日志泄漏了 SOCKS 密码" >&2; fail=1; }

echo "== 阶段 2 认证错误"
cp "$W/inst.socks/SOCKS-01.conf" "$W/prof01.bak"
sed -i 's/^password=.*/password=WrongPasswordWrongPassword01/' "$W/inst.socks/SOCKS-01.conf"
kill "$SRVPID"; sleep 1
gen_server
start_server
BEFORE_AH=$(sock_hits "$W/socks-auth.log" "$TA")
probe_all p2
for t in AnyTLS Hysteria2 TUIC Shadowsocks; do
    expect p2 "$t-01" A fail "认证错误 不回落 DIRECT"
    expect p2 "$t-02" A fail "认证错误 不回落 DIRECT"
    expect p2 "$t-03" A ok "DIRECT 不受影响"
    expect p2 "$t-04" A ok "另一个 Profile 不受影响"
done
[ "$(sock_hits "$W/socks-auth.log" "$TA")" -eq "$BEFORE_AH" ] || { echo "FAIL 认证失败的请求仍被 SOCKS 服务器接受" >&2; fail=1; }
echo "认证错误: 服务端仍在运行 $(kill -0 "$SRVPID" 2>/dev/null && echo 是 || echo 否)"
kill -0 "$SRVPID" 2>/dev/null || { echo "FAIL sing-box 进程退出" >&2; fail=1; }

echo "== 阶段 3 Profile 被禁用 再重新启用"
cp "$W/prof01.bak" "$W/inst.socks/SOCKS-01.conf"
sed -i 's/^enabled=.*/enabled=false/' "$W/inst.socks/SOCKS-01.conf"
kill "$SRVPID"; sleep 1
gen_server
start_server
probe_all p3
for t in AnyTLS Hysteria2 TUIC Shadowsocks; do
    expect p3 "$t-01" A fail "Profile 禁用 不回落 DIRECT"
    expect p3 "$t-02" A fail "Profile 禁用 不回落 DIRECT"
    expect p3 "$t-03" A ok "DIRECT 不受影响"
done
cp "$W/prof01.bak" "$W/inst.socks/SOCKS-01.conf"
kill "$SRVPID"; sleep 1
gen_server
start_server
probe_all p3b
for t in AnyTLS Hysteria2 TUIC Shadowsocks; do
    expect p3b "$t-01" A ok "重新启用后自动恢复 绑定没有改动"
    expect p3b "$t-02" B fail "重新启用后 allowlist 仍然生效"
done

echo "== 阶段 4 SOCKS 服务器不可用"
kill "$SOCKSPID"
SOCKSPID=
sleep 1
probe_all p4
for t in AnyTLS Hysteria2 TUIC Shadowsocks; do
    expect p4 "$t-01" A fail "SOCKS 服务器停止 不回落 DIRECT"
    expect p4 "$t-02" A fail "SOCKS 服务器停止 不回落 DIRECT"
    expect p4 "$t-03" A ok "DIRECT 不受影响"
    expect p4 "$t-04" A ok "另一个 SOCKS 服务器仍可用"
done
kill -0 "$SRVPID" 2>/dev/null || { echo "FAIL sing-box 进程退出" >&2; fail=1; }

if [ "$fail" -ne 0 ]; then
    echo "--- server.log" >&2; tail -20 "$W/server.log" >&2
    echo "--- client.log" >&2; tail -20 "$W/client.log" >&2
    exit 1
fi
echo "官方 sing-box $VER Server SOCKS Egress 真实流量测试通过"
