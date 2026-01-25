#!/bin/bash
# 命令工具箱：本地/GitHub/WebDAV同步命令管理工具
# 核心配置 - 版本号+默认命令名
SCRIPT_VERSION="3.5.0"
DEFAULT_CMD_NAME="cb" 
# 调试模式开关（0=关闭，1=开启，支持 DEBUG=1 cb 启动）
DEBUG=${DEBUG:-0}
# 本地缓存配置（从配置文件读取，默认10条）
declare -A CMD_CACHE
CACHE_INITED=false
# 终端颜色支持判断
if [[ -t 1 && "$TERM" != "dumb" ]]; then
    ROCKET="🚀"
    CLOUD="☁️"
    LOCAL="💻"
    WEBDAV="🔗"
    CONTINUE="➡️"
    SUCCESS="✅"
    ERROR="❌"
    WARNING="⚠️"
    gl_red='\033[31m'
    gl_green='\033[32m'
    gl_yellow='\033[33m'
    gl_blue='\033[94m'
    gl_cyan='\033[36m'
    gl_reset='\033[0m'
    BOLD='\033[1m'
    RESET="${gl_reset}"
    BOLD_CYAN="${BOLD}${gl_cyan}"
    BOLD_YELLOW="${BOLD}${gl_yellow}"
    BOLD_RED="${BOLD}${gl_red}"
else
    ROCKET=""
    CLOUD=""
    LOCAL=""
    WEBDAV=""
    CONTINUE=""
    SUCCESS=""
    ERROR=""
    WARNING=""
    gl_red=''
    gl_green=''
    gl_yellow=''
    gl_blue=''
    gl_cyan=''
    gl_reset=''
    BOLD=''
    RESET=''
    BOLD_CYAN=''
    BOLD_YELLOW=''
    BOLD_RED=''
fi
# 命令类型定义
CMD_TYPE_LOCAL="本地"
CMD_TYPE_PRIVATE_REPO="私仓"
CMD_TYPE_PUBLIC_REPO="公仓"
CMD_TYPE_NETWORK="网络"
# 同步模式定义
SYNC_MODE_LOCAL="Local"
SYNC_MODE_GITHUB="GitHub"
SYNC_MODE_WEBDAV="WebDAV"
# 配置文件路径
CONFIG_DIR="$HOME/.config/cctb"
CONFIG_FILE="$CONFIG_DIR/config"
COMMANDS_FILE="$CONFIG_DIR/commands.json"
TEMP_FILE="$CONFIG_DIR/temp.json"
VERSION_FILE="$CONFIG_DIR/version_local"
CMD_NAME_FILE="$CONFIG_DIR/cmd_name"
GITHUB_BRANCH="main"
# WebDAV配置
WEBDAV_COMMANDS_PATH="cctb/commands.json"
# 最新脚本配置（GitHub拉取路径）
LATEST_SCRIPT_URL="https://raw.githubusercontent.com/withabc/cctb/main/cctb.sh"
LATEST_SCRIPT_PATH="$CONFIG_DIR/cctb_latest"

# 跨平台ISO日期生成（兼容macOS旧版本）
get_iso_date() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        date +%Y-%m-%dT%H:%M:%S%z | sed 's/\([+-][0-9]\{2\}\)\([0-9]\{2\}\)/\1:\2/'
    else
        date -Iseconds
    fi
}

# 按键继续并清屏
press_any_key_continue() {
    echo -e "\n${gl_green}${CONTINUE} 按任意键继续...${gl_reset}"
    read -n 1 -s -r
}

# 带权限处理的文件复制（含sudo权限检查）
copy_with_permission() {
    local src="$1" dest="$2"
    if [[ "$(id -u)" -ne 0 && ! sudo -v 2>/dev/null ]]; then
        error "无sudo权限，无法复制文件到 $dest"
        return 1
    fi
    if [[ "$(id -u)" -eq 0 ]]; then
        cp -f "$src" "$dest" && chmod +x "$dest"
    else
        sudo cp -f "$src" "$dest" && sudo chmod +x "$dest"
    fi
}

# 验证网址格式
is_valid_url() {
    local url="$1"
    # 支持 http, https 和基本域名格式
    [[ "$url" =~ ^(https?://)?[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9](?:\.[a-zA-Z]{2,})+(?:/.*)?$ ]] && return 0 || return 1
}

# 检查依赖工具（含curl）
check_dependency() {
    local tool="$1"
    local install_cmd
    if command -v apt &> /dev/null; then
        install_cmd="sudo apt install $tool"
    elif command -v yum &> /dev/null; then
        install_cmd="sudo yum install $tool"
    elif command -v apk &> /dev/null; then
        install_cmd="sudo apk add $tool"
    elif command -v brew &> /dev/null; then
        install_cmd="brew install $tool"
    else
        install_cmd="请手动安装 $tool"
    fi
    if ! command -v "$tool" &> /dev/null; then
        error "需安装$tool工具：$install_cmd"
        exit 1
    fi
}

# 跨平台base64编码
base64_encode_cross() {
    local input="$1"
    base64 -w 0 "$input"
}

# 跨平台base64解码
base64_decode_cross() {
    local content="$1" output_file="$2"
    echo "$content" | base64 -d > "$output_file"
}

# 解析连续/离散编号
parse_selection() {
    local input="$1" max_num="$2"
    local nums=()
    local IFS=' '
    for item in $input; do
        if [[ "$item" =~ ^-[0-9]+$ || "$item" =~ ^[0-9]+-$ ]]; then
            echo "范围格式错误！需为完整范围（如1-3，不可为1-或-3）" >&2
            return 1
        fi
        if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start=${BASH_REMATCH[1]}
            local end=${BASH_REMATCH[2]}
            if (( start >= 1 && end <= max_num && start <= end )); then
                for ((i=start; i<=end; i++)); do
                    nums+=("$i")
                done
            fi
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            if (( item >= 1 && item <= max_num )); then
                nums+=("$item")
            fi
        fi
    done
    if [[ ${#nums[@]} -eq 0 ]]; then
        echo "无效输入格式！支持：连续（1-3）、离散（1 3）、混合（1-2 4）" >&2
        return 1
    fi
    echo "${nums[@]}" | tr ' ' '\n' | sort -nu
}

# 获取当前工具命令名
get_current_cmd_name() {
    if [[ -f "$CMD_NAME_FILE" ]]; then
        local saved_name=$(cat "$CMD_NAME_FILE" 2>/dev/null | xargs)
        [[ -n "$saved_name" ]] && echo "$saved_name" && return
    fi
    echo "$DEFAULT_CMD_NAME"
}

# 输入错误重试
error_retry() {
    local current_interface="$1"
    error "无效输入"
    case "$current_interface" in
        "main") echo -e "\n${gl_blue}可用选项：00退出 | 99进设置 | 命令编号 | 关键词搜索${gl_reset}" ;;
        "settings") echo -e "\n${gl_blue}可用选项：00返回一级 | 99退出 | 01-07命令管理${gl_reset}" ;;
        "edit") echo -e "\n${gl_blue}可用选项：0返回上级 | 1-$cmd_count 编辑编号${gl_reset}" ;;
        "import") echo -e "\n${gl_blue}可用选项：0返回上级 | 输入正确的JSON文件路径${gl_reset}" ;;
        "webdav_setup") echo -e "\n${gl_blue}可用选项：0返回上级 | 输入正确的WebDAV地址/账号/密码${gl_reset}" ;;
        *) echo -e "\n${gl_blue}请输入有效选项${gl_reset}" ;;
    esac
    echo -e "\n${gl_green}${CONTINUE} 按任意键重新输入...${gl_reset}"
    read -n 1 -s -r
}

# 搜索函数：处理输入判断、回车清空搜索、无效输入重试
cmd_search() {
    local current_search="$1"
    local interface_type="$2"
    local input="$3"
    local new_search is_valid=0

    case "$input" in
        "")
            new_search=""
            ;;
        *)
            if [[ "$input" =~ ^[[:print:]]+$ ]]; then
                new_search="$input"
            else
                error_retry "$interface_type"
                new_search="$current_search"
                is_valid=1
            fi
            ;;
    esac

    echo "$new_search $is_valid"
}

# 从GitHub拉取最新脚本
fetch_latest_script() {
    echo -e "\n${gl_green}${ROCKET} 正在从GitHub拉取最新脚本...${gl_reset}"
    if ! curl -s --connect-timeout 10 --max-time 30 "$LATEST_SCRIPT_URL" -o "$LATEST_SCRIPT_PATH"; then
        error "拉取最新脚本失败（网络超时或仓库不可访问）"
        return 1
    fi
    chmod +x "$LATEST_SCRIPT_PATH" 2>/dev/null
    echo -e "\n${gl_green}${SUCCESS} 最新脚本已保存到 $LATEST_SCRIPT_PATH${gl_reset}"
    return 0
}

# 获取远程脚本版本号（24小时内不重复拉取）
get_remote_version() {
    local cache_file="$CONFIG_DIR/version_latest"
    local cache_ttl=$((24 * 60 * 60))
    local stat_cmd
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local mac_version=$(sw_vers -productVersion | cut -d. -f1-2)
        if [[ "$mac_version" < "10.14" ]]; then
            stat_cmd="stat -f %c"
        else
            stat_cmd="stat -f %m"
        fi
    else
        stat_cmd="stat -c %Y"
    fi
    if [[ -f "$cache_file" && $(( $(date +%s) - $(eval $stat_cmd "$cache_file") )) -lt $cache_ttl ]]; then
        local cached_ver=$(cat "$cache_file" 2>/dev/null)
        if [[ "$cached_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$cached_ver"
            return 0
        fi
    fi
    if [[ ! -f "$LATEST_SCRIPT_PATH" || $(( $(date +%s) - $(eval $stat_cmd "$LATEST_SCRIPT_PATH") )) -gt 3600 ]]; then
        if ! fetch_latest_script; then
            return 1
        fi
    fi
    local remote_version=$(grep -oP '^SCRIPT_VERSION="\K[0-9]+\.[0-9]+\.[0-9]+"' "$LATEST_SCRIPT_PATH" | tr -d '"')
    if [[ -n "$remote_version" && "$remote_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$remote_version" > "$cache_file"
        echo "$remote_version"
        return 0
    fi
    error "无法解析远程脚本版本号"
    return 1
}

# 版本对比（0=需更新，1=无需更新）
version_compare() {
    local local_ver="$1" remote_ver="$2"
    IFS='.' read -r -a local_arr <<< "$local_ver"
    IFS='.' read -r -a remote_arr <<< "$remote_ver"
    for i in 0 1 2; do
        local l=${local_arr[$i]:-0}
        local r=${remote_arr[$i]:-0}
        if (( r > l )); then
            return 0
        elif (( r < l )); then
            return 1
        fi
    done
    return 1
}

# 警告提示
warning() {
    echo -e "\n${BOLD_YELLOW}${WARNING}  $1${RESET}"
}

# 错误提示
error() {
    echo -e "\n${BOLD_RED}${ERROR} $1${RESET}"
}

# 统一命令类型标识
get_cmd_type_flag() {
    local cmd_type="$1"
    case "$cmd_type" in
        "$CMD_TYPE_LOCAL") echo -e "${gl_green}[本地💻]${gl_reset}" ;;
        "$CMD_TYPE_PRIVATE_REPO") echo -e "${gl_yellow}[私仓🔒]${gl_reset}" ;;
        "$CMD_TYPE_PUBLIC_REPO") echo -e "${gl_blue}[公仓🌐]${gl_reset}" ;;
        "$CMD_TYPE_NETWORK") echo -e "${gl_cyan}[网络📡]${gl_reset}" ;;
        *) echo -e "${gl_red}[未知❓]${gl_reset}" ;;
    esac
}

# 读取配置文件键值
get_config_value() {
    local key="$1" default="$2"
    local value=$(grep -oP "^$key=\K.*" "$CONFIG_FILE" 2>/dev/null | xargs)
    echo "${value:-$default}"
}
# WebDAV基础工具：生成完整URL
get_webdav_full_url() {
    local webdav_url="$1"
    webdav_url=$(echo "$webdav_url" | sed 's#/*$##')
    echo "${webdav_url}/${WEBDAV_COMMANDS_PATH}"
}

# WebDAV基础工具：测试连接
test_webdav_connection() {
    local webdav_url="$1" webdav_user="$2" webdav_pass_raw="$3"
    local full_url=$(get_webdav_full_url "$webdav_url")
    local parent_url="${full_url%/*}/"
    if curl -s --connect-timeout 15 --max-time 30 \
        -u "${webdav_user}:${webdav_pass_raw}" \
        -X PROPFIND "$parent_url" \
        -H "Depth: 0" >/dev/null 2>&1; then
        if curl -s --connect-timeout 15 --max-time 30 \
            -u "${webdav_user}:${webdav_pass_raw}" \
            -X HEAD "$full_url" >/dev/null 2>&1; then
            return 0
        fi
        return 0
    fi
    if curl -s --connect-timeout 15 --max-time 30 \
        -u "${webdav_user}:${webdav_pass_raw}" \
        -X MKCOL "$parent_url" >/dev/null 2>&1; then
        echo -e "\n${gl_green}${SUCCESS} WebDAV CCTB目录创建成功${gl_reset}"
        return 0
    fi
    error "WebDAV连接失败（无法访问地址或创建目录）"
    return 1
}

