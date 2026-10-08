# RegionSpoof — 在国行 Mac(macOS 27)上恢复 Apple 智能资格

一个极简内核扩展(kext),在 **IORegistry 源头**把设备区域码从 `CH/A` 改成 `LL/A`(美版),
让 MobileGestalt 对全系统每个进程都返回美版区域,从而让国行机通过 Apple Intelligence
的设备区域资格门。**它解决的是资格层，不是 Apple 服务端或 Private Cloud Compute(PCC)
的网络层。**端侧模型可用但联网 AI 不可用时，先用本项目的 PCC 诊断器分类，不要把
`GREYMATTER=4` 误当成“云端一定可用”。

## macOS 27 RC 现状（26A428）

在本机 Mac15,9 / M3 Max 上，RC 版一切正常：kext 已加载，`region-info=LL/A`，`GREYMATTER=4`，
端侧模型与 PCC 云端功能均可用。Beta 4 期间出现过的云端请求超时（中继 / 证明冷启动慢于调用方超时）
在 RC 上没有复现。若你的机器仍遇到云端功能报错，用 `sudo ./install.sh pcc` 分类后对照「故障排查」处理，
不要删证明库或连续重试。

## 快速安装(一键,推荐)

```bash
sudo ./install.sh
```

脚本自动完成:检查 SIP / Apple Silicon、**移除会杀死 PCC 的 `amfi_get_out_of_my_way` boot-arg**、
安装 kext + 配置开机自启、加载并刷新 Apple 智能守护进程。首次会提示你去
「系统设置 → 隐私与安全性」点一次 **允许** 后重启。

```bash
sudo ./install.sh status      # 体检:SIP / AMFI / region / kext / 资格 一览
sudo ./install.sh diagnose    # 一键诊断:把所有关键状态打成一段纯文本(报 issue 直接贴这个)
sudo ./install.sh pcc         # 只读分类最近 30 分钟 PCC/中继/令牌状态
sudo ./install.sh uninstall   # 卸载,恢复原始区域
```

> 推荐前提:恢复模式里运行 `csrutil enable --without kext`，只关闭 kext 签名检查。完整
> `csrutil disable` 也能运行，但关闭的保护超过本项目所需。脚本现在可识别这两种状态。

## 原理

- 资格门的根因:`MGGetStringAnswer("RegionCode") == "CH"` → Apple 智能被关。
- 该值**实时**来自 IORegistry `IOPlatformExpertDevice` 的 `region-info` 属性(`"CH/A"`),
  并非任何 plist 缓存(macOS 27 的 eligibilityd 基于 SwiftData 实时重算,旧的改 plist / 锁
  uchg 方法全部失效)。
- 本 kext 匹配 `IOPlatformExpertDevice`,在 `start()` 里
  `setProperty("region-info", "LL/A")` + `setProperty("country-of-origin", "USA")`
  —— 全系统进程从**源头**读到美版,资格 / 模型下发 / 前端 UI 自然一通百通,无需逐进程注入。

## 文件

| 路径 | 作用 |
|------|------|
| `install.sh` | **一键安装 / 卸载 / 体检脚本** |
| `pcc-diagnose.sh` | PCC/隐私中继/证明节点只读分类器，不输出请求内容 |
| `tests/test-pcc-diagnose.sh` | PCC 分类器离线夹具测试 |
| `perapp-zh/` | **逐 App 汉化**：全局保持英文保资格，Finder / 自带 App / 小组件 / 系统设置界面中文；一键回退（见 [perapp-zh/README.md](perapp-zh/README.md)） |
| `src/RegionSpoof.cpp` | kext 源码(IOService,改 `region-info`) |
| `src/kmod_info.c` | kext 入口声明,提供链接必需的 `_kmod_info` 符号 |
| `src/Info.plist` | kext bundle 的 Info.plist(IOKitPersonalities 匹配 IOPlatformExpertDevice) |
| `BUILD.md` | 完整编译 / 链接命令 |
| `RegionSpoof.kext/` | 已编译好的 kext(arm64e,ad-hoc 签名) |
| `com.local.regionkext.plist` | LaunchDaemon,开机早期自动加载 kext 并刷新 AI 守护进程 |
| `region-kext-load.sh` | LaunchDaemon 调用的加载脚本 |

