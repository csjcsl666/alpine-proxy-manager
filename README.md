# Alpine Proxy Manager

面向 Alpine Linux 低内存 VPS 的轻量 Snell 与 sing-box 统一管理器

- 一条命令安装 中文为主的统一 TUI 管理界面 SSH 登录后输入短命令 `apm` 即可进入 完整的命令行
- 管理 Snell 与 sing-box 两个 Core 的安装 更新 启停 卸载 并在 sing-box 上管理 AnyTLS Hysteria2 TUIC Shadowsocks 四种协议实例
- 目标访问限制 SOCKS 出口 客户端连接地址 客户端配置 都按实例配置 四种协议共用同一套命令
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

以 root 登录 Alpine VPS 后执行 下面固定安装当前稳定版 `v0.9.1`

```sh
APM_REF=v0.9.1 sh -c "$(wget -qO- https://raw.githubusercontent.com/csjcsl666/alpine-proxy-manager/v0.9.1/install.sh)"
```

只需要 Alpine 自带的 `wget` 不需要 `curl` `git` 或 `sudo` 安装完成后运行 `apm` 进入管理界面 运行 `apm doctor` 检查环境 `apm` 是官方短入口 与完整命令 `proxy-manager` 完全等价

这条命令会以 root 身份执行下载到的脚本 如果希望先审查

```sh
wget -O install.sh https://raw.githubusercontent.com/csjcsl666/alpine-proxy-manager/v0.9.1/install.sh
less install.sh
APM_REF=v0.9.1 sh install.sh
```

校验归档 每个 GitHub Release 都附带 `SHA256SUMS` 与源码归档 可以用 `APM_ARCHIVE_URL` 指向 Release 里的归档 并用 `APM_SHA256` 指定期望的校验和 不匹配就拒绝安装 校验和用于发现下载损坏 不提供独立的发布者身份证明 发布方式是 GitHub 的 HTTPS 加 Release 不需要也不要求你验证 Git tag 签名

### 安装脚本做的事

- 检查 Alpine root 必需的 BusyBox 工具与磁盘空间 并提示 cgroup 内存上限
- 下载源码归档 不 clone 历史 在 staging 目录解压并校验 运行语法检查与 `--version` 自检
- 安装到 `/usr/local/lib/alpine-proxy-manager/releases/<Build>` 再原子切换 `current` 链接 创建命令链接 `/usr/local/bin/proxy-manager` 再次自检 任何一步失败都回滚到原状态
- 自检通过后创建短命令 `/usr/local/bin/apm` 它是指向 `proxy-manager` 的符号链接 没有第二份脚本 升级时自动补上 已经存在且不是本项目创建的 `apm` 绝不覆盖 只给出警告 仍可使用 `proxy-manager`
- Build 取自归档里记录的 commit SHA 与实际下载的源码严格对应 取不到就拒绝安装

### 开发版 main

`main` 分支是开发版 会先于正式版前进 可能包含尚未发布的改动 只建议用来测试

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/csjcsl666/alpine-proxy-manager/main/install.sh)"
```

开发版同一 `VERSION` 的新 Build 也会被当作升级 重复执行同一条命令即可更新到 `main` 的最新提交

### 升级 Manager

升级到新的正式版 把命令里的 `v0.9.1` 换成新版本的 tag 即可 README 的默认命令会随每次正式发布更新 同一 Build 且工作正常时不做任何改动 新版本自检失败会继续使用旧版本 升级 Manager 本身不会重启 Snell 与 sing-box 不会改写任何已有配置与实例

也可以直接在 `apm` 里升级 `Manager 管理` 里选 `检查更新` 只查询 GitHub 上最新的正式 Release 不自动下载 `更新 Manager` 选中即开始 需要 root 并复用同一个安装脚本 所以原子切换 自检失败回滚 与 sha256 校验都一样 只更新到正式 Release 的 tag 不会更新到 main 草稿或预发布 不会降级 更新成功后请重新运行 `apm`

```sh
apm manager check-update    # 只检查 有新版本时退出码为 10 非 root 也可以
apm manager update          # 需要 root 会提示确认
```

检查更新是手动的 没有定时任务和后台进程 失败时当前 Manager 保持不变

### 卸载 Manager

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/csjcsl666/alpine-proxy-manager/v0.9.1/install.sh)" -- --uninstall
```

只删除 Manager 自己 包括本项目创建的 `apm` 不是本项目创建的 `apm` 会保留 不删除 Snell sing-box `/etc/alpine-proxy-manager` 中的配置与 `/var/lib/alpine-proxy-manager` 中的数据

## 使用

### 统一 TUI

在交互式终端直接运行 `apm` 或 `apm tui` 完整命令 `proxy-manager` 与 `proxy-manager tui` 仍然保留 两者等价

