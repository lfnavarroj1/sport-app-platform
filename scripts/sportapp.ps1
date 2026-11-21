<#
.SYNOPSIS
    Menú único de SportApp: Strava guiado, releases automatizados y despliegue.

.DESCRIPTION
    Punto de entrada delgado. No duplica lo existente: GCP se delega en
    sportapp-gcp.ps1 y los releases en sportapp-release.ps1, ambos invocados con
    parámetros. Lo propio es el flujo LOCAL (Docker Desktop + Terraform), el
    asistente de Strava y la tableta física.

    Sin argumentos muestra el menú:

      1  Integración con Strava: asistente paso a paso (Local o GCP).
      2  Lanzar releases: secuencia check -> release del componente ->
         submódulos/manifiesto -> release de plataforma, con una confirmación
         por etapa, y comandos sueltos de sportapp-release.ps1.
      3  Desplegar la versión actual y actualizar (Local o GCP).
      0  Salir

    Subcomandos no interactivos equivalentes:

      strava   -Environment local|gcp [-FromStep n]
      release  sequence | check | status | builds | release | hotfix | apk | submodules | prepare | keystore
      deploy   -Environment local  check | build | plan | apply | update
               -Environment gcp    plan | status | images | up | promote | down

    Toda acción que crea, cambia o destruye pide escribir 'si'. Nada se aplica
    automáticamente. Los secretos se piden por terminal, viajan por stdin y nunca
    se imprimen ni se guardan. Local usa solo el contexto docker-desktop; GCP
    nunca lo usa. La tableta es solo el dispositivo físico R52NB04LMCB. Con
    -DryRun se imprimen los comandos sin ejecutarlos (ni pedir secretos).

    Instrucciones: docs/guia-menu-sportapp.md.

.EXAMPLE
    .\scripts\sportapp.ps1

.EXAMPLE
    .\scripts\sportapp.ps1 strava -Environment local -DryRun

.EXAMPLE
    .\scripts\sportapp.ps1 release sequence -Target backend -DryRun

.EXAMPLE
    .\scripts\sportapp.ps1 deploy update -Environment local -Component bff-mobile
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'strava', 'release', 'deploy', 'help')]
    [string]$Area = 'menu',

    [Parameter(Position = 1)]
    [string]$Action,

    # Ambiente de strava y deploy.
    [ValidateSet('local', 'gcp')]
    [string]$Environment,

    # strava: continúa el asistente desde ese paso (1 a 6).
    [ValidateRange(1, 6)]
    [int]$FromStep = 1,

    # deploy update (local): componente a reconstruir y reiniciar; por defecto all.
    [ValidateSet('all', 'users-management', 'affiliation-management', 'complementary-services', 'training-management', 'events-management', 'third-party-management', 'bff-web', 'bff-mobile', 'web')]
    [string]$Component = 'all',

    # Imprime los comandos sin ejecutarlos; no pide secretos ni confirmaciones.
    [switch]$DryRun,

    # Solo con -DryRun: respuestas simuladas del usuario ('<enter>' = Enter), para probar los menús y el asistente.
    [string[]]$SimulatedInput,

    # deploy plan/apply (local): incluye -var strava_integration_enabled=true.
    [switch]$Strava,

    # Rutas de los componentes; por defecto, carpetas hermanas de platform.
    [string]$BackendPath,
    [string]$FrontendPath,
    [string]$MobilePath,

    # Parámetros que se reenvían a sportapp-release.ps1 / sportapp-gcp.ps1.
    [ValidateSet('backend', 'backend-frontend', 'frontend', 'mobile', 'platform', 'all')]
    [string]$Target,
    [ValidateSet('patch', 'minor', 'major')]
    [string]$Bump,
    [string]$BackendVersion,
    [string]$FrontendVersion,
    [string]$MobileVersion,
    [string]$PlatformVersion,
    [string]$SystemVersion,
    [string[]]$Stories,
    [string]$Sprint,
    [string]$ReleaseSuffix,
    [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'

# --- Rutas y constantes -------------------------------------------------------

$PlatformRoot = Split-Path -Parent $PSScriptRoot
$LocalRoot = Join-Path $PlatformRoot 'infra\terraform\environments\local'
$ProductionRoot = Join-Path $PlatformRoot 'infra\terraform\environments\production'
$WorkloadsRoot = Join-Path $PlatformRoot 'infra\terraform\environments\production-workloads'
$GcpScript = Join-Path $PSScriptRoot 'sportapp-gcp.ps1'
$ReleaseScript = Join-Path $PSScriptRoot 'sportapp-release.ps1'
if (-not $BackendPath) { $BackendPath = Join-Path (Split-Path -Parent $PlatformRoot) 'backend' }
if (-not $FrontendPath) { $FrontendPath = Join-Path (Split-Path -Parent $PlatformRoot) 'frontend' }
if (-not $MobilePath) { $MobilePath = Join-Path (Split-Path -Parent $PlatformRoot) 'movil' }

# Contexto único del flujo local. El flujo GCP nunca lo usa y el local nunca usa gke_*.
$LocalContext = 'docker-desktop'
$LocalNamespace = 'sportapp-local'
$StravaSecret = 'sportapp-third-party'
$TabletSerial = 'R52NB04LMCB'
$TabletBffUrl = 'http://localhost:18081/'
$MobilePackage = 'com.lfnj.sport_app'
$PubSubEmulator = 'http://localhost:18085/v1/projects/sportapp-local'

$script:DryRun = [bool]$DryRun
$script:Bound = $PSBoundParameters
# Respuestas simuladas (solo con -DryRun); '<enter>' equivale a Enter.
$script:Simulated = New-Object System.Collections.Queue
foreach ($x in @(if ($SimulatedInput) { $SimulatedInput | ForEach-Object { $_ -split ',' } })) { if ($x -eq '<enter>') { $script:Simulated.Enqueue('') } else { $script:Simulated.Enqueue($x) } }

# --- Salida y confirmaciones --------------------------------------------------

function Write-Step([string]$Text) { Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [ok]    $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "  [aviso] $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host "  [falta] $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "          $Text" }

# Toda acción que crea, cambia o destruye pasa por aquí: solo 'si' continúa.
function Confirm-Si([string]$Question) {
    if ($script:DryRun) { Write-Info "[dry-run] se pediría confirmación escrita 'si': $Question"; return }
    $answer = Read-Host "$Question Escribe 'si' para continuar"
    if ($answer -ne 'si') { throw 'Cancelado por el operador; no se hizo nada.' }
}

# --- Comandos externos --------------------------------------------------------

# Ejecuta (o, con -DryRun, imprime) un comando nativo. -Capture devuelve la
# salida; -AllowFailure no lanza error con código distinto de 0. -InputText se
# envía por stdin (secretos): nunca se muestra, ni siquiera en DryRun.
function Invoke-Native {
    param(
        [string]$Exe,
        [string[]]$Arguments = @(),
        [string]$WorkDir,
        [switch]$Capture,
        [switch]$AllowFailure,
        [string]$InputText,
        [string]$Display
    )
    $text = if ($Display) { $Display } else { "$Exe $($Arguments -join ' ')" }
    if ($script:DryRun) {
        $where = if ($WorkDir) { " (en $WorkDir)" } else { '' }
        Write-Host "  [dry-run] $text$where" -ForegroundColor DarkGray
        return $null
    }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    if ($WorkDir) { Push-Location -LiteralPath $WorkDir }
    try {
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $InputText | & $Exe @Arguments 2>&1 | Out-Host
            $code = $LASTEXITCODE
            $result = $null
        } elseif ($Capture) {
            $all = & $Exe @Arguments 2>&1
            $code = $LASTEXITCODE
            $result = (@($all | ForEach-Object { "$_" }) -join "`n").Trim()
        } else {
            & $Exe @Arguments 2>&1 | Out-Host
            $code = $LASTEXITCODE
            $result = $null
        }
    } finally {
        if ($WorkDir) { Pop-Location }
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0 -and -not $AllowFailure) { throw "Falló (código ${code}): $text" }
    if ($Capture) { return [pscustomobject]@{ ExitCode = $code; Output = $result } }
}

