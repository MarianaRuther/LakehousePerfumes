#!/usr/bin/env python3
"""PreToolUse guard rail: blocks DROP, TRUNCATE, and DELETE-without-WHERE.

Covers two paths:
  - Bash calls that execute a .sql file (scripts/run_sql.py, the
    `databricks ... aitools tools query` CLI it wraps, or similar SQL
    runners) - the referenced .sql file's content is checked, plus any
    inline SQL passed as a quoted argument or heredoc.
  - Edit/Write to a .sql file - the content being introduced is checked.

Reads the PreToolUse hook JSON from stdin and, on a violation, prints a
"deny" hookSpecificOutput so the tool call never runs.
"""
import json
import os
import re
import sys

KEYWORD_RE = re.compile(r"^\s*(DROP|TRUNCATE|DELETE)\b", re.IGNORECASE)
WHERE_RE = re.compile(r"\bWHERE\b", re.IGNORECASE)
SQL_FILE_RE = re.compile(r"([A-Za-z0-9_./\\-]+\.sql)\b", re.IGNORECASE)
EXEC_INDICATOR_RE = re.compile(
    r"run_sql\.py|aitools\s+tools\s+query|\bpsql\b|\bsqlite3\b|\bmysql\b",
    re.IGNORECASE,
)


def strip_comments(sql: str) -> str:
    sql = re.sub(r"--[^\n]*", "", sql)
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.DOTALL)
    return sql


def split_statements(sql: str):
    stmts, atual, i, aspas = [], [], 0, False
    while i < len(sql):
        c = sql[i]
        if c == "'":
            aspas = not aspas
        if c == ";" and not aspas:
            stmts.append("".join(atual))
            atual = []
            i += 1
            continue
        atual.append(c)
        i += 1
    stmts.append("".join(atual))
    return [s for s in stmts if s.strip()]


def find_violation(sql_text: str):
    if not sql_text:
        return None
    cleaned = strip_comments(sql_text)
    for stmt in split_statements(cleaned):
        m = KEYWORD_RE.match(stmt)
        if not m:
            continue
        kw = m.group(1).upper()
        trecho = stmt.strip()[:120]
        if kw in ("DROP", "TRUNCATE"):
            return f"{kw} bloqueado pelo guard rail: {trecho}"
        if kw == "DELETE" and not WHERE_RE.search(stmt):
            return f"DELETE sem WHERE bloqueado pelo guard rail: {trecho}"
    return None


def extract_quoted_segments(command: str):
    segments = []
    for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', command):
        segments.append(m.group(1))
    for m in re.finditer(r"'([^']*)'", command):
        segments.append(m.group(1))
    return segments


def extract_heredocs(command: str):
    segments = []
    for m in re.finditer(r"<<[-~]?\s*['\"]?(\w+)['\"]?\n(.*?)\n\1\b", command, re.DOTALL):
        segments.append(m.group(2))
    return segments


def read_if_exists(path: str):
    for candidate in (path, os.path.join(os.getcwd(), path)):
        if os.path.isfile(candidate):
            try:
                with open(candidate, encoding="utf-8", errors="ignore") as f:
                    return f.read()
            except OSError:
                return None
    return None


def deny(reason: str):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    tool_name = payload.get("tool_name", "")
    tool_input = payload.get("tool_input", {}) or {}
    texts_to_check = []

    if tool_name == "Bash":
        command = tool_input.get("command", "") or ""
        if EXEC_INDICATOR_RE.search(command):
            for match in SQL_FILE_RE.finditer(command):
                content = read_if_exists(match.group(1))
                if content:
                    texts_to_check.append(content)
            texts_to_check.extend(extract_quoted_segments(command))
            texts_to_check.extend(extract_heredocs(command))

    elif tool_name in ("Edit", "Write"):
        file_path = tool_input.get("file_path", "") or ""
        if file_path.lower().endswith(".sql"):
            if tool_name == "Write":
                texts_to_check.append(tool_input.get("content", "") or "")
            else:
                texts_to_check.append(tool_input.get("new_string", "") or "")

    for text in texts_to_check:
        violation = find_violation(text)
        if violation:
            deny(violation)

    sys.exit(0)


if __name__ == "__main__":
    main()
