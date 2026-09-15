# material 独立外发光恢复与迁移漏项 v1.9

2026-09-15。用户要求：描边 0.85 pt，先恢复独立外发光并在浅色下适当增暗，同时解释迁移丢失细节的原因。

状态：IMPLEMENTED / WAITING_USER_VISUAL。当前 material 源码已按用户后续指令生成 build 5 交付包；main 不变。进一步通透度与原非均匀内侧深度仍未解决。

## 当前调整

| 项目 | 参数与行为 |
| --- | --- |
| 白色基础描边 | 0.85 pt，白色 alpha 0.40，Light/Dark 同宽；本机 2x 对应 1.7 物理像素的名义宽度，通过抗锯齿覆盖表达 |
| 基础外光 | 黑色、零偏移、6 pt 扩散；Light 层不透明度 0.20，Dark 0.14，跟随 effectiveAppearance |
| 透明度 | 保持原生 Clear Glass alpha=1 与原有 4% 内部承载；外光投影源在离屏生成后清除，内部没有新增不透明填充 |
| 层级 | 外光位于系统材质下方、仅向外可见；白边位于玻璃 contentView；流光仍为独立覆盖层 |
| 流光 | 无参数变化；Light 仅柔光、Dark 细线与柔光，运动冻结与恢复沿用原逻辑 |

StaticGlassRim 改为 0.85 pt；StaticGlassOuterShadow 用不透明临时投影源生成阴影，再清除投影源，缓存外部阴影。它不依赖底材 4% alpha，也不依赖 Metal 是否可用。采用与玻璃相同的矩形和圆角，避免沿用旧阴影路径内缩 0.5 pt 带来的几何差异。HUD system 兼容路径也采用 0.85 pt；旧系统未实测。

外光缓存固定角部和扩散边缘，普通缩放只伸展直边。默认 2x 下外光位图 35,328 bytes，白边位图 18,496 bytes；这是 CPU 图像数据大小，不是整个进程 RSS 或 WindowServer 内存。尺寸测试及主题切换复用同一外光图像；圆角/留白/比例变化按需重建。无新增定时器、背景采集或每帧阴影生成。

## 为什么迁移丢失了细节

迁移边界本应是“系统替换背景采样与模糊，其余视觉层逐项保留或标明差异”。实际执行过度依赖系统材质的默认观感，缺少逐层对照。计划虽然写了外扩散和非均匀深度目标，但未把它们分别落实为可见证据；检查也偏重路由、状态、权限和动画运行。这些功能成立，不能证明视觉层完整。

| 原屏幕渲染处理 | material 当前处理 | 差异性质与状态 |
| --- | --- | --- |
| 自定义背景采样、模糊、亮度/饱和度/tint | 原生 Clear Glass 负责底材合成 | 系统材质的参数和观感不等价；通透度仍未接受，不能靠额外录屏或私有 API 暗中恢复 |
| 读取后方像素判断明暗 | effectiveAppearance | 计划明确的行为取舍；跨深浅窗口移动不会按原像素规则切换附加光效 |
| 独立 SDF 外发光 | 先前复用了 fallback 的 4% 填充阴影 | 实现漏项：有代码却近乎无可见效果。v1.8 隔离确认；本次恢复独立外光，需用户确认观感 |
| 白色边线与抗锯齿覆盖 | 曾删除独立线并以系统高光代替；后恢复静态白边 | 执行误判。此次改为用户指定 0.85 pt；圆角改善程度仍以实际视觉为准 |
| 按边缘方向变化的内发光、内阴影与边线亮度 | 系统自身高光/阴影；只另保留流光的局部映射 | 原基础非均匀深度没有独立等价迁移，仍是未解决项；流光映射不能替代基础深度 |
| 底材与流光在同一 shader 中合成 | 原生底材 + 透明 Metal 覆盖 | 混合方式变化，需要同背景、同相位标定；几何复用不等于颜色结果相同 |

