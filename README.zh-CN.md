# LaunchDeck

一个从零实现的 macOS Launchpad 本地替代品 —— 起因是 macOS 26 把原生 Launchpad 移除了。
这里的一切都是原创实现：没有从任何现存应用里取用代码、图标、素材或文案。

[English](README.md) · **中文说明**

![网格](docs/deck.png)

## 功能

**核心**

- 在鼠标指针所在的那块屏幕上全屏浮层显示，层级高于所有窗口
- 使用你真实的桌面壁纸，可选毛玻璃处理
- 7 × 5 图标网格（小屏幕自动降级），横向分页并带页码圆点
- 实时搜索：精确 / 前缀 / 子串 / bundle-id / 子序列 排序评分
- 点击启动；Return 启动首选项；Esc 关闭；方向键导航
- 文件夹：把一个应用拖到另一个上即可创建，双击重命名，可移出成员、可解散
- 拖拽排序。拖到已占用的格位会**插入到它前面**并把后面的整体后移，所以整页排满时依然可以重新排列
- 只有在另一个应用上**停留**约 1.2 秒才会生成文件夹，单纯在它上面松手永远不会
- 拖到页码圆点上可把条目移到那一页；在圆点上停留约 0.5 秒会翻过去
- 可以把应用从展开的文件夹里拖出来，放到网格上
- 拖拽手势挂在滚动容器上而不是每个格子上，因此拖动过程中翻页不会把源格子回收掉、从而中断手势。拖到屏幕左右边缘会翻页；边缘翻页以网格的**实际绘制矩形**为判据，所以只在网格两侧的空白带里才会触发
- 排序规则：名称、添加日期、最近使用（取 Spotlight 元数据）或手动顺序
- 一键填补空位、恢复字母序
- 隐藏 / 取消隐藏应用，可选「让隐藏的应用也出现在搜索里」
- 右键菜单：打开、退出、强制退出、在 Finder 中显示、显示简介、隐藏、卸载

**导入旧布局**

- 直接读取 macOS 自己的 Launchpad 数据库，还原它的分页与文件夹
- 每个应用都有交代：已放置、「未安装」或「此处已隐藏」

**背景**

- 窗口本身透明，用一个 `.behindWindow` 混合模式的 `NSVisualEffectView` 采样**真实**桌面，所以背景永远精确一致 —— 包括那些 `NSWorkspace.desktopImageURL` 解析不出来的轮播相册
- 三种模式：**桌面**（压暗，即 Launchpad 自己的做法）、**毛玻璃**（Dock 和通知中心用的同一种系统材质）、**自定义图片**（固定一张文件，可调模糊）
- 这套方案取代了「画一份高斯模糊的壁纸副本」的旧做法 —— 后者永远无法与轮换中的桌面保持同步，观感也不原生

**唤起方式**

- 快捷键录制器：点一下输入框，按下你想要的组合键
- F4 可以单独使用；其他按键必须带修饰键
- 走 Carbon hot key，因此不需要辅助功能权限
- 可选：键盘的 Launchpad 键（CGEventTap，需要辅助功能权限）、触控板捏合、屏幕角落（全局鼠标监听，不需要权限）
- 可选：deck 打开时隐藏 Dock，与 Launchpad 行为一致

**卸载**

- 扫描 12 个 `~/Library` 位置，匹配 bundle id 或应用名
- 显示各项体积，可逐项取消勾选，全部移入废纸篓
- 对 root 拥有的 bundle 退化为带授权的（管理员）删除

**保持同步**

- 用 FSEvents 监听 `/Applications`、`~/Applications` 及系统应用目录，安装或卸载无需重启即可反映
- 重新扫描在非主线程执行并做了防抖，因为扫描要为每个 bundle 读取 Spotlight 元数据

**状态记忆**

- 重新打开时回到你上次停留的页码，或始终回到第一页（对应 LaunchOS 的 "Saved State" 与 "Return To Main Page"）

**关闭 deck** —— 以下任一：

- `Esc`
- 点击任意空白处（包括未使用的网格格位）
- 启动一个应用
- 再次按下快捷键，或再次按 Launchpad 键
- 右键 → **Close**

**文件夹**

