# 广东电信/移动 TcpQuality 前后对比（低流量版）

基于 [ibsgss/TcpQuality](https://github.com/ibsgss/TcpQuality)（上游提交 `6017af3`，许可证见 `LICENSE`），新增 `--gd-proxy-only` 模式，只测广东电信/移动。配合 [tcpfit](https://github.com/Kylin010/tcpfit) v0.5.9 做一次性 TCP 基础调优，并对比调优前后的效果。

- 测试范围：广东电信/移动 IPv4 普通回程、大包回程，以及 VPS → 广东单线程下载。
- 不测：联通、IPv6、上传、其他地区、教育网、国际线路。不上传报告，不参与测速排名。

## 功能一览

| 命令 | 作用 | 流量 | 能否重复 |
|---|---|---|---|
| `setup` | 安装依赖、NextTrace、tcpfit、core，不测速 | 仅安装包 | 可以 |
| `rtt <IP> [次数]` | 测 VPS → 指定 IP 的延迟和丢包 | 几十 KB 量级 | 可以，结果追加到 `rtt.csv` |
| `baseline [MiB]` | 调优前测试（延迟、丢包、单线程下载） | 约等于预算 | 不可以，已有记录会拒绝 |
| `tune <Mbps> [RTT]` | tcpfit 基础调优（修改系统参数，一次性） | 很少 | 不可以 |
| `after` | 调优后测试 | 约等于预算 | 不可以 |
| `compare` | 输出前后对比 | 无 | 可以 |
| `reset` | 清除比较记录（需 `RESET=YES`），不回滚 tcpfit | 无 | — |

## 使用顺序

每一步依赖前一步：`tune` 需要已有 `baseline`，`after` 需要 `baseline` 和 `tune`，`compare` 需要两次测试的结果。

1. 下载入口脚本并校验（只需一次）：
   ```sh
   curl -fsSL https://raw.githubusercontent.com/hytuytujyt/tcpquality-gd-compare/main/run.sh -o /root/tq-gd.sh
   chmod 700 /root/tq-gd.sh
   sha256sum /root/tq-gd.sh   # 与维护者在可信渠道公布的值比对，不一致不要运行
   ```
2. `setup`（可选，提前安装依赖）。
3. `rtt <IP>`（可选，建议在不同时段多测几次，记下中位数）。
4. `baseline [MiB]`：调优前测试。首次运行会提示安装依赖。
5. `tune <Mbps> [RTT]`：基础调优。
6. `after`：调优后测试。
7. `compare`：查看前后对比。

```sh
/root/tq-gd.sh rtt 你的公网IP
/root/tq-gd.sh baseline 512
/root/tq-gd.sh tune 200 60
/root/tq-gd.sh after
/root/tq-gd.sh compare
```

## 参数说明

- **Mbps**：VPS 的出口带宽上限（套餐值），必须是整数，不能写 `auto`。
- **RTT**（毫秒，1–2000）：优先使用 `rtt` 测得的中位数。省略时取 baseline 中电信/移动普通回程平均延迟的较大值（向上取整）；没有有效数据则用 150 ms。
- **预算 MiB**：基线 + 调优后两轮合计，范围 32–2048，必须是 4 的倍数，默认 128。每次下载上限为预算的 1/4，每次下载有 10 秒超时。
- **`rtt` 的环境变量**：`TQ_RTT_COUNT`（次数，默认 30，范围 1–999）、`TQ_RTT_PORT`（端口，默认 443）。
- **其他环境变量**：`TCPQUALITY_GD_DATA_DIR`（数据目录，默认 `/root/tcpquality-gd-compare`，须为绝对路径）、`AUTO_INSTALL=1`（非交互模式下允许安装）、`FORCE_TCPFIT=1`（强制使用校验不符的已有 tcpfit）、`TQ_SPEEDTEST_BUDGET_MIB`（预算的另一种设置方式）。

## 注意事项

**流量**
- 每完整对比一次（baseline + after）约消耗一个预算。重复 N 次即 N 倍。
- 依赖安装、节点列表、路由探测等流量不在预算内。
- 计数是网卡 RX+TX，包含其他流量，结果偏大，不等于供应商账单。脚本没有累计上限，需要自行记录。

**RTT**
- `rtt` 使用 TCP SYN 而不是 ICMP。如果目标端口丢弃 SYN，会显示全部丢包，换一个端口即可。
- 延迟受时段影响，建议在晚高峰测量。

**tune**
- 会修改系统 TCP 参数，只能执行一次。失败时会自动回滚。
- 想换 RTT 重做：`tcpfit rollback` → `RESET=YES /root/tq-gd.sh reset` → 重新 `baseline` → `tune`。`reset` 本身不会回滚 tcpfit。

**结果校验**
- `baseline`/`after` 的 CSV 必须同时包含广东电信和移动的有效单线程结果，否则不保存，可直接重试。
- `compare` 时如果两次测试相隔超过 6 小时，会给出提醒，结论需谨慎。

**外联**
- 会访问 `tcpquality.ibsgss.uk`、公网 IP 查询服务、`whois.cymru.com`，并从 NextTrace、tcpfit 的发布源和系统包仓库下载文件。不适用于零外联环境。

**iptables**
- 测速期间会临时创建 `TCPQ_TOS_*` 计数链，结束后删除。异常中断留下的残留链，下次运行时会自动清理。

**环境要求**：Linux VPS，root 权限，Bash，网络可用。

**数据文件**：默认保存在 `/root/tcpquality-gd-compare/`，包括 `baseline.csv`、`after.csv`、日志、时间戳、流量计数、`rtt.csv`、`tune.done`。
