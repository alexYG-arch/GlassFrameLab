# Light 流光轻量调校记录 v1.9.2

> 用户随后要求尝试 Light 仅显示柔光，当前实现与验证见 [v1.9.3](Light仅柔光映射试验-v1.9.3.md)。本文保留原细线加柔光候选，不代表当前可见性要求。

2026-09-14。**SOURCE_IMPLEMENTED / LOCAL_CHECKS_PASSED / USER_VISUAL_REVIEW_PENDING**。

用户确认“细线本身也太浓，整体稍微减弱”。本轮在 v1.9.1 上做小幅调校；此前只降低映射到 0.60 的临时诊断没有进入源码。

| Light 参数 | v1.9.1 | 当前 |
| --- | --- | --- |
| 细线覆盖增益 | 1.50 | 1.35（降低 10%） |
| 内部柔光增益 | 0.90 | 0.75（降低约 17%） |
| 输入蓝色 S / V 因子 | 1.00 / 0.92 | 不变 |

只改 `BorderFlowShader.swift` 的两个覆盖系数。Light/Dark 共用路径、线宽、长度、色段比例、首尾渐隐和运动时钟；基础毛玻璃、Dark 输出以及内部映射扩散范围保持不变。这里的减弱是覆盖强度调整，没有把映射改成内描边。

同一白底、相位 0.30、像素 (534,12)，细线从 `#3577EE` 变为 `#4783EF`；内部 (534,20) 从 `(224,233,251)` 变为 `(229,237,252)`。输入饱和度保持，但白底混合后的像素饱和度会随覆盖减少而略降，不能声称最终像素饱和度完全不变。[同相位对照](evidence/ADAPTIVE-FLOW-v192-source/comparison.png)、[四类浅底](evidence/ADAPTIVE-FLOW-v192-source/fixed-comparison.png)、[像素记录](evidence/ADAPTIVE-FLOW-v192-source/pixel-comparison.json)。

## 验证

- Release 源码构建通过；基础检查 24/24，生命周期 6/6。
- 当前生产 shader 八类背景、96 张临时图完成。基础 Light 与冻结基线隔离通过；首尾完整渐隐、贴边、映射可见、紫尾/蓝主体以及线宽检查均通过，未修改测试阈值。[GPU 摘要](evidence/ADAPTIVE-FLOW-v192-source/gpu.json)。
- Dark、暗色细节共 12 个相位与 v1.9.1 像素差为零。
- 当前源码实际运行白/灰/深各一周期、Finder、动态背景、注入权限不可用与 Metal 不可用场景。截图按原显示器 ICC 转为 sRGB 展示，无额外调色。[实际周期](evidence/ADAPTIVE-FLOW-v192-source/native-cycle.png)、[运行状态](evidence/ADAPTIVE-FLOW-v192-source/runtime.json)、[场景](evidence/ADAPTIVE-FLOW-v192-source/contexts.png)。
- 实际窗口前后截图的相位略有差异：[原生对照](evidence/ADAPTIVE-FLOW-v192-source/native-comparison.png)。颜色强度比较优先使用同相位固定输入，不能用不同动画位置判断长度变化。
- 当前构建一次有限功能探针 12/12 通过：拖动/缩放冻结且保持显示、恢复、开关清除、隐藏/显示、once 结束、静态停止提交及模糊/统计复用；深→浅→深切换及上下文菜单关闭完成。[功能与短资源摘要](evidence/ADAPTIVE-FLOW-v192-source/functional-and-resources.json)。

## 范围与完成边界

没有新增采集、纹理、渲染 pass、时钟或逐帧分配。只复用一次有限功能探针中的短资源片段，不跑 RSS 长测；U02-06 内存已知问题继续延期。其他系统/显示环境及正常 app 的真实 OS 权限恢复仍未验证。

当前仅源码开发，无打包或更新交付 app。视觉待用户确认；自动检查不能代替用户对轻重的判断。参数及小体积证据位于 [参数记录](evidence/ADAPTIVE-FLOW-v192-source/parameters.json)。

功能探针内复用短资源样本：开启段 CPU 中位数 5.49%、RSS 74.11→74.19 MiB（峰值 74.25 MiB）、GPU P95 0.106 ms、30 FPS。该片段为深色背景，不代表 Light 专项成本或跨构建性能排名。测试进程及自建窗口已结束。
