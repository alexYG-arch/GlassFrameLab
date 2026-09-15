# material 圆角描边：文献、论坛与修复候选 v1.4

2026-09-15。状态：RESEARCH_COMPLETE / FIX_PLANNED_NOT_IMPLEMENTED。

后续：用户已授权执行，当前实现及验证见 [v1.5 修复记录](material圆角描边修复与验证-v1.5.md)。本页保留执行前的研究状态与候选，不将中间整窗位图估算当作最终实现成本。

承接 [v1.3 实机对照](material圆角描边断点排查-v1.3.md)。本轮仅研究与更新文档；产品源码 c8eaf32、build 4 不变。新候选尚未通过本机截图验证，不能宣称圆角问题已修复。通透度问题仍单独保留。

## 1. 目前能够确认什么

当前独立白描边采用 CALayer.borderWidth=0.55 pt、白色 alpha=0.40；本机 2x 对应名义 1.1 px。v1.3 中更换 continuous、内缩、移除玻璃、改为单闭合 CAShapeLayer/Quartz 路径和改成 1 px，均未稳定消除交接处明暗不均。

因此，不能再把原因说成“玻璃裁切”“路径没闭合”或“只有 0.55 pt 导致”。更准确的判断是：问题集中在细描边的最终像素覆盖和合成表现；还需排查坐标、缩放及重采样链，尚未证实 Apple 内部的具体缺陷。几何连续不等于显示亮度均匀。

## 2. 文献和论坛给出的依据

