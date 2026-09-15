# material 圆角描边断点排查 v1.3

2026-09-15。状态：ISSUE_REPRODUCED / CANDIDATE_NOT_VERIFIED。当前产品源码仍为 c8eaf32，ZIP 仍为 build 4；本轮未修改产品代码或重打包。

用户截图显示圆角与直边交接附近有暗点/亮度接缝。问题出现在恢复独立白细边之后；当前使用 CALayer.borderWidth=0.55 pt、白色 alpha=0.40。在本机 2x 屏幕上，名义宽度为 1.1 个物理像素，细线的像素覆盖率变化容易表现为局部亮度不均。

## 已完成对照

在相同深色背景、尺寸和颜色下，以独立原生窗口比对并拍摄实际屏幕合成；检查图为原像素的 4 倍最近邻放大，仅用于观察像素，不代表原尺寸观感。

1. circular 与 continuous：缺口/交接变暗没有消除，不能归因于默认圆角曲线类型并宣称换成 continuous 即可修复。
2. 内缩 0.5 pt：改变边缘位置，但没有稳定消除交接不均；不能以内缩当作解决方案。
3. 移除 NSGlassEffectView，仅保留白边：仍出现类似交接变暗。这排除了“必须有系统玻璃裁切才出现”的假设。
4. CAShapeLayer 单闭合路径及 Quartz NSBezierPath：仍有类似现象。因此不能声称只是 CALayer 把线段拼接错了，或闭合路径已修复。
5. Quartz 0.5 pt（本机 1 px）仍有边缘亮度变化，0.55 pt 不是唯一解释。

结论边界：已定位到白细描边的转角栅格化/抗锯齿覆盖表现，未发现需要修改背景采集或玻璃材质的证据。路径在几何上连续；屏幕像素亮度在交接区出现不均。尚未证实系统内部的具体实现原因，不将其写成已确认的曲线裁切或分段拼接 bug。

## 修复候选与剩余验证

候选：整圈使用一致的圆角距离与覆盖函数生成静态描边，仍保留原 0.55 pt / 白色 0.40，不更改透明度、不混入清晰背景。

候选目前只有临时原型，未接入产品。最后一组实际截图失败后，只读检测到 frontmost=com.apple.loginwindow、CGSSessionScreenIsLocked=1；无效截图不作验证证据。已请求用户解锁，后续需确认候选确实改善四角接点、无白边断裂或第二条线，再确定实现和成本。不得直接增加常驻动画或重复背景渲染。

已保留：[曲线/内缩对照](evidence/material-v1.3/compare.png)、[闭合路径对照](evidence/material-v1.3/shape-compare.png)、[Quartz 对照](evidence/material-v1.3/quartz-compare.png)。本轮没有 RSS 专项测试。通透度继续未解决，用户拒绝清晰背景混入的约束保持。

参考：[Apple CALayer.cornerRadius](https://developer.apple.com/documentation/quartzcore/calayer/cornerradius)、[cornerCurve](https://developer.apple.com/documentation/quartzcore/calayer/cornercurve)。API 文档说明可配置边框/圆角，不证明具体抗锯齿缺陷；结论来自上述对照。

后续研究：[文献与修复候选 v1.4](material圆角描边文献与修复候选-v1.4.md)。候选顺序调整为实际 backing 坐标/缩放核对 → 独立描边高分辨率栅格化对照 → 必要时统一距离覆盖算法；本页实验结果保持不变。
