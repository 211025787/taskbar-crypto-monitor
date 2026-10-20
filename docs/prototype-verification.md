# 胶囊 UI 覆盖任务栏 —— 最小原型实机验证报告（第二步）

- **项目**：Taskbar Crypto Monitor
- **验证日期**：2026-10-19
- **验证环境**：Windows 11 Home China 26H2（Build 26300.9711，x64，实机）
- **方案**：用户确认的"汽水音乐播放栏式"胶囊 UI 覆盖任务栏（知情决策：覆盖层方案，非任务栏内部嵌入）
- **结论**：✅ **验证通过**——胶囊窗口真实覆盖在任务栏上并正确渲染，进入第三阶段开发依据成立

---

## 1. 原型实现概述

| 组件 | 实现 |
|---|---|
| 窗口框架 | Tauri 2.12.4（Wry 0.57 / WebView2），无边框 + 透明 + 置顶 + 不抢焦点（WS_EX_NOACTIVATE）+ 不进任务栏按钮 |
| 定位机制 | Rust 探测 `Shell_TrayWnd` 矩形（FindWindowW + GetWindowRect），SetWindowPos 将 372×44 胶囊垂直居中放入任务栏，右边界钳制防溢出 |
| Z 序维持 | **看门狗线程**：1.2s 周期遍历桌面 Z 序（GW_CHILD/G_HWNDNEXT），检测到 Win11 任务栏重新断言置顶压过胶囊时立即重新断言 TOPMOST |
| 胶囊 UI | React 19 + TypeScript：合约徽标 + 价格 + 涨跌幅 + SVG Sparkline（渐变面积 + 端点呼吸动画），毛玻璃拟态 CSS（半透明底/内高光/投影），入场动画，`data-tauri-drag-region` 整体可拖动 |
| 构建链 | GNU 工具链（rustc 1.98.1，D:\develop\rust）+ MSYS2 mingw64（windres 资源编译），干净 PATH 规避 git-bash DLL 冲突 |

## 2. 验证证据链（全部实机采集）

| 编号 | 验证项 | 方法 | 结果 |
|---|---|---|---|
| E1 | 窗口几何嵌入 | GetWindowRect 对比 | 任务栏 (0,1019)-(1707,1067)，胶囊 (43,1021)-(415,1065)：**完全嵌入且垂直居中** |
| E2 | TOPMOST 属性 | GetWindowLong(GWL_EXSTYLE) | PASS |
| E3 | Z 序压制 | EnumWindows 桌面 Z 序枚举 | 修复前 Shell_TrayWnd 在胶囊之上（Win11 任务栏周期性重断言置顶）；**看门狗启用后胶囊 [0] 稳定位于任务栏 [1] 之上** |
| E4 | WebView 渲染 | PrintWindow(PW_RENDERFULLCONTENT) + OCR | **完整读出全部内容**：`BTCUSDT`、`67,432.10`、`+2.41%`、绿色 Sparkline、深色圆角胶囊底、白色文本全部正确 |
| E5 | 屏幕真实可见 | 杀进程前后 CopyFromScreen 像素差分 | **23,917 像素差异**（阈值 RGB 分量和>24），胶囊对屏幕有真实视觉贡献；文本因透明窗口 alpha 合成亮度衰减，肉眼可见但低于程序化白色阈值（>170），已用差分法绕过 |

## 3. 关键技术发现（第三阶段必须遵守）

1. **Win11 任务栏 Z 序竞争**：任务栏会周期性/事件触发地重新断言自身置顶，普通 TOPMOST 窗口会被压下——看门狗线程（已实现）是持续覆盖的必要条件；
2. **透明窗口 + 截图验证陷阱**：透明窗口的内容经 alpha 合成后亮度衰减，CopyFromScreen + 高阈值扫描会误判"不可见"；正确验证手段是 PrintWindow（渲染层）+ 前后差分（合成层）；
3. **backdrop-filter 不能穿透窗口**：CSS backdrop-filter 只模糊页面内背景，无法模糊窗口背后的任务栏；胶囊底色实际由 rgba 半透明色 + 任务栏本色混合而成（深色任务栏下观感更暗，浅色下更亮），第三阶段需按任务栏主题适配底色；
4. **GNU 工具链约束**：git-bash 的 DLL 与 MSYS2 gcc 冲突导致 windres 静默失败，构建须用 mingw64 优先的干净 PATH；cdylib 目标触发 GNU ld 导出序号超限，桌面端仅保留 rlib；
5. **布局待优化**：当前 X=43 起点覆盖任务栏搜索框区域，第三阶段应避开任务栏左侧图标区（开始/搜索/任务视图），定位到任务栏中部空白带。

## 4. 阶段状态

- 第一步 技术可行性调研：✅ 完成（docs/taskbar-integration-feasibility.md）
- 第二步 最小原型实机验证：✅ **完成（本报告）**
- 第三步 行情/趋势/预警/设置开发：待启动
- 第四步 打包测试：未开始

---

*验证脚本存于 scripts/（verify-prototype.ps1 / verify-zorder.ps1 / dump-capsule-window.ps1 / diff-verify.ps1），截图存于 docs/screenshots/，可重复执行。*