# Todo kubectl local pasa por aquí: contexto fijo docker-desktop, jamás gke_*.
function Invoke-Kube {
    param([string[]]$Arguments, [switch]$Capture, [switch]$AllowFailure, [string]$InputText, [string]$Display)
    if ($Arguments | Where-Object { $_ -match '^(--context=)?gke_' }) { throw 'El flujo local no usa contextos gke_*.' }
    if ($Arguments | Where-Object { $_ -match '^--context' }) { throw 'El contexto de kubectl lo fija el menú (docker-desktop); no se admite otro.' }
    $full = @('--context', $LocalContext, '--namespace', $LocalNamespace) + $Arguments
    $params = @{ Exe = 'kubectl'; Arguments = $full; Capture = $Capture; AllowFailure = $AllowFailure }
    if ($PSBoundParameters.ContainsKey('InputText')) { $params.InputText = $InputText }
    if ($Display) { $params.Display = $Display }
    Invoke-Native @params
}

function Invoke-Terraform {
    param([string[]]$Arguments, [switch]$Capture, [switch]$AllowFailure)
    # Solo la raíz local: nunca producción ni bootstrap.
    if ((Split-Path -Leaf $LocalRoot) -ne 'local' -or (Split-Path -Leaf (Split-Path -Parent $LocalRoot)) -ne 'environments') { throw 'La raíz de Terraform local es inválida.' }
    Invoke-Native -Exe 'terraform' -Arguments (@("-chdir=$LocalRoot") + $Arguments) -Capture:$Capture -AllowFailure:$AllowFailure
}

function Test-Tool([string]$Name, [string]$Hint) {
    if (Get-Command $Name -ErrorAction SilentlyContinue) { Write-Ok $Name } else { Write-Bad "$Name no está en el PATH. $Hint"; return $false }
    $true
}

# --- Delegación en los scripts existentes ------------------------------------

# Invoca el script por parámetros (no copia su código). Un 'exit' del hijo solo
# termina al hijo; el código queda en $LASTEXITCODE.
function Invoke-Child([string]$Path, [hashtable]$Params) {
    $shown = ($Params.GetEnumerator() | Sort-Object Name | ForEach-Object { if ($_.Value -is [bool] -or $_.Value -is [System.Management.Automation.SwitchParameter]) { "-$($_.Key)" } else { "-$($_.Key) $($_.Value -join ',')" } }) -join ' '
    $label = ".\scripts\$(Split-Path -Leaf $Path) $shown"
    if ($script:DryRun) { Write-Host "  [dry-run] $label" -ForegroundColor DarkGray; return }
    $global:LASTEXITCODE = 0
    & $Path @Params
    if ($LASTEXITCODE -ne 0) { throw "$(Split-Path -Leaf $Path) terminó con código $LASTEXITCODE." }
}

# Reenvía solo los parámetros que el operador indicó.
function Get-Forwarded([string[]]$Names) {
    $map = @{}
    foreach ($name in $Names) { if ($script:Bound.ContainsKey($name)) { $map[$name] = $script:Bound[$name] } }
    $map
}

function Show-GcpIdentity {
    Write-Step 'Cuenta y proyecto de gcloud activos'
    if ($script:DryRun) {
        Invoke-Native -Exe 'gcloud' -Arguments @('config', 'get-value', 'account')
        Invoke-Native -Exe 'gcloud' -Arguments @('config', 'get-value', 'project')
        return
    }
    if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) { throw 'gcloud no está instalado; la opción GCP lo necesita.' }
    $account = Invoke-Native -Exe 'gcloud' -Arguments @('config', 'get-value', 'account', '--quiet') -Capture -AllowFailure
    $project = Invoke-Native -Exe 'gcloud' -Arguments @('config', 'get-value', 'project', '--quiet') -Capture -AllowFailure
    Write-Info "Cuenta : $(if ($account.Output) { ($account.Output -split "`n")[0] } else { '(ninguna)' })"
    Write-Info "Proyecto: $(if ($project.Output) { ($project.Output -split "`n")[0] } else { '(ninguno)' })"
    Write-Note 'GCP usa Cloud Deploy, Cloud Run, GKE y Pub/Sub administrado; nunca el clúster de Docker Desktop ni el emulador de Pub/Sub.'
}

function Invoke-Gcp([string]$Verb) {
    $verbs = @('plan', 'status', 'images', 'up', 'promote', 'down')
    if ($verbs -notcontains $Verb) { throw "Acción GCP inválida '$Verb'. Opciones: $($verbs -join ', ')." }
    Show-GcpIdentity
    $params = @{}
    $forward = Get-Forwarded @('ConfigFile', 'BackendVersion', 'FrontendVersion', 'ReleaseSuffix')
    foreach ($k in $forward.Keys) { $params[$k] = $forward[$k] }
    if ($Verb -eq 'plan') {
        # sportapp-gcp.ps1 no tiene un comando de solo plan: up/down muestran su plan
        # y piden confirmación. check -Validate es lo más cercano sin efectos.
        Write-Note 'No existe un plan aislado en sportapp-gcp.ps1; se ejecuta check -Validate (no cambia nada). up y down muestran su plan antes de aplicar.'
        $params.Command = 'check'; $params.Validate = $true
    } else { $params.Command = $Verb }
    if ($Verb -in @('up', 'promote', 'down')) {
        Confirm-Si "GCP: '$Verb' crea, modifica o destruye recursos reales."
    }
    # Nunca se reenvía -AutoApprove: el script de GCP conserva sus propias confirmaciones.
    Invoke-Child $GcpScript $params
}

# Comandos sueltos de sportapp-release.ps1. Los de solo lectura no piden 'si'.
function Invoke-Release([string]$Verb) {
    $verbs = @('check', 'status', 'builds', 'release', 'hotfix', 'apk', 'submodules', 'prepare', 'keystore')
    if ($verbs -notcontains $Verb) { throw "Acción de release inválida '$Verb'. Opciones: sequence, $($verbs -join ', ')." }
    $params = Get-Forwarded @('Target', 'Bump', 'BackendVersion', 'FrontendVersion', 'MobileVersion', 'PlatformVersion', 'SystemVersion', 'Stories', 'Sprint', 'ConfigFile')
    $params.Command = $Verb
    if ($Verb -in @('release', 'hotfix', 'apk', 'submodules', 'prepare', 'keystore')) {
        Confirm-Si "Releases: '$Verb' publica o modifica repositorios, tags o artefactos."
    }
    # Sin -AutoApprove: las confirmaciones del script de releases se conservan.
    Invoke-Child $ReleaseScript $params
}