## 前置条件(Apple Silicon)

1. **允许第三方 kext** —— 推荐在恢复模式(1TR)运行 `csrutil enable --without kext`；如系统
   不接受再用 `csrutil disable`。前者保留更多 SIP 保护。
2. `nvram boot-args` 里**不能**有 `amfi_get_out_of_my_way=1`。安装器只检测并移除这个显式
   AMFI 绕过参数；它不会再仅凭 boot-arg 为空就宣称“AMFI/PCC 已正常”。
3. kext 首次加载需在 **系统设置 → 隐私与安全性** 里点 **Allow** 后重启。
4. **Apple 账户「媒体与购买项目」地区必须是 Apple 智能支持区(不能是中国/CN)** —— 改成
   美国 / 日本等(系统设置 → 顶部你的名字 → 媒体与购买项目 → 管理 → 国家/地区)。
5. **系统语言 == Siri 语言,且为 Apple 智能支持的语言** —— 最稳是两者都设成 English (US)。
   想保留中文界面又不掉新 Siri，见下方「中文界面」一节（`perapp-zh/`），**不要改全局语言**。

> ⚠️ **kext 只负责"区域"这一项。** GREYMATTER 资格要 ~10 个输入(区域、账户地区、语言匹配、
> 设备类型……)**全部满足**才会变 4。若装好后 `region=LL/A` 和 kext 都已就位、但 `GREYMATTER`
> 仍是 `2`,八成卡在**账户地区或语言**上。跑这条查看各项输入（最终仍以 domain answer 为准；
> 个别输入为 `2` 不一定能单独解释整个域）:
>
> ```bash
> sudo /usr/libexec/PlistBuddy -c "Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:status" \
>   /private/var/db/eligibilityd/eligibility.plist
> ```
>
> 改完对应设置后,`sudo launchctl kickstart -k system/com.apple.eligibilityd` 或重启即可。

## 手动安装(可选)

```bash
sudo cp -R RegionSpoof.kext /Library/Extensions/
sudo chown -R 0:0 /Library/Extensions/RegionSpoof.kext
sudo cp region-kext-load.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/region-kext-load.sh
sudo cp com.local.regionkext.plist /Library/LaunchDaemons/
sudo kmutil load -p /Library/Extensions/RegionSpoof.kext   # 首次提示去设置 Allow → 重启
```

## 验证

```bash
# region-info 应为 0x4c4c2f41 ("LL/A")
ioreg -ard1 -c IOPlatformExpertDevice | plutil -p - | grep region-info
# GREYMATTER 资格应为 4 (eligible)
sudo /usr/libexec/PlistBuddy -c 'Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:os_eligibility_answer_t' \
  /private/var/db/eligibilityd/eligibility.plist
```

## 中文界面（逐 App 汉化，不掉资格）

资格判定读的是**用户全局**的 `AppleLanguages` 与 Siri 语言，而新 Siri 的语言白名单目前只有英文。
系统语言一旦切成中文，新 Siri 就会掉——这一点已在 eligibilityd 里逐指令核实，界面语言和资格用的是
同一个值，没有"选中文但对检测器伪装英文"的余地。

`perapp-zh/` 反过来做：全局保持 English，把中文写进**每个 App 自己的偏好域**（等价于「语言与地区 →
应用程序」逐个添加），eligibilityd 不读这些域；系统设置这类被 Apple 硬排除的 App，由一个常驻代理带
`-AppleLanguages` 启动参数拉起，Dock 单图标、深链接不丢目标。所有改动记录在案，可一键回退。

```bash
cd perapp-zh
./perapp-zh.sh dry-run       # 只统计，不改任何东西
./perapp-zh.sh all           # Finder / Dock / 自带 App / 小组件 / 系统设置
./perapp-zh.sh third-party   # 第三方 App（范围大，单独开）
./perapp-zh.sh status        # 看当前状态与资格
./perapp-zh.sh revert        # 一键回退，逐项恢复原值
```

