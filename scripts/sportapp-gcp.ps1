<#
.SYNOPSIS
    Prepara, enciende y apaga SportApp en GCP desde la estación del operador.

.DESCRIPTION
    Automatiza docs/preparacion-terraform-gcp.md. El único archivo que se completa
    a mano es platform\.env.ps1 (plantilla: .env.example.ps1); el script genera
    los bootstrap.auto.tfvars, gcp.auto.tfvars y backend.hcl de cada raíz.

      check    Valida herramientas, variables de .env.ps1, archivos de variables y
               autenticación. No cambia nada.
      setup    Preparación completa e idempotente: proyectos, APIs, bootstrap,
               production, production-workloads, delivery y primera creación de
               Cloud Run. Se detiene con instrucciones en los pasos manuales
               (autorizar la GitHub App, publicar los primeros tags) y continúa
               donde quedó al repetirlo.
      up       Vuelve a crear el plano operativo costoso (GKE, Cloud SQL y Cloud
               Run) y reconcilia production-workloads y delivery.
      down     Destruye solo GKE, Cloud SQL (con sus datos) y Cloud Run. Conserva
               proyectos, estado, identidades, Artifact Registry con sus
               imágenes, Secret Manager, red, Pub/Sub, Cloud Build y Cloud Deploy.
      status   Muestra qué recursos costosos existen.
      promote  Ejecuta el trigger promote-release. La aprobación sigue siendo humana.

    Cada apply muestra el plan y pide confirmación. No crea llaves, no usa GitHub
    y no aprueba rollouts. Instrucciones de uso: scripts/sportapp-gcp.md.

.EXAMPLE
    .\scripts\sportapp-gcp.ps1 check

.EXAMPLE
    .\scripts\sportapp-gcp.ps1 down

.EXAMPLE
    .\scripts\sportapp-gcp.ps1 promote -BackendVersion v1.2.0 -FrontendVersion v0.9.0
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'check', 'setup', 'up', 'down', 'status', 'promote')]
    [string]$Command = 'help',

    # Archivo de configuración; por defecto platform\.env.ps1.
    [string]$ConfigFile,

    # Aplica los planes sin preguntar. No omite la confirmación de down ni la de
    # un plan que elimine recursos inesperados.
    [switch]$AutoApprove,

    # check: no consulta GCP (herramientas, variables y archivos).
    [switch]$Offline,

    # check: además ejecuta terraform validate en cada raíz.
    [switch]$Validate,

    # down: ID del proyecto de producción para confirmar sin preguntar.
    [string]$ConfirmProject,

    # promote: tags SemVer y sufijo opcional (1 a 8 minúsculas o dígitos) para
    # volver a promover una versión ya publicada.
    [string]$BackendVersion,
    [string]$FrontendVersion,
    [string]$ReleaseSuffix
)

$ErrorActionPreference = 'Stop'

# --- Rutas y constantes -------------------------------------------------------

$PlatformRoot = Split-Path -Parent $PSScriptRoot
$TerraformRoot = Join-Path $PlatformRoot 'infra\terraform'
$Roots = [ordered]@{
    bootstrap  = Join-Path $TerraformRoot 'bootstrap\gcp-state'
    production = Join-Path $TerraformRoot 'environments\production'
    workloads  = Join-Path $TerraformRoot 'environments\production-workloads'
    delivery   = Join-Path $TerraformRoot 'environments\delivery'
}
if (-not $ConfigFile) { $ConfigFile = Join-Path $PlatformRoot '.env.ps1' }
elseif (Test-Path -LiteralPath $ConfigFile) { $ConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path }
# Solo un .ps1 se carga con dot-sourcing; otra extensión la abriría otro programa.
if ([IO.Path]::GetExtension($ConfigFile) -ne '.ps1') { Write-Host "ERROR: $ConfigFile debe ser un archivo .ps1." -ForegroundColor Red; exit 1 }

$BackupRoot = Join-Path $env:USERPROFILE 'terraform-state-backups\sportapp'
$GeneratedHeader = '# Generado por scripts/sportapp-gcp.ps1 a partir de .env.ps1. No lo edites: se regenera en cada ejecución.'
$CloudRunImagesFile = Join-Path $Roots.production 'cloud-run-images.auto.tfvars.json'
$BackendBase = Join-Path $PlatformRoot 'components\backend\deploy\k8s\base'

# Nombre fijo del clúster (modules/gcp/platform: "<name_prefix>-gke").
$ClusterName = 'sportapp-prod-gke'

# Plano operativo costoso que down destruye y up recrea.
$CostlyTargets = @('module.platform.module.gke', 'module.platform.module.cloud_sql', 'module.platform.module.cloud_run')

# Únicos recursos que puede eliminar down: los anteriores y los permisos que
# dependen de ellos (Terraform los recrea en up). Cualquier otra eliminación,
# por ejemplo Artifact Registry o Secret Manager, aborta la destrucción.
$CostlyDeletable = @(
    '^module\.platform\.module\.gke\.',
    '^module\.platform\.module\.cloud_sql\.',
    '^module\.platform\.module\.cloud_run\[',
    '^module\.platform\.module\.iam\.google_service_account_iam_member\.workload_identity\[',
    '^module\.platform\.module\.artifact_registry\[[^\]]+\]\.google_artifact_registry_repository_iam_member\.readers\[',
    '^module\.platform\.google_secret_manager_secret_iam_member\.db_password\[',
    '^module\.platform\.google_service_account_iam_member\.deploy_execution_act_as\['
)

# Tipos que ninguna raíz debe crear (sección 1 de la guía).
$ForbiddenTypes = @('^google_service_account_key$', '^google_iam_workload_identity_pool', '^kubernetes_(deployment|job|cron_job)')

# Eliminaciones aceptadas en el bootstrap: solo el retiro de WIF.
$BootstrapDeletable = @('workload_identity|oidc|plan_github|apply_github|delivery_github|ci_delivery')

$ExamplePlaceholders = @('XXXXXX', '000000-000000', 'sportapp-mgmt-1234', 'sportapp-prod-1234', 'sportapp-mgmt-000000', 'sportapp-prod-000000', 'example.com', 'dominio.com', '<', '>')

# --- Salida -------------------------------------------------------------------

function Write-Step([string]$Text) { Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [ok]    $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "  [aviso] $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host "  [falta] $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "          $Text" }

function Confirm-Step([string]$Question, [switch]$Always) {
    if ($AutoApprove -and -not $Always) { return }
    $answer = Read-Host "$Question Escribe 'si' para continuar"
    if ($answer -ne 'si') { throw 'Cancelado por el operador; no se aplicó nada más.' }
}

# Detiene el script en un paso manual. No es un error: al repetir el comando
# continúa desde ese punto.
class ManualStep : System.Exception {
    ManualStep([string]$Message) : base($Message) {}
}

# --- Comandos externos --------------------------------------------------------

# Muestra la salida en la consola (planes, prompts) sin devolverla, para que no
# se mezcle con el resultado de la función que la llama. El código de salida
# queda en $script:NativeExit.
function Invoke-Show {
    param([string]$Exe, [string[]]$Arguments, [int[]]$AllowedExitCodes = @(0))
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Exe @Arguments | Out-Host; $script:NativeExit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    if ($AllowedExitCodes -notcontains $script:NativeExit) {
        throw "Falló: $Exe $($Arguments -join ' ') (código $($script:NativeExit))."
    }
}

# Captura stdout y stderr por separado.
function Invoke-Capture {
    param([string]$Exe, [string[]]$Arguments, [switch]$AllowFailure)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $all = & $Exe @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    $out = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n"
    $err = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.Exception.Message }) -join "`n"
    if (-not $AllowFailure -and $code -ne 0) {
        throw "Falló: $Exe $($Arguments -join ' ') (código $code).`n$err"
    }
    [pscustomobject]@{ ExitCode = $code; Output = $out.Trim(); Error = $err.Trim() }
}

function Invoke-GcloudJson([string[]]$Arguments, [switch]$AllowFailure) {
    $r = Invoke-Capture gcloud ($Arguments + @('--format=json', '--quiet')) -AllowFailure:$AllowFailure
    if ($r.ExitCode -ne 0 -or -not $r.Output) { return $null }
    ConvertFrom-JsonText $r.Output
}

# Windows PowerShell 5.1 limita ConvertFrom-Json a ~2 MB; un plan de producción
# puede superarlo.
function ConvertFrom-JsonText([string]$Text) {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return ($Text | ConvertFrom-Json) }
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    $serializer.RecursionLimit = 1000
    , $serializer.DeserializeObject($Text)
}

