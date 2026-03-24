#!/bin/bash
# ============================================================
# aws-task.sh — HK 中控调度 AWS worker 的封装脚本
# 三步流程: 发送任务 → 等待执行 → SSH 读取结果
#
# 用法: aws-task.sh <agentId> "<任务描述>" [等待秒数]
# 示例:
#   aws-task.sh drafter-b "分析 Python vs Go 微服务"
#   aws-task.sh critic "审查以下方案: ..."
#   aws-task.sh overseas-researcher "搜索 DeepSeek V3 最新论文"
#   aws-task.sh drafter-b "写一段排序算法" 60  # 等60秒
# ============================================================

AGENT_ID="$1"
MESSAGE="$2"
WAIT="${3:-45}"

if [ -z "$AGENT_ID" ] || [ -z "$MESSAGE" ]; then
  echo "用法: aws-task.sh <agentId> <任务描述> [等待秒数]"
  echo "可用: drafter-b, critic, overseas-researcher"
  exit 1
fi

# ---- 配置 (按实际环境修改) ----
HOOKS_TOKEN="YOUR_AWS_HOOKS_TOKEN"
AWS_KEY="/root/.ssh/aws-key.pem"
AWS_HOST="ubuntu@YOUR_AWS_IP"
CF_DOMAIN="https://YOUR_CF_TUNNEL_DOMAIN"
SSH="ssh -i $AWS_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 $AWS_HOST"

# ---- 第一步: 发送任务 (主用 SSH 隧道, 备选 Cloudflare) ----
echo "[aws-task] 发送任务给 $AGENT_ID..."
RESULT=$(curl -s --connect-timeout 5 -X POST http://127.0.0.1:28789/hooks/agent \
  -H "Authorization: Bearer $HOOKS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"message\": \"$MESSAGE\", \"agentId\": \"$AGENT_ID\", \"wakeMode\": \"now\"}" 2>/dev/null)

if ! echo "$RESULT" | grep -q '"ok":true'; then
  echo "[aws-task] SSH隧道失败，切Cloudflare..."
  RESULT=$(curl -s --connect-timeout 10 -X POST ${CF_DOMAIN}/hooks/agent \
    -H "Authorization: Bearer $HOOKS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"message\": \"$MESSAGE\", \"agentId\": \"$AGENT_ID\", \"wakeMode\": \"now\"}" 2>/dev/null)
fi

if ! echo "$RESULT" | grep -q '"ok":true'; then
  echo "[aws-task] 发送失败: $RESULT"
  exit 1
fi

echo "[aws-task] 已接收，等待 ${WAIT}s..."
sleep "$WAIT"

# ---- 第二步: SSH 读取结果 ----
echo "[aws-task] 读取结果..."
OUTPUT=$($SSH "python3 ~/read-result.py $AGENT_ID" 2>/dev/null)

if [ -z "$OUTPUT" ] || [ "$OUTPUT" = "NO_RESULT" ]; then
  echo "[aws-task] 首次无结果，再等30s..."
  sleep 30
  OUTPUT=$($SSH "python3 ~/read-result.py $AGENT_ID" 2>/dev/null)
fi

echo "=== $AGENT_ID 输出 ==="
echo "$OUTPUT"
