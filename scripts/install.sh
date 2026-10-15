#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
DEPLOY_DIR="${PROJECT_DIR}/deploy"
CONFIG_SOURCE=""
BINARY_SOURCE=""
USE_RELEASE=0
START_SERVICE=1
REPOSITORY="${BITSRUN_REPOSITORY:-CloudYunLight/BitSrunLoginGo-service}"
VERSION="${BITSRUN_VERSION:-latest}"
MIRRORS=("" "https://ghproxy.net/" "https://gh-proxy.com/")

usage() {
    cat <<'EOF'
用法: ./scripts/install.sh [选项]

选项:
  --config <路径>       使用指定配置文件，默认使用仓库根目录的 Config.yaml
  --binary <路径>       安装指定的 bitsrun 可执行文件
  --release             即使存在源码，也下载预编译 Release
  --repository <仓库>   Release 仓库，格式为 owner/repo
  --version <版本>      Release 标签，默认 latest
  --no-start            安装后暂不启动服务
  -h, --help            显示帮助

环境变量 BITSRUN_MIRRORS 可追加以空格分隔的下载镜像前缀。
EOF
}

while (($# > 0)); do
    case "$1" in
        --config|--binary|--repository|--version)
            if (($# < 2)); then
                echo "选项 $1 缺少参数" >&2
                exit 2
            fi
            case "$1" in
                --config) CONFIG_SOURCE=$2 ;;
                --binary) BINARY_SOURCE=$2 ;;
                --repository) REPOSITORY=$2 ;;
                --version) VERSION=$2 ;;
            esac
            shift 2
            ;;
        --release) USE_RELEASE=1; shift ;;
        --no-start) START_SERVICE=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知选项: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -n ${BITSRUN_MIRRORS:-} ]]; then
    read -r -a EXTRA_MIRRORS <<<"${BITSRUN_MIRRORS}"
    MIRRORS+=("${EXTRA_MIRRORS[@]}")
fi

for command_name in awk curl find getent install systemctl tar useradd; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "缺少必要命令: ${command_name}" >&2
        exit 1
    fi
done
if [[ $(uname -s) != Linux ]] || [[ ! -d /run/systemd/system ]]; then
    echo "当前安装器仅支持使用 systemd 的 Linux 系统。" >&2
    exit 1
fi
for deploy_file in bitsrun.service bitsrun-config-reload.service bitsrun-config.path bitsrunctl Config.example.yaml; do
    if [[ ! -f ${DEPLOY_DIR}/${deploy_file} ]]; then
        echo "缺少部署文件: ${DEPLOY_DIR}/${deploy_file}" >&2
        exit 1
    fi
done

TEMP_DIR=$(mktemp -d)
if [[ -z ${TEMP_DIR} || ! -d ${TEMP_DIR} ]]; then
    echo "无法创建临时目录" >&2
    exit 1
fi
cleanup() {
    rm -rf -- "${TEMP_DIR}"
}
trap cleanup EXIT

run_root() {
    if [[ ${EUID} -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "安装系统服务需要 root 权限，且系统未安装 sudo。" >&2
        exit 1
    fi
}

platform() {
    case "$(uname -m)" in
        x86_64|amd64) GOARCH=amd64; RELEASE_ARCH=amd64 ;;
        i386|i486|i586|i686) GOARCH=386; RELEASE_ARCH=386 ;;
        aarch64|arm64) GOARCH=arm64; RELEASE_ARCH=arm64 ;;
        armv7l) GOARCH=arm; GOARM=7; RELEASE_ARCH=arm_v7 ;;
        armv6l) GOARCH=arm; GOARM=6; RELEASE_ARCH=arm_v6 ;;
        riscv64) GOARCH=riscv64; RELEASE_ARCH=riscv64 ;;
        *) echo "暂不支持的处理器架构: $(uname -m)" >&2; exit 1 ;;
    esac
}

