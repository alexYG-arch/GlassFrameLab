# material 透明度修复 v1.1

2026-09-15。状态：LOCAL_FIX_VERIFIED_WITH_DEFERRED_TESTS / WAITING_USER_VISUAL。范围仅 material 本机 macOS 26 路线；main/custom 不变。

## 问题与根因

用户提供的 Finder 截图显示框体接近实心灰白板。此前 ZIP 的 system 路由、无录屏权限启动、零采集初始化是真实成立的，但这些检查不能证明通透感符合目标。

复测旧交付包（build 2）：system / hudWindow、reduce_transparency=false、采集初始化 0。彩条可透出颜色，黑白分区可透出明暗，但窄细节与浅色稀疏内容被大幅平滑、淡化。代码窗口为非不透明、透明背景；没有覆盖主体的不透明填充，只有原有 4% 黑色外扩散承载。因此，本机复现的主因是 HUD 材质的模糊和底色处理不适合目标通透感，不是丢失录屏授权或 ZIP 仍走 custom。用户截图自身不能独立证明当时系统设置，本结论来自本机同版本复现。

独立原生对比测试覆盖 hudWindow、underWindowBackground、popover、menu、sidebar 的 Light/Dark。HUD 已是这些测试候选中细节较多的一种；简单替换传统 NSVisualEffectView 枚举不能解决。macOS 26 Clear Glass 在同一浅色图标/文字背景保留更多模糊轮廓，作为本次修正方向。

执行层面的缺口：原计划只把 HUD 作为起点，并要求真实视觉检查；前次执行保留了“更厚”的差异说明，但没有把用户要求的通透感作为阻止交付的条件。动态图案响应、材质可见和权限通过被用作过弱的验证。现在增加稀疏细节与旧包同位置对比；数值仅描述图像变化，不能自动代表用户视觉接受。

## 实现调整

- macOS 26：公开 NSGlassEffectView.Style.clear，原生圆角及边缘，不叠加第二圈 layer 描边。
- macOS 13–25：保留 HUD 兼容路径，诊断名 hudWindow_compatibility；该视觉仍较厚，不承诺等同 Clear Glass，未在旧系统实测。
- 保持 system 默认、采集初始化 0；不增加录屏、辅助功能或输入监控授权。
- 流光仍独立、默认关闭；Light 柔光、Dark 细线和柔光，几何与时钟不改。
- Clear Glass 中的 Metal 叠加层通过 contentView 挂载。首次候选的 sibling 挂载被原生材质盖住，已在截图检查中发现；不得把 flow_visible=true 当作可见证据。使用透明 host 保持含留白的原 shader 坐标，不增加背景纹理或模糊管线。
- 新增 light-detail / dark-detail-icons 夹具与 check_system_translucency.py，输出真实合成下旧包、Light/Dark 开关对照。

## 验证与交付

当前 build 3：

- release 构建成功；26 项 LabSupport 与 6 项 lifecycle 检查通过。
- 前景层修正后的当前构建，22/22 system 功能检查通过；包括 Light/Dark 回调、真实已提交的静态主题权重、开关、冻结、恢复、隐藏、once 和退出。`--functional-only` 的资源结论为空。
- 同一位置的旧 HUD 与 Clear Glass 稀疏图标背景比较、Light/Dark 流光开关共 5 组真实截图。已人工检查：Clear Glass 保留了模糊图标轮廓；Light 柔光、Dark 细线和柔光可见，无第二条内描边。开启/关闭截图的最大单通道差值为 Light 22、Dark 103（8-bit），只用于防止“状态开启但画面完全无变化”的回归，不作为美观或强度标准。
- Light/Dark 各完整 7 秒流光周期及 9 张截图、真实 Finder 背景移动、Metal 不可用时底材保留均通过。检查来源 `check_system_visual_edges.py`。
- 当前构建的 14 秒运动探针、10 个采样时间点、缩放后恢复通过；人工复核完整的缩放态与恢复态图，未见原有阶梯圆角问题。快速运动中截图裁切边界的旧限制仍保留，不宣称每帧像素级验证。
- ZIP 0.1.0 / build 3，331,339 bytes。CRC、安全相对路径、无 evidence/cache、归档二进制与签名原包一致、解压后严格签名检查均通过。
- 解压包经 LaunchServices 启动，未传 backend 参数，实际 system / glass_clear、材质可见、流光默认关闭；录屏预检 false，采集初始化 0，8 秒正常退出。

交付：[build 3 ZIP](../build/GlassFrameLab-Material-0.1.0-build3.zip)。仍为本机 ad hoc 签名，未公证。旧包保持运行时不会自动替换自身；先关闭旧实例，再从新 ZIP 解压启动。

真实截图：[新旧对照](evidence/material-v1.1/before-after.png)、[Light/Dark 与流光](evidence/material-v1.1/translucency.png)。收据位于本地 `docs/evidence/material-v1.1`；Git 不包含 evidence，结论和重现脚本保留在仓库。

原 build 2 ZIP 验证及 HUD 性能记录只适用于旧材质；本次不重复长 RSS 验证，不把旧系统合成成本转移成 Clear Glass 的性能结论。关闭流光时应用端没有新增连续 Metal 提交，但 WindowServer 的 Clear Glass 成本和总功耗没有量化。

真实“减少动态效果”和“降低透明度”继续按用户决定未验证。其他系统、外接屏、总 GPU 功耗仍未验证。视觉改进与最终用户视觉确认分开记录。

## 依据

- [Apple NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview)：系统语义材质与 behind-window 合成；API 存在不代表具体背景下符合本项目通透目标。
- [Apple NSGlassEffectView.Style.clear](https://developer.apple.com/documentation/appkit/nsglasseffectview/style-swift.enum/clear)：公开 Clear Glass 样式。
- 本机 macOS SDK 的 NSGlassEffectView.h 明确仅保证 contentView 位于玻璃内部的内容层；以正常窗口实测确认叠加层实际可见。
