#!/bin/bash
# ============================================================
# OpenClaw 官方部署 - 一键脚本
# 香港 ECS · 四角色中控 · 方案A (agents.list)
#
# 用法:
#   scp deploy-all.sh root@YOUR_HK_IP:/tmp/
#   ssh root@YOUR_HK_IP
#   bash /tmp/deploy-all.sh
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${BOLD}=== $1 ===${NC}\n"; }

# ============================================================
step "第 1 步: 系统环境准备"
# ============================================================

apt update -qq 2>/dev/null
apt install -y -qq curl git jq openssl 2>/dev/null
log "基础工具就绪"

# Node.js 22
if ! command -v node &>/dev/null || [[ $(node -v | cut -d. -f1 | tr -d v) -lt 22 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt install -y -qq nodejs
fi
log "Node.js $(node -v)"

# ============================================================
step "第 2 步: 安装 OpenClaw CLI"
# ============================================================

npm install -g openclaw@latest 2>/dev/null
log "OpenClaw $(openclaw --version 2>/dev/null || echo 'installed')"

# ============================================================
step "第 3 步: 收集 API Key"
# ============================================================

echo ""
read -sp "Qwen API Key (阿里云百炼): " QWEN_KEY
echo ""
if [ -z "$QWEN_KEY" ]; then err "Qwen Key 必填"; fi
log "Qwen Key 已输入"

read -sp "DeepSeek API Key (没有按回车跳过): " DEEPSEEK_KEY
echo ""
[ -n "$DEEPSEEK_KEY" ] && log "DeepSeek Key 已输入" || warn "跳过 DeepSeek"

read -sp "Moonshot/Kimi API Key (没有按回车跳过): " MOONSHOT_KEY
echo ""
[ -n "$MOONSHOT_KEY" ] && log "Moonshot Key 已输入" || warn "跳过 Moonshot"

# ============================================================
step "第 4 步: 初始化 OpenClaw"
# ============================================================

mkdir -p ~/.openclaw

if [ ! -f ~/.openclaw/openclaw.json ]; then
  # 创建最小配置让 onboard 跳过交互
  cat > ~/.openclaw/openclaw.json << 'MINJSON'
{
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "loopback"
  }
}
MINJSON
  log "创建初始配置"
fi

# 安装 daemon
# onboard 可能交互式提问，如果已经有配置文件则跳过
if openclaw onboard --install-daemon 2>&1; then
  log "OpenClaw 初始化完成"
else
  ONBOARD_EXIT=$?
  warn "onboard 退出码: $ONBOARD_EXIT"
  warn "如果是因为已有配置而跳过，属于正常情况"
  warn "如果是真正的安装失败，请检查上方错误信息后重新运行"
  echo ""
  read -p "是否继续部署？(y/n): " CONTINUE
  if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
    err "用户中止部署。请解决 onboard 问题后重新运行。"
  fi
fi

# ============================================================
step "第 5 步: 写入完整配置"
# ============================================================

GW_TOKEN=$(openssl rand -hex 24)

python3 << PYEOF
import json, os

config_path = os.path.expanduser("~/.openclaw/openclaw.json")

# 读取现有配置
cfg = {}
if os.path.exists(config_path):
    with open(config_path) as f:
        try:
            cfg = json.load(f)
        except:
            cfg = {}

# 保留 meta/wizard 等已有字段
meta = cfg.get("meta", {})
wizard = cfg.get("wizard", {})

# --- Models ---
providers = {}

# Qwen (必选)
providers["qwen"] = {
    "baseUrl": "https://dashscope.aliyuncs.com/compatible-mode/v1",
    "api": "openai-completions",
    "models": [
        {"id": "qwen-plus", "name": "Qwen Plus", "reasoning": False,
         "input": ["text", "image"],
         "cost": {"input": 0.0008, "output": 0.002, "cacheRead": 0, "cacheWrite": 0},
         "contextWindow": 131072, "maxTokens": 8192},
        {"id": "qwen-turbo", "name": "Qwen Turbo", "reasoning": False,
         "input": ["text"],
         "cost": {"input": 0.0003, "output": 0.0006, "cacheRead": 0, "cacheWrite": 0},
         "contextWindow": 131072, "maxTokens": 8192},
        {"id": "qwen-max", "name": "Qwen Max", "reasoning": False,
         "input": ["text", "image"],
         "cost": {"input": 0.002, "output": 0.006, "cacheRead": 0, "cacheWrite": 0},
         "contextWindow": 32768, "maxTokens": 8192}
    ]
}

# DeepSeek (可选)
ds_key = """$DEEPSEEK_KEY"""
if ds_key.strip():
    providers["deepseek"] = {
        "baseUrl": "https://api.deepseek.com/v1",
        "api": "openai-completions",
        "models": [
            {"id": "deepseek-chat", "name": "DeepSeek Chat", "reasoning": False,
             "input": ["text"],
             "cost": {"input": 0.00014, "output": 0.00028, "cacheRead": 0, "cacheWrite": 0},
             "contextWindow": 65536, "maxTokens": 8192},
            {"id": "deepseek-reasoner", "name": "DeepSeek Reasoner", "reasoning": True,
             "input": ["text"],
             "cost": {"input": 0.00055, "output": 0.0022, "cacheRead": 0, "cacheWrite": 0},
             "contextWindow": 65536, "maxTokens": 8192}
        ]
    }

# Moonshot (可选)
ms_key = """$MOONSHOT_KEY"""
if ms_key.strip():
    providers["moonshot"] = {
        "baseUrl": "https://api.moonshot.cn/v1",
        "api": "openai-completions",
        "models": [
            {"id": "kimi-k2.5", "name": "Kimi K2.5", "reasoning": False,
             "input": ["text", "image"],
             "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
             "contextWindow": 131072, "maxTokens": 8192}
        ]
    }

# 确定各角色的默认模型
planner_model = "qwen/qwen-plus"
executor_model = "qwen/qwen-plus"
researcher_model = "qwen/qwen-turbo"
reviewer_model = "qwen/qwen-plus"

# 如果有 DeepSeek, planner 和 reviewer 用 DeepSeek
if ds_key.strip():
    planner_model = "deepseek/deepseek-chat"
    reviewer_model = "deepseek/deepseek-chat"

home = os.path.expanduser("~")

# 组装完整配置
full_cfg = {
    "meta": meta,
    "wizard": wizard,
    "models": {
        "mode": "merge",
        "providers": providers
    },
    "agents": {
        "defaults": {
            "model": {"primary": "qwen/qwen-plus"},
            "workspace": f"{home}/.openclaw/workspace",
            "compaction": {"mode": "safeguard"},
            "maxConcurrent": 4,
            "subagents": {"maxConcurrent": 8}
        },
        "list": [
            {
                "id": "planner",
                "name": "💡 Planner",
                "default": True,
                "workspace": f"{home}/.openclaw/workspace-planner",
                "model": {"primary": planner_model, "fallbacks": ["qwen/qwen-plus"]},
                "groupChat": {
                    "mentionPatterns": ["@planner", "planner", "规划"],
                    "historyLimit": 50
                }
            },
            {
                "id": "executor",
                "name": "⚡ Executor",
                "workspace": f"{home}/.openclaw/workspace-executor",
                "model": {"primary": executor_model, "fallbacks": ["qwen/qwen-turbo"]},
                "groupChat": {
                    "mentionPatterns": ["@executor", "executor", "执行"],
                    "historyLimit": 50
                }
            },
            {
                "id": "researcher",
                "name": "🔍 Researcher",
                "workspace": f"{home}/.openclaw/workspace-researcher",
                "model": {"primary": researcher_model, "fallbacks": ["qwen/qwen-plus"]},
                "groupChat": {
                    "mentionPatterns": ["@researcher", "researcher", "研究"],
                    "historyLimit": 50
                }
            },
            {
                "id": "reviewer",
                "name": "✅ Reviewer",
                "workspace": f"{home}/.openclaw/workspace-reviewer",
                "model": {"primary": reviewer_model, "fallbacks": ["qwen/qwen-plus"]},
                "groupChat": {
                    "mentionPatterns": ["@reviewer", "reviewer", "审查"],
                    "historyLimit": 50
                }
            }
        ]
    },
    "tools": {"profile": "coding"},
    "messages": {"ackReactionScope": "group-mentions"},
    "commands": {"native": "auto", "nativeSkills": "auto", "restart": True, "ownerDisplay": "raw"},
    "session": {"dmScope": "per-channel-peer"},
    "channels": {
        "telegram": {
            "enabled": True,
            "dmPolicy": "pairing",
            "botToken": "YOUR_TELEGRAM_BOT_TOKEN",
            "groupPolicy": "disabled",
            "streaming": "partial"
        }
    },
    # NOTE: groupPolicy 设为 disabled，因为还没配群。
    # 将来要开群聊时，改为:
    #   "groupPolicy": "allowlist",
    #   "groups": { "<group_id>": { "requireMention": true } }
    # 或者 "groupPolicy": "open" 允许所有群。
    "gateway": {
        "port": 18789,
        "mode": "local",
        "bind": "lan",
        "auth": {
            "mode": "token",
            "token": "$GW_TOKEN"
        },
        "tailscale": "off"
    }
}

with open(config_path, "w") as f:
    json.dump(full_cfg, f, indent=2, ensure_ascii=False)

print("openclaw.json 写入完成")
PYEOF

log "openclaw.json 配置完成"

# ============================================================
step "第 6 步: 写入 API Key"
# ============================================================

# 所有 agent 共享 auth-profiles
for agent_id in main planner executor researcher reviewer; do
  agent_dir="$HOME/.openclaw/agents/${agent_id}/agent"
  mkdir -p "$agent_dir"

  python3 << PYEOF
import json, os
auth_path = os.path.expanduser("~/.openclaw/agents/$agent_id/agent/auth-profiles.json")
profiles = {}
if os.path.exists(auth_path):
    with open(auth_path) as f:
        try: profiles = json.load(f)
        except: profiles = {}

profiles["qwen:default"] = {"key": """$QWEN_KEY"""}
ds = """$DEEPSEEK_KEY"""
if ds.strip():
    profiles["deepseek:default"] = {"key": ds}
ms = """$MOONSHOT_KEY"""
if ms.strip():
    profiles["moonshot:default"] = {"key": ms}

with open(auth_path, "w") as f:
    json.dump(profiles, f, indent=2)
os.chmod(auth_path, 0o600)
PYEOF
done

log "API Key 写入所有 agent"

# ============================================================
step "第 7 步: 创建 Agent Workspace 和 SOUL.md"
# ============================================================

# --- Default workspace ---
mkdir -p ~/.openclaw/workspace
cat > ~/.openclaw/workspace/SOUL.md << 'EOF'
# OpenClaw 中控
你是多角色 AI 系统的主控节点，可调度 Planner、Executor、Researcher、Reviewer 四个角色。
EOF

# --- Planner ---
mkdir -p ~/.openclaw/workspace-planner
cat > ~/.openclaw/workspace-planner/SOUL.md << 'EOF'
# 💡 Planner - 任务规划与调度

## 身份
你是 Planner（规划者）。接收任务后分析意图、拆解步骤、分配给合适的角色执行。

## 调度方式
- 信息收集 → `/subagents spawn researcher "任务描述"`
- 动作执行 → `/subagents spawn executor "任务描述"`
- 完成后 → `/subagents spawn reviewer "审查: ..."`

## 原则
- 你只做规划，不自己执行
- 简单任务 1-2 步，复杂任务最多 5 步
- 用中文回复用户
EOF

# --- Executor ---
mkdir -p ~/.openclaw/workspace-executor
cat > ~/.openclaw/workspace-executor/SOUL.md << 'EOF'
# ⚡ Executor - 任务执行

## 身份
你是 Executor（执行者）。负责运行脚本、调用 API、操作文件、写代码。

## 原则
- 先理解再动手
- 每步检查前置条件
- 遇错先修，修不了就报告
- 输出清晰的执行结果
- 用中文回复
EOF

# --- Researcher ---
mkdir -p ~/.openclaw/workspace-researcher
cat > ~/.openclaw/workspace-researcher/SOUL.md << 'EOF'
# 🔍 Researcher - 信息收集

## 身份
你是 Researcher（研究者）。负责搜索整理信息，产出结构化研究材料。

## 输出格式
- 核心发现（分点列出）
- 信息来源
- 可信度
- 未找到的信息
- 后续建议

## 原则
- 优先可靠来源
- 不编造，找不到就说
- 用中文回复
EOF

# --- Reviewer ---
mkdir -p ~/.openclaw/workspace-reviewer
cat > ~/.openclaw/workspace-reviewer/SOUL.md << 'EOF'
# ✅ Reviewer - 质量审查

## 身份
你是 Reviewer（审查者）。检查其他角色输出的质量，做最终汇总。

## 审查标准
- 完整性：所有要求是否满足
- 准确性：信息和执行结果是否正确
- 可读性：输出是否对用户友好

## 决策
- 评分 < 6 → 返工
- 评分 ≥ 8 → 通过
- 输出面向用户的最终结果，用中文
EOF

# 为每个 workspace 创建空 AGENTS.md
for ws in workspace workspace-planner workspace-executor workspace-researcher workspace-reviewer; do
  cat > ~/.openclaw/${ws}/AGENTS.md << 'EOF'
# Agent Guidelines
- Use Chinese for user-facing output
- Prefer simple solutions
- Verify results before reporting
EOF
done

log "4 个 Agent workspace + SOUL.md 创建完成"

# ============================================================
step "第 8 步: 安全加固"
# ============================================================

chmod 700 ~/.openclaw
chmod 600 ~/.openclaw/openclaw.json
chmod 700 ~/.openclaw/credentials 2>/dev/null || true

log "文件权限已收紧"

# ============================================================
step "第 9 步: 设置环境变量"
# ============================================================

# Gateway token
if ! grep -q "OPENCLAW_GATEWAY_TOKEN" ~/.bashrc 2>/dev/null; then
  echo "" >> ~/.bashrc
  echo "# OpenClaw" >> ~/.bashrc
  echo "export OPENCLAW_GATEWAY_TOKEN=\"$GW_TOKEN\"" >> ~/.bashrc
fi
export OPENCLAW_GATEWAY_TOKEN="$GW_TOKEN"

log "环境变量已写入 ~/.bashrc"

# ============================================================
step "第 10 步: 启动 Gateway"
# ============================================================

# 策略: 先尝试 openclaw gateway install + start (systemd 方式)
# 如果失败，回退到手动创建 systemd unit + openclaw gateway run
# 最终用端口检查确认是否真正启动

GATEWAY_UP=false

# --- 尝试方式 1: 官方 install + start ---
log "尝试 openclaw gateway install..."
if openclaw gateway install 2>&1; then
  log "gateway install 成功，尝试 start..."
  if openclaw gateway start 2>&1; then
    sleep 8
    if ss -tlnp | grep -q 18789; then
      GATEWAY_UP=true
      log "Gateway 通过 openclaw gateway start 启动成功 ✓"
    else
      warn "start 命令执行了但端口 18789 未监听，可能还在启动中..."
      sleep 10
      if ss -tlnp | grep -q 18789; then
        GATEWAY_UP=true
        log "Gateway 延迟启动成功 ✓"
      fi
    fi
  else
    warn "openclaw gateway start 失败"
  fi
else
  warn "openclaw gateway install 失败"
fi

# --- 如果方式 1 失败，尝试方式 2: 手动 systemd unit ---
if [ "$GATEWAY_UP" = false ]; then
  warn "官方 install/start 未成功，回退到手动 systemd unit"

  OPENCLAW_BIN=$(which openclaw)

  cat > /etc/systemd/system/openclaw-gateway.service << SVCEOF
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
User=root
Environment=OPENCLAW_GATEWAY_TOKEN=$GW_TOKEN
ExecStart=$OPENCLAW_BIN gateway run --port 18789 --bind lan --auth token --token $GW_TOKEN
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable openclaw-gateway
  systemctl start openclaw-gateway

  sleep 8

  if ss -tlnp | grep -q 18789; then
    GATEWAY_UP=true
    log "Gateway 通过手动 systemd unit 启动成功 ✓"
  else
    warn "手动 systemd unit 也未能启动 Gateway"
  fi
fi

# --- 最终验证 ---
echo ""
if [ "$GATEWAY_UP" = true ]; then
  log "Gateway 端口 18789 已监听"
  ss -tlnp | grep 18789
  echo ""
  openclaw gateway status 2>&1 || true
else
  err "Gateway 未能启动。请手动排查：
  1. 查看日志: journalctl -u openclaw-gateway -n 50 --no-pager
  2. 或手动前台运行: openclaw gateway run --port 18789 --bind lan --auth token --token $GW_TOKEN
  3. 确认端口: ss -tlnp | grep 18789"
fi

# ============================================================
step "部署完成！"
# ============================================================

echo ""
echo "  🎉 OpenClaw 四角色中控已部署到香港 ECS"
echo ""
echo "  ┌───────────────────────────────────────────┐"
echo "  │ Gateway Token: $GW_TOKEN │"
echo "  │ 地址: http://YOUR_HK_IP:18789         │"
echo "  │ Bot: @YOUR_BOT                            │"
echo "  └───────────────────────────────────────────┘"
echo ""
echo "  Agent 列表:"
echo "    💡 planner    (qwen/qwen-plus)   → 任务规划"
echo "    ⚡ executor   (qwen/qwen-plus)   → 执行操作"
echo "    🔍 researcher (qwen/qwen-turbo)  → 信息收集"
echo "    ✅ reviewer   (qwen/qwen-plus)   → 质量审查"
echo ""
echo "  下一步:"
echo "    1. Telegram 给 @YOUR_BOT 发消息"
echo "    2. 服务器上执行 openclaw pairing approve telegram <配对码>"
echo "    3. 试试: '帮我分析一下这台服务器的安全配置'"
echo ""
echo "  常用命令:"
echo "    openclaw gateway status        # 状态"
echo "    openclaw gateway restart       # 重启"
echo "    openclaw agents list           # Agent 列表"
echo "    openclaw agents list --bindings # 路由绑定"
echo "    openclaw doctor                # 诊断"
echo "    openclaw logs --follow         # 实时日志"
echo ""
echo "  后续添加模型: bash /tmp/add-model.sh"
echo ""

# 保存 add-model.sh 到 /tmp 方便后续使用
cp "$(dirname "$0")/add-model.sh" /tmp/add-model.sh 2>/dev/null || true