- 主菜单 Snell sing-box 状态与诊断 日志 Manager 管理 数字选择 `0` 返回 主菜单的 `0` 退出 Snell 与 sing-box 是两个独立的 Core 各自直接进入
- sing-box 页面直接列出全部协议实例 每个实例显示协议 监听端口 运行状态 绑定的 SOCKS5 出口和上游健康 菜单是 管理实例 添加实例 SOCKS5 出口 启停重启 日志 更新 诊断详情 卸载 实例页只管理协议本身 启用禁用 监听端口 密码 TLS server-name UUID 拥塞控制 method 客户端配置 目标访问限制 删除 不再提供修改监听地址 已有实例的监听地址原样保留 命令行仍然可以改 SOCKS5 出口管理集中在一处 管理 SOCKS5 服务器 分配实例出口 把全部实例当前的出口列出来 选一个实例再选服务器或 DIRECT 就完成 健康监控开关 不再需要手动检查配置 修改保存前和启动前都会自动校验 失败时显示原因并保持原配置 客户端连接地址在第一次导出客户端配置时才询问 已保存的地址原样保留 底层监听 socket 等技术信息在 诊断详情 里 启用或禁用协议实例在 sing-box 运行且还有其他启用的实例时会先提示需要重启 sing-box
- Snell 菜单里的 `查看连接信息（含 PSK）` 直接显示地址 端口和 PSK 不再逐层确认 Manager 菜单提供 查看版本 检查更新 更新 Manager 检查环境 查看帮助
- 界面以中文为主 协议与技术名词保持原名
- TUI 只是命令行的交互层 校验 保护与事务与命令行完全一致 现有部署只提供只读入口 不显示启动 停止 更新 卸载
- 密码 密钥 PSK 输入时不回显 无论正常结束 失败还是 Ctrl+C 都会恢复终端 秘密经标准输入交给业务函数 不出现在进程参数里
- 日常操作直接执行 不再逐项确认 启用 禁用 重启 sing-box 安装 AnyTLS Gateway 查看与导出连接信息 (完整信息 sing-box JSON 分享 URL 二维码 Snell PSK) 都是选中即执行 启用或禁用实例会重新加载 sing-box 结果行会写明 其他实例的连接可能短暂中断 实例已经处于目标状态时只告知 不重启 只有不可逆或会中断连接的操作保留确认 停止服务 卸载与彻底卸载 删除实例 线路或 SOCKS5 服务器 清空名单 重新生成密码或证书 开启自动故障切换
- 菜单数字选择 输入数字后按 Enter 才执行 数字只进入输入行 Backspace 可以修改 没有输入时按 Enter 不会执行任何操作 无效选项会提示 0 也需要 Enter 单独的 Esc 立即返回上一级 方向键序列被忽略 一次性粘贴的多行只取第一行 提交后残留的输入会被丢弃 终端缺少 `stty` 或不是交互终端时由终端自己做行编辑 规则相同 `APM_TUI_ONEKEY=0` 可以强制使用终端行编辑 需要阅读的页面 (状态总览 doctor 详细信息 日志 连接信息 安装与更新结果 以及所有失败提示) 输出完整内容后停在 `按回车返回...` 按 Enter 或 Esc 才返回上级菜单 暂停期间按其他键或方向键不会返回 非交互输入不会等待
- 没有外部依赖 没有常驻进程 进入时不联网 不检查更新 只有在你选择 `查看连接信息` 或 `检查更新` 时才会联网 `NO_COLOR` 与 `TERM=dumb` 退化为纯文本 终端不是 UTF-8 时状态符号改用 `[RUNNING]` 等文本
- 不是 root 时只能查看 写操作会提示需要 root
- 在脚本或管道中运行 `proxy-manager` 不会进入 TUI 仍然输出帮助 所有命令行用法保持不变

### 命令行

`apm help` 列出全部命令 短命令 `apm` 是指向 `proxy-manager` 的符号链接 所有命令行用法都可以用 `apm` 代替 `proxy-manager` 两者共用同一套代码 行为完全一致 下面的示例沿用完整命令 常用的

