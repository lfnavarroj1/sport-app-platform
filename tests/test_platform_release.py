"""Pruebas de la composición de releases de plataforma (scripts/platform_release.py).

Ejecutar desde la raíz de sport-app-platform:
    py -3.13 -m unittest discover -s tests -v
Necesitan jsonschema y pyyaml; sin ellos se omiten.
"""

from __future__ import annotations

import copy
import hashlib
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import platform_release as rel  # noqa: E402
import promote_release as pr  # noqa: E402

try:
    import jsonschema  # noqa: F401
    import yaml
except ImportError:  # pragma: no cover
    yaml = None

FIXTURES = Path(__file__).resolve().parent / "fixtures"
REGISTRIES = {
    "backend": "us-central1-docker.pkg.dev/sportapp-prod-test/sportapp-backend",
    "frontend": "us-central1-docker.pkg.dev/sportapp-prod-test/sportapp-frontend",
}
BACKEND_COMMIT = "0123456789abcdef0123456789abcdef01234567"
FRONTEND_COMMIT = "89abcdef0123456789abcdef0123456789abcdef"
MOBILE_COMMIT = "de526b7af3b06f188f5239ace15bc64727750cdc"
APK_SHA = "d" * 64
URIS = {
    "backend": "gs://sportapp-mgmt-test-delivery-evidence-backend/sport-app-backend/v1.2.0/backend-release.json",
    "frontend": "gs://sportapp-mgmt-test-delivery-evidence-frontend/frontend/v0.9.0/frontend-release.json",
}


def draft() -> dict:
    """Manifiesto candidato de develop después de mover los submódulos."""
    return {
        "schemaVersion": 1,
        "platformVersion": "0.2.0",
        "status": "draft",
        "sprint": "Sprint 2",
        "acceptedStories": [],
        "components": {
            "backend": {"repository": "https://github.com/lfnavarroj1/sport-app-backend", "version": "1.2.0", "ref": "v1.2.0", "commit": BACKEND_COMMIT, "contractVersion": None, "artifacts": {}},
            "frontend": {"repository": "https://github.com/lfnavarroj1/sport-app-frontend", "version": "0.9.0", "ref": "v0.9.0", "commit": FRONTEND_COMMIT, "expectedBffContract": None, "artifact": None},
            "mobile": {"repository": "https://github.com/lfnavarroj1/sport-app-movil", "version": "0.3.0", "versionCode": 3000, "ref": "v0.3.0", "commit": MOBILE_COMMIT, "artifact": None},
        },
    }


def evidence() -> dict:
    result = {}
    for key in ("backend", "frontend"):
        data = (FIXTURES / f"{key}-release.json").read_bytes()
        result[key] = (json.loads(data), hashlib.sha256(data).hexdigest(), URIS[key])
    return result


def compose(**overrides):
    values = {
        "platform_version": "0.2.0",
        "sprint": "Sprint 2",
        "stories": ["HU001", "HU010"],
        "gitlinks": {"backend": BACKEND_COMMIT, "frontend": FRONTEND_COMMIT, "mobile": MOBILE_COMMIT},
        "evidence": evidence(),
        "mobile_sha256": APK_SHA,
        "registries": REGISTRIES,
        "allowlist": pr.load_allowlist(),
    }
    values.update(overrides)
    base = values.pop("draft", None) or draft()
    return rel.compose(base, **values)


@unittest.skipIf(yaml is None, "jsonschema o pyyaml no instalados")
class ComposeTest(unittest.TestCase):
    def test_compone_un_manifiesto_released_valido(self) -> None:
        manifest = compose()
        rel.validate_schema(manifest)
        c = manifest["components"]
        self.assertEqual(manifest["status"], "released")
        self.assertEqual(manifest["acceptedStories"], ["HU001", "HU010"])
        self.assertEqual(c["backend"]["contractVersion"], "0.13.0")
        self.assertEqual(len(c["backend"]["artifacts"]), 8)
        self.assertEqual(c["backend"]["evidence"]["cloudBuildId"], "b6f2a3c4-1111-4222-8333-944455556666")
        self.assertEqual(c["backend"]["evidence"]["sha256"], evidence()["backend"][1])
        self.assertEqual(c["frontend"]["expectedBffContract"], "0.12.0")
        self.assertTrue(c["frontend"]["artifact"]["uri"].startswith(REGISTRIES["frontend"] + "/web@sha256:"))
        self.assertEqual(c["mobile"]["versionCode"], 3000)
        self.assertEqual(c["mobile"]["artifact"], {"sha256": APK_SHA})

    def test_rechaza_submodulo_distinto_del_manifiesto(self) -> None:
        with self.assertRaisesRegex(rel.ReleaseError, "submódulo apunta"):
            compose(gitlinks={"backend": "f" * 40, "frontend": FRONTEND_COMMIT, "mobile": MOBILE_COMMIT})

    def test_rechaza_evidencia_de_otro_commit(self) -> None:
        base = draft()
        base["components"]["backend"]["commit"] = "f" * 40
        with self.assertRaisesRegex(rel.ReleaseError, "no del submódulo"):
            compose(draft=base, gitlinks={"backend": "f" * 40, "frontend": FRONTEND_COMMIT, "mobile": MOBILE_COMMIT})

    def test_rechaza_evidencia_invalida_con_el_mensaje_del_promotor(self) -> None:
        data = evidence()
        document = copy.deepcopy(data["backend"][0])
        document["images"]["bff-web"] = REGISTRIES["backend"] + "/bff-web:latest"
        data["backend"] = (document, data["backend"][1], URIS["backend"])
        with self.assertRaisesRegex(rel.ReleaseError, r"^backend v1\.2\.0: bff-web"):
            compose(evidence=data)

    def test_rechaza_contrato_incompatible(self) -> None:
        data = evidence()
        document = copy.deepcopy(data["frontend"][0])
        document["expectedBffContract"]["version"] = "1.0.0"
        data["frontend"] = (document, data["frontend"][1], URIS["frontend"])
        with self.assertRaisesRegex(rel.ReleaseError, "contrato incompatible"):
            compose(evidence=data)

    def test_exige_hu_apk_y_releases_de_todos_los_componentes(self) -> None:
        with self.assertRaisesRegex(rel.ReleaseError, "al menos una HU"):
            compose(stories=[])
        with self.assertRaisesRegex(rel.ReleaseError, "formato inválido"):
            compose(stories=["HU1"])
        with self.assertRaisesRegex(rel.ReleaseError, "checksum del APK"):
            compose(mobile_sha256="")
        base = draft()
        base["components"]["mobile"]["ref"] = None
        with self.assertRaisesRegex(rel.ReleaseError, "mobile no tiene release"):
            compose(draft=base)