**不要**用 `sudo` 跑它（改的是当前用户偏好）。细节、边界与回退机制见 [perapp-zh/README.md](perapp-zh/README.md)。

## 故障排查

> **拿不准卡在哪,先跑一键诊断:** `sudo ./install.sh diagnose` —— 它把 SIP / AMFI / region / kext /
> GREYMATTER 逐项 / 语言与汉化状态 / PCC 日志一次性打成一段纯文本,对照下面各节即可定位。**提 issue 时也请直接贴这段输出**
> (分享前请脱敏),否则很难帮你诊断。

如果 `region=LL/A`、kext 已加载，但资格文件长期不更新，并检查到 `uchg` / 只读权限，
可参考[匿名案例：旧资格缓存锁定的检查与离线修复](docs/eligibility-cache-recovery.md)。
这是特定机器的额外排障，不是通用安装前置；先确认故障、完整备份，再恢复系统自行更新资格的能力。
公开分享诊断前请按教程删除账户、用户目录、设备标识等隐私信息。

### `region=LL/A` 和 kext 都已就位,但 `GREYMATTER` 仍是 `2`

区域只是 ~10 个资格输入之一,八成卡在**账户地区或语言**(见上方「前置条件」第 4/5 条)。
跑这条查看输入状态；不要把任意一个 `2` 直接当成根因，最终以 GREYMATTER 的 domain answer
为准。改完对应设置后 `sudo launchctl kickstart -k
system/com.apple.eligibilityd` 或重启:

```bash
sudo /usr/libexec/PlistBuddy -c "Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:status" \
  /private/var/db/eligibilityd/eligibility.plist
```

### `COUNTRY_LOCATION` 仍是 `2`(地理围栏)

`DEVICE_REGION_CODE` 由 kext 解决;`COUNTRY_LOCATION` 是另一回事:它由 `countryd` 根据定位服务、
周边 Wi-Fi、IP 等综合判断,**本项目不处理这一项**。看 `diagnose` 逐项输入里的
`OS_ELIGIBILITY_INPUT_COUNTRY_LOCATION`,是 `2` 就说明卡在这里。

