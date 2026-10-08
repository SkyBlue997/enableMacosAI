# 匿名案例：区域已变为 LL/A，但旧资格缓存仍被锁定

本文补充一次 macOS 27.0.1 / Apple Silicon 的安装排障经历。RegionSpoof 已加载，设备区域已变为 `LL/A`，但资格文件保留着历史的不可修改标志，系统无法正常更新答案。解除这些旧锁后，主资格文件重新生成，`GREYMATTER` 变为 `4`；用户随后确认功能已能正常使用。本文没有独立执行完整的端侧功能与 PCC 云端验收，不能将用户的完成反馈当成 PCC 诊断器的实测结果。

**这不是所有用户的安装前置步骤。** 正常安装仍按 [README](../README.md) 执行。只有只读检查确认出现本文同类问题，才使用下面的修复流程；旧锁的来源无法从文件标志和时间戳确定。

## 1. 分清安装、资格和功能就绪三个阶段

| 阶段 | 检查内容 | 能证明什么 |
| --- | --- | --- |
| 安装 | RegionSpoof 已加载，`region-info=LL/A` | 扩展正在运行，区域修改已生效 |
| 资格 | 最新的 `OS_ELIGIBILITY_DOMAIN_GREYMATTER:os_eligibility_answer_t=4` | Apple 智能的这项资格判定通过 |
| 功能就绪 | 设置完成后台资源准备，实际功能能够调用；PCC 另做一次诊断 | 相应功能可用；资格通过不能代替云端验收 |

`LL/A` 是资格输入之一，不等于所有资格条件、模型资源和 Apple 服务端均已就绪。安装器已经成功改区域时，重复安装不会自动清除历史资格文件的不可修改标志。

### 从零安装时的启动安全设置顺序

已经看到扩展加载成功和 `LL/A` 的用户可以跳过这一节，不必重新设置安全策略。

Apple Silicon Mac 关机后，长按电源键，选择 **Options → Continue** 进入恢复模式。先打开 **Utilities → Startup Security Utility**，选择对应系统，点击 **Security Policy**，选择 **Reduced Security**，勾选 **Allow user management of kernel extensions from identified developers**，验证并保存。之后再打开 **Utilities → Terminal**，按项目需要执行：

```sh
csrutil enable --without kext
csrutil status
```

检查实际输出，确认 `Kext Signing: disabled`，并逐项记录其他保护的状态。不能把这个命令绝对描述成“只关闭一项保护、其余全部不变”：本案例的输出还显示 `Kernel Integrity Protections: disabled`。若输出不符合预期，先保留错误并排查，不要直接扩大到完整关闭 SIP。先改启动安全策略、后设置 `csrutil` 例外，可以避免后续策略操作覆盖前面的设置。

完成后运行 `reboot`。按 README 安装后，首次扩展审批仍可能要求到 **System Settings → Privacy & Security** 点击 **Allow** 并正常重启。

## 2. 先用只读检查确认是否是同类故障

在项目目录运行：

```sh
sudo ./install.sh status
```

如果扩展已加载、区域已经是 `LL/A`，但 `GREYMATTER` 仍是 `2`，先检查主资格目录的五个文件：

```sh
sudo ls -leO \
  /private/var/db/eligibilityd/datastore.data \
  /private/var/db/eligibilityd/datastore.data-shm \
  /private/var/db/eligibilityd/datastore.data-wal \
  /private/var/db/eligibilityd/eligibility.plist \
  /private/var/db/eligibilityd/eligibility_inputs.plist

sudo /usr/libexec/PlistBuddy \
  -c 'Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER' \
  /private/var/db/eligibilityd/eligibility.plist
```

本案例的五个文件均为 `uchg`、`0444`（`-r--r--r--`），而时间戳长期停留在历史状态。`uchg` 是不可修改标志，会阻止系统更新文件；只读权限也是需要核对的文件状态。时间戳久远本身不是充分证据，例如 SQLite 主数据库可以保持旧时间戳，同时通过 WAL 写入新事务。

可再查看资格服务的近期错误：

```sh
sudo /usr/bin/log show --last 10m --style compact \
  --predicate 'process == "eligibilityd" AND (eventMessage CONTAINS "_onQueue_saveDomainAnswerOutputs" OR eventMessage CONTAINS "Code=513")'
```

本案例出现保存资格答案失败、`NSCocoaErrorDomain Code=513`、底层 `NSPOSIXErrorDomain Code=1`。**这些错误码单独不能证明旧锁是唯一原因。** 应结合具体目标文件、标志、权限及答案是否持续更新来判断；日志若把路径遮蔽为 `<private>`，不能猜测它指向哪个文件。其他目录中的兼容输出或镜像也不应被自动纳入本流程。