# 安全函数：检查高危命令
is_high_risk_cmd() {
    local cmd="$1"
    local risk_patterns=(
        "(^| )sudo( -[a-zA-Z0-9]+)? rm -rf /"
        "(^| )sudo( -[a-zA-Z0-9]+)? rm -rf /.*"
        "(^| )sudo( -[a-zA-Z0-9]+)? rm -rf /\*"
        "(^| )sudo( -[a-zA-Z0-9]+)? dd if=.* of=.*"
        "(^| )sudo( -[a-zA-Z0-9]+)? mv /*"
        "(^| )sudo( -[a-zA-Z0-9]+)? shutdown"
        "(^| )sudo( -[a-zA-Z0-9]+)? reboot"
        "(^| )sudo( -[a-zA-Z0-9]+)? rm -rf ~"
        "(^| )sudo( -[a-zA-Z0-9]+)? rm -rf /home/[a-z0-9_]+"
        "(^| )sudo( -[a-zA-Z0-9]+)? chmod 777 /"
        "(^| )sudo( -[a-zA-Z0-9]+)? chmod 777 /\*"
        "(^| )sudo( -[a-zA-Z0-9]+)? mv /etc /"
        "(^| )sudo( -[a-zA-Z0-9]+)? rm -rf /etc"
        "(^| )sudo( -[a-zA-Z0-9]+)? rm -rf /var"
        "(^| )sudo( -[a-zA-Z0-9]+)? chown .* /"
        "(^| )sudo( -[a-zA-Z0-9]+)? fdisk /dev/"
        "(^| )sudo( -[a-zA-Z0-9]+)? cp .* /etc/passwd"
        "(^| )sudo( -[a-zA-Z0-9]+)? mv .* /etc/"
    )
    for pattern in "${risk_patterns[@]}"; do
        if echo "$cmd" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

# 安全函数：校验GitHub配置完整性
check_github_config() {
    if [[ "$SYNC_MODE" != "$SYNC_MODE_GITHUB" || -z "$GITHUB_REPO" || -z "$GITHUB_TOKEN" ]]; then
        error "GitHub配置不完整"
        return 1
    fi
    return 0
}

# 安全函数：校验WebDAV配置完整性
check_webdav_config() {
    if [[ "$SYNC_MODE" != "$SYNC_MODE_WEBDAV" || -z "$WEBDAV_URL" || -z "$WEBDAV_USER" || -z "$WEBDAV_PASS" ]]; then
        error "WebDAV配置不完整"
        return 1
    fi
    return 0
}

# Base58编解码
BASE58_CHARS="123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
base58_encode() {
    local input="$1"
    local -a bytes
    for ((i=0; i<${#input}; i++)); do
        bytes+=($(printf "%d" "'${input:$i:1}"))
    done
    local -a digits
    for byte in "${bytes[@]}"; do
        local carry=$byte
        for ((j=0; j<${#digits[@]}; j++)); do
            carry=$((carry + digits[j] * 256))
            digits[j]=$((carry % 58))
            carry=$((carry / 58))
        done
        while ((carry > 0)); do
            digits+=($((carry % 58)))
            carry=$((carry / 58))
        done
    done
    local leading_zeros=0
    for byte in "${bytes[@]}"; do
        if ((byte == 0)); then
            ((leading_zeros++))
        else
            break
        fi
    done
    local leading_ones=$(printf "%0.s1" $(seq 1 $leading_zeros))
    local result="$leading_ones"
    for ((j=${#digits[@]}-1; j>=0; j--)); do
        result+=${BASE58_CHARS:digits[j]:1}
    done
    echo -n "$result"
}

base58_decode() {
    local input="$1"
    if ! [[ "$input" =~ ^[${BASE58_CHARS}]+$ ]]; then
        echo ""
        return 1
    fi
    local leading_ones=0
    local len=${#input}
    while ((leading_ones < len)) && [[ "${input:leading_ones:1}" == "1" ]]; do
        ((leading_ones++))
    done
    local -a digits
    for ((i=leading_ones; i<len; i++)); do
        local c="${input:i:1}"
        local idx=-1
        for ((j=0; j<${#BASE58_CHARS}; j++)); do
            if [[ "${BASE58_CHARS:j:1}" == "$c" ]]; then
                idx=$j
                break
            fi
        done
        if ((idx == -1)); then
            echo ""
            return 1
        fi
        local carry=$idx
        for ((j=0; j<${#digits[@]}; j++)); do
            carry=$((carry + digits[j] * 58))
            digits[j]=$((carry % 256))
            carry=$((carry / 256))
        done
        while ((carry > 0)); do
            digits+=($((carry % 256)))
            carry=$((carry / 256))
        done
    done
    local leading_zeros=""
    for ((i=0; i<leading_ones; i++)); do
        leading_zeros+=$'\x00'
    done
    local result="$leading_zeros"
    if [[ ${#digits[@]} -eq 0 ]]; then
        printf "%b" "$result"
        return 0
    fi
    for ((j=${#digits[@]}-1; j>=0; j--)); do
        local value=${digits[j]}
        if ! (( value >= 0 && value <= 255 )); then
            warning "Base58解码值异常（超出0-255范围），已重置为0"
            value=0
        fi
        local hex_str=$(printf "%02x" "$value" 2>/dev/null)
        [[ -z "$hex_str" ]] && hex_str="00"
        result+="\\x$hex_str"
    done
    printf "%b" "$result"
}

# 缓存函数：校验并重置命令文件（重置时清空缓存）
validate_and_reset_commands_file() {
    if ! jq empty "$COMMANDS_FILE" 2>/dev/null; then
        echo '{"commands": []}' > "$COMMANDS_FILE"
        error "命令文件格式错误，已重置"
        clear_cache
        return 1
    fi
    return 0
}

# 缓存函数：初始化缓存
init_cache() {
    if [[ $CACHE_INITED == true ]]; then
        return 0
    fi
    if ! validate_and_reset_commands_file; then
        return 1
    fi
    declare -g CMD_JSON=$(cat "$COMMANDS_FILE" 2>/dev/null)
    CACHE_SIZE=$(get_config_value "CACHE_SIZE" 10)
    declare -g CACHE_FILE="$CONFIG_DIR/cache"
    [[ ! -f "$CACHE_FILE" ]] && touch "$CACHE_FILE"
    CACHE_INITED=true
    if [[ $DEBUG -eq 1 ]]; then
        echo -e "\n${gl_green}${SUCCESS} 本地命令缓存初始化完成（大小：$CACHE_SIZE，缓存文件：$CACHE_FILE）${gl_reset}"
    fi
    return 0
}

# 缓存函数：清空缓存（删除文件后重建，确保清理彻底）
clear_cache() {
    rm -f "$CACHE_FILE"
    touch "$CACHE_FILE"
    CACHE_INITED=false
    if [[ $DEBUG -eq 1 ]]; then
        echo -e "\n${gl_green}${SUCCESS} 本地命令缓存已清空（缓存文件已重建）${gl_reset}"
    fi
}

# 缓存函数：获取缓存命令
get_cached_cmd() {
    local num="$1" search_term="$2"
    local escaped_search=""
    [[ -n "$search_term" ]] && escaped_search=$(printf "%q" "$search_term")
    local cache_key="${escaped_search}_${num}"
    local cmd_data="" cmd_name=""
    local timestamp=$(date +%s)
    local is_hit=0
    if [[ -f "$CACHE_FILE" ]]; then
        local cache_line=$(grep "^$cache_key:" "$CACHE_FILE" | head -1)
        if [[ -n "$cache_line" ]]; then
            cmd_data=$(echo "$cache_line" | cut -d':' -f3-)
            if [[ -n "$search_term" ]]; then
                cmd_name=$(echo "$CMD_JSON" | jq -r --arg k "$search_term" --arg n "$num" '.commands[]? | select((.name | contains($k)) or (.command | contains($k))) | .name' | sed -n "${num}p" 2>/dev/null | xargs)
            else
                cmd_name=$(echo "$CMD_JSON" | jq -r --arg n "$num" '.commands[($n | tonumber)-1]?.name' 2>/dev/null | xargs)
            fi
            is_hit=1
            echo -e "$cmd_data|$cmd_name|$is_hit|$cache_key"
            return 0
        fi
    fi
    if [[ -n "$search_term" ]]; then
        cmd_name=$(echo "$CMD_JSON" | jq -r --arg k "$search_term" --arg n "$num" '.commands[]? | select((.name | contains($k)) or (.command | contains($k))) | .name' | sed -n "${num}p" 2>/dev/null | xargs)
        cmd_data=$(echo "$CMD_JSON" | jq -r --arg k "$search_term" --arg n "$num" '.commands[]? | select((.name | contains($k)) or (.command | contains($k))) | .command' | sed -n "${num}p" 2>/dev/null)
    else
        cmd_name=$(echo "$CMD_JSON" | jq -r --arg n "$num" '.commands[($n | tonumber)-1]?.name' 2>/dev/null | xargs)
        cmd_data=$(echo "$CMD_JSON" | jq -r --arg n "$num" '.commands[($n | tonumber)-1]?.command' 2>/dev/null)
    fi
    cmd_name=${cmd_name:-"未命名命令"}
    if [[ -n "$cmd_data" ]]; then
        local cache_count=$(wc -l < "$CACHE_FILE" 2>/dev/null)
        if [[ "$cache_count" -ge "$CACHE_SIZE" ]]; then
            sort -t ':' -k2 -n "$CACHE_FILE" | tail -n +2 > "$CACHE_FILE.tmp"
            mv "$CACHE_FILE.tmp" "$CACHE_FILE"
        fi
        echo "$cache_key:$timestamp:$cmd_data" >> "$CACHE_FILE"
        is_hit=0
        echo -e "$cmd_data|$cmd_name|$is_hit|$cache_key"
        return 0
    fi
    echo "|$cmd_name|$is_hit|$cache_key"
    return 1
}

# 配置函数：加载配置文件
load_config() {
    if [[ ! -f "$CONFIG_FILE" || ! -r "$CONFIG_FILE" ]]; then
        warning "配置文件不存在或不可读，初始化本地模式"
        setup_local_mode
        eval "$(cat "$CONFIG_FILE")"
        return
    fi
    local config_content=$(cat "$CONFIG_FILE" 2>/dev/null)
    local token_encoded=$(get_config_value "GITHUB_TOKEN")
    local webdav_pass_encoded=$(get_config_value "WEBDAV_PASS")
    
    eval "$(echo -e "$config_content" | grep -vE '^GITHUB_TOKEN=|^WEBDAV_PASS=|^WEBDAV_PASS_RAW=')"
    SYNC_MODE=${SYNC_MODE:-"Local"}
    GITHUB_REPO=${GITHUB_REPO:-$(get_config_value "GITHUB_REPO")}
    WEBDAV_URL=${WEBDAV_URL:-$(get_config_value "WEBDAV_URL")}
    WEBDAV_USER=${WEBDAV_USER:-$(get_config_value "WEBDAV_USER")}
    CACHE_SIZE=${CACHE_SIZE:-$(get_config_value "CACHE_SIZE" 10)}
    
    GITHUB_TOKEN=""
    if [[ -n "$token_encoded" ]]; then
        GITHUB_TOKEN=$(base58_decode "$token_encoded")
        [[ -z "$GITHUB_TOKEN" ]] && { 
            setup_local_mode
            error "GitHub Token解码失败，已自动切换到本地模式，请重新配置GitHub"
            return 1
        }
    fi
    
    WEBDAV_PASS=""
    WEBDAV_PASS_RAW=""
    if [[ "$SYNC_MODE" == "$SYNC_MODE_WEBDAV" && -n "$webdav_pass_encoded" ]]; then
        WEBDAV_PASS="$webdav_pass_encoded"
        WEBDAV_PASS_RAW=$(base58_decode "$webdav_pass_encoded")
        if [[ -z "$WEBDAV_PASS_RAW" ]]; then
            WEBDAV_PASS_RAW="$webdav_pass_encoded"
            warning "WebDAV密码解码失败，3秒后自动进入WebDAV重新配置界面..."
            sleep 3
            setup_webdav_mode
        fi
    fi
}

# 配置函数：配置本地模式
setup_local_mode() {
    local gh_repo=$(get_config_value "GITHUB_REPO" "")
    local gh_token=$(get_config_value "GITHUB_TOKEN" "")
    local wd_url=$(get_config_value "WEBDAV_URL" "")
    local wd_user=$(get_config_value "WEBDAV_USER" "")
    local wd_pass=$(get_config_value "WEBDAV_PASS" "")
    local cache_size=$(get_config_value "CACHE_SIZE" 10)
    
    cat > "$CONFIG_FILE" <<EOF
SYNC_MODE=$SYNC_MODE_LOCAL
GITHUB_REPO=$gh_repo
GITHUB_TOKEN=$gh_token
WEBDAV_URL=$wd_url
WEBDAV_USER=$wd_user
WEBDAV_PASS=$wd_pass
CACHE_SIZE=$cache_size
EOF
    echo -e "\n${gl_green}${SUCCESS} 切换到本地模式！已保留GitHub/WebDAV配置，命令存于 $CONFIG_DIR${gl_reset}"
}

# 配置函数：测试GitHub连接（仅需contents权限）
test_github_connection() {
    local repo="$1" token_raw="$2" token_encoded="$3"
    local test_res=$(curl -s --connect-timeout 10 --max-time 30 -w "%{http_code}" -H "Authorization: token $token_raw" "https://api.github.com/repos/$repo/contents/cctb" 2>/dev/null)
    local http_code=${test_res: -3}
    local test_body=${test_res:0:${#test_res}-3}
    local wd_url="${WEBDAV_URL:-$(get_config_value "WEBDAV_URL" "")}"
    local wd_user="${WEBDAV_USER:-$(get_config_value "WEBDAV_USER" "")}"
    local wd_pass_encoded="${WEBDAV_PASS:-$(get_config_value "WEBDAV_PASS" "")}"
    local cache_size=$(get_config_value "CACHE_SIZE" 10)
    
    if [[ "$http_code" -eq 200 ]]; then
        cat > "$CONFIG_FILE" <<EOF
SYNC_MODE=$SYNC_MODE_GITHUB
GITHUB_REPO=$repo
GITHUB_TOKEN=$token_encoded
WEBDAV_URL=$wd_url
WEBDAV_USER=$wd_user
WEBDAV_PASS=$wd_pass_encoded
CACHE_SIZE=$cache_size
EOF
        echo -e "\n${gl_green}${SUCCESS} GitHub连接成功！${gl_reset}"
        local sync_choice
        while true; do
            read -e -p "$(echo -e "\n${gl_blue}${SUCCESS} 是否从GitHub同步命令？[Y/N/0]：${gl_reset}")" sync_choice
            case "$sync_choice" in
                y|Y|"") 
                    load_config; 
                    echo -e "\n${gl_green}${CONTINUE} 从GitHub同步...${gl_reset}"
                    local res=$(curl -s --connect-timeout 10 --max-time 30 -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/$GITHUB_REPO/contents/cctb/commands.json")
                    if echo "$res" | jq -e '.content' >/dev/null 2>&1; then
                        local content=$(echo "$res" | jq -r '.content')
                        base64_decode_cross "$content" "$COMMANDS_FILE"
                        echo -e "\n${gl_green}${SUCCESS} 从GitHub同步成功！${gl_reset}"
                    else
                        error "同步失败：$(echo "$res" | jq -r '.message // "文件不存在/网络超时"')"
                        echo -e "\n"
                    fi
                    clear_cache;
                    press_any_key_continue;
                    init_config && load_config && init_cache && sync_menu
                    exit 0
                    ;;
                n|N) 
                    press_any_key_continue
                    init_config && load_config && init_cache && sync_menu
                    exit 0
                    ;;
                0) return ;;
                *) error_retry ;;
            esac
        done
    fi
    if [[ "$http_code" -eq 404 ]]; then
        echo -e "\n${gl_yellow}CCTB目录不存在，尝试创建...${gl_reset}"
        local create_res=$(curl -s --connect-timeout 10 --max-time 30 -w "%{http_code}" -X PUT -H "Authorization: token $token_raw" -H "Content-Type: application/json" -d '{"message":"创建cctb目录","content":"","path":"cctb"}' "https://api.github.com/repos/$repo/contents/cctb" 2>/dev/null)
        local create_http_code=${create_res: -3}
        local create_body=${create_res:0:${#create_res}-3}
        if [[ "$create_http_code" -eq 201 ]]; then
            cat > "$CONFIG_FILE" <<EOF
SYNC_MODE=$SYNC_MODE_GITHUB
GITHUB_REPO=$repo
GITHUB_TOKEN=$token_encoded
WEBDAV_URL=$wd_url
WEBDAV_USER=$wd_user
WEBDAV_PASS=$wd_pass_encoded
CACHE_SIZE=$cache_size
EOF
            echo -e "\n${gl_green}${SUCCESS} GitHub连接成功！${gl_reset}"
            local sync_choice
            while true; do
                read -e -p "$(echo -e "\n${gl_blue}${SUCCESS} 是否从GitHub同步命令？[Y/N/0]：${gl_reset}")" sync_choice
                case "$sync_choice" in
                    y|Y|"") 
                        load_config; 
                        echo -e "\n${gl_green}${CONTINUE} 从GitHub同步...${gl_reset}"
                        local res=$(curl -s --connect-timeout 10 --max-time 30 -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/$GITHUB_REPO/contents/cctb/commands.json")
                        if echo "$res" | jq -e '.content' >/dev/null 2>&1; then
                            local content=$(echo "$res" | jq -r '.content')
                            base64_decode_cross "$content" "$COMMANDS_FILE"
                            echo -e "\n${gl_green}${SUCCESS} 从GitHub同步成功！${gl_reset}"
                        else
                            error "同步失败：$(echo "$res" | jq -r '.message // "文件不存在/网络超时"')"
                            echo -e "\n"
                        fi
                        clear_cache;
                press_any_key_continue;
                init_config && load_config && init_cache && sync_menu
                exit 0
                ;;
                    n|N) 
                        press_any_key_continue
                        init_config && load_config && init_cache && sync_menu
                        exit 0
                        ;;
                    0) return ;;
                    *) error_retry ;;
                esac
            done
        else
            local err_msg=$(echo "$create_body" | jq -r '.message // "未知错误"' 2>/dev/null)
            error "连接失败（创建cctb目录失败：$err_msg）"
            setup_local_mode
            press_any_key_continue
            return
        fi
    fi
    local err_msg=$(echo "$test_body" | jq -r '.message // "未知错误（HTTP状态码：'$http_code'）"' 2>/dev/null)
    error "连接失败（测试cctb目录失败：$err_msg）"
    setup_local_mode
    press_any_key_continue
    return
}

# 配置函数：测试WebDAV连接并保存配置
test_webdav_connection_save() {
    local webdav_url="$1" webdav_user="$2" webdav_pass_raw="$3" webdav_pass_encoded="$4" skip_test="${5:-0}"
    
    if [[ -z "$webdav_pass_encoded" ]]; then
        webdav_pass_encoded=$(base58_encode "$webdav_pass_raw")
    fi
    
    local gh_repo=$(get_config_value "GITHUB_REPO" "")
    local gh_token=$(get_config_value "GITHUB_TOKEN" "")
    local cache_size=$(get_config_value "CACHE_SIZE" 10)
    
    if [[ "$skip_test" -ne 1 ]]; then
        if ! test_webdav_connection "$webdav_url" "$webdav_user" "$webdav_pass_raw"; then
            error "WebDAV配置失败，回退到本地模式（已保留GitHub配置）"
            setup_local_mode
            press_any_key_continue
            return
        fi
    fi
    cat > "$CONFIG_FILE" <<EOF
SYNC_MODE=$SYNC_MODE_WEBDAV
GITHUB_REPO=$gh_repo
GITHUB_TOKEN=$gh_token
WEBDAV_URL=$webdav_url
WEBDAV_USER=$webdav_user
WEBDAV_PASS=$webdav_pass_encoded
CACHE_SIZE=$cache_size
EOF
    echo -e "\n${gl_green}${SUCCESS} WebDAV连接成功！${gl_reset}"
    
    local sync_choice
    while true; do
        read -e -p "$(echo -e "\n${gl_blue}${SUCCESS} 是否从WebDAV同步命令？[Y/N/0]：${gl_reset}")" sync_choice
        case "$sync_choice" in
            y|Y|"") 
                load_config;
                sync_from_webdav
                clear_cache;
                press_any_key_continue;
                init_config && load_config && init_cache && sync_menu
                exit 0
                ;;
            n|N) 
                press_any_key_continue
                init_config && load_config && init_cache && sync_menu
                exit 0
                ;;
            0) return ;;
            *) error_retry "webdav_setup" ;;
        esac
    done
}

# 配置函数：配置GitHub模式
setup_github_mode() {
    local ready repo token token_encoded
    load_config
    local existing_repo=$(get_config_value "GITHUB_REPO" "")
    local existing_token_encoded=$(get_config_value "GITHUB_TOKEN" "")
    local existing_token_raw=""
    if [[ -n "$existing_repo" && -n "$existing_token_encoded" ]]; then
        existing_token_raw=$(base58_decode "$existing_token_encoded")
        if [[ -n "$existing_token_raw" && "$existing_token_raw" =~ ^gh[pus]_([0-9a-zA-Z]{36,})$ ]]; then
            echo -e "\n${gl_yellow}${CLOUD} 检测到已保存的GitHub配置，正在测试连接...${gl_reset}"
            if test_github_connection "$existing_repo" "$existing_token_raw" "$existing_token_encoded"; then
                echo -e "\n${gl_green}${SUCCESS} 已保存GitHub配置测试通过，直接使用${gl_reset}"
                press_any_key_continue
                sync_menu
                return
            else
                warning "已保存配置测试失败（仓库不可访问/Token无效），需重新配置"
                press_any_key_continue
            fi
        else
            warning "已保存GitHub Token解码失败，需重新配置"
            press_any_key_continue
        fi
    fi
    while true; do
        print_header
        echo -e "\n${BOLD}${CLOUD} GitHub同步配置${gl_reset}"
        echo -e "\n${gl_yellow}准备：1. 创建GitHub仓库（如cctb-commands） 2. 生成Repo权限Token（仅需contents权限）${gl_reset}"
        echo -e "\n${gl_yellow}[0] 返回上级菜单${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}已完成准备？[Y/N/0]：${gl_reset}")" ready
        case "$ready" in
            y|Y|"")
                while true; do
                    print_header
                    echo -e "\n${BOLD}${CLOUD} 输入GitHub仓库${gl_reset}"
                    echo -e "\n格式：用户名/仓库名（示例：user/repo）"
                    echo -e "\n${gl_yellow}[0] 返回上级菜单${gl_reset}"
                    read -e -p "$(echo -e "\n${gl_blue}GitHub仓库：${gl_reset}")" repo
                    repo=$(echo "$repo" | xargs)
                    if [[ "$repo" == "0" ]]; then
                        return
                    elif [[ "$repo" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
                        break
                    else
                        error_retry
                    fi
                done
                while true; do
                    print_header
                    echo -e "\n${BOLD}${CLOUD} 输入GitHub Token${gl_reset}"
                    echo -e "\nToken需包含contents权限（仅显示一次，将以Base58编码存储）"
                    echo -e "\n${gl_yellow}[0] 返回上级菜单${gl_reset}"
                    read -rs -p "$(echo -e "\n${gl_blue}GitHub Token: ${gl_reset}")" token
                    echo -e ""
                    token=$(echo "$token" | xargs)
                    if [[ "$token" == "0" ]]; then
                        return
                    elif [[ -z "$token" ]]; then
                        error_retry
                        continue
                    elif ! [[ "$token" =~ ^gh[pus]_([0-9a-zA-Z]{36,})$ ]]; then
                        error "Token格式错误！仅支持 ghp_/ghu_/ghs_开头的36位以上字母数字组合（无空格/特殊字符）"
                        error_retry
                        continue
                    else
                        token_encoded=$(base58_encode "$token")
                        if [[ -z "$token_encoded" ]]; then
                            error "Token编码失败，请重新输入"
                            error_retry
                            continue
                        fi
                        break
                    fi
                done
                test_github_connection "$repo" "$token" "$token_encoded"
                return
                ;;
            n|N)
                echo -e "\n${gl_yellow}稍后可通过 $(get_current_cmd_name) --reset 重新配置${gl_reset}"
                setup_local_mode
                echo -e "\n${gl_green}${SUCCESS} 操作完成${gl_reset}"
                press_any_key_continue
                settings
                return
                ;;
            0) return ;;
            *) error_retry ;;
        esac
    done
}

# 配置函数：配置WebDAV模式
setup_webdav_mode() {
    local ready webdav_url webdav_user webdav_pass webdav_pass_encoded
    load_config
    local existing_url=$(get_config_value "WEBDAV_URL" "")
    local existing_user=$(get_config_value "WEBDAV_USER" "")
    local existing_pass_encoded=$(get_config_value "WEBDAV_PASS" "")
    local existing_pass_raw=""
    if [[ -n "$existing_url" && -n "$existing_user" && -n "$existing_pass_encoded" ]]; then
        existing_pass_raw=$(base58_decode "$existing_pass_encoded")
        if [[ -n "$existing_pass_raw" ]]; then
            echo -e "\n${gl_yellow}${WEBDAV} 检测到已保存的WebDAV配置，正在测试连接...${gl_reset}"
            if test_webdav_connection "$existing_url" "$existing_user" "$existing_pass_raw"; then
                test_webdav_connection_save "$existing_url" "$existing_user" "$existing_pass_raw" "$existing_pass_encoded" 1
                return
            else
                warning "已保存配置测试失败（地址不可达/账号密码错误），需重新配置"
                press_any_key_continue
            fi
        else
            warning "已保存WebDAV密码解码失败，需重新配置"
            press_any_key_continue
        fi
    fi
    while true; do
        print_header
        echo -e "\n${BOLD}${WEBDAV} WebDAV同步配置${gl_reset}"
        echo -e "\n${gl_yellow}准备：1. 获取WebDAV服务器地址（如https://dav.example.com） 2. 确认账号密码（需写入权限）${gl_reset}"
        echo -e "\n${gl_yellow}[0] 返回上级菜单${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}已完成准备？[Y/N/0]：${gl_reset}")" ready
        case "$ready" in
            y|Y|"")
                while true; do
                    print_header
                    echo -e "\n${BOLD}${WEBDAV} 输入WebDAV服务器地址${gl_reset}"
                    echo -e "\n格式：完整URL（示例：https://dav.example.com 或 http://192.168.1.100:5005）"
                    echo -e "\n${gl_yellow}[0] 返回上级菜单${gl_reset}"
                    read -e -p "$(echo -e "\n${gl_blue}WebDAV地址：${gl_reset}")" webdav_url
                    webdav_url=$(echo "$webdav_url" | xargs)
                    if [[ "$webdav_url" == "0" ]]; then
                        return
                    elif [[ "$webdav_url" =~ ^https?:// ]]; then
                        break
                    else
                        error "地址格式错误！需以http://或https://开头"
                        error_retry "webdav_setup"
                    fi
                done
                while true; do
                    print_header
                    echo -e "\n${BOLD}${WEBDAV} 输入WebDAV账号${gl_reset}"
                    echo -e "\n${gl_yellow}[0] 返回上级菜单${gl_reset}"
                    read -e -p "$(echo -e "\n${gl_blue}WebDAV账号：${gl_reset}")" webdav_user
                    webdav_user=$(echo "$webdav_user" | xargs)
                    if [[ "$webdav_user" == "0" ]]; then
                        return
                    elif [[ -n "$webdav_user" ]]; then
                        break
                    else
                        error "账号不能为空"
                        error_retry "webdav_setup"
                    fi
                done
                while true; do
                    print_header
                    echo -e "\n${BOLD}${WEBDAV} 输入WebDAV密码${gl_reset}"
                    echo -e "\n密码将以Base58编码存储（仅显示一次）"
                    echo -e "\n${gl_yellow}[0] 返回上级菜单${gl_reset}"
                    read -rs -p "$(echo -e "\n${gl_blue}WebDAV密码: ${gl_reset}")" webdav_pass
                    echo -e ""
                    webdav_pass=$(echo "$webdav_pass" | xargs)
                    if [[ "$webdav_pass" == "0" ]]; then
                        return
                    elif [[ -n "$webdav_pass" ]]; then
                        webdav_pass_encoded=$(base58_encode "$webdav_pass")
                        break
                    else
                        error "密码不能为空"
                        error_retry "webdav_setup"
                    fi
                done
                test_webdav_connection_save "$webdav_url" "$webdav_user" "$webdav_pass" "$webdav_pass_encoded"
                return
                ;;
            n|N)
                echo -e "\n${gl_yellow}稍后可通过 $(get_current_cmd_name) --reset 重新配置${gl_reset}"
                setup_local_mode
                echo -e "\n${gl_green}${SUCCESS} 操作完成${gl_reset}"
                press_any_key_continue
                settings
                return
                ;;
            0) return ;;
            *) error_retry ;;
        esac
    done
}

# 同步函数：同步到GitHub
sync_to_github() {
    local target_menu="${1:-sync_menu}"
    load_config
    check_github_config || return
    local repo="$GITHUB_REPO" token="$GITHUB_TOKEN"
    local stat_cmd
    [[ "$(uname -s)" == "Darwin" ]] && stat_cmd="stat -f %z" || stat_cmd="stat -c %s"
    local file_size=$($stat_cmd "$COMMANDS_FILE" 2>/dev/null || echo 0)
    local max_size=$((80 * 1024 * 1024))
    if [[ $file_size -gt $max_size ]]; then
        error "命令文件过大（${file_size}B），超过GitHub单文件同步限制（80MB）"
        echo -e "\n${gl_yellow}建议：拆分命令到多个文件，或删除不常用命令${gl_reset}"
        press_any_key_continue
        $target_menu
    fi
    echo -e "\n${gl_green}${CONTINUE} 同步到GitHub（仓库：${gl_cyan}$repo${gl_green}）...${gl_reset}"
    local content=$(base64_encode_cross "$COMMANDS_FILE")
    local sha=$(curl -s --connect-timeout 10 --max-time 30 -H "Authorization: token $token" "https://api.github.com/repos/$repo/contents/cctb/commands.json" | jq -r '.sha // ""')
    local api_data=$(jq -n --arg msg "更新命令 $(get_iso_date)" --arg cnt "$content" --arg s "$sha" '{message:$msg, content:$cnt} + (if $s!="" then {sha:$s} else {} end)')
    local res=$(curl -s --connect-timeout 10 --max-time 30 -X PUT -H "Authorization: token $token" -H "Content-Type: application/json" -d "$api_data" "https://api.github.com/repos/$repo/contents/cctb/commands.json")
    if echo "$res" | jq -e '.content' >/dev/null 2>&1; then
        echo -e "\n${gl_green}${SUCCESS} 同步到GitHub成功！仓库：${gl_cyan}$repo${gl_reset}"
    else
        error "同步失败：$(echo "$res" | jq -r '.message // "未知错误/网络超时"')"
    fi
    press_any_key_continue
    $target_menu
}

# 同步函数：从GitHub同步
sync_from_github() {
    check_github_config || return
    echo -e "\n${gl_green}${CONTINUE} 从GitHub同步...${gl_reset}"
    local res=$(curl -s --connect-timeout 10 --max-time 30 -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/$GITHUB_REPO/contents/cctb/commands.json")
    if echo "$res" | jq -e '.content' >/dev/null 2>&1; then
        local content=$(echo "$res" | jq -r '.content')
        base64_decode_cross "$content" "$COMMANDS_FILE"
        echo -e "\n${gl_green}${SUCCESS} 从GitHub同步成功！${gl_reset}"
    else
        error "同步失败：$(echo "$res" | jq -r '.message // "文件不存在/网络超时"')"
        echo -e "\n"
    fi
    press_any_key_continue
    sync_menu
}

# 同步函数：同步到WebDAV
sync_to_webdav() {
    local target_menu="${1:-sync_menu}"
    load_config
    check_webdav_config || return
    
    local webdav_url="$WEBDAV_URL"
    local webdav_user="$WEBDAV_USER"
    local webdav_pass_raw="$WEBDAV_PASS_RAW"
    local full_url=$(get_webdav_full_url "$webdav_url")
    local cctb_dir_url="${full_url%/*}/"
    local stat_cmd
    [[ "$(uname -s)" == "Darwin" ]] && stat_cmd="stat -f %z" || stat_cmd="stat -c %s"
    local file_size=$($stat_cmd "$COMMANDS_FILE" 2>/dev/null || echo 0)
    local max_size=$((100 * 1024 * 1024))
    local dir_exists=false
    local verify_result=$(curl -s --connect-timeout 20 --max-time 30 \
        -u "${webdav_user}:${webdav_pass_raw}" \
        -X PROPFIND "$cctb_dir_url" \
        -H "Depth: 0" \
        -H "Content-Type: application/xml" \
        -w "%{http_code}" 2>&1)
    local verify_http_code="${verify_result: -3}"
    if [[ "$verify_http_code" -eq 207 || "$verify_http_code" -eq 200 ]]; then
        dir_exists=true
    fi
    if ! $dir_exists; then
        local create_result=$(curl -s --connect-timeout 20 --max-time 30 \
            -u "${webdav_user}:${webdav_pass_raw}" \
            -X MKCOL "$cctb_dir_url" \
            -H "Content-Length: 0" \
            -H "Content-Type: application/xml" \
            -w "%{http_code}" 2>&1)
        local create_http_code="${create_result: -3}"
        local create_body="${create_result%???}"
        case "$create_http_code" in
            201|204)
                dir_exists=true
                ;;
            401)
                error "CCTB文件夹创建失败：账号或密码错误（HTTP 401）"
                echo -e "  建议：重新进入「07. 配置设置」检查WebDAV账号密码"
                press_any_key_continue
                $target_menu
                return 1
                ;;
            403)
                error "CCTB文件夹创建失败：账号无写入权限（HTTP 403）"
                echo -e "  建议：联系WebDAV服务器管理员开通「目录创建」权限"
                press_any_key_continue
                $target_menu
                return 1
                ;;
            405)
                error "CCTB文件夹创建失败：服务器禁用MKCOL创建方法（HTTP 405）"
                echo -e "  建议：手动用FileZilla/Rclone创建CCTB文件夹后重试"
                press_any_key_continue
                $target_menu
                return 1
                ;;
            500|503)
                error "CCTB文件夹创建失败：服务器内部错误（HTTP $create_http_code）"
                echo -e "  服务器响应：$create_body"
                press_any_key_continue
                $target_menu
                return 1
                ;;
            *)
                warning "CCTB文件夹创建异常（HTTP $create_http_code），尝试直接同步文件..."
                echo -e "  异常详情：$create_body"
                ;;
        esac
    fi
    [[ $file_size -gt $max_size ]] && warning "命令文件过大（${file_size}B），可能超出WebDAV服务器限制（建议≤100MB）"
    echo -e "\n${gl_green}${CONTINUE} 同步到WebDAV（地址：$full_url）${gl_reset}"
    if curl -s --connect-timeout 20 --max-time 120 \
        -u "${webdav_user}:${webdav_pass_raw}" \
        -T "$COMMANDS_FILE" \
        -H "Content-Type: application/json" \
        "$full_url" >/dev/null 2>&1; then
        echo -e "\n${gl_green}${SUCCESS} 同步到WebDAV成功！${gl_reset}"
    else
        error "文件同步失败（网络超时、权限不足或服务器限制）"
        echo -e "  排查步骤：1. 确认CCTB文件夹已存在 2. 检查服务器文件大小限制 3. 验证账号写入权限"
    fi
    press_any_key_continue
    $target_menu
}

# 同步函数：从WebDAV同步
sync_from_webdav() {
    check_webdav_config || return
    local webdav_url="$WEBDAV_URL" webdav_user="$WEBDAV_USER" webdav_pass_raw="$WEBDAV_PASS_RAW"
    local full_url=$(get_webdav_full_url "$webdav_url")
    local temp_sync_file="$CONFIG_DIR/temp_sync_webdav.json"
    
    echo -e "\n${gl_green}${CONTINUE} 从WebDAV同步...${gl_reset}"
    if curl -s --connect-timeout 15 --max-time 60 \
        -u "${webdav_user}:${webdav_pass_raw}" \
        -o "$temp_sync_file" \
        "$full_url" >/dev/null 2>&1; then
        if jq empty "$temp_sync_file" 2>/dev/null; then
            mv "$temp_sync_file" "$COMMANDS_FILE"
            CMD_JSON=$(cat "$COMMANDS_FILE" 2>/dev/null)
            echo -e "\n${gl_green}${SUCCESS} 从WebDAV同步成功！${gl_reset}"
            rm -f "$temp_sync_file"
            clear_cache
            press_any_key_continue
            sync_menu
            return 0
        else
            error "同步文件格式错误，已丢弃"
            rm -f "$temp_sync_file"
        fi
    else
        error "同步失败（文件不存在、网络超时或权限不足）"
    fi
    rm -f "$temp_sync_file"
    press_any_key_continue
    sync_menu
    return 1
}

# 同步函数：同步管理菜单
sync_menu() {
    local choice is_github=$([[ "$SYNC_MODE" == "$SYNC_MODE_GITHUB" ]] && echo 1 || echo 0)
    local is_webdav=$([[ "$SYNC_MODE" == "$SYNC_MODE_WEBDAV" ]] && echo 1 || echo 0)
    while true; do
        print_header
        echo -e "\n${BOLD}${gl_blue}同步管理${gl_reset} ${gl_cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_reset}"
        echo -e "\n当前模式：${BOLD}$SYNC_MODE${gl_reset}"
        if [[ $is_github -eq 1 ]]; then
            echo -e "\n${BOLD}1. 同步到GitHub    2. 从GitHub同步${gl_reset}"
            echo -e "\n${BOLD}3. 导出快速链接    4. 切换到WebDAV模式${gl_reset}"
            echo -e "\n${BOLD}5. 切换到本地模式  0. 返回上级菜单${gl_reset}"
        elif [[ $is_webdav -eq 1 ]]; then
            echo -e "\n${BOLD}1. 同步到WebDAV      2. 从WebDAV同步${gl_reset}" 
            echo -e "\n${BOLD}3. 切换到GitHub模式  4. 切换到本地模式${gl_reset}"
            echo -e "\n${BOLD}0. 返回上级菜单${gl_reset}"
        else
            echo -e "\n${BOLD}1. 切换到GitHub模式  2. 切换到WebDAV模式${gl_reset}"
            echo -e "\n${BOLD}0. 返回上级菜单${gl_reset}"
        fi
        
        read -e -p "$(echo -e "\n${gl_blue}选择：${gl_reset}")" choice
        if [[ "$SYNC_MODE" == "$SYNC_MODE_LOCAL" && ! "$choice" =~ ^(1|2|0)$ ]]; then
            error "无效选项！Local模式下仅支持 1（切换GitHub）、2（切换WebDAV）、0（返回上级）"
            error_retry
            continue
        fi
        case "$choice" in
            1)
                if [[ $is_github -eq 1 ]]; then
                    sync_to_github
                    clear_cache
                elif [[ $is_webdav -eq 1 ]]; then
                    sync_to_webdav
                    clear_cache
                else
                    setup_github_mode
                    load_config
                    is_github=$([[ "$SYNC_MODE" == "$SYNC_MODE_GITHUB" ]] && echo 1 || echo 0)
                    is_webdav=$([[ "$SYNC_MODE" == "$SYNC_MODE_WEBDAV" ]] && echo 1 || echo 0)
                    echo -e "\n${gl_green}${SUCCESS} 已切换到$SYNC_MODE模式${gl_reset}"
                    press_any_key_continue
                    sync_menu
                fi
                ;;
            2)
                if [[ $is_github -eq 1 ]]; then
                    sync_from_github
                    clear_cache
                elif [[ $is_webdav -eq 1 ]]; then
                    sync_from_webdav
                    clear_cache
                    init_cache
                else
                    setup_webdav_mode
                    load_config
                    is_github=$([[ "$SYNC_MODE" == "$SYNC_MODE_GITHUB" ]] && echo 1 || echo 0)
                    is_webdav=$([[ "$SYNC_MODE" == "$SYNC_MODE_WEBDAV" ]] && echo 1 || echo 0)
                    echo -e "\n${gl_green}${SUCCESS} 已切换到$SYNC_MODE模式${gl_reset}"
                    press_any_key_continue
                    sync_menu
                fi
                ;;
            3)
                if [[ $is_github -eq 1 ]]; then
                    export_quick_connect
                elif [[ $is_webdav -eq 1 ]]; then
                    setup_github_mode
                    load_config
                    is_github=$([[ "$SYNC_MODE" == "$SYNC_MODE_GITHUB" ]] && echo 1 || echo 0)
                    is_webdav=$([[ "$SYNC_MODE" == "$SYNC_MODE_WEBDAV" ]] && echo 1 || echo 0)
                    echo -e "\n${gl_green}${SUCCESS} 已切换到$SYNC_MODE模式${gl_reset}"
                    press_any_key_continue
                    sync_menu
                else
                    error "仅GitHub模式支持导出快速链接"
                    error_retry
                fi
                ;;
            4)
                if [[ $is_github -eq 1 ]]; then
                    setup_webdav_mode
                    load_config
                    is_github=$([[ "$SYNC_MODE" == "$SYNC_MODE_GITHUB" ]] && echo 1 || echo 0)
                    is_webdav=$([[ "$SYNC_MODE" == "$SYNC_MODE_WEBDAV" ]] && echo 1 || echo 0)
                    echo -e "\n${gl_green}${SUCCESS} 已切换到$SYNC_MODE模式${gl_reset}"
                    press_any_key_continue
                    sync_menu
                elif [[ $is_webdav -eq 1 ]]; then
                    setup_local_mode
                    load_config
                    is_github=0
                    is_webdav=0
                    echo -e "\n${gl_green}${SUCCESS} 已切换到本地模式${gl_reset}"
                    press_any_key_continue
                    sync_menu
                else
                    error "仅GitHub/WebDAV模式支持此操作"
                    error_retry
                fi
                ;;
            5)
                if [[ $is_github -eq 1 ]]; then
                    setup_local_mode
                    load_config
                    is_github=0
                    is_webdav=0
                    echo -e "\n${gl_green}${SUCCESS} 已切换到本地模式${gl_reset}"
                    press_any_key_continue
                    sync_menu
                else
                    error "仅GitHub模式支持此操作"
                    error_retry
                fi
                ;;
            0)
                settings
                ;;
            *)
                error_retry
                ;;
        esac
    done
}