```sh
apm doctor                               # 只读环境检查
apm status                               # Core 状态与功能配置状态
apm core list                            # 发现 Core 并显示来源与管理状态
apm --version
proxy-manager sing-box list              # 完整命令同样可用
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

### Snell 网络功能

两个独立的可选功能 互斥 各自可以单独启用与禁用 都关闭时 Snell 使用原来的启动方式 没有任何辅助进程也没有额外内存

```sh
proxy-manager snell egress show
proxy-manager snell egress set --server 127.0.0.1 --port 1080 --no-auth
printf '%s\n' "$PASS" | proxy-manager snell egress set --server 地址 --port 端口 --username 用户名 --password-stdin
proxy-manager snell egress enable [--yes]   # 缺少组件时先列出并确认
proxy-manager snell egress disable
proxy-manager snell access add 192.0.2.10 443
proxy-manager snell access add example.org 443
proxy-manager snell access delete 192.0.2.10 443
proxy-manager snell access show | clear | refresh
proxy-manager snell access enable [--yes] | disable
```

- SOCKS5 出口 Snell 访问目标的 TCP UDP 和 DNS 全部经过指定的 SOCKS5 上游 上游可以是本机 局域网或公网 地址可以是 IPv4 IPv6 或域名 可选用户名密码 上游故障时连接失败 不会回退直连 DNS 由 Snell 专用的 unbound 通过上游完成
- 目标访问限制 Snell 只能连接名单里的 地址:端口 组合 其余全部拒绝 名单为空时拒绝所有目标 只转发 TCP UDP 业务一律拒绝 同一个地址的其他端口 或其他地址的同一个端口 都不放行 网关自己的地址不能加入名单
- 名单里的域名在启用 重启和 `access refresh` 时解析并固定 Snell 通过只对它自己可见的私有挂载命名空间里的 hosts 得到固定的地址 宿主的 `/etc/hosts` 不变 解析结果变化不会自动放行新的地址 需要手动刷新
- 实现 graftcp 通过 ptrace 接管 Snell 进程树的 connect 与 UDP 不改防火墙 路由和全局 DNS 目标访问限制再由 tinyproxy 按 地址:端口 精确匹配并默认拒绝 任何辅助进程退出都会拆除整套 不会恢复直连
- 组件按需安装 启用前列出并确认 graftcp 是本项目维护的补丁版 固定版本和 SHA256 来自本项目 Release 补丁 许可证与构建脚本见 `third_party/graftcp` unbound 与 tinyproxy 来自 Alpine 官方仓库 卸载 Snell 不会移除这些软件包
- 当前只验证 x86_64 需要 ptrace 与 root 容器需要 SYS_PTRACE 名单里有域名时还需要创建挂载命名空间的权限
- SOCKS5 上游自己的回环地址 例如上游就在本机 由上游决定是否放行 Snell 本机的回环服务不会被直连

## 网络与进程保护 (低内存环境, 针对 Snell)

管理员主动启用 默认关闭 入口 `apm` 的 `Snell` 里的 `网络功能` 下的 `网络与进程保护（低内存环境）` 它调整 TCP 缓冲 sshd 的 OOM 优先级并记录内存取证 不是内存清理或回收工具 命令行 `apm lowmem status | detail | enable | disable | log [N]` 针对在 128 MB 容器里观察到的 Snell 内存故障 (socket 缓冲计入容器内存 OOM 先杀 RSS 最大的 sshd 或 Snell) 设计 不承诺启用后 Snell 一定不会被 OOM 终止 也不承诺 SSH 一定不会被 OOM 终止 资源本身不足时这些保护无法替代更多内存

```sh
apm lowmem status                        # 实时检测结果 各项是否生效
apm lowmem enable                        # 一键启用 只调整需要调整的项目
apm lowmem enable --snell-sacrifice      # 同时启用高级选项 见下
apm lowmem disable                       # 恢复原值 删除服务与设置文件
```

- 三个独立模块 各自检测 各自可能不适用 状态永远从系统实时读取 整体显示 已启用 部分启用 或 未启用
- TCP 缓冲 单个连接的缓冲上限之和 (`tcp_rmem` 上限加 `tcp_wmem` 上限) 超过内存上限的四分之一时 把各字段降到内核默认值与当前值中较小者 只降不升 配置已经合理就不改 不查表 任意内存上限走同一套判断 管理员已经在 `/etc/sysctl.conf` 或 `sysctl.d` 里设置同名参数时跳过该参数 缓冲上限决定长延迟链路上的单连接吞吐上限 内核默认值在回环加延迟的实测里 RTT 50 ms 约 630 Mbit/s RTT 120 ms 约 275 Mbit/s (不是真实公网性能) 链路带宽更高且延迟更大时单连接会受限 请按需取舍
- TCP 缓冲是网络命名空间级配置 同一个网络命名空间里的所有服务都受影响 包括 sing-box 与 AnyTLS Gateway 不只是 Snell 只有进程在子用户命名空间里并且 sysctl 可写 才能确认该命名空间归本容器所有 否则显示 是否与宿主机共享 未确认 并且不自动修改 TCP 参数 独占该命名空间的管理员可以用 `--assume-own-netns` 明确指定 设置文件会记录这是用户声明
- SSH 保护 把 sshd 相关进程的 `oom_score_adj` 降到 -500 内核要求初始用户命名空间的 CAP_SYS_RESOURCE 无特权容器通常没有 此时明确显示不支持 不尝试 所在 cgroup 的 `memory.oom.group` 为 1 时整组一起终止 也不适用
- 内存取证 一个只用 sh 内建的常驻小进程 oom_kill 计数变化时记录内存组成 (anon file kernel sock slab) 与进程表 (只有进程名和 RSS 不含命令行 地址 流量与凭据) 日志 `/var/log/apm-lowmem.log` 上限约 1 MiB 需要 cgroup v2 实测 BusyBox ash 下稳态不 fork RSS 约 1.2 MB
- 高级选项 Snell 优先被 OOM 终止 (`--snell-sacrifice`) 默认不启用 把 Snell 服务的 supervise-daemon 的后代进程的 `oom_score_adj` 提高到 300 让内存吃紧时先终止 Snell 而不是 sshd 代价是 Snell 更容易被终止 即使它不是原因 300 只是实验取样值 不是各环境的最佳值 不触碰 supervise-daemon sshd sing-box AnyTLS Gateway 与其他进程 不重启 Snell
- 修改范围 当前网络命名空间的 `tcp_rmem` `tcp_wmem` sshd 进程的 `oom_score_adj` 一个 OpenRC 服务 `apm-lowmem` 开机时重新应用 TCP 设置 原值保存在 `/var/lib/alpine-proxy-manager/lowmem.orig` 关闭时只在当前值仍等于 APM 设置值时写回 被别人改过的不覆盖
- 卸载 Manager 不会自动恢复这些设置 先执行 `apm lowmem disable`

## AnyTLS Gateway

第三个独立 Core 极简的 AnyTLS 入站网关 每条转发线路是一个 AnyTLS 入站端口加一个固定的 SOCKS5 出口 只转发 TCP 为 64 MiB 容器设计

```sh
proxy-manager anytls-gateway install                       # 只安装 不创建 listener
printf '%s\n' "$PASS" | proxy-manager anytls-gateway install --port 30001 --socks-server 192.0.2.10 --socks-port 1080 --socks-username 用户名 --socks-password-stdin
proxy-manager anytls-gateway status | info | log [N]
proxy-manager anytls-gateway start | stop | restart
proxy-manager anytls-gateway listener list
proxy-manager anytls-gateway listener add --socks-server 地址 --socks-port 端口 --socks-username 用户名 --socks-password-stdin
proxy-manager anytls-gateway listener set 30001 --new-password
proxy-manager anytls-gateway listener delete 30001
proxy-manager anytls-gateway cert show
proxy-manager anytls-gateway export secret 30001
proxy-manager anytls-gateway update [--force]
proxy-manager anytls-gateway uninstall [--purge]
```

- 每条转发线路有独立的 AnyTLS 密码 自动生成 24 位 只在创建时显示一次 之后用 `export secret` 查看 SOCKS5 密码只能通过 `--socks-password-stdin` 提供
- 交互界面里选择 `查看 AnyTLS 密码` 会直接列出全部转发线路的端口和 AnyTLS 密码 不再询问线路 只读 不修改任何配置 命令行 `export secret` 不变
- 交互界面里所有 Yes/No 确认统一为 `[Y/n]` 直接按 Enter 就是 Yes 输入 n 取消 无效输入会重新询问 读取失败或输入结束不会被当成确认 包括卸载和彻底卸载 命令行和无人值守脚本不受影响
- 交互界面里添加或修改 SOCKS5 出口时 可以直接粘贴完整的 `socks5://用户名:密码@主机:端口` 链接 自动识别主机 端口和认证 用户名密码可以百分号编码 IPv6 需要方括号 链接不完整时只补问缺少的字段 输入普通地址仍按原有方式逐项填写 链接像普通地址一样可见输入 回车前可以检查和修改 程序不会再次打印也不记录链接内容 解析失败不改动任何配置 sing-box 的 SOCKS Profile 和 Snell 的 SOCKS5 出口交互界面行为一致 命令行仍然只接受分项参数
- 上游失败 认证错误 不可达都只会关闭连接 没有 DIRECT 路径 不处理 UDP 没有路由 DNS 日志文件的复杂功能 没有常驻管理进程
- 默认自签证书 RSA 2048 有效期 10 年 证书名称是占位名称 `anytls-gateway` 客户端需要跳过证书校验或固定指纹 可以用 `cert import --cert-file 文件 --key-file 文件` 导入已有证书 也可以用 `cert generate --server-name 名称` 明确重新生成带你自己域名的自签证书 CN 与 DNS SAN 都是它 重新生成会更换证书 已经导出的固定校验配置需要重新导出 只想改客户端看到的服务名而不动证书 用 `endpoint 线路 sni set 名称`
- 以专用非 root 用户 anytlsgw 运行 服务脚本里设置 GOMEMLIMIT=16MiB 与 GOGC=50
- 配置格式与现网部署的 `/etc/anytls-socks-gateway/config.json` 兼容 Manager 不自动接管已有的部署 现有部署只读识别
- 二进制 anytls-socks-gateway 是本项目维护的 Go 程序 基于 sing 与 sing-anytls GPL-3.0-or-later 源码 构建脚本 许可证在 `third_party/anytls-gateway` 二进制与对应源码包发布在 https://github.com/csjcsl666/alpine-proxy-manager/releases/tag/anytls-gateway-v0.1.0 固定版本和 SHA256 当前只验证 x86_64

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
proxy-manager sing-box health status
proxy-manager sing-box health disable
proxy-manager sing-box health enable
proxy-manager sing-box health mode all|custom
proxy-manager sing-box health profile 名称 on|off
proxy-manager sing-box health failover [名称 on|off]
proxy-manager sing-box health probe-url [1|2 https地址|default]
proxy-manager sing-box egress ID [show] | direct | socks 名称
```

- 它与目标访问限制不是同一个功能 目标访问限制决定可以访问哪些目标 SOCKS 出口决定允许之后从哪里出去 两者可以同时使用 允许的目标会走该实例的出口 不会绕过 SOCKS
- 一个 Profile 可以被多个实例共享 没有绑定就是 DIRECT 升级 Manager 不会改动现有实例
- SOCKS5 上游健康监控 默认启用 监控范围有两种互斥的模式 全部监控是默认 所有被实例使用的 SOCKS5 服务器都监控 自定义监控可以逐台开关 每台服务器的设置独立保存 切换到全部监控不会抹掉它们 再切回自定义监控时原样恢复 全部监控模式下不能单独改某一台 先切换到自定义监控 sing-box health enable 和 disable 仍然是整体开关 只有实例绑定了 SOCKS Profile 时才生效 一个常驻的小进程订阅 sing-box 自己的事件流 根据真实连接的失败与完成更新每个 Profile 的状态 正常 异常 故障 恢复中 监控已关闭 监控异常 没有流量时不做任何探测 也没有 15 分钟过期 没有发现故障就显示正常 可靠故障后显示故障 可靠恢复后显示正常 长时间没有流量保留最近一次判断 也不会连接你的 SOCKS5 服务器 上游恢复后下一次真实连接成功就自动变回正常 不需要重启 sing-box 也不需要重新绑定 监控本身只是观察 不改变出口绑定 默认不会回退 DIRECT 故障时连接照常被拒绝 只有你明确开启了下面的自动故障切换 才会临时直连 状态显示在 SOCKS Profile 与实例出口页面 `sing-box health status` 可以查看全部 长期不结束的连接恢复后可能要等它结束或者有别的连接结束才会确认 常驻内存约 4 MiB 状态文件在内存盘 `/run/apm-sbhealth` 只含状态和时间 不含地址 凭据
- 自动故障切换 默认关闭 升级不会开启 逐台 Profile 单独授权 在 TUI 的 SOCKS5 出口管理里选 4. 自动故障切换 选编号开关 或使用 `sing-box health failover 名称 on|off` 开启后 这台服务器的 SOCKS5 上游被可靠判定为故障时 新连接临时通过 VPS 自己的出口 IP 直连 目标网站会看到 VPS 的 IP 已建立的连接不迁移 目标访问限制与路由限制仍然生效 上游恢复后自动切回 SOCKS5 不重启 sing-box 也不重新绑定 需要健康监控开启 才会生效 关闭授权会立刻恢复严格的 SOCKS5 监控异常或关闭时会回到严格的 SOCKS5 不会依据过期的故障状态继续 DIRECT
- 恢复验证只由真实请求触发 没有定时探测 没有 cron 同一台服务器同一时间最多一组验证 按 5 10 20 秒到 300 秒退避 每次最多依次访问两个相互独立的 https 地址 默认 `https://cp.cloudflare.com/generate_204` 与 `https://www.gstatic.com/generate_204` 请求通过 sing-box 自己的出站走指定的 SOCKS5 任意一个通过即视为恢复 都失败则继续 DIRECT 验证失败不会被记录成新的上游故障 如果你的上游访问不了默认地址 请用 `sing-box health probe-url 1|2 https地址` 或在 TUI 的同一页面改成它能访问的地址 开启后请确认哪些服务器正处于 DIRECT
- 每台服务器只保留最近一次故障时间和最近一次恢复时间 不保存历史列表 不含域名 用户名 密码 在 SOCKS5 服务器页面显示
- 只支持 SOCKS5 SOCKS5 服务器可以在本机 内网或公网 地址可以是 IPv4 `[IPv6]` 或主机名 主机名以小写存储 由 sing-box 在连接 SOCKS 服务器时解析 解析失败连接就失败 不回落 DIRECT 访问目标的域名不在本机解析 原样交给 SOCKS 服务器由上游解析 认证只有无认证与用户名加密码 密码通过 `--password-stdin` 提供 不接受命令行明文
- UDP 通过 SOCKS5 UDP ASSOCIATE 转发 如果上游不支持 UDP 则 UDP 失败 不会直连 已用真实 SOCKS5 服务器验证
- sing-box 的协议实例通过 sing-box 自己的出站使用 SOCKS 出口 Snell 的 SOCKS5 出口是另一套机制 见上文 Snell 网络功能
- Profile 被禁用 不存在 损坏 或 SOCKS 服务器不可达 认证失败 默认都不会回落 DIRECT 流量会失败 不负载均衡 不会切换到其他 SOCKS5 服务器 唯一的例外是你逐台明确开启的自动故障切换
- 删除仍被实例引用的 Profile 会被拒绝并列出引用者 批量启用与禁用一次命令最多重启一次
- 配置有效不代表 SOCKS 服务器可用 Manager 只报告配置已应用

