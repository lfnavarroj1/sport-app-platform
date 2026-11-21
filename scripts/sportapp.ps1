<#
.SYNOPSIS
    Menú único de SportApp: desplegar en local o en GCP y lanzar releases.

.DESCRIPTION
    Punto de entrada delgado. No duplica lo existente: GCP se delega en
    sportapp-gcp.ps1 y los releases en sportapp-release.ps1, ambos invocados con
    parámetros. Lo único propio es el flujo LOCAL (Docker Desktop + Terraform),
    la carga de secretos de Strava y la tableta física.

    Sin argumentos muestra el menú:

      1  Local     prerrequisitos, construir imágenes, plan/apply, Strava,
                   estado y destrucción (solo contexto kubectl docker-desktop).
      2  GCP       sportapp-gcp.ps1 (nunca usa docker-desktop); muestra cuenta y
                   proyecto de gcloud y exige 'si' antes de crear, cambiar o destruir.
      3  Releases  sportapp-release.ps1 (check, release, plataforma, apk...).
      4  Strava    secretos locales y verificación (docs/guia-prueba-strava.md).
      5  Tableta   solo el dispositivo físico R52NB04LMCB por adb (jamás emulador).
      0  Salir

    Subcomandos no interactivos equivalentes: <área> <acción>.

      local    check | build | plan | apply | secrets | strava | status | destroy
      gcp      plan | check | setup | up | down | status | images | promote
      release  check | status | builds | release | hotfix | apk | submodules | prepare | keystore
      strava   secrets | enable | status
      tablet   check | reverse | install | logcat

    Toda acción que crea, cambia o destruye pide escribir 'si'. Nada se aplica
    automáticamente. Los secretos se piden por terminal, viajan por stdin hacia
    kubectl y nunca se imprimen ni se guardan. Con -DryRun se imprimen los
    comandos sin ejecutarlos (ni pedir secretos ni confirmaciones).

    Instrucciones: docs/guia-menu-sportapp.md.

.EXAMPLE
    .\scripts\sportapp.ps1

.EXAMPLE
    .\scripts\sportapp.ps1 local apply -DryRun

.EXAMPLE
    .\scripts\sportapp.ps1 gcp status

.EXAMPLE
    .\scripts\sportapp.ps1 release check -Target backend
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'local', 'gcp', 'release', 'strava', 'tablet', 'help')]
    [string]$Area = 'menu',

    [Parameter(Position = 1)]
    [string]$Action,

    # Imprime los comandos sin ejecutarlos; no pide secretos ni confirmaciones.
    [switch]$DryRun,

    # local plan/apply: incluye -var strava_integration_enabled=true.
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
    $verbs = @('plan', 'check', 'setup', 'up', 'down', 'status', 'images', 'promote')
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
    if ($Verb -in @('setup', 'up', 'down', 'promote')) {
        Confirm-Si "GCP: '$Verb' crea, modifica o destruye recursos reales."
    }
    # Nunca se reenvía -AutoApprove: el script de GCP conserva sus propias confirmaciones.
    Invoke-Child $GcpScript $params
}

