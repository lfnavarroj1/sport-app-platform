<#
.SYNOPSIS
    Publica la release de backend y frontend: PR develop -> main, pruebas,
    aprobación, merge y release en GitHub. Sus tags alimentan el despliegue.

.DESCRIPTION
    Se ejecuta desde la estación del operador con su sesión de GitHub CLI (gh) y,
    para seguir Cloud Build, con su gcloud (solo lectura). El móvil se publica aparte con
    sportapp-release-movil.ps1 porque no participa en el despliegue.

      check       Valida gh, permisos y ramas de backend y frontend.
      status      Cambios pendientes de develop, PR abierto y última release.
      prepare     Una sola vez: crea main en el frontend.
      release     Por fases y para cada repositorio con cambios: crea o reutiliza el
                  PR develop -> main, espera sus pruebas, pide la aprobación,
                  fusiona, crea la release vX.Y.Z, espera el workflow de release,
                  espera Cloud Build (release-backend / release-frontend) y mueve
                  los submódulos de la plataforma a los tags con imágenes.
      builds      Consulta o espera el Cloud Build de los tags publicados (por
                  defecto, el último de cada repositorio) y muestra el error si falló.
      submodules  Mueve components/backend y components/frontend a los tags
                  publicados y actualiza release-manifest.yaml.

    Cada tag inicia los triggers de Cloud Build release-backend y release-frontend
    del proyecto de gestión; para consultarlos usa gcloud con la cuenta del
    operador. El despliegue se hace después con sportapp-gcp.ps1 promote.
    Instrucciones: scripts/sportapp-release.md.

.EXAMPLE
    .\scripts\sportapp-release.ps1 release

.EXAMPLE
    .\scripts\sportapp-release.ps1 release -Repos backend -Bump patch
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'check', 'status', 'prepare', 'release', 'builds', 'submodules')]
    [string]$Command = 'help',

    # Repositorios a publicar.
    [ValidateSet('backend', 'frontend')]
    [string[]]$Repos = @('backend', 'frontend'),

    # Incremento propuesto desde el último tag de cada repositorio.
    [ValidateSet('patch', 'minor', 'major')]
    [string]$Bump = 'minor',

    # Versiones explícitas (vX.Y.Z); reemplazan la propuesta.
    [string]$BackendVersion,
    [string]$FrontendVersion,

    # Versión de plataforma (sistema) que acompaña las releases; por defecto
    # platformVersion de release-manifest.yaml.
    [string]$SystemVersion,

    # release: no mueve los submódulos de la plataforma ni release-manifest.yaml.
    [switch]$SkipPlatform,

    # release: no espera los builds de Cloud Build de los tags (fase 6).
    [switch]$SkipCloudBuild,

    # Omite las confirmaciones de rutina. La aprobación de cada PR siempre se pregunta.
    [switch]$AutoApprove,

    [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'

$PlatformRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigFile) { $ConfigFile = Join-Path $PlatformRoot '.env.ps1' }
elseif (Test-Path -LiteralPath $ConfigFile) { $ConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path }
$script:MyScriptPath = $PSCommandPath
$ReleaseScriptName = 'sportapp-release.ps1'
$MobileVersion = $null

. (Join-Path $PSScriptRoot 'sportapp-release-common.ps1')

function Invoke-Check {
    $ok = Test-GitHubAccess
    Write-Ok "versión del sistema: $(Get-SystemVersion)"
    Write-Host ''
    if ($ok) { Write-Host 'Todo listo. Siguiente: .\scripts\sportapp-release.ps1 release' -ForegroundColor Green }
    else { throw 'Hay pendientes (marcados con [falta]).' }
}

function Invoke-Prepare {
    if (-not (Get-Login)) { throw 'gh no tiene sesión: gh auth login' }
    $frontend = Get-RepoName 'frontend'
    Write-Step "Rama main en $frontend"
    if (Test-Branch $frontend 'main') { Write-Ok 'ya existe'; return }
    $path = $script:Cfg.frontendRepoPath
    if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { throw "No se encontró el clon del frontend en $path (define `$frontendRepoPath)." }
    Invoke-Show git @('-C', $path, 'fetch', '--quiet', 'origin', 'develop')
    $root = @((Invoke-Capture git @('-C', $path, 'rev-list', '--max-parents=0', 'origin/develop')).Output -split "`n")[-1]
    $message = (Invoke-Capture git @('-C', $path, 'log', '-1', '--format=%s (%ad)', '--date=short', $root)).Output
    Write-Info "Se crea main en el primer commit de develop ($($root.Substring(0, 7)) $message): el primer PR develop -> main mostrará todo el historial."
    Confirm-Step "¿Crear main en $frontend?"
    [void](Invoke-Capture gh @('api', '-X', 'POST', "repos/$frontend/git/refs", '-f', 'ref=refs/heads/main', '-f', "sha=$root"))
    Write-Ok 'main creada'
    Write-Note 'Protege main en el frontend como en el backend (Settings -> Rules: PR obligatorio y 1 aprobación).'
}

