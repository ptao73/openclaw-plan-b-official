#!/bin/bash
# ============================================================
# OpenClaw AWS Tokyo Worker 部署 (v2 - 基于官方文档修正)
# 三角色: overseas-researcher / critic / drafter-b
# 模型: DeepSeek Chat V3 + DeepSeek Reasoner R1
#
# 修复上次香港部署的坑:
# 1. 先 onboard (Skip model), 再手动加 provider
# 2. API Key 用环境变量 ${DEEPSEEK_API_KEY}
# 3. 用 openclaw models list 验证
# 4. 用 openclaw doctor --fix 验证配置
# ============================================================
set -e
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n\033[1m=== $1 ===\033[0m\n"; }

step "1/8 系统环境"
sudo apt update -qq && sudo apt install -y -qq curl git jq openssl
sudo apt autoremove -y -qq; sudo journalctl --vacuum-size=50M 2>/dev/null || true
if ! command -v node &>/dev/null || [[ $(node -v | cut -d. -f1 | tr -d v) -lt 22 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -; sudo apt install -y -qq nodejs
fi
log "Node.js $(node -v)"
AVAIL=$(df / --output=avail -B1M | tail -1 | tr -d ' ')
[ "$AVAIL" -lt 1500 ] && err "磁盘剩余 ${AVAIL}MB 不足"
log "磁盘 ${AVAIL}MB"

step "2/8 安装 OpenClaw"
# 固定版本，和 HK 保持一致，避免 latest 回归问题
sudo npm install -g openclaw@2026.3.13 2>/dev/null
log "OpenClaw $(openclaw --version 2>/dev/null || echo installed)"

step "3/8 DeepSeek API Key"
echo ""; read -sp "DeepSeek API Key: " DEEPSEEK_KEY; echo ""
[ -z "$DEEPSEEK_KEY" ] && err "Key 必填"
export DEEPSEEK_API_KEY="$DEEPSEEK_KEY"
grep -q "DEEPSEEK_API_KEY" ~/.bashrc 2>/dev/null || {
  echo "" >> ~/.bashrc
  echo "export DEEPSEEK_API_KEY=\"$DEEPSEEK_KEY\"" >> ~/.bashrc
}
log "DEEPSEEK_API_KEY 已设置"

step "4/8 onboard（模型选 Skip for now）"
echo "  ⚠️  向导问题回答指引:"
echo "     Model/auth provider → Skip for now"
echo "     Channel → Skip for now"
echo "     Skills → No"
echo "     Hatch → Do this later"
echo ""; read -p "按回车开始 onboard..." -r
if openclaw onboard --install-daemon 2>&1; then log "onboard 完成"
else
  warn "onboard 退出码: $?"
  read -p "继续？(y/n): " CONT
  [[ "$CONT" != "y" && "$CONT" != "Y" ]] && err "用户中止"
fi

step "5/8 添加 DeepSeek provider"
python3 << 'PYEOF'
import json, os
path = os.path.expanduser("~/.openclaw/openclaw.json")
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        try: cfg = json.load(f)
        except: cfg = {}
cfg.setdefault("models", {})
cfg["models"]["mode"] = "merge"
cfg["models"].setdefault("providers", {})

# API Key 从环境变量读取（步骤 3 已 export）
ds_key = os.environ.get("DEEPSEEK_API_KEY", "")
if not ds_key:
    print("错误: DEEPSEEK_API_KEY 环境变量为空")
    raise SystemExit(1)

cfg["models"]["providers"]["deepseek"] = {
    "baseUrl": "https://api.deepseek.com/v1",
    "apiKey": ds_key,
    "api": "openai-completions",
    "models": [
        {"id": "deepseek-chat", "name": "DeepSeek Chat V3", "reasoning": False,
         "input": ["text"],
         "cost": {"input": 2.8e-7, "output": 4.2e-7, "cacheRead": 2.8e-8, "cacheWrite": 2.8e-7},
         "contextWindow": 128000, "maxTokens": 8192},
        {"id": "deepseek-reasoner", "name": "DeepSeek Reasoner R1", "reasoning": True,
         "input": ["text"],
         "cost": {"input": 2.8e-7, "output": 4.2e-7, "cacheRead": 2.8e-8, "cacheWrite": 2.8e-7},
         "contextWindow": 128000, "maxTokens": 65536}
    ]
}
cfg.setdefault("agents", {})
cfg["agents"].setdefault("defaults", {})
cfg["agents"]["defaults"]["model"] = {"primary": "deepseek/deepseek-chat", "fallbacks": ["deepseek/deepseek-reasoner"]}
cfg["agents"]["defaults"]["models"] = {
    "deepseek/deepseek-chat": {"alias": "DeepSeek"},
    "deepseek/deepseek-reasoner": {"alias": "DeepSeek R1"}
}
with open(path, "w") as f: json.dump(cfg, f, indent=2, ensure_ascii=False)
print(f"DeepSeek provider 写入完成 (key: {ds_key[:8]}...)")
PYEOF
log "provider 配置完成"
echo ""; openclaw models list 2>&1 || warn "models list 需 gateway 运行后查"; echo ""

step "6/8 三个 Agent + Gateway + Hooks"
GW_TOKEN=$(openssl rand -hex 24)
python3 << PYEOF
import json, os
path = os.path.expanduser("~/.openclaw/openclaw.json")
with open(path) as f: cfg = json.load(f)
home = os.path.expanduser("~")

# setdefault 防止 KeyError
cfg.setdefault("agents", {})
cfg["agents"].setdefault("defaults", {})
d = cfg["agents"]["defaults"]
d["workspace"] = f"{home}/.openclaw/workspace"
d["compaction"] = {"mode": "safeguard"}
d["maxConcurrent"] = 4
d["subagents"] = {"maxConcurrent": 4}
cfg["agents"]["list"] = [
    {"id": "overseas-researcher", "name": "🌐 Overseas Researcher", "default": True,
     "workspace": f"{home}/.openclaw/workspace-overseas-researcher",
     "model": {"primary": "deepseek/deepseek-chat", "fallbacks": []}},
    {"id": "critic", "name": "🔥 Critic",
     "workspace": f"{home}/.openclaw/workspace-critic",
     "model": {"primary": "deepseek/deepseek-reasoner", "fallbacks": ["deepseek/deepseek-chat"]}},
    {"id": "drafter-b", "name": "📝 Drafter-B",
     "workspace": f"{home}/.openclaw/workspace-drafter-b",
     "model": {"primary": "deepseek/deepseek-chat", "fallbacks": []}}
]
cfg["channels"] = {}
cfg["tools"] = {"profile": "coding"}
cfg["commands"] = {"native": "auto", "restart": True}
cfg["session"] = {"dmScope": "per-channel-peer"}

cfg.setdefault("gateway", {})
cfg["gateway"]["port"] = 18789
cfg["gateway"]["mode"] = "local"
cfg["gateway"]["bind"] = "loopback"
cfg["gateway"]["auth"] = {"mode": "token", "token": "$GW_TOKEN"}

cfg["hooks"] = {
    "enabled": True, "token": "$GW_TOKEN", "path": "/hooks",
    "defaultSessionKey": "hook:ingress", "allowRequestSessionKey": True,
    "mappings": [
        {"match": {"path": "research"}, "action": "agent", "agentId": "overseas-researcher", "deliver": True},
        {"match": {"path": "review"}, "action": "agent", "agentId": "critic", "deliver": True},
        {"match": {"path": "draft"}, "action": "agent", "agentId": "drafter-b", "deliver": True}
    ]
}
with open(path, "w") as f: json.dump(cfg, f, indent=2, ensure_ascii=False)
print("完整配置写入完成")
PYEOF
log "配置完成"
openclaw doctor --fix 2>&1 || warn "doctor 有警告"

step "7/8 Workspace + SOUL.md"
mkdir -p ~/.openclaw/workspace
cat > ~/.openclaw/workspace/SOUL.md << 'EOF'
# AWS Tokyo Worker Node
受香港中控调度的远程执行节点。使用 DeepSeek 模型。
EOF
mkdir -p ~/.openclaw/workspace-overseas-researcher
cat > ~/.openclaw/workspace-overseas-researcher/SOUL.md << 'EOF'
# 🌐 Overseas Researcher - 海外资讯搜集
## 身份
AWS Tokyo 海外信息搜集专员。日本 IP，直连 Google/GitHub/arXiv/HackerNews/Reddit。
## 职责
接收香港中控的调研任务，收集海外信息，整理结构化报告。
## 输出格式
- 核心发现（3-5 条）、来源链接、时效性、可信度、后续建议
## 原则
优先一手来源，不编造，用中文输出。
EOF
mkdir -p ~/.openclaw/workspace-critic
cat > ~/.openclaw/workspace-critic/SOUL.md << 'EOF'
# 🔥 Critic - 尖锐审查与改进建议
## 身份
极其严格的技术审查员。你不走过场，你的价值在于说真话。
## 审查对象
香港 Qwen 输出（跨模型交叉审查）、AWS drafter-b 方案、任何需要质量把关的内容。
## 审查维度
1. 准确性 — 事实、术语、数据是否正确？AI 幻觉？
2. 逻辑完整性 — 推理链断裂？因果成立？偷换概念？
3. 实用性 — 建议能直接用？模糊表述？actionable？
4. 代码审查 — bug？边界？安全隐患？更优写法？
## 输出格式
审查结论(通过/需修改/不合格) → 问题清单(🔴严重/🟡中等/🔵轻微 + 修改建议) → 改进建议 → 评分X/10
## 原则
- 不说"总体不错" — 找不到问题说明不够仔细
- 每个问题必须附修改建议
- 8分以上才通过，6-7返工，5以下重写
- 如果输入内容明显不完整（截断、格式错乱、缺少关键段落），直接返回 "ERROR: INCOMPLETE_INPUT - 输入不完整，无法审查" 而不要强行审查
- 用中文输出
EOF
mkdir -p ~/.openclaw/workspace-drafter-b
cat > ~/.openclaw/workspace-drafter-b/SOUL.md << 'EOF'
# 📝 Drafter-B - 方案起草 (DeepSeek)

## 身份
你是 AWS Tokyo 的方案起草员，使用 DeepSeek Chat V3。
同一个任务，HK 的 Drafter-A (Qwen) 会同时出一份方案。你们的方案会交叉审查。

## 职责
- 接收中控分配的任务，独立产出完整方案
- 方案具体、可执行、有细节
- 编码任务代码必须可运行
- 标注不确定的地方

## 原则
- 你的方案会被 HK 的 Reviewer-HK (Kimi) 审查，要经得起推敲
- 不要泛泛而谈，要有具体观点
- 用中文输出
EOF
for ws in workspace workspace-overseas-researcher workspace-critic workspace-drafter-b; do
  cat > ~/.openclaw/${ws}/AGENTS.md << 'EOF'
# Agent Guidelines
- Use Chinese for all user-facing output
- Verify results before reporting
EOF
done
chmod 700 ~/.openclaw; chmod 600 ~/.openclaw/openclaw.json
log "Workspace 创建完成"

# --- auth-profiles.json for all agents (subagents need this!) ---
log "写入 auth-profiles..."
for agent_id in main overseas-researcher critic drafter-b; do
  agent_dir="$HOME/.openclaw/agents/${agent_id}/agent"
  mkdir -p "$agent_dir"
  cat > "$agent_dir/auth-profiles.json" << AUTHEOF
{
  "deepseek:default": {
    "key": "$DEEPSEEK_KEY"
  }
}
AUTHEOF
  chmod 600 "$agent_dir/auth-profiles.json"
done
log "auth-profiles 写入完成"

step "8/8 启动 Gateway"
grep -q "OPENCLAW_GATEWAY_TOKEN" ~/.bashrc 2>/dev/null || echo "export OPENCLAW_GATEWAY_TOKEN=\"$GW_TOKEN\"" >> ~/.bashrc
export OPENCLAW_GATEWAY_TOKEN="$GW_TOKEN"
GATEWAY_UP=false
if openclaw gateway install 2>&1; then
  if openclaw gateway start 2>&1; then
    sleep 10; ss -lntp | grep -q 18789 && GATEWAY_UP=true
  fi
fi
if [ "$GATEWAY_UP" = false ]; then
  warn "回退到 systemd unit"
  OPENCLAW_BIN=$(which openclaw)
  sudo tee /etc/systemd/system/openclaw-worker.service > /dev/null << SVCEOF
[Unit]
Description=OpenClaw AWS Worker
After=network.target
[Service]
Type=simple
User=$(whoami)
Environment=OPENCLAW_GATEWAY_TOKEN=$GW_TOKEN
Environment=DEEPSEEK_API_KEY=$DEEPSEEK_KEY
Environment=HOME=$HOME
ExecStart=$OPENCLAW_BIN gateway run --port 18789 --bind loopback --auth token --token $GW_TOKEN
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
SVCEOF
  sudo systemctl daemon-reload; sudo systemctl enable openclaw-worker; sudo systemctl start openclaw-worker
  sleep 10; ss -lntp | grep -q 18789 && GATEWAY_UP=true
fi

echo ""
if [ "$GATEWAY_UP" = true ]; then
  log "✅ 端口 18789 已监听（这是唯一可靠的启动判断）"
  ss -lntp | grep 18789; echo ""

  echo "--- 以下为参考信息（不代表完全可用） ---"
  openclaw gateway status 2>&1 || true; echo ""
  openclaw agents list 2>&1 || true; echo ""

  echo "--- 验证 DeepSeek API 是否真通 ---"
  echo "请手动执行以下命令测试:"
  echo '  curl -s https://api.deepseek.com/v1/models -H "Authorization: Bearer $DEEPSEEK_API_KEY" | head -20'
else
  warn "Gateway 未启动，手动: openclaw gateway run --port 18789 --bind loopback"
fi

step "部署完成"
echo "  🎉 AWS Tokyo Worker"
echo "  ┌──────────────────────────────────────────────────┐"
echo "  │ 🌐 overseas-researcher  DeepSeek Chat    海外搜索 │"
echo "  │ 🔥 critic              DeepSeek R1      尖锐审查 │"
echo "  │ 📝 drafter-b           DeepSeek Chat    出方案   │"
echo "  └──────────────────────────────────────────────────┘"
echo "  Gateway: 127.0.0.1:18789 | Token: $GW_TOKEN"
echo ""
echo "  Webhook:"
echo "    POST /hooks/research → overseas-researcher"
echo "    POST /hooks/review   → critic"
echo "    POST /hooks/draft    → drafter-b"
echo ""
echo "  ⚠️  重要: 如果 agents list 显示的 provider 不是 deepseek/ 开头"
echo "     （比如变成了 deepseek-portal/ 或 custom-xxx/）"
echo "     需要像 HK 一样修正 agents.list 里的 model.primary"
echo ""
echo "  香港中控对接:"
echo "    ssh -L 28789:127.0.0.1:18789 ubuntu@YOUR_AWS_IP -i key-pair.pem"
echo "  ⚠️ 记住 Token: $GW_TOKEN"
