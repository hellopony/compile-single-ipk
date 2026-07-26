# compile-single-ipk

面向个人设备的 OpenWrt 单软件包编译项目。GitHub Actions 只为以下三台设备
选择编译环境，但**不限制插件名称**：

- Linksys WRT32X
- FriendlyElec NanoPi R4SE
- GL.iNET GL-MT3600BE（Beryl 7，预留配置）

可以编译 SDK feeds 中已有的软件包，也可以输入任意公开 HTTPS Git 仓库。
源码包既可以位于仓库根目录，也可以放在一个或多个子目录中。

## 已登记的固件配置

| 设备 | 固件输入 | 内核输入 | 软件包架构 | 状态 |
| --- | --- | --- | --- | --- |
| WRT32X | `24.10.0` | `6.6.73` | `arm_cortex-a9_vfpv3-d16` | 可编译，精确对应官方 SDK |
| R4SE | `R25.8.8` | `6.12.42` | `aarch64_generic` | 可编译用户态包，禁止生成 kmod |
| GL-MT3600BE | `4.9.0` | 尚未确认 | 尚未确认 | 仅预留，购买并采集设备信息后启用 |

详细资料保存在
[`profiles/firmware-profiles.json`](profiles/firmware-profiles.json)。工作流不会根据
一个内核版本猜测 SDK；没有登记的组合会直接停止。WRT32X 和 R4SE 可以在
运行时提供精确的自定义 SDK URL 与 SHA256，作为一次性的用户态编译配置。

## 运行工作流

1. Fork 本仓库。
2. 进入 **Actions**。
3. 选择 **Build device-specific IPK**。
4. 点击 **Run workflow**。
5. 填写设备、固件、内核、软件包名和可选源码信息。

工作流输入：

| 输入 | 说明 |
| --- | --- |
| `device` | 三台设备之一 |
| `firmware_version` | 配置表中的固件版本或别名 |
| `kernel_version` | 路由器当前运行的精确内核版本 |
| `package_names` | 最终需要的 IPK 包名；多个名称使用空格或逗号分隔 |
| `source_url` | 可选 HTTPS Git 仓库；留空表示从 SDK feeds 编译 |
| `source_ref` | 可选分支、Tag 或 Commit |
| `package_subdir` | 可选源码子目录；留空时递归查找 OpenWrt package Makefile |
| `custom_sdk_url` | 高级选项：未登记版本使用的精确 SDK 地址 |
| `custom_sdk_sha256` | 高级选项：自定义 SDK 必须提供的 SHA256 |

`package_names` 是输出白名单。编译依赖时可能在 SDK 内生成其他 IPK，但制品中
只会收集用户指定的包，不会上传固件、所有内核模块或其他无关文件。

## 使用示例

### 编译 SDK feeds 中的软件包

例如为当前 R4SE 编译 feeds 中已有的 `nano`：

```text
device: R4SE
firmware_version: R25.8.8
kernel_version: 6.12.42
package_names: nano
source_url: 留空
source_ref: 留空
package_subdir: 留空
```

某些源码目录会生成多个运行时软件包。只有确实都需要时才同时填写。例如旧版
Tailscale feed 的同一份 Makefile 会生成两个包：

```text
package_names: tailscale tailscaled
source_url: 留空
```

### 编译仓库根目录中的自定义包

```text
package_names: luci-app-example
source_url: https://github.com/example/luci-app-example.git
source_ref: main
package_subdir: 留空
```

### 编译仓库子目录中的包

```text
package_names: luci-app-example
source_url: https://github.com/example/openwrt-packages.git
source_ref: v1.2.3
package_subdir: luci-app-example
```

如果同一仓库中需要导入多个包目录，可以使用空格或逗号分隔：

```text
package_subdir: application, luci-app-application
package_names: application luci-app-application
```

源码引用可以是分支、Tag 或完整 Commit。为了得到可重复的结果，建议使用 Tag
或 Commit，而不是始终变化的默认分支。

## R4SE 兼容性边界

已验证的 R4SE 信息：

```text
型号：FriendlyElec NanoPi R4SE
board_name：friendlyarm,nanopi-r4se
固件：LEDE R25.8.8
OpenWrt 基线：24.10.2
源码提交：02e01b92d35077a7ad48fb7a648f4389c7b5224d
目标：rockchip/armv8
架构：aarch64_generic
内核：6.12.42
内核 ABI：f4827afbd0f193bf8697617cf19ff655
GCC：13.3.0
musl：1.2.5
```

官方 OpenWrt 24.10.2 SDK 与这套固件的用户态工具链和架构匹配，适用于普通
二进制程序、脚本和 LuCI 包。但是官方 24.10.2 软件源的 Rockchip 内核是
6.6.93，而这台 LEDE 固件使用 6.12.42。因此：

- 普通用户态包和 `Architecture: all` 包可以编译。
- 用户态包可以依赖路由器中已经存在的 `kmod-*`。
- 本项目不会为这个 R4SE 配置输出 `kernel` 或 `kmod-*`。
- 不要用 `opkg --force-depends` 安装其他内核 ABI 的模块。

要启用 R4SE 内核模块编译，必须取得产生当前固件的完整构建配置或完全一致的
SDK，并在配置表中登记和验证内核 ABI。

## 新增固件版本

固件升级后，不要只修改工作流中的默认版本。应当在
`profiles/firmware-profiles.json` 中增加一个新 profile，至少登记：

```json
{
  "id": "设备-固件版本",
  "status": "ready",
  "device": "R4SE",
  "firmware_version": "新的版本",
  "kernel_version": "精确内核版本",
  "kernel_abi": "如已确认则填写",
  "sdk_url": "精确 SDK 下载地址",
  "sdk_sha256": "64 位 SHA256",
  "allow_kmods": false
}
```

普通用户每次运行时仍然只需要填写设备、固件版本、内核版本和软件包信息。

## 构建制品

每次 Actions 制品包含：

- 用户指定的 `*.ipk`
- `build-manifest.txt`：设备、SDK、源码 Commit、架构、依赖和文件 SHA256
- `check-before-install.sh`：在路由器上安装前检查型号、架构和内核

建议先把整个制品解压到路由器 `/tmp`，执行检查：

```sh
sh /tmp/check-before-install.sh
```

检查通过后，只安装实际需要的软件包：

```sh
opkg install /tmp/软件包名称_*.ipk
```

安装失败时不要强制忽略架构、依赖或内核错误；先查看
`build-manifest.txt` 中的 `Architecture` 和 `Depends`。
