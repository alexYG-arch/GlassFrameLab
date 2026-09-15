# material 外发光失效排查 v1.8

2026-09-15。状态：ROOT_CAUSE_CONFIRMED / DIAGNOSTIC_PREVIEW_ONLY / DEFAULT_UNCHANGED。

## 结论

用户指出浅色白描边难辨认可能来自深色外发光缺失。本机受控对照证实：当前 material 的外发光代码没有被删除，但在所测浅色背景上实际效果近乎消失。它是边缘缺乏明暗分离的原因之一；恢复外发光后白边本身仍偏弱，不能据此宣布视觉达标。

FramePanel.swift 的 FrameSurface.draw 将黑色 alpha 0.14、零偏移、模糊半径 6 pt 的 NSShadow，施加在 alpha 0.04 的填充上。阴影随源对象的透明遮罩一起削弱，不能把 shadowColor 的 0.14 直接当作屏幕上的外发光强度。

原 custom 的 GlassRenderer 则单独计算 `shadowAlpha = opacity * falloff² * (1 - alpha)`，不依赖 4% 承载填充。Git 历史显示，material 初始迁移 f417d88 将原 fallback 的 draw 分支扩展给 system 使用，沿用了弱阴影实现。这是迁移实现没有保持效果等价；不是本次圆角静态位图调整删除了阴影。

此前 v1.1 将“4% 承载填充”列为代码存在的事实，却没有验证它实际产生的外扩散强度；v1.7 又主要尝试线宽、白色强度与向内深色衬托，没有先隔离外发光。这是执行和视觉验证的遗漏，不能用原生材质差异解释为必然限制。

## 证据

- 离屏 NSShadow 隔离测试，824×124 px、2x、相同路径与阴影参数：保持源填充 4% 时，上边中点外侧 13 行的 8-bit alpha 全为 0；仅将临时投影源改成不透明，得到 `0,0,1,1,2,3,5,6,8,10,12,14,17`。这些是指定位置的量化值，不是任意像素或精确的通用衰减倍数。
- 真实屏幕合成 A/B/C：A 当前实现；B 关闭阴影但保留 4% 内部承载；C 在临时离屏缓冲中生成独立外阴影，清除投影源，只留下外部扩散，再保留原有 4% 内部承载。三个版本都保持原生 Clear Glass alpha=1、白描边 0.55 pt / alpha 0.40，流光关闭。
- Light 上边直线外侧 12 行、每行 424 像素：A 与 B 的 sRGB 红通道均值全为 255；C 从远处 255 渐变到近边 241.06。截图可见 C 的外侧柔暗扩散，A/B 几乎无差异。
- Dark 对照中外阴影差异很小，白描边仍在。两种主题共 6 次截图均已查看；没有借改白边或加内侧暗线制造外发光恢复的结果。

[浅色原尺寸对照](evidence/material-v1.8/light-native.png) · [浅色圆角四倍放大](evidence/material-v1.8/light-corner-4x.png) · [深色对照](evidence/material-v1.8/dark-native.png) · [屏幕采样](evidence/material-v1.8/metrics.json) · [离屏采样](evidence/material-v1.8/caster-alpha.json)。证据保留在本地，不进入 Git。

NSShadow 根据被绘制对象的图像遮罩产生模糊阴影，参见 [Apple NSShadow](https://developer.apple.com/documentation/appkit/nsshadow)。本次具体失效程度由以上本机测试确认，而非仅从 API 文档推断。

## 后续修正方向与边界

先将基础外发光与内部透明填充解耦，保持零偏移、柔和向外衰减、同一圆角几何，再评估白边可见性；不要用加粗白边或增加内部灰色线条代偿。独立外光本身不需要屏幕采集或新增连续动画。

本次 C 只是诊断用离屏绘制，没有加入生产代码，也没有改默认效果、打包或推送。它还不是可直接交付的实现：正式修复需采用静态缓存，验证尺寸、圆角、缩放比例变化以及窗口留白是否截断扩散，并复查 Light/Dark、流光、运动冻结的组合。通透度与此前圆角视觉未接受状态仍保留。未重复 RSS 测试，也没有新增性能达标结论。

重现：在 system-material 目录执行 `python3 scripts/preview_material_shadow.py`，需要当前桌面会话和截图能力。脚本编译临时变体，执行离屏测试与有限原生对照，完成后关闭自身测试窗口；不修改生产源文件。