# 命令管理函数：添加命令
add_command() {
    local name cmd desc confirm cmd_escaped cmd_type
    local type_options=()
    type_options+=("1) $CMD_TYPE_LOCAL（直接输入命令内容）")
    [[ "$SYNC_MODE" == "$SYNC_MODE_GITHUB" ]] && type_options+=("2) $CMD_TYPE_PRIVATE_REPO（自动使用已保存GitHub配置）")
    type_options+=("3) $CMD_TYPE_PUBLIC_REPO（输入 user/repo/branch/script.sh 路径）")
    type_options+=("4) $CMD_TYPE_NETWORK（输入网络脚本网址，如 test.com/test.sh）")
    while true; do
        print_header
        echo -e "\n${BOLD}${gl_blue}添加新命令${gl_reset} ${gl_cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_reset}"
        echo -e "\n${gl_yellow}[0] 返回上级菜单${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}命令名称：${gl_reset}")" name
        name=$(echo "$name" | xargs)
        if [[ "$name" == "0" ]]; then
            settings
        elif [[ -z "$name" ]]; then
            error_retry
            continue
        fi
        echo -e "\n${BOLD}选择命令类型（输入编号）：${gl_reset}\n"
        for opt in "${type_options[@]}"; do
            echo -e "${gl_green}$opt${gl_reset}"
        done
        echo -e "\n${gl_yellow}[0] 返回上级菜单${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}请输入类型编号：${gl_reset}")" cmd_type_num
        cmd_type_num=$(echo "$cmd_type_num" | xargs)
        case "$cmd_type_num" in
            0) settings ;;
            1) cmd_type="$CMD_TYPE_LOCAL" ;;
            2)
                if [[ "$SYNC_MODE" != "$SYNC_MODE_GITHUB" ]]; then
                    error "本地/WebDAV模式不支持私人仓库命令"
                    error_retry
                    continue
                fi
                cmd_type="$CMD_TYPE_PRIVATE_REPO"
                ;;
            3) cmd_type="$CMD_TYPE_PUBLIC_REPO" ;;
            4) cmd_type="$CMD_TYPE_NETWORK" ;;
            *) error "无效类型编号"; error_retry; continue ;;
        esac
        case "$cmd_type" in
            $CMD_TYPE_LOCAL)
                read -e -p "$(echo -e "\n${gl_blue}命令内容：${gl_reset}")" cmd
                cmd=$(echo "$cmd" | xargs)
                ;;
            $CMD_TYPE_PRIVATE_REPO)
                local repo="$GITHUB_REPO"
                local branch="$GITHUB_BRANCH"
                echo -e "\n已自动加载GitHub配置："
                echo -e "仓库：${gl_green}$repo${gl_reset}"
                echo -e "分支：${gl_green}$branch${gl_reset}"
                if [[ -z "$GITHUB_TOKEN" ]]; then
                    error "GitHub Token未加载！请重新配置GitHub模式（07. 配置设置 → 2. 重新配置GitHub）"
                    error_retry
                    continue
                fi
                read -e -p "$(echo -e "\n${gl_green}脚本名称（如：cctb.sh）：${gl_reset}")" script
                script=$(echo "$script" | xargs)
                if [[ -z "$script" ]]; then
                    error "脚本名不能为空"
                    error_retry
                    continue
                fi
                local encrypted_token=$(base58_encode "$GITHUB_TOKEN")
                local private_script_url="https://raw.githubusercontent.com/$repo/$branch/$script"
                cmd="bash <(curl -s --connect-timeout 10 --max-time 30 -H 'Authorization: token {ENCRYPTED_TOKEN:$encrypted_token}' \"$private_script_url\")"
                ;;
            $CMD_TYPE_PUBLIC_REPO)
                read -e -p "$(echo -e "\n${gl_blue}公共仓库完整路径（格式：user/repo/branch/script.sh）：${gl_reset}")" full_path
                full_path=$(echo "$full_path" | xargs)
                if ! [[ "$full_path" =~ ^([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+)/([a-zA-Z0-9_.-]+)/(.*)$ ]]; then
                    error "格式错误！正确示例：user/cctb-commands/main/test.sh"
                    error_retry
                    continue
                fi
                local repo="${BASH_REMATCH[1]}"
                local branch="${BASH_REMATCH[2]}"
                local script="${BASH_REMATCH[3]}"
                local public_script_url="https://raw.githubusercontent.com/$repo/$branch/$script"
                cmd="bash <(curl -s --connect-timeout 10 --max-time 30 \"$public_script_url\")"
                ;;
            $CMD_TYPE_NETWORK)
                read -e -p "$(echo -e "\n${gl_blue}网络脚本网址（示例：test.com/test.sh）：${gl_reset}")" cmd_url
                cmd_url=$(echo "$cmd_url" | xargs)
                if ! is_valid_url "$cmd_url"; then
                    error "格式错误！正确示例：test.com/test.sh"
                    error_retry
                    continue
                fi
                [[ ! "$cmd_url" =~ ^https?:// ]] && cmd_url="http://$cmd_url"
                cmd="bash <(curl -s --connect-timeout 10 --max-time 30 \"$cmd_url\")"
                ;;
        esac
        if [[ "$cmd" == "0" ]]; then
            settings
        elif [[ -z "$cmd" ]]; then
            error_retry
            continue
        fi
        if is_high_risk_cmd "$cmd"; then
            warning "检测到高危命令！添加后执行可能存在风险"
            read -e -p "$(echo -e "\n${gl_blue}确认添加？[Y/N]：${gl_reset}")" confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { error_retry; continue; }
            local log_time=$(get_iso_date)
            local current_user=$(whoami)
            local log_entry="[$log_time] 用户='$current_user' | 命令名称='$name' | 命令类型='$cmd_type' | 高危命令内容='$cmd'"
            echo "$log_entry" >> "$CONFIG_DIR/high_risk_cmd.log"
            echo -e "\n${gl_yellow}${WARNING} 高危命令已记录日志（路径：$CONFIG_DIR/high_risk_cmd.log）${gl_reset}"
        fi
        cmd_escaped=$(echo "$cmd" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        read -e -p "$(echo -e "\n${gl_blue}描述（可选）：${gl_reset}")" desc
        desc=$(echo "$desc" | xargs)
        [[ "$desc" == "0" ]] && settings
        local new_cmd=$(jq -n --arg id "$(date +%s%N | cut -b1-13)" --arg name "$name" --arg cmd "$cmd_escaped" --arg desc "$desc" --arg type "$cmd_type" --arg time "$(get_iso_date)" '{id: ($id|tonumber), name: $name, command: $cmd, description: $desc, type: $type, created_at: $time, updated_at: $time}')
        if ! jq --argjson nc "$new_cmd" '.commands += [$nc]' "$COMMANDS_FILE" > "$TEMP_FILE"; then
            error "命令添加失败，文件写入异常"
            rm -f "$TEMP_FILE"
            error_retry
            continue
        fi
        mv "$TEMP_FILE" "$COMMANDS_FILE"
        CMD_JSON=$(cat "$COMMANDS_FILE" 2>/dev/null)
        echo -e "\n${gl_green}${SUCCESS} 命令添加成功！${gl_reset}"
        clear_cache
        if [[ "$SYNC_MODE" == "$SYNC_MODE_GITHUB" ]]; then
            echo -e "\n${gl_green}${CLOUD} 自动同步到GitHub...${gl_reset}"
            sync_to_github "add_command"
        elif [[ "$SYNC_MODE" == "$SYNC_MODE_WEBDAV" ]]; then
            echo -e "\n${gl_green}${WEBDAV} 自动同步到WebDAV...${gl_reset}"
            sync_to_webdav "add_command"
        fi
        echo -e "\n${gl_green}${CONTINUE} 按任意键继续添加...${gl_reset}"
        read -n 1 -s -r
        clear
    done
}

# 命令管理函数：编辑命令
edit_command() {
    local cmd_count num current new_name new_cmd new_desc confirm new_cmd_escaped
    local new_cmd_type curr_name curr_cmd curr_desc curr_type
    local cmd repo branch script full_path new_url
    local curr_script curr_full_path curr_net_url
    local clean_curr_value
    while true; do
        print_header
        echo -e "\n${BOLD}${gl_blue}编辑命令${gl_reset} ${gl_cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_reset}"
        cmd_count=$(echo "$CMD_JSON" | jq -r '.commands | length' 2>/dev/null || echo 0)
        if [[ "$cmd_count" -eq 0 ]]; then
            warning "暂无命令可编辑"
            echo -e "\n${gl_cyan}--------------------------------------------------${gl_reset}"
            echo -e "\n  ${gl_yellow}[0] 返回上级菜单 | 提示：先通过「01. 添加命令」创建命令${gl_reset}"
            read -e -p "$(echo -e "\n${gl_blue}请输入选择：${gl_reset}")" num
            [[ "$num" == "0" ]] && settings
            error_retry
            continue
        fi
        echo -e "${gl_cyan}--------------------------------------------------${gl_reset}"
        echo -e "${BOLD}${gl_gray} 编号    类型     命令名称${gl_reset}"
        echo -e "${gl_cyan}--------------------------------------------------${gl_reset}"
        local edit_cmds=$(echo "$CMD_JSON" | jq -r '.commands[]? | [.type, .name] | @tsv' 2>/dev/null)
        local edit_idx=0
        while IFS=$'\t' read -r cmd_type cmd_name; do
            edit_idx=$((edit_idx + 1))
            local type_flag=$(get_cmd_type_flag "$cmd_type")
            printf -v padded_idx "%02d" "$edit_idx"
            echo -e "\n  ${BOLD}${gl_green}${padded_idx}${gl_reset}   ${type_flag}   ${BOLD}${cmd_name}${gl_reset}"
        done <<< "$edit_cmds"
        echo -e "\n${gl_cyan}--------------------------------------------------${gl_reset}"
        echo -e "  ${gl_green}${SUCCESS} 共 ${BOLD}$cmd_count${gl_reset}${gl_green} 条可编辑命令${gl_reset}"
        echo -e "\n  ${gl_yellow}[0] 返回上级菜单 | 操作：输入编号编辑对应命令${gl_reset}"
        echo -e "${gl_cyan}--------------------------------------------------${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}输入编辑编号：${gl_reset}")" num
        if [[ "$num" == "0" ]]; then
            settings
        elif ! [[ "$num" =~ ^[0-9]+$ ]] || [[ "$num" -gt "$cmd_count" || "$num" -lt 1 ]]; then
            error "无效编号！请输入 1-$cmd_count 之间的数字"
            error_retry
            continue
        fi
        current=$(echo "$CMD_JSON" | jq --arg n "$num" '.commands[($n|tonumber)-1]' 2>/dev/null)
        curr_name=$(echo "$current" | jq -r '.name' 2>/dev/null)
        curr_cmd=$(echo "$current" | jq -r '.command' 2>/dev/null)
        curr_desc=$(echo "$current" | jq -r '.description' 2>/dev/null)
        curr_type=$(echo "$current" | jq -r '.type // "'"$CMD_TYPE_LOCAL"'"' 2>/dev/null)
        echo -e "\n${gl_cyan}==================================================${gl_reset}"
        echo -e "${BOLD}${gl_blue}当前编辑命令信息${gl_reset}"
        echo -e "${gl_cyan}--------------------------------------------------${gl_reset}"
        echo -e "  ${gl_blue}编号：${gl_reset}${BOLD}$num${gl_reset}"
        echo -e "  ${gl_blue}类型：${gl_reset}$(get_cmd_type_flag "$curr_type")"
        echo -e "  ${gl_blue}名称：${gl_reset}${BOLD}$curr_name${gl_reset}"
        echo -e "  ${gl_blue}命令：${gl_reset}${gl_green}$curr_cmd${gl_reset}"
        echo -e "  ${gl_blue}描述：${gl_reset}$( [[ -n "$curr_desc" ]] && echo "${BOLD}$curr_desc${gl_reset}" || echo "${gl_yellow}无描述${gl_reset}" )"
        echo -e "${gl_cyan}==================================================${gl_reset}"
        echo -e "\n${gl_yellow}[0] 返回上级菜单${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}新名称（回车保留：${BOLD}$curr_name${gl_reset}${gl_blue}）：${gl_reset}")" new_name
        new_name=$(echo "$new_name" | xargs)
        new_name=${new_name:-$curr_name}
        [[ "$new_name" == "0" ]] && settings
        local edit_type_options=()
        edit_type_options+=("1) $CMD_TYPE_LOCAL（直接输入命令内容）")
        [[ "$SYNC_MODE" == "$SYNC_MODE_GITHUB" ]] && edit_type_options+=("2) $CMD_TYPE_PRIVATE_REPO（自动使用已保存GitHub配置）")
        edit_type_options+=("3) $CMD_TYPE_PUBLIC_REPO（输入 user/repo/branch/script.sh 路径）")
        edit_type_options+=("4) $CMD_TYPE_NETWORK（输入网络脚本网址）")
        echo -e "\n${BOLD}${gl_blue}选择新命令类型（输入编号，回车保留原类型）${gl_reset}"
        echo -e "${gl_cyan}--------------------------------------------------${gl_reset}\n"
        for opt in "${edit_type_options[@]}"; do
            echo -e "  ${gl_green}$opt${gl_reset}"
        done
        echo -e "\n  ${gl_blue}当前类型：$(get_cmd_type_flag "$curr_type")${gl_reset}\n"
        echo -e "${gl_yellow}[0] 返回上级菜单${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}请输入新类型编号：${gl_reset}")" new_cmd_type_num
        new_cmd_type_num=$(echo "$new_cmd_type_num" | xargs)
        if [[ -z "$new_cmd_type_num" ]]; then
            new_cmd_type="$curr_type"
        else
            case "$new_cmd_type_num" in
                0) settings ;;
                1) new_cmd_type="$CMD_TYPE_LOCAL" ;;
                2)
                    [[ "$SYNC_MODE" != "$SYNC_MODE_GITHUB" ]] && { error "本地/WebDAV模式不支持私人仓库命令"; error_retry; continue; }
                    new_cmd_type="$CMD_TYPE_PRIVATE_REPO"
                    ;;
                3) new_cmd_type="$CMD_TYPE_PUBLIC_REPO" ;;
                4) new_cmd_type="$CMD_TYPE_NETWORK" ;;
                *) error "无效类型编号"; error_retry; continue ;;
            esac
        fi
        case "$new_cmd_type" in
            "$CMD_TYPE_LOCAL")
                local prompt_text="新命令内容（回车保留：$curr_cmd）"
                read -e -p "$(echo -e "\n${gl_blue}$prompt_text：${gl_reset}")" cmd
                cmd=$(echo "$cmd" | xargs)
                cmd=${cmd:-$curr_cmd}
                ;;
            "$CMD_TYPE_PRIVATE_REPO")
                repo=$(echo "$GITHUB_REPO" | sed -r 's/\x1B\[[0-9;]*[mK]//g' | sed -r 's/[^a-zA-Z0-9_\/.-]//g')
                branch=$(echo "$GITHUB_BRANCH" | sed -r 's/\x1B\[[0-9;]*[mK]//g' | sed -r 's/[^a-zA-Z0-9_\/.-]//g')
                if [[ -n "$curr_cmd" ]]; then
                    clean_curr_value=$(echo "$curr_cmd" | sed -r 's/\x1B\[[0-9;]*[mK]//g' | sed -r 's/[^a-zA-Z0-9_\/.-]//g')
                    curr_script=$(echo "$clean_curr_value" | grep -oP "$repo/$branch/\K[a-zA-Z0-9_.-]+" 2>/dev/null || "")
                fi
                echo -e "\n已自动加载GitHub配置："
                echo -e "仓库：${gl_green}$repo${gl_reset}"
                echo -e "分支：${gl_green}$branch${gl_reset}"
                if [[ "$repo" != "$GITHUB_REPO" || "$branch" != "$GITHUB_BRANCH" ]]; then
                    printf "%s\n" "# （提示：配置变量含特殊字符，已自动清理）"
                fi
                local prompt_text="脚本名称（回车保留：$curr_script）"
                read -e -p "$(echo -e "\n${gl_blue}$prompt_text：${gl_reset}")" script
                script=$(echo "$script" | xargs)
                script=${script:-$curr_script}
                if [[ -z "$script" ]]; then
                    cmd="empty_script"
                else
                    local encrypted_token=$(base58_encode "$GITHUB_TOKEN")
                    local private_script_url="https://raw.githubusercontent.com/$repo/$branch/$script"
                    cmd="bash <(curl -s --connect-timeout 10 --max-time 30 -H 'Authorization: token {ENCRYPTED_TOKEN:$encrypted_token}' \"$private_script_url\")"
                fi
                ;;
            "$CMD_TYPE_PUBLIC_REPO")
                if [[ -n "$curr_cmd" ]]; then
                    curr_full_path=$(echo "$curr_cmd" | grep -oP "raw\.githubusercontent\.com/\K[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_./-]+" 2>/dev/null || "")
                fi
                echo -e "\n格式示例：${BOLD}user/repo/main/test.sh${gl_reset}"
                local prompt_text="公共仓库完整路径（回车保留：$curr_full_path）"
                read -e -p "$(echo -e "\n${gl_blue}$prompt_text：${gl_reset}")" full_path
                full_path=$(echo "$full_path" | xargs)
                full_path=${full_path:-$curr_full_path}
                if ! [[ "$full_path" =~ ^([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+)/([a-zA-Z0-9_.-]+)/(.*)$ ]]; then
                    cmd="invalid_format"
                else
                    local repo="${BASH_REMATCH[1]}"
                    local branch="${BASH_REMATCH[2]}"
                    local script="${BASH_REMATCH[3]}"
                    local public_script_url="https://raw.githubusercontent.com/$repo/$branch/$script"
                    cmd="bash <(curl -s --connect-timeout 10 --max-time 30 \"$public_script_url\")"
                fi
                ;;
            "$CMD_TYPE_NETWORK")
                if [[ -n "$curr_cmd" ]]; then
                    local full_url=$(echo "$curr_cmd" | grep -oP "curl -s ['\"]?\Khttps?://[a-zA-Z0-9_./-]+(?=['\"]?\))" 2>/dev/null)
                    curr_net_url=$(echo "$full_url" | sed 's/^https\?:\/\///' || "$curr_cmd")
                fi
                echo -e "\n格式示例：${BOLD}test.com/test.sh${gl_reset}"
                local prompt_text="新网络脚本网址（回车保留：$curr_net_url）"
                read -e -p "$(echo -e "\n${gl_blue}$prompt_text：${gl_reset}")" new_url
                new_url=$(echo "$new_url" | xargs)
                new_url=${new_url:-$curr_net_url}
                if ! is_valid_url "$new_url"; then
                    cmd="invalid_url"
                else
                    [[ ! "$new_url" =~ ^https?:// ]] && new_url="http://$new_url"
                    cmd="bash <(curl -s --connect-timeout 10 --max-time 30 \"$new_url\")"
                fi
                ;;
            *)
                cmd="invalid_type"
                ;;
        esac
        case "$cmd" in
            "empty_script") error "脚本名不能为空"; error_retry; continue ;;
            "invalid_format") error "格式错误！正确示例：user/repo/main/test.sh"; error_retry; continue ;;
            "invalid_type") error "无效命令类型"; error_retry; continue ;;
        esac
        new_cmd="$cmd"
        if [[ "$new_cmd" == "0" ]]; then
            settings
        elif [[ -z "$new_cmd" ]]; then
            error_retry
            continue
        fi
        if is_high_risk_cmd "$new_cmd"; then
            warning "检测到高危命令！修改后执行可能存在风险"
            read -e -p "$(echo -e "\n${gl_blue}确认修改？[Y/N]：${gl_reset}")" confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { error_retry; continue; }
        fi
        new_cmd_escaped=$(echo "$new_cmd" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' 2>/dev/null)
        read -e -p "$(echo -e "\n${gl_blue}新描述（回车保留：${BOLD}$curr_desc${gl_reset}${gl_blue}）：${gl_reset}")" new_desc
        new_desc=$(echo "$new_desc" | xargs)
        new_desc=${new_desc:-$curr_desc}
        [[ "$new_desc" == "0" ]] && settings
        local update=$(echo "$current" | jq --arg n "$new_name" --arg c "$new_cmd_escaped" --arg d "$new_desc" --arg t "$new_cmd_type" --arg time "$(get_iso_date)" '.name = $n | .command = $c | .description = $d | .type = $t | .updated_at = $time' 2>/dev/null)
        if [[ -z "$update" || "$update" == "null" ]]; then
            error "命令数据格式异常，无法更新"
            error_retry
            continue
        fi
        if ! jq --arg n "$num" --argjson u "$update" '.commands[($n|tonumber)-1] = $u' "$COMMANDS_FILE" > "$TEMP_FILE" 2>/dev/null; then
            error "命令修改失败，文件写入异常"
            rm -f "$TEMP_FILE"
            error_retry
            continue
        fi
        mv "$TEMP_FILE" "$COMMANDS_FILE"
        CMD_JSON=$(cat "$COMMANDS_FILE" 2>/dev/null)
        echo -e "\n${gl_green}${SUCCESS} 命令更新成功！${gl_reset}"
        clear_cache
        if [[ "$SYNC_MODE" == "$SYNC_MODE_GITHUB" ]]; then
            echo -e "\n${gl_green}${CLOUD} 自动同步到GitHub...${gl_reset}"
            sync_to_github "edit_command"
        elif [[ "$SYNC_MODE" == "$SYNC_MODE_WEBDAV" ]]; then
            echo -e "\n${gl_green}${WEBDAV} 自动同步到WebDAV...${gl_reset}"
            sync_to_webdav "edit_command"
        fi
        
        press_any_key_continue
    done
}

