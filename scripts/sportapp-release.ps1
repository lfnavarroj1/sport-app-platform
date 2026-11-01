<#
.SYNOPSIS
    Publica las releases de SportApp: backend, frontend, aplicación móvil y
    versión de plataforma (versión del sistema). Un solo script con menú.

.DESCRIPTION
    Se ejecuta desde la estación del operador con su sesión de GitHub CLI (gh). Sin
    comando muestra un menú con los comandos de abajo; sin -Target, otro menú
    para elegir qué se publica o se consulta:

      1. Solo backend
      2. Backend y frontend
      3. Solo frontend
      4. Solo aplicación móvil
      5. Plataforma (versión del sistema)

    Comandos:

      release     Backend y frontend: PR develop -> main, pruebas, aprobación,
                  merge, release vX.Y.Z, workflow de release, Cloud Build
                  (release-backend / release-frontend) y submódulos de la plataforma.
                  Móvil: las mismas fases y, al final, el APK firmado adjunto a la
                  release. Plataforma: rama release/vX.Y.Z desde develop, manifiesto
                  released con la evidencia de Cloud Build, PR a main, tag y
                  retorno a develop con el ciclo siguiente abierto. Si falta el
                  almacén de claves del APK, ofrece crearlo.
      hotfix      Backend, frontend o móvil: crea hotfix/vX.Y.Z (PATCH) desde main,
                  espera la corrección, PR hotfix -> main y las mismas fases de
                  release; al final abre el PR de retorno hacia develop.
      check     Valida gh, permisos, ramas y las herramientas de lo elegido.
      status      Cambios pendientes de develop, PR abierto y última release.
      prepare     Una sola vez: crea main (frontend), renombra master a main
                  (móvil) o crea develop (plataforma).
      keystore    Una sola vez: crea el almacén de claves del APK (fuera del repo).
      builds      Consulta o espera el Cloud Build de los tags publicados de
                  backend y frontend, y muestra el error si falló.
      apk         Solo compila, firma y adjunta el APK de una release del móvil.
      submodules  Mueve components/* a los tags publicados y actualiza
                  release-manifest.yaml.

    Cada tag de backend o frontend inicia release-backend o release-frontend en
    el proyecto de gestión. El despliegue se hace después con sportapp-gcp.ps1
    promote. Instrucciones: scripts/sportapp-release.md.

.EXAMPLE
    .\scripts\sportapp-release.ps1

.EXAMPLE
    .\scripts\sportapp-release.ps1 release -Target backend -Bump patch

.EXAMPLE
    .\scripts\sportapp-release.ps1 release -Target platform -Stories HU001,HU010
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    # Vacío: menú.
    [ValidateSet('help', 'check', 'status', 'prepare', 'keystore', 'release', 'hotfix', 'builds', 'apk', 'submodules')]
    [string]$Command,

    # Qué se publica o se consulta; sin -Target se pregunta con un menú.
    [ValidateSet('backend', 'backend-frontend', 'frontend', 'mobile', 'platform', 'all')]
    [string]$Target,

    # Incremento propuesto desde el último tag del repositorio elegido.
    [ValidateSet('patch', 'minor', 'major')]
    [string]$Bump = 'minor',

    # Versiones explícitas (vX.Y.Z); reemplazan la propuesta.
    [string]$BackendVersion,
    [string]$FrontendVersion,
    [string]$MobileVersion,
    [string]$PlatformVersion,

    # Versión de plataforma (sistema) que acompaña las releases de componentes;
    # por defecto platformVersion de release-manifest.yaml.
    [string]$SystemVersion,

    # Plataforma: HU de la versión; sin -Stories, las de los commits de los componentes.
    [string[]]$Stories,

    # Plataforma: sprint de la versión; por defecto el de release-manifest.yaml en develop.
    [string]$Sprint,

    # Componentes: no mueve los submódulos de la plataforma ni release-manifest.yaml.
    [switch]$SkipPlatform,

    # Backend y frontend: no espera los builds de Cloud Build de los tags.
    [switch]$SkipCloudBuild,

    # Móvil: no compila el APK al final (se puede hacer después con apk).
    [switch]$SkipApk,

    # Omite las confirmaciones de rutina. La aprobación de cada PR siempre se pregunta.
    [switch]$AutoApprove,

    [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'

$PlatformRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigFile) { $ConfigFile = Join-Path $PlatformRoot '.env.ps1' }
elseif (Test-Path -LiteralPath $ConfigFile) { $ConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path }
$ReleaseScriptName = 'sportapp-release.ps1'
$Repos = @()
# hotfix reutiliza las fases de release con la rama hotfix/vX.Y.Z en vez de develop.
$HotfixMode = $false
$ReleaseKind = 'release'

$Components = [ordered]@{
    backend  = @{ Repo = 'sport-app-backend'; Label = 'Backend'; Workflow = 'release-validation.yml'; Trigger = 'release-backend' }
    frontend = @{ Repo = 'sport-app-frontend'; Label = 'Frontend web'; Workflow = 'release-web.yml'; Trigger = 'release-frontend' }
    mobile   = @{ Repo = 'sport-app-movil'; Label = 'Móvil'; Workflow = 'release-mobile.yml' }
    platform = @{ Repo = 'sport-app-platform'; Label = 'Plataforma'; Workflow = 'validate-platform.yml' }
}

# Opciones del menú y repositorios que abarca cada una.
$Targets = [ordered]@{
    backend            = @{ Label = 'Solo backend'; Repos = @('backend') }
    'backend-frontend' = @{ Label = 'Backend y frontend'; Repos = @('backend', 'frontend') }
    frontend           = @{ Label = 'Solo frontend'; Repos = @('frontend') }
    mobile             = @{ Label = 'Solo aplicación móvil'; Repos = @('mobile') }
    platform           = @{ Label = 'Plataforma (versión del sistema)'; Repos = @('platform') }
    all                = @{ Label = 'Todo'; Repos = @('backend', 'frontend', 'mobile', 'platform') }
}
$Releasable = @('backend', 'backend-frontend', 'frontend', 'mobile', 'platform')
$CommandTargets = @{
    check      = @{ Verb = 'validar'; Targets = $Releasable + 'all' }
    status     = @{ Verb = 'consultar'; Targets = $Releasable + 'all' }
    prepare    = @{ Verb = 'preparar'; Targets = $Releasable }
    release    = @{ Verb = 'publicar'; Targets = $Releasable }
    hotfix     = @{ Verb = 'corregir con un hotfix'; Targets = @('backend', 'backend-frontend', 'frontend', 'mobile') }
    builds     = @{ Verb = 'revisar en Cloud Build'; Targets = @('backend', 'backend-frontend', 'frontend') }
    submodules = @{ Verb = 'fijar en la plataforma'; Targets = @('backend', 'backend-frontend', 'frontend', 'mobile') }
    apk        = @{ Verb = 'compilar'; Targets = @('mobile') }
    keystore   = @{ Verb = 'preparar'; Targets = @('mobile') }
}

# Menú de comandos cuando no se indica ninguno.
$CommandMenu = [ordered]@{
    release    = 'Publicar una release (backend, frontend, móvil o plataforma)'
    hotfix     = 'Publicar un hotfix desde main (backend, frontend o móvil)'
    status     = 'Ver cambios pendientes, PR abierto y última release'
    builds     = 'Consultar o esperar el Cloud Build de un tag'
    apk        = 'Compilar, firmar y adjuntar el APK de una release móvil'
    submodules = 'Mover components/* a los tags publicados'
    check      = 'Validar gh, permisos, ramas y herramientas'
    prepare    = 'Preparación única: crear o renombrar ramas main/develop'
    keystore   = 'Preparación única: crear el almacén de claves del APK'
    help       = 'Ayuda'
}

$SemVerPattern = '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$'
$PollSeconds = 30

# --- Salida y comandos externos ----------------------------------------------

function Write-Step([string]$Text) { Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [ok]    $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "  [aviso] $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host "  [falta] $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "          $Text" }

function Confirm-Step([string]$Question, [switch]$Always) {
    if ($AutoApprove -and -not $Always) { return }
    $answer = Read-Host "$Question Escribe 'si' para continuar"
    if ($answer -ne 'si') { throw 'Cancelado por el operador; no se hizo nada más.' }
}

# Muestra la salida en la consola sin devolverla; código en $script:NativeExit.
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
    if (-not $AllowFailure -and $code -ne 0) { throw "Falló: $Exe $($Arguments -join ' ') (código $code).`n$err" }
    [pscustomobject]@{ ExitCode = $code; Output = $out.Trim(); Error = $err.Trim() }
}

# Windows PowerShell 5.1 entrega un arreglo JSON como un solo objeto; ForEach-Object
# lo desenrolla para que @(...) y Where-Object vean cada elemento.
function ConvertFrom-JsonItems([string]$Text) {
    $Text | ConvertFrom-Json | ForEach-Object { $_ }
}

function Invoke-GhJson([string[]]$Arguments, [switch]$AllowFailure) {
    $r = Invoke-Capture gh $Arguments -AllowFailure:$AllowFailure
    if ($r.ExitCode -ne 0 -or -not $r.Output) { return $null }
    ConvertFrom-JsonItems $r.Output
}

# gh pr checks termina con 8 mientras hay pruebas en curso y con 1 si alguna
# falló, pero en ambos casos imprime el JSON; sin pruebas no imprime nada.
function Get-PrChecks([string]$Repo, [int]$Number) {
    $r = Invoke-Capture gh @('pr', 'checks', "$Number", '--repo', $Repo, '--json', 'name,bucket,link') -AllowFailure
    if (-not $r.Output.StartsWith('[')) { return @() }
    @(ConvertFrom-JsonItems $r.Output | Where-Object { $_ })
}

function Write-TextFile([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

# --- Configuración ------------------------------------------------------------

function Read-Config {
    $names = @('githubOwner', 'releaseReviewer', 'mobileRepoPath', 'frontendRepoPath', 'mobileKeystoreFile', 'mobileKeyAlias', 'mobileBffBaseUrl', 'healthDataConsentVersion', 'production', 'region', 'mgmt')
    $values = @{}
    if (Test-Path -LiteralPath $ConfigFile) {
        $result = & {
            param($__path, $__names)
            . $__path
            $__values = @{}
            foreach ($__name in $__names) {
                $__v = Get-Variable -Name $__name -Scope 0 -ValueOnly -ErrorAction SilentlyContinue
                if ($null -ne $__v) { $__values[$__name] = $__v }
            }
            $__values
        } $ConfigFile $names
        $values = @($result | Where-Object { $_ -is [hashtable] })[-1]
    }
    $parent = Split-Path -Parent $PlatformRoot
    if (-not $values.githubOwner) { $values.githubOwner = 'lfnavarroj1' }
    if (-not $values.mobileRepoPath) { $values.mobileRepoPath = Join-Path $parent 'movil' }
    if (-not $values.frontendRepoPath) { $values.frontendRepoPath = Join-Path $parent 'frontend' }
    if (-not $values.mobileKeyAlias) { $values.mobileKeyAlias = 'sportapp' }
    if (-not $values.mobileKeystoreFile) { $values.mobileKeystoreFile = Join-Path $env:USERPROFILE '.sportapp\sportapp-release.jks' }
    foreach ($k in 'mobileRepoPath', 'frontendRepoPath', 'mobileKeystoreFile') {
        if (-not [IO.Path]::IsPathRooted($values[$k])) { $values[$k] = Join-Path $PlatformRoot $values[$k] }
    }
    $values
}

function Get-RepoName([string]$Key) { "$($script:Cfg.githubOwner)/$($Components[$Key].Repo)" }

# --- GitHub -------------------------------------------------------------------

function Get-Login {
    $r = Invoke-Capture gh @('api', 'user', '--jq', '.login') -AllowFailure
    if ($r.ExitCode -ne 0) { return $null }
    $r.Output
}

function Test-Branch([string]$Repo, [string]$Branch) {
    (Invoke-Capture gh @('api', "repos/$Repo/branches/$Branch", '--jq', '.name') -AllowFailure).ExitCode -eq 0
}

function Get-Ahead([string]$Repo, [string]$Head = 'develop') {
    # Sin comillas dentro del filtro: Windows PowerShell 5.1 no las escapa al llamar a gh.
    $c = Invoke-GhJson @('api', "repos/$Repo/compare/main...$Head", '--jq', '{ahead: .ahead_by, behind: .behind_by, commits: [.commits[] | {sha: .sha, message: .commit.message}]}')
    [pscustomobject]@{
        ahead   = $c.ahead
        behind  = $c.behind
        commits = @($c.commits | Where-Object { $_ } | ForEach-Object { $_.sha.Substring(0, 7) + ' ' + ($_.message -split "`n")[0] })
    }
}

function Get-Tags([string]$Repo) {
    $r = Invoke-Capture gh @('api', "repos/$Repo/tags?per_page=100", '--paginate', '--jq', '.[].name') -AllowFailure
    @($r.Output -split "`n" | Where-Object { $_ -match $SemVerPattern })
}

function ConvertTo-VersionParts([string]$Tag) {
    if ($Tag -notmatch $SemVerPattern) { throw "'$Tag' no es un tag SemVer vX.Y.Z." }
    [pscustomobject]@{ Major = [int]$Matches[1]; Minor = [int]$Matches[2]; Patch = [int]$Matches[3]; Pre = $Matches[4] }
}

function Get-LatestStable([string[]]$Tags) {
    $stable = foreach ($t in $Tags) { $p = ConvertTo-VersionParts $t; if (-not $p.Pre) { [pscustomobject]@{ Tag = $t; Major = $p.Major; Minor = $p.Minor; Patch = $p.Patch } } }
    (@($stable) | Sort-Object Major, Minor, Patch | Select-Object -Last 1).Tag
}

# Sin tags se parte de v0.0.0: la serie 0.x se usa hasta el MVP (docs/manual-versionado.md).
function Get-NextVersion([string]$Latest) {
    $p = if ($Latest) { ConvertTo-VersionParts $Latest } else { [pscustomobject]@{ Major = 0; Minor = 0; Patch = 0 } }
    switch ($Bump) {
        'major' { "v$($p.Major + 1).0.0" }
        'minor' { "v$($p.Major).$($p.Minor + 1).0" }
        'patch' { "v$($p.Major).$($p.Minor).$($p.Patch + 1)" }
    }
}

# Último PR <Head> -> main fusionado cuyo merge no está en el último tag estable:
# la release se cortó después del merge (fase 3) y se retoma en la fase 4. Con
# la rama sin cambios no se puede abrir otro PR, así que sin esto quedaría omitido.
function Get-UnreleasedMerge([string]$Repo, [string]$Latest, [string]$Head = 'develop') {
    $merged = @(Invoke-GhJson @('pr', 'list', '--repo', $Repo, '--base', 'main', '--head', $Head, '--state', 'merged', '--limit', '1', '--json', 'number,url,title,mergeCommit') | Where-Object { $_ }) | Select-Object -First 1
    if (-not $merged -or -not $merged.mergeCommit) { return $null }
    if ($Latest) {
        $ahead = (Invoke-Capture gh @('api', "repos/$Repo/compare/$Latest...$($merged.mergeCommit.oid)", '--jq', '.ahead_by')).Output
        if ([int]$ahead -eq 0) { return $null }
    }
    $merged
}

function Get-SystemVersion {
    if ($SystemVersion) {
        if ($SystemVersion -notmatch $SemVerPattern) { throw "-SystemVersion '$SystemVersion' no es vX.Y.Z." }
        return $SystemVersion
    }
    $manifest = Join-Path $PlatformRoot 'release-manifest.yaml'
    $m = Select-String -LiteralPath $manifest -Pattern '^platformVersion:\s*"?([0-9][^"\s]*)"?' | Select-Object -First 1
    if (-not $m) { throw 'No se encontró platformVersion en release-manifest.yaml; usa -SystemVersion.' }
    "v$($m.Matches[0].Groups[1].Value)"
}

# Token de una segunda cuenta para aprobar: SPORTAPP_REVIEWER_TOKEN o una cuenta
# adicional iniciada en gh ($releaseReviewer). Nunca se imprime.
function Get-ReviewerToken([string]$Login) {
    if ($env:SPORTAPP_REVIEWER_TOKEN) { return $env:SPORTAPP_REVIEWER_TOKEN }
    if ($script:Cfg.releaseReviewer -and $script:Cfg.releaseReviewer -ne $Login) {
        $r = Invoke-Capture gh @('auth', 'token', '--hostname', 'github.com', '--user', $script:Cfg.releaseReviewer) -AllowFailure
        if ($r.ExitCode -eq 0 -and $r.Output) { return $r.Output }
    }
    $null
}

function Invoke-AsReviewer([string]$Token, [string[]]$Arguments) {
    $previous = $env:GH_TOKEN
    try { $env:GH_TOKEN = $Token; Invoke-Capture gh $Arguments }
    finally { if ($previous) { $env:GH_TOKEN = $previous } else { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue } }
}

# --- Fases de release de componentes --------------------------------------------

function New-ReleaseItems {
    $items = foreach ($key in $Repos) {
        $repo = Get-RepoName $key
        $item = [pscustomobject]@{
            Key = $key; Repo = $repo; Label = $Components[$key].Label; Workflow = $Components[$key].Workflow
            Version = $null; Latest = $null; Pr = $null; PrUrl = $null; MergeSha = $null; State = 'pendiente'; Detail = ''
            Commits = @(); Head = 'develop'; HeadExists = $true
        }
        if (-not (Test-Branch $repo 'main')) { $item.State = 'omitido'; $item.Detail = 'no existe main: ejecuta prepare'; $item; continue }
        if (-not (Test-Branch $repo 'develop')) { $item.State = 'omitido'; $item.Detail = 'no existe develop'; $item; continue }
        $tags = Get-Tags $repo
        $item.Latest = Get-LatestStable $tags
        $explicit = @{ backend = $BackendVersion; frontend = $FrontendVersion; mobile = $MobileVersion }[$key]
        if ($HotfixMode) {
            # Hotfix: siempre PATCH sobre el último tag y desde su propia rama.
            $item.Version = if ($explicit) { $explicit } else { Get-NextVersion $item.Latest }
            # Se usa la rama hotfix/vX.Y.Z[-descripcion] que ya exista (manual de versiones).
            $refs = @((Invoke-Capture gh @('api', "repos/$repo/git/matching-refs/heads/hotfix/$($item.Version)", '--jq', '.[].ref') -AllowFailure).Output -split "`n" |
                    Where-Object { $_ -match "^refs/heads/(hotfix/$([regex]::Escape($item.Version))(-[^/]+)?)$" } | ForEach-Object { $Matches[1] })
            if ($refs.Count -gt 1) { throw "$($item.Label): hay varias ramas de hotfix para $($item.Version) ($($refs -join ', ')); deja una." }
            $item.Head = if ($refs.Count) { $refs[0] } else { "hotfix/$($item.Version)" }
            $item.HeadExists = [bool]$refs.Count
            $merged = Get-UnreleasedMerge $repo $item.Latest $item.Head
        } else {
            # La versión aprobada es la del título del PR fusionado ("release: <Label> vX.Y.Z").
            $merged = Get-UnreleasedMerge $repo $item.Latest
            $approved = if ($merged -and $merged.title -match '\s(v\S+)$') { $Matches[1] }
            if ($approved -and $tags -contains $approved) { $merged = $null; $approved = $null }
            $item.Version = if ($explicit) { $explicit } elseif ($approved) { $approved } else { Get-NextVersion $item.Latest }
        }
        if ($item.Version -notmatch $SemVerPattern) { throw "$($item.Label): '$($item.Version)' no es vX.Y.Z." }
        if ($tags -contains $item.Version) { throw "$($item.Label): el tag $($item.Version) ya existe; indica otra versión." }
        $diff = if ($item.HeadExists) { Get-Ahead $repo $item.Head } else { [pscustomobject]@{ ahead = 0; commits = @() } }
        $item.Commits = @($diff.commits)
        if ($merged) {
            $item.Pr = $merged.number; $item.PrUrl = $merged.url; $item.MergeSha = $merged.mergeCommit.oid; $item.State = 'fusionado'
            $item.Detail = "el PR #$($item.Pr) se fusionó sin release"
        } elseif ($HotfixMode) {
            # La corrección se sube después de crear la rama (Initialize-HotfixBranches).
            if (-not $item.HeadExists) { $item.Detail = "se crea $($item.Head) desde main" }
            elseif ($diff.ahead -eq 0) { $item.Detail = "$($item.Head) todavía no tiene la corrección" }
        } elseif ($diff.ahead -eq 0) { $item.State = 'omitido'; $item.Detail = 'develop no tiene cambios respecto de main' }
        $item
    }
    @($items)
}

# Hotfix: crea las ramas que falten desde main y espera a que el operador suba la
# corrección. Una rama que siga sin cambios respecto de main se omite.
function Initialize-HotfixBranches($Items) {
    Write-Step 'Fase 0: ramas de hotfix'
    foreach ($i in $Items | Where-Object { $_.State -eq 'pendiente' }) {
        if (-not $i.HeadExists) {
            $sha = (Invoke-Capture gh @('api', "repos/$($i.Repo)/branches/main", '--jq', '.commit.sha')).Output
            [void](Invoke-Capture gh @('api', '-X', 'POST', "repos/$($i.Repo)/git/refs", '-f', "ref=refs/heads/$($i.Head)", '-f', "sha=$sha"))
            $i.HeadExists = $true
            Write-Ok "$($i.Label): $($i.Head) creada en main ($($sha.Substring(0, 7)))"
        }
        while (-not $i.Commits.Count) {
            Write-Note "$($i.Label): sube la corrección a $($i.Head) en $($i.Repo):"
            Write-Info "git fetch origin"
            Write-Info "git switch $($i.Head)"
            Write-Info "# corrige, prueba y confirma"
            Write-Info "git push origin $($i.Head)"
            $answer = Read-Host "Presiona Enter cuando esté subida (o escribe 'omitir' para dejar $($i.Label) fuera)"
            if ($answer -eq 'omitir') { $i.State = 'omitido'; $i.Detail = 'hotfix sin corrección'; break }
            $i.Commits = @((Get-Ahead $i.Repo $i.Head).commits)
            if (-not $i.Commits.Count) { Write-Bad "$($i.Head) sigue igual que main" }
        }
        if ($i.State -eq 'pendiente') { Write-Ok "$($i.Label): $($i.Commits.Count) commit(s) en $($i.Head)" }
    }
}

# Hotfix: la corrección vuelve a develop con un PR que revisa el operador; puede
# tener conflictos con lo que develop avanzó después.
function Open-BackMergePrs($Items) {
    Write-Step 'Retorno del hotfix a develop'
    foreach ($i in $Items | Where-Object { $_.MergeSha }) {
        $open = @(Invoke-GhJson @('pr', 'list', '--repo', $i.Repo, '--base', 'develop', '--head', $i.Head, '--state', 'open', '--json', 'url') | Where-Object { $_ })
        if ($open.Count) { Write-Ok "$($i.Label): ya existe $($open[0].url)"; continue }
        $file = Join-Path $env:TEMP "sportapp-pr-back-$($i.Key).md"
        Write-TextFile $file "Devuelve a develop el hotfix **$($i.Version)** de $($i.Label) (PR $($i.PrUrl)).`n`nGenerado por ``sport-app-platform/scripts/$ReleaseScriptName``."
        $r = Invoke-Capture gh @('pr', 'create', '--repo', $i.Repo, '--base', 'develop', '--head', $i.Head, '--title', "chore: devolver hotfix $($i.Label) $($i.Version) a develop", '--body-file', $file) -AllowFailure
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
        if ($r.ExitCode -eq 0) { Write-Ok "$($i.Label): $(($r.Output -split "`n")[-1]) (revísalo y fusiónalo)" }
        else { Write-Bad "$($i.Label): no se abrió el PR hacia develop: $($r.Error)" }
    }
}

function Show-Plan($Items, [string]$System) {
    Write-Step "Plan de $ReleaseKind (sistema $System)"
    foreach ($i in $Items) {
        if ($i.State -eq 'omitido') { Write-Note "$($i.Label): omitido ($($i.Detail))"; continue }
        $from = if ($i.Latest) { $i.Latest } else { 'sin tags' }
        if ($i.State -eq 'fusionado') {
            Write-Note "$($i.Label): $from -> $($i.Version) ya está en main (PR #$($i.Pr), $($i.MergeSha.Substring(0, 7))) pero no tiene release; se retoma desde la release"
            if ($i.Commits.Count) { Write-Info "$($i.Head) tiene $($i.Commits.Count) commit(s) más: van en la siguiente release" }
            continue
        }
        Write-Ok "$($i.Label): $from -> $($i.Version) con $($i.Commits.Count) commit(s) de $($i.Head)"
        if ($i.Detail) { Write-Info $i.Detail }
        $i.Commits | Select-Object -First 10 | ForEach-Object { Write-Info $_ }
        if ($i.Commits.Count -gt 10) { Write-Info "... y $($i.Commits.Count - 10) más" }
    }
}

function Open-PullRequests($Items, [string]$System) {
    Write-Step "Fase 1: pull requests hacia main"
    foreach ($i in $Items | Where-Object { $_.State -eq 'pendiente' }) {
        $open = @(Invoke-GhJson @('pr', 'list', '--repo', $i.Repo, '--base', 'main', '--head', $i.Head, '--state', 'open', '--json', 'number,url'))
        if ($open.Count -gt 0 -and $open[0]) {
            $i.Pr = $open[0].number; $i.PrUrl = $open[0].url
            Write-Ok "$($i.Label): se reutiliza el PR #$($i.Pr) $($i.PrUrl)"
            continue
        }
        $body = @(
            "$(if ($HotfixMode) { 'Hotfix' } else { 'Release' }) **$($i.Version)** de $($i.Label) desde ``$($i.Head)`` (versión del sistema $System)."
            ''
            "Generado por ``sport-app-platform/scripts/$ReleaseScriptName``. Al fusionarse se crea la release y su tag sobre el commit de merge."
            ''
            '### Commits'
            ($i.Commits | ForEach-Object { "- $_" })
        ) -join "`n"
        $file = Join-Path $env:TEMP "sportapp-pr-$($i.Key).md"
        Write-TextFile $file $body
        $r = Invoke-Capture gh @('pr', 'create', '--repo', $i.Repo, '--base', 'main', '--head', $i.Head, '--title', "${ReleaseKind}: $($i.Label) $($i.Version)", '--body-file', $file)
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
        $i.PrUrl = ($r.Output -split "`n")[-1]
        $i.Pr = [int](($i.PrUrl -split '/')[-1])
        Write-Ok "$($i.Label): PR #$($i.Pr) $($i.PrUrl)"
    }
}

function Wait-Checks($Items) {
    Write-Step 'Fase 2: pruebas de los pull requests'
    $pending = @($Items | Where-Object { $_.State -eq 'pendiente' })
    $started = Get-Date
    while ($pending.Count -gt 0) {
        foreach ($i in @($pending)) {
            $checks = Get-PrChecks $i.Repo $i.Pr
            if ($checks.Count -eq 0) {
                if (((Get-Date) - $started).TotalMinutes -ge 5) {
                    Write-Note "$($i.Label): el PR no reporta pruebas después de 5 minutos."
                    Confirm-Step "¿Continuar con $($i.Label) sin pruebas?" -Always
                    $i.State = 'probado'; $pending = @($pending | Where-Object { $_ -ne $i })
                }
                continue
            }
            $failed = @($checks | Where-Object { $_.bucket -in 'fail', 'cancel' })
            $running = @($checks | Where-Object { $_.bucket -eq 'pending' })
            if ($failed.Count -gt 0) {
                $i.State = 'fallido'; $i.Detail = 'pruebas fallidas: ' + (($failed | ForEach-Object { $_.name }) -join ', ')
                Write-Bad "$($i.Label): $($i.Detail)"
                $failed | ForEach-Object { Write-Info $_.link }
                $pending = @($pending | Where-Object { $_ -ne $i })
            } elseif ($running.Count -eq 0) {
                $i.State = 'probado'
                Write-Ok "$($i.Label): $($checks.Count) pruebas correctas"
                $pending = @($pending | Where-Object { $_ -ne $i })
            } else {
                Write-Info ("{0:HH:mm} {1}: {2} de {3} pruebas en curso" -f (Get-Date), $i.Label, $running.Count, $checks.Count)
            }
        }
        if ($pending.Count -gt 0) {
            if (((Get-Date) - $started).TotalMinutes -ge 120) { throw 'Las pruebas siguen en curso después de 2 horas; repite release más tarde (reutiliza los PR).' }
            Start-Sleep -Seconds $PollSeconds
        }
    }
}

function Approve-AndMerge($Items) {
    Write-Step 'Fase 3: aprobación y merge'
    $login = Get-Login
    $token = Get-ReviewerToken $login
    if ($token) { Write-Ok 'se aprobará con la cuenta revisora' }
    else { Write-Note "sin cuenta revisora: GitHub no deja que $login apruebe sus propios PR; se fusionará con privilegios de administrador (--admin)" }

    foreach ($i in $Items | Where-Object { $_.State -eq 'probado' }) {
        $pr = Invoke-GhJson @('pr', 'view', "$($i.Pr)", '--repo', $i.Repo, '--json', 'title,url,additions,deletions,changedFiles,commits,mergeable,reviewDecision')
        Write-Host ''
        Write-Host "  $($i.Label) $($i.Version): $($pr.title)" -ForegroundColor White
        Write-Info "$($pr.url)"
        Write-Info "$(@($pr.commits).Count) commits, $($pr.changedFiles) archivos, +$($pr.additions) -$($pr.deletions); mergeable: $($pr.mergeable); revisión: $($pr.reviewDecision)"
        if ($pr.mergeable -eq 'CONFLICTING') { $i.State = 'fallido'; $i.Detail = 'el PR tiene conflictos con main'; Write-Bad $i.Detail; continue }
        $answer = Read-Host "¿Apruebas y fusionas $($i.Label) $($i.Version)? Escribe 'si' para aprobar, otra cosa para omitir"
        if ($answer -ne 'si') { $i.State = 'omitido'; $i.Detail = 'no aprobado por el operador'; Write-Note "$($i.Label): omitido"; continue }

        $subject = "${ReleaseKind}: $($i.Label) $($i.Version) (#$($i.Pr))"
        if ($token) {
            [void](Invoke-AsReviewer $token @('pr', 'review', "$($i.Pr)", '--repo', $i.Repo, '--approve', '--body', "Aprobado desde $ReleaseScriptName para $($i.Version)."))
            Write-Ok 'PR aprobado por la cuenta revisora'
            Invoke-Show gh @('pr', 'merge', "$($i.Pr)", '--repo', $i.Repo, '--merge', '--subject', $subject)
        } else {
            [void](Invoke-Capture gh @('pr', 'comment', "$($i.Pr)", '--repo', $i.Repo, '--body', "Aprobado por @$login desde $ReleaseScriptName para $($i.Version); fusionado con privilegios de administrador porque GitHub no permite autoaprobar."))
            Invoke-Show gh @('pr', 'merge', "$($i.Pr)", '--repo', $i.Repo, '--merge', '--admin', '--subject', $subject)
        }
        for ($n = 0; $n -lt 20 -and -not $i.MergeSha; $n++) {
            $view = Invoke-GhJson @('pr', 'view', "$($i.Pr)", '--repo', $i.Repo, '--json', 'state,mergeCommit')
            if ($view.state -eq 'MERGED' -and $view.mergeCommit) { $i.MergeSha = $view.mergeCommit.oid } else { Start-Sleep -Seconds 5 }
        }
        if (-not $i.MergeSha) { $i.State = 'fallido'; $i.Detail = 'GitHub no confirmó el merge'; Write-Bad $i.Detail; continue }
        $i.State = 'fusionado'
        Write-Ok "$($i.Label): fusionado en main ($($i.MergeSha.Substring(0, 7)))"
    }
}

function New-Releases($Items, [string]$System) {
    Write-Step 'Fase 4: releases en GitHub'
    foreach ($i in $Items | Where-Object { $_.State -eq 'fusionado' }) {
        $notes = @(
            "Versión del sistema (plataforma): **$System**"
            "Pull request: $($i.PrUrl)"
            "Commit: $($i.MergeSha)"
        ) -join "`n"
        $file = Join-Path $env:TEMP "sportapp-release-$($i.Key).md"
        Write-TextFile $file $notes
        $arguments = @('release', 'create', $i.Version, '--repo', $i.Repo, '--target', $i.MergeSha, '--title', "$($i.Label) $($i.Version)", '--notes-file', $file, '--generate-notes')
        if ($i.Version -match '-') { $arguments += '--prerelease' }
        $r = Invoke-Capture gh $arguments
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
        $i.State = 'publicado'
        Write-Ok "$($i.Label): $($r.Output)"
    }
}

function Wait-ReleaseWorkflows($Items) {
    Write-Step 'Fase 5: workflows de release'
    $pending = @($Items | Where-Object { $_.State -eq 'publicado' })
    $runs = @{}
    $started = Get-Date
    while ($pending.Count -gt 0) {
        foreach ($i in @($pending)) {
            $list = @(Invoke-GhJson @('run', 'list', '--repo', $i.Repo, '--workflow', $i.Workflow, '--limit', '20', '--json', 'databaseId,headSha,status,conclusion,url') -AllowFailure | Where-Object { $_ -and $_.headSha -eq $i.MergeSha })
            if ($list.Count -eq 0) {
                if (((Get-Date) - $started).TotalMinutes -ge 10) { $i.State = 'validación desconocida'; $i.Detail = "no apareció $($i.Workflow)"; Write-Note "$($i.Label): $($i.Detail)"; $pending = @($pending | Where-Object { $_ -ne $i }) }
                continue
            }
            $run = $list[0]
            if (-not $runs.ContainsKey($i.Key)) { $runs[$i.Key] = $true; Write-Info "$($i.Label): $($run.url)" }
            if ($run.status -ne 'completed') { Write-Info ("{0:HH:mm} {1}: {2} {3}" -f (Get-Date), $i.Label, $i.Workflow, $run.status); continue }
            if ($run.conclusion -eq 'success') { $i.State = 'validado'; Write-Ok "$($i.Label): $($i.Workflow) correcto" }
            else { $i.State = 'validación fallida'; $i.Detail = "$($i.Workflow): $($run.conclusion) $($run.url)"; Write-Bad "$($i.Label): $($i.Detail)" }
            $pending = @($pending | Where-Object { $_ -ne $i })
        }
        if ($pending.Count -gt 0) {
            if (((Get-Date) - $started).TotalMinutes -ge 120) { throw 'Los workflows de release siguen en curso después de 2 horas; revisa GitHub Actions.' }
            Start-Sleep -Seconds $PollSeconds
        }
    }
}

# Fases 1 a 5 para los repositorios de $Repos. Devuelve los ítems, o $null si
# no hay nada que publicar.
function Invoke-ReleasePhases([string]$System) {
    if (-not (Get-Login)) { throw 'gh no tiene sesión: gh auth login' }
    $items = New-ReleaseItems
    Show-Plan $items $System
    if (-not @($items | Where-Object { $_.State -in 'pendiente', 'fusionado' }).Count) { Write-Note 'No hay nada que publicar.'; return $null }
    Confirm-Step '¿Continuar con estas versiones?'
    if ($HotfixMode) { Initialize-HotfixBranches $items }
    Open-PullRequests $items $System
    Wait-Checks $items
    Approve-AndMerge $items
    New-Releases $items $System
    Wait-ReleaseWorkflows $items
    if ($HotfixMode) { Open-BackMergePrs $items }
    , $items
}

function Show-Summary($Items) {
    Write-Step 'Resumen'
    foreach ($i in $Items) { Write-Info ("{0,-13} {1,-9} {2}  {3}" -f $i.Label, $i.Version, $i.State, $i.Detail) }
}

function Get-VersionCode([string]$Tag) {
    $p = ConvertTo-VersionParts $Tag
    if ($p.Minor -ge 1000 -or $p.Patch -ge 1000) { throw "$Tag no cabe en el esquema versionCode = MAJOR*1000000 + MINOR*1000 + PATCH." }
    $p.Major * 1000000 + $p.Minor * 1000 + $p.Patch
}

# --- Plataforma: submódulos y release-manifest.yaml ----------------------------

$Submodules = [ordered]@{ backend = 'components/backend'; frontend = 'components/frontend'; mobile = 'components/mobile' }

# Mueve el submódulo al tag publicado (cierre de sprint, docs/manual-versionado.md).
# .gitmodules declara update = none: se descarga con --checkout y rutas largas.
function Set-SubmoduleTag([string]$Key, [string]$Tag) {
    $path = Join-Path $PlatformRoot ($Submodules[$Key] -replace '/', '\')
    if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) {
        Invoke-Show git @('-C', $PlatformRoot, '-c', 'core.longpaths=true', 'submodule', 'update', '--init', '--checkout', $Submodules[$Key])
    }
    [void](Invoke-Capture git @('-C', $path, 'config', 'core.longpaths', 'true'))
    if ((Invoke-Capture git @('-C', $path, 'status', '--porcelain')).Output) {
        throw "$($Submodules[$Key]) tiene cambios locales; no se mueve al tag para no perderlos."
    }
    Invoke-Show git @('-C', $path, 'fetch', '--quiet', '--force', 'origin', "refs/tags/${Tag}:refs/tags/$Tag")
    Invoke-Show git @('-C', $path, 'checkout', '--quiet', '--detach', $Tag)
    (Invoke-Capture git @('-C', $path, 'rev-parse', 'HEAD')).Output
}

# Reemplaza campos de components.<Key> en release-manifest.yaml sin tocar el
# resto. Un valor con varias líneas reemplaza también las líneas anidadas.
function Update-ManifestComponent([string]$Key, [System.Collections.Specialized.OrderedDictionary]$Fields) {
    $file = Join-Path $PlatformRoot 'release-manifest.yaml'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.AddRange([string[]]([IO.File]::ReadAllText($file) -replace "`r`n", "`n" -split "`n"))
    if ($lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    $start = $lines.IndexOf("  ${Key}:")
    if ($start -lt 0) { throw "release-manifest.yaml no tiene components.$Key." }
    foreach ($name in $Fields.Keys) {
        $end = $start + 1
        while ($end -lt $lines.Count -and $lines[$end] -match '^    ') { $end++ }
        $at = -1
        for ($n = $start + 1; $n -lt $end; $n++) { if ($lines[$n] -match "^    ${name}:") { $at = $n; break } }
        if ($at -lt 0) { throw "release-manifest.yaml no tiene components.$Key.$name." }
        while ($at + 1 -lt $end -and $lines[$at + 1] -match '^      ') { $lines.RemoveAt($at + 1); $end-- }
        $value = $Fields[$name] -split "`n"
        $lines[$at] = "    ${name}:" + $(if ($value[0]) { " $($value[0])" } else { '' })
        for ($v = $value.Count - 1; $v -ge 1; $v--) { $lines.Insert($at + 1, $value[$v]) }
    }
    Write-TextFile $file (($lines -join "`n") + "`n")
}

function Get-ReleaseApkSha([string]$Tag) {
    $r = Invoke-Capture gh @('release', 'download', $Tag, '--repo', (Get-RepoName 'mobile'), '--pattern', 'SHA256SUMS', '--output', '-') -AllowFailure
    if ($r.ExitCode -ne 0) { return $null }
    $line = ($r.Output -split "`n") | Where-Object { $_ -match '^([0-9a-f]{64})\s+\S+\.apk$' } | Select-Object -First 1
    if ($line -match '^([0-9a-f]{64})') { return $Matches[1] }
    $null
}

# $Entries: lista de @{ Key; Tag }. El manifiesto queda en draft: los digests y
# la evidencia de Cloud Build se completan cuando el promotor los valida.
function Sync-Platform($Entries) {
    Write-Step 'Plataforma: submódulos y release-manifest.yaml'
    $tags = @()
    foreach ($e in $Entries) {
        $label = $Components[$e.Key].Label
        try { $commit = Set-SubmoduleTag $e.Key $e.Tag }
        catch { Write-Note "$($label): $($_.Exception.Message)"; continue }
        $fields = [ordered]@{ version = "`"$($e.Tag.Substring(1))`""; ref = "`"$($e.Tag)`""; commit = "`"$commit`"" }
        if ($e.Key -eq 'mobile') {
            $fields.versionCode = "$(Get-VersionCode $e.Tag)"
            $sha = if ($script:ApkSha256 -and $script:ApkSha256.Tag -eq $e.Tag) { $script:ApkSha256.Sha } else { Get-ReleaseApkSha $e.Tag }
            if ($sha) { $fields.artifact = "`n      sha256: `"$sha`"" } else { Write-Note 'Móvil: la release no tiene APK; artifact queda sin checksum' }
        }
        Update-ManifestComponent $e.Key $fields
        $tags += "$($e.Key) $($e.Tag)"
        Write-Ok "$($label): $($Submodules[$e.Key]) -> $($e.Tag) ($($commit.Substring(0, 7)))"
    }
    if (-not $tags.Count) { return }
    $paths = @($Submodules.Values) + 'release-manifest.yaml'
    Invoke-Show git (@('-C', $PlatformRoot, 'status', '--short', '--') + $paths)
    Write-Info 'Confirma estos cambios en una rama de la plataforma (solo estos archivos) y abre su PR hacia develop:'
    Write-Info "  git switch -c chore/componentes-$((Get-Date).ToString('yyyyMMdd'))"
    Write-Info "  git add $($paths -join ' ')"
    Write-Info "  git commit -m `"chore(platform): fijar componentes en $($tags -join ', ')`""
    Write-Info '  git push --no-recurse-submodules -u origin HEAD'
    Write-Info 'La release de plataforma (opción Plataforma de este script) toma esta combinación desde develop.'
    if ($tags -match '^backend ') {
        Write-Info 'Si cambiaron los Services del backend, reconcilia GKE con: .\scripts\sportapp-gcp.ps1 up'
    }
}

function Invoke-SubmodulesCommand {
    $entries = foreach ($key in $Repos) {
        $tag = @{ backend = $BackendVersion; frontend = $FrontendVersion; mobile = $MobileVersion }[$key]
        if (-not $tag) { $tag = Get-LatestStable (Get-Tags (Get-RepoName $key)) }
        if (-not $tag) { Write-Note "$($Components[$key].Label): sin releases; se omite"; continue }
        @{ Key = $key; Tag = $tag }
    }
    if (@($entries).Count) { Sync-Platform @($entries) }
}

# --- Backend y frontend: Cloud Build ------------------------------------------

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
    # El final del paso siempre: la herramienta que corta el build suele escribir
    # ahí la causa (p. ej. la tabla de vulnerabilidades de pip-audit). Antes, las
    # líneas de error que queden fuera de ese final; los avisos no son la causa.
    $tail = @($lines | Select-Object -Last 15)
    $errors = @($lines | Select-Object -SkipLast 15 | Where-Object { $_ -match '(?i)\berror\b|failed|exception|not found|no such file|requires|denied' -and $_ -notmatch '(?i)\bwarning\b|CoverageWarning' })
    if ($errors.Count) { Write-Info "Errores en el paso $($Build.steps[$index].id):"; $errors | Select-Object -Last 8 | ForEach-Object { Write-Info "  $_" } }
    Write-Info "Final del paso $($Build.steps[$index].id):"; $tail | ForEach-Object { Write-Info "  $_" }
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

function Invoke-ComponentRelease {
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

# --- Móvil: APK de producción -------------------------------------------------

function Get-AndroidSdk {
    foreach ($candidate in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'build-tools'))) { return $candidate }
    }
    $local = Join-Path $script:Cfg.mobileRepoPath 'local.properties'
    if (Test-Path -LiteralPath $local) {
        $m = Select-String -LiteralPath $local -Pattern '^sdk\.dir=(.+)$' | Select-Object -First 1
        if ($m) { return ($m.Matches[0].Groups[1].Value -replace '\\:', ':' -replace '\\\\', '\') }
    }
    $null
}

function Get-BuildTool([string]$Sdk, [string]$Name) {
    $dir = Get-ChildItem -LiteralPath (Join-Path $Sdk 'build-tools') -Directory | Sort-Object { [version]($_.Name -replace '-.*$', '') } | Select-Object -Last 1
    if (-not $dir) { return $null }
    $path = Get-ChildItem -LiteralPath $dir.FullName -Filter "$Name*" | Where-Object { $_.Name -match "^$Name(\.bat|\.exe)?$" } | Select-Object -First 1
    if ($path) { $path.FullName } else { $null }
}

# El lanzador gradlew.bat exige Java 21 o superior; el JAR del wrapper funciona con
# Java 17 y Gradle descarga el JDK del proyecto (gradle-daemon-jvm.properties).
function Get-Java {
    $candidates = @()
    if ($env:JAVA_HOME) { $candidates += Join-Path $env:JAVA_HOME 'bin\java.exe' }
    $cmd = Get-Command java -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += @(Get-ChildItem "$env:ProgramFiles\Java", "$env:ProgramFiles\Eclipse Adoptium", "$env:ProgramFiles\Android\Android Studio" -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'bin\java.exe' })
    $candidates += Join-Path $env:ProgramFiles 'Android\Android Studio\jbr\bin\java.exe'
    foreach ($c in $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) {
        $v = (Invoke-Capture $c @('-version') -AllowFailure).Error
        if ($v -match 'version "(\d+)') { if ([int]$Matches[1] -ge 17) { return $c } }
    }
    $null
}

# keytool está en el bin del JDK real. El java del PATH puede ser un acceso
# directo (Oracle javapath) que no lo trae al lado; java.home dice dónde está el JDK.
function Get-Keytool([string]$Java) {
    $candidates = @(Join-Path (Split-Path -Parent $Java) 'keytool.exe')
    $props = Invoke-Capture $Java @('-XshowSettings:properties', '-version') -AllowFailure
    if ("$($props.Error)`n$($props.Output)" -match 'java\.home\s*=\s*(.+)') { $candidates += Join-Path $Matches[1].Trim() 'bin\keytool.exe' }
    $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

function Get-BffUrl {
    if ($script:Cfg.mobileBffBaseUrl) { $url = $script:Cfg.mobileBffBaseUrl }
    else {
        if (-not $script:Cfg.production -or -not $script:Cfg.region) { throw 'Define $production y $region (o $mobileBffBaseUrl) en .env.ps1.' }
        $number = (Invoke-Capture gcloud @('projects', 'describe', $script:Cfg.production, '--format=value(projectNumber)', '--quiet')).Output
        # Misma URL determinista que asigna modules/gcp/platform a Cloud Run.
        $url = "https://bff-mobile-$number.$($script:Cfg.region).run.app/"
    }
    if (-not $url.EndsWith('/')) { $url += '/' }
    if ($url -notmatch '^https://[^\s/]+/') { throw "La URL de bff-mobile '$url' debe ser https." }
    $url
}

function Read-SigningPasswords {
    $store = $env:SPORTAPP_SIGNING_STORE_PASSWORD
    $key = $env:SPORTAPP_SIGNING_KEY_PASSWORD
    if (-not $store) {
        $secure = Read-Host "Contraseña del almacén de claves $($script:Cfg.mobileKeystoreFile)" -AsSecureString
        $store = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    }
    if (-not $key) {
        $secure = Read-Host "Contraseña de la clave '$($script:Cfg.mobileKeyAlias)' (Enter = la misma del almacén)" -AsSecureString
        $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        if (-not $key) { $key = $store }
    }
    @{ Store = $store; Key = $key }
}

function Publish-Apk([string]$Tag, [string]$System) {
    Write-Step "APK de producción del móvil $Tag (sistema $System)"
    $repoPath = $script:Cfg.mobileRepoPath
    $repo = Get-RepoName 'mobile'
    if (-not (Test-Path -LiteralPath (Join-Path $repoPath '.git'))) { throw "No se encontró el clon del móvil en $repoPath (define `$mobileRepoPath)." }
    Assert-Keystore
    $release = Invoke-GhJson @('release', 'view', $Tag, '--repo', $repo, '--json', 'tagName,url') -AllowFailure
    if (-not $release) { throw "No existe la release $Tag en $repo." }
    $sdk = Get-AndroidSdk
    if (-not $sdk) { throw 'No se encontró el Android SDK (ANDROID_HOME o local.properties).' }
    $java = Get-Java
    if (-not $java) { throw 'Se requiere Java 17 o superior para iniciar Gradle.' }
    $apksigner = Get-BuildTool $sdk 'apksigner'
    $aapt2 = Get-BuildTool $sdk 'aapt2'
    $bff = Get-BffUrl
    # Misma versión del consentimiento (ADR-034) que recibe users-management en GCP.
    $consent = "$($script:Cfg.healthDataConsentVersion)".Trim()
    if (-not $consent -or $consent -match '[<>]') { throw 'Define $healthDataConsentVersion en .env.ps1: el APK de producción la necesita.' }
    $code = Get-VersionCode $Tag
    $version = $Tag.Substring(1)
    Write-Info "bff-mobile: $bff"
    Write-Info "consentimiento de datos de salud: $consent"
    Write-Info "versionName $version, versionCode $code"

    # Compilación desde el commit exacto del tag, en un worktree temporal.
    Invoke-Show git @('-C', $repoPath, 'fetch', '--quiet', '--force', 'origin', "refs/tags/${Tag}:refs/tags/$Tag")
    $commit = (Invoke-Capture git @('-C', $repoPath, 'rev-list', '-n', '1', $Tag)).Output
    $work = Join-Path $env:TEMP "sportapp-apk-$version"
    if (Test-Path -LiteralPath $work) { [void](Invoke-Capture git @('-C', $repoPath, 'worktree', 'remove', '--force', $work) -AllowFailure); Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue }
    Invoke-Show git @('-C', $repoPath, 'worktree', 'add', '--detach', '--quiet', $work, $Tag)
    $passwords = $null
    try {
        $buildScript = Get-Content -Raw -LiteralPath (Join-Path $work 'app\build.gradle.kts')
        if ($buildScript -notmatch 'sportapp\.versionName' -or $buildScript -notmatch 'SPORTAPP_SIGNING_STORE_FILE') {
            throw "El tag $Tag no incluye la versión y la firma configurables en app/build.gradle.kts (rama chore/apk-produccion-versionado). Fusiónala en develop y publica una versión nueva."
        }
        Write-TextFile (Join-Path $work 'local.properties') ("sdk.dir=" + ($sdk -replace '\\', '\\' -replace ':', '\:') + "`n")

        $passwords = Read-SigningPasswords
        $env:SPORTAPP_SIGNING_STORE_FILE = $script:Cfg.mobileKeystoreFile
        $env:SPORTAPP_SIGNING_KEY_ALIAS = $script:Cfg.mobileKeyAlias
        $env:SPORTAPP_SIGNING_STORE_PASSWORD = $passwords.Store
        $env:SPORTAPP_SIGNING_KEY_PASSWORD = $passwords.Key
        Push-Location -LiteralPath $work
        try {
            Invoke-Show $java @('-jar', 'gradle\wrapper\gradle-wrapper.jar', ':app:assembleRelease', '--console=plain', '--no-configuration-cache',
                "-Psportapp.versionName=$version", "-Psportapp.versionCode=$code", "-Psportapp.systemVersion=$System", "-Psportapp.bffMobileBaseUrl.release=$bff", "-Psportapp.healthDataConsentVersion.release=$consent")
        } finally { Pop-Location }
    } finally {
        Remove-Item Env:SPORTAPP_SIGNING_* -ErrorAction SilentlyContinue
        $passwords = $null
    }

    $apk = Get-ChildItem -LiteralPath (Join-Path $work 'app\build\outputs\apk\release') -Filter '*.apk' | Select-Object -First 1
    if (-not $apk -or $apk.Name -match 'unsigned') { throw 'Gradle no produjo un APK firmado.' }
    $certificate = ''
    if ($apksigner) {
        $verify = Invoke-Capture $apksigner @('verify', '--print-certs', $apk.FullName)
        $certificate = (($verify.Output -split "`n") | Where-Object { $_ -match 'certificate SHA-256 digest' } | Select-Object -First 1) -replace '^.*digest:\s*', ''
        Write-Ok "firma verificada (certificado SHA-256 $certificate)"
    } else { Write-Note 'apksigner no está en el Android SDK; no se verificó la firma' }
    if ($aapt2) {
        $badging = (Invoke-Capture $aapt2 @('dump', 'badging', $apk.FullName)).Output -split "`n" | Select-Object -First 1
        if ($badging -notmatch "versionCode='$code'" -or $badging -notmatch "versionName='$([regex]::Escape($version))'") { throw "El APK no tiene la versión esperada: $badging" }
        Write-Ok "versión del APK verificada ($version / $code)"
    }

    $dist = Join-Path $env:TEMP "sportapp-apk-dist-$version"
    Remove-Item -Recurse -Force -LiteralPath $dist -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    $name = "sportapp-movil-$Tag-sistema-$System.apk"
    Copy-Item -LiteralPath $apk.FullName -Destination (Join-Path $dist $name)
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $dist $name)).Hash.ToLower()
    Write-TextFile (Join-Path $dist 'SHA256SUMS') "$hash  $name`n"
    Write-TextFile (Join-Path $dist 'artifact.txt') (@(
            "version=$Tag", "versionName=$version", "versionCode=$code", "systemVersion=$System", "commit=$commit",
            "bffMobileBaseUrl=$bff", "signingCertificateSha256=$certificate", "builtBy=scripts/$ReleaseScriptName"
        ) -join "`n")
    Invoke-Show gh @('release', 'upload', $Tag, '--repo', $repo, '--clobber', (Join-Path $dist $name), (Join-Path $dist 'SHA256SUMS'), (Join-Path $dist 'artifact.txt'))
    [void](Invoke-Capture git @('-C', $repoPath, 'worktree', 'remove', '--force', $work) -AllowFailure)
    Write-Ok "APK adjunto a $($release.url)"
    Write-Info "SHA-256 $hash"
    $script:ApkSha256 = @{ Tag = $Tag; Sha = $hash }
}

function Invoke-Keystore {
    $file = $script:Cfg.mobileKeystoreFile
    if (Test-Path -LiteralPath $file) { Write-Ok "ya existe $file; no se reemplaza"; return }
    $java = Get-Java
    if (-not $java) { throw 'Se requiere un JDK (keytool) 17 o superior.' }
    $keytool = Get-Keytool $java
    if (-not $keytool) { throw "No se encontró keytool junto a $java ni en su JDK; instala un JDK 17 o superior o define JAVA_HOME." }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
    Write-Step "Almacén de claves de firma: $file (alias $($script:Cfg.mobileKeyAlias))"
    Write-Info 'keytool pedirá la contraseña y los datos del certificado. Guarda una copia del archivo y de la'
    Write-Info 'contraseña en un lugar seguro: sin ellos no se pueden publicar actualizaciones de la app.'
    & $keytool -genkeypair -v -keystore $file -storetype PKCS12 -alias $script:Cfg.mobileKeyAlias -keyalg RSA -keysize 4096 -validity 10000
    if ($LASTEXITCODE -ne 0) { throw 'keytool no creó el almacén de claves.' }
    Write-Ok 'almacén de claves creado (fuera del repositorio)'
}

function Test-MobileTools {
    $ok = $true
    Write-Step 'APK de producción'
    if (Test-Path -LiteralPath (Join-Path $script:Cfg.mobileRepoPath '.git')) { Write-Ok "clon del móvil: $($script:Cfg.mobileRepoPath)" } else { Write-Bad "no existe el clon del móvil en $($script:Cfg.mobileRepoPath)"; $ok = $false }
    $java = Get-Java
    if ($java) { Write-Ok "Java para Gradle: $java" } else { Write-Bad 'falta Java 17 o superior'; $ok = $false }
    $sdk = Get-AndroidSdk
    if ($sdk) {
        Write-Ok "Android SDK: $sdk"
        if (Get-BuildTool $sdk 'apksigner') { Write-Ok 'apksigner disponible' } else { Write-Note 'apksigner no encontrado: no se verificará la firma' }
    } else { Write-Bad 'no se encontró el Android SDK (instálalo con Android Studio o define ANDROID_HOME)'; $ok = $false }
    if (Test-Path -LiteralPath $script:Cfg.mobileKeystoreFile) { Write-Ok "almacén de claves: $($script:Cfg.mobileKeystoreFile) (alias $($script:Cfg.mobileKeyAlias))" }
    else { Write-Bad "no existe el almacén de claves $($script:Cfg.mobileKeystoreFile): .\scripts\sportapp-release.ps1 keystore"; $ok = $false }
    try { Write-Ok "bff-mobile de producción: $(Get-BffUrl)" } catch { Write-Bad $_.Exception.Message; $ok = $false }
    $ok
}

# Sin almacén de claves no se firma el APK: ofrece crearlo en el momento.
function Assert-Keystore {
    if (Test-Path -LiteralPath $script:Cfg.mobileKeystoreFile) { return }
    Write-Note "No existe el almacén de claves del APK ($($script:Cfg.mobileKeystoreFile))."
    $answer = Read-Host "¿Crearlo ahora? Escribe 'si' para crearlo (Enter cancela; con -SkipApk se publica sin APK)"
    if ($answer -ne 'si') { throw "Falta el almacén de claves del APK: créalo con la opción keystore o usa -SkipApk." }
    Invoke-Keystore
}

function Invoke-MobileRelease {
    if (-not $SkipApk) { Assert-Keystore }
    $system = Get-SystemVersion
    $items = Invoke-ReleasePhases $system
    if (-not $items) { return }

    $mobile = $items | Where-Object { $_.Key -eq 'mobile' }
    if ($mobile.State -eq 'validado' -and -not $SkipApk) {
        Publish-Apk $mobile.Version $system
        $mobile.State = 'validado + APK'
    } elseif ($mobile.State -like 'validación*') {
        Write-Note "No se compila el APK porque release-mobile no terminó correctamente ($($mobile.Detail))."
    }

    if ($mobile.State -like 'validado*' -and -not $SkipPlatform) { Sync-Platform @(, @{ Key = 'mobile'; Tag = $mobile.Version }) }
    Show-Summary $items
}

function Invoke-ApkCommand {
    $tag = $MobileVersion
    if (-not $tag) { $tag = Get-LatestStable (Get-Tags (Get-RepoName 'mobile')) }
    if (-not $tag) { throw 'El móvil no tiene releases; indica -MobileVersion vX.Y.Z.' }
    Publish-Apk $tag (Get-SystemVersion)
}

# --- Versión de plataforma: scripts/platform_release.py ---------------------------

function Get-Python {
    if (Get-Command py -ErrorAction SilentlyContinue) { return @{ Exe = 'py'; Args = @('-3') } }
    if (Get-Command python -ErrorAction SilentlyContinue) { return @{ Exe = 'python'; Args = @() } }
    $null
}

function Invoke-Composer([string[]]$Arguments) {
    $py = Get-Python
    if (-not $py) { throw 'Falta Python 3: winget install --id Python.Python.3.13 -e' }
    $r = Invoke-Capture $py.Exe ($py.Args + @((Join-Path $PlatformRoot 'scripts\platform_release.py')) + $Arguments) -AllowFailure
    if ($r.ExitCode -ne 0) { throw (($r.Error, $r.Output | Where-Object { $_ }) -join "`n" -replace '(?m)^ERROR:\s*', '') }
    $r.Output
}

function Test-PythonDeps {
    $py = Get-Python
    if (-not $py) { return $false }
    (Invoke-Capture $py.Exe ($py.Args + @('-c', 'import jsonschema, yaml')) -AllowFailure).ExitCode -eq 0
}

# Mismos nombres que environments/delivery (evidence_buckets) y el mismo registro
# que valida el promotor.
function Get-EvidenceBucket([string]$Key) { "$($script:Cfg.mgmt)-delivery-evidence-$Key" }
function Get-Registry([string]$Key) { "$($script:Cfg.region)-docker.pkg.dev/$($script:Cfg.production)/sportapp-$Key" }

function Get-EvidencePath([string]$Key, [string]$Tag) {
    $allowlist = Get-Content -Raw -LiteralPath (Join-Path $PlatformRoot 'deploy\clouddeploy\allowlist.json') | ConvertFrom-Json
    $allowlist.components.$Key.evidencePath -replace '\{tag\}', $Tag
}

function Test-GcpConfig {
    if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) { return 'gcloud no está instalado' }
    foreach ($name in 'mgmt', 'region', 'production') { if (-not $script:Cfg[$name]) { return "falta `$$name en .env.ps1" } }
    $null
}

# Descarga la evidencia sin transformarla: el sha256 se calcula sobre los bytes
# publicados, igual que el promotor.
function Save-Evidence([string]$Key, [string]$Tag, [string]$Folder) {
    $uri = "gs://$(Get-EvidenceBucket $Key)/$(Get-EvidencePath $Key $Tag)"
    $file = Join-Path $Folder "$Key-release.json"
    $r = Invoke-Capture gcloud @('storage', 'cp', $uri, $file, '--quiet') -AllowFailure
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $file)) {
        throw "No se pudo leer la evidencia de $Key $Tag ($uri). ¿Terminó su Cloud Build? Consulta: .\scripts\sportapp-release.ps1 builds -Target $Key"
    }
    @{ Uri = $uri; File = $file }
}

function Get-ManifestScalar([string]$Path, [string]$Name) {
    $m = Select-String -LiteralPath $Path -Pattern "^${Name}:\s*`"?([^`"]*)`"?\s*$" | Select-Object -First 1
    if ($m) { $m.Matches[0].Groups[1].Value } else { $null }
}

function Get-Gitlinks([string]$Work) {
    $links = @{}
    $lines = (Invoke-Capture git @('-C', $Work, 'ls-tree', 'HEAD', '--', 'components/backend', 'components/frontend', 'components/mobile')).Output -split "`n"
    foreach ($line in $lines) {
        if ($line -match '^160000 commit ([0-9a-f]{40})\s+components/(backend|frontend|mobile)$') { $links[$Matches[2]] = $Matches[1] }
    }
    $links
}

function New-ReleaseWorktree([string]$Base, [string]$Branch, [string]$Work) {
    if (Test-Path -LiteralPath $Work) {
        [void](Invoke-Capture git @('-C', $PlatformRoot, 'worktree', 'remove', '--force', $Work) -AllowFailure)
        Remove-Item -Recurse -Force -LiteralPath $Work -ErrorAction SilentlyContinue
    }
    [void](Invoke-Capture git @('-C', $PlatformRoot, 'worktree', 'prune'))
    Invoke-Show git @('-C', $PlatformRoot, 'worktree', 'add', '--quiet', '--detach', $Work, $Base)
    Invoke-Show git @('-C', $Work, 'switch', '--quiet', '-C', $Branch)
}

function Remove-ReleaseWorktree([string]$Work) {
    [void](Invoke-Capture git @('-C', $PlatformRoot, 'worktree', 'remove', '--force', $Work) -AllowFailure)
    Remove-Item -Recurse -Force -LiteralPath $Work -ErrorAction SilentlyContinue
}

# Confirma y publica los archivos indicados en la rama del worktree; no hace nada
# si ya estaban confirmados (reanudación).
function Publish-Branch([string]$Work, [string]$Branch, [string[]]$Paths, [string]$Message) {
    Invoke-Show git (@('-C', $Work, 'add', '--') + $Paths)
    if ((Invoke-Capture git (@('-C', $Work, 'status', '--porcelain', '--') + $Paths)).Output) {
        Invoke-Show git @('-C', $Work, 'commit', '--quiet', '-m', $Message)
    }
    Invoke-Show git @('-C', $Work, 'push', '--quiet', '--no-recurse-submodules', '-u', 'origin', $Branch)
}

function Get-BranchPr([string]$Repo, [string]$Head, [string]$Base, [string]$State) {
    @(Invoke-GhJson @('pr', 'list', '--repo', $Repo, '--head', $Head, '--base', $Base, '--state', $State, '--json', 'number,url,mergeCommit') | Where-Object { $_ }) | Select-Object -First 1
}

# PR de $Head a $Base, reutilizado o creado; devuelve el ítem para las fases comunes
# (Wait-Checks y Approve-AndMerge). Si ya estaba fusionado, queda en 'fusionado'.
function Open-BranchPr([string]$Head, [string]$Base, [string]$Title, [string]$BodyFile, [string]$Label, [string]$Version) {
    $repo = Get-RepoName 'platform'
    $item = [pscustomobject]@{ Key = 'platform'; Repo = $repo; Label = $Label; Version = $Version; Pr = $null; PrUrl = $null; MergeSha = $null; State = 'pendiente'; Detail = ''; Commits = @() }
    $merged = Get-BranchPr $repo $Head $Base 'merged'
    if ($merged) {
        $item.Pr = $merged.number; $item.PrUrl = $merged.url; $item.MergeSha = $merged.mergeCommit.oid; $item.State = 'fusionado'
        Write-Ok "$($Label): el PR #$($item.Pr) ya está fusionado"
        return $item
    }
    $open = Get-BranchPr $repo $Head $Base 'open'
    if ($open) {
        $item.Pr = $open.number; $item.PrUrl = $open.url
        Write-Ok "$($Label): se reutiliza el PR #$($item.Pr) $($item.PrUrl)"
        return $item
    }
    $r = Invoke-Capture gh @('pr', 'create', '--repo', $repo, '--base', $Base, '--head', $Head, '--title', $Title, '--body-file', $BodyFile)
    $item.PrUrl = ($r.Output -split "`n")[-1]
    $item.Pr = [int](($item.PrUrl -split '/')[-1])
    Write-Ok "$($Label): PR #$($item.Pr) $($item.PrUrl)"
    $item
}

function Complete-BranchPr($Item) {
    if ($Item.State -eq 'fusionado') { return }
    Wait-Checks @($Item)
    Approve-AndMerge @($Item)
    if ($Item.State -ne 'fusionado') {
        throw "$($Item.Label): $($Item.State) $($Item.Detail). Corrige y repite release con la misma versión: se reutilizan la rama y el PR."
    }
}

function Remove-RemoteBranch([string]$Branch) {
    $r = Invoke-Capture gh @('api', '-X', 'DELETE', "repos/$(Get-RepoName 'platform')/git/refs/heads/$Branch") -AllowFailure
    if ($r.ExitCode -eq 0) { Write-Ok "rama $Branch eliminada en GitHub" }
}

function Test-PlatformTools {
    $ok = $true
    Write-Step 'Composición'
    $py = Get-Python
    if (-not $py) { Write-Bad 'falta Python 3: winget install --id Python.Python.3.13 -e'; $ok = $false }
    elseif (Test-PythonDeps) { Write-Ok "Python con pyyaml y jsonschema ($($py.Exe))" }
    else { Write-Bad "faltan pyyaml o jsonschema: $($py.Exe) $($py.Args -join ' ') -m pip install jsonschema==4.23.0 pyyaml==6.0.2"; $ok = $false }

    Write-Step 'Evidencia de Cloud Build (lectura)'
    $gcp = Test-GcpConfig
    if ($gcp) { Write-Bad $gcp; $ok = $false }
    else {
        foreach ($key in 'backend', 'frontend') {
            $bucket = Get-EvidenceBucket $key
            if ((Invoke-Capture gcloud @('storage', 'ls', "gs://$bucket", '--quiet') -AllowFailure).ExitCode -eq 0) { Write-Ok "gs://$bucket" }
            else { Write-Bad "no se puede leer gs://$bucket con la cuenta activa de gcloud"; $ok = $false }
        }
    }
    $latest = Get-LatestStable (Get-Tags (Get-RepoName 'platform'))
    Write-Ok "última versión de plataforma: $(if ($latest) { $latest } else { 'sin tags' }); propuesta: $(Get-NextVersion $latest)"
    $ok
}

function Invoke-PlatformStatus {
    $repo = Get-RepoName 'platform'
    Write-Step "Plataforma ($repo)"
    if (-not (Test-Branch $repo 'develop')) { Write-Bad 'no existe develop (ejecuta prepare)'; return }
    $diff = Get-Ahead $repo
    Write-Info "develop tiene $($diff.ahead) commit(s) que main no tiene; main tiene $($diff.behind) que develop no tiene"
    $latest = Invoke-GhJson @('release', 'list', '--repo', $repo, '--limit', '1', '--json', 'tagName,publishedAt') -AllowFailure
    if (@($latest).Count -and @($latest)[0]) { Write-Ok "última release: $(@($latest)[0].tagName) ($(@($latest)[0].publishedAt))" } else { Write-Info 'sin releases' }
    $open = @(Invoke-GhJson @('pr', 'list', '--repo', $repo, '--state', 'open', '--json', 'number,headRefName,baseRefName,url') | Where-Object { $_ -and $_.headRefName -match '^(release/|chore/abrir-v)' })
    foreach ($p in $open) { Write-Info "PR abierto: #$($p.number) $($p.headRefName) -> $($p.baseRefName) $($p.url)" }

    Write-Step 'Manifiesto candidato (origin/develop)'
    [void](Invoke-Capture git @('-C', $PlatformRoot, 'fetch', '--quiet', 'origin', 'develop'))
    $file = Join-Path $env:TEMP 'sportapp-manifest-develop.yaml'
    Write-TextFile $file (Invoke-Capture git @('-C', $PlatformRoot, 'show', 'origin/develop:release-manifest.yaml')).Output
    Write-Info "platformVersion $(Get-ManifestScalar $file 'platformVersion'), status $(Get-ManifestScalar $file 'status'), $(Get-ManifestScalar $file 'sprint')"
    if (Test-PythonDeps) {
        $refs = Invoke-Composer @('refs', '--draft', $file) | ConvertFrom-Json
        foreach ($key in 'backend', 'frontend', 'mobile') {
            $ref = $refs.$key
            if ($ref) { Write-Ok "$($Components[$key].Label): $ref" } else { Write-Bad "$($Components[$key].Label): sin release (no se puede publicar la plataforma)" }
        }
    }
    Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
}

# HU de la versión: lo integrado en develop se considera aceptado, así que son los
# HUxxx de los mensajes de commit de cada componente entre la versión de la release
# de plataforma anterior y la nueva (todo el historial en la primera).
function Get-DevelopedStories($Refs, [hashtable]$Previous) {
    $ids = @{}
    foreach ($key in 'backend', 'frontend', 'mobile') {
        $path = Join-Path $PlatformRoot "components\$key"
        [void](Invoke-Capture git @('-C', $path, 'fetch', '--quiet', '--tags', 'origin') -AllowFailure)
        $range = if ($Previous[$key]) { "$($Previous[$key])..$($Refs.$key)" } else { $Refs.$key }
        $log = Invoke-Capture git @('-C', $path, 'log', '--format=%s%n%b', $range) -AllowFailure
        if ($log.ExitCode -ne 0) { throw "No se pudo leer el historial de components/$key ($range): $($log.Error)" }
        foreach ($m in [regex]::Matches($log.Output, '(?i)\bHU(\d{3})\b')) { $ids["HU$($m.Groups[1].Value)"] = $true }
    }
    @($ids.Keys | Sort-Object)
}

function Invoke-PlatformRelease {
    if (-not (Get-Login)) { throw 'gh no tiene sesión: gh auth login' }
    $repo = Get-RepoName 'platform'
    if (-not (Test-Branch $repo 'develop')) { throw 'La plataforma no tiene develop: ejecuta prepare.' }
    $gcp = Test-GcpConfig
    if ($gcp) { throw "$gcp (se necesita para leer la evidencia de Cloud Build)." }
    if (-not (Test-PythonDeps)) { throw 'Faltan Python, pyyaml o jsonschema: ejecuta check.' }
    $storyList = @($Stories | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })

    # Versión: explícita o la siguiente al último tag estable.
    $tags = Get-Tags $repo
    $latest = Get-LatestStable $tags
    $version = if ($PlatformVersion) { $PlatformVersion } else { Get-NextVersion $latest }
    if ($version -notmatch $SemVerPattern) { throw "'$version' no es vX.Y.Z." }
    if ($tags -contains $version) { throw "El tag $version ya existe en la plataforma; indica otra versión con -PlatformVersion." }
    $p = ConvertTo-VersionParts $version
    $next = "$($p.Major).$($p.Minor + 1).0"
    $branch = "release/$version"
    $returnBranch = "chore/abrir-v$next"

    # Worktree temporal: no toca el árbol de trabajo del operador.
    Invoke-Show git @('-C', $PlatformRoot, 'fetch', '--quiet', '--prune', 'origin')
    $remoteRelease = (Invoke-Capture git @('-C', $PlatformRoot, 'rev-parse', '--verify', '--quiet', "refs/remotes/origin/$branch") -AllowFailure).ExitCode -eq 0
    $base = if ($remoteRelease) { "origin/$branch" } else { 'origin/develop' }
    $work = Join-Path $env:TEMP "sportapp-platform-$version"
    $done = $false
    New-ReleaseWorktree $base $branch $work
    try {
        $manifest = Join-Path $work 'release-manifest.yaml'
        $sprintName = if ($Sprint) { $Sprint } else { Get-ManifestScalar $manifest 'sprint' }
        $refs = Invoke-Composer @('refs', '--draft', $manifest) | ConvertFrom-Json
        $links = Get-Gitlinks $work
        if (-not $storyList.Count) {
            $previous = @{}
            if ($latest) {
                $file = Join-Path $env:TEMP "sportapp-manifest-$latest.yaml"
                Write-TextFile $file (Invoke-Capture git @('-C', $PlatformRoot, 'show', "${latest}:release-manifest.yaml")).Output
                $old = Invoke-Composer @('refs', '--draft', $file) | ConvertFrom-Json
                Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
                foreach ($key in 'backend', 'frontend', 'mobile') { $previous[$key] = $old.$key }
            }
            $storyList = Get-DevelopedStories $refs $previous
            if (-not $storyList.Count) { throw 'Los commits de los componentes no mencionan ninguna HU desde la release anterior; indícalas con -Stories HU001,HU010.' }
        }

        Write-Step "Plan de la release de plataforma $version"
        Write-Info "Base: $base   Sprint: $sprintName   HU: $($storyList -join ', ')"
        Write-Info "Última versión: $(if ($latest) { $latest } else { 'sin tags' }); develop queda después en $next (draft)"
        foreach ($key in 'backend', 'frontend', 'mobile') {
            $ref = $refs.$key
            if (-not $ref) { throw "$($Components[$key].Label) no tiene release en el manifiesto de develop: publícala y mueve su submódulo (sportapp-release.ps1 submodules) antes de la release de plataforma." }
            $tagSha = (Invoke-Capture gh @('api', "repos/$(Get-RepoName $key)/commits/$ref", '--jq', '.sha') -AllowFailure).Output
            if ($tagSha -ne $links[$key]) { throw "$($Components[$key].Label): components/$key apunta a $($links[$key]) pero $ref es $tagSha. Mueve el submódulo al tag (submodules) en develop." }
            Write-Ok "$($Components[$key].Label): $ref ($($links[$key].Substring(0, 7)))"
        }
        Confirm-Step "¿Componer la release $version con esta combinación?"

        Write-Step 'Manifiesto released y copia en releases/'
        $folder = Join-Path $work '.evidencia'
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        $backend = Save-Evidence 'backend' $refs.backend $folder
        $frontend = Save-Evidence 'frontend' $refs.frontend $folder
        $apk = Get-ReleaseApkSha $refs.mobile
        $copy = "releases/$version.yaml"
        $result = Invoke-Composer @(
            'compose', '--draft', $manifest, '--platform-version', $version.Substring(1), '--sprint', $sprintName, '--stories', ($storyList -join ','),
            "--gitlink=backend=$($links.backend)", "--gitlink=frontend=$($links.frontend)", "--gitlink=mobile=$($links.mobile)",
            '--backend-evidence', $backend.File, '--backend-evidence-uri', $backend.Uri, '--registry-backend', (Get-Registry 'backend'),
            '--frontend-evidence', $frontend.File, '--frontend-evidence-uri', $frontend.Uri, '--registry-frontend', (Get-Registry 'frontend'),
            '--mobile-sha256', "$apk", '--output', $manifest, '--release-copy', (Join-Path $work $copy))
        Remove-Item -Recurse -Force -LiteralPath $folder
        Write-Ok "evidencia validada y contratos compatibles: $result"
        Invoke-Show git @('-C', $work, '--no-pager', 'diff', '--stat', '--', 'release-manifest.yaml')

        $notes = Join-Path $env:TEMP "sportapp-platform-notes-$version.md"
        $previous = if ($latest) { Join-Path $work "releases/$latest.yaml" } else { $null }
        $notesArgs = @('notes', '--manifest', $manifest, '--output', $notes)
        if ($previous -and (Test-Path -LiteralPath $previous)) { $notesArgs += @('--previous', $previous) }
        [void](Invoke-Composer $notesArgs)

        Confirm-Step "¿Confirmar y publicar la rama ${branch}?"
        Publish-Branch $work $branch @('release-manifest.yaml', $copy) "release: plataforma $version"
        Write-Ok "rama $branch publicada"

        Write-Step "Pull request $branch -> main"
        $item = Open-BranchPr $branch 'main' "release: plataforma $version" $notes 'Plataforma' $version
        Complete-BranchPr $item

        Write-Step "GitHub Release $version"
        if (Invoke-GhJson @('release', 'view', $version, '--repo', $repo, '--json', 'url') -AllowFailure) { Write-Ok 'ya existe' }
        else {
            Write-TextFile $notes ((Get-Content -Raw -Encoding UTF8 -LiteralPath $notes) + "`nPull request: $($item.PrUrl)`nCommit: $($item.MergeSha)`n")
            $create = @('release', 'create', $version, '--repo', $repo, '--target', $item.MergeSha, '--title', "SportApp $version ($sprintName)", '--notes-file', $notes)
            if ($version -match '-') { $create += '--prerelease' }
            Write-Ok (Invoke-Capture gh $create).Output
        }

        Write-Step "Retorno a develop y ciclo $next"
        Invoke-Show git @('-C', $work, 'switch', '--quiet', '-C', $returnBranch)
        [void](Invoke-Composer @('reopen', '--manifest', $manifest, '--next-version', $next, '--output', $manifest))
        Publish-Branch $work $returnBranch @('release-manifest.yaml') "chore(platform): abrir el ciclo v$next"
        $body = Join-Path $env:TEMP "sportapp-platform-return-$version.md"
        Write-TextFile $body "Devuelve a develop la release **$version** (manifiesto y releases/$version.yaml) y abre el ciclo **v$next** en draft, sin HU aceptadas.`n`nGenerado por ``scripts/$ReleaseScriptName``."
        $back = Open-BranchPr $returnBranch 'develop' "chore: retorno de la release $version y ciclo v$next" $body 'Plataforma (retorno a develop)' "v$next"
        Complete-BranchPr $back
        Remove-Item -LiteralPath $notes, $body -ErrorAction SilentlyContinue
        Remove-RemoteBranch $branch
        Remove-RemoteBranch $returnBranch
        $done = $true
    } finally {
        Remove-ReleaseWorktree $work
    }
    # Las ramas locales solo existían para el worktree; si algo falló se conservan.
    if ($done) { [void](Invoke-Capture git @('-C', $PlatformRoot, 'branch', '-D', $branch, $returnBranch) -AllowFailure) }

    Write-Host ''
    Write-Host "Plataforma $version publicada; develop queda en v$next (draft)." -ForegroundColor Green
    Write-Info 'Actualiza tu clon antes de operar producción (sportapp-gcp.ps1 lee los submódulos del árbol local):'
    Write-Info '  git switch main; git pull --ff-only'
    Write-Info "Despliegue: .\scripts\sportapp-gcp.ps1 promote -BackendVersion $($refs.backend) -FrontendVersion $($refs.frontend)"
}

# --- Comandos -----------------------------------------------------------------

# Sesión de gh y acceso a los repositorios de $Repos. Devuelve $false si falta algo.
function Test-GitHubAccess {
    $ok = $true
    Write-Step 'GitHub CLI'
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Write-Bad 'gh no está instalado: winget install --id GitHub.cli -e'; throw 'Instala GitHub CLI.' }
    $login = Get-Login
    if (-not $login) { Write-Bad 'gh no tiene sesión: gh auth login'; throw 'Inicia sesión en gh.' }
    Write-Ok "sesión de gh: $login"
    if (Get-ReviewerToken $login) { Write-Ok 'cuenta revisora disponible para aprobar los PR' }
    else { Write-Note 'sin cuenta revisora ($releaseReviewer o SPORTAPP_REVIEWER_TOKEN): se fusionará con --admin' }

    Write-Step 'Repositorios'
    foreach ($key in $Repos) {
        $repo = Get-RepoName $key
        $perm = Invoke-GhJson @('api', "repos/$repo", '--jq', '{admin: .permissions.admin, push: .permissions.push}') -AllowFailure
        if (-not $perm) { Write-Bad "$repo no es accesible"; $ok = $false; continue }
        $main = Test-Branch $repo 'main'; $develop = Test-Branch $repo 'develop'
        $line = "$repo  main: $(if ($main) { 'sí' } else { 'NO' })  develop: $(if ($develop) { 'sí' } else { 'NO' })  admin: $($perm.admin)"
        if ($main -and $develop) { Write-Ok $line } else { Write-Bad "$line  -> ejecuta prepare"; $ok = $false }
    }
    $ok
}

function Invoke-CheckCommand {
    $ok = Test-GitHubAccess
    if ($Repos | Where-Object { $_ -ne 'platform' }) { Write-Ok "versión del sistema: $(Get-SystemVersion)" }
    if ($Repos -contains 'mobile') { $ok = (Test-MobileTools) -and $ok }
    if ($Repos -contains 'platform') { $ok = (Test-PlatformTools) -and $ok }
    Write-Host ''
    if (-not $ok) { throw 'Hay pendientes (marcados con [falta]).' }
    $next = if ($Target -eq 'all') { 'release' } else { "release -Target $Target" }
    Write-Host "Todo listo. Siguiente: .\scripts\sportapp-release.ps1 $next" -ForegroundColor Green
}

function Invoke-Status([string[]]$Keys) {
    foreach ($key in $Keys) {
        $repo = Get-RepoName $key
        Write-Step "$($Components[$key].Label) ($repo)"
        if (-not (Test-Branch $repo 'main')) { Write-Bad 'no existe main (ejecuta prepare)'; continue }
        $diff = Get-Ahead $repo
        Write-Info "develop tiene $($diff.ahead) commit(s) que main no tiene; main tiene $($diff.behind) que develop no tiene"
        $open = @(Invoke-GhJson @('pr', 'list', '--repo', $repo, '--base', 'main', '--head', 'develop', '--state', 'open', '--json', 'number,url') | Where-Object { $_ })
        if ($open.Count) { Write-Info "PR abierto: #$($open[0].number) $($open[0].url)" }
        $latest = Invoke-GhJson @('release', 'list', '--repo', $repo, '--limit', '1', '--json', 'tagName,publishedAt') -AllowFailure
        if (@($latest).Count -and @($latest)[0]) { Write-Ok "última release: $(@($latest)[0].tagName) ($(@($latest)[0].publishedAt))" } else { Write-Info 'sin releases' }
        $merged = Get-UnreleasedMerge $repo (Get-LatestStable (Get-Tags $repo))
        if ($merged) { Write-Bad "el PR #$($merged.number) ($($merged.title)) se fusionó en main sin release: repite release para publicarla" }
    }
}

function Invoke-StatusCommand {
    Invoke-Status @($Repos | Where-Object { $_ -ne 'platform' })
    if ($Repos -contains 'platform') { Invoke-PlatformStatus }
}

# Una sola vez por repositorio: deja main y develop como las espera release.
function Initialize-Branches([string]$Key) {
    $repo = Get-RepoName $Key
    switch ($Key) {
        'frontend' {
            Write-Step "Rama main en $repo"
            if (Test-Branch $repo 'main') { Write-Ok 'ya existe'; return }
            $path = $script:Cfg.frontendRepoPath
            if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { throw "No se encontró el clon del frontend en $path (define `$frontendRepoPath)." }
            Invoke-Show git @('-C', $path, 'fetch', '--quiet', 'origin', 'develop')
            $root = @((Invoke-Capture git @('-C', $path, 'rev-list', '--max-parents=0', 'origin/develop')).Output -split "`n")[-1]
            $message = (Invoke-Capture git @('-C', $path, 'log', '-1', '--format=%s (%ad)', '--date=short', $root)).Output
            Write-Info "Se crea main en el primer commit de develop ($($root.Substring(0, 7)) $message): el primer PR develop -> main mostrará todo el historial."
            Confirm-Step "¿Crear main en ${repo}?"
            [void](Invoke-Capture gh @('api', '-X', 'POST', "repos/$repo/git/refs", '-f', 'ref=refs/heads/main', '-f', "sha=$root"))
            Write-Ok 'main creada'
            Write-Note 'Protege main en el frontend como en el backend (Settings -> Rules: PR obligatorio y 1 aprobación).'
        }
        'mobile' {
            Write-Step "Rama main en $repo"
            if (Test-Branch $repo 'main') { Write-Ok 'ya existe'; return }
            if (-not (Test-Branch $repo 'master')) { Write-Bad 'no existen main ni master; créala a mano'; return }
            Write-Info 'Se renombra master a main: GitHub conserva los PR, redirige la rama y actualiza la rama por defecto.'
            Confirm-Step "¿Renombrar master a main en ${repo}?"
            [void](Invoke-Capture gh @('api', '-X', 'POST', "repos/$repo/branches/master/rename", '-f', 'new_name=main'))
            if (Test-Path -LiteralPath (Join-Path $script:Cfg.mobileRepoPath '.git')) { [void](Invoke-Capture git @('-C', $script:Cfg.mobileRepoPath, 'fetch', '--prune', 'origin') -AllowFailure) }
            Write-Ok 'master renombrada a main'
            Write-Note 'Protege main como en el backend (Settings -> Rules: PR obligatorio y 1 aprobación).'
        }
        'platform' {
            Write-Step "Rama develop en $repo"
            if (Test-Branch $repo 'develop') { Write-Ok 'ya existe'; return }
            $sha = (Invoke-Capture gh @('api', "repos/$repo/branches/main", '--jq', '.commit.sha')).Output
            Write-Info "Se crea develop en el commit actual de main ($($sha.Substring(0, 7)))."
            Confirm-Step "¿Crear develop en ${repo}?"
            [void](Invoke-Capture gh @('api', '-X', 'POST', "repos/$repo/git/refs", '-f', 'ref=refs/heads/develop', '-f', "sha=$sha"))
            Write-Ok 'develop creada'
            Write-Note 'Desde ahora las ramas de trabajo de la plataforma salen de develop y su PR va a develop; main solo recibe releases y hotfix.'
            Write-Note 'Protege main y develop (Settings -> Rules: PR obligatorio y 1 aprobación), como en los componentes.'
        }
        default {
            Write-Step "Ramas main y develop en $repo"
            if ((Test-Branch $repo 'main') -and (Test-Branch $repo 'develop')) { Write-Ok 'ya existen' }
            else { Write-Bad 'falta main o develop; créala a mano' }
        }
    }
}

function Invoke-PrepareCommand {
    if (-not (Get-Login)) { throw 'gh no tiene sesión: gh auth login' }
    foreach ($key in $Repos) { Initialize-Branches $key }
}

function Invoke-ReleaseCommand {
    switch ($Target) {
        'mobile' { Invoke-MobileRelease }
        'platform' { Invoke-PlatformRelease }
        default { Invoke-ComponentRelease }
    }
}

# Opción de -Target o, si falta, la que el operador elige en el menú.
function Select-Target([string[]]$Allowed, [string]$Verb) {
    if ($Target) {
        if ($Allowed -notcontains $Target) { throw "$Command no admite -Target $Target; opciones: $($Allowed -join ', ')." }
        return $Target
    }
    if ($Allowed.Count -eq 1) { return $Allowed[0] }
    Write-Step "¿Qué quieres ${Verb}?"
    for ($n = 0; $n -lt $Allowed.Count; $n++) { Write-Host ("  {0}. {1}" -f ($n + 1), $Targets[$Allowed[$n]].Label) }
    Write-Host ''
    $answer = Read-Host "Escribe el número de la opción (1-$($Allowed.Count)) o Enter para salir"
    if (-not $answer) { throw 'Cancelado por el operador; no se hizo nada.' }
    $index = 0
    if (-not [int]::TryParse($answer.Trim(), [ref]$index) -or $index -lt 1 -or $index -gt $Allowed.Count) { throw "'$answer' no es una opción del menú." }
    $Allowed[$index - 1]
}

function Select-Command {
    $keys = @($CommandMenu.Keys)
    Write-Step '¿Qué quieres hacer?'
    for ($n = 0; $n -lt $keys.Count; $n++) { Write-Host ("  {0}. {1}" -f ($n + 1), $CommandMenu[$keys[$n]]) }
    Write-Host ''
    $answer = Read-Host "Escribe el número de la opción (1-$($keys.Count)) o Enter para salir"
    if (-not $answer) { throw 'Cancelado por el operador; no se hizo nada.' }
    $index = 0
    if (-not [int]::TryParse($answer.Trim(), [ref]$index) -or $index -lt 1 -or $index -gt $keys.Count) { throw "'$answer' no es una opción del menú." }
    $keys[$index - 1]
}

$previousEncoding = [Console]::OutputEncoding
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { $previousEncoding = $null }
try {
    # Con -Target y sin comando se conserva el comportamiento anterior: release.
    if (-not $Command) { $Command = if ($Target) { 'release' } else { Select-Command } }
    if ($Command -eq 'hotfix') { $HotfixMode = $true; $ReleaseKind = 'hotfix'; $Bump = 'patch' }
    if ($Command -eq 'help') { Get-Help $PSCommandPath -Detailed | Out-Host; return }
    $script:Cfg = Read-Config
    $Target = Select-Target $CommandTargets[$Command].Targets $CommandTargets[$Command].Verb
    $Repos = $Targets[$Target].Repos
    Write-Ok "$Command`: $($Targets[$Target].Label)"
    switch ($Command) {
        'check' { Invoke-CheckCommand }
        'status' { Invoke-StatusCommand }
        'prepare' { Invoke-PrepareCommand }
        'keystore' { Invoke-Keystore }
        { $_ -in 'release', 'hotfix' } { Invoke-ReleaseCommand }
        'builds' { Invoke-BuildsCommand }
        'apk' { Invoke-ApkCommand }
        'submodules' { Invoke-SubmodulesCommand }
    }
} catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Remove-Item Env:SPORTAPP_SIGNING_STORE_PASSWORD, Env:SPORTAPP_SIGNING_KEY_PASSWORD -ErrorAction SilentlyContinue
    if ($previousEncoding) { try { [Console]::OutputEncoding = $previousEncoding } catch { } }
}
