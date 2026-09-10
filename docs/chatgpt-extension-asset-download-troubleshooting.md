# ChatGPT Extension 卡在 Apple Intelligence 资产下载状态的排障指南

本文用于诊断以下情况：

```text
Apple Intelligence assets need to finish downloading
```

或者 Siri 返回：

```text
Apple Intelligence support for ChatGPT is still downloading.
```

本文中的命令均为只读检查，不删除、不重命名、不替换 Apple Intelligence 系统资产。

## 1. 适用范围与实测环境

本文中的完整案例来自：

```text
Device: Mainland China retail Mac mini M4
Model Identifier: Mac16,10
Architecture: arm64
Memory: 16 GB
macOS: 27.0 Beta
Build: 26A5378j
System language: English (US)
Siri language: English (US)
```

不同设备、语言、系统 Build 和 ModelCatalog 版本，可能使用不同的资产数量、版本和下载大小。

## 2. 本案例的状态变化

```text
ChatGPT Provider unavailable = 0
        ↓
Provider 已允许使用，但 Extension 仍显示资产下载中

GMS unifiedReasons = assetIsNotReady
        ↓
Enhanced Siri 判断依赖资产尚未准备完成

currentOrchestrationMode = 2
desiredOrchestrationMode = 5
isAvailable = 0
        ↓
系统希望使用 Linwood，但仍运行 SAE 编排模式

ModelCatalog 检测到 generic_sparse 模型未 Ready
        ↓
com.apple.modelcatalog 新 Atomic Set 开始下载

Atomic Set 完成下载、解密、personalization、graft 和 lock
        ↓
GMS unifiedReasons = []
currentOrchestrationMode = 5
isAvailable = 1
unavailabilityReasons = 0
        ↓
ChatGPT Extension 从“资产下载中”变为可点击 Turn On
```

## 3. 检查 ChatGPT Provider

```zsh
/usr/bin/defaults read \
    com.apple.generativepartnerservicesettings 2>&1
```

重点查看：

```text
AllLLMUISettings
└── com.apple.openai.chatgpt
    ├── unavailable
    └── enablementCount
```

- `unavailable = 1`：Provider 仍受到地区、资格或 Provider 状态限制。
- `unavailable = 0`：Provider 已允许显示和启用，但不代表模型资产已经准备完成。

Provider 已通过但界面仍提示下载资产时，应继续检查 GMS、SiriAvailability 和 ModelCatalog。

## 4. 检查 GMS Enhanced Siri 阻断原因

```zsh
GMS="$HOME/Library/Preferences/com.apple.gms.availability.plist"

/usr/bin/python3 - "$GMS" <<'PY_GMS'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])

if not path.exists():
    print("GMS plist absent")
    raise SystemExit(0)

with path.open("rb") as handle:
    data = plistlib.load(handle)

value = data.get(
    "com.apple.gms.enhancedSiri.unifiedReasons",
    "<ABSENT>",
)

if isinstance(value, bytes):
    try:
        value = value.decode("utf-8")
    except Exception:
        value = repr(value)

print(value)
PY_GMS
```

典型故障状态：

```json
[{"restricted":{"_0":{"assetIsNotReady":{}}}}]
```

成功状态通常为：

```text
[]
```

或者该值中不再包含 `assetIsNotReady`。

## 5. 检查 SiriAvailability

```zsh
/usr/bin/defaults read \
    com.apple.assistant.backedup \
    SiriAvailability 2>&1
```

典型故障状态：

```text
currentOrchestrationMode = 2
desiredOrchestrationMode = 5
isAvailable = 0
```

成功状态：

```text
currentOrchestrationMode = 5
desiredOrchestrationMode = 5
desiredOrchestrationModeIfEnabled = 5
isAvailable = 1
restrictionReasons = 0
unavailabilityReasons = 0
```

最终应结合以下字段判断：

```text
currentOrchestrationMode
desiredOrchestrationMode
isAvailable
restrictionReasons
unavailabilityReasons
```

## 6. 检查 ModelCatalog 的 Apple Intelligence 用例

macOS 27 的部分 Apple Intelligence 用例会请求 `generic_sparse` 模型变体。在本案例中观察到的相关 AssetSpecifier 包括：

```text
base.generic_sparse
proofreading_review.generic_sparse
embedding_preprocessor.generic_sparse
summarization.generic_sparse
mail_reply.generic_sparse
messages_action.generic_sparse
lw_planner.generic_sparse
```

检查相关日志：

```zsh
sudo /usr/bin/log show \
    --last 30m \
    --style compact \
    --info \
    --debug \
    --predicate '
        process == "modelcatalogd"
        OR process == "mobileassetd"
    ' 2>&1 |
/usr/bin/grep -Eai \
    'com\.apple\.Settings\.AppleIntelligence|generic_sparse|assetIsNotReady|is NOT ready|missing:|setIdentifier:com\.apple\.modelcatalog' |
/usr/bin/tail -n 1500
```

`FM.GenerativeModels availableForUse = Y` 只表示当前模型集合中存在可用资产，不保证每一个具体 use case 所需的模型变体均已下载并激活。

## 7. 精确检查 com.apple.modelcatalog Atomic Set

必须限定 `com.apple.modelcatalog`，避免把 `OSEligibility` 等其他 MobileAsset 任务误判为模型下载失败：