## 客户端连接地址与配置导出

### 客户端连接地址 Public Endpoint

```sh
proxy-manager sing-box endpoint ID [show] | set 主机 端口 | clear | sni set 名称 | sni clear
proxy-manager snell endpoint [show] | set 主机 端口 | clear
proxy-manager anytls-gateway endpoint 线路ID或端口 [show] | set 主机 端口 | clear | sni set 名称 | sni clear
proxy-manager anytls-gateway client 线路ID或端口 show | secret | sing-box [--redacted] [--embed-cert] | url | qr
```

- 服务器地址选择 所有需要客户端连接地址的 TUI 入口 sing-box 实例与 AnyTLS Gateway 的客户端配置 共用同一个界面 直接按 Enter 自动获取公网 IP 输入 IPv4 IPv6 或域名使用自定义地址 输入 0 并按 Enter 或直接按 Esc 取消并返回 自动获取失败会说明原因 可以再按 Enter 重试 手动输入或返回 自动获取先试 IPv4 取不到再试 IPv6 结果必须是严格的公网地址 回环 私有 链路本地 文档保留地址都不会被接受 这只是服务器的出口地址 服务器在 NAT 后面或使用端口映射时请手动输入客户端实际连接的地址 自动获取是只读的 不修改服务器网络
- AnyTLS Gateway 的客户端配置 在 AnyTLS Gateway 菜单的 客户端配置 里 每条转发线路是一个客户端入口 有自己的端口和 AnyTLS 密码 功能与 sing-box 实例一致 查看连接信息 查看凭据 导出 sing-box JSON 隐藏凭据 嵌入证书固定校验 分享 URL 二维码 内容来自该线路的记录和网关当前使用的证书 不使用 SOCKS5 上游 也不使用任何 sing-box 实例的数据 缺少必要信息时拒绝导出 证书固定校验只在网关证书带 SAN 的自签名证书上提供 v0.8.3 起新生成的证书带 SAN 旧证书只有 CN 时客户端会拒绝 此时固定校验被拒绝并说明原因 其他导出仍然可用 由 CA 签发的证书按证书链校验 不带 insecure 导出是只读的 不改网关配置 不重启
- Snell 不需要设置 Public Endpoint 就能使用 TUI 的 `客户端信息` 里 `查看连接信息` 会在查看时通过 HTTPS 查询服务器的公网 IPv4 只用于显示 不保存 查询失败显示 `公网 IP：获取失败` 其余信息照常显示 `snell endpoint` 命令保留 已设置的值不受影响
- 内部监听地址与端口不等于客户端实际连接的地址 例如 NAT VPS 的内部端口与服务商映射的公网端口往往不同 Public Endpoint 只记录客户端应该连哪里 支持 IPv4 IPv6 与主机名
- Manager 不配置服务商的 NAT 与端口映射 不修改防火墙 不判断公网是否真的可达 显示的公网 IP 只是查询结果 在 NAT 环境里可能与客户端实际应连接的地址不同 这些需要你自己在服务商面板处理
- 没有设置时 导出会拒绝 不会把 0.0.0.0 或 127.0.0.1 导出给客户端 修改它不生成运行配置 不重启服务

