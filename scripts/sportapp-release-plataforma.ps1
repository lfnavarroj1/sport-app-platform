<#
.SYNOPSIS
    Publica la release de sport-app-platform (versión del sistema): rama
    release/vX.Y.Z desde develop, manifiesto released, PR a main, tag y retorno
    a develop con el ciclo siguiente abierto.

.DESCRIPTION
    La plataforma no construye nada: fija la combinación de backend, frontend y
    móvil ya publicados con sportapp-release.ps1 y sportapp-release-movil.ps1.
    Se ejecuta desde la estación del operador con gh, git, Python (pyyaml y
    jsonschema) y gcloud en modo lectura (evidencia de Cloud Build). No despliega.

      check    Valida gh, ramas, Python y lectura de la evidencia de Cloud Build.
      status   develop frente a main, manifiesto candidato, PR y última release.
      prepare  Una sola vez: crea develop en la plataforma desde main.
      release  Crea release/vX.Y.Z desde develop, completa release-manifest.yaml
               (status released) con la evidencia de Cloud Build y lo copia a
               releases/vX.Y.Z.yaml; abre el PR a main, espera sus pruebas, pide
               la aprobación, fusiona, crea la GitHub Release vX.Y.Z y devuelve
               el manifiesto a develop en draft con la versión siguiente.

    Instrucciones: scripts/sportapp-release-plataforma.md.

.EXAMPLE
    .\scripts\sportapp-release-plataforma.ps1 release -Stories HU001,HU010

.EXAMPLE
    .\scripts\sportapp-release-plataforma.ps1 release -Stories HU004 -Bump patch -Sprint "Sprint 2"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'check', 'status', 'prepare', 'release')]
    [string]$Command = 'help',

    # HU aceptadas en la revisión del sprint (obligatorio en release).
    [string[]]$Stories,

    # Sprint de la versión; por defecto el de release-manifest.yaml en develop.
    [string]$Sprint,

    # Incremento propuesto desde el último tag de la plataforma.
    [ValidateSet('patch', 'minor', 'major')]
    [string]$Bump = 'minor',

    # Versión explícita (vX.Y.Z); reemplaza la propuesta.
    [string]$PlatformVersion,

    # Omite las confirmaciones de rutina. La aprobación de cada PR siempre se pregunta.
    [switch]$AutoApprove,

    [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'

$PlatformRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigFile) { $ConfigFile = Join-Path $PlatformRoot '.env.ps1' }
elseif (Test-Path -LiteralPath $ConfigFile) { $ConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path }
$script:MyScriptPath = $PSCommandPath
$ReleaseScriptName = 'sportapp-release-plataforma.ps1'
$Repos = @('platform')
$BackendVersion = $null
$FrontendVersion = $null
$MobileVersion = $null
$SystemVersion = $null

. (Join-Path $PSScriptRoot 'sportapp-release-common.ps1')

# --- Python: scripts/platform_release.py -----------------------------------------

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

# --- GCP: evidencia de Cloud Build (solo lectura) ----------------------------------

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
        throw "No se pudo leer la evidencia de $Key $Tag ($uri). ¿Terminó su Cloud Build? Consulta: .\scripts\sportapp-release.ps1 builds -Repos $Key"
    }
    @{ Uri = $uri; File = $file }
}

# --- Repositorio local y worktree ---------------------------------------------------

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

# --- Pull requests --------------------------------------------------------------------

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

# --- Comandos -------------------------------------------------------------------------

function Invoke-Check {
    $ok = Test-GitHubAccess
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
    Write-Host ''
    if ($ok) { Write-Host 'Todo listo. Siguiente: .\scripts\sportapp-release-plataforma.ps1 release -Stories HU001,HU010' -ForegroundColor Green }
    else { throw 'Hay pendientes (marcados con [falta]).' }
}

function Invoke-Prepare {
    if (-not (Get-Login)) { throw 'gh no tiene sesión: gh auth login' }
    $repo = Get-RepoName 'platform'
    Write-Step "Rama develop en $repo"
    if (Test-Branch $repo 'develop') { Write-Ok 'ya existe'; return }
    $sha = (Invoke-Capture gh @('api', "repos/$repo/branches/main", '--jq', '.commit.sha')).Output
    Write-Info "Se crea develop en el commit actual de main ($($sha.Substring(0, 7)))."
    Confirm-Step "¿Crear develop en $repo?"
    [void](Invoke-Capture gh @('api', '-X', 'POST', "repos/$repo/git/refs", '-f', 'ref=refs/heads/develop', '-f', "sha=$sha"))
    Write-Ok 'develop creada'
    Write-Note 'Desde ahora las ramas de trabajo de la plataforma salen de develop y su PR va a develop; main solo recibe releases y hotfix.'
    Write-Note 'Protege main y develop (Settings -> Rules: PR obligatorio y 1 aprobación), como en los componentes.'
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

function Invoke-PlatformRelease {
    if (-not (Get-Login)) { throw 'gh no tiene sesión: gh auth login' }
    $repo = Get-RepoName 'platform'
    if (-not (Test-Branch $repo 'develop')) { throw 'La plataforma no tiene develop: ejecuta prepare.' }
    $gcp = Test-GcpConfig
    if ($gcp) { throw "$gcp (se necesita para leer la evidencia de Cloud Build)." }
    if (-not (Test-PythonDeps)) { throw 'Faltan Python, pyyaml o jsonschema: ejecuta check.' }
    $storyList = @($Stories | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
    if (-not $storyList.Count) { throw 'Indica las HU aceptadas en la revisión del sprint: -Stories HU001,HU010' }

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

        Write-Step "Plan de la release de plataforma $version"
        Write-Info "Base: $base   Sprint: $sprintName   HU: $($storyList -join ', ')"
        Write-Info "Última versión: $(if ($latest) { $latest } else { 'sin tags' }); develop queda después en $next (draft)"
        foreach ($key in 'backend', 'frontend', 'mobile') {
            $ref = $refs.$key
            if (-not $ref) { throw "$($Components[$key].Label) no tiene release en el manifiesto de develop: publícala y mueve su submódulo (sportapp-release*.ps1 submodules) antes de la release de plataforma." }
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

        Confirm-Step "¿Confirmar y publicar la rama $branch?"
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

Invoke-Main @{
    check   = { Invoke-Check }
    status  = { Invoke-PlatformStatus }
    prepare = { Invoke-Prepare }
    release = { Invoke-PlatformRelease }
}