# Secuencia recomendada con una confirmación 'si' por etapa. Dentro de cada etapa
# se pasa -AutoApprove (confirmaciones de rutina); la aprobación de cada PR sigue
# siendo humana porque sportapp-release.ps1 siempre la pregunta.
function Invoke-ReleaseSequence {
    $components = @('backend', 'backend-frontend', 'frontend', 'mobile')
    $comp = $Target
    if (-not $comp) {
        if ($script:DryRun) { throw 'Indica -Target (backend, backend-frontend, frontend o mobile) para la secuencia.' }
        $comp = Read-Choice 'Componente a publicar' @(
            @{ Label = 'Solo backend'; Value = 'backend' }, @{ Label = 'Backend y frontend'; Value = 'backend-frontend' },
            @{ Label = 'Solo frontend'; Value = 'frontend' }, @{ Label = 'Solo aplicación móvil'; Value = 'mobile' })
        if (-not $comp) { return }
    }
    if ($components -notcontains $comp) { throw "La secuencia admite -Target: $($components -join ', ')." }
    $common = Get-Forwarded @('ConfigFile')
    $stages = @(
        @{ Name = '1/4 check de componente y plataforma'; Mutating = $false; Calls = @(
            @{ Command = 'check'; Target = $comp }, @{ Command = 'check'; Target = 'platform' }) }
        @{ Name = "2/4 release del componente ($comp), sin mover la plataforma"; Mutating = $true; Calls = @(
            @{ Command = 'release'; Target = $comp; SkipPlatform = $true; Forward = @('Bump', 'BackendVersion', 'FrontendVersion', 'MobileVersion', 'SystemVersion') }) }
        @{ Name = '3/4 submódulos y release-manifest.yaml'; Mutating = $true; Calls = @(
            @{ Command = 'submodules'; Target = $comp }) }
        @{ Name = '4/4 release de la plataforma (versión del sistema)'; Mutating = $true; Calls = @(
            @{ Command = 'release'; Target = 'platform'; Forward = @('Bump', 'PlatformVersion', 'Stories', 'Sprint') }) }
    )
    foreach ($stage in $stages) {
        Write-Step "Releases: etapa $($stage.Name)"
        if ($stage.Mutating) { Confirm-Si "Etapa '$($stage.Name)': publica o modifica repositorios, tags o artefactos." }
        foreach ($call in $stage.Calls) {
            $params = @{} + $common
            $params.Command = $call.Command; $params.Target = $call.Target
            if ($call.SkipPlatform) { $params.SkipPlatform = $true }
            if ($call.Forward) { foreach ($k in (Get-Forwarded $call.Forward).GetEnumerator()) { $params[$k.Key] = $k.Value } }
            if ($stage.Mutating) { $params.AutoApprove = $true }
            Invoke-Child $ReleaseScript $params
        }
    }
    Write-Ok 'Secuencia completa. El despliegue se hace después con la opción 3 (GCP: promote).'
}

# --- LOCAL --------------------------------------------------------------------

function Invoke-LocalCheck {
    Write-Step 'Local: prerrequisitos (solo lectura)'
    if ($script:DryRun) {
        Invoke-Native -Exe 'docker' -Arguments @('version', '--format', 'Cliente {{.Client.Version}} / Servidor {{.Server.Version}}')
        Invoke-Native -Exe 'kubectl' -Arguments @('config', 'get-contexts', '-o', 'name')
        Invoke-Native -Exe 'kubectl' -Arguments @('--context', $LocalContext, 'get', 'nodes', '-o', 'wide')
        Invoke-Native -Exe 'terraform' -Arguments @('version')
        Invoke-Native -Exe 'py' -Arguments @('-3.13', '-m', 'uv', '--version')
        Invoke-Native -Exe 'git' -Arguments @('-C', $BackendPath, 'branch', '--show-current')
        return
    }
    $ok = $true
    $ok = (Test-Tool 'docker' 'Instala Docker Desktop.') -and $ok
    $ok = (Test-Tool 'kubectl' 'winget install --id Kubernetes.kubectl -e') -and $ok
    $ok = (Test-Tool 'terraform' 'winget install --id Hashicorp.Terraform -e') -and $ok
    $ok = (Test-Tool 'git' 'winget install --id Git.Git -e') -and $ok
    $ok = (Test-Tool 'py' 'Instala Python 3.13 y uv.') -and $ok
    if (-not $ok) { throw 'Faltan herramientas.' }
    $docker = Invoke-Native -Exe 'docker' -Arguments @('version', '--format', '{{.Server.Version}}') -Capture -AllowFailure
    if ($docker.ExitCode -eq 0) { Write-Ok "Docker Desktop activo (servidor $($docker.Output))" } else { Write-Bad 'Docker Desktop no responde; ábrelo y espera Engine running.'; $ok = $false }
    $contexts = Invoke-Native -Exe 'kubectl' -Arguments @('config', 'get-contexts', '-o', 'name') -Capture -AllowFailure
    if (($contexts.Output -split "`n") -contains $LocalContext) { Write-Ok "Contexto kubectl $LocalContext" } else { Write-Bad "No existe el contexto ${LocalContext}: activa Kubernetes (kubeadm) en Docker Desktop."; $ok = $false }
    $nodes = Invoke-Native -Exe 'kubectl' -Arguments @('--context', $LocalContext, 'get', 'nodes', '--no-headers') -Capture -AllowFailure
    if ($nodes.ExitCode -eq 0 -and $nodes.Output -match 'Ready') { Write-Ok 'Nodo docker-desktop Ready' } else { Write-Bad 'El nodo docker-desktop no está Ready.'; $ok = $false }
    if (Test-Path -LiteralPath (Join-Path $LocalRoot 'main.tf')) { Write-Ok "Raíz Terraform local: $LocalRoot" } else { Write-Bad "No se encontró $LocalRoot"; $ok = $false }
    foreach ($item in @(@{ N = 'backend'; P = $BackendPath }, @{ N = 'frontend'; P = $FrontendPath })) {
        if (-not (Test-Path -LiteralPath $item.P)) { Write-Bad "No existe $($item.N): $($item.P) (usa -$(([string]$item.N).Substring(0,1).ToUpper() + ([string]$item.N).Substring(1))Path)"; $ok = $false; continue }
        $branch = Invoke-Native -Exe 'git' -Arguments @('-C', $item.P, 'branch', '--show-current') -Capture -AllowFailure
        if ($item.N -eq 'backend' -and $branch.Output -ne 'develop') { Write-Bad "El backend está en '$($branch.Output)', se requiere develop (incluye strava-integration)."; $ok = $false }
        else { Write-Ok "$($item.N) en '$($branch.Output)'" }
    }
    if (-not $ok) { throw 'Prerrequisitos locales incompletos.' }
}

function Invoke-LocalBuild {
    Write-Step 'Local: construir imágenes sportapp/* (Docker local compartido con kubeadm)'
    Confirm-Si 'Se construirán las 8 imágenes del backend y la imagen web (puede tardar).'
    Invoke-Native -Exe 'py' -Arguments @('-3.13', '-m', 'uv', 'run', 'python', 'scripts/task.py', 'build', 'all') -WorkDir $BackendPath
    Invoke-Native -Exe 'docker' -Arguments @('build', '-t', 'sportapp/web:local', '.') -WorkDir $FrontendPath
    Invoke-Native -Exe 'docker' -Arguments @('images', 'sportapp/*')
}

function Get-LocalVarArgs([bool]$WithStrava) {
    if ($WithStrava) { return @('-var', 'strava_integration_enabled=true') }
    @()
}

# ¿Strava ya está desplegado? Un plan sin la bandera lo desactivaría.
function Test-StravaDeployed {
    if ($script:DryRun) { return $false }
    $r = Invoke-Kube -Arguments @('get', 'deployment', 'third-party-management', '--no-headers') -Capture -AllowFailure
    $r.ExitCode -eq 0
}

