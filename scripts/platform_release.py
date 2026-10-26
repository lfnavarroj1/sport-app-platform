#!/usr/bin/env python3
"""Composición de una release de sport-app-platform (lo usa sportapp-release-plataforma.ps1).

La plataforma no construye nada: fija una combinación de componentes ya
publicados. Este módulo, a partir del manifiesto candidato de develop y de la
evidencia que publicó Cloud Build para cada tag:

1. valida la evidencia con el mismo código del promotor (promote_release.py);
2. comprueba que el tag, el commit de la evidencia y el puntero del submódulo
   coincidan, y que el contrato que espera el frontend lo ofrezca el backend;
3. escribe release-manifest.yaml en status released y su copia inmutable
   releases/vX.Y.Z.yaml, validados contra schemas/release-manifest.schema.json;
4. reabre el manifiesto en draft para el ciclo siguiente y genera las notas.

Comandos (desde la raíz de sport-app-platform):
    refs     tags de los componentes declarados en el manifiesto (JSON)
    compose  manifiesto released y su copia en releases/
    reopen   manifiesto draft con la versión siguiente y sin HU aceptadas
    notes    notas de release en Markdown
    verify   valida un manifiesto contra el JSON Schema

Necesita pyyaml y jsonschema (las mismas versiones que validate-platform.yml).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

import promote_release as pr

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "schemas" / "release-manifest.schema.json"
COMPONENTS = ("backend", "frontend", "mobile")
STORY_RE = re.compile(r"^HU[0-9]{3}$")

DRAFT_HEADER = """\
# yaml-language-server: $schema=schemas/release-manifest.schema.json
# Composición candidata de SportApp.
#
# `draft` permite registrar los commits fijados por los submódulos antes de
# que existan releases y artefactos publicados. La release de plataforma
# (scripts/sportapp-release-plataforma.ps1) completa todos los campos, cambia el
# estado a `released` y copia este archivo a releases/vX.Y.Z.yaml.
"""

RELEASED_HEADER = """\
# yaml-language-server: $schema=schemas/release-manifest.schema.json
# Composición publicada de SportApp v{version}: versiones, commits, digests y
# evidencia de Cloud Build que validó scripts/sportapp-release-plataforma.ps1.
"""

COPY_HEADER = """\
# yaml-language-server: $schema=../schemas/release-manifest.schema.json
# Copia inmutable de la composición publicada de SportApp v{version}.
# No se edita: una corrección es una versión nueva de la plataforma.
"""


class ReleaseError(Exception):
    """La composición no se puede publicar; no se escribe nada."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ReleaseError(message)


# ------------------------------------------------------------ lectura y esquema


def load_yaml(path: Path) -> dict[str, Any]:
    import yaml  # noqa: PLC0415

    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    _require(isinstance(document, dict), f"{path.name} no es un objeto YAML")
    return document


def validate_schema(manifest: Mapping[str, Any]) -> None:
    import jsonschema  # noqa: PLC0415

    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    errors = sorted(jsonschema.Draft202012Validator(schema).iter_errors(manifest), key=lambda e: list(e.path))
    if errors:
        detail = "; ".join(f"{'.'.join(str(p) for p in e.path) or '(raíz)'}: {e.message}" for e in errors[:5])
        raise ReleaseError(f"el manifiesto no cumple release-manifest.schema.json: {detail}")


def component_refs(draft: Mapping[str, Any]) -> dict[str, str | None]:
    return {key: draft["components"][key].get("ref") for key in COMPONENTS}


def version_code(tag: str) -> int:
    """Mismo esquema que sportapp-release-movil.ps1: MAJOR*1000000 + MINOR*1000 + PATCH."""
    major, minor, patch = (int(n) for n in pr.check_tag(tag).split("-", 1)[0].split("."))
    _require(minor < 1000 and patch < 1000, f"{tag} no cabe en el esquema de versionCode")
    return major * 1_000_000 + minor * 1_000 + patch


# ------------------------------------------------------------------- compose


