#!/usr/bin/env bash
# setup-clash-ai.sh —— Linux 版一键配置（Windows 版是 Setup-ClashAI.ps1）：安全连接 AI、合理分流、安全连接代理。
#
# 前提：已安装 Clash Verge Rev（deb / rpm 包），至少打开过一次，并在「订阅」页导入了至少一个订阅。
# 用法（用普通用户运行，不要加 sudo；需要 root 的步骤脚本会自己调用 sudo）：
#   bash setup-clash-ai.sh              交互式配置：启动时逐项选择
#   bash setup-clash-ai.sh --dry-run    只生成并检查配置、预览各层节点，不改任何东西
#   bash setup-clash-ai.sh --verify     配好之后跑一遍验证清单
# 每个选项也可以用参数直接给出，给了就不再问，例如：
#   bash setup-clash-ai.sh --subscriptions all --ai-keywords ';GPT' --timezone Asia/Singapore --adblock off --dual-exit no --yes
# 其他参数：
#   --dns-keywords 关键词     「DNS 自动」用哪些节点（空 = 新加坡、日本、台湾的 1 倍节点）
#   --wired 网卡 --wifi 网卡 --gateway 地址     双出口时用
#   --clash-dir 目录          Clash Verge 配置目录不在默认位置时
#   --mihomo 路径             内核不在 /usr/bin/verge-mihomo 时
#   --skip-system             只改 Clash，不动时区、对时和网络设置
#
# 会改什么：Clash Verge 的 config.yaml / verge.yaml / profiles.yaml / 全局扩展覆写配置，新增「组合配置」；
# 系统时区与自动对时；选了双出口时再用 NetworkManager 关掉热点连接的 IPv6、调高它的跃点数。
# 改之前全部备份到 Clash Verge 配置目录下的 setup-backup-时间 目录。
# 不会做：禁用任何网卡、改订阅链接、替你选 AI 节点。

if [ -z "${BASH_VERSION:-}" ]; then echo "请用 bash 运行：bash $0" >&2; exit 1; fi
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then echo '需要 bash 4.3 或更新的版本' >&2; exit 1; fi
# bash 5.2 起替换文本里的 & 会被换成匹配到的内容，正则里可能有 &，关掉
shopt -u patsub_replacement 2>/dev/null || true
set -o pipefail

# ───────────── 参数 ─────────────
DRY_RUN=0 VERIFY=0 SKIP_SYSTEM=0 YES=0
SUBSCRIPTIONS='' AI_KEYWORDS='' TIMEZONE='' DNS_KEYWORDS='' ADBLOCK='' DUAL_EXIT=''
WIRED='' WIFI='' GATEWAY='' CLASH_DIR='' MIHOMO=''
SUBSCRIPTIONS_SET=0 AI_KEYWORDS_SET=0 DNS_KEYWORDS_SET=0

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; }

while (( $# )); do
    opt=$1 val='' has_val=0
    if [[ $opt == --*=* ]]; then val=${opt#*=}; opt=${opt%%=*}; has_val=1; fi
    case $opt in
        --dry-run) DRY_RUN=1 ;;
        --verify) VERIFY=1 ;;
        --skip-system) SKIP_SYSTEM=1 ;;
        -y|--yes) YES=1 ;;
        -h|--help) usage; exit 0 ;;
        --subscriptions|--ai-keywords|--timezone|--dns-keywords|--adblock|--dual-exit|--wired|--wifi|--gateway|--clash-dir|--mihomo)
            if (( ! has_val )); then
                (( $# >= 2 )) || { echo "参数 $opt 后面要跟一个值" >&2; exit 2; }
                val=$2; shift
            fi
            case $opt in
                --subscriptions) SUBSCRIPTIONS=$val SUBSCRIPTIONS_SET=1 ;;
                --ai-keywords) AI_KEYWORDS=$val AI_KEYWORDS_SET=1 ;;
                --timezone) TIMEZONE=$val ;;
                --dns-keywords) DNS_KEYWORDS=$val DNS_KEYWORDS_SET=1 ;;
                --adblock) ADBLOCK=$val ;;
                --dual-exit) DUAL_EXIT=$val ;;
                --wired) WIRED=$val ;;
                --wifi) WIFI=$val ;;
                --gateway) GATEWAY=$val ;;
                --clash-dir) CLASH_DIR=$val ;;
                --mihomo) MIHOMO=$val ;;
            esac ;;
        *) echo "不认识的参数：$1（用 --help 查看用法）" >&2; exit 2 ;;
    esac
    shift
done
[[ -z $ADBLOCK || $ADBLOCK == on || $ADBLOCK == off ]] || { echo '--adblock 只能是 on 或 off' >&2; exit 2; }
[[ -z $DUAL_EXIT || $DUAL_EXIT == yes || $DUAL_EXIT == no ]] || { echo '--dual-exit 只能是 yes 或 no' >&2; exit 2; }

VERGE_DIR=${CLASH_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/io.github.clash-verge-rev.clash-verge-rev}
PROFILE_NAME='组合配置'
PROFILE_MARKER='# 组合配置'

# 默认筛选规则（和 Windows 版、文档里的模板一致）
REGION_AI='新加坡|狮城|台湾|日本|韩国|美国|加拿大|英国|德国|法国|荷兰|澳大利亚|Singapore|Taiwan|Japan|Korea|United States|USA|Canada|United Kingdom|Germany|France|Netherlands|Australia'
BLOCK_AI='香港|澳门|中国|俄罗斯|伊朗|朝鲜|Hong Kong|HongKong|Macau|China|Russia'
DNS_DEFAULT='新加坡|狮城|日本|台湾|Singapore|Japan|Taiwan'
DNS_EXCLUDE='高倍|[2-9]x|[2-9]X|x[2-9]|香港|Hong Kong'
INFO_FILTER='剩余|到期|套餐|官网|客服|邮箱|重置|过期|支持AI|Traffic|Expire|Reset'

TZ_LABELS=(新加坡 台北 东京 首尔 美国西部 美国东部 伦敦 不改时区)
TZ_IDS=(Asia/Singapore Asia/Taipei Asia/Tokyo Asia/Seoul America/Los_Angeles America/New_York Europe/London skip)

