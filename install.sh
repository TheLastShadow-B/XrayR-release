#!/bin/bash
#
# XrayR 一键安装脚本 (TheLastShadow-B fork)
# 支持：Debian 12 (Bookworm) / 13 (Trixie)，x86_64
# 详细设计：docs/brainstorms/2026-04-24-install-script-refresh-requirements.md

set -euo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# ---------- helpers ----------

die() {
    echo -e "${red}错误：${plain} $*" >&2
    exit 1
}

warn() {
    echo -e "${yellow}警告：${plain} $*" >&2
}

info() {
    echo -e "${green}$*${plain}"
}

# ---------- staging + ERR trap (R3) ----------

STAGING=""
cleanup() {
    [[ -n "$STAGING" && -d "$STAGING" ]] && rm -rf "$STAGING"
}
trap cleanup EXIT

# ---------- R1: root + OS check ----------

[[ $EUID -ne 0 ]] && die "必须使用 root 用户运行此脚本"

[[ -r /etc/os-release ]] || die "无法读取 /etc/os-release（需要 Debian 12 或 13）"
# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "debian" ]] || ! [[ "${VERSION_ID:-}" =~ ^(12|12\.[0-9]+|13|13\.[0-9]+)$ ]]; then
    cat >&2 <<EOF
${red}错误：${plain} 本脚本仅支持 Debian 12 (Bookworm) 或 13 (Trixie)，检测到 ID=${ID:-unknown} VERSION_ID=${VERSION_ID:-unknown}。
${red}Error:${plain} This installer supports Debian 12 / 13 only. Detected ID=${ID:-unknown} VERSION_ID=${VERSION_ID:-unknown}.

其他系统请使用旧版 release tag:
For other systems, pick an older release tag:
  https://github.com/TheLastShadow-B/XrayR-release/releases
EOF
    exit 1
fi

# ---------- R2: arch check ----------

arch=$(uname -m)
case "$arch" in
    x86_64|amd64) ARCH_SLUG="linux-64" ;;
    *) die "本脚本仅支持 x86_64 / amd64 架构，检测到: ${arch}" ;;
esac

# ---------- R11: systemd dir sanity ----------

[[ -d /etc/systemd/system && ! -L /etc/systemd/system ]] || die "/etc/systemd/system 不存在或是符号链接，无法安装 systemd 单元"

# ---------- install_base (R4 prerequisite) ----------

install_base() {
    info "安装依赖 (curl ca-certificates unzip tar cron socat)..."
    apt-get update -qq
    apt-get install -y curl ca-certificates unzip tar cron socat
    command -v curl >/dev/null 2>&1 || die "install_base 完成后仍找不到 curl；请检查 apt 源"
}

# ---------- R6: resolve version ----------