def load_evidence(path: Path) -> tuple[dict[str, Any], str]:
    """Evidencia y su sha256 sobre los bytes publicados (el mismo que anota el promotor)."""
    data = path.read_bytes()
    try:
        document = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseError(f"{path.name} no es JSON válido: {error}") from error
    return document, hashlib.sha256(data).hexdigest()


def compose(
    draft: Mapping[str, Any],
    *,
    platform_version: str,
    sprint: str,
    stories: Sequence[str],
    gitlinks: Mapping[str, str],
    evidence: Mapping[str, tuple[Mapping[str, Any], str, str]],
    mobile_sha256: str,
    registries: Mapping[str, str],
    allowlist: Mapping[str, Any],
) -> dict[str, Any]:
    """Manifiesto released. evidence[componente] = (documento, sha256, gs://uri)."""
    _require(pr.VERSION_RE.match(platform_version) is not None, f"versión de plataforma '{platform_version}' no es SemVer")
    _require(bool(sprint.strip()), "falta el sprint")
    _require(len(stories) > 0, "una release de plataforma necesita al menos una HU aceptada")
    _require(all(STORY_RE.match(s) for s in stories), f"HU con formato inválido: {[s for s in stories if not STORY_RE.match(s)]}")
    _require(len(set(stories)) == len(stories), "hay HU repetidas")

    refs = component_refs(draft)
    for key in COMPONENTS:
        _require(refs[key] is not None, f"{key} no tiene release en el manifiesto: publícala y mueve el submódulo antes de la release de plataforma")
        commit = gitlinks.get(key, "")
        _require(pr.COMMIT_RE.match(commit) is not None, f"{key}: puntero de submódulo inválido '{commit}'")
        _require(draft["components"][key].get("commit") == commit, f"{key}: el manifiesto declara {draft['components'][key].get('commit')} pero el submódulo apunta a {commit}")

    releases = {}
    for key, validate in (("backend", pr.validate_backend), ("frontend", pr.validate_frontend)):
        document, digest, uri = evidence[key]
        try:
            release = validate(document, tag=refs[key], registry=registries[key], allowlist=allowlist, evidence_sha256=digest)
        except pr.PromotionError as error:
            raise ReleaseError(f"{key} {refs[key]}: {error}") from error
        _require(release.commit == gitlinks[key], f"{key}: la evidencia de {refs[key]} es del commit {release.commit}, no del submódulo {gitlinks[key]}")
        releases[key] = release
    try:
        pr.check_contract_compatibility(releases["frontend"].contract, releases["backend"].contract)
    except pr.PromotionError as error:
        raise ReleaseError(str(error)) from error
    _require(pr.SHA256_RE.match(mobile_sha256 or "") is not None, f"móvil {refs['mobile']}: la release no tiene el checksum del APK (SHA256SUMS)")

    backend, frontend = releases["backend"], releases["frontend"]
    return {
        "schemaVersion": 1,
        "platformVersion": platform_version,
        "status": "released",
        "sprint": sprint.strip(),
        "acceptedStories": list(stories),
        "components": {
            "backend": {
                "repository": draft["components"]["backend"]["repository"],
                "version": backend.version,
                "ref": backend.tag,
                "commit": backend.commit,
                "contractVersion": backend.contract,
                "artifacts": dict(sorted(backend.images.items())),
                "evidence": {"uri": evidence["backend"][2], "sha256": backend.evidence_sha256, "cloudBuildId": backend.build_id},
            },
            "frontend": {
                "repository": draft["components"]["frontend"]["repository"],
                "version": frontend.version,
                "ref": frontend.tag,
                "commit": frontend.commit,
                "expectedBffContract": frontend.contract,
                "artifact": {"uri": frontend.images["web"]},
                "evidence": {"uri": evidence["frontend"][2], "sha256": frontend.evidence_sha256, "cloudBuildId": frontend.build_id},
            },
            "mobile": {
                "repository": draft["components"]["mobile"]["repository"],
                "version": pr.check_tag(refs["mobile"]),
                "versionCode": version_code(refs["mobile"]),
                "ref": refs["mobile"],
                "commit": gitlinks["mobile"],
                "artifact": {"sha256": mobile_sha256},
            },
        },
    }


