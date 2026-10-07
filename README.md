# Alpine Proxy Manager

面向 Alpine Linux 低内存 VPS 的轻量 Snell 与 sing-box 统一管理器

- 一条命令安装 中文为主的统一 TUI 管理界面 完整的命令行
- 管理 Snell 与 sing-box 两个 Core 的安装 更新 启停 卸载 并在 sing-box 上管理 AnyTLS Hysteria2 TUIC Shadowsocks 四种协议实例
- 目标访问限制 SOCKS 出口 客户端连接地址 客户端配置导出 都按实例配置 四种协议共用同一套命令
- 只管理自己安装的东西 其他方式部署的 Snell 与 sing-box 只读识别 绝不修改
- 纯 POSIX sh 与 BusyBox 工具 没有常驻的管理进程 没有额外 runtime

VLESS Reality 与 Trojan 不在支持计划内

## 支持范围

- 系统 仅 Alpine Linux 与 OpenRC 不支持 systemd 与其他发行版 自动测试在 Alpine 3.21 3.22 3.24 上运行 真实 VPS 验证过 3.21 其他版本没有验证
- 架构 x86_64 已在真实 VPS 验证 sing-box 与 Snell 的官方二进制也提供 aarch64 构建 但没有在真机验证
- Core Snell 与 sing-box 各自独立 可以只装一个 也可以都装 sing-box 默认 `v1.13.14` 同时测试了 `v1.14.2` Snell 默认 `v6.0.0rc2` 官方二进制自报 `v6.0.0`
- 协议 AnyTLS Hysteria2 TUIC Shadowsocks
- 需要 root Alpine 小 VPS 通常没有 sudo 本项目不会自动提权

## 安装

以 root 登录 Alpine VPS 后执行

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/csjcsl666/alpine-proxy-manager/main/install.sh)"
```

只需要 Alpine 自带的 `wget` 不需要 `curl` `git` 或 `sudo` 安装完成后运行 `proxy-manager` 进入管理界面 运行 `proxy-manager doctor` 检查环境

这条命令会以 root 身份执行下载到的脚本 如果希望先审查

```sh
wget -O install.sh https://raw.githubusercontent.com/csjcsl666/alpine-proxy-manager/main/install.sh
less install.sh
sh install.sh
```

固定到某个正式版本 并校验归档

```sh
APM_REF=v0.5.0 sh -c "$(wget -qO- https://raw.githubusercontent.com/csjcsl666/alpine-proxy-manager/v0.5.0/install.sh)"
```

每个 GitHub Release 都附带 `SHA256SUMS` 与源码归档 可以用 `APM_ARCHIVE_URL` 指向 Release 里的归档 并用 `APM_SHA256` 指定期望的校验和 不匹配就拒绝安装

安装脚本做的事

- 检查 Alpine root 必需的 BusyBox 工具与磁盘空间 并提示 cgroup 内存上限
- 下载源码归档 不 clone 历史 在 staging 目录解压并校验 运行语法检查与 `--version` 自检
- 安装到 `/usr/local/lib/alpine-proxy-manager/releases/<Build>` 再原子切换 `current` 链接 创建命令链接 `/usr/local/bin/proxy-manager` 再次自检 任何一步失败都回滚到原状态
- Build 取自归档里记录的 commit SHA 与实际下载的源码严格对应 取不到就拒绝安装

### 升级 Manager

再次执行同一条命令 同一 Build 且工作正常时不做任何改动 同一 `VERSION` 的新 Build 也会升级 新版本自检失败会继续使用旧版本 升级 Manager 本身不会重启 Snell 与 sing-box 不会改写任何已有配置与实例

### 卸载 Manager

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/csjcsl666/alpine-proxy-manager/main/install.sh)" -- --uninstall
```

只删除 Manager 自己 不删除 Snell sing-box `/etc/alpine-proxy-manager` 中的配置与 `/var/lib/alpine-proxy-manager` 中的数据

## 使用

### 统一 TUI