### 导出

```sh
proxy-manager sing-box export ID show                 # 连接信息 不含凭据
proxy-manager sing-box export ID secret               # 显式查看凭据
proxy-manager sing-box export ID sing-box [--redacted] [--embed-cert] > client.json
proxy-manager sing-box export ID url
proxy-manager sing-box export ID qr
proxy-manager snell export info                      # 连接信息 自动查询公网 IP 不含 PSK
proxy-manager snell export show | secret             # show 使用已设置的 Public Endpoint secret 显式查看 PSK
```

- `sing-box` 生成可直接运行的 sing-box 客户端配置 含一个本机 `127.0.0.1:2080` 的 mixed 入站 `--redacted` 把凭据替换为 REDACTED 用于展示
- `url` 只提供有明确依据的分享链接 AnyTLS 与 Hysteria2 遵循各自官方的 URI Scheme Shadowsocks 遵循 SIP002 与 SIP022 TUIC 与 Snell 没有稳定的通用 URI 不提供链接 TUIC 请使用 sing-box 客户端配置
- `qr` 在终端显示分享链接的二维码 需要 `qrencode` 命令 由 Alpine 软件包 `libqrencode-tools` 提供 只有在你进入二维码功能而且命令缺失时 Manager 才会用 apk 和系统已配置的软件源自动安装它 安装成功后继续生成二维码 已安装时不重复安装 其他任何功能都不会触发安装 安装失败 例如没有 root 网络或 DNS 不可用 软件源没有该包 超时 默认 120 秒 `APM_DEP_INSTALL_TIMEOUT` 可调 会说明原因 分享链接仍可用 链接通过标准输入传给 qrencode 不出现在进程参数里 也不写日志
- 包含凭据的输出会在 stderr 打印警告 stdout 只有内容 不写临时文件 不写日志
- 导出不包含 SOCKS 出口凭据 目标访问限制 TLS 私钥与其他实例的凭据 切换 SOCKS 出口与目标访问限制不改变导出的内容

