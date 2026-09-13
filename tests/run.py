#!/usr/bin/env python3
"""Регрессионные проверки в новых схемах, полностью отменяемые ROLLBACK."""

from pathlib import Path
import re
import subprocess
import sys
import uuid


root = Path(__file__).resolve().parents[1]
if sys.argv[1:] not in ([], ["--live-sources"]):
    raise SystemExit("Usage: python tests/run.py [--live-sources]")
scenario = "live-sources.sql" if sys.argv[1:] else "scenarios.sql"
schemas = ("dwh", "source1", "source2", "source3", "external_source")
prefix = "mephi_test_" + uuid.uuid4().hex[:12]


def isolated(text):
    for schema in schemas:
        text = re.sub(rf"\b{schema}\.", f"{prefix}_{schema}.", text)
    return text


def script(name, cleanup=True):
    content = (root / "sql" / name).read_text()
    # Одна внешняя транзакция вместо отдельных транзакций рабочих скриптов.
    content = re.sub(r"(?m)^(?:BEGIN;|COMMIT;)\n", "", content)
    if cleanup:
        tables = re.findall(r"CREATE TEMP TABLE ([a-z_]+)", content)
        content += "\n" + "\n".join(f"DROP TABLE pg_temp.{t};" for t in tables)
    return content


statements = ["BEGIN;", "SET LOCAL TIME ZONE 'Europe/Moscow';",
              "SET LOCAL lock_timeout = '10s';", "SET LOCAL statement_timeout = '120s';"]
statements.extend(f"CREATE SCHEMA {prefix}_{s};" for s in schemas)
statements.append((root / "tests/bootstrap.sql").read_text())
for line in (root / "tests" / scenario).read_text().splitlines():
    if line.startswith("-- RUN: "):
        statements.append(script(line.removeprefix("-- RUN: ")))
    elif line.startswith("-- EXPECT-ERROR: "):
        name, message = line.removeprefix("-- EXPECT-ERROR: ").split(" | ", 1)
        statements.append("SELECT pg_temp.expect_error($attempt$" + script(name, cleanup=False)
                          + "$attempt$, '" + message.replace("'", "''") + "');")
    else:
        statements.append(line)
statements.append("ROLLBACK;")
sql = isolated("\n".join(statements))
result = subprocess.run(
    [sys.executable, str(root / "scripts/psql.py"), "-P", "pager=off", "-f", "-"],
    input=sql, text=True,
)
if result.returncode == 0:
    print("Regression scenarios passed; test schemas and data rolled back.")
raise SystemExit(result.returncode)
