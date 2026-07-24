# Lyric Fever Scroll

Lyric Fever Scroll 是一款面向 macOS 13 及以上版本的 Apple Music 菜单栏同步歌词应用。它按播放进度显示完整单句，不提供桌面悬浮窗口。

## 主要功能

- 优先读取 Music.app 本地缓存中的 Apple 官方 TTML 歌词，未命中时回退至 LRCLIB。
- 通过 MediaRemote 事件同步播放、暂停、跳转与切歌，避免高频轮询。
- 严格校验歌名、歌手与时长，并在本机缓存已确认的歌词。
- 将中文歌词统一转换为大陆简体；支持分别设置中文字体、英文字体与同步偏移。
- 长句自动缩小以适应菜单栏；支持登录时启动和内存诊断。

## 系统要求

- macOS 13 或更高版本
- Apple Music（Music.app）

首次运行时，请允许应用控制 Apple Music。应用仅显示在菜单栏，不显示 Dock 图标。

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
```

构建产物位于 `build/Lyric Fever Scroll.app`。

## 数据来源与限制

应用不会读取 Apple Music 账户令牌，也不会调用未授权的 Apple 歌词接口。若 Music.app 尚未写入对应歌词缓存，且 LRCLIB 没有可靠匹配，当前歌曲将暂不显示歌词。

核心依赖、固定版本、许可证及参考项目见 [NOTICE.md](NOTICE.md)。

## 许可证

本项目采用 [MIT License](LICENSE)。