### 自签名 TLS 策略

AnyTLS Hysteria2 TUIC 使用 Manager 生成的自签名证书 客户端默认跳过证书校验 这是有意的低维护设计 不需要域名 不需要申请与续期证书

- 导出的 sing-box 配置默认写 `insecure` 并设置 server name
- 需要时可以用 `--embed-cert` 把服务端证书嵌入客户端配置做证书固定校验 这是可选项
- 客户端的 TLS 服务名 SNI 默认不填写 自签名证书加跳过证书验证 服务端不要求特定 SNI 所以导出的 sing-box JSON 不写 `server_name` 分享 URL 不带 `sni` 参数 二维码内容与 URL 相同 客户端按连接地址处理 不使用 `apm.local` `anytls-gateway` 这类内部占位名称 也不使用任何第三方网站域名
  - 需要时用 `endpoint ... sni set 名称` 明确设置 设置后始终优先 同时进入连接信息 JSON 分享 URL 二维码 重新进入菜单 重新导出 升级 Manager 都不会丢 `sni clear` 恢复默认 就是清除 不是恢复成某个名称 TUI 的客户端配置页有对应的 设置客户端 TLS 服务名 SNI 入口 留空即恢复默认
  - `sni set` 只改变导出内容 不修改证书 服务端 TLS 配置 运行配置 不重启服务 名称必须是域名 不接受 IP 地址与通配符
  - 客户端发送的 SNI 不等于真实网站身份 跳过证书验证时不会验证该名称对应网站的身份 服务器也不一定持有该名称的证书 它不等于网站伪装
  - 需要按名称校验证书的配置 嵌入证书固定校验 与 CA 签发的证书 不能不指定名称 这时从服务端真实证书解析 证书只有一个 DNS SAN 就用它 有多个时连接地址在其中就用连接地址 否则使用实例记录的 server-name 如果它在其中 都不满足就拒绝并列出证书里的名称 请用 `sni set` 选择 不会猜测 用户指定的名称必须被证书覆盖才能嵌入
  - 只有 IP SAN 的证书 嵌入时不发送 SNI JSON 不写 server_name 连接地址在 IP SAN 里时按 IP 严格校验 只有 CN 没有 SAN 的历史证书 客户端会拒绝它的名称校验 所以不提供嵌入证书固定校验 跳过证书验证不受影响
  - 解析证书需要 `openssl` 只在你明确导出嵌入证书固定校验时才需要 默认导出 查看连接信息 URL 二维码 设置与清除 SNI 都不需要 缺少 openssl 时 Manager 会在这一刻用 apk 和系统已配置的软件源自动安装它 显示安装结果 然后继续导出 已安装时直接复用 失败 例如没有 root 网络或 DNS 不可用 超时 会说明原因 返回 5 不会输出任何配置 也不会悄悄降级成跳过证书验证的配置 证书格式错误或不可读同样拒绝 AnyTLS Gateway 判断证书是自签名还是 CA 签发本来就要读证书 它的导出入口缺少 openssl 时同样按需安装 安装超时默认 120 秒 `APM_DEP_INSTALL_TIMEOUT` 可调
  - 想换掉证书里的占位名称 可以明确重新生成证书 sing-box 用 `set ID server-name 名称` AnyTLS Gateway 用 `cert generate --server-name 名称` 这会更换证书 已经导出的固定校验配置需要重新导出 默认导出不受影响