function Invoke-LocalPlan([bool]$WithStrava, [string]$PlanFile = 'tfplan') {
    Write-Step "Local: terraform plan ($PlanFile)"
    if (-not $WithStrava -and (Test-StravaDeployed)) {
        Write-Note 'Strava ya está desplegado: se incluye -var strava_integration_enabled=true para no desactivarlo.'
        $WithStrava = $true
    }
    Invoke-Terraform @('init', '-input=false')
    Invoke-Terraform @('validate')
    Invoke-Terraform (@('plan', '-input=false', "-out=$PlanFile") + (Get-LocalVarArgs $WithStrava))
    Invoke-Terraform @('show', $PlanFile)
}

function Invoke-LocalApply([bool]$WithStrava) {
    if ($WithStrava) { Assert-StravaSecret }
    Invoke-LocalPlan $WithStrava
    Write-Note 'Revisa el plan de arriba. Nada se aplica sin tu confirmación.'
    Confirm-Si "terraform apply sobre $LocalRoot (Docker Desktop, namespace $LocalNamespace)."
    Invoke-Terraform @('apply', '-input=false', 'tfplan')
    Invoke-LocalStatus
}

function Invoke-LocalStatus {
    Write-Step "Local: estado (contexto $LocalContext, namespace $LocalNamespace)"
    Invoke-Kube -Arguments @('get', 'pods,jobs') -AllowFailure
    foreach ($e in @(@{ N = 'bff-web'; U = 'http://localhost:18080/health/ready' }, @{ N = 'bff-mobile'; U = 'http://localhost:18081/health/ready' }, @{ N = 'web'; U = 'http://localhost:18082/healthz' })) {
        if ($script:DryRun) { Write-Host "  [dry-run] GET $($e.U)" -ForegroundColor DarkGray; continue }
        try { $r = Invoke-WebRequest -Uri $e.U -UseBasicParsing -TimeoutSec 8; Write-Ok "$($e.N) $($e.U) -> $($r.StatusCode)" }
        catch { Write-Bad "$($e.N) $($e.U) no responde" }
    }
    foreach ($kind in @('topics', 'subscriptions')) {
        if ($script:DryRun) { Write-Host "  [dry-run] GET $PubSubEmulator/$kind" -ForegroundColor DarkGray; continue }
        try {
            $r = Invoke-RestMethod -Uri "$PubSubEmulator/$kind" -TimeoutSec 8
            $names = @($r.$kind | ForEach-Object { ($_.name -split '/')[-1] })
            Write-Ok "Pub/Sub emulador (solo local) $kind`: $(if ($names.Count) { $names -join ', ' } else { '(ninguno)' })"
        } catch { Write-Note "Emulador Pub/Sub no responde en $PubSubEmulator ($kind)." }
    }
}

# --- STRAVA: textos del asistente (editar aquí; sin lógica) -------------------
#
# Cada paso tiene Titulo, Que, Donde, Valores (lista de líneas), Ok y Falla. Un
# valor puede ser un texto o @{ local = '...'; gcp = '...' } para adaptarlo al
# ambiente. Marcadores: {DOMAIN} dominio de callback, {CALLBACK} URI completa,
# {BFFURL} URL base de bff-mobile, {PROJECT} proyecto activo de gcloud.

$StravaSteps = @(
    @{
        Titulo  = 'Crear la aplicación en Strava'
        Que     = 'Registra la aplicación OAuth de SportApp en tu cuenta de Strava.'
        Donde   = 'https://www.strava.com/settings/api (inicia sesión con la cuenta de Strava que usarás en la tableta; la aplicación nueva admite pocos atletas).'
        Valores = @(
            'Application Name = SportApp (o el nombre que prefieras)',
            'Category = Training (o la más cercana)',
            'Club = vacío',
            'Website = http://localhost',
            'Application Description = Prueba de integración de SportApp',
            @{ local = 'Authorization Callback Domain = localhost (sin http:// ni ruta)'; gcp = 'Authorization Callback Domain = {DOMAIN} (dominio de bff-mobile en Cloud Run, sin https:// ni ruta; callback completo: {CALLBACK})' },
            'Icono = sube cualquier imagen PNG o JPG',
            'Pulsa Create (o Update si la aplicación ya existe).')
        Ok      = 'La página muestra Client ID (un número) y Client Secret. Cópialos para el paso 2; no los pegues en chats ni en Git.'
        Falla   = 'Si Strava rechaza el dominio o muestra error de callback, ve al paso 6 (plan B con túnel HTTPS).'
    },
    @{
        Titulo  = 'Cargar los secretos'
        Que     = @{ local = 'El menú te pide Client ID y Client Secret, genera STRAVA_TOKEN_KEY (AES 32 bytes) y crea el Secret sportapp-third-party en Docker Desktop.'; gcp = 'El menú te pide Client ID y Client Secret, genera STRAVA_TOKEN_KEY (AES 32 bytes) y añade una versión a strava-client-id, strava-client-secret y strava-token-key en Secret Manager.' }
        Donde   = @{ local = 'Esta terminal. Se usa kubectl con el contexto docker-desktop y el namespace sportapp-local.'; gcp = 'Esta terminal. Se usa gcloud secrets versions add en el proyecto activo ({PROJECT}); debe ser el de PRODUCCIÓN.' }
        Valores = @(
            'STRAVA_CLIENT_ID = el Client ID (número) del paso 1',
            'STRAVA_CLIENT_SECRET = el Client Secret del paso 1 (se escribe oculto)',
            'STRAVA_TOKEN_KEY = la genera el menú; no escribas nada',
            "Escribe 'si' cuando se pida confirmar.")
        Ok      = 'El menú comprueba que el Secret (local) o las versiones (GCP) existen, sin mostrar valores. La clave no se vuelve a mostrar: si reemplazas el Secret, cada deportista debe vincular de nuevo.'
        Falla   = @{ local = 'Si falta el namespace, aplica primero el ambiente local (opción 3 > apply). Si kubectl no responde, abre Docker Desktop.'; gcp = 'Si gcloud responde permiso denegado, revisa la cuenta y el proyecto mostrados arriba (gcloud auth login / gcloud config set project).' }
    },
    @{
        Titulo  = 'Activar la integración'
        Que     = @{ local = 'terraform apply con strava_integration_enabled=true: migra la base terceros y despliega third-party-management, publicador, worker y consumidor.'; gcp = 'terraform apply en production-workloads con sync_strava_secret=true: copia el Secret sportapp-third-party a GKE.' }
        Donde   = @{ local = 'Esta terminal, raíz infra/terraform/environments/local.'; gcp = 'Esta terminal, raíz infra/terraform/environments/production-workloads (ya inicializada por sportapp-gcp.ps1).' }
        Valores = @('Revisa el plan que se muestra y escribe «si» solo si es lo esperado.', 'Espera: el apply puede tardar varios minutos hasta que los pods quedan listos.')
        Ok      = @{ local = 'Pods Running (third-party-management, outbox-publisher, sync-worker y training-management-external-activity-consumer) y job third-party-management-migrate-main Complete.'; gcp = 'El apply termina sin errores; el estado de GKE se revisa con la opción 3 > status.' }
        Falla   = 'third-party-management 0/1: falta el Secret o STRAVA_REDIRECT_URI; mira «kubectl describe pod» y los logs (paso 6).'
    },
    @{
        Titulo  = 'Conectar la tableta y vincular Strava'
        Que     = 'Conecta la tableta física, instala el APK de depuración y vincula tu cuenta de Strava desde la app.'
        Donde   = @{ local = 'La tableta Samsung SM-T970, serie R52NB04LMCB, por USB (jamás un emulador). El menú ejecuta adb reverse tcp:18081 y compila e instala el APK con -Psportapp.bffMobileBaseUrl.debug=http://localhost:18081/.'; gcp = 'La tableta Samsung SM-T970, serie R52NB04LMCB, por USB (jamás un emulador). El menú compila e instala el APK apuntando a {BFFURL}.' }
        Valores = @(
            'Activa Opciones de desarrollador > Depuración USB en la tableta.',
            'Conecta el cable y acepta «Permitir depuración USB» (marca «Permitir siempre»).',
            "Cuando el menú lo pida, escribe 'si' para compilar e instalar.",
            'Abre la app SportApp > menú Strava > «Conectar con Strava».',
            'Acepta el consentimiento de la app y en la página de Strava pulsa «Authorize».')
        Ok      = 'La tableta aparece como «device» en adb; al autorizar, la app vuelve por sportapp://integrations/strava?result=LINKED y el menú comprueba external_account (local).'
        Falla   = 'Sin dispositivo: cambia de cable o puerto y acepta de nuevo la depuración. result=INVALID_STATE o ERROR: ve al paso 6.'
    },
    @{
        Titulo  = 'Sincronizar y comprobar los datos'
        Que     = 'Importa tus actividades de Strava y comprueba que llegan al historial.'
        Donde   = 'En la app y en esta terminal.'
        Valores = @(
            'En la app pulsa «Sincronizar ahora» (el backend responde 202 con sync_run_id).',
            'Abre el historial y el tablero «Importadas de Strava»: deben verse las actividades.',
            'El menú consulta la base y los mensajes: sync_run, imported_activity, evento actividad.importada.v1 en la suscripción y source = STRAVA en training_session_history.')
        Ok      = 'Los conteos de sync_run e imported_activity suben y el historial muestra actividades con source = STRAVA.'
        Falla   = '0 actividades: confirma que tu cuenta de Strava tiene actividades recientes y mira el paso 6.'
    }
)