# ───────────── 输出与提问 ─────────────
if [[ -t 1 ]]; then RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' CYAN=$'\e[36m' OFF=$'\e[0m'
else RED='' GREEN='' YELLOW='' CYAN='' OFF=''; fi
say() { if [[ -n ${2:-} ]]; then printf '%s%s%s\n' "$2" "$1" "$OFF"; else printf '%s\n' "$1"; fi; }
die() { say ''; say "出错：$1" "$RED"; exit 1; }
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }
unquote() { local s; s=$(trim "$1"); s=${s#\'}; s=${s%\'}; s=${s#\"}; s=${s%\"}; printf '%s' "$s"; }
join_by() { local sep=$1 out=''; shift; (( $# )) || return 0; out=$1; shift; local x; for x in "$@"; do out+=$sep$x; done; printf '%s' "$out"; }
count_lines() { grep -c ''; }

# 结果放在 REPLY_VAL；读不到输入（EOF）时返回 1 并用默认值
ask() {
    local a
    if [[ -n ${2:-} ]]; then read -r -p "$1 [$2] " a || { REPLY_VAL=${2:-}; return 1; }
    else read -r -p "$1 " a || { REPLY_VAL=''; return 1; }; fi
    a=$(trim "$a")
    REPLY_VAL=${a:-${2:-}}
}
# 问到输入合法为止：几个选项之一（y / n 当作 yes / no）
ask_choice() {
    local prompt=$1 def=$2 a c; shift 2
    while true; do
        ask "$prompt" "$def"; a=${REPLY_VAL,,}
        [[ $a == y ]] && a=yes; [[ $a == n ]] && a=no
        for c in "$@"; do [[ $a == "$c" ]] && { REPLY_VAL=$a; return 0; }; done
        say "  请输入 $(join_by ' / ' "$@")" "$YELLOW"
    done
}
# 问到输入合法为止：1 到 count 的序号，REPLY_VAL 是下标
ask_index() {
    while true; do
        ask "$1" "$3"
        if [[ $REPLY_VAL =~ ^[0-9]+$ ]] && (( 10#$REPLY_VAL >= 1 && 10#$REPLY_VAL <= $2 )); then REPLY_VAL=$(( 10#$REPLY_VAL - 1 )); return 0; fi
        say "  请输入 1 到 $2 之间的序号" "$YELLOW"
    done
}

# 节点筛选和内核一样区分大小写；有 PCRE 就用 PCRE（和内核的正则最接近）
if printf 'a\n' | grep -qP 'a' 2>/dev/null; then RE_FLAG=-P; else RE_FLAG=-E; fi
re_keep() { grep "$RE_FLAG" -- "$1"; }
re_drop() { grep -v "$RE_FLAG" -- "$1"; }
test_regex() { local rc=0; grep "$RE_FLAG" -- "$1" </dev/null >/dev/null 2>&1 || rc=$?; (( rc != 2 )); }
yq() { printf "'%s'" "${1//\'/\'\'}"; }
esc_re() { printf '%s' "$1" | sed 's/[][\\^$.|?*+(){}]/\\&/g'; }

# 按行读写文件（去掉 CR），配合下面两个改键的函数用
read_lines() { local -n _rl_arr=$1; local _rl_line; _rl_arr=(); while IFS= read -r _rl_line || [[ -n $_rl_line ]]; do _rl_arr+=("${_rl_line%$'\r'}"); done < "$2"; }
write_lines() { local -n _wl_arr=$2; printf '%s\n' "${_wl_arr[@]}" > "$1"; }
set_top_key() {
    local -n _tk_arr=$1; local k=$2 v=$3 i
    for i in "${!_tk_arr[@]}"; do [[ ${_tk_arr[i]} == "$k:"* ]] && { _tk_arr[i]="$k: $v"; return; }; done
    _tk_arr+=("$k: $v")
}
set_tun_key() {
    local -n _tn_arr=$1; local k=$2 v=$3 i t=-1
    for i in "${!_tn_arr[@]}"; do [[ ${_tn_arr[i]} == 'tun:' ]] && { t=$i; break; }; done
    if (( t < 0 )); then for i in "${!_tn_arr[@]}"; do [[ ${_tn_arr[i]} == 'tun: {}' ]] && { _tn_arr[i]='tun:'; t=$i; break; }; done; fi
    if (( t < 0 )); then _tn_arr+=('tun:'); t=$(( ${#_tn_arr[@]} - 1 )); fi
    for (( i = t + 1; i < ${#_tn_arr[@]}; i++ )); do
        [[ ${_tn_arr[i]} == [[:space:]]* ]] || break
        [[ ${_tn_arr[i]} == "  $k:"* ]] && { _tn_arr[i]="  $k: $v"; return; }
    done
    _tn_arr=("${_tn_arr[@]:0:t+1}" "  $k: $v" "${_tn_arr[@]:t+1}")
}

# ───────────── 订阅与节点 ─────────────
# 订阅列表：Clash Verge 的 profiles.yaml 里的条目（SUB_* 是同下标的几个数组）
read_subscriptions() {
    SUB_UID=() SUB_TYPE=() SUB_NAME=() SUB_FILE=()
    local l i=-1 re_uid='^- uid:[[:space:]]*([^[:space:]]+)' re_key='^  (type|name|file):[[:space:]]*(.*)$'
    while IFS= read -r l || [[ -n $l ]]; do
        l=${l%$'\r'}
        if [[ $l =~ $re_uid ]]; then
            i=$(( i + 1 )); SUB_UID[i]=${BASH_REMATCH[1]} SUB_TYPE[i]='' SUB_NAME[i]='' SUB_FILE[i]=''
        elif (( i >= 0 )) && [[ $l =~ $re_key ]]; then
            case ${BASH_REMATCH[1]} in
                type) SUB_TYPE[i]=$(unquote "${BASH_REMATCH[2]}") ;;
                name) SUB_NAME[i]=$(unquote "${BASH_REMATCH[2]}") ;;
                file) SUB_FILE[i]=$(unquote "${BASH_REMATCH[2]}") ;;
            esac
        fi
    done < "$VERGE_DIR/profiles.yaml"
}

# 订阅文件里的节点名，一行一个（只用来预览；真正的筛选由内核做）
# 认得两种常见写法：- {name: …, …} 和 - name: …（列表项可以顶格，name 也可以不是第一个键）
node_names() {
    local path=$VERGE_DIR/profiles/$1 l started=0 ind=-1 rest n re_key
    local re_start='^proxies:[[:space:]]*(#.*)?$' re_top='^[^[:space:]#-]' re_item='^([[:space:]]*)-[[:space:]]*(.*)$'
    local re_flow="^[{][[:space:]]*name:[[:space:]]*(\"[^\"]*\"|'[^']*'|[^,}]+)" re_block='^name:[[:space:]]*(.+)$'
    [[ -n $1 && -f $path ]] || return 0
    while IFS= read -r l || [[ -n $l ]]; do
        l=${l%$'\r'}
        if (( ! started )); then [[ $l =~ $re_start ]] && started=1; continue; fi
        [[ $l =~ $re_top ]] && break
        if [[ $l =~ $re_item ]]; then
            (( ind < 0 )) && ind=${#BASH_REMATCH[1]}
            (( ${#BASH_REMATCH[1]} == ind )) || continue
            rest=${BASH_REMATCH[2]}
            if [[ $rest =~ $re_flow ]] || [[ $rest =~ $re_block ]]; then n=${BASH_REMATCH[1]}; else continue; fi
        elif (( ind >= 0 )); then
            re_key="^ {$(( ind + 2 ))}name:[[:space:]]*(.+)$"
            [[ $l =~ $re_key ]] || continue
            n=${BASH_REMATCH[1]}
        else
            continue
        fi
        unquote "$n"; printf '\n'
    done < "$path" | re_drop "$INFO_FILTER"
}

# ───────────── 验证模式 ─────────────
dns_a() { # 先问外部 DNS（被 Clash 接管时应拿到假 IP）；没有 dig / nslookup 就用系统解析
    if command -v dig >/dev/null 2>&1; then dig +short +time=3 +tries=1 @223.5.5.5 "$1" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1
    elif command -v nslookup >/dev/null 2>&1; then nslookup "$1" 223.5.5.5 2>/dev/null | awk '/^Address: /{print $2}' | grep -E '^[0-9.]+$' | head -1
    else getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'; fi
}
verify() {
    local ok=0 bad=0 c a d n tun_if bind wired='' before=0 dev listen sent w
    mark() {
        local color
        case $1 in 通过) color=$GREEN; ok=$(( ok + 1 )) ;; 失败) color=$RED; bad=$(( bad + 1 )) ;; 跳过) color=$YELLOW ;; *) color=$CYAN ;; esac
        say "[$1] $2  $3" "$color"
    }
    trace() { curl -s -m 15 "$1" 2>/dev/null; }
    kv() { sed -n "s/^$1=//p" <<< "$2" | head -1; }
    # TUN 网卡：Clash 的 TUN 地址是 198.18.0.1（Linux 版默认不写设备名，所以按地址找）
    tun_if=$(ip -o -4 addr show 2>/dev/null | awk '{split($4, a, "/"); if (a[1] == "198.18.0.1") { print $2; exit }}')
    bind=$(sed -n 's/^interface-name:[[:space:]]*//p' "$VERGE_DIR/profiles/Merge.yaml" 2>/dev/null | head -1)
    bind=$(trim "$bind")
    say ''
    say "TUN：$([[ -n $tun_if ]] && echo "开（$tun_if）" || echo 关)；双出口：$([[ -n $bind ]] && echo "是（Clash 出站绑定 $bind）" || echo 否)" "$CYAN"
    if [[ -n $tun_if ]]; then
        if [[ -n $bind ]]; then
            for d in /sys/class/net/*; do
                n=${d##*/}
                [[ -e $d/device && $n != "$bind" && $(cat "$d/operstate" 2>/dev/null) == up ]] && { wired=$n; break; }
            done
        fi
        [[ -n $wired ]] && before=$(cat "/sys/class/net/$wired/statistics/tx_bytes")
        c=$(trace https://claude.ai/cdn-cgi/trace)
        if [[ -z $c ]]; then mark 失败 'Claude 走 AI 节点' '没有响应：AI 组是不是还停在「拒绝」？'
        elif [[ $(kv loc "$c") =~ ^(CN|HK|MO|RU|IR|KP)$ ]]; then mark 失败 'Claude 走 AI 节点' "出口 $(kv ip "$c") 在 $(kv loc "$c")，这个地区不支持 AI"
        else mark 通过 'Claude 走 AI 节点' "出口 $(kv ip "$c")，地区 $(kv loc "$c")"; fi
        c=$(trace https://www.cloudflare.com/cdn-cgi/trace)
        if [[ -n $c ]]; then mark 信息 '其他网站的出口' "$(kv ip "$c")，地区 $(kv loc "$c")（应是「其他」层所选节点）"; else mark 失败 '其他网站的出口' '没有响应'; fi
        c=$(curl -s -m 12 https://myip.ipip.net 2>/dev/null)
        if [[ -n $c ]]; then mark 信息 '国内网站直连' "$(trim "$c")"; else mark 失败 '国内网站直连' '没有响应'; fi
        a=$(dns_a claude.ai)
        if [[ $a == 198.18.* ]]; then mark 通过 'DNS 被 Clash 接管' "查询拿到假 IP $a"; else mark 失败 'DNS 被 Clash 接管' "拿到的是 ${a:-（没有结果）}"; fi
        if command -v dig >/dev/null 2>&1; then
            w=$(dig +short TXT whoami.ds.akahelp.net 2>/dev/null | tr -d '"' | grep '^ecs' | tr '\n' ' ')
            if [[ -n $w ]]; then mark 信息 'Clash 自己的境外查询出口' "$w"; else mark 跳过 'Clash 自己的境外查询出口' '查询没有返回'; fi
        else
            mark 跳过 'Clash 自己的境外查询出口' '没装 dig（dnsutils / bind-utils）'
        fi
        if [[ -n $wired ]]; then
            sent=$(( $(cat "/sys/class/net/$wired/statistics/tx_bytes") - before ))
            if (( sent < 65536 )); then mark 通过 "有线（$wired）基本不发数据" "测试期间只发出 $(( sent / 1024 )) KB"
            else mark 失败 "有线（$wired）基本不发数据" "测试期间发出 $(( sent / 1024 )) KB"; fi
        fi
    else
        mark 跳过 'Claude / DNS 相关检查' 'TUN 关着时这些请求会直连出去，所以不测；打开 TUN 后再运行一次 --verify'
        c=$(trace https://www.cloudflare.com/cdn-cgi/trace)
        [[ -n $c ]] && mark 信息 'TUN 关时的出口' "$(kv ip "$c")，地区 $(kv loc "$c")（应是本地网络）"
        if [[ -n $bind ]]; then
            dev=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
            if [[ -n $dev && $dev != "$bind" ]]; then mark 通过 'TUN 关时走网线' "系统选 $dev"; else mark 失败 'TUN 关时走网线' "系统选 ${dev:-（没有路由）}"; fi
        fi
    fi
    listen=$(ss -H -lun 2>/dev/null | awk '{print $4}' | grep -E ':1053$')
    if [[ -z $listen ]]; then mark 跳过 'DNS 只监听本机' 'Clash 没在运行'
    elif ! grep -vqE '^127\.0\.0\.1:1053$' <<< "$listen"; then mark 通过 'DNS 只监听本机' '只有 127.0.0.1:1053'
    else mark 失败 'DNS 只监听本机' "$(tr '\n' ' ' <<< "$listen")"; fi
    say ''
    say "通过 $ok 项，失败 $bad 项。失效保护需要手动测：AI 组临时选「拒绝」，claude.ai 应该打不开。" "$( (( bad )) && echo "$RED" || echo "$GREEN")"
    (( bad == 0 ))
}

# ───────────── 组合配置模板（和 Windows 版逐行一致，只有第一行注释不同） ─────────────
TEMPLATE=$(cat <<'YAML'
# 组合配置（由 setup-clash-ai.sh 生成）：订阅只当节点来源；三层 DNS / AI / 其他 各选各的节点。
# 端口和 TUN 由 Clash Verge 的基础设置提供，这里不写。

mode: rule
ipv6: false
unified-delay: true
profile:
  store-selected: true
  store-fake-ip: true

proxy-providers:
{{PROVIDERS}}
proxy-groups:
  # AI 层：第一项是「拒绝」，没选过或选中的节点消失时直接断开，不会悄悄换出口。
  - name: AI
    type: select
    proxies: [REJECT]
    use: {{USE}}
    filter: {{AI_FILTER}}
    exclude-filter: {{AI_EXCLUDE}}
  - name: 其他
    type: select
    use: {{USE}}
  # DNS 层：Clash 自己查境外域名时从这里出去。第一项在几个稳定节点间自动切换；没有直连选项。
  - name: DNS
    type: select
    proxies: ['DNS 自动']
    use: {{USE}}
  - name: 'DNS 自动'
    type: fallback
    use: {{USE}}
    filter: {{DNS_FILTER}}
    exclude-filter: {{DNS_EXCLUDE}}
    url: 'https://www.gstatic.com/generate_204'
    interval: 600
  # 广告开关：PASS = 关闭（继续往下匹配），REJECT = 开启。
  - name: 广告拦截
    type: select
    proxies: {{AD_PROXIES}}

rule-providers:
  ai-inline:
    type: inline
    behavior: classical
    payload:
      # Net.Coffee「Claude Code 域名分流规则大全」
      - DOMAIN-SUFFIX,anthropic.com
      - DOMAIN-SUFFIX,claude.ai
      - DOMAIN-SUFFIX,claude.com
      - DOMAIN-SUFFIX,clau.de
      - DOMAIN-SUFFIX,claudemcpclient.com
      - DOMAIN-SUFFIX,claudemcpcontent.com
      - DOMAIN-SUFFIX,claudeusercontent.com
      - DOMAIN,servd-anthropic-website.b-cdn.net
      - DOMAIN,anthropic.com.cdn.cloudflare.net
      - DOMAIN,anthropic.auth0.com
      - DOMAIN,anthropic-com.ghost.io
      - DOMAIN-SUFFIX,sentry.io
      - DOMAIN-SUFFIX,statsigapi.net
      - DOMAIN,browser-intake-us5-datadoghq.com
      - DOMAIN-KEYWORD,datadog
      - DOMAIN-KEYWORD,sift
      - DOMAIN-SUFFIX,intercom.io
      - DOMAIN-SUFFIX,intercomcdn.com
      - DOMAIN,cdn.usefathom.com
      # 功能开关
      - DOMAIN,api.statsig.com
      - DOMAIN-SUFFIX,featuregates.org
      # AI 登录和验证码（多家 AI 共用，和 AI 页面同一个出口，验证才不会因 IP 不一致失败）
      - DOMAIN,accounts.google.com
      - DOMAIN,challenges.cloudflare.com
      - DOMAIN-SUFFIX,recaptcha.net
      - DOMAIN,recaptchaenterprise.googleapis.com
      - DOMAIN-SUFFIX,hcaptcha.com
      - DOMAIN-SUFFIX,arkoselabs.com
      - DOMAIN-SUFFIX,funcaptcha.com
      - DOMAIN,appleid.apple.com
      - DOMAIN-SUFFIX,stripe.com
      - DOMAIN-SUFFIX,stripe.network
      # 上游 AI 列表没收的
      - DOMAIN-SUFFIX,character.ai
      - DOMAIN-SUFFIX,characterai.io
      - DOMAIN-SUFFIX,suno.com
      - DOMAIN-SUFFIX,suno.ai
      - DOMAIN,sydney.bing.com
      - DOMAIN,edgeservices.bing.com
      # 你自己要加进 AI 层的域名写在这里（DNS 也会自动跟着走 AI 层）
  ai-exclude:
    type: inline
    behavior: domain
    payload:
      # 上游 AI 列表里收得太宽的：LivePerson（很多网站的客服插件）、Envato（素材站全站）
      - '+.liveperson.net'
      - '+.lpsnmedia.net'
      - '+.envato.com'
      - '+.envato-static.com'
      - '+.envatousercontent.com'
      - '+.themeforest.net'
  ai-list:
    type: http
    behavior: domain
    format: yaml
    url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/category-ai-!cn.yaml'
    path: ./ruleset/meta-ai-noncn.yaml
    interval: 86400
    proxy: 其他
  loyal-private:
    type: http
    behavior: domain
    format: yaml
    url: 'https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/private.txt'
    path: ./ruleset/loyal-private.yaml
    interval: 86400
    proxy: 其他
  loyal-reject:
    type: http
    behavior: domain
    format: yaml
    url: 'https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/reject.txt'
    path: ./ruleset/loyal-reject.yaml
    interval: 86400
    proxy: 其他
  loyal-proxy:
    type: http
    behavior: domain
    format: yaml
    url: 'https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/proxy.txt'
    path: ./ruleset/loyal-proxy.yaml
    interval: 86400
    proxy: 其他
  loyal-direct:
    type: http
    behavior: domain
    format: yaml
    url: 'https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/direct.txt'
    path: ./ruleset/loyal-direct.yaml
    interval: 86400
    proxy: 其他
  loyal-lancidr:
    type: http
    behavior: ipcidr
    format: yaml
    url: 'https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/lancidr.txt'
    path: ./ruleset/loyal-lancidr.yaml
    interval: 86400
    proxy: 其他
  loyal-cncidr:
    type: http
    behavior: ipcidr
    format: yaml
    url: 'https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/cncidr.txt'
    path: ./ruleset/loyal-cncidr.yaml
    interval: 86400
    proxy: 其他
  loyal-telegramcidr:
    type: http
    behavior: ipcidr
    format: yaml
    url: 'https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/telegramcidr.txt'
    path: ./ruleset/loyal-telegramcidr.yaml
    interval: 86400
    proxy: 其他

rules:
  # HTTP/3（QUIC）一律拒绝，浏览器会立刻改用普通 HTTPS：出口更一致，域名识别更准。
  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
  # AI 层：自己写的 Claude 清单最先匹配，不依赖上游。
  - RULE-SET,ai-inline,AI
  - GEOSITE,anthropic,AI
  # 上游 AI 列表里收得太宽的两家送去「其他」，其余进 AI 层。
  - RULE-SET,ai-exclude,其他
  - RULE-SET,ai-list,AI
  # Anthropic 的 IP 段兜底：域名规则失效时的最后一道防线。
  - IP-CIDR,160.79.104.0/21,AI,no-resolve
  - IP-CIDR6,2607:6bc0::/32,AI,no-resolve
  - IP-ASN,399358,AI,no-resolve
  # 通用规则：Loyalsoldier。
  - RULE-SET,loyal-private,DIRECT
  - RULE-SET,loyal-reject,广告拦截
  - RULE-SET,loyal-proxy,其他
  - RULE-SET,loyal-direct,DIRECT
  - RULE-SET,loyal-lancidr,DIRECT,no-resolve
  - RULE-SET,loyal-telegramcidr,其他,no-resolve
  - RULE-SET,loyal-cncidr,DIRECT
  - MATCH,其他

dns:
  enable: true
  listen: 127.0.0.1:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter-mode: blacklist
  fake-ip-filter:
    # 只放必须拿到真实地址的域名；某个程序在 TUN 下出问题时，再把它的域名加到这里。
    # 局域网和保留域名
    - '*.lan'
    - '*.local'
    - '*.localdomain'
    - '*.home.arpa'
    - '*.localhost'
    - '*.test'
    - '*.example'
    - '*.invalid'
    # 对时：对时程序会缓存地址，拿到假 IP 容易对时失败
    - '+.pool.ntp.org'
    - 'time.*.com'
    - 'time.*.gov'
    - 'time.*.edu.cn'
    - 'time.*.apple.com'
    - 'time1.*.com'
    - 'time2.*.com'
    - 'time3.*.com'
    - 'time4.*.com'
    - 'time5.*.com'
    - 'time6.*.com'
    - 'time7.*.com'
    - 'ntp.*.com'
    - 'ntp1.*.com'
    - 'ntp2.*.com'
    - 'ntp3.*.com'
    - 'ntp4.*.com'
    - 'ntp5.*.com'
    - 'ntp6.*.com'
    - 'ntp7.*.com'
    - '*.time.edu.cn'
    - '*.ntp.org.cn'
    - 'time1.cloud.tencent.com'
    # Windows 联网检测：拿到假 IP 会让任务栏显示「无 Internet」
    - '*.msftconnecttest.com'
    - '*.msftncsi.com'
    # STUN：网页通话、P2P 穿透要用真实地址
    - 'stun.*.*'
    - 'stun.*.*.*'
    # QQ 快捷登录：必须解析到 127.0.0.1
    - 'localhost.ptlogin2.qq.com'
  use-hosts: true
  respect-rules: false
  prefer-h3: false
  default-nameserver: [223.5.5.5, 119.29.29.29]
  # 固定例外：代理节点自身的地址，直连国内加密 DNS（阿里 + 腾讯）。
  proxy-server-nameserver: ['https://223.5.5.5/dns-query', 'https://1.12.12.12/dns-query']
  direct-nameserver: ['https://223.5.5.5/dns-query', 'https://1.12.12.12/dns-query']
  direct-nameserver-follow-policy: true
  # 其余所有域名：经 DNS 层节点查境外 DoH。
  nameserver: ['https://1.1.1.1/dns-query#DNS', 'https://8.8.8.8/dns-query#DNS']
  nameserver-policy:
    'rule-set:ai-exclude': ['https://1.1.1.1/dns-query#DNS', 'https://8.8.8.8/dns-query#DNS']
    # 1. AI 清单 + 你自己加的域名 → AI 层节点
    'rule-set:ai-inline': ['https://1.1.1.1/dns-query#AI', 'https://8.8.8.8/dns-query#AI']
    'geosite:anthropic': ['https://1.1.1.1/dns-query#AI', 'https://8.8.8.8/dns-query#AI']
    'rule-set:ai-list': ['https://1.1.1.1/dns-query#AI', 'https://8.8.8.8/dns-query#AI']
    # 2. 局域网、私有域名
    'rule-set:loyal-private': [{{PRIVATE_DNS}}]
    # 3. 国内域名 → 国内加密 DNS 直连
    'rule-set:loyal-direct': ['https://223.5.5.5/dns-query', 'https://1.12.12.12/dns-query']

sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  override-destination: true
  sniff:
    HTTP:
      ports: [80, '8080-8880']
    TLS:
      ports: [443, 8443, 9443]
    QUIC:
      ports: [443]
  skip-domain:
    - +.apple.co
    - Mijia Cloud
    - dlg.io.mi.com
    - +.oray.com
    - +.sunlogin.net
    - +.push.apple.com
YAML
)

RULE_FILES=(meta-ai-noncn.yaml)
RULE_RAW=('https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/category-ai-!cn.yaml')
RULE_CDN=('https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/category-ai-!cn.yaml')
for n in private reject proxy direct lancidr cncidr telegramcidr; do
    RULE_FILES+=("loyal-$n.yaml")
    RULE_RAW+=("https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/$n.txt")
    RULE_CDN+=("https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/$n.txt")
done

# ───────────── 系统设置（需要 root） ─────────────
current_timezone() { timedatectl show -p Timezone --value 2>/dev/null || readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##'; }
route_metric() { ip -4 route show default dev "$1" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "metric") { print $(i + 1); exit }}'; }
NTP_DROPIN=/etc/systemd/timesyncd.conf.d/50-clash-ai.conf
NTP_SET=0

set_timezone() {
    [[ $TIMEZONE == skip ]] && return 0
    if [[ -d /run/systemd/system ]] && command -v timedatectl >/dev/null 2>&1; then
        "${SUDO[@]}" timedatectl set-timezone "$TIMEZONE"
    else
        "${SUDO[@]}" ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime &&
            { [[ ! -f /etc/timezone ]] || printf '%s\n' "$TIMEZONE" | "${SUDO[@]}" tee /etc/timezone >/dev/null; }
    fi && say "时区已设为 $TIMEZONE" || say "时区没设好，可以之后手动运行 sudo timedatectl set-timezone $TIMEZONE" "$YELLOW"
}
set_ntp() {
    if systemctl cat systemd-timesyncd.service >/dev/null 2>&1; then
        if "${SUDO[@]}" mkdir -p "${NTP_DROPIN%/*}" &&
            printf '# 由 setup-clash-ai.sh 生成：直连国内 NTP；对时只返回 UTC 时间，不会暴露时区\n[Time]\nNTP=ntp.aliyun.com time.windows.com\n' | "${SUDO[@]}" tee "$NTP_DROPIN" >/dev/null; then
            NTP_SET=1
            "${SUDO[@]}" timedatectl set-ntp true >/dev/null 2>&1
            "${SUDO[@]}" systemctl restart systemd-timesyncd >/dev/null 2>&1
            # 服务带启动条件（比如在 WSL、容器里不跑），restart 成功不代表它真的起来了
            if systemctl is-active --quiet systemd-timesyncd; then
                say '已开启自动对时（systemd-timesyncd：阿里云、微软 NTP）'
            else
                say '对时服务 systemd-timesyncd 没有跑起来：WSL、容器里由宿主机对时，可以不管；其他情况运行 systemctl status systemd-timesyncd 查原因。' "$YELLOW"
            fi
        else
            say '自动对时没设好，可以之后手动运行 sudo timedatectl set-ntp true' "$YELLOW"
        fi
    elif systemctl is-active --quiet chronyd 2>/dev/null || systemctl is-active --quiet chrony 2>/dev/null; then
        "${SUDO[@]}" timedatectl set-ntp true >/dev/null 2>&1
        say '检测到 chrony，自动对时已开着；想换成阿里云 NTP，在 chrony 的配置里加一行 server ntp.aliyun.com iburst。' "$YELLOW"
    else
        say '没找到 systemd-timesyncd 或 chrony，跳过自动对时。' "$YELLOW"
    fi
}
# 双出口：只动热点那条连接（关 IPv6、跃点数调到 600），不碰网线
set_dual_exit_network() {
    local conn mw mf
    if ! command -v nmcli >/dev/null 2>&1; then
        say "没有 NetworkManager（nmcli），双出口的网络设置要手动做：关掉「$WIFI」的 IPv6，并让「$WIRED」默认路由的跃点数比它小。" "$YELLOW"
        return 0
    fi
    conn=$(nmcli -g GENERAL.CONNECTION device show "$WIFI" 2>/dev/null)
    if [[ -z $conn || $conn == -- ]]; then
        say "「$WIFI」现在没有连接：连上热点后再运行一次脚本，才能改它的 IPv6 和跃点数。" "$YELLOW"
        return 0
    fi
    if { "${SUDO[@]}" nmcli connection modify "$conn" ipv6.method disabled 2>/dev/null || "${SUDO[@]}" nmcli connection modify "$conn" ipv6.method ignore; } &&
        "${SUDO[@]}" nmcli connection modify "$conn" ipv4.route-metric 600; then
        "${SUDO[@]}" nmcli device reapply "$WIFI" >/dev/null 2>&1 || say "  改动要等「$WIFI」重新连接后生效" "$YELLOW"
        say "双出口：热点连接「$conn」已关闭 IPv6，默认路由跃点数设为 600"
    else
        say "没改成热点连接「$conn」的设置，请在网络设置里手动关掉它的 IPv6" "$YELLOW"
    fi
    mw=$(route_metric "$WIRED"); mf=$(route_metric "$WIFI")
    if [[ -n $mw && -n $mf ]] && (( mw >= mf )); then
        say "注意：「$WIRED」默认路由的跃点数（$mw）不比「$WIFI」（$mf）小，TUN 关时可能走热点。" "$YELLOW"
    fi
}

# ───────────── 主流程 ─────────────
choose_subscriptions() {
    local spec tok n i j m dup msg toks chosen unknown uniq
    while true; do
        spec=$SUBSCRIPTIONS
        if [[ -z $spec ]]; then ask '要用哪些订阅？输入序号或名字，用逗号分开；同一订阅的多个副本只选一个' 'all'; spec=$REPLY_VAL; fi
        chosen=() unknown=()
        if [[ $spec == all ]]; then
            chosen=("${REMOTE[@]}")
        else
            IFS=',' read -r -a toks <<< "${spec//，/,}"
            for tok in "${toks[@]}"; do
                tok=$(trim "$tok"); [[ -z $tok ]] && continue
                if [[ $tok =~ ^[0-9]+$ ]]; then
                    n=$(( 10#$tok ))
                    if (( n >= 1 && n <= ${#REMOTE[@]} )); then chosen+=("${REMOTE[n - 1]}"); else unknown+=("$tok"); fi
                else
                    m=0; for i in "${REMOTE[@]}"; do [[ ${SUB_NAME[i]} == "$tok" ]] && { chosen+=("$i"); m=1; }; done
                    (( m )) || unknown+=("$tok")
                fi
            done
        fi
        uniq=()
        for i in "${chosen[@]}"; do dup=0; for j in "${uniq[@]}"; do [[ $i == "$j" ]] && dup=1; done; (( dup )) || uniq+=("$i"); done
        CHOSEN=("${uniq[@]}")
        (( ${#unknown[@]} == 0 && ${#CHOSEN[@]} > 0 )) && return 0
        if (( ${#unknown[@]} )); then msg="没有这些订阅：$(join_by '、' "${unknown[@]}")"; else msg='没有选中任何订阅。'; fi
        (( SUBSCRIPTIONS_SET )) && die "$msg"
        say "  $msg" "$YELLOW"; SUBSCRIPTIONS=''
    done
}

main() {
    local i j p k n base kw pattern names nodes dns_count gs first existing uid file cur items_at insert_at
    if (( EUID == 0 )) && [[ -z $CLASH_DIR ]]; then
        die '请用普通用户运行，不要加 sudo：配置在你自己的用户目录里，需要 root 的步骤脚本会自己调用 sudo。'
    fi
    [[ -f $VERGE_DIR/profiles.yaml ]] || die "找不到 Clash Verge 的配置目录 $VERGE_DIR。请先安装 Clash Verge Rev 并至少打开一次。"
    if (( VERIFY )); then verify; exit $?; fi

    say '=== Clash Verge 分流配置：安全连接 AI、合理分流、安全连接代理 ===' "$CYAN"
    (( DRY_RUN )) && say '（演练模式：只生成并检查配置，不改任何东西）' "$YELLOW"

    # 1. 选订阅
    read_subscriptions
    REMOTE=(); for i in "${!SUB_UID[@]}"; do [[ ${SUB_TYPE[i]} == remote ]] && REMOTE+=("$i"); done
    (( ${#REMOTE[@]} )) || die '订阅页里还没有订阅：先在 Clash Verge 的「订阅」页导入至少一个订阅链接。'
    say ''
    say '已导入的订阅：'
    for p in "${!REMOTE[@]}"; do i=${REMOTE[p]}; say "  $(( p + 1 )). ${SUB_NAME[i]}（$(node_names "${SUB_FILE[i]}" | count_lines) 个节点）"; done
    choose_subscriptions
    # 节点来源的名字（也是节点名前缀）不能重名：重名的加序号
    KEYS=()
    for i in "${CHOSEN[@]}"; do
        k=${SUB_NAME[i]}; [[ -z $k || $k == null ]] && k=${SUB_UID[i]}
        base=$k j=2
        while [[ " ${KEYS[*]/%/$'\x1f'}" == *" $k"$'\x1f'* ]]; do k="$base $j"; j=$(( j + 1 )); done
        KEYS+=("$k")
    done

    # 2. 每个订阅里怎么认出能用 AI 的节点
    say ''
    say 'AI 层只放能用 AI 的节点。机场注明了哪些节点能用 AI（比如名字带 GPT，或只有某几个地区）时，输入关键词，多个用 | 隔开；直接回车 = 按支持 AI 的地区筛。'
    local -a kw_list=() ai_parts=()
    (( AI_KEYWORDS_SET )) && IFS=';' read -r -a kw_list <<< "$AI_KEYWORDS"
    local any_ai=0
    for p in "${!CHOSEN[@]}"; do
        i=${CHOSEN[p]}
        while true; do
            if (( AI_KEYWORDS_SET )); then kw=$(trim "${kw_list[p]:-}"); else ask "订阅「${SUB_NAME[i]}」的 AI 节点关键词（区分大小写）" ''; kw=$REPLY_VAL; fi
            test_regex "$kw" && break
            (( AI_KEYWORDS_SET )) && die "AI 节点关键词「$kw」不是有效的正则表达式。"
            say "  「$kw」不是有效的正则表达式，请重新输入" "$YELLOW"
        done
        pattern=${kw:-$REGION_AI}
        ai_parts+=("^$(esc_re "[${KEYS[p]}] ").*($pattern)")
        mapfile -t nodes < <(node_names "${SUB_FILE[i]}" | re_keep "$pattern" | re_drop "$BLOCK_AI")
        if (( ${#nodes[@]} == 0 )); then say "  ！订阅「${SUB_NAME[i]}」没有节点能进 AI 层，检查关键词" "$YELLOW"
        else any_ai=1; say "  「${SUB_NAME[i]}」能进 AI 层的 ${#nodes[@]} 个节点：$(join_by '、' "${nodes[@]}")"; fi
    done
    (( any_ai )) || die 'AI 层一个节点都没有，请换关键词重新运行。'

    # 3. 时区
    if [[ -z $TIMEZONE ]]; then
        say ''
        say '时区要和 AI 节点所在地一致（网站会看到系统时区）：'
        for i in "${!TZ_IDS[@]}"; do say "  $(( i + 1 )). ${TZ_LABELS[i]}"; done
        ask_index '选哪个？' "${#TZ_IDS[@]}" 1; TIMEZONE=${TZ_IDS[REPLY_VAL]}
    fi
    if [[ $TIMEZONE != skip && ( $TIMEZONE == *..* || ! -f /usr/share/zoneinfo/$TIMEZONE ) ]]; then
        die "没有这个时区：$TIMEZONE（用 timedatectl list-timezones 查，或填 skip）"
    fi

    # 4. DNS 自动用的节点
    if (( ! DNS_KEYWORDS_SET )); then
        while true; do
            ask '「DNS 自动」在哪些节点之间切换？输入关键词（区分大小写），直接回车 = 新加坡、日本、台湾的 1 倍节点' ''
            DNS_KEYWORDS=$REPLY_VAL
            test_regex "$DNS_KEYWORDS" && break
            say "  「$DNS_KEYWORDS」不是有效的正则表达式，请重新输入" "$YELLOW"
        done
    elif ! test_regex "$DNS_KEYWORDS"; then
        die "「DNS 自动」的关键词「$DNS_KEYWORDS」不是有效的正则表达式。"
    fi
    local dns_pattern=${DNS_KEYWORDS:-$DNS_DEFAULT}
    dns_count=0
    for i in "${CHOSEN[@]}"; do dns_count=$(( dns_count + $(node_names "${SUB_FILE[i]}" | re_keep "$dns_pattern" | re_drop "$DNS_EXCLUDE" | count_lines) )); done
    (( dns_count )) || die '「DNS 自动」一个节点都没有，请换关键词重新运行。'
    say "  「DNS 自动」会在 $dns_count 个节点之间切换"

    # 5. 广告拦截默认开不开
    [[ -n $ADBLOCK ]] || { ask_choice '广告拦截默认开吗？on / off' off on off; ADBLOCK=$REPLY_VAL; }

    # 6. 双出口
    if [[ -z $DUAL_EXIT ]]; then
        say ''
        say '双出口：电脑同时有网线和手机热点，希望开 TUN 时一切走热点、关 TUN 时一切走网线。没有这种情况就选 no。'
        ask_choice '要双出口吗？yes / no' no yes no; DUAL_EXIT=$REPLY_VAL
    fi
    if [[ $DUAL_EXIT == yes ]]; then
        local -a nics=(); local d def_wired=0 def_wifi=0 kind
        for d in /sys/class/net/*; do [[ -e $d/device ]] && nics+=("${d##*/}"); done
        if [[ -z $WIRED || -z $WIFI ]]; then
            (( ${#nics[@]} >= 2 )) || die "双出口需要两块物理网卡（网线 + Wi-Fi），这台电脑只找到 ${#nics[@]} 块。"
            say '物理网卡：'
            for i in "${!nics[@]}"; do
                if [[ -d /sys/class/net/${nics[i]}/wireless || -e /sys/class/net/${nics[i]}/phy80211 ]]; then
                    kind=无线; (( def_wifi )) || def_wifi=$(( i + 1 ))
                else
                    kind=有线; (( def_wired )) || def_wired=$(( i + 1 ))
                fi
                say "  $(( i + 1 )). ${nics[i]}（$kind，$(cat "/sys/class/net/${nics[i]}/operstate" 2>/dev/null)）"
            done
            (( def_wired )) || def_wired=1; (( def_wifi )) || def_wifi=2
            [[ -n $WIRED ]] || { ask_index '哪块是网线（有线）？' "${#nics[@]}" "$def_wired"; WIRED=${nics[REPLY_VAL]}; }
            [[ -n $WIFI ]] || { ask_index '哪块连手机热点（Wi-Fi）？' "${#nics[@]}" "$def_wifi"; WIFI=${nics[REPLY_VAL]}; }
        fi
        [[ -e /sys/class/net/$WIRED && -e /sys/class/net/$WIFI ]] || die "找不到网卡「$WIRED」或「$WIFI」。"
        [[ $WIRED != "$WIFI" ]] || die '网线和热点不能是同一块网卡。'
        if [[ -z $GATEWAY ]]; then
            local gw; gw=$(ip -4 route show default dev "$WIFI" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit }}')
            if [[ -n $gw ]]; then ask '热点的网关地址（从热点网卡读到的，回车确认）' "$gw"
            else ask "没读到「$WIFI」的网关。先连上热点，运行 ip route，把「default via」后面的地址填在这里" ''; fi
            GATEWAY=$REPLY_VAL
        fi
        local re_ip='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
        [[ $GATEWAY =~ $re_ip ]] || die "热点网关「$GATEWAY」不是 IPv4 地址。"
    fi

    # 汇总
    names=(); for i in "${CHOSEN[@]}"; do names+=("${SUB_NAME[i]}"); done
    say ''
    say '=== 将要做的事 ===' "$CYAN"
    say "  订阅：$(join_by '、' "${names[@]}")"
    say "  时区：$TIMEZONE；广告拦截默认：$ADBLOCK；双出口：$([[ $DUAL_EXIT == yes ]] && echo "是（网线 $WIRED，热点 $WIFI，网关 $GATEWAY）" || echo 否)"
    if (( ! DRY_RUN && ! YES )); then
        say '  执行时需要先退出 Clash Verge；退出期间 TUN 会断开，所有流量（包括 AI）都会直连。' "$YELLOW"
        ask_choice '确认开始？y / n' y yes no
        [[ $REPLY_VAL == yes ]] || { say '已取消，什么都没改。'; exit 0; }
    fi

    # 生成组合配置
    local prov='' block use private_dns ad_proxies profile
    local -a quoted=()
    for p in "${!CHOSEN[@]}"; do
        i=${CHOSEN[p]} k=${KEYS[p]}
        printf -v block "  %s:\n    type: file\n    path: %s\n    interval: 3600\n    exclude-filter: %s\n    exclude-type: 'direct'\n    override:\n      additional-prefix: %s\n" \
            "$(yq "$k")" "$(yq "./profiles/${SUB_FILE[i]}")" "$(yq "$INFO_FILTER")" "$(yq "[$k] ")"
        prov+=$block
        quoted+=("$(yq "$k")")
    done
    use="[$(join_by ', ' "${quoted[@]}")]"
    if [[ $DUAL_EXIT == yes ]]; then private_dns=$(yq "$GATEWAY"); else private_dns="'system'"; fi
    if [[ $ADBLOCK == on ]]; then ad_proxies='[REJECT, PASS]'; else ad_proxies='[PASS, REJECT]'; fi
    profile=$TEMPLATE
    profile=${profile//'{{PROVIDERS}}'/$prov}
    profile=${profile//'{{USE}}'/$use}
    profile=${profile//'{{AI_FILTER}}'/$(yq "$(join_by '|' "${ai_parts[@]}")")}
    profile=${profile//'{{AI_EXCLUDE}}'/$(yq "$BLOCK_AI")}
    profile=${profile//'{{DNS_FILTER}}'/$(yq "$dns_pattern")}
    profile=${profile//'{{DNS_EXCLUDE}}'/$(yq "$DNS_EXCLUDE")}
    profile=${profile//'{{AD_PROXIES}}'/$ad_proxies}
    profile=${profile//'{{PRIVATE_DNS}}'/$private_dns}

    # 用内核检查生成的配置
    local mihomo='' check out
    if [[ -n $MIHOMO ]]; then
        [[ -x $MIHOMO ]] || die "--mihomo 指定的「$MIHOMO」不能执行。"
        mihomo=$MIHOMO
    else
        for k in "$(command -v verge-mihomo 2>/dev/null)" /usr/bin/verge-mihomo /usr/lib/clash-verge/verge-mihomo; do
            [[ -n $k && -x $k ]] && { mihomo=$k; break; }
        done
    fi
    check=$(mktemp "${TMPDIR:-/tmp}/combined-profile.XXXXXX") || die '建不了临时文件。'
    printf '%s\n' "$profile" > "$check"
    if [[ -n $mihomo ]]; then
        out=$("$mihomo" -t -d "$VERGE_DIR" -f "$check" 2>&1)
        [[ $out == *'test is successful'* ]] || { rm -f "$check"; die "内核检查没通过，什么都没改："$'\n'"$out"; }
        say '内核检查通过。' "$GREEN"
    else
        say '没找到 verge-mihomo，跳过内核检查（内核不在 /usr/bin 时用 --mihomo 指定）。' "$YELLOW"
    fi

    if (( DRY_RUN )); then
        local preview="${TMPDIR:-/tmp}/Combined-Profile.preview.yaml"
        mv -f "$check" "$preview"
        say "演练结束，生成的配置在 $preview，什么都没改。" "$GREEN"
        exit 0
    fi
    rm -f "$check"

    # 等 Clash Verge 退出（指定了别的配置目录时，改的不是正在运行的那份，不用等）
    if [[ -z $CLASH_DIR ]]; then
        while pgrep -x clash-verge >/dev/null 2>&1; do
            (( YES )) && die 'Clash Verge 还在运行：请先从托盘图标退出它。'
            ask '请从托盘图标退出 Clash Verge，然后按回车' '' || die 'Clash Verge 还在运行：请先从托盘图标退出它。'
        done
    fi

    # 动手前先确认 config.yaml 的格式脚本认得，免得改到一半才失败
    if grep -Eq '^tun:[[:space:]]*[{][[:space:]]*[^}[:space:]]' "$VERGE_DIR/config.yaml" 2>/dev/null; then
        die 'config.yaml 里的 tun 是单行写法，脚本没法安全修改：先在 Clash Verge 的 TUN 设置里改一项再改回来（让它重新保存），然后重新运行。什么都没改。'
    fi

    # 需要 root 的步骤先拿到 sudo，拿不到就什么都不改
    SUDO=()
    if (( ! SKIP_SYSTEM && EUID != 0 )); then
        command -v sudo >/dev/null 2>&1 || die '改时区和对时需要 sudo；只想改 Clash 就加 --skip-system。什么都没改。'
        say '改时区、对时（和双出口的网络设置）需要 root 权限，下面可能要你输入密码。'
        sudo -v || die '没拿到 sudo 权限，什么都没改。只想改 Clash 就加 --skip-system。'
        SUDO=(sudo)
    fi

    # 备份：放在 Clash Verge 配置目录里（profiles.yaml 含订阅链接，留在原来的位置，不散到别处）
    local backup; backup="$VERGE_DIR/setup-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup/profiles" || die "建不了备份目录 $backup，什么都没改。"
    for k in config.yaml verge.yaml profiles.yaml; do
        [[ -f $VERGE_DIR/$k ]] && { cp -p "$VERGE_DIR/$k" "$backup/" || die "备份 $k 失败，什么都没改。"; }
    done
    [[ -f $VERGE_DIR/profiles/Merge.yaml ]] && { cp -p "$VERGE_DIR/profiles/Merge.yaml" "$backup/profiles/" || die '备份 Merge.yaml 失败，什么都没改。'; }
    {
        echo "# 时区"; current_timezone
        echo "# 网卡地址"; ip -o addr show 2>/dev/null
        echo "# 路由"; ip route show 2>/dev/null; ip -6 route show 2>/dev/null
        if command -v nmcli >/dev/null 2>&1; then
            echo "# NetworkManager 正在用的连接"; nmcli -t -f NAME,DEVICE,TYPE connection show --active 2>/dev/null
            [[ -n $WIFI ]] && { k=$(nmcli -g GENERAL.CONNECTION device show "$WIFI" 2>/dev/null); [[ -n $k && $k != -- ]] && nmcli -g ipv6.method,ipv4.route-metric connection show "$k" 2>/dev/null | sed "s/^/$k: /"; }
        fi
    } > "$backup/system-state.txt" 2>&1
    say "已备份到 $backup" "$GREEN"

    # 系统：时区、对时、双出口的网络设置
    if (( SKIP_SYSTEM )); then
        say '按 --skip-system 跳过时区、对时和网络设置' "$YELLOW"
    else
        set_timezone
        set_ntp
        [[ $DUAL_EXIT == yes ]] && set_dual_exit_network
    fi

    # Clash Verge 基础设置：config.yaml
    local -a cfg=() verge=() pl=() item=()
    read_lines cfg "$VERGE_DIR/config.yaml"
    set_top_key cfg ipv6 false
    set_tun_key cfg auto-route true
    set_tun_key cfg strict-route true
    if [[ $DUAL_EXIT == yes ]]; then set_tun_key cfg auto-detect-interface false; else set_tun_key cfg auto-detect-interface true; fi
    write_lines "$VERGE_DIR/config.yaml" cfg || die '写 config.yaml 失败。'

    # verge.yaml：关 DNS 覆写、关系统代理
    read_lines verge "$VERGE_DIR/verge.yaml"
    set_top_key verge enable_dns_settings false
    set_top_key verge enable_system_proxy false
    write_lines "$VERGE_DIR/verge.yaml" verge || die '写 verge.yaml 失败。'

    # 全局扩展覆写配置：整个文件会被替换，原来有别的内容时提醒一下
    local merge_path=$VERGE_DIR/profiles/Merge.yaml
    if [[ -f $merge_path ]] && grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$merge_path" | grep -qvE '^(profile:|  store-selected:|  store-fake-ip:|interface-name:)'; then
        say "注意：原来的全局扩展覆写配置里有别的内容，已备份到 $backup/profiles，需要的话手动合并回去。" "$YELLOW"
    fi
    {
        printf '# 由 setup-clash-ai.sh 生成（原文件已备份）\nprofile:\n  store-selected: true\n  store-fake-ip: true\n'
        if [[ $DUAL_EXIT == yes ]]; then printf '# 双出口：Clash 的所有出站都从这块网卡出去\ninterface-name: %s\n' "$WIFI"; fi
    } > "$merge_path" || die '写全局扩展覆写配置失败。'
    gs=$VERGE_DIR/profiles/Script.js
    if [[ -f $gs && $(grep -v '^[[:space:]]*//' "$gs" | tr -d '[:space:]') != 'functionmain(config,profileName){returnconfig;}' ]]; then
        say '注意：全局扩展脚本（profiles/Script.js）不是默认内容，它可能改写规则或 DNS，请检查。' "$YELLOW"
    fi

    # 组合配置：已有就原地更新，没有就新建，并设为当前配置
    read_subscriptions
    existing=-1
    for i in "${!SUB_UID[@]}"; do
        [[ ${SUB_TYPE[i]} == local && -n ${SUB_FILE[i]} && -f $VERGE_DIR/profiles/${SUB_FILE[i]} ]] || continue
        first=''; IFS= read -r first < "$VERGE_DIR/profiles/${SUB_FILE[i]}" || true
        first=${first#$'\xef\xbb\xbf'}
        [[ $first == "$PROFILE_MARKER"* ]] && { existing=$i; break; }
    done
    read_lines pl "$VERGE_DIR/profiles.yaml"
    if (( existing >= 0 )); then
        uid=${SUB_UID[existing]} file=${SUB_FILE[existing]}
        cp -p "$VERGE_DIR/profiles/$file" "$backup/profiles/"
        say "更新已有的组合配置（$file）"
    else
        uid="L$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 11)"
        file="$uid.yaml"
        item=("- uid: $uid" '  type: local' "  name: $PROFILE_NAME" "  file: $file" '  desc: 由 setup-clash-ai.sh 生成' "  updated: $(date +%s)")
        items_at=-1
        for i in "${!pl[@]}"; do
            [[ ${pl[i]} =~ ^items:[[:space:]]*\[\][[:space:]]*$ ]] && pl[i]='items:'
            [[ ${pl[i]} == 'items:' ]] && { items_at=$i; break; }
        done
        if (( items_at < 0 )); then pl+=('items:'); items_at=$(( ${#pl[@]} - 1 )); fi
        insert_at=${#pl[@]}
        for (( i = items_at + 1; i < ${#pl[@]}; i++ )); do [[ ${pl[i]} =~ ^[A-Za-z_]+: ]] && { insert_at=$i; break; }; done
        pl=("${pl[@]:0:insert_at}" "${item[@]}" "${pl[@]:insert_at}")
        say "新建组合配置（$file）"
    fi
    printf '%s\n' "$profile" > "$VERGE_DIR/profiles/$file" || die '写组合配置失败。'
    cur=-1; for i in "${!pl[@]}"; do [[ ${pl[i]} == current:* ]] && { cur=$i; break; }; done
    if (( cur >= 0 )); then pl[cur]="current: $uid"; else pl=("current: $uid" "${pl[@]}"); fi
    write_lines "$VERGE_DIR/profiles.yaml" pl || die '写 profiles.yaml 失败。'

    # 预放规则缓存（缺哪个下哪个；下不到就等 Clash 启动后经代理自己下）
    mkdir -p "$VERGE_DIR/ruleset"
    for i in "${!RULE_FILES[@]}"; do
        local dest="$VERGE_DIR/ruleset/${RULE_FILES[i]}" url code
        [[ -s $dest ]] && continue
        say "  下载规则集 ${RULE_FILES[i]}…"
        for url in "${RULE_RAW[i]}" "${RULE_CDN[i]}"; do
            code=$(curl -s -L --connect-timeout 8 -m 60 -o "$dest" -w '%{http_code}' "$url" 2>/dev/null)
            [[ $code == 200 && -s $dest ]] && break
            rm -f "$dest"
        done
        if [[ -s $dest ]]; then say '    已下载'; else say '    没下到，Clash 启动后会自己经代理下载' "$YELLOW"; fi
    done

    say ''
    say '=== 配置完成，接下来请手动做三件事 ===' "$GREEN"
    say '  1. 打开 Clash Verge（会自动启用「组合配置」）。'
    say '  2. 马上到「代理」页，在 AI 组里选一个节点（AI 组默认是「拒绝」，不选的话 AI 服务都连不上）。'
    say '  3. 回首页打开「虚拟网卡模式」（TUN；第一次会要求安装服务）。'
    say '  然后运行  bash setup-clash-ai.sh --verify  检查。'
    say "  恢复原样：退出 Clash Verge，把 $backup 里的文件拷回 $VERGE_DIR（原来的时区和网络状态记在同目录的 system-state.txt 里）。"
    (( NTP_SET )) && say "  对时设置在 $NTP_DROPIN，删掉它再运行 sudo systemctl restart systemd-timesyncd 就恢复。"
    return 0
}

main
