# enableMacosAI：在国行 Mac（macOS 27）上恢复 Apple 智能资格

本项目用一个极简内核扩展 RegionSpoof（kext），在 **IORegistry 源头**把设备区域码从 `CH/A` 改成
`LL/A`（美版），让 MobileGestalt 对全系统每个进程都返回美版区域，从而让国行机通过 Apple 智能的
设备区域资格门。

**它解决的是资格层，不是 Apple 服务端或 Private Cloud Compute（PCC）的网络层。**`GREYMATTER=4`
只说明资格通过，不代表云端功能一定可用；联网功能报错时请看「故障排查」里的 PCC 一节。

> **只有国行机型需要它。**在「系统信息 → 硬件」里看型号编号，以 `CH/A` 结尾才是国行。港版（`ZP/A`）
> 等非国行机型本身就有资格，在大陆用不了多半是网络问题，见「故障排查」的 PCC 一节，不需要关 SIP
> 装本项目。

## 当前状态

- **macOS 27.2 Beta（26B5101f）**：在 Mac15,9 / M3 Max 上 kext 已加载、`region-info=LL/A`、
  `GREYMATTER=4`，端侧模型与 PCC 云端功能均可用。

## 前置条件（Apple Silicon）

1. **允许第三方 kext。**这是两道独立的闸门，都在恢复模式（1TR）里开，**顺序不能反**（#79）：
   1. 启动安全性实用工具 → 选当前系统 → 安全策略 →「降低安全性」，勾选
      「允许用户管理来自被认可开发者的内核扩展」；
   2. 在同一次恢复模式里打开终端，运行 `csrutil enable --without kext`（第 1 步会重置 SIP 设置，
      所以必须在它之后）。系统不接受时再用 `csrutil disable`，后者关闭的保护超过本项目所需。

   配置后 `csrutil status` 里 Kernel Integrity Protections 也会显示 disabled，这是该命令本身的行为；
   本地启动策略会是 **Permissive**，不是 Reduced。代价是**为 iPhone / iPad 设计的 App 在这台 Mac 上
   无法打开**（#111），目前没有既加载本 kext 又保持 Reduced 的办法。
2. **`nvram boot-args` 里不能有 `amfi_get_out_of_my_way=1`**，它会破坏 PCC。安装器会检测并移除它。
3. **首次加载要批准。**在「系统设置 → 隐私与安全性」底部点 **允许 / Allow**，然后重启，首次可能要
   重启两次。如果那里只有「启用系统扩展… / Enable System Extensions…」按钮，说明第 1 条的第一道
   闸门没开。
4. **Apple 账户「媒体与购买项目」地区必须是 Apple 智能支持区**，不能是中国。改成美国、日本等：
   系统设置 → 顶部你的名字 → 媒体与购买项目 → 管理 → 国家/地区。
5. **系统语言与 Siri 语言一致，且是 Apple 智能支持的语言**，最稳是两者都设成 English (US)。新 Siri
   目前只认英文。想要中文界面请看「中文界面」一节，**不要改全局语言**。

## 安装

### 一键安装（推荐）

```bash
sudo ./install.sh
```

脚本会检查 Apple Silicon、SIP 与第三方 kext 启动策略，移除 `amfi_get_out_of_my_way`，安装 kext
并配置开机自启，然后加载 kext、刷新 Apple 智能守护进程。首次运行会提示你去批准并重启（前置条件
第 3 条），重启后再运行一次即可。加载失败时，脚本会区分「未批准」「已批准待重启」「启动策略未允许
第三方 kext」三种情况，分别给出处理步骤。

### 常用命令

```bash
sudo ./install.sh status      # 体检：SIP / AMFI / region / kext / 资格 / 开机自启
sudo ./install.sh diagnose    # 一键诊断：全部关键状态打成一段纯文本，报 issue 直接贴这个
sudo ./install.sh pcc         # 只读分类最近 30 分钟的 PCC / 中继 / 令牌状态
sudo ./install.sh uninstall   # 卸载，重启后恢复原始区域
```

安装后的预期结果：`status` 里 `region=LL/A` 为「是」、kext 已加载、`GREYMATTER` 为 4。

### 升级与系统更新