# --- Fase 6: Cloud Build ------------------------------------------------------

$CloudBuildFinal = @('SUCCESS', 'FAILURE', 'INTERNAL_ERROR', 'TIMEOUT', 'CANCELLED', 'EXPIRED')

# Build de un trigger para un tag, o $null si todavía no existe. El filtro va sin
# comillas: Windows PowerShell 5.1 no las escapa al llamar a gcloud.
function Get-TagBuild([string]$Trigger, [string]$Tag) {
    $r = Invoke-Capture gcloud @('builds', 'list', "--region=$($script:Cfg.region)", "--project=$($script:Cfg.mgmt)", "--filter=substitutions.TAG_NAME=$Tag", '--limit=20', '--format=json', '--quiet') -AllowFailure
    if ($r.ExitCode -ne 0 -or -not $r.Output) { return $null }
    ConvertFrom-JsonItems $r.Output | Where-Object { $_ -and $_.substitutions.TRIGGER_NAME -eq $Trigger } | Sort-Object createTime -Descending | Select-Object -First 1
}

# Paso que falló y el final de su log (los builds registran solo en Cloud Logging).
function Show-BuildFailure($Build) {
    Write-Info "$($Build.failureInfo.detail)"
    $index = 0
    foreach ($step in @($Build.steps)) { if ($step.status -eq 'FAILURE') { break }; $index++ }
    if ($index -ge @($Build.steps).Count) { return }
    $prefix = "Step #$index - `"$($Build.steps[$index].id)`": "
    $log = (Invoke-Capture gcloud @('builds', 'log', $Build.id, "--region=$($script:Cfg.region)", "--project=$($script:Cfg.mgmt)", '--quiet') -AllowFailure).Output -split "`n"
    $lines = @($log | Where-Object { $_.StartsWith($prefix) } | ForEach-Object { $_.Substring($prefix.Length) })
    # Primero las líneas que parecen la causa; si no hay, el final del paso.
    $errors = @($lines | Where-Object { $_ -match '(?i)\berror\b|failed|exception|not found|no such file|requires|denied' -and $_ -notmatch 'CoverageWarning' })
    if ($errors.Count) { Write-Info "Errores en el paso $($Build.steps[$index].id):"; $errors | Select-Object -Last 12 | ForEach-Object { Write-Info "  $_" } }
    else { Write-Info "Últimas líneas del paso $($Build.steps[$index].id):"; $lines | Select-Object -Last 15 | ForEach-Object { Write-Info "  $_" } }
    Write-Info "Log completo: $($Build.logUrl)"
}

# Cada tag dispara release-backend o release-frontend en el proyecto de gestión.
# Solo las versiones con build SUCCESS tienen imágenes y se pueden desplegar.
function Wait-CloudBuilds($Items) {
    $targets = @($Items | Where-Object { $_.State -like 'validado*' -or $_.State -like 'validación*' })
    if (-not $targets.Count) { return }
    Write-Step 'Fase 6: Cloud Build (imágenes por digest)'
    if (-not (Get-Command gcloud -ErrorAction SilentlyContinue) -or -not $script:Cfg.mgmt -or -not $script:Cfg.region) {
        Write-Note 'sin gcloud o sin $mgmt/$region en .env.ps1: no se comprueba Cloud Build'
        foreach ($i in $targets) { $i | Add-Member -NotePropertyName Build -NotePropertyValue 'sin comprobar' -Force }
        return
    }
    $pending = $targets
    $started = Get-Date
    $announced = @{}
    while ($pending.Count -gt 0) {
        foreach ($i in @($pending)) {
            $trigger = $Components[$i.Key].Trigger
            $build = Get-TagBuild $trigger $i.Version
            if (-not $build) {
                if (((Get-Date) - $started).TotalMinutes -ge 10) {
                    $i | Add-Member -NotePropertyName Build -NotePropertyValue 'no arrancó' -Force
                    Write-Bad "$($i.Label): $trigger no arrancó con $($i.Version) en 10 minutos (¿triggers deshabilitados?)"
                    Write-Info "Lánzalo a mano: gcloud builds triggers run $trigger --region=$($script:Cfg.region) --project=$($script:Cfg.mgmt) --tag=$($i.Version)"
                    $pending = @($pending | Where-Object { $_ -ne $i })
                }
                continue
            }
            if (-not $announced.ContainsKey($i.Key)) { $announced[$i.Key] = $true; Write-Info "$($i.Label): $trigger $($build.logUrl)" }
            if ($CloudBuildFinal -notcontains $build.status) {
                Write-Info ("{0:HH:mm} {1}: {2} {3}" -f (Get-Date), $i.Label, $trigger, $build.status)
                continue
            }
            if ($build.status -eq 'SUCCESS') {
                $i | Add-Member -NotePropertyName Build -NotePropertyValue 'imágenes publicadas' -Force
                Write-Ok "$($i.Label): $trigger terminó en SUCCESS (imágenes y evidencia publicadas)"
            } else {
                $i | Add-Member -NotePropertyName Build -NotePropertyValue "Cloud Build $($build.status)" -Force
                $i.Detail = ($i.Detail + " $trigger $($build.status)").Trim()
                Write-Bad "$($i.Label): $trigger terminó en $($build.status)"
                Show-BuildFailure $build
            }
            $pending = @($pending | Where-Object { $_ -ne $i })
        }
        if ($pending.Count -gt 0) {
            if (((Get-Date) - $started).TotalMinutes -ge 120) { throw 'Cloud Build sigue en curso después de 2 horas; revisa gcloud builds list.' }
            Start-Sleep -Seconds $PollSeconds
        }
    }
}

