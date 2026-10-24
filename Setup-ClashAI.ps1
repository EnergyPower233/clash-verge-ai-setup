<#
  Setup-ClashAI.ps1 —— 按《Clash Verge 分流方案复现指南》一键配置：安全连接 AI、合理分流、安全连接代理。

  前提：已安装 Clash Verge Rev，并在「订阅」页导入了至少一个订阅。
  用法（在脚本所在文件夹打开管理员 PowerShell）：
    powershell -ExecutionPolicy Bypass -File .\Setup-ClashAI.ps1            交互式配置：启动时逐项选择
    powershell -ExecutionPolicy Bypass -File .\Setup-ClashAI.ps1 -DryRun    只生成并检查配置、预览各层节点，不改任何东西（不需要管理员）
    powershell -ExecutionPolicy Bypass -File .\Setup-ClashAI.ps1 -Verify    配好之后跑一遍验证清单（不需要管理员）
  本文件必须保存为带 BOM 的 UTF-8，否则 Windows PowerShell 5.1 会把中文读乱。
  每个选项也可以用参数直接给出，给了就不再问，例如：
    -Subscriptions 'all' -AiKeywords ';GPT' -TimeZone 'Singapore Standard Time' -AdBlock off -DualExit no -Yes

  双出口（-DualExit）：all = 开 TUN 时一切经 Clash 从「Clash 出口」出去，关 TUN 时一切走「默认出口」；
  split = 直连流量走「默认出口」，代理流量（所有节点）走「Clash 出口」。两个出口各是哪块网卡由你选。

  会改什么：Clash Verge 的 config.yaml / verge.yaml / profiles.yaml / 全局扩展覆写配置，新增「组合配置」，
  系统时区与自动对时；选了双出口时再改两块网卡的跃点数、关 Clash 出口那块网卡的 IPv6。改之前全部备份到 Clash Verge 配置目录下的 setup-backup-时间 目录。
  不会做：禁用任何网卡、改订阅链接、替你选 AI 节点。