$StravaTroubleshooting = @(
    @{ Sintoma = 'Strava rechaza el dominio de callback'; Causa = 'localhost no aceptado por la aplicación'; Accion = 'Plan B: abre un túnel HTTPS hacia localhost:18081, registra su dominio en Strava y aplica con -var strava_redirect_uri=https://<dominio-del-túnel>/v1/integrations/strava/callback (guía sección 3).' },
    @{ Sintoma = 'La app vuelve con result=INVALID_STATE o result=ERROR'; Causa = 'STRAVA_REDIRECT_URI distinto del registrado, o sesión de vinculación caducada'; Accion = 'Compara el callback del paso 1 con terraform output strava; repite «Conectar con Strava» y autoriza de nuevo.' },
    @{ Sintoma = '0 actividades importadas'; Causa = 'cuenta sin actividades, scope no concedido o worker detenido'; Accion = 'Autoriza con read,activity:read; revisa los logs de third-party-management-sync-worker y vuelve a sincronizar.' },
    @{ Sintoma = 'third-party-management 0/1'; Causa = 'falta el Secret sportapp-third-party o STRAVA_REDIRECT_URI/STRAVA_CONSENT_VERSION'; Accion = 'Repite el paso 2 y comprueba con kubectl describe pod y /health/ready (strava_configuration).' },
    @{ Sintoma = 'La tableta no llega al BFF'; Causa = 'se perdió adb reverse al reconectar el cable'; Accion = 'Repite el paso 4 (adb -s R52NB04LMCB reverse tcp:18081 tcp:18081).' },
    @{ Sintoma = 'Los tokens ya no se descifran'; Causa = 'se reemplazó STRAVA_TOKEN_KEY'; Accion = 'Cada deportista debe vincular de nuevo.' }
)

# --- STRAVA: lógica -----------------------------------------------------------

function Assert-StravaSecret {
    if ($script:DryRun) { Invoke-Kube -Arguments @('get', 'secret', $StravaSecret); return }
    $r = Invoke-Kube -Arguments @('get', 'secret', $StravaSecret, '--no-headers') -Capture -AllowFailure
    if ($r.ExitCode -ne 0) { throw "Falta el Secret ${StravaSecret}: cárgalo primero (paso 2 del asistente)." }
    Write-Ok "Secret $StravaSecret presente"
}

function New-TokenKey {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_')
}

# Ejecuta un comando nativo enviando el texto por stdin SIN salto de línea final
# (en Secret Manager "valor\r\n" sería otra clave). El texto nunca se muestra.
function Invoke-NativeStdin([string]$Exe, [string[]]$Arguments, [string]$Text, [string]$Display) {
    if ($script:DryRun) { Write-Host "  [dry-run] $Display" -ForegroundColor DarkGray; return }
    $resolved = (Get-Command $Exe -ErrorAction Stop | Select-Object -First 1).Source
    $quoted = $Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $resolved; $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($Text); $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEnd() + $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($out.Trim()) { Write-Info ($out.Trim()) }
    if ($proc.ExitCode -ne 0) { throw "Falló (código $($proc.ExitCode)): $Display" }
}

# LOCAL: valores por terminal; el Secret viaja como JSON por stdin (sin argv, sin disco).
function Invoke-StravaSecrets {
    Write-Step "Cargar el Secret $StravaSecret en $LocalContext/$LocalNamespace"
    Write-Note 'Los valores no se imprimen, no se guardan y no quedan en el historial.'
    if ($script:DryRun) {
        Invoke-Kube -Arguments @('create', '-f', '-') -InputText '' -Display "kubectl --context $LocalContext --namespace $LocalNamespace create -f -   # Secret $StravaSecret por stdin: STRAVA_CLIENT_ID, STRAVA_CLIENT_SECRET (Read-Host -AsSecureString), STRAVA_TOKEN_KEY (AES 32 bytes base64 url-safe generada); valores no se muestran"
        Confirm-Si "Crear el Secret $StravaSecret."
        return
    }
    $exists = Invoke-Kube -Arguments @('get', 'secret', $StravaSecret, '--no-headers') -Capture -AllowFailure
    if ($exists.ExitCode -eq 0) {
        Write-Note "El Secret $StravaSecret ya existe. Reemplazarlo genera una STRAVA_TOKEN_KEY nueva: los tokens ya guardados no se podrán descifrar y cada deportista debe vincular de nuevo."
        Confirm-Si "Eliminar y recrear $StravaSecret."
    } else { Confirm-Si "Crear el Secret $StravaSecret." }
    $clientId = Read-Host 'STRAVA_CLIENT_ID'
    $secretSecure = Read-Host 'STRAVA_CLIENT_SECRET' -AsSecureString
    $secretPlain = [System.Net.NetworkCredential]::new('', $secretSecure).Password
    if (-not $clientId -or -not $secretPlain) { throw 'STRAVA_CLIENT_ID y STRAVA_CLIENT_SECRET son obligatorios.' }
    $key = New-TokenKey
    $previousEncoding = $OutputEncoding
    try {
        $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $manifest = [ordered]@{
            apiVersion = 'v1'; kind = 'Secret'; type = 'Opaque'
            metadata   = [ordered]@{ name = $StravaSecret; namespace = $LocalNamespace }
            stringData = [ordered]@{ STRAVA_CLIENT_ID = $clientId; STRAVA_CLIENT_SECRET = $secretPlain; STRAVA_TOKEN_KEY = $key }
        } | ConvertTo-Json -Depth 4 -Compress
        if ($exists.ExitCode -eq 0) { Invoke-Kube -Arguments @('delete', 'secret', $StravaSecret) | Out-Null }
        Invoke-Kube -Arguments @('create', '-f', '-') -InputText $manifest -Display "kubectl create -f - (Secret $StravaSecret por stdin; valores ocultos)"
        Write-Ok "Secret $StravaSecret creado. Conserva la clave: no se puede volver a mostrar."
    } finally {
        $OutputEncoding = $previousEncoding
        Remove-Variable clientId, secretSecure, secretPlain, key, manifest -ErrorAction SilentlyContinue
    }
    # Verificación sin valores: solo los nombres de las claves.
    Invoke-Kube -Arguments @('get', 'secret', $StravaSecret, '-o', 'go-template={{range $k, $v := .data}}{{$k}} {{end}}') -AllowFailure
}