function Invoke-Release([string]$Verb) {
    $verbs = @('check', 'status', 'builds', 'release', 'hotfix', 'apk', 'submodules', 'prepare', 'keystore')
    if ($verbs -notcontains $Verb) { throw "Acción de release inválida '$Verb'. Opciones: $($verbs -join ', ')." }
    $params = Get-Forwarded @('Target', 'Bump', 'BackendVersion', 'FrontendVersion', 'MobileVersion', 'PlatformVersion', 'SystemVersion', 'Stories', 'Sprint', 'ConfigFile')
    $params.Command = $Verb
    if ($Verb -in @('release', 'hotfix', 'apk', 'submodules', 'prepare', 'keystore')) {
        Confirm-Si "Releases: '$Verb' publica o modifica repositorios, tags o artefactos."
    }
    # Nunca se reenvía -AutoApprove: la aprobación de cada PR sigue siendo humana.
    Invoke-Child $ReleaseScript $params
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

function Invoke-LocalDestroy {
    Write-Step 'Local: destruir el ambiente (namespace y PostgreSQL se pierden; las imágenes Docker se conservan)'
    Invoke-Terraform @('init', '-input=false')
    Invoke-Terraform @('plan', '-destroy', '-input=false', '-out=tfdestroy')
    Invoke-Terraform @('show', 'tfdestroy')
    Write-Note "Raíz activa: $LocalRoot"
    Confirm-Si 'Se destruirá el ambiente local completo (datos de PostgreSQL incluidos).'
    Invoke-Terraform @('apply', '-input=false', 'tfdestroy')
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

# --- STRAVA -------------------------------------------------------------------

function Assert-StravaSecret {
    if ($script:DryRun) { Invoke-Kube -Arguments @('get', 'secret', $StravaSecret); return }
    $r = Invoke-Kube -Arguments @('get', 'secret', $StravaSecret, '--no-headers') -Capture -AllowFailure
    if ($r.ExitCode -ne 0) { throw "Falta el Secret ${StravaSecret}: cárgalo primero (local secrets / strava secrets)." }
    Write-Ok "Secret $StravaSecret presente"
}

# Valores por terminal; el Secret viaja como JSON por stdin (sin argv, sin disco).
function Invoke-StravaSecrets {
    Write-Step "Strava: cargar el Secret $StravaSecret en $LocalContext/$LocalNamespace"
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
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $key = [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_')
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
        Remove-Variable clientId, secretSecure, secretPlain, bytes, key, manifest -ErrorAction SilentlyContinue
    }
}

function Invoke-StravaStatus {
    Write-Step 'Strava: verificación (docs/guia-prueba-strava.md sección 7)'
    Invoke-Kube -Arguments @('get', 'pods') -AllowFailure
    Invoke-Kube -Arguments @('get', 'job', 'third-party-management-migrate-main') -AllowFailure
    Invoke-Kube -Arguments @('get', 'secret', $StravaSecret) -AllowFailure
    Invoke-Terraform @('output', 'strava') -AllowFailure
    Invoke-Kube -Arguments @('exec', 'statefulset/postgres', '--', 'psql', '-U', 'postgres', '-d', 'terceros', '-c', 'select count(*) from external_account') -AllowFailure
    Write-Info "Callback: http://localhost:18081/v1/integrations/strava/callback (requiere 'adb reverse' de la opción Tableta)."
}

function Invoke-StravaEnable { Invoke-LocalApply $true }

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
    Assert-Tablet
    Invoke-Native -Exe 'adb' -Arguments @('-s', $TabletSerial, 'reverse', 'tcp:18081', 'tcp:18081')
    Invoke-Native -Exe 'adb' -Arguments @('-s', $TabletSerial, 'reverse', '--list')
}

function Invoke-TabletInstall {
    Assert-Tablet
    Confirm-Si "Compilar e instalar el APK de depuración en la tableta $TabletSerial (BFF $TabletBffUrl)."
    $gradle = Join-Path $MobilePath 'gradlew.bat'
    $previousSerial = $env:ANDROID_SERIAL
    try {
        # ANDROID_SERIAL impide que installDebug alcance otro dispositivo.
        $env:ANDROID_SERIAL = $TabletSerial
        Invoke-Native -Exe $gradle -Arguments @(':app:installDebug', "-Psportapp.bffMobileBaseUrl.debug=$TabletBffUrl") -WorkDir $MobilePath -Display "ANDROID_SERIAL=$TabletSerial gradlew.bat :app:installDebug -Psportapp.bffMobileBaseUrl.debug=$TabletBffUrl"
    } finally { $env:ANDROID_SERIAL = $previousSerial }
}

function Invoke-TabletLogcat {
    Assert-Tablet
    Write-Info 'Ctrl+C para detener. Filtro: proceso de la app, Strava y errores de red.'
    if ($script:DryRun) {
        Invoke-Native -Exe 'adb' -Arguments @('-s', $TabletSerial, 'logcat', '-v', 'time') -Display "adb -s $TabletSerial logcat -v time | Select-String '$MobilePackage|Strava|OkHttp'"
        return
    }
    & adb -s $TabletSerial logcat -v time | Select-String -Pattern "$MobilePackage|Strava|OkHttp" | ForEach-Object { $_.Line }
}

# --- Menús --------------------------------------------------------------------

function Read-Choice([string]$Title, [object[]]$Items) {
    Write-Step $Title
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 1), $Items[$i].Label) }
    Write-Host '  0. Volver'
    $answer = "$(Read-Host 'Número')".Trim()
    $n = 0
    if ($answer -eq '0' -or -not $answer) { return $null }
    if (-not [int]::TryParse($answer, [ref]$n) -or $n -lt 1 -or $n -gt $Items.Count) { throw "'$answer' no es una opción del menú." }
    $Items[$n - 1].Value
}

function Invoke-Area([string]$Name, [string]$Verb) {
    switch ($Name) {
        'local' {
            switch ($Verb) {
                'check' { Invoke-LocalCheck }
                'build' { Invoke-LocalBuild }
                'plan' { Invoke-LocalPlan ([bool]$Strava) }
                'apply' { Invoke-LocalApply ([bool]$Strava) }
                'secrets' { Invoke-StravaSecrets }
                'strava' { Invoke-StravaEnable }
                'status' { Invoke-LocalStatus }
                'destroy' { Invoke-LocalDestroy }
                default { throw "Acción local inválida '$Verb'. Opciones: check, build, plan, apply, secrets, strava, status, destroy." }
            }
        }
        'gcp' { Invoke-Gcp $Verb }
        'release' { Invoke-Release $Verb }
        'strava' {
            switch ($Verb) {
                'secrets' { Invoke-StravaSecrets }
                'enable' { Invoke-StravaEnable }
                'status' { Invoke-StravaStatus }
                default { throw "Acción de Strava inválida '$Verb'. Opciones: secrets, enable, status." }
            }
        }
        'tablet' {
            switch ($Verb) {
                'check' { Assert-Tablet }
                'reverse' { Invoke-TabletReverse }
                'install' { Invoke-TabletInstall }
                'logcat' { Invoke-TabletLogcat }
                default { throw "Acción de tableta inválida '$Verb'. Opciones: check, reverse, install, logcat." }
            }
        }
    }
}

