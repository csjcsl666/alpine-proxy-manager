#!/bin/sh
# 临时诊断: 最小复现 tinyproxy 读取配置失败, 在 Alpine 容器内运行, 不含任何凭据
set -u
apk add --no-cache tinyproxy strace >/dev/null 2>&1
TP=$(command -v tinyproxy)
echo "tinyproxy=$TP sha256=$(sha256sum "$TP" | cut -c1-16) ver=$(tinyproxy -v 2>&1)"
echo "self attr: $(cat /proc/self/attr/current 2>&1) | apparmor: $(cat /proc/self/attr/apparmor/current 2>&1)"
mkdir -p /run/t /etc/tinyproxy
printf 'Port 18888\nListen 127.0.0.1\nUser nobody\nGroup nobody\n' > /run/t/tp.conf
cp /run/t/tp.conf /tmp/tp.conf; cp /run/t/tp.conf /etc/tinyproxy/tinyproxy.conf
chmod 644 /run/t/tp.conf /tmp/tp.conf /etc/tinyproxy/tinyproxy.conf
try() { # 说明 命令...
    _d=$1; shift
    _o=$(timeout 2 "$@" 2>&1 | head -3 | tr '\n' ' ')
    case $_o in *"Could not open"*) _r=FAIL ;; *) _r=OK ;; esac
    echo "[$_r] $_d :: $_o" | cut -c1-220
}
try "原路径 /run/t" "$TP" -d -c /run/t/tp.conf
try "/tmp" "$TP" -d -c /tmp/tp.conf
try "/etc/tinyproxy (包默认位置)" "$TP" -d -c /etc/tinyproxy/tinyproxy.conf
cp "$TP" /tmp/tinyproxy-copy
try "二进制复制到 /tmp/tinyproxy-copy 读 /run/t" /tmp/tinyproxy-copy -d -c /run/t/tp.conf
ln -sf "$TP" /tmp/tp-link
try "符号链接 /tmp/tp-link 读 /run/t" /tmp/tp-link -d -c /run/t/tp.conf
try "经动态加载器启动 读 /run/t" /lib/ld-musl-x86_64.so.1 "$TP" -d -c /run/t/tp.conf
echo "== strace (只看文件与身份相关调用)"
timeout 2 strace -f -e trace=execve,open,openat,openat2,setuid,setgid,setgroups,capset,prctl "$TP" -d -c /run/t/tp.conf 2>&1 | grep -vE "\.so|ld-musl|/etc/ld|locale" | head -12 | cut -c1-180
echo "== 运行中 tinyproxy 进程的安全上下文 (/etc 配置可以启动时)"
"$TP" -d -c /etc/tinyproxy/tinyproxy.conf >/dev/null 2>&1 &
sleep 1
P=$(pidof tinyproxy | cut -d' ' -f1)
[ -n "$P" ] && echo "pid=$P attr=$(cat /proc/$P/attr/current 2>&1) | $(grep -E '^(Uid|Gid|Groups|CapEff|NoNewPrivs|Seccomp):' /proc/$P/status | tr '\n' ' ' | tr -s '\t ' ' ')"
kill $P 2>/dev/null
sleep 1
"$TP" -d -c /run/t/tp.conf >/dev/null 2>&1 &
P2=$!
echo "pid(失败路径)=$P2 attr=$(cat /proc/$P2/attr/current 2>&1)"
wait
exit 0
