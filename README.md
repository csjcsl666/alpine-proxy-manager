# Alpine Proxy Manager

面向 Alpine Linux 低内存 VPS 的轻量 Snell + sing-box 统一管理器

当前为早期开发版本 `0.1.0-dev.0` 还不能安装或管理 Snell 与 sing-box

## 快速安装

以 root 登录 Alpine VPS 后执行

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/csjcsl666/alpine-proxy-manager/main/install.sh)"
```

安装完成后

```sh
proxy-manager doctor
```

只需要 Alpine 自带的 `wget` 不需要 `curl` `git` 或 `sudo` 重复执行同一条命令即可更新到最新 Build

### 这条命令做了什么

它会执行 GitHub 上的安装脚本 因此以 root 身份运行的是你下载到的这份脚本 如果希望先审查

```sh
wget -O install.sh https://raw.githubusercontent.com/csjcsl666/alpine-proxy-manager/main/install.sh
less install.sh
sh install.sh
```

安装脚本依次完成

- 检查 Alpine Linux root 必需的 BusyBox 工具 磁盘空间 并提示 cgroup 内存上限
- 从 GitHub 下载源码归档 不 clone 历史 串行下载与解压
- 在磁盘上的 staging 目录解压并校验 运行语法检查与 `--version` 自检
- 安装到 `/usr/local/lib/alpine-proxy-manager/releases/<Build>` 然后原子切换 `current` 链接
- 创建命令链接 `/usr/local/bin/proxy-manager` 再次自检 失败则回滚到原状态

Build 取自归档中记录的 commit SHA 与实际下载的源码严格对应 取不到则拒绝安装 不会显示 `unknown`

### 升级

再次执行同一条命令即可

- 同一 Build 且工作正常 不做任何改动
- 同一 `VERSION` 的新 Build 视为升级 例如 `abc1234 → def5678` 开发阶段 `main` 会不断变化 因此不只比较 `VERSION`
- 新版本校验失败 继续使用旧版本

### 指定版本

```sh
APM_REF=main sh -c "$(wget -qO- https://raw.githubusercontent.com/csjcsl666/alpine-proxy-manager/main/install.sh)"
```

`APM_REF` 可以是分支 tag 或 commit 目前没有正式 Release

### 卸载

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/csjcsl666/alpine-proxy-manager/main/install.sh)" -- --uninstall
```

只删除 Alpine Proxy Manager 自己安装的文件 不会删除 Snell sing-box `/etc/alpine-proxy-manager` 中的配置与 `/var/lib/alpine-proxy-manager` 中的数据

### 安装位置

```
/usr/local/lib/alpine-proxy-manager/
├── current -> releases/<Build>
└── releases/<Build>/
    ├── VERSION
    ├── BUILD
    ├── INSTALL
    ├── bin/
    └── lib/
/usr/local/bin/proxy-manager -> ../lib/alpine-proxy-manager/current/bin/proxy-manager
```

## 项目定位

- 仅支持 Alpine Linux 与 OpenRC 不支持 systemd 与其他发行版
- 目标环境是 musl 与小内存 VPS 优先使用 POSIX sh 与 BusyBox 工具 依赖尽量少
- Snell 与 sing-box 是两个相互独立的 Core 安装时各自可选 允许只装一个或两个都装 不存在 Both 模式
- sing-box 的协议以实例建模 例如 AnyTLS-01 AnyTLS-02 Hysteria2-01 而不是协议开关
- 所有配置变更遵循 候选配置 校验 备份 原子替换 reload 的事务流程 校验失败绝不覆盖当前工作配置

## 内存说明

64 MiB 是 Manager 与安装流程必须考虑的最低资源基线 **不代表 sing-box 本身能在 64 MiB 内长期稳定运行** sing-box 的实际内存占用取决于版本 协议和连接数 目前没有足够数据承诺它在 64 MiB 下的稳定性

## 已完成

- 一条命令安装 升级 卸载 Manager 本体
- `proxy-manager --version` 外部版本取自 `VERSION` 文件 Build 取自安装时写入的 `BUILD` 文件
- `proxy-manager doctor` 严格只读的环境检查 报告 Alpine OpenRC root 架构 cgroup 内存上限 当前内存 swap 以及 Snell 与 sing-box 安装情况 存在 cgroup 限制时优先报告 cgroup 上限
- `proxy-manager status` 显示 Core 状态与功能配置状态
- `proxy-manager core list` 只读发现 Core 并显示状态 版本 来源与管理状态 已有部署显示为 现有部署 未接管 本项目不会改动它
- `proxy-manager snell status` `snell info` `snell log [N]` Snell 只读 Adapter 显示 OpenRC 状态 版本 配置元数据 日志位置与监听 PSK 一律脱敏 日志默认只读末尾 20 行
- Core 发现只执行已确认为 ELF 的二进制 脚本与指向脚本的符号链接不会被执行 运行状态以 OpenRC 为准
- Core Adapter 分发接口 生命周期写操作目前全部未实现 `snell install` `start` `stop` `restart` `update` `uninstall` 会被拒绝
- Protocol Instance Server SOCKS Profile Relay Access Policy 的数据模型与校验
- 配置事务基础设施 候选文件 校验 hook 备份 原子替换 失败回滚
- 基础测试与 GitHub Actions CI

## 尚未完成

- Snell 与 sing-box 的安装 升级 卸载 启停 以及接管已有部署
- 任何 sing-box 协议的配置生成
- Server SOCKS Egress 与 Relay Access Policy 的实际落地 目前只有数据模型和校验
- 添加 删除 修改 查看实例的命令
- URL 与二维码导出
- 正式 Release

## 安全提醒

- 本项目处于早期阶段 不要在生产环境依赖它
- 配置文件中会保存代理凭据 配置目录权限为 0700 文件权限为 0600
- 请勿在 Issue 或日志中公开密码 PSK Token 或服务器地址

## 开发

从本地源码目录安装 Build 取自该目录的 git HEAD 有未提交修改时带 `-dirty` 后缀

```sh
git clone https://github.com/csjcsl666/alpine-proxy-manager.git
cd alpine-proxy-manager
sh install.sh --from-dir .
```

运行测试

```sh
sh tests/run.sh
```

CI 在 Alpine 3.21 3.22 与 3.24 容器内运行 `sh -n` shellcheck 与全部测试 包括安装器集成测试 测试通过 `APM_ROOT` 隔离到临时目录 不会写入真实的 `/usr/local`

`doctor` `status` `core list` 无需 root 也可以运行 它们不会修改系统