# 命令管理函数：删除命令
delete_command() {
    if ! validate_and_reset_commands_file; then
        error_retry
        settings
    fi
    local cmd_count num_str parsed_nums del_cmd_names confirm num idx
    while true; do
        print_header
        echo -e "\n${BOLD}${gl_blue}删除命令${gl_reset} ${gl_cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_reset}"
        cmd_count=$(echo "$CMD_JSON" | jq -r '.commands | length' 2>/dev/null || echo 0)
        if [[ "$cmd_count" -eq 0 ]]; then
            warning "暂无命令可删除"
            echo -e "\n${gl_cyan}--------------------------------------------------${gl_reset}"
            echo -e "\n  ${gl_yellow}[0] 返回上级菜单 | 提示：先通过「01. 添加命令」创建命令${gl_reset}"
            read -e -p "$(echo -e "\n${gl_blue}请输入选择：${gl_reset}")" num
            [[ "$num" == "0" ]] && settings
            error_retry
            continue
        fi
        echo -e "${gl_cyan}--------------------------------------------------${gl_reset}"
        echo -e "${BOLD}${gl_gray} 编号    类型     命令名称${gl_reset}"
        echo -e "${gl_cyan}--------------------------------------------------${gl_reset}"
        local del_cmds=$(echo "$CMD_JSON" | jq -r '.commands[]? | [.type, .name] | @tsv' 2>/dev/null)
        local del_idx=0
        while IFS=$'\t' read -r cmd_type cmd_name; do
            del_idx=$((del_idx + 1))
            local type_flag=$(get_cmd_type_flag "$cmd_type")
            printf -v padded_idx "%02d" "$del_idx"
            echo -e "\n  ${BOLD}${gl_green}${padded_idx}${gl_reset}   ${type_flag}   ${BOLD}${cmd_name}${gl_reset}"
        done <<< "$del_cmds"
        echo -e "\n${gl_cyan}--------------------------------------------------${gl_reset}"
        echo -e "  ${gl_green}${SUCCESS} 共 ${BOLD}$cmd_count${gl_reset}${gl_green} 条可删除命令${gl_reset}"
        echo -e "\n  ${gl_yellow}批量选择说明：${gl_reset}"
        echo -e "    • 连续选择：1-3（删除1、2、3号命令）"
        echo -e "    • 离散选择：1 3（删除1、3号命令）"
        echo -e "    • 混合选择：1-2 4（删除1、2、4号命令）"
        echo -e "\n  ${gl_yellow}[0] 返回上级菜单${gl_reset}"
        echo -e "${gl_cyan}--------------------------------------------------${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}输入删除编号：${gl_reset}")" num_str
        num_str=$(echo "$num_str" | xargs)
        if [[ "$num_str" == "0" ]]; then
            settings
        elif [[ -z "$num_str" ]]; then
            error_retry
            continue
        fi
        parsed_nums=$(parse_selection "$num_str" "$cmd_count" 2>&1)
        local parse_exit_code=$?
        if [[ $parse_exit_code -ne 0 ]]; then
            error "$parsed_nums"
            error_retry
            continue
        fi
        del_cmd_names=()
        while IFS= read -r num; do
            if [[ -n "$num" ]]; then
                local name=$(echo "$CMD_JSON" | jq -r --arg n "$num" '.commands[($n | tonumber)-1]?.name' 2>/dev/null)
                local type=$(echo "$CMD_JSON" | jq -r --arg n "$num" '.commands[($n | tonumber)-1]?.type' 2>/dev/null)
                [[ -n "$name" && "$name" != "null" ]] && del_cmd_names+=("$(get_cmd_type_flag "$type") ${BOLD}${name}${gl_reset}")
            fi
        done <<< "$parsed_nums"
        if [[ ${#del_cmd_names[@]} -eq 0 ]]; then
            error "所选编号无对应有效命令，请重新输入"
            error_retry
            continue
        fi
        echo -e "\n${gl_red}${WARNING} 确认删除以下命令（共 ${BOLD}${#del_cmd_names[@]}${gl_reset}${gl_red} 条）${gl_reset}"
        echo -e "${gl_cyan}--------------------------------------------------${gl_reset}\n"
        for idx in "${!del_cmd_names[@]}"; do
            echo -e "  ${gl_blue}$((idx+1)). ${del_cmd_names[$idx]}${gl_reset}"
        done
        echo -e "\n${gl_cyan}--------------------------------------------------${gl_reset}\n"
        echo -e "${gl_yellow}[0] 取消并返回上级菜单 | 警告：删除后无法恢复！${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}确认删除？[Y/N/0]：${gl_reset}")" confirm
        case "$confirm" in
            y|Y|"")
                local sorted_indices=()
                while IFS= read -r num; do
                    [[ -n "$num" ]] && sorted_indices+=($((num - 1)))
                done <<< "$parsed_nums"
                IFS=$'\n' sorted_indices=($(sort -nr <<<"${sorted_indices[*]}"))
                unset IFS
                local delete_success=true
                for idx in "${sorted_indices[@]}"; do
                    if ! jq --arg i "$idx" 'del(.commands[$i | tonumber])' "$COMMANDS_FILE" > "$TEMP_FILE"; then
                        error "编号$((idx+1))对应命令删除失败（JSON错误）"
                        rm -f "$TEMP_FILE"
                        delete_success=false
                        break
                    fi
                    mv "$TEMP_FILE" "$COMMANDS_FILE"
                    CMD_JSON=$(cat "$COMMANDS_FILE" 2>/dev/null)
                done
                if $delete_success; then
                    echo -e "\n${gl_green}${SUCCESS} 成功删除 ${BOLD}${#del_cmd_names[@]}${gl_reset}${gl_green} 条命令！${gl_reset}"
                    clear_cache
                    if [[ "$SYNC_MODE" == "$SYNC_MODE_GITHUB" ]]; then
                        echo -e "\n${gl_green}${CLOUD} 自动同步到GitHub...${gl_reset}"
                        sync_to_github "delete_command"
                    elif [[ "$SYNC_MODE" == "$SYNC_MODE_WEBDAV" ]]; then
                        echo -e "\n${gl_green}${WEBDAV} 自动同步到WebDAV...${gl_reset}"
                        sync_to_webdav "delete_command"
                    fi
                fi
                press_any_key_continue
                ;;
            n|N)
                echo -e "\n${gl_green}${SUCCESS} 已取消删除${gl_reset}"
                press_any_key_continue
                settings
                ;;
            0) settings ;;
            *) error_retry; continue ;;
        esac
    done
}

