# Plan B: 官方 OpenClaw 双节点对抗式协作系统

> 状态：✅ 已部署并跑通（2026年3月16日）

基于 OpenClaw 2026.3.13 官方框架，在两台服务器上部署七个 AI 角色，实现双模型对抗式协作。

本仓库已经整理为可独立发布的 GitHub 项目。仓库中不包含真实 API Key、Bot Token、隧道凭据或服务器私钥，所有配置文件都使用占位符或环境变量方案。

## 项目亮点

- 基于官方 OpenClaw 方案，适合直接落地双节点部署
- HK 中控负责规划、整合与 Telegram 交互，AWS worker 负责海外检索和对抗式起草
- 支持 SSH Tunnel、Cloudflare Tunnel、直连三层通信思路
- 同时覆盖部署脚本、SOUL 模板、配置样例和跨机调度脚本
- 文档基于真实上线经验整理，包含已验证的踩坑记录

## 系统架构

```
                         ┌─────────────────────────────────┐
                         │           用户 (Telegram)         │
                         └──────────────┬──────────────────┘
                                        │
                    ┌───────────────────▼───────────────────┐
                    │     HK 阿里云 ECS · 中控 (Qwen)       │
                    │                                        │
                    │  💡 Planner ──── 调度 + 整合终稿       │
                    │  📝 Drafter-A ── 出方案 (Qwen Plus)    │
                    │  🔍 Researcher ─ 国内信息 (Qwen Turbo) │
                    │  🔎 Reviewer-HK  审查AWS方案 (Qwen)    │
                    │                                        │
                    │  通信层:                                │
                    │  ├── SSH 隧道 (主用, autossh 保活)     │
                    │  ├── Cloudflare Tunnel (备选)          │
                    │  └── 直连 (待开放)                     │
                    └──────────────┬────────────────────────┘
                                   │ webhook + SSH
                    ┌──────────────▼────────────────────────┐
                    │     AWS EC2 东京 · Worker (DeepSeek)    │
                    │                                        │
                    │  📝 Drafter-B ──── 出方案 (DS Chat)    │
                    │  🔥 Critic ─────── 尖锐审查 (DS R1)   │
                    │  🌐 Overseas-Res ─ 海外信息 (DS Chat)  │
                    └───────────────────────────────────────┘
```

## 对抗式协作流程

```
用户提问 → Planner 分析
                │
     ┌──────────┴──────────┐
     ▼                      ▼
 Drafter-A (Qwen)    Drafter-B (DeepSeek)
 出方案 A                出方案 B
     │                      │
     │   ┌──── 交叉 ────┐   │
     ▼   ▼              ▼   ▼
 Critic (R1)        Reviewer-HK
 审查方案 A          审查方案 B
     │                      │
     └──────────┬──────────┘
                ▼
     Planner 整合终稿
     (标注来源 + 解决冲突)
```

## 部署步骤

### 前置条件

- 两台服务器（HK + AWS），均为 Ubuntu 24.04
- Qwen API Key（通义千问 DashScope）
- DeepSeek API Key
- Telegram Bot Token（通过 @BotFather 创建）
- Cloudflare 账号 + 域名（可选，用于备选通道）

### Step 1: 部署 HK 中控

```bash
scp deploy-hk.sh root@HK_IP:/tmp/
ssh root@HK_IP
bash /tmp/deploy-hk.sh
```

onboard 向导回答：
- Model → Skip for now
- Channel → 选 Telegram，输入 Bot Token
- Skills → No
- Hatch → Do this later

部署完后手动更新角色配置（Python 脚本更新 `agents.list`），参考 `config-examples/hk-openclaw.json`。

### Step 2: 验证 HK 四角色

在 Telegram 测试三条命令：
1. `让 drafter-a 写一个 Python hello world`
2. `让 researcher 查一下 Node.js 22 新特性`
3. `让 reviewer-hk 审查：TCP是四次握手协议`

确认 planner 能 spawn 三个 subagent。

### Step 3: 部署 AWS Worker

```bash
scp deploy-aws.sh ubuntu@AWS_IP:/tmp/
ssh ubuntu@AWS_IP
bash /tmp/deploy-aws.sh
```

同样 onboard 时全部 Skip，脚本会自动配置 DeepSeek provider 和三个角色。

### Step 4: 建立通信通道

**SSH 隧道（主用）：**

