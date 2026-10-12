# OpenDeck

一个从零实现的 macOS Launchpad 本地替代品 —— 起因是 macOS 26 把原生 Launchpad 移除了。
这里的一切都是原创实现：没有从任何现存应用里取用代码、图标、素材或文案。

[English](README.md) · **中文说明**

![OpenDeck](docs/deck.png)

## 功能

- 在鼠标指针所在的那块屏幕上全屏浮层显示，层级高于所有窗口，背景是真实桌面 ——
  5 档系统玻璃材质，逐帧合成真实桌面
- 图标网格 8 档可选（7–10 列 × 5–6 行），横向分页，实时搜索，文件夹，拖拽排序
- 导入你原来的 Launchpad 布局，分页与文件夹一并还原
- 唤起方式：录制的快捷键、F4、键盘的 Launchpad 键、触控板捏合，或屏幕角落 ——
  该角落已被系统触发角占用时会明确提示
- 菜单栏图标，默认不出（需要时再开）
- 卸载残留：扫描 12 个 `~/Library` 位置，命中的文件移入废纸篓
- 用 FSEvents 感知应用的安装与卸载并自动重扫；重开时回到离开的页码，或按你选的延时回到第一页
- 右键任意图标：打开、退出、强制退出、在 Finder 中显示、显示简介、隐藏、卸载

## 环境要求

- **部署目标：** macOS 15，Apple 芯片
- **开发与验证环境：** macOS 27（26A428）
- Xcode **或**命令行工具。无任何第三方依赖

## 构建

```sh
./build.sh                 # release -> build/OpenDeck.app
./build.sh debug           # debug
open build/OpenDeck.app

cp -R build/OpenDeck.app /Applications/     # 留在系统里（同时让「登录时启动」能注册）
```

`build.sh` 直接调用 `swiftc` —— 没有 Xcode 工程，也不用 SwiftPM，因此代码刻意避开依赖宏的
属性包装器（`@State`、`@Observable`），状态全部放在 `ObservableObject` 视图模型里。

## 验证

```sh
./build/OpenDeck.app/Contents/MacOS/OpenDeck --selftest    # 343 项无头检查
./build/OpenDeck.app/Contents/MacOS/OpenDeck --bench 60    # 翻页耗时
```

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