- **升级本项目**：拉取新版本后重新运行 `sudo ./install.sh`，不用先卸载。脚本会比较已安装的 kext，
  没变就跳过；二进制变了会提示你重新允许并重启。
- **macOS 更新后**：第一次开机系统要重建扩展缓存，AI 可能暂时失效，**再重启一次**通常就恢复
  （#113）。仍不行再跑 `sudo ./install.sh status`。

### 手动安装（可选）

```bash
sudo cp -R RegionSpoof.kext /Library/Extensions/
sudo chown -R 0:0 /Library/Extensions/RegionSpoof.kext
sudo mkdir -p /usr/local/bin   # 干净系统上这个目录可能不存在
sudo cp region-kext-load.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/region-kext-load.sh
sudo cp com.local.regionkext.plist /Library/LaunchDaemons/
sudo kmutil load -p /Library/Extensions/RegionSpoof.kext   # 首次会提示去设置里允许，然后重启
```

不用安装器时，手动核对结果：

```bash
# region-info 应为 0x4c4c2f41（"LL/A"）
ioreg -ard1 -c IOPlatformExpertDevice | plutil -p - | grep region-info
# GREYMATTER 资格应为 4
sudo /usr/libexec/PlistBuddy -c 'Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:os_eligibility_answer_t' \
  /private/var/db/eligibilityd/eligibility.plist
```

### 手动卸载（可选）

优先用 `sudo ./install.sh uninstall`。手动操作如下，重启后恢复原区域：

```bash
sudo launchctl bootout system/com.local.regionkext 2>/dev/null
sudo kmutil unload -b com.local.RegionSpoof 2>/dev/null
sudo rm -f /Library/LaunchDaemons/com.local.regionkext.plist /usr/local/bin/region-kext-load.sh
sudo rm -rf /Library/Extensions/RegionSpoof.kext
```

## 中文界面（逐 App 汉化，不掉资格）

资格判定读的是**用户全局**的 `AppleLanguages` 与 Siri 语言，而新 Siri 的语言白名单目前只有英文。
系统语言一旦切成中文，新 Siri 就会掉。这一点已在 eligibilityd 里逐指令核实：界面语言和资格用的是
同一个值，没有「选中文但对检测器伪装英文」的余地。

`perapp-zh/` 反过来做：全局保持 English，把中文写进**每个 App 自己的偏好域**，等价于在「语言与地区
→ 应用程序」里逐个添加，eligibilityd 不读这些域。系统设置这类被 Apple 硬排除的 App，由一个常驻代理
带 `-AppleLanguages` 启动参数拉起，Dock 里只有一个图标，深链接也不丢目标。所有改动记录在案，可一键回退。

```bash
cd perapp-zh
./perapp-zh.sh dry-run       # 只统计，不改任何东西
./perapp-zh.sh all           # Finder / Dock / 自带 App / 小组件 / 系统设置
./perapp-zh.sh third-party   # 第三方 App（范围大，单独执行）
./perapp-zh.sh status        # 查看当前状态
./perapp-zh.sh revert        # 一键回退，逐项恢复原值
```

**不要**用 `sudo` 运行它，它改的是当前用户的偏好。细节、边界与回退机制见
[perapp-zh/README.md](perapp-zh/README.md)。

## 故障排查

拿不准卡在哪，先跑一键诊断：

```bash
sudo ./install.sh diagnose
```

它把 SIP、AMFI、本地启动策略、region、kext、开机加载日志、资格逐项输入、语言与汉化状态、PCC 分类
一次性打成一段纯文本，对照下面各节即可定位。**提 issue 时请贴这段输出**，分享前先检查并去掉你不想
公开的信息。

### kext 没加载（`region` 不是 LL/A）

- **kext 签名检查仍开启**：回恢复模式运行 `csrutil enable --without kext`，或完整 `csrutil disable`。
- **没批准**：`kmutil load -p` 报 not approved。去「隐私与安全性」点允许，然后重启。
- **隐私与安全性里找不到 RegionSpoof，只有「启用系统扩展…」**：第三方 kext 的启动策略没开。
  `diagnose` 的本地安全策略里会看到 `3rd Party Kexts Status: Disabled (smb2)`，开机日志里有
  `auxiliary extensions not allowed`。按「前置条件」第 1 条的顺序在恢复模式里处理（#79、#105）。