#>
[CmdletBinding()]
param(
    [switch]$Verify,
    [switch]$DryRun,
    [string]$Subscriptions,
    [string]$AiKeywords,
    [string]$TimeZone,
    [ValidateSet('off', 'on')][string]$AdBlock,
    [ValidateSet('no', 'all', 'split', 'yes')][string]$DualExit,   # yes 是旧写法，等于 all
    [Alias('WiredAdapter')][string]$DefaultAdapter,              # 默认出口：关 TUN 时一切走它；split 时直连也走它
    [Alias('WifiAdapter')][string]$ClashAdapter,                 # Clash 出口：all 时开 TUN 一切走它；split 时只有节点连接走它
    [Alias('HotspotGateway')][string]$LanDns,                    # 双出口时，局域网域名用的 DNS
    [string]$ClashDir,       # Clash Verge 配置目录不在默认位置时（例如便携版）用它指定
    [switch]$SkipSystem,     # 只改 Clash，不动时区、对时和网卡
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$OldOutputEncoding = [Console]::OutputEncoding
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$VergeDir = if ($ClashDir) { $ClashDir } else { Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev' }
$ProfileName = '组合配置'
$ProfileMarker = '# 组合配置'

# 默认筛选规则（和文档里的模板一致）
$RegionAI   = '新加坡|狮城|台湾|日本|韩国|美国|加拿大|英国|德国|法国|荷兰|澳大利亚|Singapore|Taiwan|Japan|Korea|United States|USA|Canada|United Kingdom|Germany|France|Netherlands|Australia'
$BlockAI    = '香港|澳门|中国|俄罗斯|伊朗|朝鲜|Hong Kong|HongKong|Macau|China|Russia'
$InfoFilter = '剩余|到期|套餐|官网|客服|邮箱|重置|过期|支持AI|Traffic|Expire|Reset'

$TimeZones = @(
    @{ Label = '新加坡'; Id = 'Singapore Standard Time' },
    @{ Label = '台北'; Id = 'Taipei Standard Time' },
    @{ Label = '东京'; Id = 'Tokyo Standard Time' },
    @{ Label = '首尔'; Id = 'Korea Standard Time' },
    @{ Label = '美国西部'; Id = 'Pacific Standard Time' },
    @{ Label = '美国东部'; Id = 'Eastern Standard Time' },
    @{ Label = '伦敦'; Id = 'GMT Standard Time' },
    @{ Label = '不改时区'; Id = 'skip' }
)

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Ask([string]$prompt, [string]$default) {
    $a = Read-Host $(if ($default) { "$prompt [$default]" } else { $prompt })
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return $a.Trim()
}
# 问到输入合法为止：几个选项之一（y / n 当作 yes / no）
function Ask-Choice([string]$prompt, [string[]]$choices, [string]$default) {
    while ($true) {
        $a = (Ask $prompt $default).ToLower()
        if ($a -eq 'y') { $a = 'yes' } elseif ($a -eq 'n') { $a = 'no' }
        if ($choices -contains $a) { return $a }
        Say ("  请输入 {0}" -f ($choices -join ' / ')) 'Yellow'
    }
}
# 问到输入合法为止：1 到 count 的序号，返回下标
function Ask-Index([string]$prompt, [int]$count, [string]$default) {
    while ($true) {
        $n = 0
        if ([int]::TryParse((Ask $prompt $default), [ref]$n) -and $n -ge 1 -and $n -le $count) { return $n - 1 }
        Say "  请输入 1 到 $count 之间的序号" 'Yellow'
    }
}
function Test-Regex([string]$re) { try { [void][regex]::new($re); return $true } catch { return $false } }
function Pause-End { if (-not $Yes) { [void](Read-Host '按回车关闭') } }
function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function YQ([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
function EscRe([string]$s) { return [regex]::Replace($s, '([\\^$.|?*+()\[\]{}])', '\$1') }
function Read-Text([string]$p) { return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function Write-Text([string]$p, [string]$t) { [System.IO.File]::WriteAllText($p, $t.Replace("`r`n", "`n"), $Utf8) }

# 订阅列表：Clash Verge 的 profiles.yaml 里 type: remote 的条目
function Get-Subscriptions {
    $items = @(); $cur = $null
    foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $VergeDir 'profiles.yaml'), [System.Text.Encoding]::UTF8)) {
        if ($l -match '^- uid:\s*(\S+)') { if ($cur) { $items += [pscustomobject]$cur }; $cur = @{ Uid = $Matches[1]; Type = ''; Name = ''; File = '' } }
        elseif ($cur -and $l -match '^  (type|name|file):\s*(.*)$') { $cur[(Get-Culture).TextInfo.ToTitleCase($Matches[1])] = $Matches[2].Trim().Trim("'").Trim('"') }
    }
    if ($cur) { $items += [pscustomobject]$cur }
    return $items
}

# 订阅文件里的节点名（只用来预览；真正的筛选由内核做，所以这里同样区分大小写）
# 认得两种常见写法：- {name: …, …} 和 - name: …（列表项可以顶格，name 也可以不是第一个键）
function Get-NodeNames([string]$file) {
    $path = Join-Path $VergeDir "profiles\$file"; $names = @()
    if (-not $file -or -not (Test-Path -LiteralPath $path)) { return $names }
    $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
    $start = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^proxies:\s*(#.*)?$') { $start = $i; break } }
    if ($start -lt 0) { return $names }
    $ind = -1
    for ($i = $start + 1; $i -lt $lines.Count -and $lines[$i] -notmatch '^[^\s#-]'; $i++) {
        $l = $lines[$i]
        if ($l -match '^(\s*)-\s*(.*)$') {
            if ($ind -lt 0) { $ind = $Matches[1].Length }
            if ($Matches[1].Length -ne $ind) { continue }
            $rest = $Matches[2]
            if ($rest -match '^\{\s*name:\s*("[^"]*"|''[^'']*''|[^,}]+)') { $names += $Matches[1].Trim().Trim("'").Trim('"') }
            elseif ($rest -match '^name:\s*(.+)$') { $names += $Matches[1].Trim().Trim("'").Trim('"') }
        } elseif ($ind -ge 0 -and $l -match ('^ {' + ($ind + 2) + '}name:\s*(.+)$')) { $names += $Matches[1].Trim().Trim("'").Trim('"') }
    }
    return $names | Where-Object { $_ -cnotmatch $InfoFilter }
}

# 双出口的设置记在全局扩展覆写配置的一行注释里；旧版本只写了 interface-name，那就是 all
function Get-DualExitState {
    $merge = Join-Path $VergeDir 'profiles\Merge.yaml'
    if (-not (Test-Path $merge)) { return $null }
    $t = Read-Text $merge
    if ($t -match '(?m)^# setup-clash-ai dual-exit: mode=(all|split); clash=([^;\r\n]+); default=([^;\r\n]*)\r?$') {
        return [pscustomobject]@{ Mode = $Matches[1]; Clash = $Matches[2].Trim(); Default = $Matches[3].Trim() }
    }
    if ($t -match '(?m)^interface-name:\s*(.+?)\s*$') { return [pscustomobject]@{ Mode = 'all'; Clash = $Matches[1]; Default = '' } }
    return $null
}

# split 双出口：分别下载 1 MB，看是哪块网卡在收（会经 Clash 出口用掉约 1 MB 流量）
function Test-SplitExit([string]$clashIf, [string]$defaultIf) {
    $cases = @(
        @{ What = "代理流量走 Clash 出口（$clashIf）"; Url = 'https://speed.cloudflare.com/__down?bytes=1048576'; Range = ''; Want = $clashIf; Other = $defaultIf },
        @{ What = "直连流量走默认出口（$defaultIf）"; Url = 'https://mirrors.aliyun.com/ubuntu/ls-lR.gz'; Range = '0-1048575'; Want = $defaultIf; Other = $clashIf }
    )
    foreach ($c in $cases) {
        $w0 = (Get-NetAdapterStatistics -Name $c.Want).ReceivedBytes; $o0 = (Get-NetAdapterStatistics -Name $c.Other).ReceivedBytes
        $ca = @('-s', '-o', 'NUL', '-m', '30', '-w', '%{size_download}'); if ($c.Range) { $ca += @('-r', $c.Range) }
        [int64]$got = 0; [void][int64]::TryParse([string](curl.exe @ca $c.Url), [ref]$got)
        $w = (Get-NetAdapterStatistics -Name $c.Want).ReceivedBytes - $w0; $o = (Get-NetAdapterStatistics -Name $c.Other).ReceivedBytes - $o0
        $detail = "{0} 收到 {1:N0} KB，{2} 收到 {3:N0} KB" -f $c.Want, ($w / 1KB), $c.Other, ($o / 1KB)
        if ($got -lt 512KB) { Mark '跳过' $c.What ("下载没成功（只下到 {0:N0} KB）" -f ($got / 1KB)) }
        elseif ($w -ge $got * 0.9 -and $o -lt $got * 0.5) { Mark '通过' $c.What $detail }
        else { Mark '失败' $c.What $detail }
    }
}

# ───────────── 验证模式 ─────────────
function Invoke-Verify {
    $script:ok = 0; $script:bad = 0
    function Mark([string]$state, [string]$what, [string]$detail) {
        $color = @{ '通过' = 'Green'; '失败' = 'Red'; '跳过' = 'Yellow'; '信息' = 'Cyan' }[$state]
        Write-Host ("[{0}] {1}  {2}" -f $state, $what, $detail) -ForegroundColor $color
        if ($state -eq '通过') { $script:ok++ } elseif ($state -eq '失败') { $script:bad++ }
    }
    function Trace([string]$u) { $t = curl.exe -s -m 15 $u; if ($t) { $h = @{}; foreach ($l in ($t -split "`n")) { if ($l -match '^(ip|loc)=(.*)$') { $h[$Matches[1]] = $Matches[2].Trim() } }; return $h }; return $null }
    $dev = Select-String -LiteralPath (Join-Path $VergeDir 'config.yaml') -Pattern '^  device:\s*(\S+)' | Select-Object -First 1
    $tunName = if ($dev) { $dev.Matches[0].Groups[1].Value } else { 'Mihomo' }
    $tun = Get-NetAdapter -Name $tunName -ErrorAction SilentlyContinue
    $tunOn = $tun -and $tun.Status -eq 'Up'
    $de = Get-DualExitState
    $defIf = $null
    if ($de) { $defIf = if ($de.Default) { $de.Default } else { (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.Name -ne $de.Clash } | Select-Object -First 1).Name } }
    $dualText = if (-not $de) { '否' } elseif ($de.Mode -eq 'all') { "all（开 TUN 时一切走 $($de.Clash)，关 TUN 走 $defIf）" } else { "split（代理走 $($de.Clash)，直连走 $defIf）" }
    Say ''
    Say ("TUN：{0}；双出口：{1}" -f $(if ($tunOn) { '开' } else { '关' }), $dualText) 'Cyan'
    if ($tunOn) {
        $watchAll = $de -and $de.Mode -eq 'all' -and $defIf
        $before = if ($watchAll) { (Get-NetAdapterStatistics -Name $defIf).SentBytes } else { 0 }
        $c = Trace 'https://claude.ai/cdn-cgi/trace'
        if (-not $c) { Mark '失败' 'Claude 走 AI 节点' '没有响应：AI 组是不是还停在「拒绝」？' }
        elseif ($c.loc -in 'CN', 'HK', 'MO', 'RU', 'IR', 'KP') { Mark '失败' 'Claude 走 AI 节点' "出口 $($c.ip) 在 $($c.loc)，这个地区不支持 AI" }
        else { Mark '通过' 'Claude 走 AI 节点' "出口 $($c.ip)，地区 $($c.loc)" }
        $o = Trace 'https://www.cloudflare.com/cdn-cgi/trace'
        if ($o) { Mark '信息' '其他网站的出口' "$($o.ip)，地区 $($o.loc)（应是「其他」层所选节点）" } else { Mark '失败' '其他网站的出口' '没有响应' }
        # Google 的请求全部走「其他」层，Google 按它认定的地区决定 Gemini 能不能用
        $yt = (curl.exe -s -m 15 -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/130 Safari/537.36' -H 'Accept-Language: en-US' https://www.youtube.com/) -join ''
        $gl = [regex]::Match($yt, '"GL":"([A-Z]{2})"').Groups[1].Value
        if (-not $gl) { Mark '跳过' 'Google 认定的地区' '没取到（YouTube 没有响应）' }
        elseif ($gl -in 'CN', 'HK', 'MO') { Mark '失败' 'Google 认定的地区' "Google 认为你在 $gl，Gemini 等 Google AI 可能用不了：给「其他」层换一个支持 AI 的地区的节点" }
        else { Mark '通过' 'Google 认定的地区' "$gl（Google 的请求都走「其他」层）" }
        $d = curl.exe -s -m 12 https://myip.ipip.net
        if ($d) { Mark '信息' '国内网站直连' ($d.Trim()) } else { Mark '失败' '国内网站直连' '没有响应' }
        $a = Resolve-DnsName claude.ai -Type A -Server 223.5.5.5 -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue | Where-Object Type -eq 'A' | Select-Object -First 1
        if ($a -and $a.IPAddress -like '198.18.*') { Mark '通过' 'DNS 被 Clash 接管' "外部 DNS 查询拿到假 IP $($a.IPAddress)" } else { Mark '失败' 'DNS 被 Clash 接管' "拿到的是 $($a.IPAddress)" }
        $w = Resolve-DnsName whoami.ds.akahelp.net -Type TXT -DnsOnly -ErrorAction SilentlyContinue | Where-Object Type -eq 'TXT' | ForEach-Object { $_.Strings -join ' ' }
        if ($w) { Mark '信息' 'Clash 自己的境外查询出口' (($w | Where-Object { $_ -match '^ecs' }) -join ' ') } else { Mark '跳过' 'Clash 自己的境外查询出口' '查询没有返回' }
        if ($watchAll) {
            $sent = (Get-NetAdapterStatistics -Name $defIf).SentBytes - $before
            if ($sent -lt 64KB) { Mark '通过' "默认出口（$defIf）基本不发数据" ("测试期间只发出 {0:N1} KB" -f ($sent / 1KB)) } else { Mark '失败' "默认出口（$defIf）基本不发数据" ("测试期间发出 {0:N1} KB" -f ($sent / 1KB)) }
        }
        if ($de -and $de.Mode -eq 'split' -and $defIf) { Test-SplitExit $de.Clash $defIf }
    } else {
        Mark '跳过' 'Claude / DNS 相关检查' 'TUN 关着时这些请求会直连出去，所以不测；打开 TUN 后再运行一次 -Verify'
        $o = Trace 'https://www.cloudflare.com/cdn-cgi/trace'
        if ($o) { Mark '信息' 'TUN 关时的出口' "$($o.ip)，地区 $($o.loc)（应是本地网络）" }
        if ($de) {
            $r = Find-NetRoute -RemoteIPAddress 1.1.1.1 -ErrorAction SilentlyContinue | Where-Object DestinationPrefix | Select-Object -First 1
            $good = $r -and $(if ($defIf) { $r.InterfaceAlias -eq $defIf } else { $r.InterfaceAlias -ne $de.Clash })
            if ($good) { Mark '通过' "TUN 关时走默认出口（$defIf）" "系统选 $($r.InterfaceAlias)" } else { Mark '失败' "TUN 关时走默认出口（$defIf）" "系统选 $($r.InterfaceAlias)" }
        }
    }
    # 组合配置只走 IPv4：物理网卡上有公网 IPv6 时，IPv6 流量和网页的 WebRTC 可能绕过 Clash
    $phys = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object Name)
    $v6 = @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -match '^[23]' -and $phys -contains $_.InterfaceAlias })
    if ($v6.Count) { Mark '失败' '没有绕过 Clash 的 IPv6' ("{0} 有公网 IPv6，IPv6 流量可能绕过 Clash。关掉它：Disable-NetAdapterBinding -Name '{0}' -ComponentID ms_tcpip6" -f $v6[0].InterfaceAlias) }
    else { Mark '通过' '没有绕过 Clash 的 IPv6' '物理网卡上都没有公网 IPv6' }
    $u = @(Get-NetUDPEndpoint -LocalPort 1053 -ErrorAction SilentlyContinue)
    if ($u.Count -eq 0) { Mark '跳过' 'DNS 只监听本机' 'Clash 没在运行' }
    elseif (@($u | Where-Object { $_.LocalAddress -ne '127.0.0.1' }).Count -eq 0) { Mark '通过' 'DNS 只监听本机' '只有 127.0.0.1:1053' }
    else { Mark '失败' 'DNS 只监听本机' (($u | ForEach-Object LocalAddress) -join ', ') }
    Say ''
    Say "通过 $script:ok 项，失败 $script:bad 项。失效保护需要手动测：AI 组临时选「拒绝」，claude.ai 应该打不开。" $(if ($script:bad) { 'Red' } else { 'Green' })
}

