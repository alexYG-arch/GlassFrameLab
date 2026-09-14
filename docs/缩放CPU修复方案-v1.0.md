# 缩放 CPU 修复方案 v1.0

日期：2026-09-13。状态：**CLOSED_WITH_KNOWN_ISSUE；用户接受最大尺寸 RSS 已知问题后，剩余验收已完成**。方案交付时为 planned_not_implemented；用户随后明确授权“执行”，已启动 [UP-02](workpacks/UP-02.md)。WP-09 保持 **BLOCKED_STALLED**，原 R1～R5、F1～F4 和失败数据完整保留。

目标：在不降低视觉质量、物理像素、动态帧率、取证完整性或既定预算的条件下，解决 R09-05 的连续缩放 CPU 超限，并完成固定新构建的本机验收。建议执行时另立限定工作包 **UP-02**；该工作包已获执行授权，实际 R/F 与验证状态以工作包记录为准。

## 1. 结论与修复顺序

目前已证实“缩放 CPU 未达标”，尚未证实唯一根因。下一轮先量化热路径，优先检查**几何提交中的诊断构造/写入，以及窗口布局与提交**；仅当证据指向它们时才修复。不要继续叠加未经量化的 layer 属性调整。

建议顺序是：测量归因 → 保持行为的低风险优化 → 必要时处理窗口/捕获重复工作 → 原预算正式验收。事务呈现或 CAMetalDisplayLink 属于条件性备选，不预先改造渲染架构。

需要区分两个目标：把工作移出主线程可能改善交互延迟，但不必然减少整个进程 CPU。R09-05 要求后者；“主线程更空闲”不能替代 CPU ≤15%。

## 2. 已知事实及代码依据

| 事实 | 证据 | 推理边界 |
|---|---|---|
| R3 / R4 / R5 正式缩放 CPU 为 15.03665% / 16.44% / 15.7364% | [R3](evidence/WP-07-resize-20260913T101343Z/result.json)、[R4](evidence/WP-07-resize-20260913T103146Z/result.json)、[R5](evidence/WP-07-resize-20260913T104528Z/result.json) | 不同构建、不同运行，不能相减后声称修复的因果收益。 |
| F4 短测 CPU 为 10.9405%，正式五分钟未通过 | [短测](evidence/WP-07-resize-20260913T104049Z/cpu-diagnostic.json) | 短测不能预测稳态通过；不得只挑末段或某一分钟。 |
| R5 正式五分钟各分钟 CPU 中位数约 15.739、15.948、16.229、15.516、14.971% | [既有数据分段](evidence/WP-09-verification-20260913T104528Z/cpu-minute-diagnostic.json) | 超限不只发生在单个瞬时尖峰；也没有单调增长证据，不能直接归因于累积泄漏或热降频。 |
| R5 FPS 30、间隔 P95 41.666625 ms、GPU P95 2.97308 ms、延迟最大 82.83325 ms，其余缩放检查通过 | [R5 结果](evidence/WP-07-resize-20260913T104528Z/result.json) | GPU 预算有余量，但 GPU 时间不覆盖主线程、文件系统或取 drawable 的等待。 |
| R5 全程几何提交 8,396 次；每次 onCommit 都构造几何诊断，并同步写一个独立 JSON | [main.swift](../Sources/GlassFrameLab/main.swift)、[Diagnostics.swift](../Sources/GlassFrameLab/Diagnostics.swift) | 8,396 是全程计数，不是严格 300 秒窗口计数。`writeJSON` 使用 prettyPrinted、sortedKeys、atomic；没有输出目录时不写盘，仍需检查调用点构造成本。高频路径存在，不等于它占据主要 CPU。 |
| 既有 sample 调用栈出现 AppKit 布局/绘制、窗口提交、诊断写入和等待 | [调用栈](evidence/WP-07-resize-20260913T102041Z/cpu-sample.txt) | sample 栈的出现次数不等于忙 CPU 占比，不能据此精确分摊成本。 |
| 捕获与几何已有去重和有界调度 | [WindowGeometryController](../Sources/GlassFrameLab/WindowGeometryController.swift)、[LocalCaptureService](../Sources/GlassFrameLab/LocalCaptureService.swift) | 已有相同几何直接返回、单个待更新窗口、相同 mapping/rate 跳过 SCK 更新、过渡采样包围框。不能重新实现一套“去重”并假定有收益。 |
| 几何文件是部分测试的实时触发信号 | [check_geometry.py](../scripts/check_geometry.py) | 脚本发现 geometry 文件后等待 0.2 秒截图。异步或延后发布会改变截图时序，需要单独证明关联正确。 |