def reopen(manifest: Mapping[str, Any], next_version: str) -> dict[str, Any]:
    """Manifiesto draft del ciclo siguiente: conserva los componentes fijados."""
    _require(pr.VERSION_RE.match(next_version) is not None, f"versión siguiente '{next_version}' no es SemVer")
    document = json.loads(json.dumps(manifest))
    document.update({"platformVersion": next_version, "status": "draft", "acceptedStories": []})
    return document


# -------------------------------------------------------------------- render


def _scalar(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)


def _render(value: Any, indent: int) -> list[str]:
    pad = " " * indent
    lines: list[str] = []
    for key, item in value.items():
        if isinstance(item, dict):
            if item:
                lines.append(f"{pad}{key}:")
                lines.extend(_render(item, indent + 2))
            else:
                lines.append(f"{pad}{key}: {{}}")
        elif isinstance(item, list):
            if item:
                lines.append(f"{pad}{key}:")
                lines.extend(f"{pad}  - {_scalar(v)}" for v in item)
            else:
                lines.append(f"{pad}{key}: []")
        else:
            lines.append(f"{pad}{key}: {_scalar(item)}")
    return lines


def render_manifest(manifest: Mapping[str, Any], header: str) -> str:
    """YAML con la misma forma que edita sportapp-release-common.ps1 (componentes a 4 espacios)."""
    return header + "\n".join(_render(manifest, 0)) + "\n"


# --------------------------------------------------------------------- notes


def release_notes(manifest: Mapping[str, Any], previous: Mapping[str, Any] | None = None) -> str:
    c = manifest["components"]
    version = manifest["platformVersion"]

    def change(key: str) -> str:
        if not previous:
            return ""
        before = previous["components"][key].get("ref")
        return " (sin cambios)" if before == c[key]["ref"] else f" (antes {before or 'sin release'})"

    lines = [
        f"Composición **SportApp v{version}** del **{manifest['sprint']}**.",
        "",
        "### Historias aceptadas",
        *[f"- {story}" for story in manifest["acceptedStories"]],
        "",
        "### Componentes",
        "| Componente | Versión | Commit | Contrato |",
        "| --- | --- | --- | --- |",
        f"| Backend | {c['backend']['ref']}{change('backend')} | `{c['backend']['commit'][:12]}` | ofrece bff-web {c['backend']['contractVersion']} |",
        f"| Frontend web | {c['frontend']['ref']}{change('frontend')} | `{c['frontend']['commit'][:12]}` | espera bff-web {c['frontend']['expectedBffContract']} |",
        f"| Móvil | {c['mobile']['ref']}{change('mobile')} (versionCode {c['mobile']['versionCode']}) | `{c['mobile']['commit'][:12]}` | — |",
        "",
        "### Artefactos",
        *[f"- `{name}`: `{uri}`" for name, uri in c["backend"]["artifacts"].items()],
        f"- `web`: `{c['frontend']['artifact']['uri']}`",
        f"- APK móvil: sha256 `{c['mobile']['artifact']['sha256']}`",
        "",
        "### Evidencia de Cloud Build",
        f"- Backend: `{c['backend']['evidence']['uri']}` (sha256 `{c['backend']['evidence']['sha256']}`, build `{c['backend']['evidence']['cloudBuildId']}`)",
        f"- Frontend: `{c['frontend']['evidence']['uri']}` (sha256 `{c['frontend']['evidence']['sha256']}`, build `{c['frontend']['evidence']['cloudBuildId']}`)",
        "",
        "### Despliegue y rollback",
        "Desde la estación del operador, en `main` de la plataforma:",
        "```powershell",
        f".\\scripts\\sportapp-gcp.ps1 promote -BackendVersion {c['backend']['ref']} -FrontendVersion {c['frontend']['ref']}",
        "```",
        "Cada rollout espera aprobación en Cloud Deploy. El rollback es volver a promover la composición anterior "
        "(sección 14.2 de docs/preparacion-terraform-gcp.md). El APK se descarga de la release del móvil.",
        "",
        f"Manifiesto: `releases/v{version}.yaml`.",
    ]
    return "\n".join(lines) + "\n"