把 AWS 密钥传到 HK：
```bash
# 在 HK 上
mkdir -p /root/.ssh
# 用 nano 或 scp 把 AWS key 放到 /root/.ssh/aws-key.pem
chmod 600 /root/.ssh/aws-key.pem
```

安装 autossh 并创建 systemd 服务：
```bash
apt install -y autossh

cat > /etc/systemd/system/aws-tunnel.service << 'EOF'
[Unit]
Description=SSH Tunnel to AWS Tokyo OpenClaw
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/autossh -M 0 -o "ServerAliveInterval=30" -o "ServerAliveCountMax=3" -o "StrictHostKeyChecking=no" -N -L 28789:127.0.0.1:18789 ubuntu@AWS_IP -i /root/.ssh/aws-key.pem
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable aws-tunnel
systemctl start aws-tunnel
```

**Cloudflare Tunnel（备选）：**

在 AWS 上安装 cloudflared：
```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb
```

在 Cloudflare Dashboard 创建 Tunnel，拿到 token 后：
```bash
sudo cloudflared service install YOUR_TUNNEL_TOKEN
```

添加 Public Hostname：subdomain → domain，Service → HTTP localhost:18789。

### Step 5: 验证跨服务器通信

从 HK 测试 webhook：
```bash
curl -s -X POST http://127.0.0.1:28789/hooks/agent \
  -H "Authorization: Bearer YOUR_AWS_HOOKS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"message": "hello test", "agentId": "drafter-b", "wakeMode": "now"}'
```

返回 `{"ok":true,"runId":"..."}` 即成功。

### Step 6: 部署调度脚本

把 `scripts/aws-task.sh` 放到 HK 的 `/root/scripts/`，修改里面的 token 和 IP。

把 `scripts/read-result.py` 放到 AWS 的 `~/`。

测试：
```bash
/root/scripts/aws-task.sh drafter-b "用一句话介绍 DeepSeek V3"
```

### Step 7: 更新 Planner SOUL.md

用 `soul-templates/planner.md` 的内容替换 `~/.openclaw/workspace-planner/SOUL.md`，重启 gateway。

## 文件说明

| 文件 | 部署位置 | 作用 |
|------|---------|------|
| `deploy-hk.sh` | HK 执行一次 | HK 中控一键部署 |
| `deploy-aws.sh` | AWS 执行一次 | AWS worker 一键部署 |
| `scripts/aws-task.sh` | HK `/root/scripts/` | 封装 HK→AWS 调度流程 |
| `scripts/read-result.py` | AWS `~/` | 从 JSONL 提取 agent 输出 |
| `soul-templates/*.md` | 各 agent workspace | 角色定义 |
| `config-examples/*.json` | 参考用 | 配置模板（需替换占位符） |

## 三层通信方案

| 层级 | 方式 | 延迟 | 优点 | 适用 |
|------|------|------|------|------|
| 主用 | SSH 隧道 (autossh) | 低 | 不开端口，加密，自动重连 | 日常调度 |
| 备选 | Cloudflare Tunnel | 中 | 不开端口，有 CF 防护 | SSH 断开时 |
| 直连 | 开放 AWS 18789 | 最低 | 最快 | 需开安全组 |

`aws-task.sh` 内置自动 failover：SSH 隧道失败自动切 Cloudflare。

## 关键 Token 清单

部署完成后需要记录以下 token（各自独立生成）：

| Token | 用途 | 生成方式 |
|-------|------|---------|
| HK Gateway Token | HK gateway 认证 | `openssl rand -hex 24` |
| HK Hooks Token | 接收 AWS 回调 | `openssl rand -hex 24` |
| AWS Gateway Token | AWS gateway 认证 | 部署脚本自动生成 |
| AWS Hooks Token | HK 发任务到 AWS | `openssl rand -hex 24` |

⚠️ 同一台服务器上，Gateway Token ≠ Hooks Token（OpenClaw 强制要求不同）。

## 已知限制

1. **Subagent 模型路由 bug** — subagent 可能忽略单独配置的模型，使用 parent 的模型。暂时所有角色用同一 provider。
2. **Webhook 单向** — `ok:true` 只代表任务接收，不是完成。结果需要 SSH 拉取。
3. **SOUL.md 指令非强制** — agent 不一定按 SOUL.md 的 curl 指令回传结果，封装成脚本更可靠。

详见 [LESSONS.md](LESSONS.md)。