- 自 27 beta 4 起有用户反馈不必再改定位,把代理按下一节配好就行(#80)。先试这个。
- 社区做法(**均未经本项目验证,自担风险**):
  1. 用 [wloc](https://github.com/OpenHRTT/wloc) 把定位改到美国,然后 `sudo killall locationd`,
     再 `sudo launchctl kickstart -k system/com.apple.eligibilityd`。只改定位不杀 `locationd` 无效(#73)。
  2. 把 `/private/var/db/com.apple.countryd/countryCodeCache.plist` 里的 `CN` 全改成 `US`,
     `chflags uchg` 锁定后重启(#40)。副作用:锁住的缓存系统无法再更新,且有人 24 小时后又回落。
  3. 完全重装 macOS 后立刻运行安装脚本,不给系统留下 Wi-Fi 痕迹(#36)。
- 直接改 `eligibility.plist` 里的数值没用,`eligibilityd` 会实时重算(#73)。

### 云端功能需要的代理写法(社区验证)

PCC 走的是 Apple 私有中继,普通的系统 HTTP 代理对它无效。多位用户反复验证出的组合(#49 #59 #80):

- **TUN / 增强模式 + 全局**。规则模式要给 Apple 相关域名补规则,最省事是全局。Surge 用户:只开增强模式,
  **不要**开 system proxy(#59)。
- **开机联网后立刻挂上代理**,再登录、再用 AI。节点要稳定且快,速度时快时慢会表现为时好时坏的报错(#49)。
- 反复失败时**别连点**,先 `sudo ./install.sh pcc` 分类;`32033` 是限流,等一段时间再试一次。
- Apple 的服务端围栏会变(#51 里 8/13 放开、8/14 又收紧),PCC 时好时坏不一定是本地问题。

### kext 没加载(`region` 仍是 CH)

- **kext 签名检查仍开启** → 回恢复模式运行 `csrutil enable --without kext`（或完整
  `csrutil disable`）；
- **没批准** → `kmutil load -p` 报 not approved → 系统设置 → 隐私与安全性 → **Allow** → 重启;
- **`Authenticating extension failed: Bad code signature`** → 先用 `csrutil status` 确认输出里
  `Kext Signing: disabled`。不要仅按“部分/完整 SIP”猜测；macOS 27 已有仅 kext 豁免成功案例；
- **系统版本差异** → 太新/太旧的 macOS 可能验签或 KPI 不符,需用 `BUILD.md` 从源码重编。

### PCC 云端功能报错(写作工具语气改写 / 图乐园 / Reframe 等)

**端侧模型正常并不能证明 PCC 正常。**先运行只读分类器，**别连环点**——每次失败都可能触发
Apple 后端限流:

```bash
sudo ./install.sh pcc                 # 默认最近 30 分钟
sudo ./install.sh pcc --since 2h      # 自定义窗口
```

| 分类 | 含义 | 解法 |
|---|---|---|
| `HEALTHY` | 最近请求完成了证明验证和 PCC 调用 | 云端链路在该时刻已实证可用 |
| `CALLER_TIMEOUT_PCC_LATE` | PCC 最终成功，但 Mail/调用应用已经先超时 | 只能算 PCC 基础链路通，不能算端到端成功；检查证明池/预取 |
| `RATE_LIMITED` | `32001` / `RetryAfter` | **停手**，按时间等待；没有时间时至少等数小时 |
| `RELAY_OR_INLINE_TIMEOUT` | `NWError 89` / `32057` / `32080`，或只收到不足 2 个内联节点 | 等令牌补充后只重试一次；检查当前中继/网络，不删库 |
| `ATTESTATION_CACHE_MISS` | 本地证明库暂时没有可用节点 | 让守护进程在线回填，先等待 |
| `PREFETCH_STALLED` | 后台预取持续超过 2 分钟但证明池仍为空 | 预取流卡在中继/服务端；不要删库，先处理网络路径或稍后再试 |
| `NO_RECENT_REQUEST` | 窗口内没有结束的 PCC 请求 | 触发一次不含隐私内容的联网操作，等约 60 秒再跑 |

> `Sandbox: privatecloudcomputed deny ... AppleKeyStoreUserClient` / `AKS Locked` 只作旁证，不能
> 单独判死刑：成功的 PCC 请求也可能伴随同类记录。旧版 README 的“删除证明池”步骤
> 已移除；对中继交付超时删库既不对因，还可能让冷启动更慢。

## 卸载

```bash
sudo launchctl bootout system/com.local.regionkext 2>/dev/null
sudo rm -f /Library/LaunchDaemons/com.local.regionkext.plist /usr/local/bin/region-kext-load.sh
sudo rm -rf /Library/Extensions/RegionSpoof.kext
sudo kmutil unload -b com.local.RegionSpoof 2>/dev/null
# 重启即恢复原区域
```

## 已知边界(实测确认)

- 本 kext 是 ad-hoc 签名，必须关闭 kext 签名检查；推荐 `csrutil enable --without kext`，不再
  要求完整 Permissive。不同机器若仍报签名错误，以 `csrutil status` 的 `Kext Signing` 行和
  本地安全策略为准。
- PCC 云端还依赖中继令牌、内联证明和 Apple 服务端状态；RegionSpoof 只负责资格门。切勿添加
  `amfi_get_out_of_my_way` boot-arg，但 boot-arg 为空也不是 PCC 成功证明。
- **"New Siri" 等候名单** 是 Apple 服务端分批下发,与本地改区域无关。
- **新 Siri 的语言白名单目前只有英文（en-\*）**，系统语言设为中文会直接掉新 Siri；要中文界面走 `perapp-zh/`，别改全局语言。
