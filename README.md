# SoftEther VPN Server 5.2 一键安装脚本

从源码编译安装 SoftEther VPN Server 5.x(自动取最新版,当前 5.2.5189),并：

- **开机自启**:安装 systemd 服务 `softether-vpnserver`,异常退出自动重启
- **彻底关闭日志**(避免日志撑爆硬盘)
  - 所有虚拟 HUB 的 security / packet 日志执行 `LogDisable`
  - 日志目录 `/var/log/softether` 挂载为 16MB 内存 tmpfs(服务器日志 `server_log` 无法通过配置关闭,靠它兜底;写满也不会占硬盘,重启即清空)
  - `softether-nolog` 命令:新建 HUB 后再运行一次即可关闭新 HUB 日志
  - 升级时自动清理旧版(4.x)遗留的 `server_log / security_log / packet_log`
- **多架构**:x86_64(AMD/Intel)、aarch64(ARM64)同一个脚本,自动识别
- **多系统**:Debian / Ubuntu(apt)、RHEL / CentOS / Rocky / Alma / Fedora(dnf/yum)、openSUSE(zypper)、Arch(pacman)
- **平滑升级**:自动备份并迁移旧配置(`/opt/softether`、`/opt/vpnserver`、`/usr/local/vpnserver`),备份在 `/root/softether-backup`
- 持久开启 IPv4 转发;仅当 ufw / firewalld 已启用时才放行端口(绝不擅自开启防火墙,避免把自己锁在外面)

## 使用

```bash
wget -O install-softether5.sh https://raw.githubusercontent.com/bennyzhou88/SEOK/main/install-softether5.sh
sudo bash install-softether5.sh
```

| 选项 | 说明 |
| --- | --- |
| `-y` | 免确认 |
| `-v 5.2.5189` | 指定版本,默认自动取最新 |
| `--uninstall` | 卸载(先备份配置) |

环境变量:`SE_ADMIN_PASSWORD`(已设置管理密码时用于关闭日志)、`OPEN_FIREWALL=0`(不改防火墙)。

## 目录

| 路径 | 内容 |
| --- | --- |
| `/opt/softether` | 程序(bin / lib / libexec) |
| `/var/lib/softether` | `vpn_server.config` 配置 |
| `/var/log/softether` | 日志目录(tmpfs) |

## 安装后

1. **立即设置管理员密码**(默认为空):`vpncmd` → 选 1 → 连接 `localhost:5555` → `ServerPasswordSet`
2. 云服务器在安全组放行:TCP 443/992/1194/5555,UDP 500/1701/4500/1194
3. 之后再设了密码,要关闭新 HUB 日志:`SE_ADMIN_PASSWORD='密码' softether-nolog`

## 说明

- 编译需 CMake ≥ 3.15,即 Ubuntu 20.04+/Debian 10+/EL8+;内存建议 ≥1GB(不足时脚本会自动降低并行度并提示加 swap)。
- Alpine(musl)暂不支持。
- 已在 x86_64 上完整实测:编译、安装、`execsvc` 启动、`LogDisable`、tmpfs 日志目录、旧配置迁移与旧日志清理。ARM64 使用同一套 CMake 流程,未在真机验证。
