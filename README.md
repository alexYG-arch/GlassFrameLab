# GlassFrame Lab

> **material 分支：系统后端已实现，本机补测通过；两项真实辅助设置按用户决定延期，等待视觉选择。** 依据 [迁移计划 v1.0](docs/material系统材质迁移计划-v1.0.md)，进度及差异见 [实施记录](docs/material实施与验证记录-v1.0.md)。默认仍为 custom；main 与正式交付包保持原样。
**历史基础版本按“带已知问题验收”闭合；当前 Light 仅柔光视觉 v1.9.3 已被用户采用并重新打包，正常 app 的屏幕录制授权恢复仍待验证。** 当前构建 9mXYWr 的正式拖动、两次缩放及最终视觉验收完成；最大尺寸 RSS 偏差按用户决定延期排查。见 [验收报告](docs/缩放CPU修复与最终验收-UP02.md) 和 [已知问题](docs/本机已知问题.md)。

部署目标为 macOS 13 的自定义玻璃框体项目；本版实际验收限定为 Apple M4 / macOS 26.5.2 / 内置 2x 屏，其他系统及显示环境仍待验证。默认启动无系统装饰的实时玻璃框体，**本机升级已闭合：UP-02 为 CLOSED_WITH_KNOWN_ISSUE；U02-06 最大尺寸 RSS 偏差已接受并延期排查**。根因与截图见 [圆角毛边排查](docs/圆角毛边排查-WP07.md)，需求及工作包门禁见 [开发规约与工作包计划](开发规约与工作包计划.md)。

## 系统后端开发入口

```sh
bash scripts/build_source.sh
.build/release/GlassFrameLab --material-backend system
# 显式开启流光；Light 只显示柔光，Dark 线与柔光同时显示。
.build/release/GlassFrameLab --material-backend system --border-flow
```

system 不采屏，材质由系统合成；附加光效按应用/系统外观切换，不按窗后像素切换。正式打包流程仍保留 custom 默认值，不能将旧打包命令当作系统版交付。

系统专项检查：`check_system_flow.py`（GPU 透明层）、`check_system_material.py base|visual`（真实系统底材/交叉外观）、`check_system_smoke.py`（有限功能及短资源）、`check_system_visual_edges.py`（整圈/Finder/故障）、`check_system_motion.py`（时钟对齐的运动截图）、`check_system_theme.py`（真实系统主题切换后恢复）。原始证据留临时目录，验收摘要见实施记录。

## 构建与运行

需要带 macOS SDK 的 Swift 5.9+ 工具链（本机使用 Command Line Tools 中的 Swift 6.3.2），无需第三方依赖。应用部署目标为 macOS 13。

本机 CLT 缺少 XCTest，且自带 Testing 框架缺少运行时依赖，因此测试入口使用直接调用生产 `LabSupport` 模块的 Swift 检查程序；每项断言独立执行，失败返回非零退出码，不依赖 XCTest 或 Testing。

```sh
bash scripts/build.sh
open build/GlassFrameLab.app
```

为避免 iCloud 对 app 包写入 Finder 元数据而破坏签名，签名后的运行实例位于 `/private/tmp/glassframe-build.*`；`build/GlassFrameLab.app` 是启动链接，`build/GlassFrameLab.zip` 是保留在项目中的完整应用压缩包。临时目录被系统清理后重新构建，或将压缩包解压到本地应用目录运行。

默认显示 800×100 **显示像素**的框体：2x 屏幕上为 400×50 pt。没有系统标题栏、红黄绿按钮、外围底板或内部文字；右键选择“关闭”退出。当前材质使用真实局部采样与 Metal 高斯模糊；已实现零偏移暗色外扩散、非均匀内发光和独立细边。`--frame-carrier` 可显式回到窗口承载测试。

历史 WP-00 校准图案保留在显式 `--calibration` 模式中（800×240 pt 普通测试窗口），与产品框体尺寸无关。`--animate` 会选择带动画的校准模式。

## 验证

```sh
bash scripts/test.sh
python3 scripts/check_failures.py
python3 scripts/measure_baseline.py
python3 scripts/check_frame.py
python3 scripts/check_window_lifecycle.py
python3 scripts/check_geometry.py
python3 scripts/check_capture.py
```

测量脚本顺序运行 15 秒无窗口基线、15 秒静态窗口、20 秒动画窗口，并只对本应用的静态测试窗口截图两次。每次在 `docs/evidence/WP-00-<UTC时间>/` 保存独立结果，不覆盖已有运行。原生窗口截图受当前系统权限与图形会话影响，失败会记录在 `screenshot-results.json`，不能算截图验证通过。

`check_frame.py` 验证实际 800×100 px 窗体和截图。`check_window_lifecycle.py` 要求先关闭其他测试实例，再在 18 秒内用临时测试窗口验证显示/隐藏/移动和原生全屏 Space，并自动恢复；这是显式开发测试，不是产品内部界面，也不证明所有第三方全屏应用兼容。

