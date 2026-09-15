# material 描边恢复与通透度边界 v1.2

2026-09-15。状态：白描边已实现并通过定向视觉检查；用户已拒绝清晰背景混入方案，进一步通透度仍未解决。产品保持原生 clear / alpha=1，仅打包白描边修复为 build 4。

## 白描边回归

用户指出 build 3 的白色描边消失。原因明确：v1.1 将独立描边删除，并假定 NSGlassEffectView 的原生边缘可以替代。这是执行中的错误判断，系统高光不是原固定白色细线；前次验证没有约束住该视觉要求。

恢复独立静态白色细描边：0.55 pt、白色 alpha 0.40。描边归基础效果，创建于流光渲染器之前，Light/Dark、关闭流光、Metal 初始化失败时均保留。无新增计时器、采屏或背景模糊；层路径只随尺寸改变。

实际截图覆盖 Dark、Light、Dark 流光开启、Metal 不可用 4 项；白边已观察到，Light 在纯白底自然较弱。旧系统 HUD 兼容路径也改为白色细线，旧系统仍未实测。当前构建 14 秒运动探针和 10 个采样点通过；截图已复核恢复态，描边随原几何更新。

## 通透度的边界与候选

检查本机公开 NSGlassEffectView.h 与 [Apple API](https://developer.apple.com/documentation/appkit/nsglasseffectview)：提供 style、tintColor、cornerRadius、contentView，没有公开的独立背景模糊半径或强度参数。当前已使用 clear，不能把一个虚构的 blurRadius 设置描述成修复。

独立原生试验比较 alphaValue 为 1.0、0.80、0.65 的 Clear Glass，使用相同浅色图标与文字背景。降低不透明度确实增加透底，但未模糊的文字和图标边缘也混入原有模糊层；不是把系统模糊核调小。0.65 比 0.80 的清晰细节混入更强。

用户回复“不接受”，明确拒绝混入清晰背景。因此废弃这些候选，产品保持 alpha=1，不降低窗口或材质不透明度。只修复白描边；通透度要求仍未解决，不标视觉验收通过。不隐式恢复屏幕采集或使用私有 API。

实际对照：[白描边](evidence/material-v1.2/white-rim-dark.png)、[不透明度候选](evidence/material-v1.2/opacity-candidates.png)。这次未重跑长 RSS 或完整性能比较。真实辅助设置、旧系统和其他显示环境仍保留未验证。


## 白描边修复包

[Material build 4 ZIP](../build/GlassFrameLab-Material-0.1.0-build4.zip)，331,451 bytes，仅白描边与对应层级修正；没有更改玻璃不透明度或模糊策略。ZIP CRC、路径/排除项、签名二进制一致性、解压后严格签名检查通过。经 LaunchServices 正常默认启动，实际 glass_clear、流光默认关闭、采集初始化 0，5 秒正常退出。新包不包含 evidence，本机 ad hoc 签名、未公证。

视觉范围：白描边修复已验证，进一步通透度未解决；不能把这次打包视为全部视觉要求通过。
