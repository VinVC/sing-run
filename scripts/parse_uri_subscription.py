#!/usr/bin/env python3
"""Parse vmess:// / vless:// subscription text into Clash-like proxies YAML."""

from __future__ import annotations

import base64
import json
import sys
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse


def _maybe_decode_subscription(raw: str) -> str:
    stripped = raw.strip()
    try:
        decoded = base64.b64decode(stripped).decode("utf-8", errors="replace")
    except Exception:
        return stripped
    if "vmess://" in decoded or "vless://" in decoded:
        return decoded
    return stripped


def _write_vmess(out, line: str) -> bool:
    try:
        node = json.loads(
            base64.b64decode(line[len("vmess://") :] + "==").decode(
                "utf-8", errors="replace"
            )
        )
    except Exception:
        return False

    name = str(node.get("ps", "Unknown"))
    server = str(node.get("add", ""))
    port = node.get("port", "")
    uuid = str(node.get("id", ""))
    if not server or not port or not uuid:
        return False

    safe_name = name.replace('"', '\\"')
    out.write(f'  - name: "{safe_name}"\n')
    out.write("    type: vmess\n")
    out.write(f"    server: {server}\n")
    out.write(f"    port: {port}\n")
    out.write(f"    uuid: {uuid}\n")
    out.write(f"    alterId: {node.get('aid', 0)}\n")
    out.write("    cipher: auto\n")
    out.write(f"    network: {node.get('net', 'tcp')}\n")
    tls_val = str(node.get("tls", ""))
    if tls_val and tls_val.lower() not in ("", "null", "false", "none", "0"):
        out.write("    tls: true\n")
    return True


def _write_vless(out, line: str) -> bool:
    parsed = urlparse(line)
    if not parsed.hostname or not parsed.port or not parsed.username:
        return False

    qs = {key: values[0] for key, values in parse_qs(parsed.query).items()}
    name = unquote(parsed.fragment) if parsed.fragment else "Unknown"
    safe_name = name.replace('"', '\\"')
    network = qs.get("type", "tcp") or "tcp"
    security = qs.get("security", "none") or "none"

    out.write(f'  - name: "{safe_name}"\n')
    out.write("    type: vless\n")
    out.write(f"    server: {parsed.hostname}\n")
    out.write(f"    port: {parsed.port}\n")
    out.write(f"    uuid: {parsed.username}\n")
    out.write(f"    network: {network}\n")
    if qs.get("flow"):
        out.write(f"    flow: {qs['flow']}\n")
    if security in ("tls", "reality"):
        out.write("    tls: true\n")
    if qs.get("sni"):
        out.write(f"    servername: {qs['sni']}\n")
    if qs.get("fp"):
        out.write(f"    client-fingerprint: {qs['fp']}\n")
    if security == "reality":
        # Quote Reality values: an all-digit short-id would otherwise become a
        # YAML number, and sing-box requires a string.
        out.write("    reality-opts:\n")
        out.write(f'      public-key: "{qs.get("pbk", "")}"\n')
        out.write(f'      short-id: "{qs.get("sid", "")}"\n')
    return True


def main() -> int:
    if len(sys.argv) != 3:
        print(
            f"用法: {sys.argv[0]} <raw-subscription> <output-yaml>",
            file=sys.stderr,
        )
        return 2

    original = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
    raw = _maybe_decode_subscription(original)
    if raw != original.strip() and ("vmess://" in raw or "vless://" in raw):
        print("已解码 base64 内容", file=sys.stderr)

    lines = [line.strip() for line in raw.splitlines() if line.strip()]
    vmess_lines = [line for line in lines if line.startswith("vmess://")]
    vless_lines = [line for line in lines if line.startswith("vless://")]
    if not vmess_lines and not vless_lines:
        print("错误: 未找到 vmess:// 或 vless:// 链接", file=sys.stderr)
        return 1

    count = 0
    errors = 0
    with Path(sys.argv[2]).open("w", encoding="utf-8") as out:
        out.write("proxies:\n")
        for line in vmess_lines:
            if _write_vmess(out, line):
                count += 1
            else:
                errors += 1
        for line in vless_lines:
            if _write_vless(out, line):
                count += 1
            else:
                errors += 1

    if errors > 0:
        print(f"跳过 {errors} 个无效链接", file=sys.stderr)
    print(f"解析到 {count} 个节点", file=sys.stderr)
    return 0 if count > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