也可直接运行已构建程序，使用一个新的输出目录：

```sh
build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab --animate --duration 20 --output /tmp/glass-frame-run
```

`--baseline` 不创建窗口，不能与 `--animate` 同用。未传 `--duration` 时由用户手动退出。`--output` 可省略，此时不保存证据。默认实时模式只读检查已有录屏权限，已授权则局部采样并实时更新；未授权或采样失败时显示系统材质 fallback，不自动弹出授权请求，授予录屏权限后重新启动可进入自定义材质；`--frame-carrier` 不采集背景。显式 `--capture-probe` 检查已有权限并局部采集框体背后的画面，关闭音频/光标且排除本应用；未授权则报告 `permission_required`，不自动弹出授权请求。配合 `--output` 时会显示一个临时纯色色块验证自身排除，并在隐藏后检查停采；测试入口建议设置 `--duration 8`。`check_capture.py` 额外依赖 Python Pillow，仅用于检查测试截图。

默认框体可用 `--width-px 1600 --height-px 300` 指定期望显示像素尺寸；`--geometry-probe` 自动验证运行中的放大、超限和恢复。超限时遵守屏幕边界，未提供尺寸时仍为 800×100 px。

## 单帧玻璃预览

```sh
build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab --glass-preview --sigma 12
```

`--sigma` 为采样纹理像素，范围 0～40；0 可对照原始背景。`--foreground-probe` 仅在此模式添加清晰的临时前景标记。预览使用一次真实局部采样结果，经 Metal/MPS 模糊后显示，随后停采；移动窗口或背景变化不会刷新这一静态预览。`python3 scripts/check_glass_preview.py` 验证三种预览并保存截图供视觉审查。默认启动提供实时更新。旧 WP-05 构建性能预算已通过，恢复时序问题已由 UP-00 修复；当前本机视觉与性能状态见 [UP-02 报告](docs/缩放CPU修复与最终验收-UP02.md)。

## 实时测试

### 玻璃材质配置

默认配置集中在 `GlassStyle`，可复制 [完整 JSON 模板](Config/glass-default.json) 修改后用 `--style 路径.json` 启动。模板字段为完整配置，不省略键；参数按命令行从左到右应用，因此把单项覆盖和关闭开关放在 `--style` 之后。

```sh
build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab --style Config/glass-default.json
build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab --no-outer-glow
build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab --no-inner-glow
build/GlassFrameLab.app/Contents/MacOS/GlassFrameLab --no-edge
```

外扩散、内发光和细边独立控制；三个关闭开关保持透明留白和采样大小不变，便于比较 shader 成本。`shadowExtent` 为每侧透明留白和外扩散范围，单位 pt；默认 6 pt。`innerWidth`、`cornerRadius`、`strokeWidth` 也用 pt，内光带宽度另受主体短边 12% 上限约束；`sigma` 使用采样纹理像素。`shadowColor`、`innerColor`、`tintColor` 为线性 RGB 的 0～1 数组；各 opacity/strength 为独立合成强度。光照方向只改变内光带/细边分布，不改变外扩散的零偏移。

`--style-probe` 是显式实时测试入口，在 3/6/9 秒切换外光晕、内光晕并恢复默认。它应在静态背景上完成三次额外合成，复用一次背景模糊；该入口的帧延迟包含复用图像的年龄，不能用于动态采样延迟预算。`scripts/check_style_updates.py` 验证重绘和模糊次数；`scripts/check_glass_style.py` 保存六类背景、两种尺寸及逐层开关的真实截图。测试文字/图案均属于独立夹具，不是产品内容。

`bash scripts/build_fixture.sh` 构建独立的背景图案测试进程；`caffeinate -di python3 scripts/check_runtime_smoke.py` 检查静态去重和 20 次显示/隐藏，约 2 分 30 秒。`python3 scripts/measure_glass_performance.py <已通过的 cycles 证据目录>` 固定当前构建，逐场景预热 30 秒后测量 5 分钟；无窗口基线与静态场景同环境并行，动态、最大尺寸和关闭新增边缘效果的动态对照随后串行。测量脚本仅在自身存活期间用临时电源断言阻止自动睡眠，结束自动释放，不改系统设置；手动锁屏或桌面不可用则中断，不能计作通过。产品应用不持有该断言。测试夹具仅用于可重复输入，不能作为真实视频或第三方应用兼容性证据。

`--test-corner` 将测试框体置于另一个固定位置，绕开电脑操作工具遗留的动画指针高亮；默认产品仍居中。静态/动态默认尺寸的采样面积保持不变。测试期间移动框体或让其他内容覆盖夹具会使结果无效。

## 数据口径