- 打开时面板从图标位置放大展开，用记录的 frame 作为动画代理（LaunchOS 称其为 `FolderAnimationProxy*` 的那套做法）；面板打开期间源格子隐藏
- 面板按内容定尺寸：按应用数量排 1–4 列，超过 12 个应用则整行滚动
- 双击标题重命名。标题是**浮在面板之上的独立浮层**，而不是面板内部的一行，因此进入重命名模式不会改变文件夹尺寸；它会变成一个小白框。这与 LaunchOS 的 `FolderFloatingTitleView`（label 与 `titleField` 在面板布局之外互换）一致 —— 把输入框放进面板自己的 stack 里，正是导致面板被撑宽的原因

**进入设置**

- 搜索放大镜**左侧**的齿轮按钮
- 在 deck 上任意空白处右键：设置、导入、填补空位、重置顺序、退出
- deck 没有盖住菜单栏时按 ⌘,

设置窗口包含：导入、排序规则、壁纸与毛玻璃、唤起方式（含快捷键录制器）、隐藏的应用、权限状态、登录时启动。

## 环境要求

- macOS 15（Sequoia）或更高版本，Apple 芯片
- Xcode **或**命令行工具（`xcode-select --install`）
- 无任何第三方依赖 —— 没有任何东西需要安装

## 构建

```sh
./build.sh            # release
./build.sh debug      # debug
open build/LaunchDeck.app
```

产物为 `build/LaunchDeck.app`。没有 Xcode 工程，也不用 SwiftPM —— `build.sh` 直接调用
`swiftc`。想把它留在系统里（同时让「登录时启动」能注册成功）：

```sh
cp -R build/LaunchDeck.app /Applications/
```

### 工具链说明

代码刻意避开 `@State`、`@Observable` 以及其他依赖宏的 SwiftUI 属性包装器，因此在 Xcode 或
仅有命令行工具的环境下都能编译。所有可变的 UI 状态都放在 `ObservableObject` 视图模型里，
通过 `@ObservedObject` / `@Binding` / `@FocusState` 消费。

不使用 SwiftPM：本机命令行工具安装里的 `libPackageDescription.dylib` 缺少 `Package.init`
符号，导致 manifest 链接失败。

## 你原来的 Launchpad 布局数据在哪

Launchpad 在 macOS 26 被移除，但它的数据库没有被移除。它已经**不在**
`~/Library/Application Support/Dock` 里了 —— 而是搬到了紧邻 `TMPDIR` 的那一级用户级
容器目录：

```
/private/var/folders/<xx>/<hash>/0/com.apple.dock.launchpad/db/db
```

有两个 schema 细节很关键，任一处弄错都会**静默丢数据**：

- `items.type` 对**分页**和**外层文件夹**用 **3**，但真正存放文件夹成员的内层分组用 **2**。
  文件夹以两层嵌套分组存储：外层带名字，内层带应用。
- 数据库处于 **WAL 模式**。一旦 Dock 回收了 `-shm` 边车文件，以只读方式打开会报
  `SQLITE_CANTOPEN`，因为 SQLite 需要创建它。LaunchDeck 的做法是先把数据库复制出一份私有
  副本，再以读写方式打开**那份副本**。

## 验证

```sh
./build/LaunchDeck.app/Contents/MacOS/LaunchDeck --selftest
```

254 项无头检查，覆盖一切截图无法确认的东西：容量不变量、隐藏 / 取消隐藏、文件夹的创建 /
重命名 / 解散、移动、三种排序规则、一次完整的「保存 → 重新加载」往返、壁纸解析与毛玻璃渲染、
快捷键解析与注册、Launchpad 导入（对着真实数据库跑）、分页模型钳制、跨页移动、frame 注册表、
热区几何、拖拽用的网格命中测试（每个格位中心都能映射回它自己，末尾空位可投放而网格之外的点不可），
以及热路径耗时与卸载扫描。它使用一次性的布局文件，绝不删除任何东西。

`--bench` 会额外驱动一次真实的滚动，检查页码指示器是否跟随，不跟随则非零退出。这是针对
「滑动时圆点停在 page 0 不动」那个 bug 的回归测试。

当前状态：**254/254 通过**，scroll-follow 3/3，翻页 p95 远在 60 fps 预算之内（本机 3.0 ms）。

这套测试是值回票价的。以下是它抓到的、但界面看上去一切正常的 bug：

