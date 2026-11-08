# 广东电信/移动低流量 TcpQuality 前后对比

本目录包含一个基于 [ibsgss/TcpQuality](https://github.com/ibsgss/TcpQuality) 的专用版本，源代码对应上游提交 `6017af3fcb83b300b9a15b058d58062551d1c682`。保留上游许可证，见本目录 `LICENSE`；新增 `--gd-proxy-only` 专用模式，限制测试范围。

独立仓库：[hytuytujyt/tcpquality-gd-compare](https://github.com/hytuytujyt/tcpquality-gd-compare)。

## 测试范围

- 广东电信、移动的 IPv4 普通回程。
- 广东电信、移动的 IPv4 大包回程。
- VPS → 广东的电信、移动单线程下载测速。
- 单线程下载总预算按调优前、调优后两轮合计设置，可设 32–2048 MiB（4 的倍数），默认 128 MiB。预算平均分配给四次下载（两个运营商 × 两轮）；每次另有 10 秒超时，实际通常更少。

不测联通、其他地区、IPv6、上传、教育网、国际互联、Apple CDN；不上传测试报告或参与测速排名。未能获取广东地区对应运营商测速节点时会报错，不回退到其他地区。

网卡 RX+TX 计数会记录在结果文件中，但包含 VPS 上其他并发流量，也不保证等于商家计费字节。

## 自动准备与操作流程

以 root 在 Linux VPS 上运行。需要 Bash 与网络连接。首次执行 `baseline` 会：

1. 检查并询问是否自动安装缺少的系统工具。
2. 下载固定版本的 NextTrace Tiny 发行二进制，并在安装前校验对应架构的 SHA256；下载的 TcpQuality core 也会校验 SHA256，运行前无论 core 来自脚本目录还是数据目录都会再次校验。wrapper 会从不可变提交下载与发布版本匹配的 core。
3. 如系统没有 tcpfit，下载官方 v0.5.9 脚本并校验 SHA256 后安装到 `/usr/local/bin/tcpfit`。
4. 完成上述准备后才开始基线测试。

支持 Debian/Ubuntu 和 Alpine 的系统依赖安装。包管理器下载会消耗额外流量，**不包含在测速载荷上限内**；脚本会在安装前显示计划并要求确认。测速时通过 wrapper 禁止 core 静默安装依赖；若检查到缺失，会提示先运行 `setup` 准备依赖。

从不可变提交下载入口脚本（该提交版本为 `25f70af3c1b6f20b42c6ba1b071a8e7d1eb58914`）：

```sh
curl -fsSL https://raw.githubusercontent.com/hytuytujyt/tcpquality-gd-compare/main/run.sh -o /root/tq-gd.sh
chmod 700 /root/tq-gd.sh
```

下载的 `run.sh` 本身仍需由用户从可信渠道确认；README 给出的链接固定到 commit，但没有提供入口脚本的独立 checksum。

```sh
# 只自动安装/检查，不开始测试（可选）
/root/tq-gd.sh setup

# 自动准备依赖；交互设置基线+调优后两轮的下载总预算，默认128MiB
/root/tq-gd.sh baseline
# 也可指定两轮总量：512MiB总预算，四次下载各最多128MiB
# /root/tq-gd.sh baseline 512

# 只做 tcpfit 基础调优；200 替换成套餐已知带宽 Mbps
# 可选传入测得的 RTT（毫秒）；省略时按固定 150 ms 调优
/root/tq-gd.sh tune 200 35

# 调优后复测并比较
/root/tq-gd.sh after
/root/tq-gd.sh compare
```

`baseline` 会询问调优前+调优后两轮的单线程下载载荷总预算，默认 128 MiB，须为 4 的倍数；也可用 `baseline 512` 或 `TQ_SPEEDTEST_BUDGET_MIB=512 /root/tq-gd.sh baseline` 设置。`after` 自动沿用该预算。预算四等分给四次下载：128 MiB 意味每次最多 32 MiB；512 MiB 意味每次最多 128 MiB。它不是全机网络流量硬上限。

`tune 200` 等价于 `tcpfit tune --role proxy --bw 200 --rtt 150`；也可用 `tune 200 35` 指定实测 RTT（毫秒，范围 1–2000）。不传 RTT 时 tcpfit 使用固定默认值 150 ms，不会自动探测，建议按目标线路测量后传入。命令固定代理用途和已知带宽，只做基础调优，不执行 iperf 带宽探测、自动调优或拐点扫描。带宽必须是已知数值，不要写 `auto`。脚本采用一次性标记，防止误跑重复调优或重复测速。

## 依赖安装与测试流程

系统工具只在准备阶段检查和安装。`baseline`、`after` 运行时缺少 core 依赖会停止并提示先运行 `setup`，不会在测速期间静默安装；独立直接运行 core 时仍按 core 自身行为检查依赖。

入口 `run.sh` 固定从新仓库的不可变提交下载 core，并在使用前校验其 SHA256。

## 外联、系统规则与结果解释

“不上传测试报告或参与测速排名”仅指报告/排名上传已关闭，不表示完全没有外联。运行时会从 `tcpquality.ibsgss.uk` 请求广东节点列表及测速候选；会向公网 IP 查询服务（如 ipify、icanhazip、ifconfig.me）查询出口地址，并把路由跳点 IP 交给 `whois.cymru.com` 查询 ASN。NextTrace、core、tcpfit 和系统依赖也会从各自发布源/包仓库下载。若需要零外联环境，此工具不适用。

系统已有 iptables/ip6tables 时，core 会为单次测速临时创建 `TCPQ_TOS_*` 计数链，以统计目标连接流量；正常结束会删除规则和链。强制杀进程或断电可能跳过清理，异常后可用 `iptables -S | grep TCPQ_TOS` 检查 IPv4 规则（IPv6 可检查 `ip6tables -S`）。这是计数用途，不是用于放行或阻断流量的规则。

单次前后对比受时段、节点负载和链路波动影响。需要较可靠的结论时，建议在相近时段重复多轮，比较中位数，并记录节点/RTT；不要把一次小流量下载结果视为稳定带宽承诺。

## 流量预算与数据保存

用户设置的总预算分配到四个下载对象（两个运营商 × 两轮），每次最多为总预算的四分之一；另有少量回程探测、脚本/节点列表下载、协议开销及可能重传。安装系统依赖和 NextTrace/Tcpfit 工具的流量单独记录。脚本最后会列出准备工具、调优前测试、tcpfit 基础调优、调优后测试各阶段的网卡 RX+TX 增量及合计。计数包含并发流量，不是全机流量硬封顶，也不保证等于供应商账单。

结果默认保存在 `/root/tcpquality-gd-compare/`，包括预算设置、基线/调优后 CSV、完整日志、时间戳、分阶段流量计数及 `tune.done` 标记。每次运行的 CSV 使用独立临时文件名，完成后才替换对应阶段结果。可以设置 `TCPQUALITY_GD_DATA_DIR` 更换目录（绝对路径且不能经过符号链接）。

如需重开一组：先备份结果；如要恢复系统到首次调优前，先运行 `tcpfit rollback`，再执行：

```sh
RESET=YES /root/tq-gd.sh reset
```

reset 仅删除工具管理的比较记录和数据目录中的 core，保留目录及其他文件，不会卸载系统依赖/tcpfit，也不会回滚系统 TCP 配置。为避免误删，`TCPQUALITY_GD_DATA_DIR` 必须是绝对路径；脚本拒绝根目录、常见系统目录、用户主目录及路径中的符号链接。
