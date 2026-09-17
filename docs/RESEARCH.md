# 技术验证记录

日期：2026-09-17。

## 目标分离

1. M4 当前可验证：开盖状态内屏退出桌面布局、请求面板关闭，外屏正常工作，断开所有外屏或程序结束时恢复。
2. 基础款 M3 待研究：模拟真实合盖触发显示资源重新分配，使两台原生外屏在物理开盖时工作。

第二项目标不能用第一项测试通过代替。已收到 M3 的开盖／合盖／重新开盖采样，但没有远程控制该机的环境。v0.2 新增实际驱动合盖请求与严格双外屏验收，M3 硬件解锁效果尚未验证；实现见 [DIRECT-ROUTING.md](DIRECT-ROUTING.md)。

## 本机观测

- 型号：Mac16,12 / M4 MacBook Air；macOS 15.6.1 (24G90)。
- 初始内屏 ID 1；外屏 ID 3、2，均为扩展模式。
- HID 匹配：VendorID 0x05ac，ProductID 0x8104，UsagePage 0x20，Usage 0x8a。
- Feature report 1 读取成功，原始字节 `01 25 00`，实验解释为 37 度；这不是跨机型校准结论。
- 调用 `IORegistryEntrySetCFProperty` 提交 `IOPMTestClamshellOpen` 返回 `0xe00002e2`，即不允许；系统合盖状态仍为 false。
- 当前原型没有尝试写 HID output/feature report：写物理设备报告与向系统注入传感器输入并不等价。

## 显示短测

日志：项目 `.tmp/trial.log`；由 `tests/check_trial.py` 检查。

1. 初始三个屏幕在线，系统开盖。
2. SkyLight 布局断开成功，面板 power=0 请求返回 0。
3. 在线显示列表只剩两台原有外屏；合盖状态依然 false。
4. 独立守护定时请求面板 power=1，恢复布局；内屏回到 active/awake。

读取到的 framebuffer `current_power=1`、`idle_state=5` 在关屏前后未变化；不能据此证明面板物理断电。`CGDisplayIsAsleep` 对已断开内屏也不能作为有效光学状态判据。背光状态等待肉眼验证。

## 恢复保护

- 会话启动顺序：检查外屏和开盖状态 → 缓存内屏 ID → 独立守护 READY → 断开布局与面板电源请求。
- 外屏检测使用 CoreGraphics 在线且 active 的非内建显示器。读取失败按无可用外屏处理，优先恢复。当前未针对 DisplayLink、AirPlay、Sidecar 或虚拟显示器认证；推荐原生外屏测试。
- 守护通过独立进程、管道 EOF 和心跳超时检测主程序故障。
- 第一次强杀测试的日志转发随主程序消失，测试错误地未能确认恢复；随后直接查询证实内屏已恢复。已将 READY 后的守护输出改为直接继承日志目标，消除转发依赖。
- 恢复状态机有 8 个测试，包括两外屏减少到一台继续工作、减到零触发恢复、EOF、心跳失败、超时与短测期限。
- 硬件拔线测试尚未执行，不把状态机测试称为拔线验证。
- 修复后重跑 `tests/crash_recovery.py` 通过：SIGKILL 结束本项目测试主进程后，独立守护记录 `owner_exited`，重新查询确认内屏 active/awake。日志位于 `.tmp/crash-recovery.log`。
- 原生菜单栏应用已启动；Computer Use 界面检查工具超时，尚未完成菜单的可视化验收。

## 证据与后续研究边界

- [Apple XNU IOPMrootDomain.cpp](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOPMrootDomain.cpp)：当前开源 main 中 `IOPMTestClamshellClose/Open` 受 `DEBUG || DEVELOPMENT` 编译条件限制，`setProperties` 还有 entitlement 检查。该源码不是当前机器闭源驱动的完整证明，也不保证与本机内核版本完全相同。
- [Apple IOKit 属性写入](https://developer.apple.com/documentation/iokit/1514882-ioregistryentrysetcfproperty)：请求由接收对象处理，不是任意状态写入。
- [BetterDisplay M3 讨论](https://github.com/waydabber/BetterDisplay/discussions/3914)：开发者区分 soft-off 与释放 framebuffer 输出资源。
- [Lunar FAQ](https://lunar.fyi/faq)：M3 开盖双外屏仍未实现。
- [Clamless helper](https://github.com/TCXM/clamless/blob/main/src/helper/clamless-display.c)：本项目引用的 MIT 显示控制实现；Git blob a3e4ac277b461d64bb6baf4bb3461e596dace2b3。

需要 M3 实机进一步比较真正合盖与软件关闭的设备树、显示日志和输出路由。任何需要替换内核、驱动、固件或改变系统安全设置的实验，都超出此原型当前执行范围。