在交互式终端直接运行 `proxy-manager` 或 `proxy-manager tui`

- 主菜单 Core 管理 协议实例 目标访问限制 SOCKS 出口 客户端配置导出 状态与诊断 日志 Manager 管理 数字选择 `0` 返回 主菜单的 `0` 退出
- 界面以中文为主 协议与技术名词保持原名
- TUI 只是命令行的交互层 校验 保护与事务与命令行完全一致 现有部署只提供只读入口 不显示启动 停止 更新 卸载
- 密码 密钥 PSK 输入时不回显 无论正常结束 失败还是 Ctrl+C 都会恢复终端 秘密经标准输入交给业务函数 不出现在进程参数里
- 删除实例 删除 Profile 卸载 批量禁用 以及任何会显示客户端凭据的操作都需要确认 默认是 N
- 没有外部依赖 没有常驻进程 进入时不联网 不检查更新 `NO_COLOR` 与 `TERM=dumb` 退化为纯文本 终端不是 UTF-8 时状态符号改用 `[RUNNING]` 等文本
- 不是 root 时只能查看 写操作会提示需要 root
- 在脚本或管道中运行 `proxy-manager` 不会进入 TUI 仍然输出帮助 所有命令行用法保持不变

### 命令行

`proxy-manager help` 列出全部命令 常用的

```sh
proxy-manager doctor                     # 只读环境检查
proxy-manager status                     # Core 状态与功能配置状态
proxy-manager core list                  # 发现 Core 并显示来源与管理状态
proxy-manager --version
```

## Managed 与现有部署

Manager 安装的 Snell 与 sing-box 称为 Managed 由 Manager 完整管理 其他方式部署的 例如 apk 安装 第三方脚本安装 称为现有部署 只读识别 绝不修改

- 归属只由 Manager 自己写下的元数据证明 路径看起来像并不算 没有元数据 元数据损坏 或二进制不是已确认的 ELF 一律按现有部署处理 所有写操作都会拒绝 TUI 也不会提供入口
- Core 发现只执行已确认为 ELF 的二进制 脚本与指向脚本的符号链接不会被执行 运行状态以 OpenRC 为准
- 不支持接管 adopt 与迁移 migrate 现有部署需要自行处理

## Snell

```sh
proxy-manager snell install              # 下载官方 release 安装并启动 随机端口 自动生成 PSK
proxy-manager snell install --port 20000 --psk-stdin
proxy-manager snell status | info | log [N]
proxy-manager snell start | stop | restart
proxy-manager snell config               # 显示配置 PSK 脱敏
proxy-manager snell config set listen 0.0.0.0:20001
proxy-manager snell config set psk --generate
proxy-manager snell update [标签] [--force]
proxy-manager snell uninstall            # 保留配置与日志
proxy-manager snell uninstall --purge    # 同时删除配置 日志与由 Manager 创建的用户
```

- 布局 二进制 `/usr/local/bin/snell-server` 配置 `/etc/snell/snell-server.conf` OpenRC `/etc/init.d/snell` 日志 `/var/log/snell/` 元数据 `/var/lib/alpine-proxy-manager/cores/snell.meta`
- 运行依赖 `gcompat` `libstdc++` `libgcc` 只在 `snell install` 时通过 apk 安装缺失的包
- 精确 release 记录在 Manager 元数据里 不从二进制自报的版本推断
- 安装 配置修改与更新都是事务式的 失败回滚到之前的状态并恢复服务
- PSK 通过 `--psk-stdin` 或 `--stdin` 提供 不接受命令行明文 自动生成的 PSK 在生成时显示一次 之后需要时用 `snell export secret` 显式查看

## sing-box

```sh
proxy-manager sing-box install           # 下载官方 musl release 安装并启动 默认 v1.13.14
proxy-manager sing-box status | info | log [N] | check
proxy-manager sing-box start | stop | restart
proxy-manager sing-box update [标签] [--force]
proxy-manager sing-box uninstall [--purge]
```