1. `DeckStore.init` 在读取布局文件**之前**就扫描并 reconcile，而 `reconcile()` 最后会调
   `save()`。于是每次启动，已保存的布局都被默认值覆盖 —— 页码顺序、文件夹、隐藏应用、排序
   设置从来没能在重启后存活。
2. `makeFolder` 调用了 `removeFromGrid(source)`，而后者会把应用从任何包含它的文件夹里摘掉
   —— 等于立刻撤销它刚创建的那个文件夹。
3. `enforceCapacity` 在加载时压缩每一页，把用户刻意留下的空隙填掉了。现已拆分为
   `enforceCapacity`（只拆分超载页）与 `reflow`（只在网格形状变化时压缩）。
4. `CFBundleDisplayName` 为空的 bundle 会产出一个没有名字的图标。
5. `.skipsHiddenFiles` 让 `contentsOfDirectory` **漏掉了 Safari**。Foundation 在应用该选项
   时会解析符号链接，而 Safari.app 是指向 Cryptex 卷的符号链接，于是被静默排除在扫描之外。
   现在改为按文件名过滤点文件。
6. `LSUIElement` 应用被过滤出扫描结果。Launchpad 是显示它们的（调度中心、截屏、提示），所以
   deck 既与 Launchpad 不一致，又在导入时丢了应用。去掉该过滤后：143 个应用而不是 125 个。
7. 解析失败的文件夹成员被直接丢弃且不上报，于是导入看起来完整，实际并不完整。
8. `NSTemporaryDirectory()` 是 `…/<hash>/T/`，而 Launchpad 数据库在 `…/<hash>/0/` —— 只根据
   TMPDIR 推导路径什么也找不到。
9. **滑动时页码圆点从来不移动。** 滚动偏移是通过 `.background` 里的 `PreferenceKey` 跟踪的，
   而它从未触发。改用 `onScrollGeometryChange`，并加了回归测试。
10. **`matchedGeometryEffect` 弄坏了文件夹面板。** 用它来实现 Launchpad 那种「从图标放大展开」
    的打开效果时，窗口角落会渲染出一个空白方块，并把文件夹的格子藏起来 —— 因为源视图位于惰性
    容器内，会被回收。改用 frame 注册表加显式 transform。
11. **一个补丁脚本静默丢弃了自己的工作。** `sys.exit` 在写文件之前就触发了，于是五处成功的修改
    从未落盘，构建在一个只改了一半的文件上失败。现在补丁总是会写盘，并上报失败而不是中止。
12. **快照诊断是死代码。** `deckVM` 声明了却从未赋值，导致打开文件夹的代码路径从未执行，代理
    frame 静默退回到居中面板。是「打印算出来的起始 frame」而不是「相信图片」抓到的。
13. **重命名输入框把整个文件夹撑宽了。** 标题原本是面板 stack 里的一行，于是输入框的固有宽度
    把面板拉伸了。已移出为浮动浮层。
14. **拖拽排序完全不工作。** 它建立在 SwiftUI 的 `.onDrag`/`.onDrop` 之上，而它们的失败模式是
    静默的 —— 什么都不发生，也无从判断原因。改为自管理拖拽：`DragGesture` 上报指针位置，
    `GridHitTester`（纯值类型，有单元测试）把它映射到格位，一个代理图标跟随光标。另外，格子
    上还带着一个 `.padding(6)`，让它比自己的网格列更宽，导致指针位置根本映射不回任何格位。
15. **穿透按钮画出一个实心方块。** 用 `.sourceAtop` 填充模板符号来染色时覆盖了整个矩形；现在
    改为通过符号自身的 `paletteColors` 配置染色。
16. **跨页拖拽是死代码。** 页码圆点仍然用 `.onDrop`，而它需要系统拖拽会话 —— 但系统拖拽早已
    被自管理手势取代，圆点的投放目标因此永远不会触发。更糟的是，手势挂在每个格子上，拖动中翻页
    会在惰性 stack 里回收源格子并取消拖拽；现在它挂在滚动容器上，并从拖拽起点解析源。
17. **拖到已占用的格位会建文件夹而不是重排。** 整页排满时根本不存在空格位，于是重新排列成为
    不可能 —— 也就是用户反馈的「拖不到我想要的位置」。现在投放是插入并后推；合并只在停留时发生。
