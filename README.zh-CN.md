# OpenDeck

一个从零实现的 macOS Launchpad 本地替代品 —— 起因是 macOS 26 把原生 Launchpad 移除了。
这里的一切都是原创实现：没有从任何现存应用里取用代码、图标、素材或文案。

[English](README.md) · **中文说明**

![OpenDeck](docs/deck.png)

## 功能

- 在鼠标指针所在的那块屏幕上全屏浮层显示，层级高于所有窗口，背景是真实桌面（可选毛玻璃）
- 7 × 5 图标网格，横向分页，实时搜索，文件夹，拖拽排序
- 导入你原来的 Launchpad 布局，分页与文件夹一并还原
- 唤起方式：录制的快捷键、F4、键盘的 Launchpad 键、触控板捏合，或屏幕角落
- 卸载残留：扫描 12 个 `~/Library` 位置，命中的文件移入废纸篓
- 用 FSEvents 感知应用的安装与卸载并自动重扫；可记住离开时的页码
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
./build/OpenDeck.app/Contents/MacOS/OpenDeck --selftest    # 267 项无头检查
./build/OpenDeck.app/Contents/MacOS/OpenDeck --bench 60    # 翻页耗时
```

## 状态文件

分页、文件夹、隐藏的应用与排序规则保存在
`~/Library/Application Support/OpenDeck/layout.json`；其余设置放在 `UserDefaults` 的
`local.opendeck.app` 域下。

从 LaunchDeck（本应用改名前的名字）升级？首次启动会把旧的布局与设置**复制**过来，改名前的
目录原样保留，所以这次升级可以随时回退。

## 已知缺口

- 捏合会对任意手指数触发 —— AppKit 不报告是几根手指产生的
- 没有备份导入/导出，没有多语言，没有自动更新
- 文件夹的放大动画作用于面板，而不是图标自身的图像

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
