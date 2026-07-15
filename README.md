# RegionSpoof — 在国行 Mac(macOS 27)上开启完整 Apple 智能

一个极简内核扩展(kext),在 **IORegistry 源头**把设备区域码从 `CH/A` 改成 `LL/A`(美版),
让 MobileGestalt 对全系统每个进程都返回美版区域,从而在国行机
(本机 Mac15,9 / M3 Max / macOS 27 26A5353q)上启用**完整的 Apple Intelligence**——
端侧 + Private Cloud Compute 云端全功能(写作工具含语气改写、图乐园、Genmoji、
Foundation Models、ChatGPT 扩展)。

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
sudo ./install.sh uninstall   # 卸载,恢复原始区域
```

> 前提:SIP 已关闭(恢复模式里 `csrutil disable`)。脚本若检测到未关,会给出分步指引。

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
| `src/RegionSpoof.cpp` | kext 源码(IOService,改 `region-info`) |
| `src/kmod_info.c` | kext 入口声明,提供链接必需的 `_kmod_info` 符号 |
| `src/Info.plist` | kext bundle 的 Info.plist(IOKitPersonalities 匹配 IOPlatformExpertDevice) |
| `BUILD.md` | 完整编译 / 链接命令 |
| `RegionSpoof.kext/` | 已编译好的 kext(arm64e,ad-hoc 签名) |
| `com.local.regionkext.plist` | LaunchDaemon,开机早期自动加载 kext 并刷新 AI 守护进程 |
| `region-kext-load.sh` | LaunchDaemon 调用的加载脚本 |

## 前置条件(Apple Silicon)

1. **SIP 关闭 + Permissive 安全模式 + 允许第三方 kext** —— 恢复模式(1TR)里 `csrutil disable`
   一条即可全设。
2. **AMFI 必须保持开启** —— `nvram boot-args` 里**不能**有 `amfi_get_out_of_my_way=1`。
   AMFI 一关,SEP 会拒绝给 Private Cloud Compute 出硬件证明(日志表现为
   `AppleKeyStore kIOReturnNotPermitted`),**云端 AI 全部失效**;端侧仍可用。
3. kext 首次加载需在 **系统设置 → 隐私与安全性** 里点 **Allow** 后重启。
4. **Apple 账户「媒体与购买项目」地区必须是 Apple 智能支持区(不能是中国/CN)** —— 改成
   美国 / 日本等(系统设置 → 顶部你的名字 → 媒体与购买项目 → 管理 → 国家/地区)。
5. **系统语言 == Siri 语言,且为 Apple 智能支持的语言** —— 最稳是两者都设成 English (US)。

> ⚠️ **kext 只负责"区域"这一项。** GREYMATTER 资格要 ~10 个输入(区域、账户地区、语言匹配、
> 设备类型……)**全部满足**才会变 4。若装好后 `region=LL/A` 和 kext 都已就位、但 `GREYMATTER`
> 仍是 `2`,八成卡在**账户地区或语言**上。跑这条看是哪一项没过(值为 `2` 的就是它):
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

## 故障排查

### ChatGPT Extension 一直显示资产正在下载

如果 ChatGPT Provider 已显示 `unavailable = 0`，但仍提示
`Apple Intelligence assets need to finish downloading`，可以继续检查
GMS、`SiriAvailability` 和 `com.apple.modelcatalog` Atomic Set。

详见：

[ChatGPT Extension 资产下载专项排障指南](docs/chatgpt-extension-asset-download-troubleshooting.md)


> **拿不准卡在哪,先跑一键诊断:** `sudo ./install.sh diagnose` —— 它把 SIP / AMFI / region / kext /
> GREYMATTER 逐项 / 模型大小 / PCC 日志一次性打成一段纯文本,对照下面各节即可定位。**提 issue 时也请直接贴这段输出**
> (无隐私信息),否则很难帮你诊断。

### `region=LL/A` 和 kext 都已就位,但 `GREYMATTER` 仍是 `2`

区域只是 ~10 个资格输入之一,八成卡在**账户地区或语言**(见上方「前置条件」第 4/5 条)。
跑这条看哪一项没过(值为 `2` 的就是它),改完对应设置后 `sudo launchctl kickstart -k
system/com.apple.eligibilityd` 或重启:

```bash
sudo /usr/libexec/PlistBuddy -c "Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:status" \
  /private/var/db/eligibilityd/eligibility.plist