若文件没有本文的锁定状态，或资格文件已经正常更新，请回到 README 检查其他资格条件、模型与云端状态，不要执行下面的修改。

## 3. 准备一个仅修复这五个文件的脚本

先在正常桌面系统中查询**当前启动系统的数据卷 UUID**，保留在本地，供恢复模式识别同一卷使用：

```sh
AI_DATA_UUID="$(/usr/sbin/diskutil info -plist /System/Volumes/Data | /usr/bin/plutil -extract VolumeUUID raw -o - -)"
printf '%s\n' "$AI_DATA_UUID"
```

这是读者自己机器的 UUID，不要把它贴到公开 issue。不要使用别人的 UUID，也不要记下一个 `diskXsY` 后假定重启后编号不变。

将下面整个代码块在正常桌面系统的终端中运行。它只创建通用辅助脚本，尚不修改资格文件。若同名脚本已存在，创建步骤会停止，先检查已有文件内容，避免覆盖未知脚本。

```sh
(
  umask 077
  set -C
  cat > /Users/Shared/eligibility-cache-repair.sh <<'BASH'
#!/bin/bash
set -euo pipefail
umask 077

fail() { printf '停止：%s\n' "$*" >&2; exit 1; }
[ "$(/usr/bin/id -u)" -eq 0 ] || fail '需要管理员权限；恢复模式终端通常已是 root。'
[ "$#" -eq 2 ] || fail '用法：脚本 <数据卷实际装载点> <该数据卷 UUID>'

AI_DATA_MOUNT="${1%/}"
AI_EXPECTED_UUID="$2"
case "$AI_DATA_MOUNT" in /*) ;; *) fail '装载点必须是绝对路径。' ;; esac
[ -d "$AI_DATA_MOUNT" ] && [ ! -L "$AI_DATA_MOUNT" ] || fail '装载点缺失或为符号链接。'
AI_VOLUME_INFO="$(/usr/sbin/diskutil info -plist "$AI_DATA_MOUNT")"
AI_ACTUAL_UUID="$(printf '%s\n' "$AI_VOLUME_INFO" | /usr/bin/plutil -extract VolumeUUID raw -o - -)"
AI_ACTUAL_MOUNT="$(printf '%s\n' "$AI_VOLUME_INFO" | /usr/bin/plutil -extract MountPoint raw -o - -)"
[ "$AI_ACTUAL_UUID" = "$AI_EXPECTED_UUID" ] || fail '数据卷 UUID 不匹配。'
[ "$AI_ACTUAL_MOUNT" = "$AI_DATA_MOUNT" ] || fail '传入路径不是该卷的实际装载点。'

AI_ELIG_DIR="$AI_DATA_MOUNT/private/var/db/eligibilityd"
AI_SHARED_DIR="$AI_DATA_MOUNT/Users/Shared"
AI_FILES=(datastore.data datastore.data-shm datastore.data-wal eligibility.plist eligibility_inputs.plist)
for AI_DIR in "$AI_ELIG_DIR" "$AI_SHARED_DIR"; do
  [ -d "$AI_DIR" ] && [ ! -L "$AI_DIR" ] || fail "目录缺失或为符号链接：$AI_DIR"
done

# 此教程只支持本例的 uchg/0444，或已经部分修复的无标志/0644。
# 不处理 schg、restricted、其他标志、ACL 或不同的权限/所有者。
for AI_NAME in "${AI_FILES[@]}"; do
  AI_FILE="$AI_ELIG_DIR/$AI_NAME"
  [ -f "$AI_FILE" ] && [ ! -L "$AI_FILE" ] || fail "目标缺失、不是普通文件或为符号链接：$AI_NAME"
  AI_FLAGS="$(/usr/bin/stat -f '%Sf' "$AI_FILE")"
  case "$AI_FLAGS" in uchg|-) ;; *) fail "目标存在本教程不处理的标志：$AI_NAME ($AI_FLAGS)" ;; esac
  AI_MODE="$(/usr/bin/stat -f '%Lp' "$AI_FILE")"
  case "$AI_MODE" in 444|644) ;; *) fail "目标权限不是本例的 0444/0644：$AI_NAME ($AI_MODE)" ;; esac
  if [ "$AI_DATA_MOUNT" = '/System/Volumes/Data' ]; then
    [ "$AI_FLAGS" = 'uchg' ] && [ "$AI_MODE" = '444' ] || fail "在线修复只接受五项仍全部为 uchg/0444；已部分解锁时改为恢复模式离线处理：$AI_NAME"
  fi
  [ "$(/usr/bin/stat -f '%u' "$AI_FILE")" -eq 0 ] || fail "目标所有者不是 root：$AI_NAME"
  AI_ACL="$(/bin/ls -lde "$AI_FILE" | /usr/bin/sed -n '2,$p')"
  [ -z "$AI_ACL" ] || fail "目标有 ACL，需要另行诊断：$AI_NAME"
done

AI_BACKUP_DIR="$(/usr/bin/mktemp -d "$AI_SHARED_DIR/eligibility-cache-backup.XXXXXX")"
AI_LOG="$AI_BACKUP_DIR/repair.log"
printf '备份与日志目录：%s\n' "$AI_BACKUP_DIR"
exec 3>&1
exec > "$AI_LOG" 2>&1
finish() {
  AI_RESULT=$?
  trap - EXIT
  /bin/cat "$AI_LOG" >&3 || true
  if [ "$AI_RESULT" -ne 0 ]; then
    printf '\n修复未全部完成。保留以上错误和备份，不要把部分完成当成成功。\n' >&3
  fi
  exit "$AI_RESULT"
}
trap finish EXIT

printf '修复前状态：\n'
for AI_NAME in "${AI_FILES[@]}"; do
  /bin/ls -leO "$AI_ELIG_DIR/$AI_NAME"
  /bin/cp -p "$AI_ELIG_DIR/$AI_NAME" "$AI_BACKUP_DIR/$AI_NAME"
  /usr/bin/cmp -s "$AI_ELIG_DIR/$AI_NAME" "$AI_BACKUP_DIR/$AI_NAME" || fail "备份内容校验失败：$AI_NAME"
done
printf '\n五个文件均已备份并校验。仅解除 uchg、增加所有者写权限。\n'

for AI_NAME in "${AI_FILES[@]}"; do
  AI_FILE="$AI_ELIG_DIR/$AI_NAME"
  /usr/bin/chflags nouchg "$AI_FILE"
  /bin/chmod u+w "$AI_FILE"
  [ "$(/usr/bin/stat -f '%Sf' "$AI_FILE")" = '-' ] || fail "仍存在文件标志：$AI_NAME"
  [ "$(/usr/bin/stat -f '%Lp' "$AI_FILE")" = '644' ] || fail "写权限未恢复为 0644：$AI_NAME"
  /bin/ls -leO "$AI_FILE"
done
printf '\n成功：五个文件均已解除旧锁并恢复所有者写权限。\n'
printf '脚本没有重启机器。恢复模式中看到此成功信息后，才手动运行 reboot。\n'
BASH
)
```