- 默认 release 固定为 `v1.13.14` 不会自动取 latest 内置了该 release 的 sha256 其他 release 通过发布页的资产 digest 校验 都取不到就拒绝安装 选择 1.13.14 的依据是同一份 AnyTLS 配置空闲内存实测明显低于更新的 1.14.2
- 使用官方 musl 构建 压缩包约 24 MB 解压后的二进制约 68 MB 只解压 sing-box 一个文件并立即删除压缩包 磁盘上至少需要 256 MiB 空闲
- 布局 二进制 `/usr/local/bin/sing-box` 配置 `/etc/sing-box/config.json` 证书 `/etc/sing-box/tls/` OpenRC `/etc/init.d/sing-box` 日志 `/var/log/sing-box/` 实例定义 `/etc/alpine-proxy-manager/instances/`
- 配置由实例生成 请使用 `add` `set` 等命令或 TUI 不要手工编辑 `config.json` 每次变更都经官方 `sing-box check` 通过后才原子替换并重启 失败会恢复旧配置与服务
- 更新前先用新二进制对当前配置执行 check 不兼容就拒绝升级 新版本启动失败会回滚旧二进制 服务以专用用户 `sing-box` 运行 监听端口需要 1025 以上

### 协议实例

```sh
proxy-manager sing-box add anytls|hysteria2|tuic|shadowsocks [--name ID] [--port 端口 | --listen 地址] [--password-stdin]
proxy-manager sing-box add anytls|hysteria2|tuic [--server-name 名称]
proxy-manager sing-box add tuic [--uuid UUID] [--congestion-control cubic|new_reno|bbr]
proxy-manager sing-box add shadowsocks [--method 方法]
proxy-manager sing-box list | show ID
proxy-manager sing-box enable ID | disable ID | delete ID
proxy-manager sing-box set ID port|listen|server-name|congestion-control 值
proxy-manager sing-box set ID uuid UUID | --generate
proxy-manager sing-box set ID password --stdin | --generate
proxy-manager sing-box set ID method 方法 [--stdin | --generate]
```

- 实例以 ID 命名 例如 AnyTLS-01 AnyTLS-02 Hysteria2-01 每个实例有自己的端口与凭据
- 端口冲突按 协议 地址 端口 判断 AnyTLS 使用 TCP Hysteria2 与 TUIC 使用 UDP Shadowsocks 同时使用 TCP 与 UDP 任何一个传输层冲突都会整体拒绝
- TUIC 的凭据是 UUID 加密码 Shadowsocks 的凭据是 method 加密钥 默认 `2022-blake3-aes-128-gcm` 可选 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305 aes-128-gcm aes-256-gcm chacha20-ietf-poly1305 2022 系列要求 base64 编码的 16 或 32 字节密钥
- 自动生成的密码在生成时显示一次 之后需要时用 `export ID secret` 显式查看 `show` 与 `list` 只显示已配置
- `show` 只报告系统内部的监听状态 不代表公网可达

## 目标访问限制

按实例控制通过该实例入站的客户端允许访问哪些目标 IP 与端口

```sh
proxy-manager sing-box access ID [show]
proxy-manager sing-box access ID unrestricted | allowlist | clear
proxy-manager sing-box access ID add 地址 端口
proxy-manager sing-box access ID delete 地址 端口
```

- 默认不限制 没有设置过的实例不会生成任何限制规则
- `allowlist` 只放行明确列出的目标 其他一律拒绝 列表为空时拒绝全部 不会退回不限制 限制配置无效时整体拒绝生成配置 不会悄悄变成不限制
- 第一版只支持 IPv4 与 IPv6 加端口 不支持域名 CIDR 与端口范围 目标完全由你指定 没有任何内置地址
- 规则只按入站实例匹配 限制一个实例不影响其他实例
- 目标访问限制是服务端策略 不会出现在客户端导出里

## SOCKS 出口