18. **未钳制的页码在拖拽时崩溃。** 在第 0 页拖进边缘带会把 `currentPage` 设为 `-1`；而守卫
    条件 `page < store.pages.count` 不会拒绝负数，于是下一次指针移动读到 `store.pages[-1]` 并
    触发 trap。现在钳制统一发生在 `DragState.clampPage`，并且每一处页码读取都会检查下界。
19. **中间的空页会永久存活。** `normalizePages` 只移除**末尾**的空页，于是中间的空白页每次
    启动都被重新保存，并渲染成一个「点一下就关闭 deck」的页面。
20. **`appendToGrid` 无视容量**，写出一个超载页，下一次启动就凭空多拆出一页。
21. **开发工具改写了真实的 `layout.json`。** `--bench` 与 `--snapshot` 会打开真实的 store 并
    保存它。现在它们使用只读 store；通过在这两个工具前后对文件取哈希来验证。
22. **保存的字节是不确定的。** 文件夹按字典的迭代顺序编码，于是相同的状态会产出不同的文件。
23. **快照框架无法渲染动画。** `NSHostingView` 从未被放进窗口，SwiftUI 因此永远不会推进
    `withAnimation` —— 每张快照里的文件夹面板都冻结在第一帧，两个不同状态产出的 PNG 逐字节
    相同。现在框架会把视图挂到一个屏幕外窗口上。

## 开发辅助

```sh
# 把真实的视图层级渲染成 PNG（不需要屏幕录制权限）
./build/LaunchDeck.app/Contents/MacOS/LaunchDeck --snapshot /tmp/deck.png
./build/LaunchDeck.app/Contents/MacOS/LaunchDeck --snapshot /tmp/settings.png --settings
./build/LaunchDeck.app/Contents/MacOS/LaunchDeck --snapshot /tmp/search.png --query "chr"

# 测量翻页的布局开销（p50 / p95，对照 60 fps 预算）
./build/LaunchDeck.app/Contents/MacOS/LaunchDeck --bench 60
```

## 代码结构

```
Sources/LaunchDeck/
  main.swift                       入口（+ --selftest、--snapshot）
  AppDelegate.swift                生命周期、通知、集成装配
  SelfTest.swift                   检查套件
  Snapshot.swift                   屏幕外渲染器
  Models/
    AppInfo.swift                  AppInfo、SortKey、AppFolder、DeckSlot
    GridMetrics.swift              屏幕 → 列数/行数/图标尺寸
  Services/
    AppScanner.swift               在标准位置发现应用
    DeckStore.swift                布局模型、持久化、导入、reconcile
    LaunchpadImporter.swift        读取 macOS 的 Launchpad SQLite 数据库
    RuntimeCache.swift             图标缓存 + 运行中应用集合缓存
    WallpaperProvider.swift        壁纸解析、降采样、毛玻璃
    DeckSettings.swift             基于 UserDefaults 的偏好设置
    HotKeyManager.swift            HotKeySpec + Carbon 注册
    LaunchpadKeyMonitor.swift      Launchpad 键的 CGEventTap
    PinchMonitor.swift             全局捏合手势监听
    HotCornersMonitor.swift        指针进入角落的触发
    AppUninstaller.swift           关联文件扫描 + 移入废纸篓
    LaunchServices.swift           启动 / 退出 / 定位 / 显示简介
    Permissions.swift              辅助功能 / 完全磁盘访问权限检测
  UI/
    LaunchpadView.swift            deck、背景、滚动容器、搜索栏
    LaunchpadViewModel.swift       搜索、选中、文件夹
    PagingState.swift              PageIndicator / PageJumper（隔离的分页）
    Backdrop.swift                 系统材质背景 + 模式
    FrameRegistry.swift            格子 frame，供文件夹动画代理使用
    GridHitTester.swift            纯函数式「点 → 格位」映射，有单元测试
    DragState.swift                进行中的拖拽：目标、代理、翻页
    PassthroughButton.swift        首次点击即生效、且永不夺取焦点的按钮
    LaunchpadWindowController.swift
    AppCell.swift                  应用 / 文件夹格子、空格位
    FolderOverlayView.swift        展开的文件夹
    SettingsView.swift             设置窗口（+ 快捷键录制器）
    AuxiliaryWindows.swift         设置 / 卸载窗口的宿主
    UninstallView.swift            卸载确认界面
Tools/make-icon.swift              生成 Resources/AppIcon.icns
```

