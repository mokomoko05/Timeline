# Timeline iPhone 版

iPhone 版和 Mac 版共用数据层（`TimelineCore`），通过 **iCloud 云盘里的「Timeline」文件夹**同步。不需要付费开发者账号，也不需要 iCloud 权限，用免费 Apple ID 签名即可。

## 同步原理

- 每台设备只写自己的 `Timeline/devices/<设备>.json`，内容是这台设备知道的全部状态。
- 各设备读取其他设备的文件后逐字段合并：较晚的修改生效，删除也会同步。
- 两边同时改了同一页工作板或同一天的小结时，两份内容都保留，中间用「同步冲突」标记隔开。
- 图片放在 `Timeline/images/`，哪边缺就补哪边。
- 草稿留在各自设备上，不同步。
- 本机数据仍在原来的位置。第一次与其他设备合并前，会先备份到 `Backups/before-first-sync-*.json`。

## 首次设置

1. **Mac 版**：在设置里打开「通过 iCloud Drive 与 iPhone 同步」，iCloud 云盘里就会出现「Timeline」文件夹。
2. **Xcode**：在 设置 › 账户 里用 Apple ID 登录（免费账号即可）。
3. **iPhone**：
   - 用数据线连接 Mac，在手机上点「信任」。
   - 在 Xcode › Window › Devices and Simulators 里勾选「Connect via network」，之后就能通过 Wi-Fi 安装。
   - 在手机上打开 设置 › 隐私与安全性 › 开发者模式（手机会重启）。
4. 运行 `bash scripts/install-ios.sh`。
5. 首次安装后，手机可能要求信任开发者：到 设置 › 通用 › VPN与设备管理 里信任你的 Apple ID。
6. 在手机上打开 Timeline，进入「同步」标签，选中 iCloud 云盘里的「Timeline」文件夹。

## 7 天过期

免费签名的应用 7 天后过期，重装不会丢数据。可以自己定期重新运行 `bash scripts/install-ios.sh`，也可以执行一次：

```sh
bash scripts/install-ios.sh --schedule
```

之后 Mac 每 6 小时检查一次：距上次安装超过 4 天、且手机在线（同一 Wi-Fi 或连着线）时自动重装。日志在 `~/Library/Logs/Timeline/ios-install.log`。要取消，运行 `--unschedule`。