脚本只接受指定卷和明确的五个普通文件。它先验证全部目标，再复制并逐个比较备份；所有备份成功后才执行 `nouchg` 和 `u+w`。它不改 plist 答案、不删除 SQLite 数据库及 WAL、不改所有者、不改目录权限、不处理其他标志，也不修改 SIP、启动安全策略或 FileVault。备份目录为私有权限，日志只记录检查与修复状态。

## 4. 先尝试正常系统中的管理员修复

在上一步的同一终端中运行；如果换了终端，先重新执行数据卷 UUID 查询：

```sh
sudo /bin/bash /Users/Shared/eligibility-cache-repair.sh /System/Volumes/Data "$AI_DATA_UUID"
```

输入本机管理员密码。如果五项全部成功，无需进入恢复模式；刷新资格服务一次后继续检查：

```sh
sudo launchctl kickstart -k system/com.apple.eligibilityd
```

在线尝试要求五个文件仍全部为 `uchg/0444`，使本例的旧数据在备份期间保持不可修改。若上次修复已经部分解锁，脚本会在备份和修改之前停止；这时核对状态后使用恢复模式离线处理，避免复制正在写入的 SQLite 文件。本流程的目标不是为任意正在运行的数据库制作一致性备份。

本案例在普通系统中备份成功，但管理员执行 `chflags` 时仍收到 `Operation not permitted`；系统策略日志显示拒绝 `file-write-flags`。**管理员权限不能绕过系统策略。** 只有确认是这种在线解锁被拒绝、且目标确实仍有本文的 `uchg` 旧锁，才继续离线修复。

若是缺文件、UUID 不匹配、不同权限、ACL、`schg` 或 `restricted` 等其他错误，先停止并诊断，不要把它泛化为“再关闭更多保护就能修好”。

## 5. 恢复模式中先解锁并装载数据卷，再取得真实路径

保存工作并关机，长按电源键，选择 **Options → Continue**。按提示验证管理员账户，打开 **Utilities → Terminal**。

把 `YOUR_DATA_VOLUME_UUID` 替换为第 3 节从自己当前启动系统查询到的数据卷 UUID，再逐行执行：

