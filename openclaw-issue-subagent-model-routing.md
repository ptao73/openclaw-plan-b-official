Title: Subagents ignore configured model routing and fall back to primary/default model

---

## Summary

Subagents consistently ignore their intended model configuration and fall back to the primary/default model of the parent agent.

Multi-agent role separation works at the persona/workspace level, but not at the model-routing level.

## Expected behavior

Subagents should use the model configured for them, via:

- `agents.list[].model.primary`
- `agents.defaults.subagents.model`
- or an explicit model parameter during `sessions_spawn`

## Actual behavior

The spawned subagent uses the primary/default model of the parent agent instead.

Gateway log shows:

```
model not allowed: custom-dashscope-aliyuncs-com/qwen-plus
```

And `model-fallback/decision` log entry confirms:

```json
{
  "requestedProvider": "qwen-portal",
  "requestedModel": "qwen-plus",
  "candidateProvider": "qwen-portal",
  "candidateModel": "qwen-plus",
  "reason": "auth",
  "status": 401
}
```

This occurs even when:
- The agent's `auth-profiles.json` contains valid keys for the configured provider
- `openclaw agents list` correctly shows each agent with its intended model

## Minimal config

```json
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "custom-dashscope-aliyuncs-com/qwen-plus"
      },
      "subagents": {
        "maxConcurrent": 8,
        "model": "custom-dashscope-aliyuncs-com/qwen-turbo"
      }
    },
    "list": [
      {
        "id": "planner",
        "default": true,
        "model": { "primary": "custom-dashscope-aliyuncs-com/qwen-plus" },
        "subagents": {
          "allowAgents": ["executor", "researcher", "reviewer"]
        }
      },
      {
        "id": "reviewer",
        "model": { "primary": "moonshot/kimi-k2.5" }
      }
    ]
  }
}
```

Intent: planner uses Qwen-Plus, reviewer uses Kimi K2.5.

Result: reviewer runs on the planner's default model instead of its own.

## Steps to reproduce

1. Define multiple agents in `agents.list` with different `model.primary` values
2. Set `subagents.allowAgents` on the spawning agent
3. Ensure `auth-profiles.json` exists for each agent with valid keys
4. Spawn a subagent via `sessions_spawn` or `/subagents spawn`
5. Observe that the spawned subagent uses the default/primary model, not its configured one

## Related issues

This appears related to several existing reports:

- #10963 — subagents ignore `agents.defaults.subagents.model.primary`
- #6671 — sub-agent model override not working for custom providers
- #10883 — subagent model configuration not enforced
- #17330 — custom agents in `agents.list` not recognized, only main agent available

## Suggestions

A few improvements would help clarify and resolve this:

1. **Document the exact precedence order** for subagent model resolution, e.g.:
   1. spawn-time explicit `model` parameter
   2. `agents.list[agentId].model`
   3. `agents.defaults.subagents.model`
   4. `agents.defaults.model`

2. **Log the actual resolved provider/model** when a subagent starts, so users can verify routing without guessing

3. **Clarify whether `agents.defaults.subagents.model` is currently functional** — multiple issues suggest it is not

4. **Clarify `sessions_spawn(agentId=...)` limitations** — it's unclear when `agentId` is respected vs silently ignored

## Environment

- **OpenClaw version:** 2026.3.13 (61d171a)
- **Install method:** `npm install -g openclaw@latest`
- **OS:** Ubuntu 24.04 (Alibaba Cloud ECS, Hong Kong)
- **Node:** v22.x
- **Providers tested:** Qwen (DashScope compatible mode), Moonshot (Kimi K2.5)
- **Config style:** `agents.list` with 4 agents + `subagents.allowAgents`

I'm happy to help test a fix or clarify the reproduction steps if needed.