@unittest.skipIf(yaml is None, "jsonschema o pyyaml no instalados")
class RenderTest(unittest.TestCase):
    def test_yaml_conserva_el_contenido_y_la_forma_que_edita_powershell(self) -> None:
        manifest = compose()
        text = rel.render_manifest(manifest, rel.RELEASED_HEADER.format(version="0.2.0"))
        self.assertEqual(yaml.safe_load(text), manifest)
        # Update-ManifestComponent busca "  <componente>:" y campos a 4 espacios.
        for key in ("backend", "frontend", "mobile"):
            self.assertIn(f"\n  {key}:\n", text)
        self.assertIn('\n    ref: "v1.2.0"\n', text)
        self.assertTrue(text.startswith("# yaml-language-server"))

    def test_reabre_en_draft_para_el_ciclo_siguiente(self) -> None:
        reopened = rel.reopen(compose(), "0.3.0")
        rel.validate_schema(reopened)
        self.assertEqual((reopened["status"], reopened["platformVersion"], reopened["acceptedStories"]), ("draft", "0.3.0", []))
        self.assertEqual(reopened["components"]["backend"]["ref"], "v1.2.0")
        self.assertIn("acceptedStories: []", rel.render_manifest(reopened, rel.DRAFT_HEADER))

    def test_notas_con_versiones_artefactos_y_despliegue(self) -> None:
        previous = draft()
        previous["components"]["frontend"]["ref"] = "v0.8.0"
        notes = rel.release_notes(compose(), previous)
        self.assertIn("**SportApp v0.2.0** del **Sprint 2**", notes)
        self.assertIn("- HU010", notes)
        self.assertIn("v1.2.0 (sin cambios)", notes)
        self.assertIn("v0.9.0 (antes v0.8.0)", notes)
        self.assertIn("promote -BackendVersion v1.2.0 -FrontendVersion v0.9.0", notes)
        self.assertIn(APK_SHA, notes)

    def test_cli_compone_copia_y_reabre(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "draft.yaml").write_text(rel.render_manifest(draft(), rel.DRAFT_HEADER), encoding="utf-8")
            for key in ("backend", "frontend"):
                (tmp / f"{key}.json").write_bytes((FIXTURES / f"{key}-release.json").read_bytes())
            arguments = ["compose", "--draft", str(tmp / "draft.yaml"), "--platform-version", "0.2.0", "--sprint", "Sprint 2", "--stories", "HU001, HU010"]
            arguments += [f"--gitlink=backend={BACKEND_COMMIT}", f"--gitlink=frontend={FRONTEND_COMMIT}", f"--gitlink=mobile={MOBILE_COMMIT}"]
            for key in ("backend", "frontend"):
                arguments += [f"--{key}-evidence", str(tmp / f"{key}.json"), f"--{key}-evidence-uri", URIS[key], f"--registry-{key}", REGISTRIES[key]]
            arguments += ["--mobile-sha256", APK_SHA, "--output", str(tmp / "release-manifest.yaml"), "--release-copy", str(tmp / "releases" / "v0.2.0.yaml")]
            self.assertEqual(rel.main(arguments), 0)
            released = yaml.safe_load((tmp / "release-manifest.yaml").read_text(encoding="utf-8"))
            self.assertEqual(released, yaml.safe_load((tmp / "releases" / "v0.2.0.yaml").read_text(encoding="utf-8")))
            self.assertEqual(rel.main(["reopen", "--manifest", str(tmp / "release-manifest.yaml"), "--next-version", "0.3.0", "--output", str(tmp / "next.yaml")]), 0)
            self.assertEqual(rel.main(["verify", "--manifest", str(tmp / "next.yaml")]), 0)
            self.assertEqual(rel.main(["refs", "--draft", str(tmp / "next.yaml")]), 0)


@unittest.skipIf(yaml is None, "jsonschema o pyyaml no instalados")
class PublishedReleasesTest(unittest.TestCase):
    """Cada copia en releases/ es una composición publicada y válida."""

    def test_copias_publicadas_validas(self) -> None:
        for path in sorted((ROOT / "releases").glob("*.yaml")) if (ROOT / "releases").is_dir() else []:
            with self.subTest(path.name):
                match = re.fullmatch(r"v(.+)\.yaml", path.name)
                self.assertIsNotNone(match, "el nombre debe ser vX.Y.Z.yaml")
                document = rel.load_yaml(path)
                rel.validate_schema(document)
                self.assertEqual(document["status"], "released")
                self.assertEqual(document["platformVersion"], match.group(1))


if __name__ == "__main__":
    unittest.main()