让一个实例显式选择出口 DIRECT 或某个 SOCKS5 Profile 此时 sing-box 自己是 SOCKS5 客户端

```sh
printf '%s\n' "$SOCKS_PASSWORD" | proxy-manager sing-box socks add --server 192.0.2.10 --port 1080 --username user --password-stdin
proxy-manager sing-box socks add --server 地址 --port 端口 --no-auth [--name 名称]
proxy-manager sing-box socks list | show 名称
proxy-manager sing-box socks set 名称 server 地址 | port 端口 | no-auth
proxy-manager sing-box socks set 名称 credential 用户名 --password-stdin | password --password-stdin
proxy-manager sing-box socks enable 名称... | disable 名称... | enable-all | disable-all
proxy-manager sing-box socks delete 名称
proxy-manager sing-box egress ID [show] | direct | socks 名称
```

- 它与目标访问限制不是同一个功能 目标访问限制决定可以访问哪些目标 SOCKS 出口决定允许之后从哪里出去 两者可以同时使用 允许的目标会走该实例的出口 不会绕过 SOCKS
- 一个 Profile 可以被多个实例共享 没有绑定就是 DIRECT 升级 Manager 不会改动现有实例
- 只支持 SOCKS5 的 IPv4 与 IPv6 地址 不支持域名 认证只有无认证与用户名加密码 密码通过 `--password-stdin` 提供 不接受命令行明文
- Profile 被禁用 不存在 损坏 或 SOCKS 服务器不可达 认证失败 都不会回落 DIRECT 流量会失败 不自动切换 不负载均衡 不故障转移
- 删除仍被实例引用的 Profile 会被拒绝并列出引用者 批量启用与禁用一次命令最多重启一次
- 配置有效不代表 SOCKS 服务器可用 Manager 只报告配置已应用

## 客户端连接地址与配置导出

### 客户端连接地址 Public Endpoint

```sh
proxy-manager sing-box endpoint ID [show] | set 主机 端口 | clear
proxy-manager snell endpoint [show] | set 主机 端口 | clear
```

- 内部监听地址与端口不等于客户端实际连接的地址 例如 NAT VPS 的内部端口与服务商映射的公网端口往往不同 Public Endpoint 只记录客户端应该连哪里 支持 IPv4 IPv6 与主机名
- Manager 不配置服务商的 NAT 与端口映射 不修改防火墙 不自动探测公网 IP 也不判断公网是否真的可达 这些需要你自己在服务商面板处理
- 没有设置时 导出会拒绝 不会把 0.0.0.0 或 127.0.0.1 导出给客户端 修改它不生成运行配置 不重启服务

### 导出

```sh
proxy-manager sing-box export ID show                 # 连接信息 不含凭据
proxy-manager sing-box export ID secret               # 显式查看凭据
proxy-manager sing-box export ID sing-box [--redacted] [--embed-cert] > client.json
proxy-manager sing-box export ID url
proxy-manager sing-box export ID qr
proxy-manager snell export show | secret
```

- `sing-box` 生成可直接运行的 sing-box 客户端配置 含一个本机 `127.0.0.1:2080` 的 mixed 入站 `--redacted` 把凭据替换为 REDACTED 用于展示
- `url` 只提供有明确依据的分享链接 AnyTLS 与 Hysteria2 遵循各自官方的 URI Scheme Shadowsocks 遵循 SIP002 与 SIP022 TUIC 与 Snell 没有稳定的通用 URI 不提供链接 TUIC 请使用 sing-box 客户端配置
- `qr` 在终端显示分享链接的二维码 需要可选的 `qrencode` 包 `apk add libqrencode-tools` Manager 不会自动安装 链接通过标准输入传给它 不出现在进程参数里
- 包含凭据的输出会在 stderr 打印警告 stdout 只有内容 不写临时文件 不写日志
- 导出不包含 SOCKS 出口凭据 目标访问限制 TLS 私钥与其他实例的凭据 切换 SOCKS 出口与目标访问限制不改变导出的内容