```sh
AI_DATA_UUID='YOUR_DATA_VOLUME_UUID'
/usr/sbin/diskutil apfs unlockVolume "$AI_DATA_UUID"
/usr/sbin/diskutil mount "$AI_DATA_UUID"
```

开启 FileVault 时，第一条按提示输入本机密码解锁；不要把密码放在命令参数中。若提示卷已经解锁或已经装载，可以继续；其他错误应先处理，不能假定后面的路径已经可用。也可通过恢复模式的 **Disk Utility** 解锁并 **Mount** 对应的数据卷，之后仍按 UUID 核对。

解锁和装载成功后，取得该卷的**实际 MountPoint**：

```sh
AI_DATA_MOUNT="$(/usr/sbin/diskutil info -plist "$AI_DATA_UUID" | /usr/bin/plutil -extract MountPoint raw -o - -)"
printf '数据卷实际装载点：%s\n' "$AI_DATA_MOUNT"
/bin/ls -l "$AI_DATA_MOUNT/Users/Shared/eligibility-cache-repair.sh"
```

不能假定数据卷一定叫 `Data`，也不能假定它在 `/Volumes/Data`：名称、FileVault 状态和实际装载点都可能不同。若脚本路径不存在或 MountPoint 为空，停在这里，核对是否解锁了正确的数据卷，以及第 3 节的脚本是否已保存成功；不要直接更换磁盘编号试写，也不要先重启把错误丢失。

确认脚本存在后运行：

```sh
/bin/bash "$AI_DATA_MOUNT/Users/Shared/eligibility-cache-repair.sh" "$AI_DATA_MOUNT" "$AI_DATA_UUID"
```

脚本会再次建立备份，核对卷 UUID 并逐项验证结果。**只有看到“成功：五个文件均已解除旧锁并恢复所有者写权限。”才运行：**

```sh
reboot
```

这一步无需再修改 SIP、启动安全策略或加 boot-args。若恢复模式中仍被拒绝，保存屏幕错误和日志目录，停止继续修改；本文没有依据将完整关闭 SIP 当作下一步通用解法。前置检查失败可能发生在日志创建之前，此时终端错误同样需要保留。

## 6. 回到桌面后验证新资格，再验证实际功能

在项目目录执行：

```sh
sudo ./install.sh status
sudo /usr/libexec/PlistBuddy \
  -c 'Print :OS_ELIGIBILITY_DOMAIN_GREYMATTER:os_eligibility_answer_t' \
  /private/var/db/eligibilityd/eligibility.plist
```

本案例中，五个文件恢复为无不可修改标志和 `0644`，主资格 plist 的时间戳更新，WAL 开始增长，`GREYMATTER` 变为 `4`。修复的目的只是让系统重新保存自己的计算结果，**解锁成功并不保证每台机器立即获得 Apple 智能**；若最新答案仍为 `2`，继续按 README 核对资格输入，不要手改答案。

设置曾显示 **Adding support for Siri is in progress** 和 **Apple Intelligence assets need to finish downloading**。这与扩展未安装或资格仍为 `2` 是不同阶段；部分资产日志显示完成也不能证明所有必需资产、激活过程和 Siri 初始化均已完成。按界面继续等待后台准备并复查实际功能，不要仅凭这两条提示重新修缓存、删除模型或扩大安全豁免。

Siri AI 还有独立的启用流程与服务端等候名单。完成后先测试一次不含个人信息的功能；若测试联网 AI，再按 README 触发一次请求、等待约一分钟并运行：

```sh
sudo ./install.sh pcc
```

只有相应实际调用和诊断结果，才能说明那一刻的云端链路是否可用。本文的最终正常使用来自用户反馈，不替代该验证。

## 7. 分享诊断时保护隐私

公开 issue 只需提供系统版本、Apple Silicon、扩展是否加载、区域是否为 `LL/A`、资格答案、相关文件标志/权限和经过脱敏的错误码。不要原样上传完整诊断日志、资格输入内容、备份文件或整张设备设置截图。

删除用户名、用户目录、邮箱、Apple Account、磁盘 UUID、序列号、位置、IP、代理信息和精确时间等可识别细节。备份与日志留在本地，不应提交到 Git 仓库。

## 参考

- [项目 README：安装、资格与 PCC 诊断](../README.md)
- [Apple：Use macOS Recovery on a Mac with Apple silicon](https://support.apple.com/guide/mac-help/mchl82829c17/mac)
- [Apple：Startup disk security policy control](https://support.apple.com/guide/security/sec7d92dc49f/web)
- [Apple：How to get Siri AI](https://support.apple.com/en-us/127893)
- [Apple：How to get the next generation of Apple Intelligence](https://support.apple.com/en-us/121115)
