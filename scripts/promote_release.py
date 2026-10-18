#!/usr/bin/env python3
"""Promotor de releases de SportApp (lo ejecuta cloudbuild.promote.yaml en GCP).

Corre dentro de Cloud Build con la cuenta release-promoter, en un trigger manual
interno que nunca se invoca desde GitHub. Para el componente y el tag indicados:

1. descarga la evidencia que publicó Cloud Build (backend-release.json o
   frontend-release.json) del bucket del componente;
2. la valida: SemVer, repositorio, commit, Cloud Build ID, pruebas, contratos,
   allowlist de imágenes, registro de Artifact Registry propio y digests
   (rechaza latest, tags e imágenes externas);
3. para el backend, obtiene deploy/k8s/base en el commit exacto de la release
   (lectura mediante la conexión de Cloud Build) y comprueba que solo contenga
   los objetos de la allowlist;
4. prepara la fuente controlada por la plataforma (deploy/clouddeploy) y crea
   releases en los pipelines existentes. Con requireApproval en cada target,
   el primer rollout queda pendiente de aprobación humana.

No aprueba rollouts, no modifica pipelines ni targets, no ejecuta Terraform ni
kubectl y no acepta comandos: solo opciones validadas. Solo usa la biblioteca
estándar y ejecuta procesos sin shell.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess  # nosec B404: comandos fijos, sin shell
import sys
import tempfile
import urllib.request
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
DEPLOY_DIR = ROOT / "deploy" / "clouddeploy"
ALLOWLIST_PATH = DEPLOY_DIR / "allowlist.json"

SEMVER = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?"
TAG_RE = re.compile(rf"^v(?P<version>{SEMVER})$")
VERSION_RE = re.compile(rf"^{SEMVER}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
BUILD_ID_RE = re.compile(r"^[0-9a-f-]{8,64}$")
PROJECT_RE = re.compile(r"^[a-z][a-z0-9-]{4,28}[a-z0-9]$")
REGION_RE = re.compile(r"^[a-z]+-[a-z]+[0-9]$")
BUCKET_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$")
K8S_NAME_RE = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
AR_RE = re.compile(r"^(?P<location>[a-z0-9-]+)-docker\.pkg\.dev/(?P<project>[a-z][a-z0-9-]+)/(?P<repository>sportapp-(backend|frontend))$")
PINNED_IMAGE_RE = re.compile(r"^[a-z0-9.-]+(/[a-z0-9._-]+)+(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$")
REPOSITORY_RESOURCE_RE = re.compile(r"^projects/[a-z0-9-]+/locations/[a-z0-9-]+/connections/[a-z0-9-]+/repositories/[A-Za-z0-9._-]+$")
PLACEHOLDER_RE = re.compile(r"@@[A-Z_]+@@")

# Lo único que puede contener deploy/k8s/base del backend.
ALLOWED_KINDS = {"Deployment", "Job", "Service"}
FORBIDDEN_SPEC = ("privileged: true", "hostNetwork: true", "hostPID: true", "hostIPC: true", "hostPath:")
FORBIDDEN_KUSTOMIZE = ("generators", "transformers", "helmCharts", "components", "replacements", "openapi", "crds")


class PromotionError(Exception):
    """Evidencia o configuración inválida: no se crea ninguna release."""


# ------------------------------------------------------------------ ejecución

Runner = Callable[[Sequence[str], Mapping[str, str] | None], str]


def run_command(command: Sequence[str], env: Mapping[str, str] | None = None) -> str:
    """Ejecuta un comando fijo (lista de argumentos, sin shell) y devuelve su salida."""
    completed = subprocess.run(  # nosec B603: argumentos validados, sin shell
        list(command),
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, **(env or {})},
    )
    if completed.returncode != 0:
        raise PromotionError(f"falló {command[0]} {command[1] if len(command) > 1 else ''}: {completed.stderr.strip()[-500:]}")
    return completed.stdout


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise PromotionError(message)


# ----------------------------------------------------------------- allowlist

def load_allowlist(path: Path = ALLOWLIST_PATH) -> dict[str, Any]:
    allowlist = json.loads(path.read_text(encoding="utf-8"))
    _require(allowlist.get("schemaVersion") == 1, "allowlist con schemaVersion desconocido")
    return allowlist


def all_allowed_images(allowlist: Mapping[str, Any], component: str) -> list[str]:
    images: list[str] = []
    for pipeline in allowlist["components"][component]["pipelines"].values():
        images.extend(pipeline["images"])
    return images


# ------------------------------------------------------------------ evidencia

def check_tag(tag: str) -> str:
    match = TAG_RE.match(tag)
    _require(match is not None, f"el tag '{tag}' no es SemVer vX.Y.Z o vX.Y.Z-pre")
    return match.group("version")  # type: ignore[union-attr]


def check_image(uri: str, registry: str, name: str) -> str:
    """Una imagen promovible: de este registro y repositorio, del nombre esperado y por digest."""
    _require(isinstance(uri, str), f"{name}: la imagen no es texto")
    _require("latest" not in uri.split("/")[-1].split("@")[0], f"{name}: se rechaza latest")
    expected = re.compile(rf"^{re.escape(registry)}/{re.escape(name)}@sha256:[0-9a-f]{{64}}$")
    _require(expected.match(uri) is not None, f"{name}: '{uri}' no es {registry}/{name}@sha256:<digest> (tags e imágenes externas no se aceptan)")
    return uri


def _exact_keys(document: Mapping[str, Any], required: set[str], where: str) -> None:
    keys = set(document)
    _require(required <= keys, f"{where}: faltan {sorted(required - keys)}")
    _require(keys <= required, f"{where}: campos no permitidos {sorted(keys - required)}")


@dataclass
class Release:
    component: str
    version: str
    tag: str
    commit: str
    build_id: str
    contract: str
    images: dict[str, str]
    evidence_sha256: str
    checksums: dict[str, str] = field(default_factory=dict)


def validate_backend(manifest: Mapping[str, Any], *, tag: str, registry: str, allowlist: Mapping[str, Any], evidence_sha256: str) -> Release:
    _exact_keys(manifest, {"schemaVersion", "kind", "repository", "version", "tag", "commit", "contractVersion", "contracts", "builtAt", "build", "images", "testResults"}, "backend-release.json")
    _require(manifest["schemaVersion"] == 1, "backend-release.json: schemaVersion distinto de 1")
    _require(manifest["kind"] == "backend-release", "backend-release.json: kind distinto de backend-release")
    expected_repo = "https://github.com/" + allowlist["components"]["backend"]["repository"]
    _require(manifest["repository"] == expected_repo, f"repositorio '{manifest['repository']}' distinto de {expected_repo}")
    version = check_tag(tag)
    _require(manifest["tag"] == tag and manifest["version"] == version, "el tag o la versión del manifiesto no coinciden con el solicitado")
    _require(isinstance(manifest["commit"], str) and COMMIT_RE.match(manifest["commit"]) is not None, "commit inválido")
    _require(isinstance(manifest["contractVersion"], str) and VERSION_RE.match(manifest["contractVersion"]) is not None, "contractVersion no es SemVer")
    contracts = manifest["contracts"]
    _require(isinstance(contracts, dict) and contracts.get("bff-web") == manifest["contractVersion"], "contracts['bff-web'] no coincide con contractVersion")
    _require(all(isinstance(v, str) and VERSION_RE.match(v) for v in contracts.values()), "hay contratos sin versión SemVer")
    build = manifest["build"]
    _require(isinstance(build, dict) and build.get("system") == "cloud-build" and BUILD_ID_RE.match(str(build.get("id", ""))) is not None, "falta el identificador de Cloud Build")
    results = manifest["testResults"]
    _require(isinstance(results, dict) and results.get("status") == "passed", "las pruebas no terminaron en passed")
    suites = results.get("suites", {})
    _require(sorted(suites) == ["component", "contract", "integration", "unit"], "faltan suites de prueba")
    _require(all(s.get("status") == "passed" and int(s.get("tests", 0)) > 0 for s in suites.values()), "hay suites fallidas o vacías")
    images = manifest["images"]
    allowed = set(all_allowed_images(allowlist, "backend"))
    _require(isinstance(images, dict) and set(images) == allowed, f"imágenes fuera de la allowlist o faltantes: {sorted(set(images) ^ allowed)}")
    checked = {name: check_image(uri, registry, name) for name, uri in images.items()}
    return Release(
        component="backend",
        version=version,
        tag=tag,
        commit=manifest["commit"],
        build_id=build["id"],
        contract=manifest["contractVersion"],
        images=checked,
        evidence_sha256=evidence_sha256,
        checksums={name: uri.split("@", 1)[1] for name, uri in checked.items()},
    )


def validate_frontend(manifest: Mapping[str, Any], *, tag: str, registry: str, allowlist: Mapping[str, Any], evidence_sha256: str) -> Release:
    _exact_keys(manifest, {"schemaVersion", "kind", "repository", "component", "version", "tag", "commit", "expectedBffContract", "artifact", "checks", "smokeTest", "image", "cloudBuild", "createdAt"}, "frontend-release.json")
    _require(manifest["schemaVersion"] == "1.0", "frontend-release.json: schemaVersion distinto de 1.0")
    _require(manifest["kind"] == "frontend-release", "frontend-release.json: kind distinto de frontend-release")
    expected_repo = allowlist["components"]["frontend"]["repository"]
    _require(manifest["repository"] == expected_repo, f"repositorio '{manifest['repository']}' distinto de {expected_repo}")
    _require(manifest["component"] == "web", "el componente del frontend debe ser web")
    version = check_tag(tag)
    _require(manifest["tag"] == tag and manifest["version"] == version, "el tag o la versión del manifiesto no coinciden con el solicitado")
    _require(isinstance(manifest["commit"], str) and COMMIT_RE.match(manifest["commit"]) is not None, "commit inválido")
    contract = manifest["expectedBffContract"]
    _require(isinstance(contract, dict) and contract.get("name") == "bff-web" and VERSION_RE.match(str(contract.get("version", ""))) is not None, "expectedBffContract inválido")
    _require(SHA256_RE.match(str(contract.get("sha256", ""))) is not None, "expectedBffContract sin checksum sha256")
    artifact = manifest["artifact"]
    _require(isinstance(artifact, dict) and SHA256_RE.match(str(artifact.get("sha256", ""))) is not None, "el artefacto web no tiene checksum sha256")
    _require(all(c.get("status") == "passed" for c in manifest["checks"]) and len(manifest["checks"]) > 0, "hay comprobaciones fallidas")
    _require(manifest["smokeTest"].get("status") == "passed", "la prueba de humo no terminó en passed")
    cloud_build = manifest["cloudBuild"]
    _require(isinstance(cloud_build, dict) and BUILD_ID_RE.match(str(cloud_build.get("buildId", ""))) is not None, "falta el identificador de Cloud Build")
    image = manifest["image"]
    uri = check_image(image.get("uri", ""), registry, "web")
    _require(uri.endswith("@" + str(image.get("digest", ""))), "el digest no coincide con la URI de la imagen")
    return Release(
        component="frontend",
        version=version,
        tag=tag,
        commit=manifest["commit"],
        build_id=cloud_build["buildId"],
        contract=contract["version"],
        images={"web": uri},
        evidence_sha256=evidence_sha256,
        checksums={"web": image["digest"], "web.tgz": "sha256:" + artifact["sha256"], "bff-web.openapi": "sha256:" + contract["sha256"]},
    )


def _semver_tuple(version: str) -> tuple[int, int, int]:
    major, minor, patch = version.split("-", 1)[0].split(".")
    return int(major), int(minor), int(patch)


def check_contract_compatibility(expected_bff: str, offered_bff: str) -> None:
    """El frontend espera bff-web X.Y: el backend ofrece la misma MAJOR y una MINOR igual o mayor."""
    expected, offered = _semver_tuple(expected_bff), _semver_tuple(offered_bff)
    _require(expected[0] == offered[0] and offered[1] >= expected[1], f"contrato incompatible: el frontend espera bff-web {expected_bff} y el backend ofrece {offered_bff}")


# --------------------------------------------------- manifiestos del backend

_DOC_SPLIT = re.compile(r"^---\s*$", re.MULTILINE)
_KIND = re.compile(r"^kind:\s*(\S+)\s*$", re.MULTILINE)
_META_NAME = re.compile(r"^metadata:\s*\n(?:^[ ]{2,}.*\n)*?^  name:\s*(\S+)\s*$", re.MULTILINE)


def inventory_base(base: Path) -> dict[str, set[str]]:
    """Objetos de deploy/k8s/base por tipo; rechaza tipos, campos o archivos fuera de la allowlist."""
    kustomization = base / "kustomization.yaml"
    _require(kustomization.is_file(), "deploy/k8s/base no tiene kustomization.yaml")
    text = kustomization.read_text(encoding="utf-8")
    for key in FORBIDDEN_KUSTOMIZE:
        _require(re.search(rf"^{key}:", text, re.MULTILINE) is None, f"kustomization.yaml del backend usa '{key}', no permitido")
    _require("://" not in text and "../" not in text, "kustomization.yaml del backend referencia recursos externos")
    found: dict[str, set[str]] = {kind: set() for kind in ALLOWED_KINDS}
    for path in sorted(base.glob("*.yaml")):
        if path.name == "kustomization.yaml":
            continue
        content = path.read_text(encoding="utf-8")
        for forbidden in FORBIDDEN_SPEC:
            _require(forbidden not in content, f"{path.name}: '{forbidden}' no está permitido")
        for document in _DOC_SPLIT.split(content):
            if not document.strip() or _KIND.search(document) is None:
                continue
            kind = _KIND.search(document).group(1)  # type: ignore[union-attr]
            name_match = _META_NAME.search(document if document.endswith("\n") else document + "\n")
            _require(name_match is not None, f"{path.name}: objeto {kind} sin metadata.name")
            name = name_match.group(1)  # type: ignore[union-attr]
            _require(kind in ALLOWED_KINDS, f"{path.name}: tipo {kind} no permitido en GKE")
            found[kind].add(name)
    return found


def check_base(base: Path, allowlist: Mapping[str, Any]) -> dict[str, set[str]]:
    rules = allowlist["components"]["backend"]["kubernetes"]
    found = inventory_base(base)
    allowed_deployments = set(rules["deployments"]) | set(rules["cloudRunDeployments"])
    _require(found["Deployment"] <= allowed_deployments, f"Deployments fuera de la allowlist: {sorted(found['Deployment'] - allowed_deployments)}")
    _require(set(rules["deployments"]) <= found["Deployment"], f"faltan Deployments: {sorted(set(rules['deployments']) - found['Deployment'])}")
    _require(found["Job"] <= set(rules["jobs"]), f"Jobs fuera de la allowlist: {sorted(found['Job'] - set(rules['jobs']))}")
    _require(len(found["Job"]) > 0, "el backend no declara Jobs de migración")
    _require(found["Service"] <= set(rules["services"]), f"Services fuera de la allowlist: {sorted(found['Service'] - set(rules['services']))}")
    return found


# --------------------------------------------------------- fuente y release

def release_name(pipeline: str, release: Release, suffix: str = "") -> str:
    """Nombre válido de release (minúsculas, <= 63): <pipeline>-<versión>-<commit corto>[-<sufijo>].

    El sufijo solo se usa para volver a promover una versión ya publicada (rollback).
    """
    version = re.sub(r"[^a-z0-9]+", "-", release.version.lower()).strip("-")
    name = f"{pipeline}-v{version}-{release.commit[:7]}" + (f"-{suffix}" if suffix else "")
    _require(len(name) <= 63 and re.match(r"^[a-z][a-z0-9-]*[a-z0-9]$", name) is not None, f"nombre de release inválido: {name}")
    return name


def render_source(template: Path, destination: Path, values: Mapping[str, str]) -> None:
    """Copia la plantilla de la plataforma y completa los @@...@@; ninguno puede quedar sin valor."""
    shutil.copytree(template, destination, ignore=shutil.ignore_patterns("README.md", "backend-base"))
    for path in destination.rglob("*.yaml"):
        text = path.read_text(encoding="utf-8")
        for key, value in values.items():
            _require("@@" not in value and "\n" not in value, f"valor inválido para {key}")
            text = text.replace(f"@@{key}@@", value)
        left = PLACEHOLDER_RE.findall(text)
        _require(not left, f"{path.name}: quedan valores sin resolver {sorted(set(left))}")
        path.write_text(text, encoding="utf-8")


@dataclass
class Settings:
    component: str
    tag: str
    backend_tag: str | None
    delivery_project: str
    region: str
    evidence_buckets: dict[str, str]
    source_bucket: str
    registries: dict[str, str]
    gke_cluster: str
    gke_location: str
    gke_project: str
    namespace: str
    run_project: str
    run_region: str
    deploy_tools_image: str
    run_verify_image: str
    backend_repository_resource: str
    release_suffix: str = ""


def validate_settings(args: argparse.Namespace) -> Settings:
    _require(args.component in ("backend", "frontend"), "componente desconocido")
    check_tag(args.version)
    if args.component == "frontend":
        _require(bool(args.backend_version), "el frontend exige --backend-version para comprobar el contrato con bff-web")
    if args.backend_version:
        check_tag(args.backend_version)
    for value, regex, name in (
        (args.delivery_project, PROJECT_RE, "proyecto de entrega"),
        (args.gke_project, PROJECT_RE, "proyecto de GKE"),
        (args.run_project, PROJECT_RE, "proyecto de Cloud Run"),
        (args.region, REGION_RE, "región"),
        (args.run_region, REGION_RE, "región de Cloud Run"),
        (args.gke_location, re.compile(r"^[a-z]+-[a-z]+[0-9](-[a-z])?$"), "ubicación de GKE"),
        (args.gke_cluster, K8S_NAME_RE, "clúster"),
        (args.namespace, K8S_NAME_RE, "namespace"),
        (args.evidence_bucket_backend, BUCKET_RE, "bucket de evidencia backend"),
        (args.evidence_bucket_frontend, BUCKET_RE, "bucket de evidencia frontend"),
        (args.source_bucket, BUCKET_RE, "bucket de fuentes"),
        (args.deploy_tools_image, PINNED_IMAGE_RE, "imagen de herramientas"),
        (args.run_verify_image, PINNED_IMAGE_RE, "imagen de verificación"),
    ):
        _require(regex.match(value or "") is not None, f"{name} inválido: '{value}'")
    registries = {"backend": args.ar_backend, "frontend": args.ar_frontend}
    for key, registry in registries.items():
        match = AR_RE.match(registry or "")
        _require(match is not None and match.group("repository") == f"sportapp-{key}", f"registro {key} inválido: '{registry}'")
        _require(match.group("project") == args.run_project, f"el registro {key} no es del proyecto de producción")  # type: ignore[union-attr]
    _require(re.match(r"^([a-z0-9]{1,8})?$", args.release_suffix) is not None, "el sufijo de release admite de 1 a 8 minúsculas o dígitos")
    if args.component == "backend":
        _require(REPOSITORY_RESOURCE_RE.match(args.backend_repository_resource or "") is not None, "falta el repositorio backend de la conexión de Cloud Build")
    return Settings(
        component=args.component,
        tag=args.version,
        backend_tag=args.backend_version or None,
        delivery_project=args.delivery_project,
        region=args.region,
        evidence_buckets={"backend": args.evidence_bucket_backend, "frontend": args.evidence_bucket_frontend},
        source_bucket=args.source_bucket,
        registries=registries,
        gke_cluster=args.gke_cluster,
        gke_location=args.gke_location,
        gke_project=args.gke_project,
        namespace=args.namespace,
        run_project=args.run_project,
        run_region=args.run_region,
        deploy_tools_image=args.deploy_tools_image,
        run_verify_image=args.run_verify_image,
        backend_repository_resource=args.backend_repository_resource or "",
        release_suffix=args.release_suffix,
    )


def fetch_evidence(settings: Settings, component: str, tag: str, allowlist: Mapping[str, Any], runner: Runner) -> tuple[dict[str, Any], str]:
    path = allowlist["components"][component]["evidencePath"].format(tag=tag)
    text = runner(["gcloud", "storage", "cat", f"gs://{settings.evidence_buckets[component]}/{path}"], None)
    try:
        document = json.loads(text)
    except json.JSONDecodeError as error:
        raise PromotionError(f"{path} no es JSON: {error}") from error
    _require(isinstance(document, dict), f"{path} no es un objeto JSON")
    return document, hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_release(settings: Settings, component: str, tag: str, allowlist: Mapping[str, Any], runner: Runner) -> Release:
    document, digest = fetch_evidence(settings, component, tag, allowlist, runner)
    validate = validate_backend if component == "backend" else validate_frontend
    return validate(document, tag=tag, registry=settings.registries[component], allowlist=allowlist, evidence_sha256=digest)


def fetch_backend_base(settings: Settings, release: Release, workdir: Path, runner: Runner) -> Path:
    """deploy/k8s/base en el commit exacto de la release, leído por la conexión de Cloud Build."""
    access_token = runner(["gcloud", "auth", "print-access-token"], None).strip()
    request = urllib.request.Request(  # nosec B310: URL fija de la API de Cloud Build
        f"https://cloudbuild.googleapis.com/v2/{settings.backend_repository_resource}:accessReadToken",
        data=b"{}",
        method="POST",
        headers={"Authorization": f"Bearer {access_token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:  # nosec B310
        read_token = json.loads(response.read())["token"]
    clone = workdir / "backend"
    clone.mkdir()
    # El token viaja en una cabecera por entorno, nunca en los argumentos ni en los logs.
    basic = base64.b64encode(f"x-access-token:{read_token}".encode()).decode()
    env = {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "http.extraHeader", "GIT_CONFIG_VALUE_0": f"Authorization: Basic {basic}", "GIT_TERMINAL_PROMPT": "0"}
    remote = "https://github.com/lfnavarroj1/sport-app-backend.git"
    runner(["git", "-C", str(clone), "init", "--quiet"], None)
    runner(["git", "-C", str(clone), "fetch", "--quiet", "--depth", "1", remote, release.commit], env)
    runner(["git", "-C", str(clone), "checkout", "--quiet", "FETCH_HEAD", "--", "deploy/k8s/base"], None)
    commit = runner(["git", "-C", str(clone), "rev-parse", "FETCH_HEAD"], None).strip()
    _require(commit == release.commit, "el commit obtenido no es el de la release")
    return clone / "deploy" / "k8s" / "base"


def release_commands(settings: Settings, release: Release, allowlist: Mapping[str, Any], workdir: Path, base: Path | None) -> list[list[str]]:
    """Comandos `gcloud deploy releases create` (uno por pipeline de la allowlist del componente)."""
    commands = []
    pipelines = allowlist["components"][release.component]["pipelines"]
    for pipeline, spec in pipelines.items():
        name = release_name(pipeline, release, settings.release_suffix)
        source = workdir / "source" / pipeline
        values = {
            "DEPLOY_TOOLS_IMAGE": settings.deploy_tools_image,
            "RUN_VERIFY_IMAGE": settings.run_verify_image,
            "RUN_PROJECT": settings.run_project,
            "RUN_REGION": settings.run_region,
            "GKE_CLUSTER": settings.gke_cluster,
            "GKE_LOCATION": settings.gke_location,
            "GKE_PROJECT": settings.gke_project,
            "NAMESPACE": settings.namespace,
            "RELEASE_LABEL": name,
            "RELEASE_SUFFIX": "-" + hashlib.sha256(name.encode()).hexdigest()[:8],
        }
        if spec["source"] == "gke":
            _require(base is not None, "falta deploy/k8s/base del backend")
            found = check_base(base, allowlist)  # type: ignore[arg-type]
            rules = allowlist["components"]["backend"]["kubernetes"]
            values["EXPECTED_JOBS"] = str(len(found["Job"]))
            values["DEPLOYMENTS"] = " ".join(sorted(set(rules["deployments"]) & found["Deployment"]))
            values["SMOKE_SERVICES"] = " ".join(rules["smokeServices"])
        render_source(DEPLOY_DIR / spec["source"], source, values)
        if spec["source"] == "gke":
            shutil.copytree(base, source / "backend-base")  # type: ignore[arg-type]
        images = ",".join(f"sportapp/{image}={release.images[image]}" for image in spec["images"])
        annotations = ",".join([
            f"sportapp.io/component={release.component}",
            f"sportapp.io/version={release.version}",
            f"sportapp.io/commit={release.commit}",
            f"sportapp.io/cloud-build={release.build_id}",
            f"sportapp.io/contract={release.contract}",
            f"sportapp.io/evidence-sha256={release.evidence_sha256}",
        ])
        commands.append([
            "gcloud", "deploy", "releases", "create", name,
            f"--project={settings.delivery_project}",
            f"--region={settings.region}",
            f"--delivery-pipeline={pipeline}",
            f"--source={source}",
            "--skaffold-file=skaffold.yaml",
            f"--images={images}",
            f"--gcs-source-staging-dir=gs://{settings.source_bucket}/source",
            f"--annotations={annotations}",
            f"--description={release.component} {release.tag} ({release.commit[:7]}), Cloud Build {release.build_id}",
        ])
    return commands


def promote(settings: Settings, runner: Runner = run_command, allowlist: Mapping[str, Any] | None = None) -> list[list[str]]:
    allowlist = allowlist or load_allowlist()
    release = load_release(settings, settings.component, settings.tag, allowlist, runner)
    if release.component == "frontend":
        backend = load_release(settings, "backend", settings.backend_tag or "", allowlist, runner)
        check_contract_compatibility(release.contract, backend.contract)
    with tempfile.TemporaryDirectory(prefix="promote-") as tmp:
        workdir = Path(tmp)
        base = fetch_backend_base(settings, release, workdir, runner) if release.component == "backend" else None
        commands = release_commands(settings, release, allowlist, workdir, base)
        for command in commands:
            runner(command, None)
            print(f"release creada (pendiente de aprobación): {command[4]}")
    print(json.dumps({"component": release.component, "tag": release.tag, "commit": release.commit, "cloudBuild": release.build_id, "checksums": release.checksums, "evidenceSha256": release.evidence_sha256}, indent=2))
    return commands


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--component", required=True, choices=["backend", "frontend"])
    parser.add_argument("--version", required=True, help="tag SemVer de la release del componente")
    parser.add_argument("--backend-version", default="", help="tag del backend con el que se comprueba el contrato del frontend")
    for option in ("delivery-project", "region", "evidence-bucket-backend", "evidence-bucket-frontend", "source-bucket", "ar-backend", "ar-frontend", "gke-cluster", "gke-location", "gke-project", "namespace", "run-project", "run-region", "deploy-tools-image", "run-verify-image"):
        parser.add_argument(f"--{option}", required=True)
    parser.add_argument("--backend-repository-resource", default="")
    parser.add_argument("--release-suffix", default="", help="solo para volver a promover una versión ya publicada (rollback)")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    try:
        promote(validate_settings(parse_args(argv)))
    except PromotionError as error:
        print(f"promote_release: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
