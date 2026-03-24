# Plan B: Official OpenClaw Dual-Node Collaborative System

[中文](README.md) | [English](README.en.md)

> Status: deployed and validated on March 16, 2026.

This project documents a production-tested dual-node OpenClaw deployment using a Hong Kong controller and an AWS Tokyo worker. It combines Qwen and DeepSeek roles in an adversarial collaboration workflow over Telegram.

This repository is packaged as a standalone GitHub project. It does not include real API keys, bot tokens, tunnel secrets, or server private keys. Sensitive values are represented with placeholders or environment variables.

## Highlights

- Based on the official OpenClaw workflow
- Production-tested dual-node deployment pattern
- HK controller handles planning, review, and Telegram interaction
- AWS worker handles overseas research and alternative drafting
- Includes deployment scripts, SOUL templates, config examples, and cross-node scheduling helpers

## System Architecture

```text
User on Telegram
    -> HK Controller (Qwen)
       -> Planner
       -> Drafter-A
       -> Researcher
       -> Reviewer-HK
    -> AWS Worker (DeepSeek)
       -> Drafter-B
       -> Critic
       -> Overseas-Researcher
```

## Collaboration Flow

```text
User request
    -> Planner analyzes the task
    -> Drafter-A produces solution A
    -> Drafter-B produces solution B
    -> Critic reviews one branch
    -> Reviewer-HK reviews the other branch
    -> Planner merges the final answer
```

## Prerequisites

- Two Ubuntu 24.04 servers: one in HK and one in AWS
- Qwen API key
- DeepSeek API key
- Telegram bot token
- Optional Cloudflare account and domain for fallback connectivity

## Deployment Steps

### 1. Deploy the HK controller

```bash
scp deploy-hk.sh root@HK_IP:/tmp/
ssh root@HK_IP
bash /tmp/deploy-hk.sh
```

During onboarding:

- Model -> Skip for now
- Channel -> Select Telegram and provide the bot token
- Skills -> No
- Hatch -> Do this later

Then update the role configuration manually using `config-examples/hk-openclaw.json`.

### 2. Verify the four HK roles

Test commands in Telegram:

1. Ask `drafter-a` to write a Python hello world.
2. Ask `researcher` to look up new Node.js 22 features.
3. Ask `reviewer-hk` to review a statement such as "TCP uses four-way handshakes".

### 3. Deploy the AWS worker

```bash
scp deploy-aws.sh ubuntu@AWS_IP:/tmp/
ssh ubuntu@AWS_IP
bash /tmp/deploy-aws.sh
```

Skip onboarding configuration again. The script will prepare the DeepSeek provider and the three AWS-side roles.

### 4. Establish connectivity

Primary option: SSH tunnel with `autossh`.

Fallback option: Cloudflare Tunnel.

Direct-connect is also possible if you choose to expose the AWS gateway port.

### 5. Verify cross-server communication

```bash
curl -s -X POST http://127.0.0.1:28789/hooks/agent \
  -H "Authorization: Bearer YOUR_AWS_HOOKS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"message": "hello test", "agentId": "drafter-b", "wakeMode": "now"}'
```

If the response is `{"ok":true,"runId":"..."}`, the webhook path is working.

### 6. Deploy helper scripts

- Put `scripts/aws-task.sh` on the HK machine, for example under `/root/scripts/`
- Put `scripts/read-result.py` on the AWS machine

Then test:

```bash
/root/scripts/aws-task.sh drafter-b "Introduce DeepSeek V3 in one sentence"
```

### 7. Update the Planner SOUL

Replace `~/.openclaw/workspace-planner/SOUL.md` with the content of `soul-templates/planner.md`, then restart the gateway.

## Repository Layout

| File | Purpose |
|------|---------|
| `deploy-hk.sh` | One-time deployment script for the HK controller |
| `deploy-aws.sh` | One-time deployment script for the AWS worker |
| `scripts/aws-task.sh` | HK to AWS task dispatch helper |
| `scripts/read-result.py` | Reads agent output from JSONL files on AWS |
| `soul-templates/*.md` | SOUL templates for each agent |
| `config-examples/*.json` | Reference configuration files |

## Communication Layers

| Layer | Method | Notes |
|------|--------|-------|
| Primary | SSH tunnel with `autossh` | Encrypted, no open public port, auto-reconnect |
| Fallback | Cloudflare Tunnel | Useful when the SSH path is unavailable |
| Direct | Public AWS port | Lowest latency, but requires security group exposure |

`scripts/aws-task.sh` is designed with automatic failover from SSH tunnel to Cloudflare Tunnel.

## Key Tokens

After deployment, record these values separately:

| Token | Purpose |
|------|---------|
| HK Gateway Token | HK gateway authentication |
| HK Hooks Token | Callback authentication for HK hooks |
| AWS Gateway Token | AWS gateway authentication |
| AWS Hooks Token | HK to AWS task submission |

On the same server, the gateway token and hooks token must be different.

## Known Limitations

1. Subagent model routing may ignore per-agent model settings and reuse the parent model.
2. A successful webhook response only confirms task acceptance, not task completion.
3. SOUL instructions are helpful but not fully enforceable, so wrapper scripts are more reliable for result return paths.

## Related Documents

- Deployment lessons: [LESSONS.md](LESSONS.md)
