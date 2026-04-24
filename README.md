# XrayR

A Xray backend framework that can easily support many panels.

一个基于 Xray 的后端框架，支持 V2ray、Trojan、Shadowsocks、Hysteria 2 协议，极易扩展，支持多面板对接。

Source code: [TheLastShadow-B/XrayR](https://github.com/TheLastShadow-B/XrayR)

## 系统要求

- **OS**: Debian 12 (Bookworm) 或 Debian 13 (Trixie)
- **架构**: x86_64 / amd64
- 其他系统请使用仓库的历史 release tag: <https://github.com/TheLastShadow-B/XrayR-release/releases>

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/TheLastShadow-B/XrayR-release/master/install.sh)
```

安装脚本会校验发行包的 SHA256（失败即终止），支持幂等升级（保留 `/etc/XrayR/` 现有配置与 `cert/` 目录），并在检测到 `NodeType: Hysteria2` 时提示 TLS / UDP 前置条件。

指定版本：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/TheLastShadow-B/XrayR-release/master/install.sh) v1.2.3
```

## 管理脚本

安装完成后，终端执行 `XrayR`（或小写 `xrayr`）进入管理菜单。常用子命令：

```
XrayR start | stop | restart | status | log
XrayR update [x.y.z]    # 更新到最新版或指定版本
XrayR config            # 编辑 /etc/XrayR/config.yml
XrayR uninstall         # 卸载
XrayR version
```

管理菜单内的 "一键安装 BBR" 通过写入 `/etc/sysctl.d/99-bbr.conf` 并 `sysctl --system` 原生启用 BBR，不再下载外部脚本。受限虚拟化方案（OpenVZ、非特权 LXC）会给出明确提示。

## Docker 安装

> 目前镜像仍引用上游 `ghcr.io/xrayr-project/xrayr`。本仓库计划发布 fork 自有镜像后会更新此处（见 OQ2）。

```bash
docker pull ghcr.io/xrayr-project/xrayr:latest
docker run --restart=always --name xrayr -d \
  -v ${PATH_TO_CONFIG}/config.yml:/etc/XrayR/config.yml \
  --network=host \
  ghcr.io/xrayr-project/xrayr:latest
```

## Docker Compose 安装

Debian 12/13 安装 Docker + Compose 插件：

```bash
curl -fsSL https://get.docker.com | bash -s docker
apt-get install -y docker-compose-plugin
```

拉起服务：

```bash
git clone https://github.com/TheLastShadow-B/XrayR-release
cd XrayR-release
# 编辑 config/config.yml
docker compose up -d
```

配置文件基本格式见 [`config/config.yml`](config/config.yml)。Hysteria 2 节点示例已以注释形式内置，解除注释并按需修改即可。

## Docker Compose 升级

```bash
docker compose pull
docker compose up -d
```
