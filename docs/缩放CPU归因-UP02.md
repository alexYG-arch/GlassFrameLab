# UP-02 缩放 CPU 归因记录

状态：F2 缩放 CPU 修复已验证；用户接受 U02-06 延期排查后，当前本机版本已完成带已知问题验收。2026-09-13，用户已授权执行 [方案](缩放CPU修复方案-v1.0.md)。

## 原构建 CPU Profiler

失败基线 RrZwDN；固定缩放轨迹，约 30 秒预热后录制 75 秒，仅目标应用进程。原生应用正常退出，录制完成。数据为诊断，不作为五分钟性能验收。

证据：[运行状态](evidence/UP-02-profile-cpu-profiler-20260913T110629Z/profile-result.json)、[CPU 表](evidence/UP-02-profile-cpu-profiler-20260913T110629Z/cpu.xml)、[统计摘要](evidence/UP-02-profile-cpu-profiler-20260913T110629Z/cpu-summary.json)。导出的 TOC 已移除环境字段；报告不包含自动采集的无关运行环境元数据。

14,919 条 Running 样本。以下比例是 CPU Profiler **运行周期权重**占比，不是单核 CPU 百分比，也不是墙钟时间。包含调用链的比例相互重叠，不相加。

| 路径 | 权重占比 | 解释 |
|---|---:|---|
| Diagnostics.writeJSON，最近应用帧归因 | 6.423% | 编码与写入值得量化，但不能认定为唯一主因。 |
| FramePanel.setFrame，最近应用帧归因 | 6.398% | 不含被归入更内层应用函数的工作，不等于整个几何提交成本。 |
| CA::Layer::display_if_needed 包含调用链 | 20.488% | 存在内容更新/回放成本，需定位具体层；不能直接等同 FrameSurface.draw。 |
| CAMetalLayer.nextDrawable 包含调用链 | 17.255% | 包含资源获取、纹理/IOSurface 等运行工作；具体墙钟等待仍需另测。 |

就 Diagnostics 路径进一步分解，JSONSerialization 对应约 2.41% 的总运行周期权重、Data.write 约 2.26%、URL.appendingPathComponent 约 1.45%。这些仍是采样近似值，不是期望可全部消除的成本。仅把写入移至后台并不能消除总 CPU 工作。

## F1 阶段探针

构建 exzc9Q，开启 GLASS_CPU_DIAGNOSTICS 后，在 30～120 秒内分别测同步线程 CPU 和墙钟时间；不跨 await，不将嵌套区间相加。默认关闭，不修改光效或取证数量。

首次启动的 [诊断](evidence/UP-02-diagnostic-F1-stages-20260913T111504Z/result.json) 在登录/锁屏界面停止，`capture_start_attempts=0`。该次无有效阶段测量，不能作候选或性能证据，等待用户解锁后重启同一诊断。

## 后续判断所需证据

优先对照 CAFlush 与 SurfaceDraw/SurfaceLayout 的次数及 CPU。如果 SurfaceDraw 很少而 CA 更新仍高，须考虑缓存内容回放或其他 backing layer，不能将两者混为一谈。只有测量支持时才采用透明层的最小更新路径。

[Apple wantsUpdateLayer](https://developer.apple.com/documentation/appkit/nsview/wantsupdatelayer) 明确允许视图通过 updateLayer 更新 layer，并要求覆盖相应方法；[onSetNeedsDisplay](https://developer.apple.com/documentation/appkit/nsview/layercontentsredrawpolicy-swift.enum/onsetneedsdisplay) 控制显式重绘。它们是可能的实现机制，不证明当前视图切换后一定更省 CPU。任何候选都必须保留 carrier/fallback 的原有可见内容和尺寸更新，并通过实际恢复截图验证。

## R2：解锁后的同步阶段结果

[F1 阶段计时](evidence/UP-02-diagnostic-F1-stages-resumed-20260913T115726Z/cpu-stages.json) 正常结束，零溢出，90 秒 CPU 中位数 14.87095%，仍只作诊断。

| 同步区间 | 次数 | 线程 CPU 总毫秒 | 墙钟总毫秒 |
|---|---:|---:|---:|
| CACommit | 2700 | 1802.37 | 1940.90 |
| CAFlush | 2700 | 0.97 | 1.95 |
| NextDrawable | 2700 | 1446.40 | 1579.88 |
| PanelSetFrame | 2247 | 832.52 | 898.72 |
| JSONSerialize | 2427 | 103.57 | 105.41 |
| JSONWrite（含 URL 构造） | 2427 | 1373.55 | 1495.85 |
| CaptureConfiguration | 2232 | 15.89 | 17.19 |
| SurfaceLayout | 2225 | 1.75 | 2.79 |

SurfaceDraw 在统计窗口内没有调用。这排除了“每帧重新执行 FrameSurface.draw 是主要成本”的解释；CA 内容更新仍可能涉及缓存回放或其他 backing layer。上述区间存在嵌套，不加总为总进程 CPU，也不与另一运行的周期权重直接换算。

## F2 候选（待对照与正式验证）

固定 9mXYWr，仅在 FrameSurface 无 carrier/fallback 时使用 wantsUpdateLayer，updateLayer 清空 contents；降级/载体仍用原 draw 方法。F1 探针已移除，日志完全恢复原样。代码差异见 [F2 patch](evidence/UP-02-F2-candidate.patch)，A-B-B-A 的全部结果将写入 [对照记录](evidence/UP-02-ABBA-F2.json)。候选旨在去掉不必要的透明绘制缓存，不预先认定其消除了全部 CACommit 成本。

## A-B-B-A 完成

基线两次 CPU 中位数 15.2173% / 14.93845%，候选两次 13.58255% / 13.07375%；两组均值差 1.749725 个百分点，大于基线波动 0.27885。四次呈现中位数均为 30 FPS。该受控对照支持“去掉空透明承载绘制缓存能够减少本场景 CPU 工作”，不证明唯一根因、不承诺跨环境相同比例，也未替代正式五分钟预算。候选已冻结进入 UP-02 R3。

## 收尾

R3 发现最大尺寸 RSS 一次跳升，F3 元数据候选的 R4 数值通过无法证明触发条件已消除；F4 已撤回，R5 保留 U02-06。当前源码仅保留 F2 修复，详情见 [执行报告](缩放CPU修复与最终验收-UP02.md)。

用户接受 U02-06 后，当前构建的正式拖动和最终视觉检查已补齐；产品验收为 CLOSED_WITH_KNOWN_ISSUE，内存根因仍未证实，见 [最终报告](缩放CPU修复与最终验收-UP02.md)。
