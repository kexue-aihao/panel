#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_REPO="kexue-aihao/panel"
REPO="${ACEPANEL_REPO:-$DEFAULT_REPO}"
ACTION="auto"
VERSION="latest"
ROOT=""
WORK_DIR=""
BACKUP_DIR=""
UNIT_FILE="/etc/systemd/system/acepanel.service"
CLI_FILE="/usr/local/sbin/acepanel"
MUTATING=0
COMMITTED=0
CREATED_UNIT=0
CREATED_CONFIG=0
WAS_ACTIVE=0
UNIT_ORIGINAL=""
PANEL_DIR=""

fail() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
用法：install.sh [install|upgrade] [--version VERSION] [--repo OWNER/REPO]

默认自动检测安装状态：未安装时安装，已安装时升级。
EOF
}

while (($#)); do
    case "$1" in
        install|upgrade)
            [[ "$ACTION" == auto ]] || fail "只能指定一个操作"
            ACTION="$1"
            shift
            ;;
        --version)
            (($# >= 2)) || fail "--version 缺少参数"
            VERSION="$2"
            shift 2
            ;;
        --repo)
            (($# >= 2)) || fail "--repo 缺少参数"
            REPO="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "未知参数：$1"
            ;;
    esac
done

[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "GitHub 仓库格式无效：$REPO"
[[ "$VERSION" == latest || "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || fail "版本号格式无效：$VERSION"
[[ "$(id -u)" -eq 0 ]] || fail "请使用 root 运行"
command -v systemctl >/dev/null 2>&1 || fail "系统未安装 systemd"
command -v unzip >/dev/null 2>&1 || fail "请先安装 unzip"
command -v sha256sum >/dev/null 2>&1 || fail "请先安装 sha256sum"

if command -v curl >/dev/null 2>&1; then
    download() {
        curl --connect-timeout 10 --retry 3 --retry-delay 2 -fsSL "$1" -o "$2"
    }
    download_text() {
        curl --connect-timeout 10 --retry 3 --retry-delay 2 -fsSL "$1"
    }
elif command -v wget >/dev/null 2>&1; then
    download() {
        wget -q --timeout=10 --tries=4 -O "$2" "$1"
    }
    download_text() {
        wget -q --timeout=10 --tries=4 -O - "$1"
    }
else
    fail "请先安装 curl 或 wget"
fi

config_root() {
    local file="$1"
    awk '
        /^[[:space:]]*app:[[:space:]]*($|#)/ { in_app = 1; next }
        in_app && /^[^[:space:]#]/ { in_app = 0 }
        in_app && /^[[:space:]]+root:[[:space:]]*/ {
            sub(/^[[:space:]]+root:[[:space:]]*/, "")
            sub(/[[:space:]]+#.*$/, "")
            gsub(/[\047\042]/, "")
            print
            exit
        }
    ' "$file"
}

unit_property() {
    local file="$1" key="$2"
    sed -n "s/^[[:space:]]*${key}=[[:space:]]*//p" "$file" | head -n 1
}

on_exit() {
    local status="$1"
    trap - EXIT
    if [[ "$MUTATING" -eq 1 && "$COMMITTED" -eq 0 ]]; then
        printf '操作失败，正在恢复旧程序文件...\n' >&2
        if [[ -f "$BACKUP_DIR/ace" ]]; then
            cp -a "$BACKUP_DIR/ace" "$PANEL_DIR/.ace.rollback" && mv -f "$PANEL_DIR/.ace.rollback" "$PANEL_DIR/ace"
        else
            rm -f "$PANEL_DIR/ace"
        fi
        if [[ -f "$BACKUP_DIR/cli" ]]; then
            cp -a "$BACKUP_DIR/cli" "$PANEL_DIR/.cli.rollback" && mv -f "$PANEL_DIR/.cli.rollback" "$PANEL_DIR/cli"
        else
            rm -f "$PANEL_DIR/cli"
        fi
        if [[ -f "$BACKUP_DIR/acepanel" ]]; then
            cp -a "$BACKUP_DIR/acepanel" "$CLI_FILE.rollback" && mv -f "$CLI_FILE.rollback" "$CLI_FILE"
        else
            rm -f "$CLI_FILE"
        fi
        if [[ "$CREATED_UNIT" -eq 1 ]]; then
            systemctl disable acepanel >/dev/null 2>&1 || true
            rm -f "$UNIT_FILE"
        fi
        if [[ "$CREATED_CONFIG" -eq 1 ]]; then
            rm -f "$CONFIG_FILE"
        fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        if [[ "$WAS_ACTIVE" -eq 1 ]]; then
            systemctl start acepanel >/dev/null 2>&1 || true
        else
            systemctl stop acepanel >/dev/null 2>&1 || true
        fi
        printf '备份位置：%s\n' "$BACKUP_DIR" >&2
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
    exit "$status"
}

if [[ ! -d /run/systemd/system ]] || ! systemctl --version >/dev/null 2>&1; then
    fail "systemd 未運行，無法管理 acepanel 服務"
fi

UNIT_ORIGINAL="$(systemctl show --property=FragmentPath --value acepanel 2>/dev/null || true)"
if [[ -z "$UNIT_ORIGINAL" || ! -f "$UNIT_ORIGINAL" ]]; then
    if [[ -f "$UNIT_FILE" ]]; then
        UNIT_ORIGINAL="$UNIT_FILE"
    elif [[ -f /usr/lib/systemd/system/acepanel.service ]]; then
        UNIT_ORIGINAL="/usr/lib/systemd/system/acepanel.service"
    elif [[ -f /lib/systemd/system/acepanel.service ]]; then
        UNIT_ORIGINAL="/lib/systemd/system/acepanel.service"
    else
        UNIT_ORIGINAL=""
    fi
fi

CONFIG_FILE="/opt/ace/panel/storage/config.yml"
CONFIG_ROOT=""
if [[ -f "$CONFIG_FILE" ]]; then
    CONFIG_ROOT="$(config_root "$CONFIG_FILE")"
fi

UNIT_WORKDIR=""
UNIT_EXEC=""
if [[ -n "$UNIT_ORIGINAL" ]]; then
    UNIT_WORKDIR="$(unit_property "$UNIT_ORIGINAL" WorkingDirectory)"
    UNIT_EXEC="$(unit_property "$UNIT_ORIGINAL" ExecStart)"
    [[ "$UNIT_EXEC" =~ (^|/)ace([[:space:]]|$) ]] || fail "$UNIT_ORIGINAL 不是可识别的 AcePanel 服务配置"
fi

if [[ -n "$CONFIG_ROOT" ]]; then
    ROOT="$CONFIG_ROOT"
elif [[ "$UNIT_WORKDIR" == */panel ]]; then
    ROOT="${UNIT_WORKDIR%/panel}"
elif [[ "$UNIT_EXEC" == */panel/ace* ]]; then
    ROOT="${UNIT_EXEC%%/panel/ace*}"
else
    ROOT="/opt/ace"
fi

[[ "$ROOT" == /* && "$ROOT" != "/" && "$ROOT" != *[[:space:]]* ]] || fail "无法安全识别面板目录：$ROOT"
PANEL_DIR="$ROOT/panel"
if [[ -n "$UNIT_WORKDIR" && "$UNIT_WORKDIR" != "$PANEL_DIR" ]]; then
    fail "配置中的面板目录与 acepanel.service 不一致，请先检查 $CONFIG_FILE 和 $UNIT_ORIGINAL"
fi

INSTALLED=0
if [[ -n "$UNIT_ORIGINAL" ]]; then
    INSTALLED=1
fi
if [[ -x "$PANEL_DIR/ace" && -f "$CONFIG_FILE" && -f "$PANEL_DIR/storage/panel.db" ]]; then
    INSTALLED=1
fi

if [[ "$INSTALLED" -eq 0 && -d "$PANEL_DIR/storage" ]]; then
    if [[ -f "$PANEL_DIR/storage/config.yml" || -f "$PANEL_DIR/storage/panel.db" ]] || \
        find "$PANEL_DIR/storage" -mindepth 1 ! -path "$PANEL_DIR/storage/logs" ! -path "$PANEL_DIR/storage/logs/*" -print -quit | grep -q .; then
        fail "发现未关联到 acepanel 服务的数据：$PANEL_DIR/storage；为避免覆盖，请先确认现有安装"
    fi
fi

if [[ "$ACTION" == auto ]]; then
    if [[ "$INSTALLED" -eq 1 ]]; then
        ACTION=upgrade
    else
        ACTION=install
    fi
elif [[ "$ACTION" == upgrade && "$INSTALLED" -eq 0 ]]; then
    fail "未发现可升级的 AcePanel 安装"
elif [[ "$ACTION" == install && "$INSTALLED" -eq 1 ]]; then
    fail "检测到已有 AcePanel 安装，请使用 upgrade 或不指定操作"
fi

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) fail "不支持的系统架构：$ARCH" ;;
esac

if [[ "$VERSION" == latest ]]; then
    RELEASE_JSON="$(download_text "https://api.github.com/repos/$REPO/releases/latest")" || fail "无法读取 GitHub 最新 Release"
    RELEASE_TAG="$(printf '%s\n' "$RELEASE_JSON" | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
else
    RELEASE_TAG="$VERSION"
    [[ "$RELEASE_TAG" == v* ]] || RELEASE_TAG="v$RELEASE_TAG"
fi
[[ -n "$RELEASE_TAG" ]] || fail "GitHub 未返回有效的 Release 版本"
TAG="${RELEASE_TAG#v}"
[[ "$TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || fail "Release 版本格式无效：$TAG"

ARCHIVE="panel_${TAG}_linux_${ARCH}.zip"
RELEASE_URL="https://github.com/$REPO/releases/download/$RELEASE_TAG"
WORK_DIR="$(mktemp -d /tmp/acepanel-install.XXXXXX)"
trap 'on_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '正在下载 AcePanel %s (%s)...\n' "$TAG" "$ARCH"
download "$RELEASE_URL/$ARCHIVE" "$WORK_DIR/$ARCHIVE" || fail "下载发布包失败：$ARCHIVE"
download "$RELEASE_URL/panel_${TAG}_checksums.txt" "$WORK_DIR/checksums.txt" || fail "下载校验文件失败"
EXPECTED_HASH="$(awk -v name="$ARCHIVE" '$2 == name { print $1; exit }' "$WORK_DIR/checksums.txt")"
[[ "$EXPECTED_HASH" =~ ^[[:xdigit:]]{64}$ ]] || fail "校验文件中没有 $ARCHIVE 的 SHA-256"
printf '%s  %s\n' "$EXPECTED_HASH" "$ARCHIVE" | (cd "$WORK_DIR" && sha256sum -c -) || fail "发布包 SHA-256 校验失败"

mkdir -p "$WORK_DIR/extracted"
unzip -q "$WORK_DIR/$ARCHIVE" -d "$WORK_DIR/extracted" || fail "解压发布包失败"
[[ -f "$WORK_DIR/extracted/ace" && -f "$WORK_DIR/extracted/cli" && -f "$WORK_DIR/extracted/config.example.yml" ]] || fail "发布包缺少必要文件"

if [[ -n "$UNIT_ORIGINAL" ]] && systemctl is-active --quiet acepanel; then
    WAS_ACTIVE=1
fi

BACKUP_DIR="$ROOT/backup/installer-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$BACKUP_DIR"
if [[ -e "$PANEL_DIR/ace" ]]; then cp -a "$PANEL_DIR/ace" "$BACKUP_DIR/ace"; fi
if [[ -e "$PANEL_DIR/cli" ]]; then cp -a "$PANEL_DIR/cli" "$BACKUP_DIR/cli"; fi
if [[ -e "$CLI_FILE" ]]; then cp -a "$CLI_FILE" "$BACKUP_DIR/acepanel"; fi
if [[ -n "$UNIT_ORIGINAL" ]]; then cp -a "$UNIT_ORIGINAL" "$BACKUP_DIR/acepanel.service"; fi

MUTATING=1
if [[ -n "$UNIT_ORIGINAL" ]]; then
    systemctl stop acepanel
fi

mkdir -p "$PANEL_DIR/storage/logs" /usr/local/sbin /etc/systemd/system
if [[ ! -f "$CONFIG_FILE" ]]; then
    [[ "$ROOT" == "/opt/ace" ]] || fail "自定义根目录安装缺少 $CONFIG_FILE，请先用旧安装器创建配置"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    install -m 0600 "$WORK_DIR/extracted/config.example.yml" "$CONFIG_FILE"
    CREATED_CONFIG=1
fi

install -m 0700 "$WORK_DIR/extracted/ace" "$PANEL_DIR/.ace.new"
mv -f "$PANEL_DIR/.ace.new" "$PANEL_DIR/ace"
install -m 0700 "$WORK_DIR/extracted/cli" "$PANEL_DIR/.cli.new"
mv -f "$PANEL_DIR/.cli.new" "$PANEL_DIR/cli"
install -m 0700 "$WORK_DIR/extracted/cli" "$CLI_FILE.new"
mv -f "$CLI_FILE.new" "$CLI_FILE"
chmod 0700 "$PANEL_DIR"
chmod 0600 "$CONFIG_FILE"

if [[ -z "$UNIT_ORIGINAL" ]]; then
    cat > "$UNIT_FILE.new" <<EOF
[Unit]
Description=AcePanel
After=syslog.target network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=$PANEL_DIR
ExecStart=$PANEL_DIR/ace
User=root
Restart=always
RestartSec=5
LimitNOFILE=1048576
LimitNPROC=1048576
Delegate=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$UNIT_FILE.new"
    mv -f "$UNIT_FILE.new" "$UNIT_FILE"
    CREATED_UNIT=1
fi

systemctl daemon-reload
if [[ "$CREATED_UNIT" -eq 1 ]]; then
    systemctl enable acepanel
fi
systemctl start acepanel

for _ in {1..30}; do
    if systemctl is-active --quiet acepanel; then
        COMMITTED=1
        printf 'AcePanel %s 已%s，服务运行正常。\n' "$TAG" "$([[ "$ACTION" == install ]] && printf 安装 || printf 升级)"
        printf '备份位置：%s\n' "$BACKUP_DIR"
        exit 0
    fi
    sleep 1
done
fail "acepanel 服务未能在 30 秒内正常启动"

on_exit() {
    local status="$1"
    trap - EXIT
    if [[ "$MUTATING" -eq 1 && "$COMMITTED" -eq 0 ]]; then
        printf '操作失败，正在恢复旧程序文件...\n' >&2
        if [[ -f "$BACKUP_DIR/ace" ]]; then
            cp -a "$BACKUP_DIR/ace" "$PANEL_DIR/.ace.rollback" && mv -f "$PANEL_DIR/.ace.rollback" "$PANEL_DIR/ace"
        else
            rm -f "$PANEL_DIR/ace"
        fi
        if [[ -f "$BACKUP_DIR/cli" ]]; then
            cp -a "$BACKUP_DIR/cli" "$PANEL_DIR/.cli.rollback" && mv -f "$PANEL_DIR/.cli.rollback" "$PANEL_DIR/cli"
        else
            rm -f "$PANEL_DIR/cli"
        fi
        if [[ -f "$BACKUP_DIR/acepanel" ]]; then
            cp -a "$BACKUP_DIR/acepanel" "$CLI_FILE.rollback" && mv -f "$CLI_FILE.rollback" "$CLI_FILE"
        else
            rm -f "$CLI_FILE"
        fi
        if [[ "$CREATED_UNIT" -eq 1 ]]; then
            systemctl disable acepanel >/dev/null 2>&1 || true
            rm -f "$UNIT_FILE"
        fi
        if [[ "$CREATED_CONFIG" -eq 1 ]]; then
            rm -f "$CONFIG_FILE"
        fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        if [[ "$WAS_ACTIVE" -eq 1 ]]; then
            systemctl start acepanel >/dev/null 2>&1 || true
        else
            systemctl stop acepanel >/dev/null 2>&1 || true
        fi
        printf '备份位置：%s\n' "$BACKUP_DIR" >&2
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
    exit "$status"
}