resolve_version() {
    local requested="${1:-}"
    local tag=""

    if [[ -n "$requested" ]]; then
        # 用户指定版本
        [[ "$requested" == v* ]] && tag="$requested" || tag="v${requested}"
        if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            die "版本格式无效: ${requested}（期望 vX.Y.Z）"
        fi
        echo "$tag"
        return
    fi

    # 主路径：GitHub API
    local api_body
    api_body=$(curl -sf --max-time 10 "https://api.github.com/repos/TheLastShadow-B/XrayR/releases/latest" 2>/dev/null || true)
    if [[ -n "$api_body" ]]; then
        tag=$(echo "$api_body" | grep '"tag_name":' | head -1 | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')
        if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            echo "$tag"
            return
        fi
    fi

    # 回退：解析 releases/latest 重定向 Location 头（HEAD 请求，不跟随）
    warn "GitHub API 未返回有效版本，回退解析 releases/latest 重定向..."
    tag=$(curl -sI --max-time 10 "https://github.com/TheLastShadow-B/XrayR/releases/latest" \
        | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r' \
        | sed -n 's|^https://github\.com/TheLastShadow-B/XrayR/releases/tag/\(v[0-9][^[:space:]]*\)$|\1|p' \
        | head -1)
    if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        echo "$tag"
        return
    fi

    die "无法解析 XrayR 最新版本（API + Location 回退均失败）"
}

# ---------- R4 + R5: download + integrity ----------

download_and_verify() {
    local tag="$1"
    local url="https://github.com/TheLastShadow-B/XrayR/releases/download/${tag}/XrayR-${ARCH_SLUG}.zip"
    local zip_path="${STAGING}/XrayR-${ARCH_SLUG}.zip"
    local dgst_path="${zip_path}.dgst"

    info "下载 XrayR ${tag} ..."
    curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 10 \
        -o "$zip_path" "$url" \
        || die "下载 XrayR ${tag} 失败: ${url}"

    info "下载校验文件 .dgst ..."
    curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 10 \
        -o "$dgst_path" "${url}.dgst" \
        || die "下载校验文件失败（${url}.dgst 不存在）；无法校验完整性，终止安装"

    # 提取 SHA-256 行。release.yml 用 `openssl dgst -sha256` + sed 剥掉 (filename)，
    # 现代 OpenSSL 输出行头为 "SHA2-256=" (旧版为 "SHA256=")，两种都接受。
    local expected actual
    expected=$(awk '/^(SHA2-256|SHA256)=/{print $NF}' "$dgst_path" | head -1)
    [[ -n "$expected" ]] || die "校验文件中未找到 SHA256 行"

    actual=$(sha256sum "$zip_path" | awk '{print $1}')

    if [[ "$expected" != "$actual" ]]; then
        die "SHA256 校验失败（文件可能被篡改或下载损坏）
  expected: $expected
  actual:   $actual"
    fi
    info "SHA256 校验通过: ${actual:0:16}..."
}

# ---------- R7: install / upgrade with deny-list preservation ----------

install_xrayr() {
    local zip_path="${STAGING}/XrayR-${ARCH_SLUG}.zip"

    # 清空 /usr/local/XrayR（无操作者状态）并解压
    rm -rf /usr/local/XrayR
    mkdir -p /usr/local/XrayR
    (cd /usr/local/XrayR && unzip -q "$zip_path")

    chmod +x /usr/local/XrayR/XrayR
    [[ -f /usr/local/XrayR/XrayR ]] || die "解压后找不到 XrayR 二进制"

    # 确保 /etc/XrayR 存在
    mkdir -p /etc/XrayR

    # 总是覆盖 geoip / geosite
    cp -f /usr/local/XrayR/geoip.dat   /etc/XrayR/geoip.dat
    cp -f /usr/local/XrayR/geosite.dat /etc/XrayR/geosite.dat

    # 仅在缺失时写入默认配置文件（保留既有）
    local f
    for f in config.yml dns.json route.json custom_outbound.json custom_inbound.json rulelist; do
        if [[ ! -f "/etc/XrayR/$f" && -f "/usr/local/XrayR/$f" ]]; then
            cp "/usr/local/XrayR/$f" "/etc/XrayR/$f"
        fi
    done

    # systemd unit：首次安装写入；已存在则保留（R7 / R21）
    if [[ ! -f /etc/systemd/system/XrayR.service ]]; then
        curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 10 \
            -o /etc/systemd/system/XrayR.service \
            "https://raw.githubusercontent.com/TheLastShadow-B/XrayR-release/master/XrayR.service" \
            || die "下载 XrayR.service 失败"
        systemctl daemon-reload
        systemctl enable XrayR >/dev/null 2>&1 || true
    fi
}

# ---------- R9: management script ----------

install_mgmt_script() {
    curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 10 \
        -o /usr/bin/XrayR \
        "https://raw.githubusercontent.com/TheLastShadow-B/XrayR-release/master/XrayR.sh" \
        || die "下载 XrayR 管理脚本失败"
    chmod +x /usr/bin/XrayR
    ln -sf /usr/bin/XrayR /usr/bin/xrayr
}

# ---------- R22: config drift detection ----------

# 比对本地 /etc/XrayR/ 下的模板文件与发行包中的新模板，内容不同则写 .new 并提示
# 用户手动合并。本函数从不修改既有配置本身（与 R7 一致）。
DRIFTED_FILES=()
check_config_drift() {
    local f src dst
    for f in config.yml dns.json route.json custom_outbound.json custom_inbound.json rulelist; do
        src="/usr/local/XrayR/$f"
        dst="/etc/XrayR/$f"
        [[ -f "$src" && -f "$dst" ]] || continue
        if ! cmp -s "$src" "$dst"; then
            cp -f "$src" "${dst}.new"
            DRIFTED_FILES+=("$f")
        else
            # 上次升级留下的 .new 若内容现已与本地一致，顺手清理
            rm -f "${dst}.new"
        fi
    done
}

print_drift_banner() {
    [[ ${#DRIFTED_FILES[@]} -eq 0 ]] && return 0
    echo
    echo -e "${yellow}⚠️  检测到新版模板与本地配置存在差异：${plain}"
    local f
    for f in "${DRIFTED_FILES[@]}"; do
        echo -e "${yellow}    /etc/XrayR/${f}.new${plain}"
    done
    echo
    echo -e "${yellow}    查看差异:  diff /etc/XrayR/${DRIFTED_FILES[0]}{,.new}${plain}"
    echo -e "${yellow}    按需手动合并；合并后可删除对应 .new 文件${plain}"
    echo
}

# ---------- R10: Hy2 pre-flight banner ----------

hy2_preflight_check() {
    # 匹配：行首空白（非 #）+ NodeType: + 可选引号 + Hysteria2 + 可选引号 + 可选尾部注释
    local pat='^[[:space:]]*NodeType:[[:space:]]*["'\'']?Hysteria2["'\'']?[[:space:]]*(#.*)?$'
    if [[ -f /etc/XrayR/config.yml ]] && grep -Eq "$pat" /etc/XrayR/config.yml; then
        echo
        echo -e "${yellow}⚠️  Hysteria 2 节点检测到。请确认：${plain}"
        echo -e "${yellow}   1. CertConfig.CertMode 必须是 file / http / dns（none 会启动失败）${plain}"
        echo -e "${yellow}   2. 对应监听端口（UDP）必须在防火墙与安全组放行${plain}"
        echo
    fi
}

# ---------- main ----------

info "开始安装 XrayR (TheLastShadow-B fork)"
install_base

STAGING=$(mktemp -d -t xrayr-install.XXXXXX)
TAG=$(resolve_version "${1:-}")
info "目标版本: ${TAG}"

download_and_verify "$TAG"
install_xrayr
install_mgmt_script

# 启动或重启服务
if systemctl is-active --quiet XrayR; then
    systemctl restart XrayR
    sleep 2
    if systemctl is-active --quiet XrayR; then
        info "XrayR 重启成功"
    else
        warn "XrayR 重启失败，请使用 XrayR log 查看日志"
    fi
else
    if [[ -f /etc/XrayR/config.yml ]]; then
        # 初次安装的 config.yml 来自模板，未必已被编辑 — 不自动启动，提示操作者
        info ""
        info "安装完成。请先编辑 /etc/XrayR/config.yml，配置面板/节点后执行："
        info "  XrayR start"
        info ""
        info "详细文档: https://github.com/TheLastShadow-B/XrayR"
    fi
fi

check_config_drift
print_drift_banner
hy2_preflight_check

cat <<'EOF'

XrayR 管理脚本使用方法 (兼容 xrayr，大小写不敏感):
------------------------------------------
XrayR                    - 显示管理菜单 (功能更多)
XrayR start              - 启动 XrayR
XrayR stop               - 停止 XrayR
XrayR restart            - 重启 XrayR
XrayR status             - 查看 XrayR 状态
XrayR enable             - 设置 XrayR 开机自启
XrayR disable            - 取消 XrayR 开机自启
XrayR log                - 查看 XrayR 日志
XrayR update             - 更新 XrayR
XrayR update x.x.x       - 更新 XrayR 指定版本
XrayR config             - 显示配置文件内容
XrayR install            - 安装 XrayR
XrayR uninstall          - 卸载 XrayR
XrayR version            - 查看 XrayR 版本
------------------------------------------
EOF
