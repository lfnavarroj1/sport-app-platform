"""Políticas del modelo de entrega, verificadas sobre el código del repositorio.

GitHub no se autentica contra GCP, Terraform solo lo ejecuta el operador,
Cloud Build y Cloud Deploy no comparten workloads con Terraform y ninguna
automatización recibe roles administrativos ni aprueba rollouts.

Ejecutar: py -3.13 -m unittest discover -s tests -v
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TERRAFORM = ROOT / "infra" / "terraform"
WORKFLOWS = ROOT / ".github" / "workflows"
MIGRATION_DOC = ROOT / "docs" / "migracion-retiro-wif-github.md"


def terraform_files() -> list[Path]:
    return [p for p in TERRAFORM.rglob("*.tf") if ".terraform" not in p.parts]


def code(path: Path) -> str:
    """Contenido sin comentarios de línea (#, //)."""
    return "\n".join(re.sub(r"(^|\s)(#|//).*$", "", line) for line in path.read_text(encoding="utf-8").splitlines())


class SinIdentidadGcpParaGithubTest(unittest.TestCase):
    def test_terraform_no_crea_wif_ni_principals_de_github(self) -> None:
        forbidden = (
            "google_iam_workload_identity_pool",
            "token.actions.githubusercontent.com",
            "principalSet://",
            "principal://iam.googleapis.com",
            "workload_identity_provider",
            "ci-delivery",
            "github_repository\"",
            "component_repositories",
        )
        for path in terraform_files():
            text = code(path)
            for pattern in forbidden:
                with self.subTest(archivo=str(path.relative_to(ROOT)), patron=pattern):
                    self.assertNotIn(pattern, text)

    def test_workflows_sin_credenciales_ni_operaciones_gcp(self) -> None:
        for path in WORKFLOWS.glob("*.y*ml"):
            text = path.read_text(encoding="utf-8")
            with self.subTest(workflow=path.name):
                self.assertNotIn("id-token: write", text)
                self.assertNotIn("google-github-actions", text)
                self.assertNotRegex(text, r"\bgcloud\b|\bkubectl\b|terraform apply|terraform destroy|terraform plan")
                self.assertNotRegex(text, r"secrets\.[A-Z_]*(GCP|GOOGLE|SA|SERVICE_ACCOUNT)")
                for init in re.findall(r"terraform init[^\n]*", text):
                    self.assertIn("-backend=false", init)

    def test_variables_de_github_retiradas(self) -> None:
        names = ("GCP_WORKLOAD_IDENTITY_PROVIDER", "PROD_TF_PLAN_SA", "PROD_TF_APPLY_SA", "GCP_DELIVERY_SERVICE_ACCOUNT")
        files = [p for p in ROOT.rglob("*") if p.is_file() and p.suffix in {".md", ".tf", ".yml", ".yaml", ".json", ".example", ".tfvars"} and ".git" not in p.parts and ".terraform" not in p.parts and "components" not in p.relative_to(ROOT).parts[:1] and p != MIGRATION_DOC and p.parent.name != "tests"]
        for path in files:
            text = path.read_text(encoding="utf-8", errors="ignore")
            for name in names:
                with self.subTest(archivo=str(path.relative_to(ROOT)), variable=name):
                    self.assertNotIn(name, text)


class PermisosMinimosTest(unittest.TestCase):
    def test_sin_roles_administrativos_generales(self) -> None:
        for path in terraform_files():
            text = code(path)
            for role in ('"roles/owner"', '"roles/editor"', "cluster-admin", '"roles/iam.serviceAccountTokenCreator"'):
                if role == '"roles/iam.serviceAccountTokenCreator"' and path.parent.name == "gcp-state":
                    continue  # solo operadores y agentes de servicio (pruebas del bootstrap)
                with self.subTest(archivo=str(path.relative_to(ROOT)), rol=role):
                    self.assertNotIn(role, text)

    def test_approver_solo_para_personas(self) -> None:
        for path in terraform_files():
            text = code(path)
            if re.search(r'role\s*=\s*"roles/clouddeploy\.approver"', text):
                with self.subTest(archivo=str(path.relative_to(ROOT))):
                    self.assertEqual(path.relative_to(TERRAFORM).as_posix(), "environments/delivery/main.tf")
                    self.assertIn("member   = each.value.member", text)
                    self.assertRegex((path.parent / "variables.tf").read_text(encoding="utf-8"), r"\^\(user\|group\):")

    def test_todos_los_targets_exigen_aprobacion(self) -> None:
        text = code(TERRAFORM / "environments" / "delivery" / "main.tf")
        targets = len(re.findall(r'resource "google_clouddeploy_target"', text))
        self.assertGreater(targets, 0)
        self.assertEqual(len(re.findall(r"require_approval\s*=\s*true", text)), targets)
        self.assertNotRegex(text, r"require_approval\s*=\s*(false|var\.)")


class PropiedadTerraformCloudDeployTest(unittest.TestCase):
    def test_production_workloads_no_administra_cargas(self) -> None:
        folder = TERRAFORM / "environments" / "production-workloads"
        text = "\n".join(code(p) for p in folder.glob("*.tf") if p.name != "migration.tf")
        self.assertNotIn('resource "kubernetes_manifest"', text)
        self.assertNotRegex(text, r'resource "kubernetes_(deployment|job|cron_job)')
        self.assertNotIn("image_digests", text)
        self.assertIn('can(regex("^_/Service/", id))', text)
        self.assertNotRegex(text, r"for_each\s*=\s*local\.ids_rendered")

    def test_cloud_run_solo_ignora_campos_de_cloud_deploy(self) -> None:
        text = code(TERRAFORM / "modules" / "gcp" / "cloud-run" / "main.tf")
        block = re.search(r"ignore_changes\s*=\s*\[\s*\n(.*?)\n\s*\]\s*\n", text, re.S)
        self.assertIsNotNone(block)
        fields = {f.strip() for f in block.group(1).split(",") if f.strip()}  # type: ignore[union-attr]
        self.assertEqual(fields, {
            "template[0].containers[0].image",
            "template[0].revision",
            "template[0].labels",
            "template[0].annotations",
            "traffic",
            "client",
            "client_version",
        })
        self.assertNotIn("ignore_changes = all", text)

    def test_plantillas_de_cloud_deploy_sin_tags_mutables(self) -> None:
        for path in (ROOT / "deploy" / "clouddeploy").rglob("*.yaml"):
            if "backend-base" in path.parts:
                continue
            text = path.read_text(encoding="utf-8")
            with self.subTest(archivo=str(path.relative_to(ROOT))):
                self.assertNotRegex(text, r"image:\s*\S+:latest")
                for image in re.findall(r"image:\s*\"?([^\s\"]+)", text):
                    self.assertTrue(image.startswith("sportapp/") or image.startswith("@@"), image)


class PromotorTest(unittest.TestCase):
    def test_promotor_no_aprueba_ni_usa_shell(self) -> None:
        for path in (ROOT / "scripts" / "promote_release.py", ROOT / "cloudbuild.promote.yaml"):
            text = code(path)
            with self.subTest(archivo=path.name):
                # Invocaciones, no prosa: ningún comando approve, terraform o kubectl.
                found = re.search(r'"(approve|terraform|kubectl)"|rollouts\s+approve|shell=True|os\.system', text)
                self.assertIsNone(found, found and found.group(0))
        yaml = (ROOT / "cloudbuild.promote.yaml").read_text(encoding="utf-8")
        self.assertIn("substitutionOption: MUST_MATCH", yaml)
        # MUST_MATCH: el trigger envía exactamente las sustituciones que declara el archivo.
        declared = set(re.findall(r"^  (_[A-Z_]+):", yaml, re.MULTILINE))
        delivery = (TERRAFORM / "environments" / "delivery" / "main.tf").read_text(encoding="utf-8")
        block = re.search(r"promote_substitutions = \{(.*?)\n  \}", delivery, re.S)
        self.assertIsNotNone(block)
        sent = set(re.findall(r"^\s+(_[A-Z_]+)\s+=", block.group(1), re.MULTILINE))  # type: ignore[union-attr]
        self.assertEqual(sent, declared)
        self.assertIn("logging: CLOUD_LOGGING_ONLY", yaml)
        self.assertNotIn("serviceAccount", code(ROOT / "cloudbuild.promote.yaml"))


if __name__ == "__main__":
    unittest.main()