function Get-Keys($Map) {
    if ($null -eq $Map) { return @() }
    if ($Map -is [System.Collections.IDictionary]) { return @($Map.Keys) }
    @($Map.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-Value($Map, [string]$Key) {
    if ($null -eq $Map) { return $null }
    if ($Map -is [System.Collections.IDictionary]) { if (@($Map.Keys) -ccontains $Key) { return $Map[$Key] }; return $null }
    $p = $Map.PSObject.Properties[$Key]
    if ($p) { return $p.Value }
    $null
}

# --- Configuración (.env.ps1) ------------------------------------------------

$EmailPattern = '^[^@\s"\\]+@[^@\s"\\]+\.[^@\s"\\]+$'
$ProjectPattern = '^[a-z][a-z0-9-]{4,28}[a-z0-9]$'

# Orden y significado de cada variable; Example es la línea que se sugiere.
$VariableSpecs = @(
    @{ Name = 'billing'; Required = $true; Example = '"XXXXXX-XXXXXX-XXXXXX"'; Help = 'cuenta de facturación (gcloud billing accounts list)' }
    @{ Name = 'mgmt'; Required = $true; Example = '"sportapp-mgmt-1234"'; Help = 'ID del proyecto de gestión (estado, Cloud Build, Cloud Deploy)' }
    @{ Name = 'production'; Required = $true; Example = '"sportapp-prod-1234"'; Help = 'ID del proyecto de producción (GKE, Cloud SQL, Cloud Run)' }
    @{ Name = 'region'; Required = $true; Example = '"us-central1"'; Help = 'región; debe coincidir con environments/production/terraform.tfvars' }
    @{ Name = 'operator'; Required = $true; Example = '"usuario@dominio.com"'; Help = 'correo de la persona que ejecuta Terraform (cuenta activa de gcloud)' }
    @{ Name = 'budgetAmount'; Required = $true; Example = '1000'; Help = 'presupuesto mensual, en la moneda de la cuenta de facturación' }
    @{ Name = 'budgetCurrency'; Required = $true; Example = '"USD"'; Help = 'moneda de la cuenta de facturación (USD, COP...)' }
    @{ Name = 'budgetAlertAmounts'; Required = $false; Example = '@(50, 100, 250, 500)'; Help = 'avisos en montos absolutos; vacío = 50 %, 90 % y 100 %' }
    @{ Name = 'healthDataConsentVersion'; Required = $true; Example = '"<versión aprobada>"'; Help = 'versión vigente del consentimiento de datos de salud (ADR-034)' }
    @{ Name = 'deployToolsImage'; Required = $true; Example = '"gcr.io/google.com/cloudsdktool/google-cloud-cli:588.0.0@sha256:<64 hex>"'; Help = 'imagen por digest con gcloud y kubectl para las verificaciones de GKE' }
    @{ Name = 'jwtPrivateKeyFile'; Required = $false; Example = '"C:\ruta-segura\sportapp-users-jwt.pem"'; Help = 'clave Ed25519 de users-management; solo se usa si el secreto aún no tiene versión' }
    @{ Name = 'approvers'; Required = $false; Example = '@("user:aprobador@dominio.com")'; Help = 'quién aprueba rollouts; por defecto user:$operator' }
    @{ Name = 'alertEmails'; Required = $false; Example = '@("equipo@dominio.com")'; Help = 'destinatarios de alertas; por defecto $operator' }
    @{ Name = 'operators'; Required = $false; Example = '@("user:usuario@dominio.com")'; Help = 'quién puede impersonar Terraform; por defecto user:$operator' }
    @{ Name = 'releaseTriggersEnabled'; Required = $false; Example = '$true'; Help = 'habilita los triggers de tags cuando backend y frontend tengan cloudbuild.release.yaml en main' }
    @{ Name = 'initialBackendVersion'; Required = $false; Example = '"v1.0.0"'; Help = 'release backend para crear Cloud Run la primera vez; por defecto la más reciente' }
    @{ Name = 'initialFrontendVersion'; Required = $false; Example = '"v1.0.0"'; Help = 'release frontend para crear Cloud Run la primera vez; por defecto la más reciente' }
)

function Test-Placeholder([string]$Value) {
    foreach ($p in $ExamplePlaceholders) { if ($Value.Contains($p)) { return $true } }
    $false
}

function Read-Config {
    $raw = @{}
    if (Test-Path -LiteralPath $ConfigFile) {
        # Se ejecuta en un ámbito propio: sus variables no alteran las del script.
        $result = & {
            param($__path, $__names)
            . $__path
            $__values = @{}
            foreach ($__name in $__names) {
                $__v = Get-Variable -Name $__name -Scope 0 -ValueOnly -ErrorAction SilentlyContinue
                if ($null -ne $__v) { $__values[$__name] = $__v }
            }
            $__values
        } $ConfigFile @($VariableSpecs | ForEach-Object { $_.Name })
        # Cualquier salida que escriba .env.ps1 se ignora; el último valor es el mapa.
        $raw = @($result | Where-Object { $_ -is [hashtable] })[-1]
    }

    $problems = New-Object System.Collections.Generic.List[object]
    function Add-Problem([string]$Name, [string]$Message) {
        $spec = $VariableSpecs | Where-Object { $_.Name -eq $Name }
        $problems.Add([pscustomobject]@{ Name = $Name; Message = $Message; Example = $spec.Example; Help = $spec.Help })
    }

    foreach ($spec in $VariableSpecs) {
        $v = $raw[$spec.Name]
        $empty = $null -eq $v -or ($v -is [string] -and [string]::IsNullOrWhiteSpace($v))
        if ($spec.Required -and $empty) { Add-Problem $spec.Name 'no está definida' }
    }

    $cfg = @{}
    foreach ($k in $raw.Keys) { $cfg[$k] = $raw[$k] }

    function Test-String([string]$Name, [string]$Pattern, [string]$Message) {
        $v = $cfg[$Name]
        if ($null -eq $v -or "$v" -eq '') { return }
        if ($v -isnot [string]) { Add-Problem $Name 'debe ser texto entre comillas'; return }
        if (Test-Placeholder $v) { Add-Problem $Name "conserva el valor de ejemplo '$v'"; return }
        if ($Pattern -and $v -notmatch $Pattern) { Add-Problem $Name $Message }
    }

    Test-String 'billing' '^[0-9A-Fa-f]{6}-[0-9A-Fa-f]{6}-[0-9A-Fa-f]{6}$' 'formato XXXXXX-XXXXXX-XXXXXX'
    Test-String 'mgmt' $ProjectPattern 'ID de proyecto inválido (6 a 30 caracteres: minúsculas, dígitos y guiones)'
    Test-String 'production' $ProjectPattern 'ID de proyecto inválido (6 a 30 caracteres: minúsculas, dígitos y guiones)'
    Test-String 'region' '^[a-z]+-[a-z]+[0-9]+$' 'región inválida, por ejemplo us-central1'
    Test-String 'operator' $EmailPattern 'correo inválido'
    Test-String 'budgetCurrency' '^[A-Z]{3}$' 'código ISO de 3 letras, por ejemplo USD'
    Test-String 'healthDataConsentVersion' '^.{1,64}$' 'de 1 a 64 caracteres'
    Test-String 'deployToolsImage' '^[a-z0-9.-]+(:[0-9]+)?/[^@\s]+@sha256:[0-9a-f]{64}$' 'debe terminar en @sha256:<64 hex> (sin latest)'
    Test-String 'initialBackendVersion' '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' 'tag SemVer vX.Y.Z'
    Test-String 'initialFrontendVersion' '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' 'tag SemVer vX.Y.Z'
    if ($cfg.deployToolsImage -match ':latest@') { Add-Problem 'deployToolsImage' 'no puede usar latest' }
    if ($cfg.mgmt -and $cfg.mgmt -eq $cfg.production) { Add-Problem 'production' 'debe ser distinto de $mgmt' }
    if ($cfg.healthDataConsentVersion -match '["\\]') { Add-Problem 'healthDataConsentVersion' 'no puede contener comillas ni barras invertidas' }

    if ($null -ne $cfg.budgetAmount -and "$($cfg.budgetAmount)" -ne '') {
        $budget = 0
        if (-not [decimal]::TryParse("$($cfg.budgetAmount)", [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$budget) -or $budget -le 0) {
            Add-Problem 'budgetAmount' 'debe ser un número mayor que 0, sin comillas'
        } else {
            $cfg.budgetAmount = $budget
            $alerts = @()
            foreach ($a in @($cfg.budgetAlertAmounts | Where-Object { $null -ne $_ })) {
                $n = 0
                if (-not [decimal]::TryParse("$a", [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -or $n -le 0 -or $n -gt $budget) {
                    Add-Problem 'budgetAlertAmounts' "cada aviso debe ser mayor que 0 y no superar budgetAmount ($a)"
                }
                $alerts += $n
            }
            $cfg.budgetAlertAmounts = $alerts
        }
    }

    if ($cfg.operator -and "$($cfg.operator)" -match $EmailPattern -and -not (Test-Placeholder "$($cfg.operator)")) {
        if (-not $cfg.approvers) { $cfg.approvers = @("user:$($cfg.operator)") }
        if (-not $cfg.operators) { $cfg.operators = @("user:$($cfg.operator)") }
        if (-not $cfg.alertEmails) { $cfg.alertEmails = @($cfg.operator) }
    }
    foreach ($name in 'approvers', 'operators') {
        $cfg[$name] = @($cfg[$name] | Where-Object { $_ })
        foreach ($m in $cfg[$name]) {
            if ("$m" -notmatch '^(user|group):[^@\s"\\]+@[^@\s"\\]+$' -or (Test-Placeholder "$m")) { Add-Problem $name "'$m' debe ser user:<correo> o group:<correo>" }
        }
    }
    $cfg.alertEmails = @($cfg.alertEmails | Where-Object { $_ })
    foreach ($m in $cfg.alertEmails) {
        if ("$m" -notmatch $EmailPattern -or (Test-Placeholder "$m")) { Add-Problem 'alertEmails' "'$m' no es un correo válido" }
    }

    if ($null -eq $cfg.releaseTriggersEnabled) { $cfg.releaseTriggersEnabled = $false }
    elseif ($cfg.releaseTriggersEnabled -isnot [bool]) { Add-Problem 'releaseTriggersEnabled' 'debe ser $true o $false (sin comillas)' }

    if ($cfg.jwtPrivateKeyFile -and -not (Test-Path -LiteralPath $cfg.jwtPrivateKeyFile -PathType Leaf)) {
        Add-Problem 'jwtPrivateKeyFile' "no existe el archivo '$($cfg.jwtPrivateKeyFile)'"
    }

    # La región de producción está versionada en terraform.tfvars.
    $tfvars = Join-Path $Roots.production 'terraform.tfvars'
    if ($cfg.region -and (Test-Path -LiteralPath $tfvars)) {
        $m = Select-String -LiteralPath $tfvars -Pattern '^\s*region\s*=\s*"([^"]+)"' | Select-Object -First 1
        if ($m -and $m.Matches[0].Groups[1].Value -ne $cfg.region) {
            Add-Problem 'region' "no coincide con region = `"$($m.Matches[0].Groups[1].Value)`" de environments/production/terraform.tfvars"
        }
    }

    [pscustomobject]@{ Values = $cfg; Problems = $problems; Exists = (Test-Path -LiteralPath $ConfigFile) }
}

function Show-ConfigReport($Config) {
    Write-Step "Variables de $ConfigFile"
    if (-not $Config.Exists) {
        Write-Bad 'el archivo no existe. Crea uno a partir de .env.example.ps1:'
        Write-Info "Copy-Item `"$(Join-Path $PlatformRoot '.env.example.ps1')`" `"$ConfigFile`""
    }
    foreach ($spec in $VariableSpecs) {
        $issues = @($Config.Problems | Where-Object { $_.Name -eq $spec.Name })
        $value = $Config.Values[$spec.Name]
        if ($issues.Count -gt 0) {
            foreach ($i in $issues) { Write-Bad ("`${0}: {1}" -f $spec.Name, $i.Message) }
        } elseif ($null -ne $value -and "$value" -ne '') {
            $shown = if ($value -is [array]) { '@(' + ($value -join ', ') + ')' } else { "$value" }
            Write-Ok ("`${0} = {1}" -f $spec.Name, $shown)
        } elseif (-not $spec.Required) {
            Write-Info ("`${0}: opcional, sin valor ({1})" -f $spec.Name, $spec.Help)
        }
    }
    if ($Config.Problems.Count -gt 0) {
        Write-Host ''
        Write-Host '  Corrige o agrega en .env.ps1 (una línea por variable):' -ForegroundColor Yellow
        foreach ($name in @($Config.Problems | ForEach-Object { $_.Name } | Select-Object -Unique)) {
            $spec = $VariableSpecs | Where-Object { $_.Name -eq $name }
            Write-Host ("    `${0} = {1}   # {2}" -f $name, $spec.Example, $spec.Help)
        }
    }
}

function Assert-Config($Config) {
    if (-not $Config.Exists -or $Config.Problems.Count -gt 0) {
        Show-ConfigReport $Config
        throw "Completa $ConfigFile antes de continuar (detalle arriba)."
    }
}

# --- Archivos de variables generados -----------------------------------------

function ConvertTo-Hcl($Value) {
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [decimal] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        return ([decimal]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [array]) { return '[' + ((@($Value) | ForEach-Object { ConvertTo-Hcl $_ }) -join ', ') + ']' }
    '"' + ("$Value" -replace '\\', '\\' -replace '"', '\"' -replace '\$\{', '$$$${') + '"'
}

function Format-HclMap([System.Collections.Specialized.OrderedDictionary]$Map, [int]$Indent = 2) {
    $pad = ' ' * $Indent
    $width = ($Map.Keys | Measure-Object -Property Length -Maximum).Maximum
    $lines = foreach ($k in $Map.Keys) { "$pad$($k.PadRight($width)) = $(ConvertTo-Hcl $Map[$k])" }
    "{`n" + ($lines -join "`n") + "`n" + (' ' * ($Indent - 2)) + '}'
}

function Get-BootstrapOutputs {
    $state = Join-Path $Roots.bootstrap 'terraform.tfstate'
    if (-not (Test-BootstrapRemote) -and -not (Test-Path -LiteralPath $state)) { return $null }
    $r = Invoke-Capture terraform @("-chdir=$($Roots.bootstrap)", 'output', '-json') -AllowFailure
    if ($r.ExitCode -ne 0 -or -not $r.Output) { return $null }
    $o = ConvertFrom-JsonText $r.Output
    $apply = Get-Value (Get-Value (Get-Value $o 'apply_service_accounts') 'value') 'production'
    if (-not $apply) { return $null }
    $ids = Get-Value (Get-Value $o 'delivery_identities') 'value'
    [pscustomobject]@{
        ApplyAccount = $apply
        StateBucket  = Get-Value (Get-Value (Get-Value $o 'state_buckets') 'value') 'production'
        Delivery     = [ordered]@{
            build_backend    = Get-Value $ids 'build_backend'
            build_frontend   = Get-Value $ids 'build_frontend'
            release_promoter = Get-Value $ids 'release_promoter'
            deploy_execution = Get-Value $ids 'deploy_execution'
        }
    }
}

function Test-BootstrapRemote {
    $versions = Get-Content -LiteralPath (Join-Path $Roots.bootstrap 'versions.tf') -Raw
    $versions -match '(?m)^\s*backend\s+"gcs"'
}

function Get-DesiredFiles($Cfg, $Boot, [bool]$ConnectionReady) {
    $files = [ordered]@{}

    $environment = [ordered]@{
        project_id           = $Cfg.production
        operators            = @($Cfg.operators)
        budget_amount        = $Cfg.budgetAmount
        budget_alert_amounts = @($Cfg.budgetAlertAmounts)
        delivery             = $true
    }
    $files[(Join-Path $Roots.bootstrap 'bootstrap.auto.tfvars')] = @(
        "management_project_id = $(ConvertTo-Hcl $Cfg.mgmt)"
        "region                = $(ConvertTo-Hcl $Cfg.region)"
        "billing_account       = $(ConvertTo-Hcl $Cfg.billing)"
        "budget_currency       = $(ConvertTo-Hcl $Cfg.budgetCurrency)"
        ''
        'environments = {'
        "  production = $(Format-HclMap $environment 4)"
        '}'
    ) -join "`n"

    if (-not $Boot) { return $files }

    $backend = @(
        "bucket                      = $(ConvertTo-Hcl $Boot.StateBucket)"
        "impersonate_service_account = $(ConvertTo-Hcl $Boot.ApplyAccount)"
    ) -join "`n"
    $identities = "delivery_identities = $(Format-HclMap $Boot.Delivery)"

    $files[(Join-Path $Roots.production 'backend.hcl')] = $backend
    $files[(Join-Path $Roots.production 'gcp.auto.tfvars')] = @(
        "project_id                  = $(ConvertTo-Hcl $Cfg.production)"
        "impersonate_service_account = $(ConvertTo-Hcl $Boot.ApplyAccount)"
        "health_data_consent_version = $(ConvertTo-Hcl $Cfg.healthDataConsentVersion)"
        "alert_emails                = $(ConvertTo-Hcl @($Cfg.alertEmails))"
        ''
        $identities
        ''
        '# cloud_run_images está en cloud-run-images.auto.tfvars.json (también generado).'
    ) -join "`n"

    $files[(Join-Path $Roots.workloads 'backend.hcl')] = $backend
    $files[(Join-Path $Roots.workloads 'gcp.auto.tfvars')] = @(
        "project_id                  = $(ConvertTo-Hcl $Cfg.production)"
        "region                      = $(ConvertTo-Hcl $Cfg.region)"
        "state_bucket                = $(ConvertTo-Hcl $Boot.StateBucket)"
        "impersonate_service_account = $(ConvertTo-Hcl $Boot.ApplyAccount)"
    ) -join "`n"

    $files[(Join-Path $Roots.delivery 'backend.hcl')] = $backend
    $files[(Join-Path $Roots.delivery 'gcp.auto.tfvars')] = @(
        "management_project_id       = $(ConvertTo-Hcl $Cfg.mgmt)"
        "region                      = $(ConvertTo-Hcl $Cfg.region)"
        "impersonate_service_account = $(ConvertTo-Hcl $Boot.ApplyAccount)"
        "state_bucket                = $(ConvertTo-Hcl $Boot.StateBucket)"
        ''
        $identities
        ''
        "approvers          = $(ConvertTo-Hcl @($Cfg.approvers))"
        "deploy_tools_image = $(ConvertTo-Hcl $Cfg.deployToolsImage)"
        ''
        '# github_connection_ready: true cuando la conexión github está en COMPLETE.'
        "github_connection_ready  = $(ConvertTo-Hcl $ConnectionReady)"
        "release_triggers_enabled = $(ConvertTo-Hcl ([bool]($ConnectionReady -and $Cfg.releaseTriggersEnabled)))"
    ) -join "`n"

    $files
}

function Get-FileStatus([string]$Path, [string]$Body) {
    $wanted = "$GeneratedHeader`n$Body`n"
    if (-not (Test-Path -LiteralPath $Path)) { return 'nuevo' }
    $current = ([IO.File]::ReadAllText($Path)) -replace "`r`n", "`n"
    if ($current -eq $wanted) { return 'al día' }
    if (-not $current.StartsWith($GeneratedHeader)) { return 'manual' }
    'desactualizado'
}

function Write-TextFile([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

function Save-Backup([string]$Path, [string]$Kind) {
    $dir = Join-Path $BackupRoot $Kind
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $relative = $Path.Substring($TerraformRoot.Length).TrimStart('\') -replace '[\\/]', '_'
    $target = Join-Path $dir ("{0}-{1}" -f $relative, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $Path -Destination $target
    $target
}

function Sync-GeneratedFiles($Cfg, $Boot, [bool]$ConnectionReady) {
    $files = Get-DesiredFiles $Cfg $Boot $ConnectionReady
    foreach ($path in $files.Keys) {
        $status = Get-FileStatus $path $files[$path]
        $name = $path.Substring($TerraformRoot.Length).TrimStart('\')
        if ($status -eq 'al día') { continue }
        if ($status -eq 'manual') {
            $copy = Save-Backup $path 'vars'
            Write-Note "$name no lo generó este script; copia de respaldo en $copy"
        }
        Write-TextFile $path "$GeneratedHeader`n$($files[$path])`n"
        Write-Ok "$name ($status -> generado)"
    }
    if (-not (Test-Path -LiteralPath $CloudRunImagesFile)) { Save-CloudRunImages @{} }
}

function Get-CloudRunImages {
    if (-not (Test-Path -LiteralPath $CloudRunImagesFile)) { return @{} }
    $o = ConvertFrom-JsonText ([IO.File]::ReadAllText($CloudRunImagesFile))
    $images = @{}
    $map = Get-Value $o 'cloud_run_images'
    foreach ($k in Get-Keys $map) { $images[$k] = Get-Value $map $k }
    $images
}

function Save-CloudRunImages([hashtable]$Images) {
    $entries = foreach ($k in @('web', 'bff-web', 'bff-mobile')) {
        if ($Images[$k]) { "    `"$k`": `"$($Images[$k])`"" }
    }
    $body = if ($entries) { "{`n  `"cloud_run_images`": {`n" + (@($entries) -join ",`n") + "`n  }`n}`n" } else { "{`n  `"cloud_run_images`": {}`n}`n" }
    Write-TextFile $CloudRunImagesFile $body
}

# --- Terraform ----------------------------------------------------------------

function Initialize-Root([string]$Key) {
    $root = $Roots[$Key]
    $arguments = @("-chdir=$root", 'init', '-input=false', '-no-color')
    if ($Key -eq 'bootstrap') {
        if (Test-BootstrapRemote) { $arguments += @('-reconfigure', "-backend-config=bucket=$($script:Cfg.mgmt)-tfstate-production") }
    } else {
        $arguments += @('-reconfigure', '-backend-config=backend.hcl')
    }
    Invoke-Show terraform $arguments
}

function Get-PlanChanges([string]$Root, [string]$PlanFile) {
    $r = Invoke-Capture terraform @("-chdir=$Root", 'show', '-json', $PlanFile)
    $plan = ConvertFrom-JsonText $r.Output
    $changes = foreach ($rc in @(Get-Value $plan 'resource_changes')) {
        if ($null -eq $rc) { continue }
        $actions = @(Get-Value (Get-Value $rc 'change') 'actions') -join ','
        if ($actions -eq 'no-op' -or $actions -eq 'read' -or $actions -eq '') { continue }
        [pscustomobject]@{ Address = Get-Value $rc 'address'; Type = Get-Value $rc 'type'; Actions = $actions }
    }
    @($changes)
}

function Test-AnyMatch([string]$Text, [string[]]$Patterns) {
    foreach ($p in $Patterns) { if ($Text -match $p) { return $true } }
    $false
}

# plan -> revisión automática -> confirmación -> apply del plan guardado.
# Devuelve $true si aplicó cambios. -PlanOnly solo genera y revisa el plan.
function Invoke-TerraformStep {
    param(
        [string]$Key,
        [string]$Name,
        [string]$Purpose,
        [string[]]$PlanArgs = @(),
        [switch]$Destroy,
        [string[]]$DeletablePatterns = @(),
        [switch]$OnlyUpdates,
        [switch]$PlanOnly,
        [int]$Attempt = 1
    )
    $root = $Roots[$Key]
    $planFile = "tfplan-$Name"
    Write-Step "$Purpose ($Key)"
    $arguments = @("-chdir=$root", 'plan', '-input=false', '-no-color', '-lock-timeout=120s', '-detailed-exitcode', "-out=$planFile") + $PlanArgs
    if ($Destroy) { $arguments += '-destroy' }
    Invoke-Show terraform $arguments -AllowedExitCodes @(0, 2)
    if ($script:NativeExit -eq 0) { Write-Ok 'sin cambios'; return $false }

    $changes = Get-PlanChanges $root $planFile
    $count = @{}
    foreach ($c in $changes) {
        if ($c.Actions -match 'delete' -and $c.Actions -match 'create') { $kind = 'reemplazar' }
        elseif ($c.Actions -eq 'delete') { $kind = 'eliminar' }
        elseif ($c.Actions -eq 'create') { $kind = 'crear' }
        elseif ($c.Actions -eq 'update') { $kind = 'actualizar' }
        else { $kind = $c.Actions }
        $count[$kind] = 1 + [int]$count[$kind]
    }
    Write-Step "Revisión del plan $planFile"
    Write-Info (($count.Keys | Sort-Object | ForEach-Object { "$_ $($count[$_])" }) -join ' | ')
    Write-Info "Detalle: terraform -chdir=`"$root`" show $planFile"

    $forbidden = @($changes | Where-Object { $_.Actions -match 'create' -and (Test-AnyMatch $_.Type $ForbiddenTypes) })
    if ($forbidden.Count -gt 0) {
        $forbidden | ForEach-Object { Write-Bad "$($_.Address) ($($_.Actions))" }
        throw 'El plan crea recursos prohibidos por el modelo de seguridad; no se aplica.'
    }
    if ($OnlyUpdates) {
        $other = @($changes | Where-Object { $_.Actions -ne 'update' })
        if ($other.Count -gt 0) {
            $other | ForEach-Object { Write-Bad "$($_.Address) ($($_.Actions))" }
            throw 'Este paso solo debe actualizar atributos (protecciones) y el plan crea o elimina recursos; no se aplica.'
        }
    }
    $deletes = @($changes | Where-Object { $_.Actions -match 'delete' })
    $unexpected = @($deletes | Where-Object { -not (Test-AnyMatch $_.Address $DeletablePatterns) })
    if ($Destroy -and $unexpected.Count -gt 0) {
        $unexpected | ForEach-Object { Write-Bad "$($_.Address) ($($_.Actions))" }
        throw 'La destrucción alcanzaría recursos del plano que se conserva; no se aplica.'
    }
    if ($deletes.Count -gt 0) {
        Write-Note 'El plan elimina o reemplaza:'
        $deletes | ForEach-Object { Write-Info "$($_.Address) ($($_.Actions))" }
    }
    if ($PlanOnly) { Remove-Item -LiteralPath (Join-Path $root $planFile) -ErrorAction SilentlyContinue; return $false }
    if (-not $Destroy -and $unexpected.Count -gt 0) {
        Confirm-Step 'El plan elimina o reemplaza recursos (lista arriba). ¿Aplicarlo?' -Always
    } else {
        Confirm-Step "¿Aplicar $($planFile)?"
    }
    Invoke-Show terraform @("-chdir=$root", 'apply', '-input=false', '-no-color', '-lock-timeout=120s', $planFile) -AllowedExitCodes @(0, 1)
    if ($script:NativeExit -ne 0) {
        # Lo creado antes del error ya está en el estado: un plan nuevo continúa desde ahí.
        if ($Attempt -ge 3) { throw "El apply de $planFile falló $Attempt veces; revisa el error anterior." }
        Write-Note 'El apply falló. Si el error es transitorio (cuota por minuto, API recién habilitada o propagación de IAM), un plan nuevo continúa desde lo que ya se creó.'
        Confirm-Step '¿Esperar 60 s y reintentar con un plan nuevo?'
        Start-Sleep -Seconds 60
        $PSBoundParameters['Attempt'] = $Attempt + 1
        return (Invoke-TerraformStep @PSBoundParameters)
    }
    $true
}

function Get-RootOutputs([string]$Key) {
    $r = Invoke-Capture terraform @("-chdir=$($Roots[$Key])", 'output', '-json') -AllowFailure
    if ($r.ExitCode -ne 0 -or -not $r.Output) { return $null }
    ConvertFrom-JsonText $r.Output
}

function Get-StateAddresses([string]$Key) {
    $r = Invoke-Capture terraform @("-chdir=$($Roots[$Key])", 'state', 'list') -AllowFailure
    if ($r.ExitCode -ne 0) { return @() }
    @($r.Output -split "`n" | Where-Object { $_ })
}

function Backup-BootstrapState {
    $r = Invoke-Capture terraform @("-chdir=$($Roots.bootstrap)", 'state', 'pull')
    $dir = Join-Path $BackupRoot 'state'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $file = Join-Path $dir ("bootstrap-{0}.tfstate" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-TextFile $file $r.Output
    Write-Ok "respaldo del estado del bootstrap: $file"
    Write-Info "SHA256 $((Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash)"
}

# --- Comprobaciones de la estación y de GCP ----------------------------------

function Test-Tools([switch]$Quiet) {
    $missing = @()
    foreach ($t in @(
            @{ Name = 'terraform'; Install = 'winget install --id Hashicorp.Terraform -e' }
            @{ Name = 'gcloud'; Install = 'winget install --id Google.CloudSDK -e' }
            @{ Name = 'git'; Install = 'winget install --id Git.Git -e' }
        )) {
        if (-not (Get-Command $t.Name -ErrorAction SilentlyContinue)) {
            Write-Bad "$($t.Name) no está instalado: $($t.Install)"
            $missing += $t.Name
        }
    }
    if ($missing.Count -gt 0) { return $false }
    $tf = ConvertFrom-JsonText (Invoke-Capture terraform @('version', '-json')).Output
    $version = [version]((Get-Value $tf 'terraform_version') -replace '-.*$', '')
    if ($version -lt [version]'1.11.0') { Write-Bad "Terraform $version; se requiere >= 1.11"; return $false }
    if (-not $Quiet) {
        Write-Ok "terraform $version"
        Write-Ok "gcloud $(Get-Value (Invoke-GcloudJson @('version') -AllowFailure) 'Google Cloud SDK')"
        Write-Ok ((Invoke-Capture git @('version') -AllowFailure).Output)
        if (Get-Command kubectl -ErrorAction SilentlyContinue) { Write-Ok 'kubectl (opcional, para verificar GKE)' }
        else { Write-Info 'kubectl no está instalado (opcional): winget install --id Kubernetes.kubectl -e' }
    }
    $true
}

function Test-Auth($Cfg, [switch]$Interactive) {
    $account = (Invoke-Capture gcloud @('config', 'get-value', 'account', '--quiet') -AllowFailure).Output
    if (-not $account -or $account -eq '(unset)') {
        if (-not $Interactive) { Write-Bad 'gcloud no tiene una cuenta activa: gcloud auth login'; return $false }
        Write-Note 'gcloud no tiene cuenta activa; se abrirá el navegador.'
        Invoke-Show gcloud @('auth', 'login', $Cfg.operator)
        $account = (Invoke-Capture gcloud @('config', 'get-value', 'account', '--quiet')).Output
    }
    if ($account -ne $Cfg.operator) {
        Write-Bad "la cuenta activa de gcloud es '$account' y `$operator es '$($Cfg.operator)'"
        Write-Info "Cambia con: gcloud config set account $($Cfg.operator)   (o gcloud auth login $($Cfg.operator))"
        return $false
    }
    Write-Ok "cuenta activa de gcloud: $account"

    $adc = Invoke-Capture gcloud @('auth', 'application-default', 'print-access-token', '--quiet') -AllowFailure
    if ($adc.ExitCode -ne 0) {
        if (-not $Interactive) { Write-Bad 'faltan las credenciales de aplicación (ADC): gcloud auth application-default login'; return $false }
        Write-Note 'Faltan las credenciales ADC que usa Terraform; se abrirá el navegador.'
        Invoke-Show gcloud @('auth', 'application-default', 'login')
    }
    Write-Ok 'credenciales ADC disponibles (fuera del repositorio)'
    $true
}

function Get-ConnectionStage($Cfg) {
    $r = Invoke-Capture gcloud @('builds', 'connections', 'describe', 'github', "--region=$($Cfg.region)", "--project=$($Cfg.mgmt)", '--format=value(installationState.stage)', '--quiet') -AllowFailure
    if ($r.ExitCode -ne 0) { return '' }
    $r.Output
}

function Test-Impersonation([string]$Account) {
    for ($i = 1; $i -le 10; $i++) {
        $r = Invoke-Capture gcloud @('auth', 'print-access-token', "--impersonate-service-account=$Account", '--quiet') -AllowFailure
        if ($r.ExitCode -eq 0) { Write-Ok "el operador puede impersonar $Account"; return }
        if ($i -eq 10) { break }
        Write-Note "todavía sin permiso para impersonar $Account (propagación de IAM); reintento $i/9 en 30 s"
        Start-Sleep -Seconds 30
    }
    throw "No se pudo impersonar $Account. Revisa que `$operator esté en operators y que el bootstrap haya terminado."
}

# --- Pasos de la fase fija ----------------------------------------------------

function Initialize-Projects($Cfg) {
    Write-Step 'Proyectos y facturación'
    foreach ($p in @(@{ Id = $Cfg.mgmt; Name = 'SportApp gestion' }, @{ Id = $Cfg.production; Name = 'SportApp produccion' })) {
        $exists = Invoke-Capture gcloud @('projects', 'describe', $p.Id, '--format=value(projectId)', '--quiet') -AllowFailure
        if ($exists.ExitCode -ne 0) {
            Confirm-Step "El proyecto $($p.Id) no existe o no es accesible. ¿Crearlo?"
            Invoke-Show gcloud @('projects', 'create', $p.Id, "--name=$($p.Name)", '--quiet')
        } else { Write-Ok "proyecto $($p.Id)" }
        $billing = Invoke-Capture gcloud @('billing', 'projects', 'describe', $p.Id, '--format=value(billingEnabled)', '--quiet') -AllowFailure
        if ($billing.Output -ne 'True') {
            Invoke-Show gcloud @('billing', 'projects', 'link', $p.Id, "--billing-account=$($Cfg.billing)", '--quiet')
        }
        Write-Ok "facturación habilitada en $($p.Id)"
    }
}

function Enable-Apis([string]$Project, [string[]]$Apis) {
    $enabled = @((Invoke-Capture gcloud @('services', 'list', '--enabled', "--project=$Project", '--format=value(config.name)', '--quiet')).Output -split "`n")
    $missing = @($Apis | Where-Object { $enabled -notcontains $_ })
    if ($missing.Count -eq 0) { Write-Ok "APIs de arranque habilitadas en $Project"; return $false }
    Write-Info "habilitando en ${Project}: $($missing -join ', ')"
    Invoke-Show gcloud (@('services', 'enable') + $missing + @("--project=$Project", '--quiet'))
    $true
}

function Initialize-BaseApis($Cfg) {
    Write-Step 'APIs de arranque y agentes de Cloud Build y Cloud Deploy'
    $changed = Enable-Apis $Cfg.mgmt @('cloudresourcemanager.googleapis.com', 'serviceusage.googleapis.com', 'cloudbuild.googleapis.com', 'clouddeploy.googleapis.com')
    $changed = (Enable-Apis $Cfg.production @('cloudresourcemanager.googleapis.com', 'serviceusage.googleapis.com')) -or $changed

    foreach ($service in 'clouddeploy', 'cloudbuild') {
        $r = Invoke-Capture gcloud @('beta', 'services', 'identity', 'create', "--service=$service.googleapis.com", "--project=$($Cfg.mgmt)", '--format=value(email)', '--quiet')
        Write-Ok "agente $service`: $($r.Output)"
    }

    # Sección 5.3: el agente de Cloud Deploy necesita su rol de agente.
    $number = (Invoke-Capture gcloud @('projects', 'describe', $Cfg.mgmt, '--format=value(projectNumber)', '--quiet')).Output
    $agent = "serviceAccount:service-$number@gcp-sa-clouddeploy.iam.gserviceaccount.com"
    $roles = (Invoke-Capture gcloud @('projects', 'get-iam-policy', $Cfg.mgmt, '--flatten=bindings[].members', "--filter=bindings.members:$agent", '--format=value(bindings.role)', '--quiet')).Output
    if ($roles -notmatch 'roles/clouddeploy.serviceAgent') {
        Invoke-Show gcloud @('projects', 'add-iam-policy-binding', $Cfg.mgmt, "--member=$agent", '--role=roles/clouddeploy.serviceAgent', '--condition=None', '--quiet', '--format=none')
        $changed = $true
    }
    if ($changed) { Write-Note 'esperando 90 s a que se propaguen las APIs y los agentes'; Start-Sleep -Seconds 90 }
}

function Invoke-Bootstrap($Cfg) {
    Sync-GeneratedFiles $Cfg $null $false
    Initialize-Root 'bootstrap'
    $applied = Invoke-TerraformStep -Key bootstrap -Name bootstrap -Purpose 'Bootstrap: estado, identidades y presupuesto' -DeletablePatterns $BootstrapDeletable
    if ($applied -and -not (Test-BootstrapRemote)) { Backup-BootstrapState }
    $boot = Get-BootstrapOutputs
    if (-not $boot -or -not $boot.StateBucket -or -not $boot.Delivery.deploy_execution) {
        throw 'El bootstrap no tiene las salidas esperadas (state_buckets, apply_service_accounts, delivery_identities).'
    }
    $boot
}

# --- Pasos de la fase operativa ----------------------------------------------

function Get-Prepared($Cfg) {
    $boot = Get-BootstrapOutputs
    if (-not $boot) { throw 'El bootstrap todavía no está aplicado en esta estación: ejecuta primero "setup".' }
    $ready = (Get-ConnectionStage $Cfg) -eq 'COMPLETE'
    Write-Step 'Archivos de variables'
    Sync-GeneratedFiles $Cfg $boot $ready
    Test-Impersonation $boot.ApplyAccount
    [pscustomobject]@{ Boot = $boot; ConnectionReady = $ready }
}

function Invoke-Production([string]$Name = 'production') {
    Initialize-Root 'production'
    [void](Invoke-TerraformStep -Key production -Name $Name -Purpose 'Infraestructura de producción')
    $out = Get-RootOutputs 'production'
    if (-not (Get-Value $out 'gke')) { throw 'production no tiene salidas después del apply; revisa el error anterior.' }
}

function Initialize-AppSecrets($Cfg) {
    Write-Step 'Versiones de los secretos de aplicación'
    $ids = Get-Value (Get-Value (Get-RootOutputs 'production') 'app_secret_ids') 'value'
    # Lista de ids (una lista de un elemento llega como texto) o mapa id -> recurso.
    if ($ids -is [System.Collections.IDictionary] -or $ids -is [System.Management.Automation.PSCustomObject]) { $names = Get-Keys $ids }
    else { $names = @($ids | Where-Object { $_ }) }
    $pending = @()
    foreach ($id in $names) {
        $secret = ($id -split '/')[-1]
        $versions = (Invoke-Capture gcloud @('secrets', 'versions', 'list', $secret, "--project=$($Cfg.production)", '--filter=state:ENABLED', '--format=value(name)', '--quiet')).Output
        if ($versions) { Write-Ok "$secret tiene una versión habilitada"; continue }
        if ($secret -eq 'users-jwt-private-key' -and $Cfg.jwtPrivateKeyFile) {
            Invoke-Show gcloud @('secrets', 'versions', 'add', $secret, "--data-file=$($Cfg.jwtPrivateKeyFile)", "--project=$($Cfg.production)", '--quiet')
            Write-Ok "$secret cargado desde `$jwtPrivateKeyFile"
            continue
        }
        $pending += $secret
    }
    if ($pending.Count -gt 0) {
        $msg = "Faltan versiones en Secret Manager: $($pending -join ', ')."
        if ($pending -contains 'users-jwt-private-key') {
            $msg += "`nPara users-jwt-private-key define `$jwtPrivateKeyFile en .env.ps1 con una clave Ed25519 guardada fuera del repositorio, por ejemplo:" +
            "`n  & `"C:\Program Files\Git\usr\bin\openssl.exe`" genpkey -algorithm ed25519 -out C:\ruta-segura\sportapp-users-jwt.pem"
        }
        throw [ManualStep]::new("$msg`nDespués ejecuta de nuevo este comando.")
    }
}

function Invoke-Workloads([string]$Name = 'workloads') {
    if (-not (Test-Path -LiteralPath $BackendBase)) {
        Write-Step 'Submódulo components/backend (Services de GKE)'
        # .gitmodules declara update = none; --checkout lo reemplaza solo para esta descarga.
        # core.longpaths: la ruta del proyecto supera MAX_PATH en algunas migraciones.
        Invoke-Show git @('-C', $PlatformRoot, '-c', 'core.longpaths=true', 'submodule', 'update', '--init', '--checkout', 'components/backend')
        if (-not (Test-Path -LiteralPath $BackendBase)) {
            throw "El commit fijado del submódulo components/backend no tiene deploy/k8s/base. Actualízalo al tag publicado del backend (o a develop antes de la primera release):`n  git -C components/backend fetch origin`n  git -C components/backend checkout --detach origin/develop"
        }
    }
    Initialize-Root 'workloads'
    [void](Invoke-TerraformStep -Key workloads -Name $Name -Purpose 'Base Kubernetes en GKE')
}

# Terraform no puede crear la conexión pendiente (la API exige github_config y el
# provider omite el bloque vacío): se crea con gcloud, sin PAT, y se importa.
function Initialize-GithubConnection($Cfg) {
    $id = "projects/$($Cfg.mgmt)/locations/$($Cfg.region)/connections/github"
    $exists = (Invoke-Capture gcloud @('builds', 'connections', 'describe', 'github', "--region=$($Cfg.region)", "--project=$($Cfg.mgmt)", '--format=value(name)', '--quiet') -AllowFailure).ExitCode -eq 0
    if (-not $exists) {
        Write-Step 'Conexión github de Cloud Build (pendiente de autorizar)'
        Invoke-Show gcloud @('builds', 'connections', 'create', 'github', 'github', "--region=$($Cfg.region)", "--project=$($Cfg.mgmt)", '--quiet')
    }
    if ((Get-StateAddresses 'delivery') -notcontains 'google_cloudbuildv2_connection.github') {
        Write-Step 'Importar la conexión github al estado de delivery'
        Invoke-Show terraform @("-chdir=$($Roots.delivery)", 'import', '-input=false', '-no-color', '-lock-timeout=120s', 'google_cloudbuildv2_connection.github', $id)
    }
}

function Invoke-Delivery($Cfg, $Prepared, [string]$Name) {
    Sync-GeneratedFiles $Cfg $Prepared.Boot $Prepared.ConnectionReady
    Initialize-Root 'delivery'
    Initialize-GithubConnection $Cfg
    [void](Invoke-TerraformStep -Key delivery -Name $Name -Purpose 'Cloud Build y Cloud Deploy')
}

function Get-LatestTag([string]$Prefix, [string]$Preferred) {
    $r = Invoke-Capture gcloud @('storage', 'ls', $Prefix, '--quiet') -AllowFailure
    if ($r.ExitCode -ne 0) { return $null }
    $tags = foreach ($line in $r.Output -split "`n") {
        if ($line -match '/(v([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?)/$') {
            [pscustomobject]@{ Tag = $Matches[1]; Major = [int]$Matches[2]; Minor = [int]$Matches[3]; Patch = [int]$Matches[4]; Stable = -not $Matches[5] }
        }
    }
    $tags = @($tags)
    if ($Preferred) { return ($tags | Where-Object { $_.Tag -eq $Preferred } | ForEach-Object { $_.Tag } | Select-Object -First 1) }
    ($tags | Sort-Object Stable, Major, Minor, Patch, Tag | Select-Object -Last 1).Tag
}

# Primera creación de Cloud Run: digests de web, bff-web y bff-mobile tomados de
# la evidencia de Cloud Build.
function Get-InitialCloudRunImages($Cfg) {
    $buckets = Get-Value (Get-Value (Get-RootOutputs 'delivery') 'evidence_buckets') 'value'
    $backendBucket = Get-Value $buckets 'backend'
    $frontendBucket = Get-Value $buckets 'frontend'
    if (-not $backendBucket -or -not $frontendBucket) { return $null }
    $backendTag = Get-LatestTag "gs://$backendBucket/sport-app-backend/" $Cfg.initialBackendVersion
    $frontendTag = Get-LatestTag "gs://$frontendBucket/frontend/" $Cfg.initialFrontendVersion
    if (-not $backendTag -or -not $frontendTag) { return $null }

    $backend = ConvertFrom-JsonText (Invoke-Capture gcloud @('storage', 'cat', "gs://$backendBucket/sport-app-backend/$backendTag/backend-release.json", '--quiet')).Output
    $frontend = ConvertFrom-JsonText (Invoke-Capture gcloud @('storage', 'cat', "gs://$frontendBucket/frontend/$frontendTag/frontend-release.json", '--quiet')).Output
    $images = @{
        'bff-web'    = Get-Value (Get-Value $backend 'images') 'bff-web'
        'bff-mobile' = Get-Value (Get-Value $backend 'images') 'bff-mobile'
        'web'        = Get-Value (Get-Value $frontend 'image') 'uri'
    }
    $registry = [regex]::Escape("$($Cfg.region)-docker.pkg.dev/$($Cfg.production)/")
    foreach ($k in @($images.Keys)) {
        if ("$($images[$k])" -notmatch "^$registry(sportapp-backend|sportapp-frontend)/$([regex]::Escape($k))@sha256:[0-9a-f]{64}$") {
            throw "La evidencia de $k no trae una imagen propia por digest: '$($images[$k])'."
        }
    }
    Write-Ok "digests de Cloud Run desde backend $backendTag y frontend $frontendTag"
    $images
}

function Show-PromoteHint($Cfg) {
    $releases = Invoke-GcloudJson @('deploy', 'releases', 'list', '--delivery-pipeline=backend-gke', "--region=$($Cfg.region)", "--project=$($Cfg.mgmt)", '--sort-by=~createTime', '--limit=1') -AllowFailure
    $version = $null
    foreach ($r in @($releases)) { $version = Get-Value (Get-Value $r 'annotations') 'sportapp.io/version' }
    Write-Step 'Siguiente paso: desplegar las cargas con Cloud Deploy'
    # Corto a propósito: Cloud Deploy nombra el rollout <release>-to-<target>-0001 con
    # un máximo de 63 caracteres, y el target más largo es production-gke-migrations.
    $suffix = 'r' + (Get-Random -Minimum 1 -Maximum 10)
    if ($version) {
        if ($version -notmatch '^v') { $version = "v$version" }
        Write-Info "GKE quedó sin Deployments y Cloud SQL vacía. Vuelve a promover la última release del backend ($version):"
        Write-Info ".\scripts\sportapp-gcp.ps1 promote -BackendVersion $version -ReleaseSuffix $suffix"
    } else {
        Write-Info 'Promueve las releases publicadas por Cloud Build (primero backend, después frontend):'
        Write-Info '.\scripts\sportapp-gcp.ps1 promote -BackendVersion vX.Y.Z -FrontendVersion vA.B.C'
    }
    Write-Info "Después aprueba en Cloud Deploy: production-gke-migrations, luego production-gke, bff-web, bff-mobile y frontend-web."
}

# --- Comandos -----------------------------------------------------------------

function Invoke-Check($Config) {
    Write-Step 'Herramientas'
    $toolsOk = Test-Tools
    Show-ConfigReport $Config
    $cfg = $Config.Values
    $ok = $toolsOk -and $Config.Exists -and $Config.Problems.Count -eq 0

    Write-Step 'Archivos versionados'
    foreach ($f in @('production\terraform.tfvars', 'production\gcp.auto.tfvars.example', 'delivery\gcp.auto.tfvars.example', 'production-workloads\gcp.auto.tfvars.example')) {
        $path = Join-Path (Join-Path $TerraformRoot 'environments') $f
        if (Test-Path -LiteralPath $path) { Write-Ok "environments\$f" } else { Write-Bad "environments\$f no existe"; $ok = $false }
    }
    if (Test-Path -LiteralPath $BackendBase) { Write-Ok 'components\backend\deploy\k8s\base' }
    else { Write-Note 'components\backend no está descargado; setup/up ejecutan git submodule update --init components/backend' }

    $boot = $null
    if ($toolsOk) { $boot = Get-BootstrapOutputs }
    Write-Step 'Estado del bootstrap'
    if ($boot) {
        Write-Ok "tf-apply: $($boot.ApplyAccount)"
        Write-Ok "bucket de estado: $($boot.StateBucket)"
    } else { Write-Note 'sin salidas del bootstrap: setup lo aplicará primero' }

    if ($Config.Problems.Count -eq 0 -and $Config.Exists) {
        Write-Step 'Archivos de variables que genera el script'
        $ready = $false
        if (-not $Offline -and $boot) { $ready = (Get-ConnectionStage $cfg) -eq 'COMPLETE' }
        $files = Get-DesiredFiles $cfg $boot $ready
        foreach ($path in $files.Keys) {
            $name = $path.Substring($TerraformRoot.Length).TrimStart('\')
            switch (Get-FileStatus $path $files[$path]) {
                'al día' { Write-Ok $name }
                'nuevo' { Write-Info "$name se creará" }
                'desactualizado' { Write-Note "$name se regenerará con los valores actuales de .env.ps1" }
                'manual' { Write-Note "$name fue editado a mano; se respaldará en $BackupRoot\vars y se regenerará" }
            }
        }
        if (-not $boot) { Write-Info 'los gcp.auto.tfvars y backend.hcl se generan con las salidas del bootstrap' }
        $images = Get-CloudRunImages
        if ($images.Count -gt 0) { Write-Ok "cloud-run-images.auto.tfvars.json: $(@($images.Keys) -join ', ')" }
        else { Write-Info 'cloud-run-images.auto.tfvars.json: vacío hasta la primera release (Cloud Run aún no se crea)' }
    }

    if ($Validate -and $toolsOk) {
        Write-Step 'terraform validate (sin backend)'
        foreach ($key in $Roots.Keys) {
            Invoke-Show terraform @("-chdir=$($Roots[$key])", 'init', '-backend=false', '-input=false', '-no-color') -AllowedExitCodes @(0, 1)
            Invoke-Show terraform @("-chdir=$($Roots[$key])", 'validate', '-no-color') -AllowedExitCodes @(0, 1)
            if ($script:NativeExit -eq 0) { Write-Ok "$key válido" } else { Write-Bad "$key no valida"; $ok = $false }
        }
    }

    if (-not $Offline -and $toolsOk -and $Config.Problems.Count -eq 0 -and $Config.Exists) {
        Write-Step 'Autenticación'
        $ok = (Test-Auth $cfg) -and $ok
        if ($boot) {
            $stage = Get-ConnectionStage $cfg
            if ($stage) { Write-Ok "conexión github de Cloud Build: $stage" } else { Write-Info 'conexión github de Cloud Build: todavía no existe' }
        }
    }

    Write-Host ''
    if ($ok) { Write-Host 'Todo listo. Siguiente: .\scripts\sportapp-gcp.ps1 setup (primera vez) o up/down.' -ForegroundColor Green }
    else { throw 'Hay pendientes (marcados con [falta]).' }
}

function Invoke-Setup($Cfg) {
    Write-Step 'Estación'
    if (-not (Test-Tools)) { throw 'Instala las herramientas que faltan.' }
    if (-not (Test-Auth $Cfg -Interactive)) { throw 'Corrige la autenticación de gcloud.' }

    # Fase fija (secciones 5 y 7).
    Initialize-Projects $Cfg
    Initialize-BaseApis $Cfg
    [void](Invoke-Bootstrap $Cfg)

    # Fase operativa (sección 12).
    $prepared = Get-Prepared $Cfg
    Invoke-Production
    Initialize-AppSecrets $Cfg
    Invoke-Workloads

    # Entrega (sección 13): conexión, autorización manual, repositorios y triggers.
    Invoke-Delivery $Cfg $prepared 'delivery'
    if (-not $prepared.ConnectionReady) {
        Write-Step 'Paso manual: autorizar la GitHub App de Cloud Build (una sola vez)'
        Write-Info "1. Abre https://console.cloud.google.com/cloud-build/repositories/2nd-gen?project=$($Cfg.mgmt)"
        Write-Info "2. Región $($Cfg.region), conexión github -> Terminar la configuración."
        Write-Info '3. Instala la app solo en sport-app-backend, sport-app-frontend y sport-app-platform.'
        while ((Get-ConnectionStage $Cfg) -ne 'COMPLETE') {
            $answer = Read-Host "Presiona Enter cuando termines (o escribe 'salir' para continuar en otro momento)"
            if ($answer -eq 'salir') { throw [ManualStep]::new('Autoriza la conexión github y ejecuta de nuevo: .\scripts\sportapp-gcp.ps1 setup') }
            if ((Get-ConnectionStage $Cfg) -ne 'COMPLETE') { Write-Note "la conexión sigue en '$(Get-ConnectionStage $Cfg)'" }
        }
        Write-Ok 'conexión github en COMPLETE'
        $prepared.ConnectionReady = $true
        Invoke-Delivery $Cfg $prepared 'delivery-repositories'
    }

    if (-not $Cfg.releaseTriggersEnabled) {
        throw [ManualStep]::new(
            "Repositorios vinculados; los triggers de release siguen deshabilitados.`n" +
            "Cuando backend y frontend tengan cloudbuild.release.yaml en main, agrega en .env.ps1:`n" +
            "  `$releaseTriggersEnabled = `$true`n" +
            'y ejecuta de nuevo: .\scripts\sportapp-gcp.ps1 setup')
    }

    # Primera release y Cloud Run (secciones 13.6 a 13.8).
    $images = Get-CloudRunImages
    if ($images.Count -lt 3) {
        Write-Step 'Primera release: digests para Cloud Run'
        $images = Get-InitialCloudRunImages $Cfg
        if (-not $images) {
            throw [ManualStep]::new(
                "Triggers habilitados, pero todavía no hay evidencia de release de backend y frontend.`n" +
                "Publica un tag vX.Y.Z desde main en cada repositorio (docs/manual-versionado.md), espera`n" +
                "que release-backend y release-frontend terminen en SUCCESS:`n" +
                "  gcloud builds list --region=$($Cfg.region) --project=$($Cfg.mgmt) --limit=5`n" +
                'y ejecuta de nuevo: .\scripts\sportapp-gcp.ps1 setup')
        }
        Save-CloudRunImages $images
        Invoke-Production 'production-cloud-run'
        Invoke-Delivery $Cfg $prepared 'delivery-cloud-run'
    }

    Write-Host ''
    Write-Host 'Preparación completa: plano fijo y plano operativo creados.' -ForegroundColor Green
    Show-PromoteHint $Cfg
}

function Invoke-Up($Cfg) {
    Write-Step 'Estación'
    if (-not (Test-Tools -Quiet)) { throw 'Instala las herramientas que faltan.' }
    if (-not (Test-Auth $Cfg -Interactive)) { throw 'Corrige la autenticación de gcloud.' }
    $prepared = Get-Prepared $Cfg
    Invoke-Production 'up'
    Initialize-AppSecrets $Cfg
    Invoke-Workloads 'up'
    if ($prepared.ConnectionReady) { Invoke-Delivery $Cfg $prepared 'delivery-up' }
    else { Write-Note 'la conexión github no está en COMPLETE; termina la preparación con setup' }
    Write-Host ''
    Write-Host 'Plano operativo encendido.' -ForegroundColor Green
    Show-PromoteHint $Cfg
}

function Invoke-Down($Cfg) {
    Write-Step 'Estación'
    if (-not (Test-Tools -Quiet)) { throw 'Instala las herramientas que faltan.' }
    if (-not (Test-Auth $Cfg -Interactive)) { throw 'Corrige la autenticación de gcloud.' }
    [void](Get-Prepared $Cfg)
    Initialize-Root 'production'
    $state = Get-StateAddresses 'production'
    $present = @($state | Where-Object { Test-AnyMatch $_ @('^module\.platform\.module\.(gke|cloud_sql)\.', '^module\.platform\.module\.cloud_run\[') })
    if ($present.Count -eq 0) { Write-Ok 'GKE, Cloud SQL y Cloud Run ya están destruidos.'; return }

    Write-Step 'Se destruirá el plano operativo costoso'
    Write-Info "Proyecto: $($Cfg.production)"
    Write-Info 'Se eliminan: GKE (y todo lo que corre dentro), Cloud SQL con TODOS sus datos y respaldos, y Cloud Run.'
    Write-Info 'Se conservan: proyectos, estado, identidades, Artifact Registry e imágenes, secretos, red, Pub/Sub, Cloud Build y Cloud Deploy.'
    Write-Info 'Comprueba antes que no haya un rollout o una migración en curso en Cloud Deploy.'
    if ($ConfirmProject -ne $Cfg.production) {
        $typed = Read-Host 'Escribe el ID del proyecto de producción para confirmar'
        if ($typed -ne $Cfg.production) { throw 'Confirmación incorrecta; no se destruyó nada.' }
    }

    # 1. Antes de tocar nada: el plan de destrucción solo alcanza lo permitido.
    $protection = @('-var=deletion_protection=false', "-var=destroy_confirmation=$($Cfg.production)")
    $targets = @($CostlyTargets | ForEach-Object { "-target=$_" })
    [void](Invoke-TerraformStep -Key production -Name 'down-scope' -Purpose 'Comprobar el alcance de la destrucción' -Destroy -PlanArgs ($protection + $targets) -DeletablePatterns $CostlyDeletable -PlanOnly)

    # up recrea Cloud Run con los últimos digests desplegados por Cloud Deploy.
    $services = Invoke-GcloudJson @('run', 'services', 'list', "--project=$($Cfg.production)", "--region=$($Cfg.region)") -AllowFailure
    $images = Get-CloudRunImages
    foreach ($s in @($services)) {
        if ($null -eq $s) { continue }
        $name = Get-Value (Get-Value $s 'metadata') 'name'
        $containers = Get-Value (Get-Value (Get-Value (Get-Value $s 'spec') 'template') 'spec') 'containers'
        $image = Get-Value (@($containers)[0]) 'image'
        if (@('web', 'bff-web', 'bff-mobile') -contains $name -and "$image" -match '@sha256:[0-9a-f]{64}$') { $images[$name] = $image }
    }
    Save-CloudRunImages $images
    Write-Ok 'digests actuales de Cloud Run guardados en cloud-run-images.auto.tfvars.json'

    # 2. Objetos de GKE: al borrar los Services se liberan los balanceadores internos.
    $clusters = (Invoke-Capture gcloud @('container', 'clusters', 'list', "--project=$($Cfg.production)", '--format=value(name)', '--quiet') -AllowFailure).Output -split "`n"
    if ($clusters -contains $ClusterName) {
        Initialize-Root 'workloads'
        # Solo los Services: los Secrets tienen prevent_destroy y el resto desaparece con
        # el clúster; production-workloads conserva su estado y up recrea lo que falte.
        [void](Invoke-TerraformStep -Key workloads -Name 'workloads-destroy' -Purpose 'Retirar los Services de GKE (libera los balanceadores internos)' -Destroy -PlanArgs @('-target=kustomization_resource.services') -DeletablePatterns @('^kustomization_resource\.services\['))
        Write-Step 'Esperando que GKE libere los balanceadores internos'
        for ($i = 0; $i -lt 30; $i++) {
            $rules = (Invoke-Capture gcloud @('compute', 'forwarding-rules', 'list', "--project=$($Cfg.production)", '--filter=description~kubernetes.io/service-name', '--format=value(name)', '--quiet') -AllowFailure).Output
            if (-not $rules) { break }
            Start-Sleep -Seconds 20
        }
        if ($rules) { Write-Note "siguen balanceadores de GKE: $($rules -replace "`n", ', '). Revísalos después con status." }
        else { Write-Ok 'sin balanceadores de GKE' }
    } else {
        Write-Note 'el clúster no existe; production-workloads conserva su estado y up lo reconcilia'
    }

    # 3. Quitar protecciones solo en lo que se destruye (sección 15.3).
    [void](Invoke-TerraformStep -Key production -Name 'unprotect' -Purpose 'Desactivar la protección contra borrado' -PlanArgs ($protection + $targets) -OnlyUpdates)

    # 4. Destrucción dirigida; aborta si alcanza algo que se conserva.
    [void](Invoke-TerraformStep -Key production -Name 'down' -Purpose 'Destruir GKE, Cloud SQL y Cloud Run' -Destroy -PlanArgs ($protection + $targets) -DeletablePatterns $CostlyDeletable)

    Write-Host ''
    Write-Host 'Plano operativo apagado. Para encenderlo: .\scripts\sportapp-gcp.ps1 up' -ForegroundColor Green
    Invoke-Status $Cfg
}

function Invoke-Status($Cfg) {
    Write-Step "Recursos costosos en $($Cfg.production)"
    $checks = @(
        @{ Label = 'GKE'; Args = @('container', 'clusters', 'list', "--project=$($Cfg.production)", '--format=value(name,status)') }
        @{ Label = 'Cloud SQL'; Args = @('sql', 'instances', 'list', "--project=$($Cfg.production)", '--format=value(name,state)') }
        @{ Label = 'Cloud Run'; Args = @('run', 'services', 'list', "--project=$($Cfg.production)", "--region=$($Cfg.region)", '--format=value(metadata.name)') }
        @{ Label = 'Balanceadores'; Args = @('compute', 'forwarding-rules', 'list', "--project=$($Cfg.production)", '--format=value(name)') }
    )
    foreach ($c in $checks) {
        $r = Invoke-Capture gcloud ($c.Args + '--quiet') -AllowFailure
        if ($r.ExitCode -ne 0) { Write-Info "$($c.Label): no disponible (API deshabilitada o sin permiso)"; continue }
        if ($r.Output) { Write-Note "$($c.Label) encendido: $($r.Output -replace "`n", ' | ')" } else { Write-Ok "$($c.Label): ninguno" }
    }
    Write-Step "Plano fijo en $($Cfg.mgmt)"
    $stage = Get-ConnectionStage $Cfg
    if ($stage) { Write-Ok "conexión github: $stage" } else { Write-Info 'conexión github: no existe todavía' }
}

function Invoke-Promote($Cfg) {
    if (-not $BackendVersion -and -not $FrontendVersion) { throw 'Indica -BackendVersion y/o -FrontendVersion (tags vX.Y.Z).' }
    if ($FrontendVersion -and -not $BackendVersion) { throw 'El frontend se valida contra un backend: indica también -BackendVersion.' }
    foreach ($v in @(@($BackendVersion, $FrontendVersion) | Where-Object { $_ })) {
        if ($v -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$') { throw "'$v' no es un tag SemVer vX.Y.Z." }
    }
    if ($ReleaseSuffix -and $ReleaseSuffix -notmatch '^[a-z0-9]{1,8}$') { throw 'El sufijo admite de 1 a 8 minúsculas o dígitos.' }
    # Cloud Deploy nombra el primer rollout <pipeline>-v<versión>-<commit7>[-sufijo]-to-<target>-0001
    # con un máximo de 63 caracteres; el caso más largo es backend-gke con production-gke-migrations.
    if ($BackendVersion) {
        $longest = "backend-gke-$($BackendVersion -replace '\.', '-')-0000000" + $(if ($ReleaseSuffix) { "-$ReleaseSuffix" } else { '' }) + '-to-production-gke-migrations-0001'
        if ($longest.Length -gt 63) {
            $room = 63 - ($longest.Length - $(if ($ReleaseSuffix) { $ReleaseSuffix.Length + 1 } else { 0 })) - 1
            throw "El nombre del rollout tendría $($longest.Length) caracteres (máximo 63). Usa un sufijo de $([Math]::Max($room, 0)) caracteres como máximo, por ejemplo -ReleaseSuffix r1."
        }
    }
    if (-not (Test-Auth $Cfg)) { throw 'Corrige la autenticación de gcloud.' }

    $runs = @()
    if ($BackendVersion) { $runs += , @('backend', "_COMPONENT=backend,_VERSION=$BackendVersion") }
    if ($FrontendVersion) { $runs += , @('frontend', "_COMPONENT=frontend,_VERSION=$FrontendVersion,_BACKEND_VERSION=$BackendVersion") }
    foreach ($run in $runs) {
        $subs = $run[1]
        if ($ReleaseSuffix) { $subs += ",_RELEASE_SUFFIX=$ReleaseSuffix" }
        Write-Step "promote-release: $($run[0])"
        $build = Invoke-GcloudJson @('builds', 'triggers', 'run', 'promote-release', "--region=$($Cfg.region)", "--project=$($Cfg.mgmt)", '--branch=main', "--substitutions=$subs")
        if (-not $build) { throw "No se pudo iniciar promote-release para $($run[0])." }
        $b = Get-Value (Get-Value $build 'metadata') 'build'
        Write-Ok "build $(Get-Value $b 'id')"
        Write-Info "Log: $(Get-Value $b 'logUrl')"
        if ($run[0] -eq 'backend' -and $FrontendVersion) {
            Write-Info 'Esperando que termine el promotor del backend antes del frontend...'
            Invoke-Show gcloud @('builds', 'log', (Get-Value $b 'id'), '--stream', "--region=$($Cfg.region)", "--project=$($Cfg.mgmt)") -AllowedExitCodes @(0, 1)
        }
    }
    Write-Step 'Aprobación humana'
    Write-Info "Revisa y aprueba en https://console.cloud.google.com/deploy/delivery-pipelines?project=$($Cfg.mgmt)"
    Write-Info 'Orden: production-gke-migrations, luego promover y aprobar production-gke; después bff-web, bff-mobile y frontend-web.'
}

function Show-Help {
    Get-Help $PSCommandPath -Detailed | Out-Host
    Write-Host 'Uso: .\scripts\sportapp-gcp.ps1 <check|setup|up|down|status|promote> [-AutoApprove]'
    Write-Host 'Primero completa platform\.env.ps1 (plantilla .env.example.ps1) y ejecuta check.'
}

# --- Entrada ------------------------------------------------------------------

# Terraform y gcloud escriben UTF-8 (rutas y descripciones con tildes).
$previousEncoding = [Console]::OutputEncoding
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { $previousEncoding = $null }
try {
    if ($Command -eq 'help') { Show-Help; return }
    $config = Read-Config
    if ($Command -eq 'check') { Invoke-Check $config; return }
    Assert-Config $config
    $script:Cfg = $config.Values
    switch ($Command) {
        'setup' { Invoke-Setup $script:Cfg }
        'up' { Invoke-Up $script:Cfg }
        'down' { Invoke-Down $script:Cfg }
        'status' { Invoke-Status $script:Cfg }
        'promote' { Invoke-Promote $script:Cfg }
    }
} catch [ManualStep] {
    Write-Host ''
    Write-Host 'Paso manual pendiente:' -ForegroundColor Yellow
    Write-Host $_.Exception.Message
    exit 2
} catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ($previousEncoding) { try { [Console]::OutputEncoding = $previousEncoding } catch { } }
}