当前失败基线为 `RrZwDN`，与 ZIP 内可执行文件一致，见 [打包身份](evidence/WP-09-verification-20260913T104528Z/package.json)。没有把旧构建的通过项拼入当前验收。

## 3. 文献与论坛推理

以下是技术文档、官方讲座、作者实验和论坛原帖；不是同行评审论文。检索与核验日期为 2026-09-13。来源支持机制和实验设计，不承诺本项目收益。

| 编号及来源 | 可支持的观点 | 本方案如何使用 |
|---|---|---|
| S1：[Apple WWDC25 — Optimize CPU performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/308/) | 先用数据定位 CPU 工作；定时采样可能与周期工作发生混叠，CPU Profiler 可提供另一种观察。工具本身也有开销。 | 对 30 Hz 管线同时考虑 CPU Profiler 与 Time Profiler；分析录制在测量后进行，带 profiler 的运行不作为正式预算。 |
| S2：[Apple WWDC23 — Analyze hangs with Instruments](https://developer.apple.com/videos/play/wwdc2023/10248/) | 忙线程与阻塞线程需要不同分析；线程状态和调度证据补足单纯热点栈。 | Time/CPU Profiler 定位忙工作，System Trace 区分等待、可运行但未调度与实际运行；不将所有等待归为 CPU 消耗。 |
| S3：[Apple — Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes) | File Activity 可关联文件活动与调用栈；频繁创建、原子替换以及小写入带来额外工作，批量处理存在内存取舍。 | 优先测几何 JSON 路径。文档中的具体 iOS 元数据字节数不套用到本机 APFS；也不因其建议批量写入就改变当前取证契约。 |
| S4：[Swift Forums — Quinn / Apple DTS，Task safe way to write a file asynchronously](https://forums.swift.org/t/task-safe-way-to-write-a-file-asynchronously/54639/7)，2022-01-16 | Apple 文件系统调用涉及同步工作；小文件同步 I/O 不必一概禁止，把调用放进 Task 也不会自动使内核工作无阻塞。 | 不把 async/await 当作降低总 CPU 的修复；后台写入只在实测主线程阻塞重要时评估，并限制排队。属于当时的工程解释，不声称覆盖未来所有 API。 |
| S5：[Apple — Recording Performance Data](https://developer.apple.com/documentation/os/recording-performance-data) | signpost 可为任务标记区间及独立实例 ID。 | 把几何 revision、采样 sequence 与阶段区间对应；区间表示墙钟时间，CPU 归因仍需 profiler 或线程 CPU 计时。 |
| S6：[Apple Developer Forums — Redraw MTKView when its size changes](https://developer.apple.com/forums/thread/77901)，2017～2019 | 官方人员和使用者讨论固定 drawable、内容拉伸及窗口边缘滞后的取舍。 | 不采用固定低分辨率旧图拉伸来降低 resize 成本；论坛历史问题不等于当前 macOS 的根因。 |
| S7：[Tristan Hume — Glitchless Metal Window Resizing](https://thume.ca/2019/06/19/glitchless-metal-window-resizing/)，2019-06-19 | 作者通过 CAMetalLayer、事务呈现及特定等待顺序改善其测试项目，并处理高 DPI 尺寸。 | 作为同步方案的实验线索；不能直接移植到本项目异步 SCK 管线或声称会降低 CPU。 |
| S8：[Apple Developer Forums — drawableSize 更新后 nextDrawable 约 1 秒](https://developer.apple.com/forums/thread/773229)，2025-01 | 发帖者报告取 drawable 停顿，DTS 建议 CAMetalDisplayLink，但未给出该个案的完整根因说明。 | 只有本机 trace 也定位到 drawable/调度问题时才评估；目前 R5 最大呈现延迟没有复现该帖的约 1 秒现象。 |

补充交叉检查：本机 SDK `CAMetalLayer.h` 说明 `presentsWithTransaction=false` 与正常 layer 更新异步；因此现有截图和提交顺序不是系统级同帧原子保证。`CAMetalDisplayLink.h` 声明 macOS 14 起可用，项目 macOS 13 部署目标仍需版本分支。线上 presentsWithTransaction 页面本轮正文受 JS/Markdown 抓取限制，具体机制采用已读取的 SDK 注释，不把仅见链接写成已读全文。

此前的光效/缓存资料继续见 [WP-09 文献对照](性能优化依据与论坛对照-WP09.md)。

## 4. 待验证假设与选择规则

| 假设 | 应取得的证据 | 证据支持后可选的最小修复 | 不支持时的处理 |
|---|---|---|---|
| H1：几何诊断构造、序列化或文件操作贡献了重要忙 CPU | CPU 栈归因、序列化/写入独立区间、File Activity 事件、受控对照的进程总 CPU | 先减少等价表示的构造/格式化成本，保留每次记录、字段、时间戳语义、文件名和原子发布；只有等待占主线程关键路径时再考虑有界串行写入 | 不继续调日志；不能用禁用诊断或少写文件的结果验收。 |
| H2：AppKit 几何提交、布局或 flush 有可避免的重复工作 | setFrame/layout/draw/flush 的调用次数、输入相等比例、忙 CPU 与墙钟时间；对照真实几何提交 | 仅消除已证实的同值 setter 或同一目标的重复失效；维持最新几何、真实 drawable 尺寸及呈现关联 | 不再凭感觉修改 display、layer backing 或 flush。F3/F4 既有结果不支持“调这些属性必然解决”。 |
| H3：捕获配置构造或 SCK 更新发生无效重复 | 配置构造次数与真正 updateConfiguration 次数分开统计；mapping/rate/envelope 变化、耗时关联 | 若同一有效配置被重复构造且占显著成本，缓存经验证的输入键；屏幕、比例、sigma、ROI、帧率和生命周期变化必须失效 | 已有去重有效则保持。不得扩大到全屏采样或延迟必须的映射更新。 |
| H4：CPU 在取 drawable / 等待呈现链上受调度影响 | nextDrawable、GPU 编码/完成、present、CA flush 的区间与 System/Metal Trace | 另行比较正确的事务呈现顺序或按需 display link；先验证本机适用性和静态停绘 | 若主要是等待而非 CPU，不能用该方向解释 R09-05；若预算与体验都无问题则不改。 |
| H5：像素比较、纹理包装等其他 CPU 工作是实际热点 | 捕获回调中 equalPixels/锁像素与 CVMetalTexture 包装的忙 CPU，按尺寸与 sequence 关联 | 仅针对已测热点减少等价重复操作；不能把近似像素比较替代现有精确静态去重 | 不因函数看起来昂贵就改 shader、模糊或静态判定。 |

候选必须同时满足：调用链可解释、受控对照方向一致、总 CPU 改善超出同组基线波动、视觉/延迟/资源无退化。单次好结果或总耗时区间变短，不足以证明忙 CPU 减少。若诊断后仍无可信归因，交付诊断结论并暂停候选选择，不将所有假设一起实现。

## 5. 分阶段执行与可交付证据

### P0：冻结实验及工具入口

执行授权后先保留 RrZwDN 可执行文件、ZIP 和配置；不依赖可能过期的 `/private/tmp` 目录。使用相同编译模式、fixture、轨迹、尺寸、输出目录所在卷、供电、显示器与背景。记录其他前台活动、热状态和低电量模式；受 Finder 切换、锁屏等干扰的运行保留并标识，按预先规则判无效，不挑选数据。

本机默认 `xcode-select -p` 为 CommandLineTools，直接 `xcrun --find xctrace` 失败，但 `/Applications/Xcode.app/Contents/Developer/usr/bin/xctrace` 实际存在，版本输出为 16.0 (17F42)。已只读核验模板含 CPU Profiler、Time Profiler、System Trace、File Activity、Metal System Trace、Logging。使用绝对路径，不全局切换开发目录；CLI 需要访问其缓存目录，真正录制仍须届时确认权限与可采数据。模板存在不等于已成功录制。

交付：环境记录、固定实验参数、基线身份、阶段/线程/事件计数定义。该阶段不打开测试窗口。

### P1：定位成本，建立可证伪的归因

先用原基线在固定缩放轨迹上进行一次 CPU/线程分析；按发现补充一次 File Activity 或 Metal 分析，避免所有重型模板同时运行。30 秒预热后分析 60～90 秒，录制结束后再做离线分析。此长度用于归因，不是正式预算。

仅在现有工具无法关联调用链时添加小范围诊断：GeometryApply、GeometryRecordBuild/Serialize/Write、CaptureConfiguration、UpdateConfiguration、DrawableAcquire、Encode/Complete、Present/Flush。每个区间带已有 revision/sequence，异步区间结束要匹配同一实例；墙钟时间不得相加后当成进程 CPU，因为阶段可能重叠、线程可能等待。

至少输出：各阶段次数、忙 CPU 热点及采样限制、区间 P50/P95/max、文件事件数/字节数、真实 SCK 更新次数、几何提交与呈现次数。`getrusage` 的进程 user+system CPU 仍是总 CPU 口径。必要时用线程 CPU 计时补充同步小区间，但不能跨 await 直接作同线程差分，也不能将嵌套区间重复相加。

H1 允许做一次显式的诊断对照：原写入与内存接收记录比较，用于估计文件路径影响；后者必须标记 DIAGNOSTIC_ONLY，不能参与验收，也不能用差值承诺实际修复收益。是否增加此对照由 trace 决定，不默认引入长期模式。

交付：`diagnosis.md`（事实/假设/反证/选择）、trace 或导出的可读摘要、受控对照数据。新增探针关闭时不应自激循环，正式验收不附加重型 profiler。

### P2：只实现被证据支持的候选

优先选择不改变线程及文件发布时机的修复。例如 H1 若由序列化占主导，可比较等价的紧凑编码或复用稳定字段；记录仍一条不漏，解析后的字段和值一致，时间戳在真实几何提交时产生，不在写盘时补写。不先取消 `.atomic`：实时读者存在，禁止暴露半个 JSON。

若必须移出主线程，另增加以下约束：AppKit 状态在主线程快照；后台只处理不可变记录；单串行执行器，排队同时受条数和字节数限制（初始提案上限 64 条 / 256 KiB，任一先到即满）；不逐条创建无界 Task。满队列或写失败显式使取证失败，不丢记录、不静默回退为降低采样频率。还须证明 `check_geometry.py` 对应截图的事件关联，不能让迟到文件指向已变化的窗口。

后台化本身不会减少总工作；只改善延迟而 CPU 仍超限的候选不解决 R09-05。持续记录积压也不能把 CPU 挪出正式窗口：记录入队/完成时间、数量和队列高水位，报告 300 秒内以及结束 drain 的 CPU 与耗时；仍在积压的结果不可验收。隐藏/退出必须有界收敛，释放写入资源，且不能破坏既有隐藏预算。

H2/H3 的修复沿用现有调度与失效规则，不新增第二套状态机。H4 若需要替换呈现管线、引入版本分支或全新驱动方式，视为扩大范围，先更新候选设计，不与日志优化混在一次改动中。

候选只做一组预先约定的 A-B-B-A 对照：相同负载、每次预热 30 秒并记录 90 秒，保留四次全部结果；A 为基线，B 为候选。该组只判断方向与波动，不能替代五分钟验收。不重复运行到碰巧出现好结果；方向不稳定则不宣称有效。

### P3：固定候选后正式验收

先运行现有 22 项支持模块和 6 项生命周期检查；按实际改动补充必要测试。只改同步编码时验证字段等价、文件原子可读与错误传播；只有引入后台写入才验证顺序、满队列、失败和关闭 drain。几何/捕获修改必须覆盖取消、恢复与过期帧，不写仅照抄实现的测试。

然后冻结同一候选构建，按既有脚本先跑五分钟缩放。通过后补一次独立同条件五分钟缩放确认，两次均按原阈值判断、全部报告，不平均成通过。该重复针对本次短测与长测差异，不是无限重跑。任一次失败即为 finding。

两次缩放通过后，同构建完成默认静态/动态/效果全关、最大尺寸、拖动、默认与最大尺寸各 20 次恢复、隐藏停采、兼容恢复、动态几何及样式切换。完成 22 组视觉矩阵和真实白色/图案/Finder 背景，复核圆角、外扩散、非均匀内光、前景清晰度及恢复帧。

WP-08 的旧构建真实锁屏、权限、全屏等证据保留来源。若改动仅同步诊断编码，记录适用性说明并做相关当前回归；若触及生命周期、异步 drain、SCK 或呈现恢复路径，必须重验受影响的真实场景。需要用户配合的锁屏只在确有该依赖且采集已准备好后提出，不反复无目的锁屏。

交付：同构建预算汇总、最终视觉判断、回归证据、ZIP 一致性和新的验收报告。旧 WP-09 仍保留历史 BLOCKED_STALLED，由授权后的 UP-02 验收报告说明 R09-05 如何关闭及哪些旧证据可复用，不把 WP-09 重命名为 R6。

## 6. 不可改变的验收契约

采用 [冻结预算](workpacks/WP-00-performance-budget.md)，本机 Apple M4 / macOS 26.5.2 / 内置 2x。默认主体 800×100 物理像素、透明输出 824×124，sampleScale 0.5；局部采样，不捕获音频/指针，排除自身窗口。不改空框体范围，不降低光效。

| 门槛 | 要求 |
|---|---|
| 正式时间与统计 | 30 秒预热 + 300 秒测量，CPU/RSS 约 1 Hz；nearest-rank P95；报告全部样本和零呈现时间 |
| 默认动态/拖动/缩放 CPU | 单核中位数 ≤15%；静态 ≤3% |
| 默认质量 | 呈现中位数 27～30 FPS，间隔 P95 ≤50 ms，GPU P95 ≤12 ms |
| 延迟 | 采样到呈现 P95 ≤100 ms、最大 ≤250 ms；保留过期几何拒绝，不删除已呈现慢帧 |
| 内存 | 默认相对同构建无窗口基线增量 ≤128 MiB；五分钟斜率 ≤1 MiB/min，末分钟减首分钟 ≤5 MiB |
| 恢复/隐藏 | 默认与最大尺寸 20 次恢复后隐藏 10 秒，相对预热隐藏基线 ≤10 MiB；隐藏 1 秒内停采停周期提交，稳定缓冲/在途为 0，CPU ≤无窗口基线 +0.5 个百分点 |
| 资源 | queueDepth=3，保留最新缓冲 ≤1、GPU 在途 ≤1、应用中间纹理 ≤4；drawable/IOSurface 另列，不将 SDK 池上限当作实测分配量 |
| 最大尺寸 | 使用本机实际允许尺寸，报告全部指标；硬门槛按既有规则为资源有界、隐藏停止和稳态内存，不擅自扩大默认 CPU 门槛适用范围 |
| 视觉与证据 | 实际 drawable 与目标几何一致；圆角无毛边、不靠拉伸旧图遮掩；完整逐帧指标与逐提交记录，不关闭诊断验收 |

可把 CPU ≤13.5% 作为候选的工程余量目标，便于判断是否值得进行整批验收；它不是用户已接受的新硬门槛。正式 PASS 仍按 15%，但必须报告两次独立结果。CPU/GPU 改善仅为能耗代理，不声明降低了多少瓦。

macOS 13 实机、外接/跨屏、非 2x 与实际窄屏继续 BLOCKED_VERIFICATION，不纳入本次已验证范围，也不写为不适用。

## 7. 文件范围、轮次与回滚

预期文件只限命中假设的部分：H1 为 `Diagnostics.swift`、`main.swift`；H2 为 `FramePanel.swift`、`WindowGeometryController.swift`、必要的 renderer 提交入口；H3 为 `LocalCaptureService.swift`；H4 涉及 `GlassRenderer.swift`、`RealtimeGlassController.swift`，需先明确范围。测试与证据脚本仅改关联部分。禁止修改预算分析阈值、fixture 轨迹、视觉参数或扩大产品功能来解决本 finding。

执行授权后的 UP-02 遵守 [规约 §7.0](../开发规约与工作包计划.md)：最多 5 次只读 R、4 次对应 F。建议 R1 核对基线/归因方案，必要的探针进入 F1；R2 完成归因并选择最小 F2；R3 验证候选和收齐验收。仅有具体 finding 才进入剩余 F/R，R5 仍有 finding 则 BLOCKED_STALLED。归因与 A/B 都记在工作包内，不另起无限试验循环。新的最终视觉最多 3 次，纳入相应 R；此额度随新工作包执行授权确认，当前没有重置旧 WP-09 计数。

预估：归因与一组 A/B 约 15～30 分钟纯运行时间；完整验收加独立缩放确认约 40～50 分钟，代码分析、修复及图像审查另计。这是规划估算，不是已测耗时或完成承诺。测试结束/失败均关闭本项目窗口、fixture 和临时防休眠；不启用 CUA 指针。

回滚按单候选进行：保存基线及变更清单，失败后恢复该候选涉及的源码和构建，不覆盖用户后续编辑、不删除证据。RrZwDN 只是失败基线，回退到它不能称作恢复已验收版本。所有未通过候选标记未验收；不得发布或将 ZIP 标记为正式完成。

## 8. 方案交付与后续授权

方案交付阶段完成代码与旧数据复核、文献/论坛检索、本机 profiler 工具可用性核验；当时没有修改产品代码、启动原生测试或声称修复已实现。

用户后续确认“执行本方案”时，按本方案建立 UP-02 并开始 P0；如果只要求调整方案，则继续保持 planned_not_implemented。当前不需要为了交付这份方案额外确认性能预算。

用户随后授权执行：UP-02 已开始，旧 WP-09 计数与失败状态保留，当前进度见工作包。

## 执行中发现的关联内存问题（R3 / F3）

固定构建 9mXYWr 两次正式缩放 CPU 已通过。完整验收发现最大尺寸 RSS 在第一次逐像素判定相等时跳升约 9.09 MiB，随后平稳；原稳态预算仍判失败，未裁剪样本或延长预热。此关联触发 H5 的精确重复读取检查。F3 采用元数据先确认零变化、其他情况保留精确比较的限定候选，不改轨迹、预算或光效。

[Apple WWDC22](https://developer.apple.com/videos/play/wwdc2022/10155/) 说明 dirty rects 描述相对上一帧的变化区域；本机 SDK 说明包含重绘与移动区域。[WebRTC 原始实现](https://webrtc.googlesource.com/src/+/f7c1d7e4d3c1fe207eef6ed6251812cb6b982644/modules/desktop_capture/mac/screen_capturer_sck.mm) 根据零面积矩形判断未更新，并特别避开尺寸重配后的附件。项目只采用保守的零面积判断，不对局部区域做坐标投影或近似比较。来源支持机制，候选是否解决本机内存问题以新证据为准。

## 执行结论

UP-02 R5 仍有 U02-06 最大尺寸 RSS 问题，按本方案 §7 停止；缩放 CPU 的 6 行修复已通过两次正式测量，未证实的元数据候选已撤回。见 [执行报告](缩放CPU修复与最终验收-UP02.md)。后续 [UP-03 方案](最大尺寸RSS复核与后续修复方案-UP03-v1.0.md) 尚未启动，不自动重置轮次。

## 用户接受后的本机闭合

用户明确接受 U02-06 延期排查，并授权完成当前构建拖动及最终视觉验收。该收尾已完成，当前本机状态为 CLOSED_WITH_KNOWN_ISSUE，见 [报告](缩放CPU修复与最终验收-UP02.md)。此前 R5 停止和原 RSS 数值失败保留为历史，UP-03 不启动。
