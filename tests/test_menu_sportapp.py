"""Pruebas del menú único scripts/sportapp.ps1, sin efectos reales.

Análisis sintáctico (ParseFile), reglas estáticas de seguridad y ejecución con
-DryRun, que imprime los comandos sin ejecutarlos. Las pruebas de ejecución se
omiten si no hay PowerShell (powershell o pwsh) en el equipo.

Ejecutar: py -3.13 -m unittest discover -s tests -v
"""

from __future__ import annotations

import re
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "sportapp.ps1"
POWERSHELL = shutil.which("powershell") or shutil.which("pwsh")


def source() -> str:
    return SCRIPT.read_text(encoding="utf-8-sig")


def dry_run(*args: str) -> str:
    result = subprocess.run(
        [POWERSHELL, "-NoProfile", "-NonInteractive", "-File", str(SCRIPT), *args, "-DryRun"],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120, cwd=ROOT, stdin=subprocess.DEVNULL,
    )
    assert result.returncode == 0, f"{args}: código {result.returncode}\n{result.stdout}\n{result.stderr}"
    return result.stdout


class EstaticoTest(unittest.TestCase):
    def test_existe_con_bom_para_powershell_5_1(self) -> None:
        self.assertTrue(SCRIPT.read_bytes().startswith(b"\xef\xbb\xbf"))

    def test_sin_sintaxis_exclusiva_de_powershell_7(self) -> None:
        text = source()
        self.assertNotRegex(text, r"\?\?|\?\.\w|&&|\|\|(?!\s*\{)|ForEach-Object\s+-Parallel|\bclean\s*\{")

    def test_delega_por_parametros_sin_autoapprove(self) -> None:
        text = source()
        self.assertIn("sportapp-gcp.ps1", text)
        self.assertIn("sportapp-release.ps1", text)
        self.assertNotRegex(text, r"AutoApprove\s*=")
        self.assertNotRegex(text, r"-AutoApprove\b(?!\s*`)(?=[^\n]*Invoke-Child)")

    def test_local_solo_docker_desktop_y_gcp_sin_kubectl(self) -> None:
        text = source()
        self.assertNotRegex(text.replace("gke_*", "").replace("'^(--context=)?gke_'", ""), r"gke_")
        gcp = text[text.index("function Show-GcpIdentity"):text.index("function Invoke-Release")]
        self.assertNotIn("kubectl", gcp)
        self.assertNotIn("docker-desktop", gcp)
        self.assertNotIn("Invoke-Kube", gcp)
        self.assertNotRegex(gcp, r"\bterraform\b(?!-)\s")

    def test_tableta_solo_dispositivo_fisico(self) -> None:
        text = source()
        self.assertIn("R52NB04LMCB", text)
        for line in re.findall(r"^.*'adb'.*$", text, flags=re.M):
            if "'devices'" in line or "Get-Command" in line:
                continue
            self.assertIn("$TabletSerial", line)
        self.assertNotRegex(text, r"avdmanager|emulator\.exe|-e\s+reverse")

    def test_secretos_no_se_imprimen_ni_se_guardan(self) -> None:
        text = source()
        self.assertIn("-AsSecureString", text)
        self.assertNotRegex(text, r"Write-(Host|Info|Ok|Note)[^\n]*\$(secretPlain|key|clientId)\b")
        self.assertNotRegex(text, r"(Set-Content|Out-File|Add-Content|Start-Transcript)")
        self.assertNotRegex(text, r"--from-literal")


@unittest.skipUnless(POWERSHELL, "PowerShell no disponible")
class SintaxisTest(unittest.TestCase):
    def test_parsefile_sin_errores(self) -> None:
        command = (
            "$e=$null;$t=$null;[void][System.Management.Automation.Language.Parser]::ParseFile("
            f"'{SCRIPT}',[ref]$t,[ref]$e);$e|ForEach-Object{{$_.Message}};exit $e.Count"
        )
        result = subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-Command", command], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


@unittest.skipUnless(POWERSHELL, "PowerShell no disponible")
class DryRunTest(unittest.TestCase):
    def test_local_apply_muestra_plan_confirmacion_y_apply(self) -> None:
        out = dry_run("local", "apply")
        for expected in ("init -input=false", "validate", "plan -input=false -out=tfplan", "show tfplan", "confirmación escrita 'si'", "apply -input=false tfplan", "--context docker-desktop"):
            self.assertIn(expected, out)
        self.assertNotIn("strava_integration_enabled", out)

    def test_local_apply_strava_agrega_la_variable(self) -> None:
        self.assertIn("-var strava_integration_enabled=true", dry_run("local", "apply", "-Strava"))

    def test_local_build_usa_los_comandos_documentados(self) -> None:
        out = dry_run("local", "build")
        self.assertIn("py -3.13 -m uv run python scripts/task.py build all", out)
        self.assertIn("docker build -t sportapp/web:local .", out)

    def test_local_destroy_planifica_y_confirma(self) -> None:
        out = dry_run("local", "destroy")
        self.assertIn("plan -destroy", out)
        self.assertIn("confirmación escrita 'si'", out)

    def test_local_nunca_usa_gke(self) -> None:
        for action in ("check", "status", "apply", "destroy"):
            self.assertNotIn("gke_", dry_run("local", action))

    def test_secretos_de_strava_no_muestran_valores(self) -> None:
        out = dry_run("local", "secrets")
        self.assertIn("por stdin", out)
        self.assertNotIn("--from-literal", out)

    def test_gcp_muestra_identidad_y_delega_sin_docker_desktop(self) -> None:
        out = dry_run("gcp", "down")
        self.assertIn("gcloud config get-value account", out)
        self.assertIn("gcloud config get-value project", out)
        self.assertIn("confirmación escrita 'si'", out)
        self.assertIn("sportapp-gcp.ps1 -Command down", out)
        self.assertNotIn("docker-desktop", out)
        self.assertNotIn("AutoApprove", out)

    def test_gcp_lectura_no_pide_confirmacion(self) -> None:
        out = dry_run("gcp", "status")
        self.assertIn("sportapp-gcp.ps1 -Command status", out)
        self.assertNotIn("confirmación escrita", out)

    def test_release_reenvia_parametros(self) -> None:
        out = dry_run("release", "release", "-Target", "platform", "-Stories", "HU001,HU010")
        self.assertIn("sportapp-release.ps1", out)
        self.assertIn("-Command release", out)
        self.assertIn("-Target platform", out)
        self.assertIn("confirmación escrita 'si'", out)
        self.assertNotIn("AutoApprove", out)

    def test_tableta_solo_serie_fisica(self) -> None:
        out = dry_run("tablet", "install")
        self.assertIn("ANDROID_SERIAL=R52NB04LMCB", out)
        self.assertIn("-Psportapp.bffMobileBaseUrl.debug=http://localhost:18081/", out)
        reverse = dry_run("tablet", "reverse")
        self.assertIn("adb -s R52NB04LMCB reverse tcp:18081 tcp:18081", reverse)
        self.assertNotIn("emulator", reverse)

    def test_accion_invalida_falla(self) -> None:
        result = subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-File", str(SCRIPT), "local", "inexistente", "-DryRun"], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