# 命令管理函数：命令排序
sort_commands() {
    local cmd_count sort_input new_order
    while true; do
        print_header
        echo -e "\n${BOLD}${gl_blue}命令排序${gl_reset} ${gl_cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_reset}"
        cmd_count=$(echo "$CMD_JSON" | jq -r '.commands | length' 2>/dev/null || echo 0)
        if [[ "$cmd_count" -eq 0 ]]; then
            warning "暂无命令可排序"
            echo -e "\n${gl_cyan}--------------------------------------------------${gl_reset}"
            echo -e "\n  ${gl_yellow}[0] 返回上级菜单 | 提示：先通过「01. 添加命令」创建命令${gl_reset}"
            read -e -p "$(echo -e "\n${gl_blue}请输入选择：${gl_reset}")" num
            [[ "$num" == "0" ]] && { settings; return; }
            error_retry; continue
        fi
        echo -e "${gl_cyan}--------------------------------------------------${gl_reset}"
        echo -e "${BOLD}${gl_gray}原始编号 类型     命令名称${gl_reset}"
        echo -e "${gl_cyan}--------------------------------------------------${gl_reset}"
        local sort_cmds=$(echo "$CMD_JSON" | jq -r '.commands[]? | [.type, .name] | @tsv' 2>/dev/null)
        local sort_idx=0
        while IFS=$'\t' read -r cmd_type cmd_name; do
            sort_idx=$((sort_idx + 1))
            local type_flag=$(get_cmd_type_flag "$cmd_type")
            printf -v padded_idx "%02d" "$sort_idx"
            echo -e "\n  ${BOLD}${gl_yellow}${padded_idx}${gl_reset}   ${type_flag}   ${BOLD}${cmd_name}${gl_reset}"
        done <<< "$sort_cmds"
        echo -e "\n${gl_cyan}--------------------------------------------------${gl_reset}"
        echo -e "  ${gl_green}${SUCCESS} 共 ${BOLD}$cmd_count${gl_reset}${gl_green} 条可排序命令${gl_reset}"
        echo -e "\n${gl_yellow}  排序说明：${gl_reset}"
        echo -e "    • 完整排序：输入 5 2 3 6 4 1 7（覆盖全部顺序）"
        echo -e "    • 局部调换：输入 1-3=3 1 2（1-3号命令改为3、1、2）"
        echo -e "    • 两两对调：输入 1=7（交换1号和7号命令位置）"
        echo -e "\n${gl_yellow}  [0] 返回上级菜单${gl_reset}"
        echo -e "${gl_cyan}--------------------------------------------------${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}输入排序指令：${gl_reset}")" sort_input
        sort_input=$(echo "$sort_input" | xargs)
        if [[ "$sort_input" == "0" ]]; then
            settings; return
        elif [[ -z "$sort_input" ]]; then
            error_retry; continue
        fi
        if [[ "$sort_input" =~ ^([0-9]+)-([0-9]+)=([0-9 ]+)$ ]]; then
            local start=${BASH_REMATCH[1]}
            local end=${BASH_REMATCH[2]}
            local local_order=${BASH_REMATCH[3]}
            local local_nums=($local_order)
            if (( start < 1 || end > cmd_count || start > end )); then
                error "局部范围无效！需在 1-$cmd_count 之间且开始≤结束"
                error_retry; continue
            fi
            if (( ${#local_nums[@]} != (end - start + 1) )); then
                error "局部排序编号数量不匹配！需输入 $((end - start + 1)) 个编号"
                error_retry; continue
            fi
            for num in "${local_nums[@]}"; do
                if ! [[ "$num" =~ ^[0-9]+$ ]] || (( num < 1 || num > (end - start + 1) )); then
                    error "局部排序编号 $num 无效！需在 1~$((end - start + 1)) 之间"
                    error_retry; continue 2
                fi
            done
            new_order=()
            for ((i=1; i<=cmd_count; i++)); do
                if (( i >= start && i <= end )); then
                    local local_idx=$((i - start))
                    new_order+=($((start + local_nums[local_idx] - 1)))
                else
                    new_order+=($i)
                fi
            done
        elif [[ "$sort_input" =~ ^([0-9]+)=([0-9]+)$ ]]; then
            local num1=${BASH_REMATCH[1]}
            local num2=${BASH_REMATCH[2]}
            if (( num1 < 1 || num1 > cmd_count || num2 < 1 || num2 > cmd_count )); then
                error "对调编号无效！需在 1-$cmd_count 之间"
                error_retry; continue
            fi
            new_order=()
            for ((i=1; i<=cmd_count; i++)); do
                if (( i == num1 )); then
                    new_order+=($num2)
                elif (( i == num2 )); then
                    new_order+=($num1)
                else
                    new_order+=($i)
                fi
            done
        else
            local full_nums=($sort_input)
            if (( ${#full_nums[@]} != cmd_count )); then
                error "排序编号数量不匹配！需输入 $cmd_count 个编号"
                error_retry; continue
            fi
            local valid=1
            for num in "${full_nums[@]}"; do
                if ! [[ "$num" =~ ^[0-9]+$ ]] || (( num < 1 || num > cmd_count )); then
                    valid=0
                    break
                fi
            done
            if (( valid == 0 )); then
                error "排序编号无效！需在 1-$cmd_count 之间"
                error_retry; continue
            fi
            local unique_nums=($(echo "${full_nums[@]}" | tr ' ' '\n' | sort -nu))
            if (( ${#unique_nums[@]} != cmd_count )); then
                error "排序编号存在重复或缺失！需包含 1-$cmd_count 所有编号"
                error_retry; continue
            fi
            new_order=("${full_nums[@]}")
        fi
        echo -e "\n${gl_cyan}${BOLD}排序预览（新顺序）${gl_reset}"
        echo -e "${gl_cyan}--------------------------------------------------${gl_reset}\n"
        local preview_idx=0
        for orig_num in "${new_order[@]}"; do
            preview_idx=$((preview_idx + 1))
            local cmd_name=$(echo "$CMD_JSON" | jq -r --arg n "$orig_num" '.commands[($n | tonumber)-1]?.name' 2>/dev/null)
            local cmd_type=$(echo "$CMD_JSON" | jq -r --arg n "$orig_num" '.commands[($n | tonumber)-1]?.type' 2>/dev/null)
            local type_flag=$(get_cmd_type_flag "$cmd_type")
            printf -v padded_preview "%02d" "$preview_idx"
            echo -e "  ${BOLD}${gl_green}${padded_preview}${gl_reset}   ${type_flag}   ${BOLD}${cmd_name}${gl_reset}（原#$orig_num）"
        done
        echo -e "\n${gl_cyan}--------------------------------------------------${gl_reset}\n"
        echo -e "${gl_yellow}[0] 取消并返回上级菜单 | 警告：排序后将覆盖原顺序${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}确认排序？[Y/N/0]：${gl_reset}")" confirm
        case "$confirm" in
            y|Y|"")
                local new_commands="[]"
                for orig_num in "${new_order[@]}"; do
                    local cmd=$(echo "$CMD_JSON" | jq -r --arg n "$orig_num" '.commands[($n | tonumber)-1]' 2>/dev/null)
                    new_commands=$(echo "$new_commands" | jq --argjson c "$cmd" '. += [$c]')
                done
                if ! jq --argjson nc "$new_commands" '.commands = $nc' "$COMMANDS_FILE" > "$TEMP_FILE"; then
                    error "排序失败，文件写入异常"
                    rm -f "$TEMP_FILE"
                    error_retry; continue
                fi
                mv "$TEMP_FILE" "$COMMANDS_FILE"
                CMD_JSON=$(cat "$COMMANDS_FILE" 2>/dev/null)
                echo -e "\n${gl_green}${SUCCESS} 命令排序成功！${gl_reset}"
                clear_cache
                if [[ "$SYNC_MODE" == "$SYNC_MODE_GITHUB" ]]; then
                    echo -e "\n${gl_green}${CLOUD} 自动同步到GitHub...${gl_reset}"
                    sync_to_github "sort_commands"
                elif [[ "$SYNC_MODE" == "$SYNC_MODE_WEBDAV" ]]; then
                    echo -e "\n${gl_green}${WEBDAV} 自动同步到WebDAV...${gl_reset}"
                    sync_to_webdav "sort_commands"
                fi
                
                press_any_key_continue
                ;;
            n|N)
                echo -e "\n${gl_green}${SUCCESS} 已取消排序${gl_reset}"
                press_any_key_continue
                settings; return
                ;;
            0) settings; return ;;
            *) error_retry; continue ;;
        esac
    done
}

# 命令管理函数：导入导出菜单
import_export_menu() {
    local choice
    while true; do
        print_header
        echo -e "\n${BOLD}${gl_blue}导入导出${gl_reset} ${gl_cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_reset}"
        echo -e "\n${BOLD}1. 导出命令到文件    2. 从文件导入命令${gl_reset}"
        echo -e "\n${BOLD}0. 返回上一级菜单${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}选择：${gl_reset}")" choice
        case "$choice" in
            1) export_commands ;;
            2) import_commands ;;
            0) settings ;;
            *) error_retry ;;
        esac
    done
}

# 命令管理函数：导出命令（毫秒级时间戳防覆盖）
export_commands() {
    local export_path confirm
    while true; do
        print_header
        echo -e "\n${BOLD}导出命令${gl_reset}"
        local timestamp=$(date +%Y%m%d_%H%M%S_%N | cut -b1-13)
        local default_path="$HOME/cctb_commands_$timestamp.json"
        echo -e "\n默认导出路径：$default_path"
        read -e -p "$(echo -e "\n${gl_blue}请输入导出路径（直接回车用默认路径）：${gl_reset}")" export_path
        export_path=$(echo "$export_path" | xargs)
        if [[ "$export_path" == "0" ]]; then
            import_export_menu; return
        elif [[ -z "$export_path" ]]; then
            export_path="$default_path"
        fi
        if [[ -f "$export_path" ]]; then
            warning "文件已存在：$export_path"
            read -e -p "$(echo -e "\n${gl_blue}是否覆盖？[Y/N]：${gl_reset}")" confirm
            case "$confirm" in
                n|N) error_retry; continue ;;
                0) import_export_menu; return ;;
            esac
        fi
        if cp "$COMMANDS_FILE" "$export_path" 2>/dev/null; then
            echo -e "\n${gl_green}${SUCCESS} 导出成功！${gl_reset}"
            echo -e "\n${gl_green}${SUCCESS} 导出路径：${gl_cyan}$export_path${gl_reset}"
        else
            error "导出失败（无写入权限或路径无效）"
            error_retry; continue
        fi
        press_any_key_continue
        import_export_menu
    done
}

