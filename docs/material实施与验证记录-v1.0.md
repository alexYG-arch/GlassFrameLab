# material 实施与验证记录 v1.0

2026-09-15。状态：IMPLEMENTED / LOCAL_VALIDATION_PARTIAL；M05 未确认。

执行依据：[迁移计划 v1.0](material系统材质迁移计划-v1.0.md)。分支 material，实施前 bdd0ee6；custom 基线 70ab8ad。默认仍为 custom，不修改 main、正式应用或 ZIP。

## 实现边界

- system 使用正常的 NSVisualEffectView hudWindow / behindWindow，独立于 fallback。
- SystemMaterialController 不创建 LocalCaptureService；SystemFlowRenderer 只有透明光效，没有采集纹理、MPS 模糊、亮度统计 buffer。
- Light 仅柔光；Dark 细线与柔光，沿用蓝紫色及圆角周长数学。使用 effectiveAppearance，不再根据窗外像素切换光效。
- 运动时冻结相位并保留图像，几何与完成的 drawable 一起提交；隐藏、once、主题及辅助状态使用独立暂停原因。
- --material-backend system 显式启用；与采集及旧后端诊断冲突时启动前拒绝。系统右键菜单没有背景重连或录屏授权选项。

## 当前已验证

1. 源码 release 构建；25 项 LabSupport 与 6 项原有 lifecycle 检查通过。
2. custom GlassRenderer、BorderFlowShader、BorderFlowStyle 与 70ab8ad 没有源码差异。原固定输入 GPU 检查 96 张图通过，包括 Light 仅柔光及品牌色。
3. 新透明叠加层 GPU 检查覆盖 7 个直边/转角相位、3 个主题权重；关闭全透明，Light full=spill、line-only 全透明，Dark 有线，RGB 不超过预乘 alpha，外围留白清空。Light 内映射半峰宽为 16 px，不是新增细内线。
4. 临时正常 app 身份 local.uidev.GlassFrameLab.material，经 LaunchServices 打开；录屏预检 false，采集服务真实初始化计数 0。默认尺寸 800×100 px，窗口总尺寸 824×124 px。
5. 实际屏幕合成下 native Light/Dark 都随动态图案更新；主题×白/灰/深/暖/冷/动态背景共 12 组已截图，静态流光按相位 0.30 对齐。

## 原生底材的视觉差异

hudWindow 比 custom 更磨砂、更依赖系统配方：Light 乳白填充更强，Dark 更沉，内部非均匀深度较弱。不得宣称等价还原或用户已接受。暂未为追求通透感引入私有材质参数、透明截图或第二次背景模糊；是否继续这种系统风格交由 M05 判断。

## 验收工具修正

首次 window-only 截图为灰板，不能证明系统底材失效：该截图没有包含 WindowServer 的 behindWindow 背景。改为实际屏幕区域截图后，原生背景正常变化。保留这个失败及原因，不把离屏/独立窗口截图当作最终系统合成结果。截图先按 ICC 转 sRGB，拼图不做调色。

短资源脚本首次被其他进程名称的非 UTF-8 字节中断，未产生有效资源结论；已改为仅查询 WindowServer PID 的数字列。已修复后完成一组有效对照，结果见下表。

## 功能与原生窗口结果

- custom 对照 12 项、system 正常 app 21 项检查通过：开关清除、运动冻结并保持可见、恢复、隐藏期间零提交、once 结束、主题切换不重启 once、右键关闭及结束清理。
- system 还验证了 effectiveAppearance 回调、嵌套 sleep/session 暂停组合，以及减少动态效果与 session 暂停互不覆盖。减少动态效果在本项中是显式测试注入，不等于系统设置已实测；通知注入没有真实锁屏/睡眠用户机器。
- Light 与 Dark 各采 9 帧，覆盖超过一个 7 秒周期；全部光效可见、相位继续。原生 Finder 自建窗口移动时，屏幕合成图平均 RGB 差异 15.48，产品仍无采屏。
- 注入 Metal 初始化失败时，native 底材正常，GPU 提交为 0，采集初始化为 0；菜单将流光标为不可用，保持关闭操作。
- 后续针对运动中间态补截图时遇到真实 login_window：系统冷启动已暂停光效，提交数 0。该次视觉补测未通过/未完成，不能把锁屏图算作运动截图。不会解锁用户机器或授予测试工具辅助功能权限。

## 一组短资源比较

同一深色夹具、默认尺寸，custom 源码与 system 独立 app 串行。有效关闭段 7 秒、开启段 14 秒，复用功能运行；截图安排在有效资源段外。无长 RSS、无新固定 CPU 门槛。

| 指标 | custom 关闭 | system 关闭 | custom 开启 | system 开启 |
| --- | --- | --- | --- | --- |
| 应用 CPU 中位数（单核 %） | 0.6166 | 0.2398 | 5.61135 | 3.8375 |
| RSS 首 → 末（MiB） | 69.125 → 68.984 | 65.156 → 61.906 | 74.125 → 74.219 | 69.641 → 69.750 |
| RSS 峰值（MiB） | 69.125 | 65.156 | 74.219 | 69.750 |
| 呈现 FPS | 0 | 0 | 30 | 30 |
| 本应用 Metal command P95（ms） | 无提交 | 无提交 | 0.10979 | 0.08325 |

WindowServer 的 `ps` CPU 快照中位数：custom 关闭/开启 1.0/16.95%，system 关闭/开启 1.8/12.9%；RSS 快照约 111.5–111.7 MiB。这些是整个合成进程的瞬时统计，包含其他窗口且不是本产品的归因测量，不据此算节能百分比。总 GPU、真实功耗和长期内存走势未测；system Metal 时间只覆盖附加层，原生背景模糊成本不在其中。custom 的 U02-06 继续延期，未由这些数据解决。

## 可复核材料与范围

- 实际底材：[对照图](evidence/material-v1.0/base-comparison.png)。
- 外观交叉组合：[12 组截图](evidence/material-v1.0/appearance-matrix.png)。
- 一圈与自然背景：[整圈/Finder/故障](evidence/material-v1.0/loop-finder-failure.png)。
- [功能及资源摘要](evidence/material-v1.0/functional-resources.json)、[GPU 与底材摘要](evidence/material-v1.0/technical-summary.json)。

图片及原始 JSON 在被 Git 忽略的 evidence 目录；远端读者可直接阅读本记录及运行 scripts/check_system_*.py 复核。常驻材料目前远低于 2 MB。源码文件范围和旧 shader 相等性另以 Git diff 检查，不复制历史 evidence 的 PASS。

## 最后复核修正

复核“减少动态效果 + 主题变化”的组合时，发现状态值可能已到目标，但提交前的主题插值仍会重算旧权重。现已令静态辅助状态直接使用目标主题，并额外记录真正送入已提交 drawable 的外观权重，避免只检查状态字典。此修正已写入，新增实际呈现断言仍待解锁后运行；原 21 项通过记录不冒充这项新断言已通过。

## 待完成

- 当前构建已有真实交互入口检查通过；补充以程序内时钟对齐的运动中间态截图，避免正常 app 启动时差。
- 真实系统全局主题切换后恢复（应用级 effectiveAppearance 已验证）。
- 总 GPU 功耗未测，不影响本计划不虚构节能结论的边界。
- 真实系统辅助设置与注入测试分别注明；macOS 13、外接/1x 环境仍未验证。
- M05 用户视觉选择；不自动合并 main 或切换发布默认。
