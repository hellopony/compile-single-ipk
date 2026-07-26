# sdk-action

![操作截图](./action.jpg)

fork 后会自动切到自己的仓库：
   1. 切到Action页面
   2. 选择set_variable 工作流
   3. 点击 Run workflow 按钮，选择需要编译的目标设备
   4. 编译 Tailscale 时，Package preset 选择 `tailscale`，源码地址和包名留空
   5. 编译自定义包时，Package preset 选择 `custom`，填写源码地址和包名
   6. 如果源代码需要认证信息可以输入邮箱和密码，如果没有则留空
   7. 点击 Run workflow

接下来会自动执行编译，编译时间快的可能2，3分钟，取决于插件本身的编译时间

编译完成后，点击对应工作，可查看编译好的插件压缩包，压缩包中包含了你需要编译的插件以及所有依赖软件包

下载解压后找到需要的ipk文件

将ipk文件传到路由器后台，使用 opkg 命令安装.

```bash
opkg install /tmp/*.ipk
```

## NanoPi R4SE / FriendlyWrt R23.7.7

状态页显示的 `R23.7.7` 是 FriendlyWrt 的日期版开发快照，并不是 OpenWrt
正式发行版号。NanoPi R4SE 对应的编译目标为 `rockchip/armv8`，生成的
软件包架构为 `aarch64_generic`。

工作流选择：

```
Select target device: R4SE
Package preset: tailscale
Source code URL(s): 留空
OpenWrt package name(s): 留空
```

下载的 GitHub Actions 制品名称必须以 `R4SE_` 开头。若名称以 `X86_`
开头，说明运行工作流时选择了 X86，里面的 `x86_64.ipk` 不能安装到 R4SE。

默认使用最接近该快照且仍能公开下载的 OpenWrt 23.05.0-rc2 SDK
（GCC 12.3.0 / musl）。它用于编译 Tailscale 等用户态程序。默认 SDK 的
内核 ABI 是 5.15.118，而截图中的 FriendlyWrt 内核是 5.15.120，因此不要
安装默认构建产生的任何 `kmod-*.ipk`。

Tailscale 依赖 `kmod-tun`。先在路由器上确认它已由当前 FriendlyWrt 安装：

```bash
opkg list-installed | grep '^kmod-tun '
```

如果缺少 `kmod-tun`，应从这台路由器当前配置的 FriendlyWrt 软件源安装，
不能使用其他内核版本编译的 kmod。

如果从 FriendlyELEC 下载到了与当前固件完全匹配的 SDK，可以在运行工作流
时填写 `sdk_url`；建议同时填写 `sdk_sha256`。支持 `.tar.xz`、`.tar.zst`
和 `.tgz` SDK。这样也可以安全编译内核模块。

Tailscale 来自 SDK 固定的 OpenWrt packages feed。默认 RC2 SDK 会生成
`tailscale` 和 `tailscaled` 两个 1.40.1 软件包，安装时两者都需要：

```bash
opkg install /tmp/tailscaled_*.ipk /tmp/tailscale_*.ipk
/etc/init.d/tailscale enable
/etc/init.d/tailscale start
tailscale up
```

工作流只会上传 `tailscale_*.ipk` 和 `tailscaled_*.ipk`，不会再把 SDK
自带的固件、内核模块和其他无关 ipk 一并放进制品。R4SE 构建若生成的
文件不是 `aarch64_generic.ipk`，任务会直接报错而不会上传错误架构的文件。

## 可选的包

<table width="100%">
   <thead>
      <tr>
         <th>仓库</th>
         <th>名称</th>
      </tr>
   </thead>
   <tbody>
      <tr>
         <td>https://github.com/openwrt-packages/openwrt-vlmcsd</td>
         <td>openwrt-vlmcsd</td>
      </tr>
      <tr>
         <td>https://github.com/openwrt-packages/luci-app-vlmcsd</td>
         <td>luci-app-vlmcsd</td>
      </tr>
      <tr>
         <td>https://github.com/openwrt-packages/helloworld</td>
         <td>luci-app-ssr-plus</td>
      </tr>
      <tr>
         <td>https://github.com/openwrt-packages/luci-app-bandwidthd</td>
         <td>luci-app-bandwidthd</td>
      </tr>
      <tr>
         <td>https://github.com/openwrt-packages/luci-app-clash</td>
         <td>luci-app-clash</td>
      </tr>
      <tr>
         <td>OpenWrt packages feed（无需填写源码 URL）</td>
         <td>tailscale / tailscaled</td>
      </tr>
   </tbody>
</table>

luci-samba4 新增一项

![luci-samba4 配置](./samba4.jpg)

```
名称     tmp
路径     /tmp
可浏览   勾选
允许用户 ftp
```