状态保存在 `~/Library/Application Support/LaunchDeck/layout.json`：分页、文件夹、隐藏的应用、
排序设置与手动顺序。

## 性能

两个独立的问题，都经过实测。

**body 里的逐帧开销**（`--selftest`，144 个应用）：

| 热路径 | 开销 |
|---|---|
| 运行状态查询，143 应用 × 20 | 0.2 ms |
| 图标查询，143 应用 × 5 | 0.1 ms |
| 毛玻璃壁纸，冷启动 | 59 ms |
| 毛玻璃壁纸，命中缓存 | 0.8 ms |

原先每个格子每次渲染都要问一次 `NSWorkspace` 它的应用是否在运行，并重新取一次图标；壁纸则是按
原始分辨率（最高 4000 px）合成的。现在都变成了缓存的集合 / 字典查询，壁纸只按屏幕分辨率解码一次。

**翻页卡顿**（`--bench`）。状态原本堆在一个被整个 deck 观察的 `ObservableObject` 里，于是
*鼠标在图标上每移动一次*、以及*每次翻页的每一帧*都会重建全部 175 个格子：

| | 优化前 | 优化后 |
|---|---|---|
| 翻页，均值 | 52.2 ms | — |
| 翻页，p50 | — | **3.8 ms** |
| 翻页，p95 | — | **4.7 ms** |
| 观测到的最差值 | 97.4 ms | 9.6 ms |

在 60 次迭代、4 页、146 个应用的条件下复测：p50 2.1 ms、p95 3.0 ms、最差 11.0 ms。绝对耗时
会随机器和每次运行浮动 —— 真正有意义的是 p95 对照 16.7 ms 预算的余量。

60 fps 的预算是 16.7 ms，所以 p95 现在有充足余量。共三处改动：

1. **悬停状态按格子隔离。** 每个格子持有自己的 `HoverState`（`@StateObject`），因此悬停只重绘
   一个图标，而不是整个 deck。
2. **分页不在网格的观察图里。** `PageIndicator`（已稳定的页码，只被圆点读取）与 `PageJumper`
   （一次跳页请求，只被滚动容器观察）是两个独立对象；滚动容器以普通引用持有 indicator，因此写它
   不会重建网格。
3. **没有双向滚动绑定。** 页码由 `onScrollGeometryChange` 推导，而它只在推导出的页码变化时才
   触发。原先的 `scrollPosition` 绑定每帧发布两次，并通过 `onChange` 又喂出第二次发布。

此外还移除了逐图标的 `.shadow` 与 `.interpolation(.high)`；两者都会为每个格子强制一次离屏渲染。

## 已知缺口

- 捏合会对**任意**手指数触发。AppKit 只暴露捏合缩放量，不暴露产生它的手指数；原生 Launchpad
  读的是一个私有多点触控框架来区分三 / 四 / 五指。
- 轮换的桌面不记录「当前」是哪张图，所以 deck 每个轮换槽位挑一张照片，而不是精确镜像屏幕上那张。
  要做到精确匹配需要屏幕录制权限。
- 文件夹的放大是面板自身的 transform，而非独立的代理图层，所以它不会像 Launchpad 那样让格子
  自己的图像一起变形。
- 热区用的是全局鼠标监听，因此指针必须真的移动到角落；Launchpad 自己的实现行为相同。
- 投放到页码圆点上会把条目移到该页的**末尾**。指针下方不存在可插入的网格位置，这与 Launchpad
  一致。跨页的精确位置靠拖到边缘来调整，它会实时重排。
- 没有备份的导入 / 导出，没有多语言字符串，没有自动更新。自动更新与授权激活是原版里唯二对个人
  使用确实没有必要的东西。
- 展开文件夹的呈现是居中的毛玻璃面板，而不是「从图标放大展开」的动画。

## 参与贡献

构建 / 测试流程与代码约定见 [CONTRIBUTING.md](CONTRIBUTING.md) —— 其中最重要的一条是：每一处
新增的检查都必须经过变异测试，证明它**确实会失败**。附带
`~/Library/Application Support/LaunchDeck/layout.json` 的 bug 报告会好处理得多；它就是全部的
持久化状态。

上面列出的这些修复背后的开发过程记录保存在本机的评审笔记里，不随仓库发布。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