- **批准过了，重启后仍未加载**：看 `diagnose` 里「最近一次开机加载日志」，它会记录 `kmutil` 的原始
  报错。本地安全策略里只有 `auxp`、没有 `auxi` / `auxr`，说明批准了但扩展缓存没建成，再重启一次。
- **`Authenticating extension failed: Bad code signature`**：先确认 `csrutil status` 里是
  `Kext Signing: disabled`，不要只凭「部分 / 完整 SIP」猜测。
- **系统版本差异**：太新或太旧的 macOS 可能验签或 KPI 不符，需按 [BUILD.md](BUILD.md) 从源码重编。

### kext 已就位，但 `GREYMATTER` 仍是 2

区域只是约 10 个资格输入之一，八成卡在**账户地区或语言**上（前置条件第 4、5 条）。查看各项输入：

```bash
sudo /usr/libexec/PlistBuddy -c "Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:status" \
  /private/var/db/eligibilityd/eligibility.plist
```

`2` 表示不满足、`3` 表示满足，但个别输入为 2 不一定导致整个域失败，最终以 GREYMATTER 的 answer
为准。改完对应设置后运行 `sudo launchctl kickstart -k system/com.apple.eligibilityd`，或者重启。

### 资格文件被锁定

症状：`region=LL/A`，但 `DEVICE_REGION_CODE` 仍是 2，或者重启后又回退。

旧教程常让人 `chflags uchg` 锁定资格文件。锁住后 eligibilityd 写不进新结果，`status` / `diagnose`
读到的是锁定那天的旧值，可能一直是 2，也可能是一个过时的 4。现在 `status` 和 `diagnose` 发现这种
情况会直接标出「资格文件被锁定」并列出文件。

解锁即可，**不需要改权限**：正常状态下这些文件本来就是只读（`0444`，`root:_eligibilityd`），
eligibilityd 通过替换文件写入。

```bash
cd /private/var/db
sudo chflags nouchg,noschg eligibilityd/* os_eligibility/eligibility.plist
ls -lO eligibilityd os_eligibility        # 第 5 列应为 "-"，没有 uchg / schg
sudo chown _eligibilityd:_eligibilityd eligibilityd os_eligibility   # 仅当目录属主被改过时需要
sudo launchctl kickstart -k system/com.apple.eligibilityd
sudo ./install.sh status
```

`chflags` 报 `Operation not permitted` 时，先给「终端」开「完全磁盘访问权限」再试。仍不行说明带了
`schg`，需要进恢复模式临时 `csrutil disable` 后解锁，完成后再恢复原来的 SIP 设置（#20）。

### PCC 云端功能报错（写作工具语气改写、图乐园、Siri 联网回答等）

**端侧模型正常不能证明 PCC 正常。**PCC 走的是 Apple 私有中继，普通的系统 HTTP 代理对它无效。
多位用户反复验证出的代理写法（#49、#59、#80）：

- **TUN / 增强模式 + 全局。**规则模式要给 Apple 相关域名补规则，最省事是全局。Surge 用户只开
  增强模式，**不要**开 system proxy（#59）。
- **开机联网后立刻挂上代理**，再登录、再用 AI。节点要稳定且快，速度忽快忽慢会表现为时好时坏的报错（#49）。
- Apple 的服务端围栏会变（#51 里 8 月 13 日放开、14 日又收紧），时好时坏不一定是本地问题。

反复失败时**别连点**，每次失败都可能触发 Apple 后端限流。先用只读分类器判断卡在哪：

```bash
sudo ./install.sh pcc                 # 默认最近 30 分钟
sudo ./install.sh pcc --since 2h      # 自定义窗口
```

