#!/usr/bin/env python3
"""Validación estática del repositorio de plataforma, sin red ni credenciales.

- JSON y YAML bien formados (los YAML con varios documentos se leen completos);
- enlaces relativos de Markdown que apuntan a archivos existentes.

Requiere pyyaml. Ejecutar desde la raíz: python scripts/validate_repo.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SKIP = {".git", ".terraform", "components", "node_modules", "backend-base"}
LINK = re.compile(r"\[[^\]]*\]\((?!https?://|mailto:|#)([^)\s]+)\)")


def files(*suffixes: str) -> list[Path]:
    return [p for p in ROOT.rglob("*") if p.is_file() and p.suffix in suffixes and not SKIP & set(p.relative_to(ROOT).parts)]


def main() -> int:
    errors: list[str] = []
    for path in files(".json"):
        try:
            json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            errors.append(f"{path.relative_to(ROOT)}: {error}")
    for path in files(".yaml", ".yml"):
        try:
            list(yaml.safe_load_all(path.read_text(encoding="utf-8")))
        except (yaml.YAMLError, UnicodeDecodeError) as error:
            errors.append(f"{path.relative_to(ROOT)}: {error}")
    for path in files(".md"):
        text = path.read_text(encoding="utf-8")
        for target in LINK.findall(text):
            relative = target.split("#", 1)[0]
            if relative and not (path.parent / relative).exists():
                errors.append(f"{path.relative_to(ROOT)}: enlace roto {target}")
    for error in errors:
        print(error, file=sys.stderr)
    print(f"validados {len(files('.json'))} JSON, {len(files('.yaml', '.yml'))} YAML y {len(files('.md'))} Markdown; {len(errors)} errores")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
