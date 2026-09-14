# Light 流光覆盖修正记录 v1.9.1

> **后续反馈：用户确认饱和度有提升，但细线与整体仍偏重。** 本文保留 v1.9.1 的实际结果，当前小幅减弱见 [v1.9.2 调校记录](Light流光轻量调校记录-v1.9.2.md)，尚未视觉闭合。

2026-09-14。**SOURCE_IMPLEMENTED / LOCAL_CHECKS_PASSED / USER_VISUAL_REVIEW_PENDING**。用户反馈“light 下还是发灰”，v1.9 A 的视觉结论重新打开。本轮沿用 [v1.9 方案](Light流光视觉优化方案-v1.9.md) 的几何、基础材质和功能约束，仅修正 Light 细线覆盖及截图色彩处理；未打包或替换交付 app。

## 根因与修正

**生产合成：**输入蓝色 S 已为 1，继续提高输入饱和度没有空间。线条仍乘总强度 0.85、细线高斯覆盖、沿边渐隐和外侧衰减，在白描边上合成后明显冲淡。上一版分层诊断虽发现覆盖不足，却只把线条幅度恢复为 1.00，没有解决最终像素的色彩覆盖。因此这是上一轮执行校准不足，不能以输入参数或自动检查通过认定视觉解决。

这次只把 `lightFlowOver` 的细线覆盖增益从 1.00 改为 **1.50**，仍限制在有效透明度范围。增益作用于完整横截面以及同一首尾渐隐，不新增接触色带、不扩大高斯宽度。映射维持 0.90、输入 V=0.92/S=1，保持较轻的内部柔光，避免整体又变成强烈色雾。蓝紫颜色、比例、路径、周期及冻结时钟未改；Dark 合成分支、基础 GlassStyle 未改。

固定白底、相位 0.30、像素 (534,12)：最终颜色由 `#6E9DF2` 变为 `#3577EE`；同位置向内的映射像素 (534,20) 保持 `(224,233,251)`。这说明此次改变集中在细线，数值仅用于解释差异，**不作为视觉通过标准**。见 [同输入对照](evidence/ADAPTIVE-FLOW-v191-source/fixed-comparison.png) 与 [像素记录](evidence/ADAPTIVE-FLOW-v191-source/pixel-comparison.json)。

**评审图片：**macOS 原始截图带显示器 ICC 配置，之前拼图只调用 `convert('RGB')` 后粘贴到无配置图像，没有转换色彩空间，蓝色展示偏淡。现在 `check_source_visuals.py` 在拼图与像素测量前按原 ICC 转为 sRGB；本轮截图展示也统一转换，原截图保留。没有对截图额外调色、增饱和或锐化。这是证据展示问题，不能用它替代生产合成问题的解释。[色彩处理说明](evidence/ADAPTIVE-FLOW-v191-source/screenshot-color.json)。

[实际窗口前后对照](evidence/ADAPTIVE-FLOW-v191-source/native-comparison.png) 使用两轮相近时间截图，动画相位略有差异；严格同相位判断使用固定输入图。此前 v1.9 的旧拼图不再作为颜色精确比较依据。

## 当前构建验证

- 源码 Release 构建通过，基础检查 24/24、生命周期检查 6/6 通过。
- 当前生产 shader 的八类输入、96 张临时渲染完成。Light 基础六类输入与冻结基线一致；关闭基础自适应后八类输入与基线一致；流光独立适配通过。未降低或删除任何本轮图像断言。[GPU 摘要](evidence/ADAPTIVE-FLOW-v191-source/gpu.json)。
- Dark 和暗色细节各六相位，对 v1.9 A 最大通道差全部为 0。Light 固定截面半高宽仍不超过 2 像素；首尾上下截面渐隐、无脱离头部的色带、紫尾及蓝色主体检查通过。观察 [直边与转角](evidence/ADAPTIVE-FLOW-v191-source/fixed-phases.png)，颜色核心较清楚，内部映射仍为柔散效果；此观察不等于用户接受。
- 实际源码窗口完成白、灰、深色各一个周期，以及 Finder、动态背景、注入权限不可用、注入 Metal 不可用。实时背景变化检查通过。[周期截图](evidence/ADAPTIVE-FLOW-v191-source/native-cycle.png)、[实际场景](evidence/ADAPTIVE-FLOW-v191-source/contexts.png)、[运行状态](evidence/ADAPTIVE-FLOW-v191-source/runtime.json)。色彩转换 helper 使用本轮原始截图复核，无需重复采集同一画面。
- 一次 85 秒功能探针的 12 项全部通过，涵盖拖动/缩放冻结且保持显示、恢复、开关清除、隐藏/显示、once、静态关闭无提交及模糊/统计复用；经过深→浅→深切换，并通过上下文菜单关闭。见 [功能与短资源](evidence/ADAPTIVE-FLOW-v191-source/functional-and-resources.json)。

## 性能与完成边界

未增加纹理、采集、渲染 pass、逐帧分配或时钟，只改变已有 Light 分支的标量覆盖计算。复用功能探针的短样本：关闭段 CPU 中位数 0.67%、RSS 69.41→69.25 MiB；开启段 CPU 6.08%、RSS 74.02→74.13 MiB、GPU P95 0.071 ms、30 FPS。资源片段位于深色背景，不能用来宣称 Light 合成成本已单独测定，也不是长期泄漏证明；本轮无新增长时 RSS 测试。

原 U02-06 内存已知问题继续延期。正常 app 的真实 OS 权限恢复、macOS 13、外接及非 2x 屏仍未验证。本轮为当前本机源码检查；视觉仍待用户确认，不能自动闭合。测试自建进程/窗口已结束。

永久证据位于 `docs/evidence/ADAPTIVE-FLOW-v191-source/`，仅保存精选截图、冻结 shader 与摘要，低于 1 MB。参数见 [记录](evidence/ADAPTIVE-FLOW-v191-source/parameters.json)。