```zsh
sudo /usr/bin/log show \
    --last 60m \
    --style compact \
    --info \
    --debug \
    --predicate 'process == "mobileassetd"' 2>&1 |
/usr/bin/grep -E \
    'setIdentifier:com\.apple\.modelcatalog|com\.apple\.modelcatalog' |
/usr/bin/grep -Eai \
    'Starting next download|latestDownloaded:[YN]|fullyDownloaded:[YN]|SET-DOWNLOAD|job has finished|personalize\+graft|successful set-lock' |
/usr/bin/tail -n 1200
```

下载中：

```text
latestDownloaded:N
fullyDownloaded:N
Starting next download
```

Atomic Set 完整下载成功：

```text
latestDownloaded:Y
fullyDownloaded:Y
onFilesystem:Y
incomplete:N
SET-DOWNLOAD | SUCCESS
job has finished | SUCCESS(DOWNLOADED)
```

完成激活：

```text
personalize+graft|mount set SUCCESS
successful set-lock
atomic_instance_latest.locker
```

## 8. 本案例观察到的下载结果

在 macOS 27 build `26A5378j` 上，本案例观察到：

```text
新 ModelCatalog Atomic Set：111 个条目
base.generic_sparse：约 5.64 GB
最终 Catalog 请求：HTTP 200
最终 Atomic Set：fullyDownloaded:Y
最终任务：SUCCESS(DOWNLOADED)
最终 personalization、graft 和 set-lock：SUCCESS
```

这些数字仅代表本案例，不能据此断言所有设备都使用相同的条目数、模型大小、版本或下载顺序。

## 9. Pallas HTTP 401 的解释边界

本案例早期曾观察到：

```text
MADownloadServerAuthFailure(41)
HTTP 401
```

但后续 `FM.GenerativeModels` Catalog 请求恢复为 HTTP 200，并完成资产下载。

因此：

- 历史 401 不等于当前请求仍失败。
- 旧 `newerVersionError` 不等于当前下载正在失败。
- Catalog 请求和 CDN 文件下载属于不同阶段。
- 不能仅凭单个 401 认定代理、SIP 或硬件是唯一原因。

应检查同一 AssetType 最近一次请求的实际结果。

## 10. 常见误判

### Provider 可用不等于模型 Ready

`unavailable = 0` 只说明 ChatGPT Provider 没有被禁用。

### Descriptor 存在不等于 Atomic Set 已激活

下载过程中可能出现：

```text
isOnFilesystem = True
neverBeenLocked = True
locker = 0
```

这可能只是 Atomic Set 尚未完成提交。

### 暂时没有 Locker 不等于资产损坏

应继续等待：

```text
fullyDownloaded:Y
graft SUCCESS
set-lock SUCCESS
```

### 无关任务失败不等于 ModelCatalog 失败

例如：

```text
com.apple.MobileAsset.OSEligibility
FAILED(RELEASED_GRANT)
```

必须结合准确的 AssetType 和 `setIdentifier` 判断，不能仅凭通用的 `job has finished` 字段归因。

### 其他语言 NOT ready 不一定阻断当前 Siri 语言

ModelCatalog 可能同时扫描多种语言、多个系统应用和多个可选 use case。最终应结合当前 Siri locale、GMS 和 SiriAvailability 判断。

### `Unable to Sign In` 属于账户授权阶段

当界面已经出现 `Turn On`，但随后显示：

```text
Unable to Sign In
Sign In Canceled
```

说明 Apple Intelligence 资产主链路已经恢复。该状态属于 ChatGPT 账户授权阶段，不再属于资产下载故障。

## 11. 不应执行的操作

排查此问题时，不应：

```text
删除 /System/Library/AssetsV2
删除 /private/var/MobileAsset
删除 /private/var/db/os_eligibility
把 generic 文件重命名为 generic_sparse
手工复制或替换 Apple 模型文件
反复清除整个 GMS domain
在下载过程中强制终止 mobileassetd
强制写入 ChatGPT isEnabled
```

这些操作可能破坏 Descriptor、Atomic Set coherence、Personalization、Graft、Lock 和 ModelCatalog metadata。

## 12. 本案例最终成功状态

```text
GMS unifiedReasons = []

currentOrchestrationMode = 5
desiredOrchestrationMode = 5
desiredOrchestrationModeIfEnabled = 5
isAvailable = 1
restrictionReasons = 0
unavailabilityReasons = 0

ChatGPT Provider unavailable = 0
```

最终界面由资产下载提示变为：

```text
To use ChatGPT, you'll need to enable it first.
Turn On
```

这说明 ChatGPT Provider 资格状态通过、Enhanced Siri 资产限制解除、Linwood 编排模式启用，ChatGPT Extension 已进入正常用户启用阶段。

## 13. 隐私与结论边界

公开 Issue 或 Pull Request 时，不应上传：

```text
Apple Account 或 OpenAI 邮箱
手机号、序列号和 UDID
公网 IP、VPS IP 和代理订阅地址
Cookie、OAuth code 和访问令牌
设备证明原文
Apple 模型、AEA 文件或 Cryptex DMG
```

本文是单设备、单 Build 的实测案例。推荐使用“在本案例中”“根据当前日志”“在 build 26A5378j 上观察到”等表述，不应将单设备观测写成所有设备的统一规则。
