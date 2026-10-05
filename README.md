# Alpine Proxy Manager

面向 Alpine Linux 低内存 VPS 的轻量 Snell + sing-box 统一管理器

## 当前状态

早期开发阶段 当前版本 `0.1.0-dev.0` 只有骨架和只读检查命令 **还不能安装或管理 Snell 与 sing-box**

## 项目定位

- 仅支持 Alpine Linux 与 OpenRC 不支持 systemd 与其他发行版
- 目标环境是 musl 与小内存 VPS 优先使用 POSIX sh 与 BusyBox 工具 依赖尽量少
- Snell 与 sing-box 是两个相互独立的 Core 安装时各自可选 允许只装一个或两个都装 不存在 Both 模式
- sing-box 的协议以实例建模 例如 AnyTLS-01 AnyTLS-02 Hysteria2-01 而不是协议开关
- 所有配置变更遵循 候选配置 校验 备份 原子替换 reload 的事务流程 校验失败绝不覆盖当前工作配置

## 内存说明

64 MiB 是 Manager 与安装流程必须考虑的最低资源基线 **不代表 sing-box 本身能在 64 MiB 内长期稳定运行** sing-box 的实际内存占用取决于版本 协议和连接数 目前没有足够数据承诺它在 64 MiB 下的稳定性

## 已完成

- `proxy-manager --version` 外部版本取自 `VERSION` 文件 Build 取自 git short SHA 或安装时写入的 `BUILD` 文件 取不到时为 `unknown`
- `proxy-manager doctor` 严格只读的环境检查 报告 Alpine OpenRC root 架构 cgroup 内存上限 当前内存 swap 以及 Snell 与 sing-box 安装情况 存在 cgroup 限制时优先报告 cgroup 上限
- `proxy-manager status` 显示 Core 状态与功能配置状态
- `proxy-manager core list` 列出 Core
- Core Adapter 分发接口 生命周期操作目前全部未实现
- Protocol Instance Server SOCKS Profile Relay Access Policy 的数据模型与校验
- 配置事务基础设施 候选文件 校验 hook 备份 原子替换 失败回滚
- `install.sh` 只安装 proxy-manager 本身
- 基础测试与 GitHub Actions CI

## 尚未完成

- Snell 与 sing-box 的安装 升级 卸载 启停
- 任何 sing-box 协议的配置生成
- Server SOCKS Egress 与 Relay Access Policy 的实际落地 目前只有数据模型和校验
- 添加 删除 修改 查看实例的命令
- URL 与二维码导出
- 正式 Release

## 安装

```sh
git clone https://github.com/csjcsl666/alpine-proxy-manager.git
cd alpine-proxy-manager
doas sh install.sh   # 或使用 root 执行
proxy-manager doctor
```

`install.sh` 只复制程序本体到 `/usr/local/lib/alpine-proxy-manager` 并链接到 `/usr/local/bin/proxy-manager` 不会下载或安装任何代理程序 `sh install.sh --uninstall` 卸载 不会删除 `/etc/alpine-proxy-manager` 中的配置

`doctor` `status` `core list` 无需 root 也可以运行 它们不会修改系统

## 测试

```sh
sh tests/run.sh
```

CI 在 Alpine 3.22 与 3.24 容器内运行 `sh -n` shellcheck 与全部测试

## 安全提醒

- 本项目处于早期阶段 不要在生产环境依赖它
- 配置文件中会保存代理凭据 配置目录权限为 0700 文件权限为 0600
- 请勿在 Issue 或日志中公开密码 PSK Token 或服务器地址

## 开发

配置文件格式 数据模型与架构说明见仓库内源码注释 开发笔记在私有仓库维护
