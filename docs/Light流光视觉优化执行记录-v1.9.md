# Light 流光视觉优化执行记录 v1.9

> **状态更新：v1.9 A 已被用户以“Light 仍发灰”否定，记为 USER_VISUAL_REJECTED。** 下文参数与检查为当时记录，当前采用及打包状态见 [v1.9.3 仅柔光实现](Light仅柔光映射试验-v1.9.3.md)。Light 显示细线的旧要求已被用户覆盖；原路径、色段、基础隔离和功能约束继续有效。

2026-09-14。历史执行状态：**SOURCE_IMPLEMENTED / LOCAL_CHECKS_PASSED / USER_VISUAL_REJECTED**。用户通过“调整”授权执行 v1.9；当前源码采用候选 A。没有打包、替换交付 app 或宣布视觉闭合。

## 改动与选择

从实际生产 shader 输出基础、仅线条、仅映射、完整合成四类图。v1.8 的独立线条可辨，但完整图中宽淡色映射的视觉面积较大，支持先调整两者覆盖关系的方向：[v1.8 分层](evidence/ADAPTIVE-FLOW-v19-source/v18-layers.png)、[A 分层](evidence/ADAPTIVE-FLOW-v19-source/a-layers.png)。颜色外推可能导致的色域问题不认定为全部根因；本轮撤销它以恢复有界输入。

按方案只比较 A/B 两组。推荐 A：保持原明度，细线更突出、柔光染色减轻；B 稍深，但本轮观察中未显示明确的整体协调性优势。这是本次视觉判断，不是用户已确认结论。[同输入、同相位对照](evidence/ADAPTIVE-FLOW-v19-source/candidate-comparison.png)。

| 参数 | v1.8 | 当前 A | 比较用 B |
| --- | --- | --- | --- |
| V 因子 | 0.92 | 0.92 | 0.88 |
| Light 线条幅度 | 0.75 | 1.00 | 1.00 |
| Light 映射增益 | 1.33 | 0.90 | 0.90 |
| 颜色外推 | 1.30 | 移除 | 移除 |

蓝色色相仍来自品牌 #3B78DD，S=1，A 的合成前蓝头约 #0058EB；紫色沿共同进度混合。长度、色段比例、0.375 pt 高斯尺度、头尾包络、扩散范围、7 秒周期和运动冻结规则保持与 Dark 一致。映射增益减少约 32%，并未缩小其几何范围。删除额外颜色外推，保留混合前透明边缘校正；基础材质未改。

源码修改集中于 `Sources/GlassFrameLab/BorderFlowShader.swift`。测试夹具补充暖/冷浅底以及测试专用的分层输出；生产 UI 没有新增开关。对照 shader 和参数见 [参数记录](evidence/ADAPTIVE-FLOW-v19-source/parameters.json)。

## 验证结果

- Release 源码编译通过；基础检查 24/24、生命周期检查 6/6 通过。
- A/B 各用真实 GPU 渲染八类固定输入：白、灰、暖浅、冷浅、深、暗色细节、混合、图案。各生成 96 张临时图，用于基线、分层及多相位比较。永久证据只保留精选图与摘要。
- A/B 的 Light 基础六类输入与冻结基线像素差为 0；关闭基础自适应后八类输入均保持旧输出；流光独立适配、色相和首尾截面检查通过。[A 回归](evidence/ADAPTIVE-FLOW-v19-source/gpu-a.json)、[B 回归](evidence/ADAPTIVE-FLOW-v19-source/gpu-b.json)。
- Dark 和暗色细节各六个相位，A/B 与 v1.8 的完整像素差均为 0。[隔离结果](evidence/ADAPTIVE-FLOW-v19-source/dark-isolation.json)。
- 半高宽固定样本保持不超过 2 像素，上下截面同步渐隐、无脱离首端的残留色带等检查通过。[原尺寸与局部放大](evidence/ADAPTIVE-FLOW-v19-source/a-fixed-phases.png)。映射是本次明确降低的变量，像素差下限从 20 改为 10，当前白/灰样本约 16；同时检查实际分层和完整图，不以该数值替代映射视觉判断。
- 最终源码运行白、浅灰、深色各一周期，观察直边、转角及底边；另检查 Finder、动态条纹背景、注入权限不可用及 Metal 不可用状态。[窗口矩阵](evidence/ADAPTIVE-FLOW-v19-source/contexts.png)、[周期样本](evidence/ADAPTIVE-FLOW-v19-source/native-cycle.png)、[Finder](evidence/ADAPTIVE-FLOW-v19-source/finder-context.png)、[运行状态](evidence/ADAPTIVE-FLOW-v19-source/runtime.json)。注入降级状态仅证明 fallback 路径，不能替代真实 OS 授权恢复。
- 一次原生功能探针 12/12 通过：静止关闭无提交、开启时模糊/统计不超过背景变化、拖动与缩放冻结且保持显示、恢复、开关清除、隐藏/显示、once 结束。探针在第 83 秒触发真实上下文菜单的“关闭”动作后正常退出。[功能与短资源记录](evidence/ADAPTIVE-FLOW-v19-source/functional-and-resources.json)。

探针同时经历深→浅→深背景切换，窗口保持材质显示；动态背景独立用前后截图差检查实时更新。正常应用的 OS 权限恢复仍未实测，不混入本轮通过项。

## 短资源观察

复用功能探针的静态片段，没有重复 RSS 长测。

| 指标 | 关闭段（约 7 秒） | 开启段（约 14 秒） |
| --- | --- | --- |
| CPU 中位数，单核百分比 | 0.64% | 6.04% |
| RSS 首→末 | 69.61→69.45 MiB | 74.28→74.39 MiB |
| GPU P95 | 无提交，未计值 | 0.107 ms |
| 渲染 FPS | 0 | 30 |

这是本机短时观察，不是跨构建性能排名或长期内存稳定性证明。开启段没有表现出需要启动额外长测的突增；原 U02-06 仍按已知问题延期。本轮没有新增纹理、采集、render pass 或动画时钟，删除了原颜色外推计算，但不据此声称已量化性能提升。

## 当前完成边界

P0～P3 已完成，P4 已提交推荐 A、B 对照及完整本机检查结果，等待用户视觉评价。Light 效果现在更偏细线强调，是否达到“纯净、不显脏”的要求仍以实际观看为准；不能由饱和度数值、测试数量或本记录自动转为视觉通过。

当前测试进程和自行创建的窗口已结束。其他系统/显示环境、正常交付 app 权限恢复及原内存已知问题按原范围保留。未发布、未打包。