# ───────────── 组合配置模板 ─────────────
$Template = @'
# 组合配置（由 Setup-ClashAI.ps1 生成）：订阅只当节点来源；三层 DNS / AI / 其他 各选各的节点。
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
  # DNS 层：Clash 自己查境外域名时从这里出去。默认跟「其他」层走同一个节点，也可以单独选一个；没有直连选项。
  - name: DNS
    type: select
    proxies: [其他]
    use: {{USE}}
  # 广告开关：PASS = 关闭（继续往下匹配），REJECT = 开启。
  - name: 广告拦截
    type: select
    proxies: {{AD_PROXIES}}
  # 全局模式（Clash Verge 首页切到「全局」）用这个组：默认跟「其他」层走，选 AI 就一切走 AI 节点。
  - name: GLOBAL
    type: select
    proxies: [其他, AI]
    use: {{USE}}

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
      # AI 登录和验证码（多家 AI 共用，和 AI 页面同一个出口，验证才不会因 IP 不一致失败）。Google 的登录和验证码跟着 Google 走「其他」。
      - DOMAIN,challenges.cloudflare.com
      - DOMAIN-SUFFIX,hcaptcha.com
      - DOMAIN-SUFFIX,arkoselabs.com
      - DOMAIN-SUFFIX,funcaptcha.com
      - DOMAIN,appleid.apple.com
      - DOMAIN,idmsa.apple.com
      - DOMAIN,appleid.cdn-apple.com
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
  # Google 整个走「其他」，包括 Gemini、AI Studio 和 Google 登录：Google 按账号判断地区，同一个账号的请求要从同一个出口出去；
  # 上游还把 Google 一部分国内能连的域名放进了直连，会带着账号 Cookie 暴露真实 IP。所以「其他」层要选一个能正常用 Google 的节点。
  - GEOSITE,google,其他
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
  # 必应整个走「其他」：上游把它一部分国内能连的域名放进了直连，这些请求会带着账号 Cookie 从你的真实 IP 出去。
  - DOMAIN-SUFFIX,bing.com,其他
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
  skip-domain:
    - +.apple.co
    - Mijia Cloud
    - dlg.io.mi.com
    - +.oray.com
    - +.sunlogin.net
    - +.push.apple.com