function Test-Deployable($Item) {
    $Item.State -like 'validado*' -and ((-not $Item.PSObject.Properties['Build']) -or $Item.Build -in 'imágenes publicadas', 'sin comprobar')
}

function Invoke-Release {
    $system = Get-SystemVersion
    $items = Invoke-ReleasePhases $system
    if (-not $items) { return }
    if (-not $SkipCloudBuild) { Wait-CloudBuilds $items }

    # La plataforma apunta a los tags publicados, validados y con imágenes.
    $published = @($items | Where-Object { Test-Deployable $_ } | ForEach-Object { @{ Key = $_.Key; Tag = $_.Version } })
    if ($published.Count -and -not $SkipPlatform) { Sync-Platform $published }

    Show-Summary $items
    foreach ($i in $items | Where-Object { $_.PSObject.Properties['Build'] }) { Write-Info ("{0,-13} Cloud Build: {1}" -f $i.Label, $i.Build) }
    $backend = $items | Where-Object { $_.Key -eq 'backend' -and (Test-Deployable $_) }
    $frontend = $items | Where-Object { $_.Key -eq 'frontend' -and (Test-Deployable $_) }
    $failed = @($items | Where-Object { $_.PSObject.Properties['Build'] -and $_.Build -notin 'imágenes publicadas', 'sin comprobar' })
    if ($failed.Count) {
        Write-Info ''
        Write-Info 'Las versiones sin imágenes no se pueden desplegar: corrige en develop y publica una versión nueva (-Bump patch).'
    }
    if ($backend -or $frontend) {
        Write-Info ''
        Write-Info 'Siguiente: si es la primera release, crea Cloud Run con .\scripts\sportapp-gcp.ps1 setup; después despliega con:'
        $promoteArgs = @()
        if ($backend) { $promoteArgs += "-BackendVersion $($backend.Version)" }
        if ($frontend) { $promoteArgs += "-FrontendVersion $($frontend.Version)"; if (-not $backend) { $promoteArgs += '-BackendVersion <versión backend desplegada>' } }
        Write-Info ".\scripts\sportapp-gcp.ps1 promote $($promoteArgs -join ' ')"
    }
}

# Cloud Build de tags ya publicados: el indicado o el último estable de cada repo.
function Invoke-BuildsCommand {
    $items = foreach ($key in $Repos) {
        $tag = @{ backend = $BackendVersion; frontend = $FrontendVersion }[$key]
        if (-not $tag) { $tag = Get-LatestStable (Get-Tags (Get-RepoName $key)) }
        if (-not $tag) { Write-Note "$($Components[$key].Label): sin releases; se omite"; continue }
        [pscustomobject]@{ Key = $key; Label = $Components[$key].Label; Version = $tag; State = 'validado'; Detail = '' }
    }
    $items = @($items)
    if (-not $items.Count) { return }
    Wait-CloudBuilds $items
    $ready = @($items | Where-Object { $_.Build -eq 'imágenes publicadas' })
    if ($ready.Count -eq $items.Count) {
        Write-Host ''
        Write-Host 'Imágenes publicadas. Siguiente: .\scripts\sportapp-gcp.ps1 setup (primera vez) o promote.' -ForegroundColor Green
    } elseif ($items | Where-Object { $_.Build -like 'Cloud Build*' }) {
        throw 'Hay builds fallidos (detalle arriba): corrige en develop y publica una versión nueva con release -Bump patch.'
    }
}

Invoke-Main @{
    check      = { Invoke-Check }
    status     = { Invoke-Status }
    prepare    = { Invoke-Prepare }
    release    = { Invoke-Release }
    builds     = { Invoke-BuildsCommand }
    submodules = { Invoke-SubmodulesCommand }
}