function Get-GcpProject {
    if ($script:DryRun) { return '<proyecto-activo>' }
    $r = Invoke-Native -Exe 'gcloud' -Arguments @('config', 'get-value', 'project', '--quiet') -Capture -AllowFailure
    $p = ($r.Output -split "`n")[0].Trim()
    if (-not $p -or $p -match '\(unset\)') { throw 'No hay proyecto activo en gcloud (gcloud config set project <producción>).' }
    $p
}

# GCP: gcloud secrets versions add, valor por stdin; nunca se imprime.
function Invoke-StravaSecretsGcp {
    Write-Step 'Cargar los secretos de Strava en Secret Manager (GCP)'
    Show-GcpIdentity
    $project = Get-GcpProject
    Write-Note 'strava-client-id, strava-client-secret y strava-token-key ya existen vacíos (Terraform); se añade una versión a cada uno.'
    Confirm-Si "Añadir versiones de secretos en el proyecto $project (debe ser el de PRODUCCIÓN)."
    $clientId = $null; $secretPlain = $null; $key = $null
    if (-not $script:DryRun) {
        $clientId = Read-Host 'STRAVA_CLIENT_ID'
        $secretPlain = [System.Net.NetworkCredential]::new('', (Read-Host 'STRAVA_CLIENT_SECRET' -AsSecureString)).Password
        if (-not $clientId -or -not $secretPlain) { throw 'STRAVA_CLIENT_ID y STRAVA_CLIENT_SECRET son obligatorios.' }
        $key = New-TokenKey
    }
    try {
        foreach ($item in @(@{ N = 'strava-client-id'; V = $clientId }, @{ N = 'strava-client-secret'; V = $secretPlain }, @{ N = 'strava-token-key'; V = $key })) {
            Invoke-NativeStdin -Exe 'gcloud' -Arguments @('secrets', 'versions', 'add', $item.N, '--data-file=-', '--project', $project, '--quiet') -Text $item.V -Display "gcloud secrets versions add $($item.N) --data-file=- --project $project   # valor por stdin; oculto"
        }
    } finally { Remove-Variable clientId, secretPlain, key -ErrorAction SilentlyContinue }
    foreach ($n in @('strava-client-id', 'strava-client-secret', 'strava-token-key')) {
        Invoke-Native -Exe 'gcloud' -Arguments @('secrets', 'versions', 'list', $n, '--project', $project, '--limit=1', '--format=value(name,state)') -AllowFailure
    }
}

# URI de callback de bff-mobile (Cloud Run) según la salida de Terraform de producción.
function Get-GcpCallback {
    if ($script:DryRun) {
        $null = Invoke-Native -Exe 'terraform' -Arguments @("-chdir=$ProductionRoot", 'output', '-json', 'runtime_config')
        return $null
    }
    $r = Invoke-Native -Exe 'terraform' -Arguments @("-chdir=$ProductionRoot", 'output', '-json', 'runtime_config') -Capture -AllowFailure
    if ($r.ExitCode -eq 0 -and $r.Output -match '"strava_redirect_uri"\s*:\s*"([^"]+)"') { return $Matches[1] }
    $null
}

function Invoke-StravaActivateGcp {
    Write-Note 'sportapp-gcp.ps1 no expone sync_strava_secret; se ejecuta Terraform sobre production-workloads (ya inicializada por sportapp-gcp.ps1 up/check). El plan se muestra y el apply pide «si».'
    Show-GcpIdentity
    Invoke-Native -Exe 'terraform' -Arguments @("-chdir=$WorkloadsRoot", 'plan', '-input=false', '-out=tfplan-strava', '-var', 'sync_strava_secret=true')
    Invoke-Native -Exe 'terraform' -Arguments @("-chdir=$WorkloadsRoot", 'show', 'tfplan-strava')
    Confirm-Si 'terraform apply en production-workloads (copia el Secret sportapp-third-party a GKE).'
    Invoke-Native -Exe 'terraform' -Arguments @("-chdir=$WorkloadsRoot", 'apply', '-input=false', 'tfplan-strava')
    Write-Note 'Un sportapp-gcp.ps1 up posterior reconcilia workloads sin esta variable: repite este paso si lo ejecutas.'
}

# --- STRAVA: asistente --------------------------------------------------------

# Respuesta del usuario: con -DryRun toma las de -SimulatedInput (o Enter); si no, pregunta.
function Read-Answer([string]$Prompt) {
    if ($script:Simulated.Count -gt 0) {
        $a = [string]$script:Simulated.Dequeue()
        Write-Host "$Prompt $a   [simulado]" -ForegroundColor DarkGray
        return $a
    }
    if ($script:DryRun) { Write-Host "$Prompt   [simulado: Enter]" -ForegroundColor DarkGray; return '' }
    Read-Host $Prompt
}

function Expand-Text($Value, [string]$Env, [hashtable]$Context) {
    $text = if ($Value -is [hashtable]) { [string]$Value[$Env] } else { [string]$Value }
    foreach ($k in $Context.Keys) { $text = $text.Replace("{$k}", [string]$Context[$k]) }
    $text
}

function Show-StravaStep([hashtable]$Step, [int]$Number, [int]$Total, [string]$Env, [hashtable]$Context) {
    Write-Step "Paso $Number/$Total · $($Step.Titulo)"
    Write-Host "  QUÉ hacer : $(Expand-Text $Step.Que $Env $Context)"
    Write-Host "  DÓNDE     : $(Expand-Text $Step.Donde $Env $Context)"
    Write-Host '  VALORES   :'
    foreach ($v in $Step.Valores) { Write-Host "    - $(Expand-Text $v $Env $Context)" }
    Write-Host "  CÓMO SABER QUE SALIÓ BIEN: $(Expand-Text $Step.Ok $Env $Context)" -ForegroundColor Green
    Write-Host "  SI FALLA  : $(Expand-Text $Step.Falla $Env $Context)" -ForegroundColor Yellow
}

function Show-StravaTroubleshooting {
    Write-Step 'Si algo falla: síntoma, causa y acción'
    foreach ($row in $StravaTroubleshooting) {
        Write-Host "  * $($row.Sintoma)" -ForegroundColor Yellow
        Write-Host "      causa : $($row.Causa)"
        Write-Host "      acción: $($row.Accion)"
    }
}

# Ofrece abrir una URL; solo con respuesta 'si'.
function Open-Url([string]$Url) {
    $a = (Read-Answer "¿Abrir $Url en el navegador? (si/no)").Trim()
    if ($a -ne 'si') { return }
    if ($script:DryRun) { Write-Host "  [dry-run] Start-Process $Url" -ForegroundColor DarkGray; return }
    Start-Process $Url
}