因此，不能将全部差异归因于“无录屏的系统版本必然更差”。模糊控制和明暗判断有明确边界；白边、独立外光和可自定义的深度装饰则属于可保留能力，先前没有完整落实。计划现补充 R12/R13 及漏项账本，未验证视觉项不能被功能 PASS 覆盖。

## 验证与实际截图

- 当前 release 源码构建成功；26/26 LabSupport、6/6 lifecycle 检查通过。
- 当前构建 Light/Dark × 流光关闭、开启、Metal 不可用、放大尺寸，共 8 组实际屏幕合成截图已查看：白边与外光可见，浅色外光更强，Metal 不可用时基础效果仍在。未把流光状态字段当成唯一视觉证据。
- 白边缓存检查：0.85 pt 对应直边 alpha 积分预期 173.4、实际 173（8-bit 求和）；中心透明，20 次移动和普通缩放复用缓存。
- 外光检查：中心透明、外侧非零；Light/Dark 强度分别 0.20/0.14，主题和普通缩放复用缓存；最外行原始 alpha=2，乘 Light 强度后为 0.4/255，未见明显硬截边。该结论限本机 2x 默认几何。
- 14 秒程序驱动的运动/缩放探针通过，结束后底材可见、流光恢复、采集初始化为 0。已查看中间缩放与恢复态截图；恢复态背后是实际应用内容，不将其与纯色夹具做颜色数值对比。没有声称完成真人拖动或所有中间帧视觉验收。
- 当前构建 22/22 功能回归通过：主题切换、拖动/缩放冻结且可见、隐藏后零提交、恢复、once、关闭和采集初始化为零均通过。资源测量关闭，off/on 资源结果为 null。减少动态效果的状态注入检查不等于真实系统开关验证。见 [功能收据](evidence/material-v1.9/functional-summary.json)。

[当前 Light/Dark 原尺寸](evidence/material-v1.9/current-native.png) · [浅色修改前后](evidence/material-v1.9/light-before-after.png) · [圆角四倍放大](evidence/material-v1.9/corner-4x.png) · [完整 8 组](evidence/material-v1.9/review.png) · [缓存检查](evidence/material-v1.9/cache-check.json) · [运动记录](evidence/material-v1.9/motion-result.json)。截图本地保留，不进入 Git。

本次没有开展 RSS 专项或长时资源测试，没有新增功耗/长期内存达标结论。真实辅助功能开关、旧 macOS、非 2x/外接屏继续未验证。开始验证时一次通用 swift build 因缓存路径权限失败；其后误启动的旧二进制截图已排除，正式证据只采用 build_source.sh 成功后的当前构建。

重现：`bash scripts/build_source.sh`；`bash scripts/test.sh`；`python3 scripts/check_material_rim.py`；`python3 scripts/check_system_motion.py`；`python3 scripts/check_system_smoke.py --backend system --functional-only`。原生验证脚本只创建临时测试身份，不替换交付包。

## build 5 交付

用户随后明确要求重新打包并推送 Git。独立 Material 包版本 0.1.0 / build 5，337,806 bytes，包含 0.85 pt 白边、独立外发光及 Light 0.20 / Dark 0.14 强度。视觉待确认与其余未解决项不因打包改为已通过。

[下载 build 5 ZIP](../build/GlassFrameLab-Material-0.1.0-build5.zip)。常用 `build/GlassFrameLab-Material.zip` 同步为同一份归档。CRC、安全相对路径、evidence/cache 排除、归档二进制与签名原包一致均通过；使用 macOS ditto 正确恢复 ZIP 元数据后，严格签名验证通过。仍为本机 ad hoc 签名。

解压包经 LaunchServices 启动，未指定 backend：实际默认 system / glass_clear、流光关闭、采集初始化 0；5 秒正常退出。没有重新执行 RSS 专项。详细收据保留于本地 `build/material-package-verification.json`。源码、测试脚本和文档提交到 material；build 与 evidence 不进入 Git。
