"""Pruebas del menú único scripts/sportapp.ps1, sin efectos reales.

Análisis sintáctico (ParseFile), reglas estáticas de seguridad y ejecución con
-DryRun, que imprime los comandos sin ejecutarlos; el asistente de Strava se
recorre con respuestas simuladas (-SimulatedInput). Las pruebas de ejecución se
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
ENTER = "<enter>"
ENTERS = ",".join([ENTER] * 14)


def source() -> str:
    return SCRIPT.read_text(encoding="utf-8-sig")


def run(*args: str, expect: int = 0) -> str:
    result = subprocess.run(
        [POWERSHELL, "-NoProfile", "-NonInteractive", "-File", str(SCRIPT), *args],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180, cwd=ROOT, stdin=subprocess.DEVNULL,
    )
    assert result.returncode == expect, f"{args}: código {result.returncode}\n{result.stdout}\n{result.stderr}"
    return result.stdout


def dry_run(*args: str, expect: int = 0) -> str:
    return run(*args, "-DryRun", expect=expect)


class EstaticoTest(unittest.TestCase):
    def test_existe_con_bom_para_powershell_5_1(self) -> None:
        self.assertTrue(SCRIPT.read_bytes().startswith(b"\xef\xbb\xbf"))

    def test_sin_sintaxis_exclusiva_de_powershell_7(self) -> None:
        self.assertNotRegex(source(), r"\?\?|\?\.\w|&&|ForEach-Object\s+-Parallel|\bclean\s*\{")

    def test_menu_solo_tiene_tres_bloques(self) -> None:
        text = source()
        menu = text[text.index("function Show-Menu"):text.index("function Show-Help")]
        self.assertEqual(len(re.findall(r"Write-Host '  [0-9]\. ", menu)), 4)  # 1, 2, 3 y 0
        self.assertNotRegex(text, r"Invoke-LocalDestroy|tfdestroy")

    def test_delega_por_parametros(self) -> None:
        text = source()
        self.assertIn("sportapp-gcp.ps1", text)
        self.assertIn("sportapp-release.ps1", text)

    def test_autoapprove_solo_en_etapas_de_release(self) -> None:
        text = source()
        sequence = text[text.index("function Invoke-ReleaseSequence"):text.index("# --- LOCAL ---")]
        self.assertIn("$params.AutoApprove = $true", sequence)
        self.assertEqual(text.count("$params.AutoApprove"), 1)

    def test_local_solo_docker_desktop_y_gcp_sin_kubectl(self) -> None:
        text = source()
        self.assertNotRegex(text.replace("gke_*", "").replace("'^(--context=)?gke_'", ""), r"gke_")
        gcp = text[text.index("function Show-GcpIdentity"):text.index("function Invoke-Release(")]
        for forbidden in ("kubectl", "docker-desktop", "Invoke-Kube"):
            self.assertNotIn(forbidden, gcp)

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

    def test_textos_del_asistente_separados_de_la_logica(self) -> None:
        text = source()
        data = text[text.index("$StravaSteps = @("):text.index("# --- STRAVA: lógica")]
        self.assertNotRegex(data, r"\b(Invoke-|Read-Host|Write-Host)")
        self.assertEqual(len(re.findall(r"Titulo\s+=", data)), 5)
        for field in ("Que", "Donde", "Valores", "Ok", "Falla"):
            self.assertEqual(len(re.findall(rf"\n\s+{field}\s+=", data)), 5, field)


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
class AsistenteStravaTest(unittest.TestCase):
    def test_local_recorre_los_cinco_pasos_y_la_tabla_de_fallos(self) -> None:
        out = dry_run("strava", "-Environment", "local", "-SimulatedInput", ENTERS)
        for n in range(1, 6):
            self.assertIn(f"Paso {n}/6", out)
        for label in ("QUÉ hacer", "DÓNDE", "VALORES", "CÓMO SABER QUE SALIÓ BIEN", "SI FALLA"):
            self.assertIn(label, out)
        self.assertIn("https://www.strava.com/settings/api", out)
        self.assertIn("Authorization Callback Domain = localhost", out)
        self.assertIn("adb -s R52NB04LMCB reverse tcp:18081 tcp:18081", out)
        self.assertIn("-Psportapp.bffMobileBaseUrl.debug=http://localhost:18081/", out)
        self.assertIn("-var strava_integration_enabled=true", out)
        self.assertIn("Si algo falla: síntoma, causa y acción", out)
        self.assertNotIn("gke_", out)
        self.assertNotIn("--from-literal", out)

    def test_abrir_navegador_solo_si_el_usuario_acepta(self) -> None:
        self.assertNotIn("Start-Process", dry_run("strava", "-Environment", "local", "-SimulatedInput", ENTERS))
        out = dry_run("strava", "-Environment", "local", "-SimulatedInput", "si," + ENTERS)
        self.assertIn("[dry-run] Start-Process https://www.strava.com/settings/api", out)

    def test_repetir_y_salir(self) -> None:
        out = dry_run("strava", "-Environment", "local", "-SimulatedInput", "no,r,no,s", expect=1)
        self.assertEqual(out.count("Paso 1/6"), 2)
        self.assertIn("Asistente detenido por el operador", out)

    def test_ayuda_de_fallos_con_a(self) -> None:
        out = dry_run("strava", "-Environment", "local", "-FromStep", "5", "-SimulatedInput", "<enter>,a,<enter>")
        self.assertGreaterEqual(out.count("Si algo falla: síntoma, causa y acción"), 2)

    def test_gcp_usa_gcloud_y_production_workloads_sin_docker_desktop(self) -> None:
        out = dry_run("strava", "-Environment", "gcp", "-SimulatedInput", ENTERS)
        self.assertIn("gcloud secrets versions add strava-client-id", out)
        self.assertIn("gcloud secrets versions add strava-client-secret", out)
        self.assertIn("gcloud secrets versions add strava-token-key", out)
        self.assertIn("sync_strava_secret=true", out)
        self.assertIn("production-workloads", out)
        self.assertIn("output -json runtime_config", out)
        self.assertIn("gcloud config get-value project", out)
        self.assertNotIn("docker-desktop", out)
        self.assertNotIn("--namespace sportapp-local", out)
        self.assertNotIn("[dry-run] adb -s R52NB04LMCB reverse", out)

    def test_simulado_solo_con_dryrun(self) -> None:
        run("strava", "-Environment", "local", "-SimulatedInput", "s", expect=1)


@unittest.skipUnless(POWERSHELL, "PowerShell no disponible")
class DryRunTest(unittest.TestCase):
    def test_menu_navega_con_respuestas_simuladas(self) -> None:
        out = dry_run("-SimulatedInput", "3,1,2,0")
        self.assertIn("1. Integración con Strava", out)
        self.assertIn("2. Lanzar releases", out)
        self.assertIn("3. Desplegar la versión actual y actualizar", out)
        self.assertIn("terraform", out)

    def test_release_secuencia_una_confirmacion_por_etapa(self) -> None:
        out = dry_run("release", "sequence", "-Target", "backend", "-Bump", "patch")
        for stage in ("1/4", "2/4", "3/4", "4/4"):
            self.assertIn(f"etapa {stage}", out)
        self.assertEqual(out.count("confirmación escrita 'si'"), 3)  # etapas 2, 3 y 4
        self.assertIn("-Command check -Target backend", out)
        self.assertIn("-Command check -Target platform", out)
        self.assertIn("-Command release", out)
        self.assertIn("-SkipPlatform", out)
        self.assertIn("-Command submodules", out)
        self.assertIn("-Target platform", out)
        self.assertIn("-AutoApprove", out)

    def test_release_sin_target_en_dryrun_falla(self) -> None:
        dry_run("release", "sequence", expect=1)

    def test_release_comando_suelto_reenvia_parametros(self) -> None:
        out = dry_run("release", "release", "-Target", "platform", "-Stories", "HU001,HU010")
        self.assertIn("-Command release", out)
        self.assertIn("-Target platform", out)
        self.assertIn("confirmación escrita 'si'", out)
        self.assertNotIn("AutoApprove", out)

    def test_release_check_es_lectura(self) -> None:
        out = dry_run("release", "check", "-Target", "backend")
        self.assertIn("sportapp-release.ps1 -Command check -Target backend", out)
        self.assertNotIn("confirmación escrita", out)

    def test_deploy_local_apply_muestra_plan_confirmacion_y_apply(self) -> None:
        out = dry_run("deploy", "apply", "-Environment", "local")
        for expected in ("init -input=false", "validate", "plan -input=false -out=tfplan", "show tfplan", "confirmación escrita 'si'", "apply -input=false tfplan", "--context docker-desktop"):
            self.assertIn(expected, out)

    def test_deploy_local_build_usa_los_comandos_documentados(self) -> None:
        out = dry_run("deploy", "build", "-Environment", "local")
        self.assertIn("py -3.13 -m uv run python scripts/task.py build all", out)
        self.assertIn("docker build -t sportapp/web:local .", out)

    def test_deploy_local_update_reconstruye_y_reinicia(self) -> None:
        out = dry_run("deploy", "update", "-Environment", "local")
        self.assertIn("confirmación escrita 'si'", out)
        self.assertIn("rollout restart deployment", out)
        self.assertIn("--for=condition=Available", out)
        one = dry_run("deploy", "update", "-Environment", "local", "-Component", "bff-mobile")
        self.assertIn("task.py build bff-mobile", one)
        self.assertIn("rollout restart deployment/bff-mobile", one)
        self.assertIn("rollout status deployment/bff-mobile", one)
        self.assertNotIn("docker build", one)

    def test_deploy_local_nunca_usa_gke_ni_destruye(self) -> None:
        for action in ("check", "plan", "apply", "update"):
            out = dry_run("deploy", action, "-Environment", "local")
            self.assertNotIn("gke_", out)
            self.assertNotIn("destroy", out)

    def test_deploy_gcp_muestra_identidad_y_delega_sin_docker_desktop(self) -> None:
        out = dry_run("deploy", "promote", "-Environment", "gcp", "-BackendVersion", "v1.2.0")
        self.assertIn("gcloud config get-value account", out)
        self.assertIn("gcloud config get-value project", out)
        self.assertIn("confirmación escrita 'si'", out)
        self.assertIn("sportapp-gcp.ps1", out)
        self.assertIn("-Command promote", out)
        self.assertIn("-BackendVersion v1.2.0", out)
        self.assertNotIn("docker-desktop", out)
        self.assertNotIn("AutoApprove", out)

    def test_deploy_gcp_lectura_no_pide_confirmacion(self) -> None:
        for action, command in (("status", "status"), ("images", "images"), ("plan", "check")):
            out = dry_run("deploy", action, "-Environment", "gcp")
            self.assertIn(f"-Command {command}", out)
            self.assertNotIn("confirmación escrita", out)

    def test_acciones_eliminadas(self) -> None:
        dry_run("deploy", "destroy", "-Environment", "local", expect=1)
        dry_run("tablet", "install", expect=1)


if __name__ == "__main__":
    unittest.main()