# Devuelve 'next' o 'repeat'; 's' detiene el asistente.
function Read-StepNav {
    while ($true) {
        $a = (Read-Answer "Enter = continuar, r = repetir el paso, a = ayuda si falla, s = salir").Trim().ToLowerInvariant()
        switch ($a) {
            '' { return 'next' }
            'r' { return 'repeat' }
            'a' { Show-StravaTroubleshooting }
            's' { throw 'Asistente detenido por el operador; continúa más tarde con -FromStep <n>.' }
            default { Write-Bad "'$a' no es válido." }
        }
    }
}

# Acción automática de cada paso (el texto está en $StravaSteps).
function Invoke-StravaStepAction([int]$Number, [string]$Env, [hashtable]$Context) {
    $isLocal = $Env -eq 'local'
    switch ($Number) {
        1 { Open-Url 'https://www.strava.com/settings/api' }
        2 { if ($isLocal) { Invoke-StravaSecrets } else { Invoke-StravaSecretsGcp } }
        3 {
            if ($isLocal) { Invoke-LocalApply $true } else { Invoke-StravaActivateGcp }
        }
        4 {
            Assert-Tablet
            if ($isLocal) { Invoke-TabletReverse }
            Invoke-TabletInstall $Context.BFFURL
            Wait-Manual 'Abre la app > Strava > «Conectar con Strava» > Authorize y espera result=LINKED.'
            if ($isLocal) { Invoke-Kube -Arguments @('exec', 'statefulset/postgres', '--', 'psql', '-U', 'postgres', '-d', 'terceros', '-c', 'select count(*) from external_account') -AllowFailure }
        }
        5 {
            Wait-Manual 'Pulsa «Sincronizar ahora» en la app.'
            if ($isLocal) {
                foreach ($q in @('select count(*) from sync_run', 'select count(*) from imported_activity')) {
                    Invoke-Kube -Arguments @('exec', 'statefulset/postgres', '--', 'psql', '-U', 'postgres', '-d', 'terceros', '-c', $q) -AllowFailure
                }
                Invoke-Kube -Arguments @('exec', 'statefulset/postgres', '--', 'psql', '-U', 'postgres', '-d', 'entrenamientos_read', '-c', "select count(*) from training_session_history where source = 'STRAVA'") -AllowFailure
                Invoke-LocalStatus
            } else {
                $project = Get-GcpProject
                Invoke-Native -Exe 'gcloud' -Arguments @('pubsub', 'subscriptions', 'describe', 'entrenamientos-actividades-externas-v1', '--project', $project) -AllowFailure
                Invoke-Native -Exe 'gcloud' -Arguments @('run', 'services', 'list', '--project', $project, '--format=table(metadata.name,status.url)') -AllowFailure
                Invoke-Child $GcpScript @{ Command = 'status' }
            }
        }
    }
}

function Wait-Manual([string]$Text) {
    Write-Host "  >> $Text" -ForegroundColor Cyan
    $null = Read-Answer 'Pulsa Enter cuando lo hayas hecho'
}

function Invoke-StravaWizard([string]$Env) {
    $context = @{ DOMAIN = 'bff-mobile-<número-del-proyecto>.<región>.run.app'; CALLBACK = 'https://<dominio>/v1/integrations/strava/callback'; BFFURL = $TabletBffUrl; PROJECT = '<proyecto-activo>' }
    if ($Env -eq 'local') {
        $context.DOMAIN = 'localhost'; $context.CALLBACK = 'http://localhost:18081/v1/integrations/strava/callback'
    } else {
        $uri = Get-GcpCallback
        if ($uri) {
            $context.CALLBACK = $uri; $context.DOMAIN = ([uri]$uri).Host
            $context.BFFURL = ([uri]$uri).GetLeftPart([System.UriPartial]::Authority) + '/'
        } elseif (-not $script:DryRun) {
            Write-Note 'No se pudo leer terraform output runtime_config de production; escribe la URL pública de bff-mobile.'
            $context.BFFURL = "$(Read-Answer 'URL base de bff-mobile (https://.../)')".Trim()
        } else { $context.BFFURL = 'https://bff-mobile-<número>.<región>.run.app/' }
        $context.PROJECT = Get-GcpProject
    }
    Write-Step "Integración con Strava: asistente guiado ($Env)"
    Write-Info "Referencia: docs/guia-prueba-strava.md. Cinco pasos más la tabla de fallos (paso 6); en cada uno confirmas antes de seguir."
    $total = $StravaSteps.Count + 1
    $n = [Math]::Max($FromStep, 1)
    while ($n -le $StravaSteps.Count) {
        Show-StravaStep $StravaSteps[$n - 1] $n $total $Env $context
        Invoke-StravaStepAction $n $Env $context
        $nav = Read-StepNav
        if ($nav -eq 'next') { $n++ }
    }
    Show-StravaTroubleshooting
    Write-Ok 'Asistente terminado.'
}

# --- TABLETA (solo el dispositivo físico) -------------------------------------

function Assert-Tablet {
    if ($TabletSerial -like 'emulator-*') { throw 'Los emuladores están prohibidos.' }
    if ($script:DryRun) { Invoke-Native -Exe 'adb' -Arguments @('devices'); return }
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { throw 'adb no está en el PATH (Android SDK platform-tools).' }
    $r = Invoke-Native -Exe 'adb' -Arguments @('devices') -Capture
    $line = @($r.Output -split "`n" | Where-Object { $_ -match "^$TabletSerial\s+device\b" })
    if (-not $line) { throw "La tableta física $TabletSerial no está conectada y autorizada (estado 'device'). No se usan emuladores ni otros dispositivos." }
    Write-Ok "Tableta $TabletSerial conectada"
}

function Invoke-TabletReverse {
    Invoke-Native -Exe 'adb' -Arguments @('-s', $TabletSerial, 'reverse', 'tcp:18081', 'tcp:18081')
    Invoke-Native -Exe 'adb' -Arguments @('-s', $TabletSerial, 'reverse', '--list')
}

function Invoke-TabletInstall([string]$BaseUrl) {
    Confirm-Si "Compilar e instalar el APK de depuración en la tableta $TabletSerial (BFF $BaseUrl)."
    $gradle = Join-Path $MobilePath 'gradlew.bat'
    $previousSerial = $env:ANDROID_SERIAL
    try {
        # ANDROID_SERIAL impide que installDebug alcance otro dispositivo.
        $env:ANDROID_SERIAL = $TabletSerial
        Invoke-Native -Exe $gradle -Arguments @(':app:installDebug', "-Psportapp.bffMobileBaseUrl.debug=$BaseUrl") -WorkDir $MobilePath -Display "ANDROID_SERIAL=$TabletSerial gradlew.bat :app:installDebug -Psportapp.bffMobileBaseUrl.debug=$BaseUrl"
    } finally { $env:ANDROID_SERIAL = $previousSerial }
}

# --- DESPLEGAR Y ACTUALIZAR ---------------------------------------------------