function Show-Menu {
    $sections = @{
        '1' = @{ T = 'Local (Docker Desktop + Terraform)'; A = 'local'; I = @(
            @{ Label = 'Prerrequisitos (docker, kubectl docker-desktop, terraform, backend en develop)'; Value = 'check' },
            @{ Label = 'Construir imágenes sportapp/* (backend y web)'; Value = 'build' },
            @{ Label = 'Terraform plan (solo muestra el plan)'; Value = 'plan' },
            @{ Label = 'Terraform apply (plan + confirmación)'; Value = 'apply' },
            @{ Label = 'Cargar el Secret sportapp-third-party (Strava)'; Value = 'secrets' },
            @{ Label = 'Activar Strava (apply con strava_integration_enabled=true)'; Value = 'strava' },
            @{ Label = 'Estado y verificación (pods, jobs, health, tópicos)'; Value = 'status' },
            @{ Label = 'Destruir el ambiente local'; Value = 'destroy' }) }
        '2' = @{ T = 'GCP (sportapp-gcp.ps1)'; A = 'gcp'; I = @(
            @{ Label = 'Plan/verificación (check -Validate, no cambia nada)'; Value = 'plan' },
            @{ Label = 'Estado de recursos costosos'; Value = 'status' },
            @{ Label = 'Imágenes publicadas y última release'; Value = 'images' },
            @{ Label = 'Preparación completa (setup)'; Value = 'setup' },
            @{ Label = 'Encender producción (up)'; Value = 'up' },
            @{ Label = 'Apagar producción (down)'; Value = 'down' },
            @{ Label = 'Promover una release (promote)'; Value = 'promote' }) }
        '3' = @{ T = 'Releases (sportapp-release.ps1)'; A = 'release'; I = @(
            @{ Label = 'Validar gh, permisos, ramas y herramientas (check)'; Value = 'check' },
            @{ Label = 'Ver cambios pendientes y última release (status)'; Value = 'status' },
            @{ Label = 'Publicar una release (componente o plataforma)'; Value = 'release' },
            @{ Label = 'Publicar un hotfix'; Value = 'hotfix' },
            @{ Label = 'Consultar Cloud Build de un tag (builds)'; Value = 'builds' },
            @{ Label = 'Compilar y adjuntar el APK (apk)'; Value = 'apk' },
            @{ Label = 'Mover components/* a los tags publicados (submodules)'; Value = 'submodules' }) }
        '4' = @{ T = 'Strava (local)'; A = 'strava'; I = @(
            @{ Label = 'Cargar secretos (Client ID/Secret por terminal, clave AES generada)'; Value = 'secrets' },
            @{ Label = 'Activar la integración (terraform apply con la bandera)'; Value = 'enable' },
            @{ Label = 'Verificar (pods, job, Secret, callback)'; Value = 'status' }) }
        '5' = @{ T = "Tableta física $TabletSerial (adb)"; A = 'tablet'; I = @(
            @{ Label = 'Comprobar que la tableta está conectada'; Value = 'check' },
            @{ Label = 'adb reverse tcp:18081'; Value = 'reverse' },
            @{ Label = 'Compilar e instalar el APK de depuración'; Value = 'install' },
            @{ Label = 'Logcat filtrado'; Value = 'logcat' }) }
    }
    while ($true) {
        Write-Step 'SportApp: ¿qué quieres hacer?'
        if ($script:DryRun) { Write-Note 'Modo -DryRun: solo se imprimen los comandos.' }
        Write-Host '  1. Local: desplegar y verificar en Docker Desktop'
        Write-Host '  2. GCP: producción (Cloud Deploy, Cloud Run, GKE)'
        Write-Host '  3. Releases: publicar componentes, plataforma y APK'
        Write-Host '  4. Strava: secretos locales y verificación'
        Write-Host '  5. Tableta: dispositivo físico por adb'
        Write-Host '  0. Salir'
        $choice = "$(Read-Host 'Número')".Trim()
        if ($choice -eq '0' -or -not $choice) { return }
        if (-not $sections.ContainsKey($choice)) { Write-Bad "'$choice' no es una opción."; continue }
        $section = $sections[$choice]
        try {
            $verb = Read-Choice $section.T $section.I
            if ($verb) { Invoke-Area $section.A $verb }
        } catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
    }
}

function Show-Help { Get-Help $PSCommandPath -Detailed | Out-Host }

# --- Entrada ------------------------------------------------------------------

$previousConsoleEncoding = [Console]::OutputEncoding
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { $previousConsoleEncoding = $null }
try {
    if ($Area -eq 'help') { Show-Help; return }
    if ($Area -eq 'menu' -or -not $Action) {
        if ($Area -eq 'menu') { Show-Menu; return }
        throw "Indica una acción para '$Area' (ver .\scripts\sportapp.ps1 help)."
    }
    Invoke-Area $Area $Action
} catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ($previousConsoleEncoding) { try { [Console]::OutputEncoding = $previousConsoleEncoding } catch { } }
}