'@

$RuleSets = @(
    @{ File = 'meta-ai-noncn.yaml'; Raw = 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/category-ai-!cn.yaml'; Cdn = 'https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/category-ai-!cn.yaml' }
)
foreach ($n in 'private', 'reject', 'proxy', 'direct', 'lancidr', 'cncidr', 'telegramcidr') {
    $RuleSets += @{ File = "loyal-$n.yaml"; Raw = "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/$n.txt"; Cdn = "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/$n.txt" }
}

# ───────────── 主流程 ─────────────
try {
    if (-not (Test-Path (Join-Path $VergeDir 'profiles.yaml'))) {
        throw "找不到 Clash Verge 的配置目录 $VergeDir。请先安装 Clash Verge Rev 并至少打开一次；用别的管理员账户运行也会这样。"
    }
    if ($Verify) { Invoke-Verify; Pause-End; return }
    if (-not $DryRun -and -not $SkipSystem -and -not (Test-Admin)) { throw '请用管理员 PowerShell 运行（改时区、对时、网卡设置需要管理员）；只想预览就加 -DryRun。' }

    Say '=== Clash Verge 分流配置：安全连接 AI、合理分流、安全连接代理 ===' 'Cyan'
    if ($DryRun) { Say '（演练模式：只生成并检查配置，不改任何东西）' 'Yellow' }

    # 1. 选订阅
    $subs = @(Get-Subscriptions | Where-Object { $_.Type -eq 'remote' })
    if ($subs.Count -eq 0) { throw '订阅页里还没有订阅：先在 Clash Verge 的「订阅」页导入至少一个订阅链接。' }
    Say ''
    Say '已导入的订阅：'
    for ($i = 0; $i -lt $subs.Count; $i++) { Say ("  {0}. {1}（{2} 个节点）" -f ($i + 1), $subs[$i].Name, @(Get-NodeNames $subs[$i].File).Count) }
    while ($true) {
        if (-not $Subscriptions) { $Subscriptions = Ask '要用哪些订阅？输入序号，用逗号分开；同一订阅的多个副本只选一个' 'all' }
        $chosen = @(); $unknown = @()
        if ($Subscriptions -eq 'all') { $chosen = $subs }
        else {
            foreach ($tok in ($Subscriptions -split '[,，]')) {
                $t = $tok.Trim(); $n = 0; if (-not $t) { continue }
                if ([int]::TryParse($t, [ref]$n)) { if ($n -ge 1 -and $n -le $subs.Count) { $chosen += $subs[$n - 1] } else { $unknown += $t } }
                else { $m = @($subs | Where-Object { $_.Name -eq $t }); if ($m.Count) { $chosen += $m } else { $unknown += $t } }
            }
        }
        $uniq = @(); foreach ($c in $chosen) { if (-not @($uniq | Where-Object { $_.Uid -eq $c.Uid }).Count) { $uniq += $c } }
        $chosen = $uniq
        if ($unknown.Count -eq 0 -and $chosen.Count -gt 0) { break }
        $msg = if ($unknown.Count) { "没有这些订阅：$($unknown -join '、')" } else { '没有选中任何订阅。' }
        if ($PSBoundParameters.ContainsKey('Subscriptions')) { throw $msg }
        Say "  $msg" 'Yellow'; $Subscriptions = ''
    }
    # 节点来源的名字（也是节点名前缀）不能重名：重名的加序号
    $keys = @{}
    foreach ($s in $chosen) {
        $k = if ($s.Name -and $s.Name -ne 'null') { $s.Name } else { $s.Uid }
        $base = $k; $j = 2
        while ($keys.ContainsKey($k)) { $k = "$base $j"; $j++ }
        $keys[$k] = $true
        $s | Add-Member -NotePropertyName Key -NotePropertyValue $k -Force
    }

    # 2. 每个订阅里怎么认出能用 AI 的节点
    Say ''
    Say 'AI 层只放能用 AI 的节点。机场注明了哪些节点能用 AI（比如名字带 GPT，或只有某几个地区）时，输入关键词，多个用 | 隔开；直接回车 = 按支持 AI 的地区筛。'
    $kwList = @()
    if ($PSBoundParameters.ContainsKey('AiKeywords')) { $kwList = @([string]$AiKeywords -split ';') }
    $aiParts = @(); $preview = @()
    for ($i = 0; $i -lt $chosen.Count; $i++) {
        $s = $chosen[$i]
        while ($true) {
            $kw = if ($PSBoundParameters.ContainsKey('AiKeywords')) { if ($i -lt $kwList.Count) { $kwList[$i].Trim() } else { '' } } else { Ask "订阅「$($s.Name)」的 AI 节点关键词（区分大小写）" '' }
            if (Test-Regex $kw) { break }
            if ($PSBoundParameters.ContainsKey('AiKeywords')) { throw "AI 节点关键词「$kw」不是有效的正则表达式。" }
            Say "  「$kw」不是有效的正则表达式，请重新输入" 'Yellow'
        }
        $pattern = if ($kw) { $kw } else { $RegionAI }
        $aiParts += '^' + (EscRe "[$($s.Key)] ") + '.*(' + $pattern + ')'
        $nodes = @(Get-NodeNames $s.File | Where-Object { $_ -cmatch $pattern -and $_ -cnotmatch $BlockAI })
        $preview += [pscustomobject]@{ Sub = $s.Name; Count = $nodes.Count; Nodes = $nodes }
    }
    foreach ($p in $preview) {
        if ($p.Count -eq 0) { Say ("  ！订阅「{0}」没有节点能进 AI 层，检查关键词" -f $p.Sub) 'Yellow' }
        else { Say ("  「{0}」能进 AI 层的 {1} 个节点：{2}" -f $p.Sub, $p.Count, ($p.Nodes -join '、')) }
    }
    if (@($preview | Where-Object { $_.Count -gt 0 }).Count -eq 0) { throw 'AI 层一个节点都没有，请换关键词重新运行。' }

    # 3. 时区
    if (-not $TimeZone) {
        Say ''
        Say '时区要和 AI 节点所在地一致（网站会看到系统时区）：'
        for ($i = 0; $i -lt $TimeZones.Count; $i++) { Say ("  {0}. {1}" -f ($i + 1), $TimeZones[$i].Label) }
        $TimeZone = $TimeZones[(Ask-Index '选哪个？' $TimeZones.Count '1')].Id
    }
    if ($TimeZone -ne 'skip' -and -not @(Get-TimeZone -ListAvailable | Where-Object { $_.Id -eq $TimeZone }).Count) { throw "没有这个时区：$TimeZone（用 Get-TimeZone -ListAvailable 查 Id，或填 skip）" }

    # 4. 广告拦截默认开不开
    if (-not $AdBlock) { $AdBlock = Ask-Choice '广告拦截默认开吗？on / off' @('on', 'off') 'off' }

    # 5. 双出口
    if ($DualExit -eq 'yes') { $DualExit = 'all' }
    if (-not $DualExit) {
        Say ''
        Say '双出口：电脑同时连着两个网络（比如网线和手机热点）时，可以让流量分开走。只有一个网络就选 no。'
        Say '  all    开 TUN 时一切经 Clash 从「Clash 出口」出去，关 TUN 时一切走「默认出口」'
        Say '  split  直连流量走「默认出口」，代理流量（所有节点）走「Clash 出口」；关 TUN 时一切走「默认出口」'
        $DualExit = Ask-Choice '用哪种？no / all / split' @('no', 'all', 'split', 'yes') 'no'
        if ($DualExit -eq 'yes') { $DualExit = 'all' }
    }
    if ($DualExit -ne 'no') {
        $nics = @(Get-NetAdapter -Physical | Sort-Object Name)
        if (-not $DefaultAdapter -or -not $ClashAdapter) {
            if ($nics.Count -lt 2) { throw "双出口需要两块物理网卡，这台电脑只找到 $($nics.Count) 块。" }
            Say '物理网卡：'
            for ($i = 0; $i -lt $nics.Count; $i++) { Say ("  {0}. {1}（{2}，{3}）" -f ($i + 1), $nics[$i].Name, $nics[$i].InterfaceDescription, $nics[$i].Status) }
            $media = @($nics | ForEach-Object { [string]$_.PhysicalMediaType })
            $defWired = [Array]::IndexOf($media, '802.3') + 1; if ($defWired -lt 1) { $defWired = 1 }
            $defWifi = [Array]::IndexOf($media, 'Native 802.11') + 1; if ($defWifi -lt 1) { $defWifi = 2 }
            if ($defWifi -eq $defWired) { $defWifi = if ($defWired -eq 1) { 2 } else { 1 } }   # 两块都是无线或都是有线时，默认值别指向同一块
            $defRole = if ($DualExit -eq 'all') { '关 TUN 时一切走它' } else { '直连流量和关 TUN 时都走它' }
            $clashRole = if ($DualExit -eq 'all') { '开 TUN 时一切走它' } else { '代理流量（所有节点）走它' }
            if (-not $DefaultAdapter) { $DefaultAdapter = $nics[(Ask-Index "哪块网卡做「默认出口」（$defRole）？" $nics.Count "$defWired")].Name }
            if (-not $ClashAdapter) { $ClashAdapter = $nics[(Ask-Index "哪块网卡做「Clash 出口」（$clashRole）？" $nics.Count "$defWifi")].Name }
        }
        if (-not (Get-NetAdapter -Name $DefaultAdapter -ErrorAction SilentlyContinue) -or -not (Get-NetAdapter -Name $ClashAdapter -ErrorAction SilentlyContinue)) { throw "找不到网卡「$DefaultAdapter」或「$ClashAdapter」。" }
        if ($DefaultAdapter -eq $ClashAdapter) { throw '默认出口和 Clash 出口不能是同一块网卡。' }
        # 局域网域名的 DNS：直连从哪块网卡出去，就用那边的 DNS
        $lanIf = if ($DualExit -eq 'all') { $ClashAdapter } else { $DefaultAdapter }
        if (-not $LanDns) {
            $found = @(Get-DnsClientServerAddress -InterfaceAlias $lanIf -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object ServerAddresses) | Select-Object -First 1
            if (-not $found) { $found = (Get-NetIPConfiguration -InterfaceAlias $lanIf -ErrorAction SilentlyContinue).IPv4DefaultGateway.NextHop | Select-Object -First 1 }
            $LanDns = if ($found) { Ask "局域网域名用的 DNS（从「$lanIf」读到的，回车确认）" $found } else { Ask "没读到「$lanIf」的 DNS。运行 ipconfig /all，把「$lanIf」那一项的「DNS 服务器」填在这里" '' }
        }
        if ($LanDns -notmatch '^(\d{1,3}\.){3}\d{1,3}$') { throw "局域网 DNS「$LanDns」不是 IPv4 地址。" }
    }

    # 汇总
    Say ''
    Say '=== 将要做的事 ===' 'Cyan'
    Say ("  订阅：{0}" -f (($chosen | ForEach-Object Name) -join '、'))
    $dualText = switch ($DualExit) {
        'all' { "all（开 TUN 时一切走 $ClashAdapter，关 TUN 走 $DefaultAdapter；局域网 DNS $LanDns）" }
        'split' { "split（直连走 $DefaultAdapter，代理走 $ClashAdapter；局域网 DNS $LanDns）" }
        default { '否' }
    }
    Say ("  时区：{0}；广告拦截默认：{1}；双出口：{2}" -f $TimeZone, $AdBlock, $dualText)
    if (-not $DryRun -and -not $Yes) {
        Say '  执行时需要先退出 Clash Verge；退出期间 TUN 会断开，所有流量（包括 AI）都会直连。' 'Yellow'
        if ((Ask-Choice '确认开始？y / n' @('yes', 'no') 'y') -ne 'yes') { Say '已取消，什么都没改。'; Pause-End; return }
    }

    # 生成组合配置
    $prov = ''
    # split：只有节点连接绑在 Clash 出口上，直连照常走系统默认出口
    $bind = if ($DualExit -eq 'split') { "      interface-name: $(YQ $ClashAdapter)`n" } else { '' }
    foreach ($s in $chosen) {
        $prov += "  $(YQ $s.Key):`n    type: file`n    path: $(YQ "./profiles/$($s.File)")`n    interval: 3600`n    exclude-filter: $(YQ $InfoFilter)`n    exclude-type: 'direct'`n    override:`n      additional-prefix: $(YQ "[$($s.Key)] ")`n$bind"
    }
    $use = '[' + (($chosen | ForEach-Object { YQ $_.Key }) -join ', ') + ']'
    $privateDns = if ($DualExit -ne 'no') { YQ $LanDns } else { "'system'" }
    $adProxies = if ($AdBlock -eq 'on') { '[REJECT, PASS]' } else { '[PASS, REJECT]' }
    $profileText = $Template.Replace('{{PROVIDERS}}', $prov).Replace('{{USE}}', $use).Replace('{{AI_FILTER}}', (YQ ($aiParts -join '|'))).Replace('{{AI_EXCLUDE}}', (YQ $BlockAI)).Replace('{{AD_PROXIES}}', $adProxies).Replace('{{PRIVATE_DNS}}', $privateDns) + "`n"

    # 用内核检查生成的配置
    $mihomo = @("$env:ProgramFiles\Clash Verge\verge-mihomo.exe", "$env:LOCALAPPDATA\Programs\Clash Verge\verge-mihomo.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    $checkFile = Join-Path $env:TEMP 'Combined-Profile.check.yaml'
    Write-Text $checkFile $profileText
    if ($mihomo) {
        $out = & $mihomo -t -d $VergeDir -f $checkFile 2>&1 | Out-String
        if ($out -notmatch 'test is successful') { throw "内核检查没通过，什么都没改：`n$out" }
        Say '内核检查通过。' 'Green'
    } else { Say '没找到 verge-mihomo.exe，跳过内核检查。' 'Yellow' }

    if ($DryRun) {
        $preview = Join-Path $env:TEMP 'Combined-Profile.preview.yaml'
        Move-Item $checkFile $preview -Force
        Say "演练结束，生成的配置在 $preview，什么都没改。" 'Green'
        Pause-End; return
    }
    Remove-Item $checkFile -ErrorAction SilentlyContinue

    # 等 Clash Verge 退出（指定了别的配置目录时，改的不是正在运行的那份，不用等）
    while (-not $ClashDir -and (Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue)) {
        if ($Yes) { throw 'Clash Verge 还在运行：请先从托盘图标退出它。' }
        [void](Read-Host '请从托盘图标退出 Clash Verge，然后按回车')
    }

    # 动手前先确认 config.yaml 的格式脚本认得，免得改到一半才失败
    if ((Read-Text "$VergeDir\config.yaml") -match '(?m)^tun:[ \t]*\{[ \t]*[^}\s]') { throw 'config.yaml 里的 tun 是单行写法，脚本没法安全修改：先在 Clash Verge 的 TUN 设置里改一项再改回来（让它重新保存），然后重新运行。什么都没改。' }

    # 备份：放在 Clash Verge 配置目录里（profiles.yaml 含订阅链接，留在原来的位置，不散到别处）
    $backup = Join-Path $VergeDir ('setup-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $backup, "$backup\profiles" | Out-Null
    foreach ($f in 'config.yaml', 'verge.yaml', 'profiles.yaml') { if (Test-Path "$VergeDir\$f") { Copy-Item "$VergeDir\$f" $backup } }
    if (Test-Path "$VergeDir\profiles\Merge.yaml") { Copy-Item "$VergeDir\profiles\Merge.yaml" "$backup\profiles" }
    Get-NetIPInterface | Select-Object InterfaceAlias, AddressFamily, AutomaticMetric, InterfaceMetric | ConvertTo-Json | Set-Content "$backup\network-metrics.json" -Encoding UTF8
    Get-NetAdapterBinding -ComponentID ms_tcpip6 | Select-Object Name, Enabled | ConvertTo-Json | Set-Content "$backup\ipv6-bindings.json" -Encoding UTF8
    Say "已备份到 $backup" 'Green'

    # 系统：时区与对时
    if ($SkipSystem) { Say '按 -SkipSystem 跳过时区、对时和网卡设置' 'Yellow' }
    if (-not $SkipSystem -and $TimeZone -ne 'skip') { Set-TimeZone -Id $TimeZone; Say "时区已设为 $TimeZone" }
    if (-not $SkipSystem) { try {
        Set-Service w32time -StartupType Automatic; Start-Service w32time -ErrorAction SilentlyContinue
        w32tm /config /manualpeerlist:"ntp.aliyun.com,0x8 time.windows.com,0x8" /syncfromflags:manual /update | Out-Null
        w32tm /resync | Out-Null
        Say '已开启自动对时（阿里云、微软 NTP）'
    } catch { Say "自动对时没设好：$($_.Exception.Message)" 'Yellow' } }

    # 系统：双出口
    if ($DualExit -ne 'no' -and -not $SkipSystem) {
        foreach ($fam in 'IPv4', 'IPv6') {
            Set-NetIPInterface -InterfaceAlias $DefaultAdapter -AddressFamily $fam -AutomaticMetric Disabled -InterfaceMetric 1 -ErrorAction SilentlyContinue
            Set-NetIPInterface -InterfaceAlias $ClashAdapter -AddressFamily $fam -AutomaticMetric Disabled -InterfaceMetric 500 -ErrorAction SilentlyContinue
        }
        Disable-NetAdapterBinding -Name $ClashAdapter -ComponentID ms_tcpip6 -Confirm:$false
        Say "双出口：跃点数 $DefaultAdapter=1、$ClashAdapter=500，已关闭 $ClashAdapter 的 IPv6"
    }

    # Clash Verge 基础设置：config.yaml
    $cfgPath = "$VergeDir\config.yaml"
    $cfg = [System.Collections.Generic.List[string]]([System.IO.File]::ReadAllLines($cfgPath, [System.Text.Encoding]::UTF8))
    function Set-TopKey([System.Collections.Generic.List[string]]$l, [string]$k, [string]$v) {
        for ($i = 0; $i -lt $l.Count; $i++) { if ($l[$i] -match "^${k}:") { $l[$i] = "${k}: $v"; return } }
        $l.Add("${k}: $v")
    }
    function Set-TunKey([System.Collections.Generic.List[string]]$l, [string]$k, [string]$v) {
        $t = $l.IndexOf('tun:')
        if ($t -lt 0) { $t = $l.IndexOf('tun: {}'); if ($t -ge 0) { $l[$t] = 'tun:' } }
        if ($t -lt 0) { $l.Add('tun:'); $t = $l.Count - 1 }
        for ($i = $t + 1; $i -lt $l.Count -and $l[$i] -match '^\s'; $i++) { if ($l[$i] -match "^  ${k}:") { $l[$i] = "  ${k}: $v"; return } }
        $l.Insert($t + 1, "  ${k}: $v")
    }
    Set-TopKey $cfg 'ipv6' 'false'
    Set-TunKey $cfg 'auto-route' 'true'
    Set-TunKey $cfg 'strict-route' 'true'
    Set-TunKey $cfg 'auto-detect-interface' $(if ($DualExit -eq 'all') { 'false' } else { 'true' })
    Write-Text $cfgPath (($cfg -join "`n") + "`n")

    # verge.yaml：关 DNS 覆写、关系统代理
    $vPath = "$VergeDir\verge.yaml"
    $v = [System.Collections.Generic.List[string]]([System.IO.File]::ReadAllLines($vPath, [System.Text.Encoding]::UTF8))
    Set-TopKey $v 'enable_dns_settings' 'false'
    Set-TopKey $v 'enable_system_proxy' 'false'
    Write-Text $vPath (($v -join "`n") + "`n")

    # 全局扩展覆写配置：整个文件会被替换，原来有别的内容时提醒一下
    $mergePath = "$VergeDir\profiles\Merge.yaml"
    if ((Test-Path $mergePath) -and @((Read-Text $mergePath) -split "`n" | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' -and $_ -notmatch '^(profile:|  store-selected:|  store-fake-ip:|interface-name:)' }).Count) {
        Say "注意：原来的全局扩展覆写配置里有别的内容，已备份到 $backup\profiles，需要的话手动合并回去。" 'Yellow'
    }
    $merge = "# 由 Setup-ClashAI.ps1 生成（原文件已备份）`nprofile:`n  store-selected: true`n  store-fake-ip: true`n"
    if ($DualExit -ne 'no') { $merge += "# 双出口的设置（-Verify 读这一行，别改）`n# setup-clash-ai dual-exit: mode=$DualExit; clash=$ClashAdapter; default=$DefaultAdapter`n" }
    if ($DualExit -eq 'all') { $merge += "# 双出口 all：Clash 的所有出站都从这块网卡出去`ninterface-name: $ClashAdapter`n" }
    Write-Text "$VergeDir\profiles\Merge.yaml" $merge
    $gs = "$VergeDir\profiles\Script.js"
    if ((Test-Path $gs) -and ((Read-Text $gs) -notmatch '^\s*//[^\n]*\n\s*function main\(config, profileName\) \{\s*return config;\s*\}\s*$')) {
        Say '注意：全局扩展脚本（profiles\Script.js）不是默认内容，它可能改写规则或 DNS，请检查。' 'Yellow'
    }

    # 组合配置：已有就原地更新，没有就新建，并设为当前配置
    $pPath = "$VergeDir\profiles.yaml"
    $plines = [System.Collections.Generic.List[string]]([System.IO.File]::ReadAllLines($pPath, [System.Text.Encoding]::UTF8))
    $existing = Get-Subscriptions | Where-Object { $_.Type -eq 'local' -and $_.File -and (Test-Path "$VergeDir\profiles\$($_.File)") -and ((Read-Text "$VergeDir\profiles\$($_.File)").StartsWith($ProfileMarker)) } | Select-Object -First 1
    if ($existing) {
        $uid = $existing.Uid; $file = $existing.File
        Copy-Item "$VergeDir\profiles\$file" "$backup\profiles" -Force
        Say "更新已有的组合配置（$file）"
    } else {
        $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.ToCharArray()
        $uid = 'L' + (-join (1..11 | ForEach-Object { $chars | Get-Random }))
        $file = "$uid.yaml"
        $item = @("- uid: $uid", '  type: local', "  name: $ProfileName", "  file: $file", '  desc: 由 Setup-ClashAI.ps1 生成', "  updated: $([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())")
        $itemsAt = $plines.IndexOf('items:')
        if ($itemsAt -lt 0) { $plines.Add('items:'); $itemsAt = $plines.Count - 1 }
        $insertAt = $plines.Count
        for ($i = $itemsAt + 1; $i -lt $plines.Count; $i++) { if ($plines[$i] -match '^[A-Za-z_]+:') { $insertAt = $i; break } }
        $plines.InsertRange($insertAt, [string[]]$item)
        Say "新建组合配置（$file）"
    }
    Write-Text "$VergeDir\profiles\$file" $profileText
    $cur = -1; for ($i = 0; $i -lt $plines.Count; $i++) { if ($plines[$i] -match '^current:') { $cur = $i; break } }
    if ($cur -ge 0) { $plines[$cur] = "current: $uid" } else { $plines.Insert(0, "current: $uid") }
    Write-Text $pPath (($plines -join "`n") + "`n")

    # 预放规则缓存（缺哪个下哪个；下不到就等 Clash 启动后经代理自己下）
    New-Item -ItemType Directory -Force -Path "$VergeDir\ruleset" | Out-Null
    foreach ($r in $RuleSets) {
        $dest = "$VergeDir\ruleset\$($r.File)"
        if (Test-Path $dest) { continue }
        Say "  下载规则集 $($r.File)…"
        foreach ($u in $r.Raw, $r.Cdn) {
            $code = curl.exe -s -L --connect-timeout 8 -m 60 -o $dest -w '%{http_code}' $u
            if ($code -eq '200' -and (Test-Path $dest) -and (Get-Item $dest).Length -gt 0) { break }
            Remove-Item $dest -ErrorAction SilentlyContinue
        }
        if (Test-Path $dest) { Say '    已下载' } else { Say '    没下到，Clash 启动后会自己经代理下载' 'Yellow' }
    }

    Say ''
    Say '=== 配置完成，接下来请手动做三件事 ===' 'Green'
    Say '  1. 打开 Clash Verge（会自动启用「组合配置」）。'
    Say '  2. 马上到「代理」页，在 AI 组里选一个节点（AI 组默认是「拒绝」，不选的话 AI 服务都连不上）。'
    Say '     「其他」组也要选好：Google（包括 Gemini）都走它，选一个在支持 Gemini 的地区、能正常打开 Google 的节点。'
    Say '  3. 回首页打开「虚拟网卡模式」（TUN；第一次会要求安装服务）。'
    Say "  然后运行  powershell -ExecutionPolicy Bypass -File .\Setup-ClashAI.ps1 -Verify  检查。"
    Say "  恢复原样：退出 Clash Verge，把 $backup 里的文件拷回 $VergeDir（网卡原来的跃点数和 IPv6 设置记在同目录的两个 json 里）。"
    Pause-End
} catch {
    Say ''
    Say "出错：$($_.Exception.Message)" 'Red'
    Say ("位置：第 {0} 行  {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim()) 'DarkGray'
    Pause-End
    exit 1
} finally {
    try { [Console]::OutputEncoding = $OldOutputEncoding } catch {}
}