| 来源 | 实际支持的结论 | 对本项目的适用边界 |
| --- | --- | --- |
| [Apple：High Resolution APIs](https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/APIs/APIs.html) | 不同对象的分辨率可能不同；应使用 backing 坐标转换和像素对齐 API | 先记录实际坐标、比例和变换；不能仅凭屏幕是 2x 就认定整条链正确 |
| [Apple：CAShapeLayer](https://developer.apple.com/documentation/quartzcore/cashapelayer) | 路径有抗锯齿，但栅格化可能偏重速度；祖先滤镜可能改变栅格化空间 | 单闭合路径不是质量保证；这不是 Apple 对本项目圆角断点的确认 |
| [Stack Overflow：圆形细描边对照，2014](https://stackoverflow.com/questions/24316705/how-to-draw-a-smooth-circle-with-cashapelayer-and-uibezierpath) | 回答者在 Retina iPad 上发现：按屏幕比例栅格化改善有限，使用屏幕比例的 2 倍后更平滑；只开启 shouldRasterize 会因默认比例而模糊 | 第一手实验，但属于旧 iOS、不同几何与描边；值得复测，不保证现代 macOS 有效 |
| [Apple：rasterizationScale](https://developer.apple.com/documentation/quartzcore/calayer/rasterizationscale) / [shouldRasterize](https://developer.apple.com/documentation/quartzcore/calayer/shouldrasterize) | 开启栅格化后使用独立比例，默认 1；生成位图后参与合成，缩放会使用采样滤镜 | 必须区分 contentsScale 与 rasterizationScale；提高分辨率同时改变内存和重采样成本 |
| [McNamara、McCormack、Jouppi，2000：Prefiltered Antialiased Lines](https://diglib.eg.org/items/180fa65c-b842-405d-b5e6-e0f39338373e) | 通过距离函数与预先计算的滤波强度改善细线抗锯齿 | 支持可控覆盖算法的方向；论文的直线方法不能直接证明圆角环形 SDF 已正确 |
| [Chan、Durand：GPU Gems 2，Fast Prefiltered Lines](https://developer.nvidia.com/gpugems/gpugems2/part-iii-high-quality-rendering/chapter-22-fast-prefiltered-lines) | 采样和滤波支撑范围影响细线质量，距离到强度可预计算；更宽滤波也可能过糊 | 不能把任意 smoothstep 或加大模糊半径当作高质量覆盖的保证 |

检索了 Apple Developer Forums 与 Stack Overflow；未找到与当前 NSGlassEffectView + 本机细白边完全同症、且由 Apple 确认的修复。上述论坛经验是候选依据，不是当前系统的官方补丁说明。

## 3. 修复顺序

### P0：先核对实际像素链

在有限时长的诊断窗口中记录 window.backingScaleFactor、rim 的 bounds/frame、convertToBacking 结果、layer.contentsScale、rasterizationScale、shouldRasterize，以及祖先 transform、mask 和滤镜。确认截图是否保持原始分辨率，排除显示缩放造成的假接缝。

逐项控制像素相位、描边外轮廓与半径，不重复笼统“内缩 0.5 pt”。CALayer 的内侧边框与路径中心线描边要保持同一可见几何。默认宽度和颜色不变，1 px 仅作诊断对照。像素对齐可以排除输入问题，不能保证所有曲线像素亮度一致。

### P1：仅对白描边做较高分辨率的栅格化对照

保留原实现作为 A 组；B 组为独立静态描边，在当前 backing 比例下栅格化；C 组使用其 2 倍。本机 backing=2 时，C 的 rasterizationScale=4，而不是把窗口或几何放大 4 倍。

先使用独立描边层试验 shouldRasterize；若系统缓存/采样不可控，再比较显式高分辨率位图、带足够滤波留白的降采样方案。两者都必须检查边缘裁切、白线变宽和整体变糊，不以柔化掩盖断点。

限制：只处理描边，不栅格化 NSGlassEffectView、contentView 或包含流光的祖先层。保持玻璃原生动态响应，描边仍由 contentView 承载。关闭流光或 Metal 不可用时白边仍存在。有关承载方式的依据是 [Apple contentView 文档](https://developer.apple.com/documentation/appkit/nsglasseffectview/contentview)：任意子视图没有相同的玻璃层级保证。

### P2：P1 无效时，再验证统一距离覆盖描边

使用统一圆角环形几何生成静态透明图像；距离、线宽、滤波支撑和预乘 alpha 一起定义。直边与转角使用同一覆盖规则，评估曲率附近的亮度一致性；必要时以高采样参考图核对，而不是把现有 smoothstep 原型视为真值。

不增加常驻 Metal 渲染或新定时器。已有距离函数原型未通过有效截图，仍为未验证。P1 已满足视觉要求则停止，不为了技术形式继续重写。

不采用：盲目加粗白边、关闭抗锯齿、反复替换相同普通路径、私有材质滤镜、降低整窗 alpha 混入清晰背景。这些没有解决本问题的验证依据，后两项也不符合现有材质约束。

## 4. 性能与内存边界

建议显式缓存仅保留当前几何的一份描边；尺寸、屏幕比例或样式变化时更新，普通拖动不因位置变化反复重建。缩放过程避免每次事件累积旧图，结束后生成目标尺寸；原有流光冻结行为保持。

估算默认 400×50 pt：2x 的 800×100 RGBA8 位图约 0.305 MiB；4x 的 1600×200 位图约 1.22 MiB。每边采样翻倍，像素存储为 4 倍。数字只含单张原始像素，不含留白、行对齐、临时图、Core Animation 缓存或 GPU 副本，不能当作 RSS 增量保证。

显式降采样后可以释放高分辨率中间图；应检查实际保留资源。尺寸增大时按像素数计算成本，不默认推广到全屏高采样。无持续重建也仍有合成成本，不宣称“零功耗”。

## 5. 最小而完整的验证

1. 相同背景、尺寸和参数，先关闭流光，对比原实现和候选。检查四角及八处直边/圆弧接点；原尺寸截图判断观感，4 倍最近邻图用于定位。
2. 单独诊断几个亚像素相位，检查两个尺寸及一次缩放结束状态，避免仅某个位置碰巧平滑。保留白边宽度、清晰度和贴边关系，不出现第二条线。
3. Light/Dark 各检查一次；开启流光确认层级正常；关闭流光及模拟 Metal 不可用时白边仍完整。系统玻璃不被位图化，通透度没有被暗改。
4. 像素辅助分析沿描边法线比较窄带内的覆盖/亮度分布；不把单个像素变暗直接判为几何断裂。最终通过仍需真实 1:1 视觉检查，不能靠统计指标代替。
5. 若增加缓存，只做一次短时预热、尺寸切换和静置资源检查，确认无连续增长或周期性重建；不恢复长时间 RSS 套件。此成本缩减不减少上述实现与视觉验证。

本轮未运行新候选或资源测试。后续实机验证须在桌面可用时完成；v1.3 锁屏期间的无效截图不计入证据。若候选没有改善，保留原产品构建并记录失败，不直接发布。