select_download_url() {
    local origin_url=$1
    local prefix candidate
    for prefix in "${MIRRORS[@]}"; do
        candidate="${prefix}${origin_url}"
        echo "探测下载源: ${candidate}" >&2
        if curl -fsIL --connect-timeout 4 --max-time 12 "${candidate}" >/dev/null; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

select_goproxy() {
    local proxy
    for proxy in https://proxy.golang.org https://goproxy.cn https://goproxy.io; do
        echo "探测 Go 模块源: ${proxy}" >&2
        if curl -fsSL --connect-timeout 3 --max-time 8 "${proxy}/golang.org/x/text/@v/list" -o /dev/null; then
            printf '%s,direct\n' "${proxy}"
            return
        fi
    done
    printf 'direct\n'
}

select_go_download_url() {
    local archive=$1
    local candidate
    local candidates=(
        "https://go.dev/dl/${archive}"
        "https://mirrors.aliyun.com/golang/${archive}"
        "https://golang.google.cn/dl/${archive}"
    )
    for candidate in "${candidates[@]}"; do
        echo "探测 Go 工具链源: ${candidate}" >&2
        if curl -fsIL --connect-timeout 4 --max-time 12 "${candidate}" >/dev/null; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

build_from_source() {
    local go_version go_archive selected_url goproxy
    go_version=$(awk '$1 == "go" {print $2; exit}' "${PROJECT_DIR}/go.mod")
    if [[ -z ${go_version} ]]; then
        echo "无法从 go.mod 读取 Go 版本" >&2
        exit 1
    fi
    go_archive="go${go_version}.linux-${GOARCH}.tar.gz"
    selected_url=$(select_go_download_url "${go_archive}") || {
        echo "没有可用的 Go 工具链下载源" >&2
        exit 1
    }
    echo "下载临时 Go ${go_version}（不会安装到系统）..."
    curl -fL --retry 2 "${selected_url}" -o "${TEMP_DIR}/${go_archive}"
    tar -xzf "${TEMP_DIR}/${go_archive}" -C "${TEMP_DIR}"
    goproxy=$(select_goproxy)
    echo "使用 Go 模块源: ${goproxy}"
    (
        cd "${PROJECT_DIR}"
        env CGO_ENABLED=0 GOOS=linux GOARCH="${GOARCH}" GOARM="${GOARM:-}" \
            GOPROXY="${goproxy}" GOTOOLCHAIN=local \
            "${TEMP_DIR}/go/bin/go" build -trimpath -ldflags "-s -w" \
            -o "${TEMP_DIR}/bitsrun" ./cmd/bitsrun
    )
    BINARY_SOURCE="${TEMP_DIR}/bitsrun"
}

download_release() {
    local archive="bitsrun_linux_${RELEASE_ARCH}.tar.gz"
    local api_url metadata tag asset_url selected_url
    api_url="https://api.github.com/repos/${REPOSITORY}/releases/${VERSION}"
    if [[ ${VERSION} != latest ]]; then
        api_url="https://api.github.com/repos/${REPOSITORY}/releases/tags/${VERSION}"
    fi
    if ! selected_url=$(select_download_url "${api_url}"); then
        echo "无法访问 GitHub Release API，可通过 BITSRUN_MIRRORS 增加镜像。" >&2
        exit 1
    fi
    metadata="${TEMP_DIR}/release.json"
    curl -fsSL --retry 2 "${selected_url}" -o "${metadata}"
    tag=$(awk -F '"' '/"tag_name"[[:space:]]*:/ {print $4; exit}' "${metadata}")
    asset_url=$(awk -F '"' -v name="/${archive}" '/"browser_download_url"[[:space:]]*:/ && index($4, name) {print $4; exit}' "${metadata}")
    if [[ -z ${tag} || -z ${asset_url} ]]; then
        echo "Release ${VERSION} 中没有适用于当前架构的 ${archive}" >&2
        exit 1
    fi
    selected_url=$(select_download_url "${asset_url}") || {
        echo "没有可用的 Release 下载源" >&2
        exit 1
    }
    echo "下载 ${REPOSITORY} ${tag}: ${archive}"
    curl -fL --retry 2 "${selected_url}" -o "${TEMP_DIR}/${archive}"
    mkdir "${TEMP_DIR}/release"
    tar -xzf "${TEMP_DIR}/${archive}" -C "${TEMP_DIR}/release"
    BINARY_SOURCE=$(find "${TEMP_DIR}/release" -type f -name bitsrun -print -quit)
    if [[ -z ${BINARY_SOURCE} ]]; then
        echo "Release 压缩包中未找到 bitsrun" >&2
        exit 1
    fi
}

platform
if [[ -n ${BINARY_SOURCE} ]]; then
    if [[ ! -f ${BINARY_SOURCE} ]]; then
        echo "指定的可执行文件不存在: ${BINARY_SOURCE}" >&2
        exit 1
    fi
elif [[ ${USE_RELEASE} -eq 0 && -f ${PROJECT_DIR}/go.mod && -d ${PROJECT_DIR}/cmd/bitsrun ]]; then
    build_from_source
else
    download_release
fi

if [[ -z ${CONFIG_SOURCE} && -f ${PROJECT_DIR}/Config.yaml ]]; then
    CONFIG_SOURCE="${PROJECT_DIR}/Config.yaml"
fi
if [[ -n ${CONFIG_SOURCE} && ! -f ${CONFIG_SOURCE} ]]; then
    echo "指定的配置文件不存在: ${CONFIG_SOURCE}" >&2
    exit 1
fi

echo "安装 bitsrun 和 systemd 服务..."
if ! getent passwd bitsrun >/dev/null 2>&1; then
    NOLOGIN_SHELL=$(command -v nologin || true)
    if [[ -z ${NOLOGIN_SHELL} ]]; then
        NOLOGIN_SHELL=/usr/sbin/nologin
    fi
    run_root useradd --system --home-dir /var/lib/bitsrun --shell "${NOLOGIN_SHELL}" bitsrun
fi
run_root install -d -m 0750 -o bitsrun -g bitsrun /var/lib/bitsrun
run_root install -d -m 0750 -o root -g bitsrun /etc/bitsrun
run_root install -m 0755 "${BINARY_SOURCE}" /usr/local/bin/bitsrun
run_root install -m 0755 "${DEPLOY_DIR}/bitsrunctl" /usr/local/bin/bitsrunctl
run_root install -m 0644 "${DEPLOY_DIR}/bitsrun.service" /etc/systemd/system/bitsrun.service
run_root install -m 0644 "${DEPLOY_DIR}/bitsrun-config-reload.service" /etc/systemd/system/bitsrun-config-reload.service
run_root install -m 0644 "${DEPLOY_DIR}/bitsrun-config.path" /etc/systemd/system/bitsrun-config.path

CONFIG_READY=1
if [[ -n ${CONFIG_SOURCE} ]]; then
    run_root install -m 0640 -o root -g bitsrun "${CONFIG_SOURCE}" /etc/bitsrun/Config.yaml
elif [[ ! -f /etc/bitsrun/Config.yaml ]]; then
    run_root install -m 0640 -o root -g bitsrun "${DEPLOY_DIR}/Config.example.yaml" /etc/bitsrun/Config.yaml
    CONFIG_READY=0
    echo "已安装示例配置，请先运行 bitsrunctl config 填写账号和密码。"
else
    run_root chown root:bitsrun /etc/bitsrun/Config.yaml
    run_root chmod 0640 /etc/bitsrun/Config.yaml
fi

run_root systemctl daemon-reload
run_root systemctl enable bitsrun.service bitsrun-config.path
run_root systemctl start bitsrun-config.path
if [[ ${START_SERVICE} -eq 1 && ${CONFIG_READY} -eq 1 ]]; then
    run_root systemctl restart bitsrun.service
    systemctl status bitsrun.service --no-pager || true
else
    echo "服务尚未启动；配置完成后运行: bitsrunctl start"
fi

echo "安装完成。常用命令: bitsrunctl status | restart | logs | config"