| 分类 | 含义 | 解法 |
|---|---|---|
| `HEALTHY` | 最近请求完成了证明验证和 PCC 调用 | 云端链路在该时刻已实证可用 |
| `CALLER_TIMEOUT_PCC_LATE` | PCC 最终成功，但调用方应用已经先超时 | 只能算 PCC 基础链路通，不算端到端成功；检查证明池和预取 |
| `RATE_LIMITED` | `32001` / `RetryAfter` | **停手**，按提示时间等待；没有时间时至少等几个小时 |
| `RELAY_OR_INLINE_TIMEOUT` | `NWError 89` / `32057` / `32080`，或只收到不足 2 个内联节点 | 等令牌补充后只重试一次；检查当前中继和网络，不删库 |
| `ATTESTATION_CACHE_MISS` | 本地证明库暂时没有可用节点 | 让守护进程在线回填，先等待 |
| `PREFETCH_STALLED` | 后台预取持续超过 2 分钟，证明池仍为空 | 预取卡在中继或服务端；不要删库，先处理网络路径或稍后再试 |
| `NO_RECENT_REQUEST` | 窗口内没有结束的 PCC 请求 | 触发一次不含隐私内容的联网操作，等约 60 秒再跑 |
| `PCC_REQUEST_FAILED` | 请求失败，但不符合以上任何已知模式 | 先确认代理配置；社区在 27.0.1 上用 `launchctl kickstart -k gui/$(id -u)/com.apple.privatecloudcomputed`（`networkserviceproxy`、`swtransparencyd` 同样处理）恢复过（#93） |

> `Sandbox: privatecloudcomputed deny ... AppleKeyStoreUserClient` / `AKS Locked` 只能作旁证：成功的
> PCC 请求也可能伴随同类记录。不要删除证明池，对中继交付超时删库既不对因，还可能让冷启动更慢。

## 原理

- 资格门的根因：`MGGetStringAnswer("RegionCode") == "CH"` 时 Apple 智能被关闭。
- 该值**实时**来自 IORegistry `IOPlatformExpertDevice` 的 `region-info` 属性（`"CH/A"`），不是任何
  plist 缓存。macOS 27 的 eligibilityd 基于 SwiftData 实时重算，旧的改 plist / 锁 uchg 方法全部失效。
- 本 kext 匹配 `IOPlatformExpertDevice`，在 `start()` 里执行 `setProperty("region-info", "LL/A")` 和
  `setProperty("country-of-origin", "USA")`。全系统进程从源头读到美版，资格、模型下发、前端 UI
  都随之生效，无需逐进程注入。

## 文件

| 路径 | 作用 |
|------|------|
| `install.sh` | 一键安装 / 升级 / 卸载 / 体检 / 诊断脚本 |
| `pcc-diagnose.sh` | PCC / 隐私中继 / 证明节点只读分类器，不输出请求内容 |
| `tests/test-pcc-diagnose.sh` | PCC 分类器离线夹具测试 |
| `perapp-zh/` | 逐 App 汉化，全局保持英文保资格，见 [perapp-zh/README.md](perapp-zh/README.md) |
| `RegionSpoof.kext/` | 已编译好的 kext（arm64e，ad-hoc 签名） |
| `src/RegionSpoof.cpp` | kext 源码（IOService，改 `region-info`） |
| `src/kmod_info.c` | kext 入口声明，提供链接必需的 `_kmod_info` 符号 |
| `src/Info.plist` | kext 的 Info.plist（IOKitPersonalities 匹配 IOPlatformExpertDevice） |
| `com.local.regionkext.plist` | LaunchDaemon，开机自动加载 kext 并刷新 AI 守护进程 |
| `region-kext-load.sh` | LaunchDaemon 调用的加载脚本，日志在 `/var/log/region-kext.log` |
| `BUILD.md` | 完整编译 / 链接命令 |

## 已知边界

- **安全策略**：本 kext 是 ad-hoc 签名，必须关闭 kext 签名检查并允许第三方 kext，本地启动策略最终
  都是 Permissive，iPhone / iPad App 因此无法在这台 Mac 上打开（#111）。
- **PCC 云端**还依赖中继令牌、内联证明和 Apple 服务端状态，本项目只负责资格门。boot-args 为空也
  不能证明 PCC 一定可用。
- **新 Siri 等候名单**由 Apple 服务端分批下发，与本地改区域无关。
- **新 Siri 的语言白名单目前只有英文（en-\*）**，系统语言设为中文会直接掉新 Siri；要中文界面用
  `perapp-zh/`，别改全局语言。
- **ChatGPT 扩展**的地区判断由 OpenAI 一侧决定，和 Apple 智能资格是两回事，本项目处理不了。社区
  经验是 ChatGPT 流量走支持地区的节点、用 TUN 模式或更换网络后有人恢复
  （#97、#108、#115）。写作工具在**空白内容**上调用 ChatGPT 会让 App 崩溃，是系统 bug（#112）。
