# EtherGuard Windows 测试实验室

该目录在独立的 `etherguard-winlab` Compose project 中运行 dockur/windows v6.00。Web、RDP、Windows SSH 与 EtherGuard UDP 均仅绑定远端回环地址，必须经 `ssh hk-coolify` 隧道访问。

## 首次准备

在远端专用目录 `/root/etherguard-windows-lab` 中放置本目录内容。复制对应环境模板为 `.env.local`，设置随机 RDP 密码并执行 `chmod 600 .env.local`。为实验室生成独立 SSH 密钥，将公钥保存为 `oem/authorized_keys`，权限设为 `0600`；不要提交密码、私钥或 `authorized_keys`。

```sh
cp .env.win10.example .env.local
chmod 600 .env.local oem/authorized_keys
./lab.sh prepare
./lab.sh sync-source
./lab.sh up win10
```

`prepare` 检查 KVM、Docker、磁盘与端口，并从官方发布页下载和校验 TAP-Windows6 9.27.0、Win32-OpenSSH 7.7.2、Windows 7 SHA-2 与维护栈更新 KB4474419/KB4490628，以及对应系统的 Go 安装资产。Win10 使用校验后的 Go 1.26.5 ZIP 便携工具链，避免静默 MSI 安装挂起；Win7 旧基线使用 Go 1.20.14 MSI。已有缓存也会重新校验。

## 系统兼容性

基于 PR15 的当前源码依赖 Go 1.26.5，支持 Windows 10 / Windows Server 2016 或更高版本。Go 1.20 是最后支持 Windows 7/8 的版本，因此 Win7 VM 仅用于旧依赖基线、驱动与 OpenSSH 兼容性回归，不能用于构建当前分支。需要验证 Win7 时，应同步仍使用 Go 1.20 依赖基线的历史分支或提交。

## 访问与运维

`./lab.sh tunnel` 输出应在本机执行的 SSH 隧道命令。隧道建立后，Web 控制台使用 `http://127.0.0.1:18006`，RDP 使用 `127.0.0.1:13389`，Windows SSH 使用 `ssh -p 12222 EtherGuard@127.0.0.1`。

任一时刻只允许运行一个 VM。切换到 Win7 前先执行 `./lab.sh down`，复制 `.env.win7.example` 为 `.env.local`，再执行 `./lab.sh up win7`。`status` 会显示容器日志、目录占用和 qcow2 虚拟/物理大小。

```sh
./lab.sh status
./lab.sh down
./lab.sh prune-win7
```

`down` 只清理本 project 的容器、匿名卷与孤儿容器。`prune-win7` 仅删除 Win7 系统盘、固件状态与启动标记，保留 ISO、OEM、固定工具缓存和配置。禁止对共享远端执行任何全局 Docker prune。

完成首次系统安装后，可以不经 RDP 直接在当前 VM 内以 `LocalSystem` 执行命令。该通道只使用 Windows VM 私网中的 SMB 与 Service Control Manager；辅助容器使用固定镜像摘要、执行后自动删除，不新增宿主端口。

```sh
./lab.sh exec -- whoami
./lab.sh exec -- 'C:\EtherGuard\toolchains\go1.26.5\go\bin\go.exe version'
./lab.sh exec -- 'powershell.exe -NoProfile -Command "Get-Service sshd"'
```

`exec` 适合无人值守构建、测试、日志采集和服务控制。它使用 `.env.local` 中的实验室密码连接当前 VM，命令和凭据都不会写入仓库。

双节点验收时可用 `acceptance` profile 启动临时 Linux TAP peer。该 peer 与 Windows VM 共享隔离的容器网络命名空间，只获得 `/dev/net/tun` 和 `NET_ADMIN`，不会新增宿主端口；配置必须放在被忽略的 `shared/acceptance/` 中。

```sh
docker compose -p etherguard-winlab --env-file .env.local -f compose.yaml --profile acceptance up -d linux-peer
docker compose -p etherguard-winlab --env-file .env.local -f compose.yaml logs -f linux-peer
```

## Windows 验证

OEM 脚本安装匹配系统的 TAP-Windows6 amd64 驱动并将适配器命名为 `tap1`，安装固定 Go 和 OpenSSH，启用仅公钥 SSH，并创建 `C:\EtherGuard` 目录结构。登录后至少验证：

```powershell
go version
Get-Service sshd
Get-WmiObject Win32_NetworkAdapter | Where-Object NetConnectionID -eq "tap1"
```

Win7 缺少部分现代 PowerShell cmdlet，必要时使用 `Get-WmiObject` 与 `netsh advfirewall` 查看等价状态。