# Reconstruye y reinicia lo afectado. Con migraciones o cambios de manifiestos usa
# plan/apply (docs/preparacion-terraform-local.md sección 7).
function Invoke-LocalUpdate {
    Write-Step "Local: actualizar imágenes ($Component) y reiniciar los despliegues"
    Write-Note 'Sin migraciones. Con migraciones o cambios de manifiestos usa plan/apply con un tag nuevo (guía de preparación local, sección 7.2).'
    Confirm-Si "Reconstruir $Component y reiniciar sus despliegues en $LocalContext/$LocalNamespace."
    $backendArgs = @('-3.13', '-m', 'uv', 'run', 'python', 'scripts/task.py', 'build', $(if ($Component -in @('all', 'web')) { 'all' } else { $Component }))
    if ($Component -ne 'web') { Invoke-Native -Exe 'py' -Arguments $backendArgs -WorkDir $BackendPath }
    if ($Component -in @('all', 'web')) { Invoke-Native -Exe 'docker' -Arguments @('build', '-t', 'sportapp/web:local', '.') -WorkDir $FrontendPath }
    if ($Component -eq 'all') {
        Invoke-Kube -Arguments @('rollout', 'restart', 'deployment')
        Invoke-Kube -Arguments @('wait', '--for=condition=Available', 'deployment', '--all', '--timeout=600s')
    } else {
        $names = @($Component)
        if (-not $script:DryRun -and $Component -ne 'web') {
            $all = Invoke-Kube -Arguments @('get', 'deployments', '-o', 'name') -Capture -AllowFailure
            $names = @($all.Output -split "`n" | ForEach-Object { ($_ -split '/')[-1].Trim() } | Where-Object { $_ -eq $Component -or $_.StartsWith("$Component-") })
            if (-not $names) { $names = @($Component) }
        }
        foreach ($n in $names) {
            Invoke-Kube -Arguments @('rollout', 'restart', "deployment/$n")
            Invoke-Kube -Arguments @('rollout', 'status', "deployment/$n", '--timeout=600s')
        }
    }
    Invoke-LocalStatus
}

function Invoke-Deploy([string]$Env, [string]$Verb) {
    if ($Env -eq 'gcp') { Invoke-Gcp $Verb; return }
    switch ($Verb) {
        'check' { Invoke-LocalCheck }
        'build' { Invoke-LocalBuild }
        'plan' { Invoke-LocalPlan ([bool]$Strava) }
        'apply' { Invoke-LocalApply ([bool]$Strava) }
        'update' { Invoke-LocalUpdate }
        default { throw "Acción local inválida '$Verb'. Opciones: check, build, plan, apply, update." }
    }
}

# --- Menús --------------------------------------------------------------------

function Read-Choice([string]$Title, [object[]]$Items) {
    Write-Step $Title
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 1), $Items[$i].Label) }
    Write-Host '  0. Volver'
    $answer = "$(Read-Answer 'Número')".Trim()
    $n = 0
    if ($answer -eq '0' -or -not $answer) { return $null }
    if (-not [int]::TryParse($answer, [ref]$n) -or $n -lt 1 -or $n -gt $Items.Count) { throw "'$answer' no es una opción del menú." }
    $Items[$n - 1].Value
}

function Select-Environment {
    if ($Environment) { return $Environment }
    Read-Choice 'Ambiente (Local y GCP están separados)' @(
        @{ Label = 'Local: Docker Desktop + Terraform (contexto docker-desktop)'; Value = 'local' },
        @{ Label = 'GCP: Cloud Deploy, Cloud Run, GKE y Pub/Sub administrado'; Value = 'gcp' })
}

function Invoke-Area([string]$Name, [string]$Verb) {
    switch ($Name) {
        'strava' { $e = Select-Environment; if ($e) { Invoke-StravaWizard $e } }
        'release' { if (-not $Verb -or $Verb -eq 'sequence') { Invoke-ReleaseSequence } else { Invoke-Release $Verb } }
        'deploy' {
            $e = Select-Environment
            if (-not $e) { return }
            if (-not $Verb) { throw 'Indica la acción (local: check, build, plan, apply, update; gcp: plan, status, images, up, promote, down).' }
            Invoke-Deploy $e $Verb
        }
    }
}

function Show-Menu {
    $releaseItems = @(
        @{ Label = 'Secuencia completa: check, release del componente, submódulos/manifiesto, plataforma'; Value = 'sequence' },
        @{ Label = 'Solo check (gh, permisos, ramas, herramientas)'; Value = 'check' },
        @{ Label = 'Ver cambios pendientes y última release (status)'; Value = 'status' },
        @{ Label = 'Publicar una release suelta (release)'; Value = 'release' },
        @{ Label = 'Consultar Cloud Build de un tag (builds)'; Value = 'builds' },
        @{ Label = 'Compilar y adjuntar el APK (apk)'; Value = 'apk' })
    $localItems = @(
        @{ Label = 'Prerrequisitos (docker, kubectl docker-desktop, terraform, backend en develop)'; Value = 'check' },
        @{ Label = 'Construir imágenes de la versión actual (backend y web)'; Value = 'build' },
        @{ Label = 'Terraform plan (solo muestra el plan)'; Value = 'plan' },
        @{ Label = 'Terraform apply (plan + confirmación)'; Value = 'apply' },
        @{ Label = 'Actualizar imágenes (reconstruir y rollout restart + verificación)'; Value = 'update' })
    $gcpItems = @(
        @{ Label = 'Plan/verificación (check -Validate, no cambia nada)'; Value = 'plan' },
        @{ Label = 'Estado de recursos costosos (status)'; Value = 'status' },
        @{ Label = 'Imágenes publicadas y última release (images)'; Value = 'images' },
        @{ Label = 'Encender producción (up)'; Value = 'up' },
        @{ Label = 'Desplegar o actualizar una release / imágenes (promote)'; Value = 'promote' },
        @{ Label = 'Apagar producción (down)'; Value = 'down' })
    while ($true) {
        Write-Step 'SportApp: ¿qué quieres hacer?'
        if ($script:DryRun) { Write-Note 'Modo -DryRun: solo se imprimen los comandos.' }
        Write-Host '  1. Integración con Strava (asistente paso a paso, Local o GCP)'
        Write-Host '  2. Lanzar releases (backend, frontend, móvil y plataforma)'
        Write-Host '  3. Desplegar la versión actual y actualizar (Local o GCP)'
        Write-Host '  0. Salir'
        $choice = "$(Read-Answer 'Número')".Trim()
        if ($choice -eq '0' -or -not $choice) { return }
        try {
            switch ($choice) {
                '1' { Invoke-Area 'strava' '' }
                '2' { $v = Read-Choice 'Releases (sportapp-release.ps1)' $releaseItems; if ($v) { Invoke-Area 'release' $v } }
                '3' {
                    $e = Select-Environment
                    if ($e) {
                        $v = Read-Choice "Desplegar y actualizar ($e)" $(if ($e -eq 'local') { $localItems } else { $gcpItems })
                        if ($v) {
                            if ($v -eq 'update' -and -not $script:Bound.ContainsKey('Component')) {
                                $c = "$(Read-Answer 'Componente (all, web o un servicio; Enter = all)')".Trim()
                                if ($c) { $script:Component = $c }
                            }
                            Invoke-Deploy $e $v
                        }
                    }
                }
                default { Write-Bad "'$choice' no es una opción." }
            }
        } catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
    }
}

function Show-Help { Get-Help $PSCommandPath -Detailed | Out-Host }

# --- Entrada ------------------------------------------------------------------

$previousConsoleEncoding = [Console]::OutputEncoding
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { $previousConsoleEncoding = $null }
try {
    if ($SimulatedInput -and -not $script:DryRun) { throw '-SimulatedInput solo se admite junto con -DryRun.' }
    if ($Area -eq 'help') { Show-Help; return }
    if ($Area -eq 'menu') { Show-Menu; return }
    Invoke-Area $Area $Action
} catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ($previousConsoleEncoding) { try { [Console]::OutputEncoding = $previousConsoleEncoding } catch { } }
}
