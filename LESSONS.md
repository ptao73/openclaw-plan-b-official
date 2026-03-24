# 踩坑记录 — OpenClaw 双节点部署

部署过程中遇到的所有坑和解决方案，按重要性排序。

## 🔴 致命级

### 1. Provider 命名映射问题

**现象**：配置 provider 名为 `qwen`，但 `openclaw onboard` 过程中内部映射成了 `qwen-portal`，导致 auth 失败。

**错误信息**：
```
No API key found for provider "qwen". Auth store: ~/.openclaw/agents/planner/agent/auth-profiles.json
```

**原因**：OpenClaw 在 `onboard` 时自动创建 provider，内部会重命名（`qwen` → `qwen-portal`，`deepseek` → `deepseek-portal`）。但 `agents.list` 里的 model 引用还是旧名。

**解决方案**：
1. `onboard` 时 model 选 "Skip for now"
2. 手动通过 `openclaw configure` 添加 provider
3. 用 `openclaw agents list` 确认实际 provider 名
4. 在 `agents.list` 里用 **实际名称**（如 `custom-dashscope-aliyuncs-com/qwen-plus`）

### 2. hooks.token 不能等于 gateway.auth.token

**现象**：Gateway 反复 crash，日志显示配置无效。

**错误信息**：
```
Gateway failed to start: Error: Invalid config: hooks.token must not match gateway auth token
```

**原因**：OpenClaw 强制要求 hooks token 和 gateway auth token 不同，防止混淆。

**解决方案**：用 `openssl rand -hex 24` 分别生成两个不同的 token。

### 3. API Key 在 Heredoc 中不展开

**现象**：脚本部署后 DeepSeek 认证失败。

**原因**：Python heredoc 用了单引号 `<< 'PYEOF'`，导致 `${DEEPSEEK_API_KEY}` 作为字面量写入配置，不是实际的 key。

**解决方案**：在 Python 代码里用 `os.environ["DEEPSEEK_API_KEY"]` 读取环境变量。

## 🟡 重要级

### 4. Subagent 模型路由 Bug

**现象**：给 subagent 配了不同模型，但实际运行时 subagent 总是用 parent 的模型。

**相关 Issue**：#10963, #6671, #10883, #17330

**影响**：无法实现跨模型 subagent（比如 planner 用 Qwen、reviewer 用 Kimi）。

**当前绕过**：所有 subagent 先用同一个 provider 的模型，等官方修复后再切换。

### 5. Webhook 是单向的

**现象**：通过 webhook 给 AWS 发任务，返回 `ok:true`，但结果不会自动回传。

**原因**：`ok:true` 只表示任务已接收，不是完成。OpenClaw webhook 不支持同步等待结果。

**解决方案**：封装 `aws-task.sh` 脚本，三步流程：
1. curl 发任务 → 2. sleep 等待 → 3. SSH 读取 JSONL 结果

### 6. SOUL.md 中写 curl 命令不可靠

**现象**：在 SOUL.md 里写"完成后用 curl 回传结果"，agent 大概率不执行。

**原因**：LLM 不是脚本执行器，SOUL.md 里的指令是建议不是强制。

**解决方案**：把复杂操作封装成 shell 脚本，SOUL.md 里只写 `/root/scripts/aws-task.sh <agentId> "任务"`。

### 7. Webhook 正确的 payload 格式

**现象**：用 `{"message": "..."}` 发到自定义 mapping path 报错 "hook mapping requires message"。

**正确方式**：不用自定义 mapping，直接用内置 `/hooks/agent` 端点：
```bash
curl -X POST http://host:port/hooks/agent \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"message": "任务", "agentId": "角色名", "wakeMode": "now"}'
```

### 8. JSONL Session 文件格式

**现象**：读取 session JSONL 时用 `obj.get('role')` 找不到 assistant 消息。

**原因**：OpenClaw JSONL 格式是嵌套的：
```json
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"..."}]}}
```
不是顶层 `{"role":"assistant"}`。

**解决方案**：先检查 `obj.get('type') == 'message'`，再取 `obj['message']['role']`。

## 🔵 注意级

### 9. SSH Heredoc + Markdown 代码块冲突

**现象**：通过 SSH 远程执行 heredoc 写文件，如果内容包含 markdown 代码块（`` ``` ``），shell 解析混乱。

**解决方案**：先在本地写好文件，用 `scp` 传到远程。

### 10. 阿里云 Workbench 粘贴会带入 shell 提示符

**现象**：通过阿里云 Workbench 粘贴密钥内容，开头多了 `(` 结尾多了 `% )`。

**解决方案**：粘贴前确认只选中了密钥内容，或用 `nano` 编辑器手动粘贴。

### 11. openclaw@latest 不适合部署脚本

**原因**：OpenClaw 有过版本回归，latest 可能拉到不稳定版本。

**解决方案**：固定版本号 `openclaw@2026.3.13`。

### 12. allowAgents 的位置

**正确**：`allowAgents` 放在 **发起方（parent）** 的 agent 配置里。
**错误**：放在 defaults 里或 child agent 配置里。

```json
{
  "id": "planner",
  "subagents": {
    "allowAgents": ["drafter-a", "researcher", "reviewer-hk"]
  }
}
```