```

### kext 没加载(`region` 仍是 CH)

- **SIP 没关** → `csrutil status` 须为 disabled;没关就回恢复模式 `csrutil disable`;
- **没批准** → `kmutil load -p` 报 not approved → 系统设置 → 隐私与安全性 → **Allow** → 重启;
- **`Authenticating extension failed: Bad code signature`** → 你处于 Reduced Security(部分关 SIP),
  ad-hoc kext 不放行;**必须 Permissive(完整关 SIP)**,想 SIP-on 则需 Developer-ID 正经签名;
- **系统版本差异** → 太新/太旧的 macOS 可能验签或 KPI 不符,需用 `BUILD.md` 从源码重编。

### PCC 云端功能报错(写作工具语气改写 / 图乐园 / Reframe 等)

**端侧(校对/摘要/Genmoji)不受影响。** PCC 出问题先看日志定位,**别连环点**——每次失败都可能触发
Apple 后端限流,越点越坏:

```bash
sudo log show --last 3m --predicate 'process == "privatecloudcomputed"' 2>/dev/null \
  | grep -iE 'finished successfully|3200[0-9]|RetryAfter|NWError|3205[0-9]|Insufficient inline|32080' | tail -15
```

| 日志特征 | 含义 | 解法 |
|---|---|---|
| `Ropes request finished successfully` | ✅ 正常 | — |
| `32001` + `RetryAfterDate` | 被 Apple 限流(请求太频繁/失败太多) | **停手**,等几小时 / 过夜 |
| `Insufficient inline attestations` / `32080` | 证明池陈旧或没热 | 见下方**重置证明池** |
| `32057` + `NWError` / 大量 `cancelled` | 网络到 Apple 中继不通 | 换**支持区**网络(美/日节点或直连),别用香港等非支持区 |

> 另外:PCC 还要求 **AMFI 开启**(前置条件第 2 条)。"Internet Connection Required" 多半也是上面这些(不是真没网)。

**重置证明池**(`Insufficient` / 反复折腾后 PCC 一直 flaky 时的杀手锏):

```bash
# 1) 先定位证明库(趁 daemon 还活着;容器 UUID 各机不同)
DIR="$(sudo lsof -c privatecloudcomputed -Fn 2>/dev/null | sed -n 's/^n//p' | grep -m1 -oE '.*/attestationstore_v3')"
# 2) 停 daemon → 删陈旧证明库 + 收到的节点缓存
sudo launchctl kill KILL system/com.apple.privatecloudcomputed
sudo rm -f "$DIR"/db.sqlite* "$(dirname "$DIR")"/nodesReceived.log
# 3) 重启,然后晾 15~30 分钟让它联网重建一池干净证明,再试(别马上猛点)
```

## 卸载

```bash
sudo launchctl bootout system/com.local.regionkext 2>/dev/null
sudo rm -f /Library/LaunchDaemons/com.local.regionkext.plist /usr/local/bin/region-kext-load.sh
sudo rm -rf /Library/Extensions/RegionSpoof.kext
sudo kmutil unload -b com.local.RegionSpoof 2>/dev/null
# 重启即恢复原区域
```

## 已知边界(实测确认)

- **SIP 必须保持关闭(Permissive)。** 本 kext 是 ad-hoc 签名;切到 Reduced Security(SIP 开)
  会以 `Authenticating extension failed: Bad code signature` 拒绝它,区域退回 CH、AI 关闭。
  要在 SIP 开启下使用,必须用 **Apple Developer ID($99/年)** 给 kext 正经签名后再走
  Reduced Security。
- **PCC 云端功能(语气改写 / 图乐园)依赖 AMFI 开启。** 切勿添加
  `amfi_get_out_of_my_way` boot-arg。
- **"New Siri" 等候名单** 是 Apple 服务端分批下发,与本地改区域无关。
