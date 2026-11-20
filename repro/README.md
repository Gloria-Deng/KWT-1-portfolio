# KWT-1 可复现源码发布版

这是 KWT-1 的独立复现包。它不包含旧仓库历史、模型权重、用户输入、部署环境、商业 EDA 或 SRAM 工艺模型。不是原竞赛提交。采用 [Apache License 2.0](../LICENSE)。

## 运行

需要 Python 3.9+ 和 Icarus Verilog（在 Linux 上用 12.0 验证，`iverilog`、`vvp` 应在 PATH）。完整矩阵测试 `--frame` 另需 Verilator 5.032 或同等支持 `--timing` 的版本、make 和 C++ 编译器；建议 Linux 或 WSL。Python 无第三方依赖。解压后在此目录运行：

```sh
python3 reproduce.py
python3 reproduce.py --frame --protocol
```

Windows 用户建议用 WSL 运行全套；基础算术和控制器项也可在安装 Icarus 后试用 `py -3 reproduce.py --protocol`。没有在原生 Windows 上实测。脚本只在临时目录生成合成向量，不下载数据、不联网，不依赖旧仓库。失败时返回非零退出状态。

## 验证范围

- **原版算术 RTL：** 5,913 组舍入向量，逐项比对 11、12、16 位输出。输入含半数、饱和、32 位极值及移位边界。MAC 分别验证 W10、W12，两行、两组累加器和 64 通道，比较有符号累加和。
- **原版整层 RTL：** Python 从固定随机种子生成 99×64 输入、64×256 的 W12 权重、偏置和缩放。测试对 99×256 的 O16 输出逐值比对，同时检查行尾、帧尾和完成状态。SRAM 用新写的行为模型代替，输出端施加固定规则的等待。
- **原版 NICE 控制器：** 单独运行已有的控制协议测试，含持续施加压力的写回、异常路径、序列回绕、重试和复位。核心终端为模拟模型，这项测试本身不检查算术、不模拟物理 Flash/SRAM。
- **不包含** E203 完整 SoC、真实 Flash 时序、CPU 读回、赛题数据和 EDA 流程。整层的周期数只描述本测试握手条件下从接受 start 到最后一个输出握手的边沿差，**不等于**作品集公布的系统吞吐量，不用于推导 150 MHz、面积、功耗或能耗。

## 文件来源

`rtl/core` 的七个模块、`rtl/nice/kwt_nice_linear_v10.v` 和两份既有控制器测试文件来自此前已整理的 KWT-1 源码快照。新增的是 Python 参考/运行工具、三个测试平台和仿真专用行为 SRAM。没有拷贝 E203、QSPI、APB UART、固件、PDK 或第三方 RTL。原始 KWT-1 代码由本项目作者编写；新增测试和文档与本复现包一同发布。

## 参考输出

同一合成数据下，报告应包含这些 PASS 标记：

```text
REQUANT_PASS vectors=5913 widths=3 comparisons=17739
MAC_PASS W=10 enabled_beats=128 lane_comparisons=256
MAC_PASS W=12 enabled_beats=128 lane_comparisons=256
FRAME_PASS W=12 O=16 inputs=6336 pairs=12672 values=25344 start_cycle=6469 final_cycle=22444 elapsed_edges=15975
NICE_FINAL_V43_PROTOCOL_CONTROL_PASS ...
```

合成整帧中，全部 25,344 个输出与 Python 整数参考值逐项一致。15,975 个周期仅为此测试台的计数，不是面积、能耗或整机性能复现。