# ----------------------------------------------------------------------- CLI


def _gitlinks(values: Sequence[str]) -> dict[str, str]:
    result = {}
    for value in values:
        key, _, commit = value.partition("=")
        _require(key in COMPONENTS and bool(commit), f"--gitlink '{value}' debe ser componente=sha")
        result[key] = commit
    return result


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = parser.add_subparsers(dest="command", required=True)

    refs = sub.add_parser("refs")
    refs.add_argument("--draft", type=Path, required=True)

    comp = sub.add_parser("compose")
    comp.add_argument("--draft", type=Path, required=True)
    comp.add_argument("--platform-version", required=True)
    comp.add_argument("--sprint", required=True)
    comp.add_argument("--stories", required=True, help="HU separadas por comas")
    comp.add_argument("--gitlink", action="append", default=[], help="componente=sha del submódulo")
    for key in ("backend", "frontend"):
        comp.add_argument(f"--{key}-evidence", type=Path, required=True)
        comp.add_argument(f"--{key}-evidence-uri", required=True)
        comp.add_argument(f"--registry-{key}", required=True)
    comp.add_argument("--mobile-sha256", default="")
    comp.add_argument("--output", type=Path, required=True)
    comp.add_argument("--release-copy", type=Path, required=True)

    reo = sub.add_parser("reopen")
    reo.add_argument("--manifest", type=Path, required=True)
    reo.add_argument("--next-version", required=True)
    reo.add_argument("--output", type=Path, required=True)

    notes = sub.add_parser("notes")
    notes.add_argument("--manifest", type=Path, required=True)
    notes.add_argument("--previous", type=Path)
    notes.add_argument("--output", type=Path, required=True)

    ver = sub.add_parser("verify")
    ver.add_argument("--manifest", type=Path, required=True)
    return parser.parse_args(argv)


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.command == "refs":
            print(json.dumps(component_refs(load_yaml(args.draft))))
        elif args.command == "compose":
            evidence = {}
            for key in ("backend", "frontend"):
                document, digest = load_evidence(getattr(args, f"{key}_evidence"))
                evidence[key] = (document, digest, getattr(args, f"{key}_evidence_uri"))
            manifest = compose(
                load_yaml(args.draft),
                platform_version=args.platform_version,
                sprint=args.sprint,
                stories=[s.strip() for s in args.stories.split(",") if s.strip()],
                gitlinks=_gitlinks(args.gitlink),
                evidence=evidence,
                mobile_sha256=args.mobile_sha256,
                registries={"backend": args.registry_backend, "frontend": args.registry_frontend},
                allowlist=pr.load_allowlist(),
            )
            validate_schema(manifest)
            _write(args.output, render_manifest(manifest, RELEASED_HEADER.format(version=args.platform_version)))
            _write(args.release_copy, render_manifest(manifest, COPY_HEADER.format(version=args.platform_version)))
            print(json.dumps({"platformVersion": args.platform_version, "components": {k: manifest["components"][k]["ref"] for k in COMPONENTS}}))
        elif args.command == "reopen":
            manifest = reopen(load_yaml(args.manifest), args.next_version)
            validate_schema(manifest)
            _write(args.output, render_manifest(manifest, DRAFT_HEADER))
        elif args.command == "notes":
            previous = load_yaml(args.previous) if args.previous else None
            _write(args.output, release_notes(load_yaml(args.manifest), previous))
        elif args.command == "verify":
            validate_schema(load_yaml(args.manifest))
    except (ReleaseError, pr.PromotionError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