### 自签名 TLS 策略

AnyTLS Hysteria2 TUIC 使用 Manager 生成的自签名证书 客户端默认跳过证书校验 这是有意的低维护设计 不需要域名 不需要申请与续期证书

- 导出的 sing-box 配置默认写 `insecure` 并设置 server name
- 需要时可以用 `--embed-cert` 把服务端证书嵌入客户端配置做证书固定校验 这是可选项
- 本版本不包含 ACME 与域名证书

## 更新 卸载 与保留的数据

- 更新 Core `proxy-manager snell update` 与 `proxy-manager sing-box update` 更新前会校验 失败回滚旧版本 更新 Manager 见上文
- 卸载 Core 默认保留配置 证书 日志 实例与 SOCKS Profile 重新安装会沿用 `--purge` 才会删除 并且只删除由 Manager 创建的内容 现有部署的任何内容都不会被删除
- 备份 每次配置变更都会在 `/var/lib/alpine-proxy-manager/backups/` 保留最近 2 份 目录 0700 文件 0600 其中包含凭据
- 数据位置 `/etc/alpine-proxy-manager/` 实例 SOCKS Profile 客户端连接地址 `/var/lib/alpine-proxy-manager/` 元数据与备份 配置文件权限 0600 目录 0700

## 限制与边界

- 内存 64 MiB 是 Manager 与安装流程的资源基线 不代表 sing-box 在 64 MiB 内能长期稳定运行 sing-box 的内存取决于版本 协议和连接数 在 128 MB cgroup 的真实 VPS 上 Snell 加 sing-box 四个实例的整体内存约 40 MB
- 不提供公网可用性监控与 uptime 探测 服务器自己无法判断来自公网却没有到达它的连接 外部可达性需要独立的观察点 请使用专用的监控工具
- 日志不自动轮转 sing-box 默认 warn 级别只记录错误 单行约 150 字节 `proxy-manager sing-box info` 会显示日志大小 长期无人维护的机器可以自行配置 logrotate 日志可能包含访问的目标 请不要公开
- 写操作 安装 更新 配置变更 开始后会忽略 Ctrl+C 断开 SSH 与 TERM 信号 避免留下半装的 Core 或与实例不一致的配置 所以中途关闭 SSH 窗口是安全的 命令会照常完成 只有下载阶段可以中断 如果某个写命令真的卡住 例如服务一直不响应 请在另一个终端用 `kill -9 进程号` 结束它 残留的锁会在下一次命令时自动清理
- 公网可达性 NAT 与防火墙 Manager 不管理也没有验证
- Hysteria2 的带宽 混淆 masquerade 等可选参数 TUIC 的可选调优参数 Shadowsocks 多用户 没有实现
- 不包含 ACME 域名证书 Web 界面 自动 failover 负载均衡 域名形式的目标访问限制与 SOCKS 服务器

## 安全提醒

- 配置文件中保存代理凭据 目录权限 0700 文件权限 0600 请勿在 Issue 或日志中公开密码 PSK Token 或服务器地址
- 所有凭据只通过标准输入传入 不经过命令行参数 不写入 shell 历史
- 服务以专用的非 root 用户运行 Manager 部署的二进制属主是 root
- Manager 不修改防火墙 路由 sysctl 与服务商网络

## 开发

从本地源码目录安装 Build 取自该目录的 git HEAD 有未提交修改时带 `-dirty` 后缀

```sh
git clone https://github.com/csjcsl666/alpine-proxy-manager.git
cd alpine-proxy-manager
sh install.sh --from-dir .
sh tests/run.sh
```

CI 在 Alpine 3.21 3.22 与 3.24 容器内运行 `sh -n` shellcheck 与全部测试 并用官方 Snell 与 sing-box 二进制做真实流量测试 包括服务端到导出的客户端配置再到官方 sing-box 客户端的完整链路 测试通过 `APM_ROOT` 隔离到临时目录 不会写入真实的 `/usr/local`