# 命令管理函数：导入命令
import_commands() {
    local import_path mode
    while true; do
        print_header
        echo -e "\n${BOLD}导入命令${gl_reset}"
        echo -e "\n${gl_yellow}[0] 返回上级菜单${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}导入文件路径：${gl_reset}")" import_path
        import_path=$(echo "$import_path" | xargs)
        if [[ "$import_path" == "0" ]]; then
            import_export_menu
        elif [[ ! -f "$import_path" ]]; then
            error "文件不存在"; error_retry; continue
        elif ! jq empty "$import_path" 2>/dev/null; then
            error "无效JSON文件"; error_retry; continue
        fi
        local has_commands=$(jq -e '.commands | type == "array"' "$import_path" 2>/dev/null)
        local has_required_fields=true
        local cmd_count=$(jq -r '.commands | length' "$import_path" 2>/dev/null)
        if [[ "$has_commands" == "true" && "$cmd_count" -gt 0 ]]; then
            has_required_fields=$(jq -e '.commands[] | has("name") and has("command")' "$import_path" 2>/dev/null)
        fi
        if [[ "$has_commands" != "true" || "$has_required_fields" != "true" ]]; then
            error "导入文件结构错误！需满足："
            error "1. 根节点含commands数组 2. 每个命令含name（名称）和command（内容）字段"
            error_retry "import"; continue
        fi
        echo -e "\n1. 合并（保留现有）    2. 替换（覆盖现有）"
        echo -e "\n${gl_yellow}[0] 返回上级菜单${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}选择模式：${gl_reset}")" mode
        case "$mode" in
            1|"")
                if ! jq -s '.[0].commands as $existing | .[1].commands as $imported | ($imported | map(select(.name | ascii_downcase as $n | $existing | map(.name | ascii_downcase) | contains([$n]) | not))) as $new_cmds | ($existing + $new_cmds) as $combined_cmds | {"commands": $combined_cmds}' "$COMMANDS_FILE" "$import_path" > "$TEMP_FILE"; then
                    error "合并失败，文件格式异常"
                    rm -f "$TEMP_FILE"
                    error_retry; continue
                fi
                mv "$TEMP_FILE" "$COMMANDS_FILE"
                echo -e "\n${gl_green}${SUCCESS} 合并成功！已自动去重（保留现有命令）${gl_reset}"
                ;;
            2)
                if ! cp "$import_path" "$COMMANDS_FILE" 2>/dev/null; then
                    error "替换失败，无写入权限"
                    error_retry; continue
                fi
                echo -e "\n${gl_green}${SUCCESS} 替换成功！${gl_reset}"
                ;;
            0) import_export_menu ;;
            *) error_retry; continue ;;
        esac
        clear_cache
        if [[ "$SYNC_MODE" == "$SYNC_MODE_GITHUB" ]]; then
            echo -e "\n${gl_green}${CLOUD} 自动同步到GitHub...${gl_reset}"
            sync_to_github
        elif [[ "$SYNC_MODE" == "$SYNC_MODE_WEBDAV" ]]; then
            echo -e "\n${gl_green}${WEBDAV} 自动同步到WebDAV...${gl_reset}"
            sync_to_webdav
        fi
        
        press_any_key_continue
        import_export_menu
    done
}

# 配置关联函数：导出快速连接（GitHub模式专属）
export_quick_connect() {
    while true; do
        print_header
        echo -e "\n${BOLD}导出快速连接${gl_reset}\n"
        local sync_mode=$(get_config_value "SYNC_MODE")
        local github_repo=$(get_config_value "GITHUB_REPO")
        local token_encoded=$(get_config_value "GITHUB_TOKEN")
        local token_decoded=$(base58_decode "$token_encoded")
        local branch_encoded
        local current_cmd=$(get_current_cmd_name)
        if ! [[ "$GITHUB_BRANCH" =~ ^[a-zA-Z0-9_\./-]+$ ]]; then
            error "GitHub分支名含非法字符，无法生成链接"
            echo -e "\n${gl_yellow}[0] 返回上级菜单${gl_reset}"
            read -e -p "$(echo -e "\n${gl_blue}请输入选择：${gl_reset}")" choice
            [[ "$choice" == "0" ]] && sync_menu
            error_retry; continue
        fi
        if ! command -v python3 &> /dev/null; then
            warning "python3未安装，使用基础字符转义（仅兼容/字符）"
            branch_encoded=$(echo "$GITHUB_BRANCH" | sed 's/\//%2F/g')
        else
            branch_encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$GITHUB_BRANCH'))")
        fi
        if [[ "$sync_mode" != "$SYNC_MODE_GITHUB" || -z "$github_repo" || -z "$token_decoded" ]]; then
            error "非GitHub模式或配置不完整"
            echo -e "\n${gl_yellow}[0] 返回上级菜单${gl_reset}"
            read -e -p "$(echo -e "\n${gl_blue}请输入选择：${gl_reset}")" choice
            [[ "$choice" == "0" ]] && sync_menu
            error_retry; continue
        fi
        echo -e "\n${gl_cyan}GitHub配置：${gl_reset}"
        echo -e "\n仓库：$github_repo"
        echo -e "分支：$GITHUB_BRANCH（编码后：$branch_encoded）"
        echo -e "Token：已设置（Base58编码存储，生成命令时自动处理）"
        echo -e "\n${gl_cyan}一键安装同步命令（启动命令：${gl_green}$current_cmd${gl_reset}）：${gl_reset}"
        echo -e '\nexport CCTB_TOKEN="'$token_decoded'" && bash <(curl -s --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/withabc/cctb/'$branch_encoded'/cctb.sh) --sync "'$github_repo'" "$CCTB_TOKEN" && unset CCTB_TOKEN'
        echo -e "\n${gl_yellow}注意：1. 执行前确保已安装curl 2. Token敏感，执行后自动清除环境变量${gl_reset}"
        echo -e "\n${gl_green}${CONTINUE} 按任意键返回...${gl_reset}\n"
        read -n 1 -s -r
        sync_menu
    done
}

# 配置关联函数：删除GitHub配置
delete_github_config() {
    local confirm
    while true; do
        print_header
        echo -e "\n${BOLD}${gl_red}删除GitHub配置${gl_reset}\n"
        echo -e "${gl_yellow}警告：此操作将清除已保存的GitHub仓库、Token配置，且不可恢复！${gl_reset}"
        echo -e "\n${gl_yellow}[0] 取消并返回上级菜单${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}确认删除？[Y/N/0]：${gl_reset}")" confirm
        case "$confirm" in
            y|Y|"")
                local wd_url=$(get_config_value "WEBDAV_URL" "")
                local wd_user=$(get_config_value "WEBDAV_USER" "")
                local wd_pass=$(get_config_value "WEBDAV_PASS" "")
                local cache_size=$(get_config_value "CACHE_SIZE" 10)
                cat > "$CONFIG_FILE" <<EOF
SYNC_MODE=$SYNC_MODE_LOCAL
GITHUB_REPO=
GITHUB_TOKEN=
WEBDAV_URL=$wd_url
WEBDAV_USER=$wd_user
WEBDAV_PASS=$wd_pass
CACHE_SIZE=$cache_size
EOF
                load_config
                echo -e "\n${gl_green}${SUCCESS} GitHub配置已删除，已切换到本地模式${gl_reset}"
                press_any_key_continue
                config_menu
                return
                ;;
            n|N)
                echo -e "\n${gl_green}${SUCCESS} 已取消删除${gl_reset}"
                press_any_key_continue
                config_menu
                return
                ;;
            0) config_menu; return ;;
            *) error_retry; continue ;;
        esac
    done
}

# 配置关联函数：删除WebDAV配置
delete_webdav_config() {
    local confirm
    while true; do
        print_header
        echo -e "\n${BOLD}${gl_red}删除WebDAV配置${gl_reset}\n"
        echo -e "${gl_yellow}警告：此操作将清除已保存的WebDAV地址、账号、密码，且不可恢复！${gl_reset}"
        echo -e "\n${gl_yellow}[0] 取消并返回上级菜单${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}确认删除？[Y/N/0]：${gl_reset}")" confirm
        case "$confirm" in
            y|Y|"")
                local gh_repo=$(get_config_value "GITHUB_REPO" "")
                local gh_token=$(get_config_value "GITHUB_TOKEN" "")
                local cache_size=$(get_config_value "CACHE_SIZE" 10)
                cat > "$CONFIG_FILE" <<EOF
SYNC_MODE=$SYNC_MODE_LOCAL
GITHUB_REPO=$gh_repo
GITHUB_TOKEN=$gh_token
WEBDAV_URL=
WEBDAV_USER=
WEBDAV_PASS=
CACHE_SIZE=$cache_size
EOF
                load_config
                echo -e "\n${gl_green}${SUCCESS} WebDAV配置已删除，已切换到本地模式${gl_reset}"
                press_any_key_continue
                config_menu
                return
                ;;
            n|N)
                echo -e "\n${gl_green}${SUCCESS} 已取消删除${gl_reset}"
                press_any_key_continue
                config_menu
                return
                ;;
            0) config_menu; return ;;
            *) error_retry; continue ;;
        esac
    done
}

# 配置关联函数：配置菜单
config_menu() {
    local choice
    while true; do
        print_header
        echo -e "\n${BOLD}${gl_blue}配置设置${gl_reset} ${gl_cyan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_reset}"
        echo -e "\n${BOLD}1. 删除GitHub配置    2. 删除WebDAV配置${gl_reset}"
        echo -e "\n${BOLD}3. 查看当前配置      4. 查看帮助信息${gl_reset}"
        echo -e "\n${BOLD}5. 修改启动命令      0. 返回上级菜单${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}选择：${gl_reset}")" choice
        case "$choice" in
            1)
                delete_github_config 
                clear_cache
                ;;
            2)
                delete_webdav_config 
                clear_cache
                ;;
            3)
                local current_cmd=$(get_current_cmd_name)
                local token_encoded=$(get_config_value "GITHUB_TOKEN")
                local webdav_pass_encoded=$(get_config_value "WEBDAV_PASS")
                local token_status="未设置"
                local webdav_pass_status="未设置"
                local cache_count=$(wc -l < "$CACHE_FILE" 2>/dev/null)
                [[ -n "$token_encoded" ]] && token_status="已设置（Base58编码）"
                [[ -n "$webdav_pass_encoded" ]] && webdav_pass_status="已设置（Base58编码）"
                echo -e "\n${gl_cyan}${BOLD}当前配置：${gl_reset}\n"
                echo -e "同步模式：$(get_config_value "SYNC_MODE")"
                echo -e "GitHub仓库：$(get_config_value "GITHUB_REPO" "未设置")"
                echo -e "GitHub分支：$GITHUB_BRANCH（全局统一配置）"
                echo -e "Token 状态：$token_status"
                echo -e "WebDAV地址：$(get_config_value "WEBDAV_URL" "未设置")"
                echo -e "WebDAV账号：$(get_config_value "WEBDAV_USER" "未设置")"
                echo -e "WebDAV密码：$webdav_pass_status"
                echo -e "当前版本：v${SCRIPT_VERSION}"
                echo -e "启动命令：${gl_green}$current_cmd${gl_reset}"
                echo -e "缓存状态：$( [[ $CACHE_INITED == true ]] && echo "已初始化（$cache_count/$CACHE_SIZE条）" || echo "未初始化" )"
                press_any_key_continue
                ;;
            4)
                show_help
                press_any_key_continue
                ;;
            5)
                change_cmd_name
                ;;
            0)
                settings
                ;;
            *)
                error_retry
                ;;
        esac
    done
}

# 配置关联函数：修改启动命令
change_cmd_name() {
    local current_cmd=$(get_current_cmd_name)
    local new_cmd
    local script_path="$LATEST_SCRIPT_PATH"
    while true; do
        print_header
        echo -e "\n${BOLD}${ROCKET} 修改启动命令${gl_reset}"
        echo -e "\n${gl_cyan}当前启动命令：${gl_green}$current_cmd${gl_reset}"
        echo -e "\n${gl_yellow}注意：1. 仅支持字母、数字、下划线 2. 禁止覆盖系统命令（如ls、rm）${gl_reset}"
        echo -e "\n${gl_blue}输入0返回上级，直接回车保留当前命令${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}请输入新的启动命令：${gl_reset}")" new_cmd
        new_cmd=$(echo "$new_cmd" | xargs)
        if [[ "$new_cmd" == "0" ]]; then
            config_menu
        fi
        if [[ -z "$new_cmd" ]]; then
            echo -e "\n${gl_green}${SUCCESS} 已保留当前命令：$current_cmd${gl_reset}"
            press_any_key_continue
            return
        fi
        if ! [[ "$new_cmd" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
            error "无效命令名！需以字母/下划线开头，含字母/数字/下划线"
            press_any_key_continue
            continue
        fi
        local existing_tool_cmds=$(ls /usr/local/bin/ 2>/dev/null | grep -E "^[a-zA-Z_][a-zA-Z0-9_]*$" | xargs)
        if [[ -n "$existing_tool_cmds" && "$existing_tool_cmds" =~ "$new_cmd" ]]; then
            error "新命令名 '$new_cmd' 已被其他工具箱实例使用，请更换名称！"
            press_any_key_continue
            continue
        fi
        if command -v "$new_cmd" &> /dev/null; then
            error "新命令名 '$new_cmd' 是系统命令，禁止覆盖！"
            press_any_key_continue
            continue
        fi
        if [[ "$new_cmd" == "$current_cmd" ]]; then
            warning "新命令名与当前命令名相同，无需修改"
            press_any_key_continue
            return
        fi
        if [[ ! -f "$script_path" ]]; then
            echo -e "\n${gl_yellow}脚本文件不存在，自动拉取最新版本...${gl_reset}"
            if ! fetch_latest_script; then
                error "拉取脚本失败，无法修改启动命令"
                press_any_key_continue
                continue
            fi
        fi
        local confirm
        read -e -p "$(echo -e "\n确认改为 ${gl_green}$new_cmd${gl_reset} ？[Y/N/0]：")" confirm
        case "$confirm" in
            y|Y|"")
                if [[ "$(id -u)" -eq 0 ]]; then
                    rm -f "/usr/local/bin/$current_cmd" 2>/dev/null
                else
                    sudo rm -f "/usr/local/bin/$current_cmd" 2>/dev/null
                fi
                if ! copy_with_permission "$script_path" "/usr/local/bin/$new_cmd"; then
                    error "命令修改失败：权限不足或路径无效"
                    echo -e "\n${gl_yellow}请手动执行（Root用户）：${gl_reset}"
                    echo "cp -f $script_path /usr/local/bin/$new_cmd && chmod +x /usr/local/bin/$new_cmd && rm -f /usr/local/bin/$current_cmd"
                    press_any_key_continue
                    continue
                fi
                echo "$new_cmd" > "$CMD_NAME_FILE"
                echo -e "\n${gl_green}${SUCCESS} 命令名修改成功！后续用 ${gl_green}$new_cmd ${gl_green}启动${gl_reset}"
                press_any_key_continue
                if ! exec env -i PATH="$PATH" HOME="$HOME" TERM="$TERM" "$new_cmd"; then
                    error "命令重启失败（$new_cmd 不在PATH中）"
                    echo -e "\n${gl_yellow}请手动执行 $new_cmd 启动工具，或返回配置菜单${gl_reset}"
                    read -e -p "$(echo -e "\n${gl_blue}输入 0 返回配置菜单：${gl_reset}")" back_choice
                    [[ "$back_choice" == "0" ]] && config_menu
                    press_any_key_continue
                    exit 0
                fi
                ;;
            n|N)
                press_any_key_continue
                continue 
                ;;
            0) config_menu ;;
            *)
                press_any_key_continue
                continue 
                ;;
        esac
    done
}

# 界面函数：头部界面
print_header() {
    clear
    local current_cmd=$(get_current_cmd_name)
    echo -e "\n${BOLD}${gl_cyan}▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬${gl_reset}"
    echo -e "${BOLD}${gl_cyan}                命令工具箱 V${SCRIPT_VERSION}                ${gl_reset}"
    echo -e "${BOLD}${gl_cyan}  ──────────────────────────────────────────────${gl_reset}"
    echo -e "${BOLD}${gl_cyan}     输入关键词搜索|输入数字执行|启动命令：${gl_green}$current_cmd${gl_reset}"
    echo -e "${BOLD}${gl_cyan}▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬${gl_reset}"
}

# 界面函数：欢迎界面
show_welcome() {
    local choice
    while true; do
        print_header
        echo -e "\n${BOLD}${ROCKET} 欢迎使用命令工具箱（v${SCRIPT_VERSION}）！${gl_reset}"
        echo -e "\n${gl_cyan}功能：存储常用命令 | 快速执行 | 多设备同步（GitHub/WebDAV） | 自定义启动命令${gl_reset}"
        echo -e "\n${BOLD}选择使用模式：${gl_reset}"
        echo -e "${gl_green}[1] 本地模式${gl_reset} → 单机使用，命令存本地"
        echo -e "${gl_blue}[2] GitHub模式${gl_reset} → 多设备同步，需仓库/Token（仅需contents权限）"
        echo -e "${gl_cyan}[3] WebDAV模式${gl_reset} → 多设备同步，需WebDAV地址/账号/密码"
        echo -e "${gl_yellow}[0] 退出程序${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}请选择 [0/1/2/3]：${gl_reset}")" choice
        case "$choice" in
            1) 
                setup_local_mode; 
                break 
                ;;
            2) 
                setup_github_mode; 
                clear
                break 
                ;;
            3) 
                setup_webdav_mode; 
                clear
                break 
                ;;
            0) 
                clear; 
                echo -e "\n${gl_green}再见！${gl_reset}"; 
                sleep 1; 
                clear; 
                exit 0 
                ;;
            *) error_retry ;;
        esac
    done
    echo -e "\n${gl_green}${SUCCESS} 配置完成！2秒后启动...${gl_reset}\n"
    sleep 2
    clear
    init_config && load_config && init_cache && main
}

