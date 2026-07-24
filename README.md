# Lyric Fever Scroll

一个低资源占用的 macOS 菜单栏 Apple Music 同步歌词客户端。

## 行为

- 每次完整显示当前一句歌词；在 420pt 内自动缩小字号，不截断、不做连续滚动动画。
- 默认中文使用 `KaiTi`，英文使用 `Times New Roman`，可从菜单栏设置修改。
- 同步偏移可在设置中从延后 1.5 秒到提前 1.5 秒连续调整；默认保持提前 0.65 秒。
- 使用固定版本 OpenCC 1.3.1 的 `tw2sp` 转换链，将繁体字、台湾异体字和台湾词汇统一为大陆简体，并应用少量大陆首选用词和歌词错字修正。
- 正常播放按每句时间点零容差触发；拖动进度由 MediaRemote 系统事件立即更新，不轮询，15 秒只在后台做一次完整状态校准，不阻塞切句。
- Mac 从睡眠唤醒时立即校准；MediaRemote 辅助进程异常时按 1–30 秒指数退避重启。
- 可从菜单启用 macOS 原生“登录时自动启动”，不安装额外守护进程。
- 保留 LRC 的空时间点，在间奏开始时立即清空上一句。
- 优先读取 Music.app 已下载的 Apple 官方 TTML 歌词，不读取账户令牌、不额外请求 Apple 接口。
- 切歌后短时监听 Music 缓存目录写入，官方歌词到达时立即采用；该监听由文件系统事件驱动，不轮询。
- Apple 缓存未命中时由 LRCLIB 并行回退；已验证的结果会保留在本机，再次播放可立即显示，最多保留最新 500 份。
- 宽泛搜索只接受歌名、歌手和时长均可信的版本，避免错误现场版进入缓存。
- 原始标题搜索失败时，才会用另一种繁简字形再查一次；缓存保存和裁剪在低优先级串行队列执行。
- 菜单栏可复制最近 100 条内存诊断事件；不写日志文件，不增加轮询。
- 现场版没有独立结果时，会按基础歌名和最接近的时长回退匹配。
- 回退版本在时长差不超过 5% 时，会按 Apple Music 实际时长缩放时间轴。

## 构建与测试

```sh
./scripts/build.sh

mkdir -p build
swiftc -swift-version 5 -O \
  -framework AppKit -framework CoreServices -framework Foundation \
  Sources/MainlandChineseConverter.swift Sources/LyricCore.swift \
  Sources/AppleMusicCache.swift Sources/MediaRemotePositionStream.swift \
  Tests/main.swift \
  -o build/logic-tests
./build/logic-tests

swiftc -swift-version 5 -O \
  -framework AppKit -framework CoreServices -framework Foundation \
  -framework ScriptingBridge \
  Sources/MainlandChineseConverter.swift Sources/LyricCore.swift \
  Sources/AppleMusicCache.swift Sources/MediaRemotePositionStream.swift \
  Tests/SyncMonitor.swift \
  -o build/sync-monitor
./build/sync-monitor 60
```

MediaRemoteAdapter 已固定在 `Vendor/MediaRemoteAdapter` 并在构建前校验 SHA-256，不依赖另一个已安装应用。

首次运行时，macOS 会询问是否允许控制 Apple Music。应用是菜单栏程序，不显示 Dock 图标。

## 依赖和来源

- AppKit / CoreServices / Foundation / ServiceManagement：macOS 系统框架。
- [MediaRemoteAdapter](https://github.com/ejbills/mediaremote-adapter)：固定提交和 SHA-256 后随项目提供，用于事件驱动的播放位置更新；构建不再依赖另一个已安装应用。
- [OpenCC](https://github.com/BYVoid/OpenCC)：使用固定的 1.3.1 台湾转大陆简体词典，运行时只在每首歌加载歌词时转换一次。
- [LRCLIB](https://lrclib.net)：运行时同步歌词 API；服务端源码采用 MIT 许可证。
- [Apple Music Lyrics](https://github.com/Takpap/apple-music-lyrics)：MIT 许可；参考 Music.app 本地 CFNetwork 缓存索引和强元数据匹配思路。
- [MusanovaKit](https://github.com/rryam/MusanovaKit)：MIT 许可；参考结构化 TTML 解析和时间语义；本项目未引入其需要特权令牌的网络层。
- [LyricsOnMacOSBar](https://github.com/motian566/LyricsOnMacOSBar)：MIT 许可；参考菜单栏产品形态和多来源回退思路，不使用其用户令牌网络方案。
- [LyricFever](https://github.com/aviwad/LyricFever)：MIT 许可的上游项目。本程序未复制其源码，但保留名称和设计来源说明。
- [actions/checkout](https://github.com/actions/checkout)：CI 中以完整 SHA 固定的 MIT 许可 GitHub Action，不进入应用包。

详见 `NOTICE.md`。
