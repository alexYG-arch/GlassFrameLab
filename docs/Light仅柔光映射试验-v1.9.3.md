# Light 仅柔光映射试验 v1.9.3

2026-09-14。**SOURCE_IMPLEMENTED / LOCAL_CHECKS_PASSED / USER_VISUAL_CONFIRMED / MACOS_PACKAGE_VERIFIED**。

用户要求“尝试修改为 Light 下不显示线，只显示柔光映射”。此指令覆盖此前 Light 与 Dark 都显示流动细线的要求：**Light 只保留蓝紫柔光，Dark 仍保留细线与映射**。基础玻璃描边不是流光线，保持原样。

## 实现边界

`lightFlowOver` 删除细线混合，只合成原有内侧柔光；无映射覆盖时直接返回基础像素。移除不再使用的 falloff 参数。映射增益保持 0.75，颜色、蓝紫进度、扩散范围、头部柔化与尾部渐隐均沿用 v1.9.2，没有为了隐藏细线而加重柔光。

充分浅色背景上，完整流光输出等于独立柔光输出；充分深色背景上，输出保持原状。中间亮度仍使用已有连续背景适配系数，从 Dark 的细线和柔光逐渐过渡到 Light 的仅柔光，不增加突变阈值。判定来自背景像素，未改为系统主题开关。

路径、长度、周期、蓝紫位置及冻结时钟继续共用；这里改变的是线条可见性。拖动/缩放时保留柔光并冻结相位，结束后继续。整体开关仍控制全部流光及映射，关闭后恢复原基础材质。

## 当前验证

- Release 源码构建通过，基础检查 24/24，生命周期检查 6/6。
- 生产 shader 八类输入、96 张临时图完成：基础隔离及独立适配通过。[GPU 摘要](evidence/ADAPTIVE-FLOW-v193-source/gpu.json)。
- 白、浅灰、暖浅、冷浅四类输入上，“完整效果 = 独立柔光”“仅线条 = 原基础材质”“框体外没有流动线残留”均为逐像素一致。当前 Light 完整图也与上一版独立柔光图逐像素一致，证明柔光本身未被改变。
- Dark 和暗色细节各六个相位，与 v1.9.2 完整输出逐像素一致。[隔离对照](evidence/ADAPTIVE-FLOW-v193-source/pixel-isolation.json)。
- 图像断言按新要求调整：Light 不再要求 2 像素彩色细线和对应贴边截面，改为上述层级一致性，以及柔光宽度、内部自然衰减、头部渐散、蓝紫映射可辨。旧细线断言保留为冻结历史 shader 的 `--light-flow line` 对照模式，当前默认 `spill`。基础、颜色与功能检查没有删除。
- 新柔光衰减检查首次取样范围过短，把高斯尾部的正常微弱颜色当作残留；已延长到超过两个 10 pt 扩散半径，未改光效参数或降低信号阈值，随后通过。该调试失败不算视觉缺陷修复。
- 当前源码实际运行白/浅灰/深色各一周期，以及 Finder、动态背景、注入权限不可用和 Metal 不可用；实时更新与降级状态通过。[实际周期](evidence/ADAPTIVE-FLOW-v193-source/native-cycle.png)、[场景](evidence/ADAPTIVE-FLOW-v193-source/contexts.png)、[运行状态](evidence/ADAPTIVE-FLOW-v193-source/runtime.json)。截图按显示器 ICC 正确转换为 sRGB。
- 当前构建一次有限功能探针 12/12 通过：拖动/缩放冻结且保持显示、恢复、开关清除、隐藏/显示、once 结束、静态停止提交及模糊/统计复用；深→浅→深切换与上下文菜单关闭完成。[功能与短资源](evidence/ADAPTIVE-FLOW-v193-source/functional-and-resources.json)。

[同背景同相位前后对照](evidence/ADAPTIVE-FLOW-v193-source/comparison.png)：每组上方为 v1.9.2 细线加柔光，下方为当前仅柔光。该图来自实际生产 GPU shader，原生窗口另见上方运行证据。

## 性能与完成边界

没有新增采集、纹理、渲染 pass、时钟或逐帧分配。删除 Light 线条混合不等于整段动画停止，柔光仍需随时间渲染；不承诺零成本或具体性能提升。只复用一次有限功能探针的短资源片段，不追加 RSS 长测。

用户通过“使用这一版，重新 macOS 打包”确认采用本视觉并授权打包。视觉已确认；正常 app 的真实 OS 权限恢复、其他系统/显示环境及 U02-06 内存已知问题仍保留，不能将视觉确认扩大为全部环境闭合。参数见 [记录](evidence/ADAPTIVE-FLOW-v193-source/parameters.json)。

功能探针的短开启段记录 CPU 中位数 6.46%、RSS 74.17→74.27 MiB、GPU P95 0.105 ms、约 29.93 FPS。此片段在深色背景，不代表 Light 专项成本或性能提升证据。测试进程和自建窗口已结束。

## 用户采用与 macOS 重新打包

已运行 `bash scripts/build.sh` 更新 [macOS 应用 ZIP](../build/GlassFrameLab.zip) 与本机启动链接 `build/GlassFrameLab.app`。包为 arm64 / Apple Silicon，采用本机 ad-hoc 签名，部署目标 macOS 13；保留既有应用标识及元数据。v1.9.3 是视觉迭代编号。

ZIP CRC、路径安全、无 evidence/缓存检查通过；实际解压后 `codesign --verify --strict` 通过；在临时副本中移除签名后，包内可执行文件与当前 Release 构建逐字节一致。应用 ZIP 大小 294,418 字节。[打包验证记录](../build/packaging-v1.9.3.json)。

通过 LaunchServices 对 ZIP 解压得到的 app 做 8 秒短启动：初始化及定时退出成功，但实际状态为 `permission_required`，毛玻璃与流光未显示。因此本次**没有**将包的实时渲染或 OS 授权恢复记为通过。用户正常打开时需授予屏幕录制权限，后续真实授权恢复仍待验证。未改系统权限、未安装到 Applications、未做额外 RSS 长测。

默认流光开关仍为关闭；右键“流光效果”启用后，浅色显示仅柔光，深色保留细线与柔光。测试实例已退出。