# 界面函数：帮助信息
show_help() {
    local current_cmd=$(get_current_cmd_name)
    echo -e "${gl_cyan}====================================================================${gl_reset}"
    echo -e "\n${BOLD}${gl_cyan}命令工具箱 v${SCRIPT_VERSION}  - 完整用法${gl_reset}"
    echo -e "\n${BOLD}一、核心命令${gl_reset}"
    echo -e "\n  ${gl_green}$current_cmd${gl_reset}                   启动一级主界面（仅显示可执行命令，屏蔽管理操作）"
    echo -e "  ${gl_green}$current_cmd -h/--help${gl_reset}         查看本完整帮助文档"
    echo -e "  ${gl_green}$current_cmd -v/--version${gl_reset}      查看当前版本及核心特性"
    echo -e "  ${gl_green}$current_cmd -m/--manage${gl_reset}       直接进入二级设置界面（命令管理/同步/配置）"
    echo -e "  ${gl_green}$current_cmd -s/--sync${gl_reset}         手动触发同步（GitHub/WebDAV模式有效，自动处理冲突）"
    echo -e "  ${gl_green}$current_cmd --reset${gl_reset}           重置配置（清除~/.cctb下所有数据：命令/同步模式/缓存）"
    echo -e "  ${gl_green}$current_cmd --change-cmd${gl_reset}      修改启动命令（如从cb改为cctb，自动重启生效）"
    echo -e "  ${gl_green}$current_cmd -l/--list${gl_reset}         列出所有已存储命令（显示编号、类型、名称）"
    echo -e "  ${gl_green}DEBUG=1 $current_cmd${gl_reset}           开启调试模式（显示缓存命中/同步日志/命令解析过程）"
    echo -e "\n${BOLD}二、命令类型说明${gl_reset}"
    echo -e "\n  ${gl_blue}1. 本地命令${gl_reset} → 直接输入命令内容（如htop、docker ps），存储于本地，无网络依赖"
    echo -e "  ${gl_blue}2. 私仓命令${gl_reset} → GitHub模式专属，自动加载已配置仓库/分支（需Token含contents权限），仅本人可访问"
    echo -e "  ${gl_blue}3. 公仓命令${gl_reset} → 输入GitHub公仓路径（格式：user/repo/branch/script.sh，如withabc/cctb/main/test.sh），公开可访问"
    echo -e "  ${gl_blue}4. 网络命令${gl_reset} → 输入网络脚本URL（格式：test.com/test.sh），自动补全http/https前缀，需网络连接"
    echo -e "\n${BOLD}三、同步模式详情${gl_reset}"
    echo -e "\n  ${gl_blue}1. 本地模式（Local）${gl_reset} → 命令仅存储于~/.cctb/commands.json，适合单机使用，无需网络"
    echo -e "     - 数据路径：~/.cctb（所有配置、命令、缓存文件均在此目录）"
    echo -e "     - 适用场景：单台设备，无需多端同步"
    echo -e "\n  ${gl_blue}2. GitHub模式${gl_reset} → 多设备同步，需提前准备："
    echo -e "     - 前提条件：创建GitHub仓库（如cctb-commands）、生成Token（仅需contents权限，最小权限原则）"
    echo -e "     - 自动同步：添加/编辑/删除命令后、导入命令后，自动同步到GitHub仓库"
    echo -e "     - 手动同步：二级界面「05. 同步管理」选项或执行 $current_cmd --sync"
    echo -e "     - 同步限制：单文件最大80MB（超过将提示拆分文件）"
    echo -e "\n  ${gl_blue}3. WebDAV模式${gl_reset} → 多设备同步，需提前准备："
    echo -e "     - 前提条件：WebDAV服务器地址（如https://dav.example.com 或局域网地址）、账号密码（需写入权限）"
    echo -e "     - 密码存储：WebDAV密码采用Base58编码存储，避免明文泄露"
    echo -e "     - 自动同步：与GitHub模式一致，命令操作后自动同步到WebDAV服务器"
    echo -e "     - 手动同步：二级界面「05. 同步管理」选项或执行 $current_cmd --sync"
    echo -e "     - 同步建议：文件大小≤100MB（避免超出服务器限制）"
    echo -e "\n${BOLD}四、界面操作规则${gl_reset}"
    echo -e "\n  ${gl_blue}1. 一级主界面${gl_reset}（命令执行界面）："
    echo -e "     - 执行命令：输入命令编号（如1、10）"
    echo -e "     - 进入管理：输入99进入二级设置界面"
    echo -e "     - 退出程序：输入00"
    echo -e "     - 命令搜索：输入关键词（不区分大小写，匹配命令名称或内容）"
    echo -e "     - 屏蔽操作：禁止直接输入01-07（需进入二级界面操作）"
    echo -e "\n  ${gl_blue}2. 二级设置界面${gl_reset}（命令管理界面）："
    echo -e "     - 01. 添加命令：创建新命令，支持4种命令类型选择"
    echo -e "     - 02. 编辑命令：修改已有命令的名称、类型、内容、描述"
    echo -e "     - 03. 删除命令：支持批量删除（连续1-3、离散1 3、混合1-2 4）"
    echo -e "     - 04. 命令排序：调整命令显示顺序（完整排序、局部调换、两两对调）"
    echo -e "     - 05. 同步管理：切换同步模式、执行手动同步、导出GitHub快速链接"
    echo -e "     - 06. 文件导出：导入/导出命令文件（JSON格式，防覆盖）"
    echo -e "     - 07. 配置设置：删除同步配置、查看当前配置、修改启动命令、查看帮助"
    echo -e "     - 返回上级：输入00回到一级主界面"
    echo -e "     - 退出程序：输入99"
    echo -e "\n  ${gl_blue}3. 命令排序语法${gl_reset}："
    echo -e "     - 完整排序：输入所有命令编号（如5 2 3 6 4 1 7），覆盖全部顺序"
    echo -e "     - 局部调换：输入范围+新顺序（如1-3=3 1 2），仅调整1-3号命令顺序"
    echo -e "     - 两两对调：输入两个编号（如1=7），交换1号和7号命令位置"
    echo -e "\n${BOLD}五、导入导出说明${gl_reset}"
    echo -e "\n  ${gl_blue}1. 导出命令${gl_reset} → 生成带毫秒时间戳的JSON文件（如~/.cctb_commands_20240520_153045_1234567.json）"
    echo -e "     - 防覆盖：自动生成唯一文件名，避免误删现有文件"
    echo -e "     - 自定义路径：支持手动输入导出路径，直接回车使用默认路径（$HOME目录下）"
    echo -e "     - 权限校验：导出前检查目标路径写入权限，无权限则提示错误"
    echo -e "\n  ${gl_blue}2. 导入命令${gl_reset} → 支持两种模式，需导入文件为标准JSON格式："
    echo -e "     - 合并模式（1）：保留现有命令，自动跳过同名命令（大小写不敏感去重）"
    echo -e "     - 替换模式（2）：覆盖现有所有命令，适用于批量迁移场景"
    echo -e "     - 文件要求：根节点含\"commands\"数组，每个命令需有\"name\"（名称）和\"command\"（内容）字段"
    echo -e "     - 格式校验：自动检测JSON格式有效性，无效格式提示错误"
    echo -e "\n${BOLD}六、安全特性${gl_reset}"
    echo -e "\n  ${gl_blue}1. 敏感信息加密存储${gl_reset} → GitHub Token、WebDAV密码均采用Base58编码存储于~/.cctb/config，避免明文泄露"
    echo -e "     - 解码容错：解码失败时自动切换到本地模式，提示重新配置"
    echo -e "\n  ${gl_blue}2. 高危命令检测拦截${gl_reset} → 执行前强制二次确认，检测范围包括但不限于："
    echo -e "     - sudo rm -rf / 或 /.*（根目录删除）、sudo rm -rf ~（用户目录删除）"
    echo -e "     - sudo dd if=* of=*（磁盘写入，可能覆盖磁盘）"
    echo -e "     - sudo shutdown/reboot（系统关机/重启）"
    echo -e "     - sudo chmod 777 / 或 /*（全局权限篡改）"
    echo -e "     - sudo fdisk /dev/（磁盘分区操作）、sudo cp/mv .* /etc/（系统配置篡改）"
    echo -e "     - 高危日志：添加高危命令时自动记录日志（路径：~/.cctb/high_risk_cmd.log），包含时间、用户、命令详情"
    echo -e "\n  ${gl_blue}3. 环境变量安全${gl_reset} → GitHub快速连接命令中，Token通过环境变量传递，执行后自动unset，避免Shell历史记录泄露"
    echo -e "\n  ${gl_blue}4. 权限控制${gl_reset} → 安装/修改启动命令时检查sudo权限，无权限则提示手动执行，避免越权操作"
    echo -e "\n${BOLD}七、缓存特性${gl_reset}"
    echo -e "\n  ${gl_blue}1. 自动缓存机制${gl_reset} → 缓存最近N条执行命令（N=~/.cctb/config中CACHE_SIZE，默认10条），加速命令加载"
    echo -e "     - 缓存文件：~/.cctb/cache，存储缓存键、时间戳、命令内容"
    echo -e "     - 缓存命中：重复执行同一命令时，优先从缓存加载，减少JSON解析耗时"
    echo -e "\n  ${gl_blue}2. 缓存自动清空${gl_reset} → 以下操作后自动清空缓存，确保数据最新："
    echo -e "     - 命令添加/编辑/删除/排序、命令导入/导出"
    echo -e "     - 从GitHub/WebDAV同步命令、修改同步模式"
    echo -e "\n  ${gl_blue}3. 缓存调试${gl_reset} → 开启DEBUG模式（DEBUG=1 $current_cmd），可查看："
    echo -e "     - 缓存命中日志（如「缓存命中：htop（键：htop_1）」）"
    echo -e "     - 缓存更新日志（如「命令缓存更新：docker ps（键：docker_2）」）"
    echo -e "     - 缓存初始化状态（大小、文件路径）"
    echo -e "\n${BOLD}八、配置文件信息${gl_reset}"
    echo -e "\n  ${gl_blue}配置目录${gl_reset}：~/.cctb（所有数据存储于此，删除该目录即完全重置工具）"
    echo -e "  ${gl_blue}关键文件说明${gl_reset}："
    echo -e "     - config：存储同步模式、GitHub仓库/Token（Base58编码）、WebDAV地址/账号/密码（Base58编码）、缓存大小"
    echo -e "     - commands.json：所有命令的JSON存储文件（可手动编辑，需保证JSON格式正确，错误将自动重置为空数组）"
    echo -e "     - cmd_name：当前启动命令（如cb），修改后立即生效"
    echo -e "     - version_local：已安装版本号，用于版本对比，判断是否需要更新"
    echo -e "     - version_latest：远程最新版本号缓存（24小时内不重复拉取，减少网络请求）"
    echo -e "     - cctb_latest：从GitHub拉取的最新脚本文件，用于更新或安装"
    echo -e "     - high_risk_cmd.log：高危命令操作日志，记录高危命令添加记录"
    echo -e "\n${BOLD}九、跨平台兼容特性${gl_reset}"
    echo -e "\n  ${gl_blue}1. 系统兼容${gl_reset} → 支持Linux（Ubuntu/CentOS/Alpine）、macOS（含旧版本10.14以下）"
    echo -e "     - 日期生成：macOS旧版本使用sed处理ISO日期格式，Linux直接使用date -Iseconds"
    echo -e "     - stat命令：macOS旧版本使用stat -f %c/%z，新版本及Linux使用stat -f %m/%z或stat -c %Y/%s"
    echo -e "     - 包管理器：自动识别apt/yum/apk/brew，提示对应安装命令（如依赖jq、curl时）"
    echo -e "\n  ${gl_blue}2. 工具兼容${gl_reset} → 跨平台支持base64编解码（base64 -w 0/-d）、jq JSON处理、curl网络请求"
    echo -e "     - Base58编解码：纯Shell实现，无需依赖外部工具，确保各平台一致"
    echo -e "\n${BOLD}十、常见问题与解决方案${gl_reset}"
    echo -e "\n  ${gl_blue}1. 命令执行失败${gl_reset} → 排查步骤："
    echo -e "     - 本地命令：检查命令内容是否正确（如拼写错误、参数缺失）"
    echo -e "     - 私仓/公仓命令：检查GitHub仓库路径、分支是否正确，Token权限是否有效（仅contents权限即可）"
    echo -e "     - 网络命令：检查URL是否可访问（curl命令测试），是否需补全http/https前缀"
    echo -e "     - 高危命令：确认是否已通过二次确认，是否有足够权限执行（如sudo命令需输入密码）"
    echo -e "\n  ${gl_blue}2. 同步失败（GitHub模式）${gl_reset} → 排查步骤："
    echo -e "     - 配置检查：进入「07. 配置设置 → 3. 查看当前配置」，确认GitHub仓库、Token是否完整"
    echo -e "     - 网络检查：确认网络可访问GitHub（ping github.com），curl能否拉取脚本（curl -s $LATEST_SCRIPT_URL）"
    echo -e "     - Token权限：确认Token含contents权限（创建Token时勾选repo → contents）"
    echo -e "     - 文件大小：检查commands.json是否超过80MB（GitHub单文件限制），超过则拆分或删除无用命令"
    echo -e "\n  ${gl_blue}3. 同步失败（WebDAV模式）${gl_reset} → 排查步骤："
    echo -e "     - 配置检查：确认WebDAV地址（需http/https开头）、账号、密码是否正确"
    echo -e "     - 连接测试：手动用curl测试连接（curl -u 账号:密码 -X PROPFIND WebDAV地址）"
    echo -e "     - 权限检查：确认账号有目录创建（MKCOL）、文件写入（PUT）权限"
    echo -e "     - 目录存在：确认cctb目录已存在（WebDAV地址/cctb/），不存在则工具会自动尝试创建"
    echo -e "     - 超时问题：同步超时可检查网络稳定性，工具默认连接超时20秒、传输超时120秒"
    echo -e "\n  ${gl_blue}4. 启动命令修改后无效${gl_reset} → 解决方案："
    echo -e "     - 手动刷新Shell：执行「exec $SHELL」或重新打开终端，确保PATH生效"
    echo -e "     - 检查PATH：确认/usr/local/bin在PATH中（echo $PATH | grep /usr/local/bin），不在则添加（echo 'export PATH=/usr/local/bin:$PATH' >> ~/.bashrc/.zshrc）"
    echo -e "     - 手动执行：若自动修改失败，执行手动命令（sudo cp ~/.cctb/cctb_latest /usr/local/bin/新命令 && sudo chmod +x /usr/local/bin/新命令 && sudo rm -f /usr/local/bin/旧命令）"
    echo -e "\n  ${gl_blue}5. 命令文件格式错误（已重置）${gl_reset} → 原因与解决："
    echo -e "     - 原因：手动编辑commands.json时格式错误（如逗号缺失、引号不匹配）"
    echo -e "     - 解决：工具自动重置为{\"commands\": []}，需重新导入命令或添加命令；建议手动编辑前备份文件"
    echo -e "\n  ${gl_blue}6. 依赖工具缺失（如jq、curl）${gl_reset} → 解决方案："
    echo -e "     - Ubuntu/Debian：sudo apt install jq curl"
    echo -e "     - CentOS/RHEL：sudo yum install jq curl"
    echo -e "     - Alpine：sudo apk add jq curl"
    echo -e "     - macOS：brew install jq curl"
    echo -e "\n  ${gl_blue}7. 无法拉取最新脚本（更新失败）${gl_reset} → 解决方案："
    echo -e "     - 网络检查：确认网络可访问GitHub，是否需配置代理（export http_proxy/https_proxy）"
    echo -e "     - 手动拉取：执行curl -s $LATEST_SCRIPT_URL -o ~/.cctb/cctb_latest，再手动安装/更新"
    echo -e "\n${BOLD}十一、版本更新说明${gl_reset}"
    echo -e "\n  ${gl_blue}1. 自动更新${gl_reset} → 启动工具时自动检测远程版本（GitHub main分支），检测到新版本（v$remote_ver）时提示更新，默认选择Y（更新）"
    echo -e "     - 更新逻辑：拉取最新脚本到~/.cctb/cctb_latest，覆盖安装到/usr/local/bin/$current_cmd，更新version_local文件"
    echo -e "     - 失败处理：更新失败时提示手动执行命令，继续使用当前版本"
    echo -e "\n  ${gl_blue}2. 手动更新${gl_reset} → 执行以下命令："
    echo -e "     - curl -s $LATEST_SCRIPT_URL -o ~/.cctb/cctb_latest"
    echo -e "     - sudo cp ~/.cctb/cctb_latest /usr/local/bin/$current_cmd && sudo chmod +x /usr/local/bin/$current_cmd"
    echo -e "\n${gl_cyan}====================================================================${gl_reset}"
}

# 界面函数：版本信息
show_version() {
    local current_cmd=$(get_current_cmd_name)
    echo -e "命令工具箱 v${SCRIPT_VERSION}"
    echo -e "启动命令：${gl_green}$current_cmd${gl_reset}"
    echo -e "界面层级：一级主界面（执行命令）→ 二级设置界面（管理命令）"
    echo -e "支持同步模式：本地模式、GitHub模式、WebDAV模式"
    echo -e "支持命令类型：本地命令、公仓命令、网络命令（GitHub模式额外支持私仓命令）"
    echo -e "安全特性：GitHub Token/WebDAV密码 Base58编码存储 + 高危命令二次确认（含通配符/权限篡改检测）"
    echo -e "缓存特性：自动缓存最近${CACHE_SIZE}条命令，支持配置文件自定义缓存大小"
    echo -e "退出规则：一级界面输00退出，二级界面输00返回一级、99退出"
    echo -e "GitHub：https://github.com/withabc/cctb/tree/$GITHUB_BRANCH"
}

