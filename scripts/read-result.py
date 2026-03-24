#!/usr/bin/env python3
"""
read-result.py — 从 OpenClaw session JSONL 文件中提取最新的 assistant 输出

部署位置: AWS 服务器 ~/read-result.py
调用方式: python3 ~/read-result.py <agentId>
示例:     python3 ~/read-result.py drafter-b

OpenClaw JSONL 格式:
  {"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"..."}]}}
"""
import json
import glob
import os
import sys

agent_id = sys.argv[1] if len(sys.argv) > 1 else "drafter-b"
pattern = os.path.expanduser(f"~/.openclaw/agents/{agent_id}/sessions/*.jsonl")
files = glob.glob(pattern)

if not files:
    print(f"NO_FILES: {pattern}")
    sys.exit()

# 取最新的 JSONL 文件
latest = max(files, key=os.path.getmtime)
results = []

with open(latest) as f:
    for line in f:
        try:
            obj = json.loads(line)
            # OpenClaw 嵌套格式: {"type":"message","message":{"role":"...","content":[...]}}
            if obj.get("type") == "message":
                msg = obj.get("message", {})
                if msg.get("role") == "assistant":
                    content = msg.get("content", "")
                    if isinstance(content, list):
                        for c in content:
                            if isinstance(c, dict) and c.get("type") == "text":
                                results.append(c["text"])
                    elif isinstance(content, str) and content.strip():
                        results.append(content)
        except Exception:
            pass

if results:
    # 输出最后一条 assistant 消息（通常是最终结果）
    print(results[-1])
else:
    print("NO_RESULT")