- 本版本不包含 ACME 与域名证书

## 更新 卸载 与保留的数据

- 更新 Core `proxy-manager snell update` 与 `proxy-manager sing-box update` 更新前会校验 失败回滚旧版本 更新 Manager 见上文
- 卸载 Core 默认保留配置 证书 日志 实例与 SOCKS Profile 重新安装会沿用 `--purge` 才会删除 并且只删除由 Manager 创建的内容 现有部署的任何内容都不会被删除
- 命令行 `sing-box uninstall` 保留数据 `sing-box uninstall --purge` 完整删除 sing-box 专属的托管数据 包括协议实例 目标访问限制 客户端连接地址 SOCKS Profile 证书 运行配置 配置备份 日志与由 Manager 创建的用户 不会碰 Snell
- TUI 里卸载 sing-box 会先列出将删除的内容与数量 再让你选择 完整卸载 或 仅卸载程序 然后确认 完整卸载复用 `--purge`
- 备份 每次配置变更都会在 `/var/lib/alpine-proxy-manager/backups/` 保留最近 2 份 目录 0700 文件 0600 其中包含凭据
- 数据位置 `/etc/alpine-proxy-manager/` 实例 SOCKS Profile 客户端连接地址 `/var/lib/alpine-proxy-manager/` 元数据与备份 配置文件权限 0600 目录 0700