# 执行函数：显示命令列表
display_commands() {
    local search_term="$1"
    if ! validate_and_reset_commands_file; then
        return
    fi
    local cmds cmd_idx=0 total_count=0
    total_count=$(echo "$CMD_JSON" | jq -r '.commands | length' 2>/dev/null || echo 0)
    echo -e "\n${gl_cyan}==================================================${gl_reset}"
    if [[ -n "$search_term" ]]; then
        echo -e "${BOLD}${gl_cyan}命令搜索结果：\"${gl_yellow}$search_term${gl_cyan}\"${gl_reset}"
    else
        echo -e "${BOLD}${gl_cyan}命令列表（共 ${gl_green}$total_count${gl_cyan} 条）${gl_reset}"
    fi
    echo -e "${gl_cyan}--------------------------------------------------${gl_reset}"
    echo -e "${BOLD}${gl_gray} 编号    类型     命令名称${gl_reset}"
    echo -e "${gl_cyan}--------------------------------------------------${gl_reset}"
    if [[ -n "$search_term" ]]; then
        cmds=$(echo "$CMD_JSON" | jq -r --arg k "$search_term" '.commands[]? | select((.name | contains($k)) or (.command | contains($k)) or (.type | contains($k))) | [.type, .name] | @tsv' 2>/dev/null)
    else
        cmds=$(echo "$CMD_JSON" | jq -r '.commands[]? | [.type, .name] | @tsv' 2>/dev/null)
    fi
    if [[ -z "$cmds" ]]; then
        echo -e "\n  ${gl_yellow}${WARNING} 没有匹配的命令${gl_reset}"
        echo -e "\n${gl_cyan}==================================================${gl_reset}\n"
        return
    fi
    local search_term_lower="${search_term,,}"
    while IFS=$'\t' read -r cmd_type cmd_name; do
        cmd_idx=$((cmd_idx + 1))
        local type_flag=$(get_cmd_type_flag "$cmd_type")
        printf -v padded_idx "%02d" "$cmd_idx"
        local final_name="$cmd_name"
        if [[ -n "$search_term" ]]; then
            local cmd_name_lower="${cmd_name,,}"
            local pos=$(expr index "$cmd_name_lower" "$search_term_lower")
            if [[ $pos -gt 0 ]]; then
                local len=${#search_term}
                local prefix="${cmd_name:0:$((pos - 1))}"
                local match="${cmd_name:$((pos - 1)):$len}"
                local suffix="${cmd_name:$((pos + len - 1))}"
                final_name="${prefix}${gl_red}${BOLD}${match}${RESET}${suffix}"
            fi
        fi
        echo -e "\n  ${BOLD}${gl_green}${padded_idx}${gl_reset}   ${type_flag}   ${BOLD}${final_name}${gl_reset}"
    done <<< "$cmds"
    local result_count=$cmd_idx
    echo -e "\n${gl_cyan}--------------------------------------------------${gl_reset}"
    if [[ -n "$search_term" ]]; then
        echo -e "${gl_green}${SUCCESS} 找到 ${BOLD}$result_count${gl_reset}${gl_green} 条匹配命令${gl_reset}"
    else
        echo -e "${gl_green}${SUCCESS} 共 ${BOLD}$total_count${gl_reset}${gl_green} 条命令，当前显示全部${gl_reset}"
    fi
    echo -e "${gl_cyan}==================================================${gl_reset}"
}

# 执行函数：处理用户输入（一级/二级区分）
handle_input() {
    local input="$1" search_term="$2"
    local current_cmd=$(get_current_cmd_name)
    if [[ -z "$input" ]]; then
        settings ""
        return
    fi
    case "$input" in
        q|quit|exit) clear; echo -e "\n${gl_green}再见！${gl_reset}"; sleep 1; clear; exit 0 ;;
        01) add_command ;;
        02) edit_command ;;
        03) delete_command ;;
        04) sort_commands ;;
        05) sync_menu ;;
        06) import_export_menu ;;
        07) config_menu ;;
        "$current_cmd --change-cmd") change_cmd_name ;;
        [1-9]|[1-9][0-9]*) execute_command "$input" "$search_term" ;;
        *) settings "$input" ;;
    esac
}

# 执行函数：执行命令（优先缓存）
execute_command() {
    local num="$1" search_term="$2"
    local cmd_data cmd_name is_hit cache_key cache_result
    init_cache || { error_retry; settings "$search_term"; return; }
    
    cache_result=$(get_cached_cmd "$num" "$search_term")
    cmd_data=$(echo "$cache_result" | cut -d'|' -f1)
    cmd_name=$(echo "$cache_result" | cut -d'|' -f2)
    is_hit=$(echo "$cache_result" | cut -d'|' -f3)
    cache_key=$(echo "$cache_result" | cut -d'|' -f4)
    if [[ -z "$cmd_data" || "$cmd_name" == "未命名命令" && -z "$cmd_data" ]]; then
        if [[ -n "$search_term" ]]; then
            local search_count=$(echo "$CMD_JSON" | jq -r --arg k "$search_term" '.commands[]? | select((.name | ascii_downcase | contains($k | ascii_downcase)) or (.command | ascii_downcase | contains($k | ascii_downcase))) | .name' | wc -l 2>/dev/null)
            error "无效命令编号（搜索结果共$search_count条）"
        else
            local total_commands=$(echo "$CMD_JSON" | jq -r '.commands | length' 2>/dev/null || echo 0)
            error "无效命令编号（共$total_commands条命令）"
        fi
        error_retry
        settings "$search_term"
        return
    fi
    if is_high_risk_cmd "$cmd_data"; then
        local confirm
        warning "检测到高危命令！执行可能导致数据丢失或系统异常"
        read -e -p "$(echo -e "\n${gl_blue}确认继续执行？[Y/N]：${gl_reset}")" confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "\n${gl_green}已取消执行${gl_reset}"
            press_any_key_continue
            settings "$search_term"
            return
        fi
    fi
    echo -e "\n${gl_green}${CONTINUE} 即将进入脚本界面：${cmd_name}${gl_reset}"
    if [[ $DEBUG -eq 1 ]]; then
        if [[ "$is_hit" -eq 1 ]]; then
            echo -e "\n${gl_green}${SUCCESS} 缓存命中：${gl_cyan}$cmd_name${gl_reset}（键：$cache_key）"
        else
            echo -e "\n${gl_green}${SUCCESS} 命令缓存更新：${gl_cyan}$cmd_name${gl_reset}（键：$cache_key）"
        fi
    fi
    echo -e "\n${gl_yellow}${WARNING} 提示：外部脚本退出后，将返回工具箱主界面...${gl_reset}"
    echo -e "\n${gl_green}${CONTINUE} 按任意键启动脚本...${gl_reset}\n"
    read -n 1 -s -r
    clear
    local decrypted_cmd
    decrypted_cmd=$(echo "$cmd_data" | sed -E 's/\{ENCRYPTED_TOKEN:([^}]+)\}/$(base58_decode "\1" || echo "invalid_token")/g')
    if [[ "$decrypted_cmd" == *"bash <(curl"* ]]; then
        if ! echo "$decrypted_cmd" | grep -qE "curl .+https?://"; then
            error "命令格式异常！可能是Token解密失败或URL无效"
            echo -e "\n${gl_yellow}当前解析的命令：${gl_red}$decrypted_cmd${gl_reset}"
            press_any_key_continue
            settings "$search_term"
            return
        fi
    fi
    eval "bash -c \"$decrypted_cmd\""
    local exit_code=$?
    echo -e "\n${gl_cyan}${SUCCESS} 外部脚本已退出（退出码：$exit_code）${gl_reset}"
    echo -e "\n${gl_yellow}${CONTINUE} 按任意键返回工具箱界面...${gl_reset}\n"
    read -n 1 -s -r
    clear
    settings "$search_term"
}

# 执行函数：初始化配置
init_config() {
    local is_first_run=false
    [[ ! -d "$CONFIG_DIR" ]] && { mkdir -p "$CONFIG_DIR"; is_first_run=true; }
    if [[ ! -f "$COMMANDS_FILE" ]]; then
        if ! echo '{"commands": []}' > "$COMMANDS_FILE"; then
            error "命令文件初始化失败！请检查 $CONFIG_DIR 写入权限"
            exit 1
        fi
        is_first_run=true
    else
        validate_and_reset_commands_file
    fi
    [[ ! -f "$CMD_NAME_FILE" ]] && { echo "$DEFAULT_CMD_NAME" > "$CMD_NAME_FILE"; is_first_run=true; }
    if $is_first_run && [[ ! -f "$CONFIG_FILE" || ! "$(get_config_value "SYNC_MODE")" =~ ^($SYNC_MODE_GITHUB|$SYNC_MODE_WEBDAV)$ ]]; then
        show_welcome
    fi
    init_cache
}

# 界面函数：一级主界面（屏蔽01-07操作）
main() {
    local input search_term="" new_search is_valid
    init_config && load_config && init_cache
    while true; do
        clear
        echo -e "\n${BOLD} ${gl_red}                   命令收藏夹${gl_reset}"
        local cmd_count=$(echo "$CMD_JSON" | jq -r '.commands | if type == "array" then length else 0 end' 2>/dev/null || echo 0)
        
        if [[ "$cmd_count" -eq 0 ]]; then
            warning "暂无收藏命令，可进入【设置】添加"
            echo -e "\n${gl_cyan}==================================================${gl_reset}"
        else
            display_commands "$search_term"
        fi
        
        echo -e "${BOLD}99. 进入设置           ${gl_red}CCTB${gl_reset}           ${BOLD}00. 退出程序${gl_reset}"
        echo -e "${gl_cyan}==================================================${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}请输入选择：${gl_reset}")" input
        
        case "$input" in
            00)
                clear; echo -e "\n${gl_green}再见！${gl_reset}"; sleep 1; clear; exit 0
                ;;
            99)
                settings "$search_term"
                ;;
            0)
                error_retry "main"
                ;;
            01|02|03|04|05|06|07)
                error "一级界面不支持该操作！请先输入99进入设置"
                error_retry "main"
                ;;
            [1-9]|[1-9][0-9]*)
                if [[ "$input" =~ ^0[1-7]$ ]]; then
                    error "一级界面不支持该操作！请先输入99进入设置"
                    error_retry "main"
                    continue
                fi
                execute_command "$input" "$search_term"
                ;;
            *)
                if [[ -z "$input" ]]; then
                    search_term=""
                else
                    read new_search is_valid <<< $(cmd_search "$search_term" "main" "$input")
                    [[ "$is_valid" -eq 0 ]] && search_term="$new_search"
                fi
                ;;
        esac
    done
}

# 界面函数：二级设置界面
settings() {
    local input search_term="$1" new_search is_valid
    local mode_icon mode_text current_cmd cache_count cmd_count
    while true; do
        print_header
        if [[ "$SYNC_MODE" == "$SYNC_MODE_GITHUB" ]]; then
            mode_icon="${CLOUD}"; mode_text="GitHub同步"
        elif [[ "$SYNC_MODE" == "$SYNC_MODE_WEBDAV" ]]; then
            mode_icon="${WEBDAV}"; mode_text="WebDAV同步"
        else
            mode_icon="${LOCAL}"; mode_text="本地模式"
        fi
        cmd_count=$(echo "$CMD_JSON" | jq -r '.commands | if type == "array" then length else 0 end' 2>/dev/null || echo 0)
        current_cmd=$(get_current_cmd_name)
        cache_count=$(wc -l < "$CACHE_FILE" 2>/dev/null)
        echo -e "\n${BOLD}${gl_cyan}运行状态：$mode_icon $mode_text \n命令总数：📊 共 $cmd_count 条 \n缓存状态：♻️ $( [[ $CACHE_INITED == true ]] && echo "已加载（$cache_count/$CACHE_SIZE条）" || echo "未加载" ) ${gl_reset}"
        
        if [[ "$cmd_count" -eq 0 ]]; then
            warning "暂无收藏命令，输入01添加第一个命令"
            echo -e "\n${gl_cyan}推荐命令：${gl_reset}"
            echo -e " • 系统监控：htop\n • 查看端口：netstat -tlnp\n • Docker状态：docker ps -a"
        else
            display_commands "$search_term"
        fi
        
        echo -e "\n${gl_cyan}====================${gl_reset} ${BOLD}${gl_cyan}命令管理${gl_reset} ${gl_cyan}====================${gl_reset}"
        echo -e "${BOLD}01. 添加命令       02. 编辑命令       03. 删除命令${gl_reset}"
        echo -e "${gl_cyan}--------------------------------------------------${gl_reset}"
        echo -e "${BOLD}04. 命令排序       05. 同步管理       06. 文件导出${gl_reset}"
        echo -e "${gl_cyan}--------------------------------------------------${gl_reset}"
        echo -e "${BOLD}07. 配置设置       99. 退出程序       00. 返回上级${gl_reset}"
        echo -e "${gl_cyan}==================================================${gl_reset}"
        read -e -p "$(echo -e "\n${gl_blue}请输入选择：${gl_reset}")" input
        
        case "$input" in
            00)
                clear; main; return
                ;;
            99)
                clear; echo -e "\n${gl_green}再见！${gl_reset}"; sleep 1; clear; exit 0
                ;;
            0)
                error_retry "settings"
                ;;
            01|02|03|04|05|06|07)
                handle_input "$input" "$search_term"
                ;;
            [1-9]|[1-9][0-9]*)
                execute_command "$input" "$search_term"
                ;;
            *)
                if [[ -z "$input" ]]; then
                    search_term=""
                else
                    read new_search is_valid <<< $(cmd_search "$search_term" "settings" "$input")
                    [[ "$is_valid" -eq 0 ]] && search_term="$new_search"
                fi
                ;;
        esac
    done
}

# 核心函数：自动安装或更新
auto_install_or_update() {
    local action_type="$1"
    local default_cmd="$DEFAULT_CMD_NAME"
    local latest_script="$LATEST_SCRIPT_PATH"
    local local_ver="$SCRIPT_VERSION"
    local current_cmd=$(get_current_cmd_name)
    echo -e "\n${gl_green}${ROCKET} 正在比对版本号（本地版本：v$local_ver ）...${gl_reset}"
    if ! fetch_latest_script; then
        error "自动${action_type}失败：无法获取GitHub最新脚本"
        return 1
    fi
    local remote_ver=$(grep -oP '^SCRIPT_VERSION="\K[0-9]+\.[0-9]+\.[0-9]+"' "$latest_script" | tr -d '"')
    if [[ -z "$remote_ver" ]]; then
        error "\n无法解析GitHub最新脚本的版本号"
        return 1
    fi
    echo -e "\n${gl_green}${ROCKET} 正在${action_type}命令工具箱（目标版本：v$remote_ver，默认命令：${gl_red}$current_cmd ${gl_green}）...${gl_reset}"
    if copy_with_permission "$latest_script" "/usr/local/bin/$current_cmd"; then
        echo -e "\n${gl_green}${SUCCESS} ${action_type}成功！已安装到 /usr/local/bin/$current_cmd${gl_reset}"
        echo "$remote_ver" > "$VERSION_FILE"
    else
        error "\n自动${action_type}失败！请手动执行："
        echo "sudo cp $latest_script /usr/local/bin/$current_cmd && sudo chmod +x /usr/local/bin/$current_cmd"
        return 1
    fi
    echo -e "\n${gl_cyan}====================================================================${gl_reset}"
    echo -e "\n${BOLD}${gl_cyan}命令工具箱 v$remote_ver  - ${action_type}完成${gl_reset}"
    echo -e "\n${BOLD}后续可直接输入 ${gl_green}$current_cmd ${gl_reset}${BOLD}启动工具${gl_reset}"
    echo -e "\n${gl_cyan}====================================================================${gl_reset}"
    return 0
}

# 核心函数：版本更新判断
need_update() {
    [[ ! -f "$VERSION_FILE" ]] && return 1
    local installed_version=$(cat "$VERSION_FILE" 2>/dev/null | xargs)
    if ! [[ "$installed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
    IFS='.' read -r -a curr_arr <<< "$SCRIPT_VERSION"
    IFS='.' read -r -a inst_arr <<< "$installed_version"
    for i in 0 1 2; do
        local curr=${curr_arr[$i]:-0}
        local inst=${inst_arr[$i]:-0}
        if (( curr > inst )); then
            return 0
        elif (( curr < inst )); then
            return 1
        fi
    done
    return 1
}

# 启动入口函数
init_and_start() {
    if [[ "$1" == "-list" || "$1" == "-l" ]]; then
        mkdir -p "$CONFIG_DIR"
        check_dependency "jq"
        if [[ ! -f "$COMMANDS_FILE" ]]; then
            echo '{"commands": []}' > "$COMMANDS_FILE"
        elif ! jq empty "$COMMANDS_FILE" 2>/dev/null; then
            echo '{"commands": []}' > "$COMMANDS_FILE"
            echo -e "\n${BOLD_RED}${ERROR} 命令文件格式错误，已重置${RESET}"
        fi
        local cmd_count=$(jq -r '.commands | length' "$COMMANDS_FILE" 2>/dev/null || echo 0)
        echo -e "\n${BOLD_CYAN}             已储存命令列表（共 $cmd_count 条）${RESET}"
        echo -e "${gl_cyan}--------------------------------------------------${RESET}"
        echo -e "${BOLD} 编号    类型     命令名称${RESET}"
        echo -e "${gl_cyan}--------------------------------------------------${RESET}"
        local idx=0
        jq -r '.commands[] | [.type, .name] | @tsv' "$COMMANDS_FILE" 2>/dev/null | while IFS=$'\t' read -r cmd_type cmd_name; do
            idx=$((idx + 1))
            local type_flag=$(get_cmd_type_flag "$cmd_type")
            printf -v padded_idx "%02d" "$idx"
            echo -e "\n  ${BOLD}${gl_green}$padded_idx${RESET}   $type_flag   ${BOLD}$cmd_name${RESET}"
        done
        echo -e "\n${gl_cyan}--------------------------------------------------${RESET}\n"
        exit 0
    fi

    mkdir -p "$CONFIG_DIR"
    check_dependency "base64"
    check_dependency "jq"
    check_dependency "curl"
    
    local local_ver="$SCRIPT_VERSION"
    local remote_ver=""
    local current_cmd=$(get_current_cmd_name)
    if remote_ver=$(get_remote_version); then
        if version_compare "$local_ver" "$remote_ver"; then
            echo -e "\n${gl_yellow}${WARNING}  检测到新版本：v$remote_ver（当前：v$local_ver）${gl_reset}"
            read -e -i "Y" -p "$(echo -e "\n${gl_blue}是否更新？[Y/N]：${gl_reset}")" update_choice
            update_choice=$(echo "$update_choice" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]')
            update_choice=${update_choice:-"Y"}
            
            if [[ "$update_choice" == "Y" ]]; then
                if auto_install_or_update "更新"; then
                    echo -e "\n${gl_green}${SUCCESS} 更新完成！重启中...${gl_reset}"
                    sleep 2
                    exec "$current_cmd"
                else
                    echo -e "\n${gl_red}${ERROR} 更新失败，继续使用当前版本${gl_reset}"
                    press_any_key_continue
                fi
            else
                echo -e "\n${gl_yellow}${WARNING} 已取消更新，继续使用当前版本 v${local_ver}${gl_reset}"
                press_any_key_continue
            fi
        fi
    fi
    if ! command -v "$current_cmd" &> /dev/null; then
        echo -e "\n${gl_green}${ROCKET} 检测到未安装，自动安装到 /usr/local/bin...${gl_reset}"
        if auto_install_or_update "安装"; then
            echo -e "\n${gl_green}${SUCCESS} 自动安装完成！启动中...${gl_reset}"
            sleep 3
            exec "$current_cmd"
        else
            echo -e "\n${gl_red}${ERROR} 自动安装失败，可手动执行：${gl_reset}"
            echo "sudo cp $LATEST_SCRIPT_PATH /usr/local/bin/$current_cmd && sudo chmod +x /usr/local/bin/$current_cmd"
            press_any_key_continue
        fi
    fi
    clear && init_config && load_config && init_cache && main
}

# 启动程序
init_and_start "$@"