- `resident_bytes`：进程驻留内存，不能当作 GPU 分配或 physical footprint。
- `cpu_percent_one_core`：进程 user+system CPU 时间与实际采样间隔的比值，100% 对应一个 CPU 核心。
- `draw_calls_per_second`：实际 NSView 绘制调用次数，不能当作屏幕呈现 FPS。
- `frames.csv`：GPU command 时间与真实 `MTLDrawable.presentedTime` 分开记录；呈现时间 0 表示未呈现/跳过，延迟留空，不计作有效 FPS。
- `runtime-samples.csv`：采集、像素变化、提交、在途帧和纹理分配计数。
- `environment.json`：系统、屏幕尺寸/缩放、电量模式等运行环境。
- `ready.json` 与 `termination.json`：应用就绪和正常退出证据，不是工作包通过证明。

旧 WP-05 构建的同版本预热 30 秒后五分钟静态、动态、最大尺寸测量，以及 20 次显示/隐藏检查已完成：[完整结果](docs/evidence/WP-05-performance-20260911T043556Z/result.json)。默认动态中位 29 FPS、CPU 中位数约 4.20%；静态预热后无重复渲染。结果通过[性能预算 v1.1](docs/workpacks/WP-00-performance-budget.md)，没有精确瓦数测量，也不代表生命周期和最终产品验收通过。

## 当前审查

本次新增视觉要求的执行方案见 [玻璃框体视觉升级计划 v1.0](docs/玻璃框体视觉升级计划-v1.0.md)。执行状态见 [UP-00](docs/workpacks/UP-00.md)、[UP-01](docs/workpacks/UP-01.md) 和 [WP-06](docs/workpacks/WP-06.md)。当前 2x 默认主体仍为 800×100 px，含透明留白的窗口为 824×124 px；光晕已接入，升级验收进行中。

[WP-00（已关闭）](docs/workpacks/WP-00.md)、[WP-01（已关闭）](docs/workpacks/WP-01.md)、[WP-02（已关闭）](docs/workpacks/WP-02.md)、[WP-03（已关闭）](docs/workpacks/WP-03.md)、[WP-04（已关闭）](docs/workpacks/WP-04.md)、[WP-05（历史阻塞记录）](docs/workpacks/WP-05.md)。用户已授权 UP-00，恢复问题已关闭；UP-01、WP-06、WP-07 已关闭，WP-08 本机范围已关闭，WP-09 历史缩放 CPU 问题已由 UP-02 修复验证；用户接受最大尺寸 RSS 已知问题后，当前固定构建完成其余验收，UP-02 为 CLOSED_WITH_KNOWN_ISSUE。历史失败记录保留。

当前动态几何和性能证据见 [WP-07 性能报告](docs/动态几何性能报告-WP07.md)，降级与环境验证见 [WP-08](docs/workpacks/WP-08.md)。

WP-08 本机验证已完成，包括真实锁屏冷启动与解锁恢复；macOS 13、外接/跨屏、非 2x 和实际窄屏保留为后续未验证环境，详见 [兼容与降级验证](docs/兼容与降级验证-WP08.md)。当前系统降级材质保持框体可用，不等同于自定义 shader 的全部视觉参数。


最终验收可运行 `python3 scripts/verify_wp09.py`，会使用临时背景与实际 Finder 测试窗口，并串行执行完整性能场景；测试期间保持解锁且避免遮挡测试区域。需要先按上文构建产品及背景夹具。真实锁屏冷启动的独立协作入口为 `python3 scripts/check_real_lock.py`：它先编译本次只读诊断工具，看到 WAITING_FOR_LOCK 后再手动锁屏，保持约 10 秒再解锁；截图仅在公开解锁信号稳定后进行。

## 自适应与流光升级

当前采用：[v1.9.3 Light 仅柔光](docs/Light仅柔光映射试验-v1.9.3.md)。用户已确认视觉并授权重新打包：[应用 ZIP](build/GlassFrameLab.zip)。Light 隐藏流动细线、保留原蓝紫柔光，Dark 和基础玻璃描边保持原样；默认流光关闭，右键“流光效果”启用。包验证通过，新包短启动检测到尚缺屏幕录制权限，授权后的真实恢复仍待验证。

[背景自适应深色材质升级方案 v1.3](docs/背景自适应深色材质升级方案-v1.3.md)：Light 基线必须保持，流光采用同色相的深浅适配；RSS 短测不缩减功能/视觉检查。用户本次已授权更新 macOS 应用包；其他环境与已知问题边界保持。历史浅底颜色增纯见 [v1.8 记录](docs/浅底流光增纯修复-v1.8.md)，统一几何与渐隐依据见 [v1.7](docs/统一流光几何与渐隐修复-v1.7.md)，启动与功能背景见 [v1.4](docs/启动与功能修复记录-v1.4.md)。

源码检查：`bash scripts/test.sh`；功能探针运行 `.build/release/GlassFrameLab`。本次按用户要求另行运行打包脚本，验证见 v1.9.3 记录；历史检查不能替代新包权限恢复验证。