## 限制与边界

- 内存 64 MiB 是 Manager 与安装流程的资源基线 不代表 sing-box 在 64 MiB 内能长期稳定运行 sing-box 的内存取决于版本 协议和连接数 在 128 MB cgroup 的真实 VPS 上 Snell 加 sing-box 四个实例的整体内存约 40 MB
- 不提供公网可用性监控与 uptime 探测 服务器自己无法判断来自公网却没有到达它的连接 外部可达性需要独立的观察点 请使用专用的监控工具
- 日志不自动轮转 sing-box 默认 warn 级别只记录错误 单行约 150 字节 `proxy-manager sing-box info` 会显示日志大小 长期无人维护的机器可以自行配置 logrotate 日志可能包含访问的目标 请不要公开
- 写操作 安装 更新 配置变更 开始后会忽略 Ctrl+C 断开 SSH 与 TERM 信号 避免留下半装的 Core 或与实例不一致的配置 所以中途关闭 SSH 窗口是安全的 命令会照常完成 只有下载阶段可以中断 如果某个写命令真的卡住 例如服务一直不响应 请在另一个终端用 `kill -9 进程号` 结束它 残留的锁会在下一次命令时自动清理
- 公网可达性 NAT 与防火墙 Manager 不管理也没有验证
- Hysteria2 的带宽 混淆 masquerade 等可选参数 TUIC 的可选调优参数 Shadowsocks 多用户 没有实现
- 不包含 ACME 域名证书 Web 界面 负载均衡 切换到其他 SOCKS5 服务器 域名形式的目标访问限制 Snell 的 SOCKS 出口

## 安全提醒

- 配置文件中保存代理凭据 目录权限 0700 文件权限 0600 请勿在 Issue 或日志中公开密码 PSK Token 或服务器地址
- 所有凭据只通过标准输入传入 不经过命令行参数 不写入 shell 历史
- 服务以专用的非 root 用户运行 Manager 部署的二进制属主是 root
- Manager 不修改防火墙 路由 sysctl 与服务商网络

## 第三方组件与许可证

- Alpine Proxy Manager 自己的脚本是独立程序 不包含下面的组件
- graftcp 补丁版 `v0.8.3-apm1` 仅在启用 Snell 网络功能时下载 基于 hmgle/graftcp v0.8.3 GPL-3.0-or-later 只加了精确 协议 地址 端口 豁免 补丁 许可证 构建脚本 第三方许可证 见 `third_party/graftcp` 二进制与对应的完整源码包发布在 https://github.com/csjcsl666/alpine-proxy-manager/releases/tag/graftcp-v0.8.3-apm1 可以用 `sh third_party/graftcp/build.sh 输出目录` 复现构建
- AnyTLS Gateway 二进制 基于 sagernet/sing 与 sing-anytls GPL-3.0-or-later 源码 构建脚本 许可证 `third_party/anytls-gateway` 对应源码包在 https://github.com/csjcsl666/alpine-proxy-manager/releases/tag/anytls-gateway-v0.1.0
- unbound 与 tinyproxy 来自 Alpine 官方仓库 按其各自的许可证分发

## 开发

从本地源码目录安装 Build 取自该目录的 git HEAD 有未提交修改时带 `-dirty` 后缀

```sh
git clone https://github.com/csjcsl666/alpine-proxy-manager.git
cd alpine-proxy-manager
sh install.sh --from-dir .
sh tests/run.sh
```

CI 在 Alpine 3.21 3.22 与 3.24 容器内运行 `sh -n` shellcheck 与全部测试 并用官方 Snell 与 sing-box 二进制做真实流量测试 包括服务端到导出的客户端配置再到官方 sing-box 客户端的完整链路 测试通过 `APM_ROOT` 隔离到临时目录 不会写入真实的 `/usr/local`
