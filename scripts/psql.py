#!/usr/bin/env python3
"""Запуск psql с параметрами из pass и временным файлом пароля."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    prefix = os.environ.get("MEPHI_PASS_PREFIX", "MEPhI/semester-3/data-warehouse")
    params = {}
    for key in ("host", "port", "dbname", "user", "password"):
        result = subprocess.run(
            ["pass", "show", f"{prefix}/{key}"], capture_output=True, text=True
        )
        if result.returncode:
            print(f"Не удалось прочитать поле {key} из pass.", file=sys.stderr)
            return 1
        value = result.stdout.removesuffix("\n")
        if not value or "\n" in value or "\r" in value:
            print(f"Поле {key} должно содержать одну непустую строку.", file=sys.stderr)
            return 1
        params[key] = value

    certificate = Path(os.environ.get(
        "PGSSLROOTCERT", str(Path.home() / ".postgresql/yandex-cloud.crt")
    )).expanduser()
    if not certificate.is_file():
        print("Не найден корневой сертификат. Укажите PGSSLROOTCERT.", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="mephi-pgpass-") as directory:
        password_file = Path(directory) / "pgpass"
        # Формат .pgpass требует экранировать обратную косую черту и двоеточие.
        fields = [params[key].replace("\\", "\\\\").replace(":", "\\:")
                  for key in ("host", "port", "dbname", "user", "password")]
        fd = os.open(password_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(":".join(fields) + "\n")

        environment = os.environ.copy()
        environment.pop("PGPASSWORD", None)
        environment.update(
            PGHOST=params["host"], PGPORT=params["port"],
            PGDATABASE=params["dbname"], PGUSER=params["user"],
            PGPASSFILE=str(password_file), PGSSLMODE="verify-full",
            PGSSLROOTCERT=str(certificate), PGCONNECT_TIMEOUT="10",
            PGAPPNAME="mephi-dwh-project",
        )
        return subprocess.run(
            ["psql", "-X", "--no-password", "--set=ON_ERROR_STOP=1", *sys.argv[1:]],
            env=environment,
        ).returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FileNotFoundError:
        print("Для запуска необходимы установленные pass и psql.", file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        raise SystemExit(130)
