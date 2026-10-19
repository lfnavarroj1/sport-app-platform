# Funciones compartidas por sportapp-release.ps1 (backend y frontend) y
# sportapp-release-movil.ps1 (móvil). Se carga con dot-sourcing desde esos
# scripts, que definen antes sus parámetros, $PlatformRoot, $ConfigFile,
# $ReleaseScriptName y $Repos; no se ejecuta solo.

$Components = [ordered]@{
    backend  = @{ Repo = 'sport-app-backend'; Label = 'Backend'; Workflow = 'release-validation.yml'; Trigger = 'release-backend' }
    frontend = @{ Repo = 'sport-app-frontend'; Label = 'Frontend web'; Workflow = 'release-web.yml'; Trigger = 'release-frontend' }
    mobile   = @{ Repo = 'sport-app-movil'; Label = 'Móvil'; Workflow = 'release-mobile.yml' }
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
    $names = @('githubOwner', 'releaseReviewer', 'mobileRepoPath', 'frontendRepoPath', 'mobileKeystoreFile', 'mobileKeyAlias', 'mobileBffBaseUrl', 'production', 'region', 'mgmt')
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

function Get-Ahead([string]$Repo) {
    # Sin comillas dentro del filtro: Windows PowerShell 5.1 no las escapa al llamar a gh.
    $c = Invoke-GhJson @('api', "repos/$Repo/compare/main...develop", '--jq', '{ahead: .ahead_by, behind: .behind_by, commits: [.commits[] | {sha: .sha, message: .commit.message}]}')
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

# --- Fases de release ---------------------------------------------------------

function New-ReleaseItems {
    $tagsUsed = @{}
    $items = foreach ($key in $Repos) {
        $repo = Get-RepoName $key
        $item = [pscustomobject]@{
            Key = $key; Repo = $repo; Label = $Components[$key].Label; Workflow = $Components[$key].Workflow
            Version = $null; Latest = $null; Pr = $null; PrUrl = $null; MergeSha = $null; State = 'pendiente'; Detail = ''
            Commits = @()
        }
        if (-not (Test-Branch $repo 'main')) { $item.State = 'omitido'; $item.Detail = 'no existe main: ejecuta prepare'; $item; continue }
        if (-not (Test-Branch $repo 'develop')) { $item.State = 'omitido'; $item.Detail = 'no existe develop'; $item; continue }
        $diff = Get-Ahead $repo
        $item.Commits = @($diff.commits)
        $tags = Get-Tags $repo
        $item.Latest = Get-LatestStable $tags
        $explicit = @{ backend = $BackendVersion; frontend = $FrontendVersion; mobile = $MobileVersion }[$key]
        $item.Version = if ($explicit) { $explicit } else { Get-NextVersion $item.Latest }
        if ($item.Version -notmatch $SemVerPattern) { throw "$($item.Label): '$($item.Version)' no es vX.Y.Z." }
        if ($tags -contains $item.Version) { throw "$($item.Label): el tag $($item.Version) ya existe; indica otra versión." }
        if ($diff.ahead -eq 0) { $item.State = 'omitido'; $item.Detail = 'develop no tiene cambios respecto de main' }
        $item
    }
    @($items)
}

function Show-Plan($Items, [string]$System) {
    Write-Step "Plan de release (sistema $System)"
    foreach ($i in $Items) {
        if ($i.State -eq 'omitido') { Write-Note "$($i.Label): omitido ($($i.Detail))"; continue }
        $from = if ($i.Latest) { $i.Latest } else { 'sin tags' }
        Write-Ok "$($i.Label): $from -> $($i.Version) con $($i.Commits.Count) commit(s) de develop"
        $i.Commits | Select-Object -First 10 | ForEach-Object { Write-Info $_ }
        if ($i.Commits.Count -gt 10) { Write-Info "... y $($i.Commits.Count - 10) más" }
    }
}

function Open-PullRequests($Items, [string]$System) {
    Write-Step 'Fase 1: pull requests develop -> main'
    foreach ($i in $Items | Where-Object { $_.State -eq 'pendiente' }) {
        $open = @(Invoke-GhJson @('pr', 'list', '--repo', $i.Repo, '--base', 'main', '--head', 'develop', '--state', 'open', '--json', 'number,url'))
        if ($open.Count -gt 0 -and $open[0]) {
            $i.Pr = $open[0].number; $i.PrUrl = $open[0].url
            Write-Ok "$($i.Label): se reutiliza el PR #$($i.Pr) $($i.PrUrl)"
            continue
        }
        $body = @(
            "Release **$($i.Version)** de $($i.Label) (versión del sistema $System)."
            ''
            "Generado por ``sport-app-platform/scripts/$ReleaseScriptName``. Al fusionarse se crea la release y su tag sobre el commit de merge."
            ''
            '### Commits'
            ($i.Commits | ForEach-Object { "- $_" })
        ) -join "`n"
        $file = Join-Path $env:TEMP "sportapp-pr-$($i.Key).md"
        Write-TextFile $file $body
        $r = Invoke-Capture gh @('pr', 'create', '--repo', $i.Repo, '--base', 'main', '--head', 'develop', '--title', "release: $($i.Label) $($i.Version)", '--body-file', $file)
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

        $subject = "release: $($i.Label) $($i.Version) (#$($i.Pr))"
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
    Write-Info 'Confirma estos cambios en una rama de la plataforma (solo estos archivos):'
    Write-Info "  git switch -c chore/componentes-$((Get-Date).ToString('yyyyMMdd'))"
    Write-Info "  git add $($paths -join ' ')"
    Write-Info "  git commit -m `"chore(platform): fijar componentes en $($tags -join ', ')`""
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

# --- Comandos comunes ---------------------------------------------------------

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

function Invoke-Status {
    foreach ($key in $Repos) {
        $repo = Get-RepoName $key
        Write-Step "$($Components[$key].Label) ($repo)"
        if (-not (Test-Branch $repo 'main')) { Write-Bad 'no existe main (ejecuta prepare)'; continue }
        $diff = Get-Ahead $repo
        Write-Info "develop tiene $($diff.ahead) commit(s) que main no tiene; main tiene $($diff.behind) que develop no tiene"
        $open = @(Invoke-GhJson @('pr', 'list', '--repo', $repo, '--base', 'main', '--head', 'develop', '--state', 'open', '--json', 'number,url') | Where-Object { $_ })
        if ($open.Count) { Write-Info "PR abierto: #$($open[0].number) $($open[0].url)" }
        $latest = Invoke-GhJson @('release', 'list', '--repo', $repo, '--limit', '1', '--json', 'tagName,publishedAt') -AllowFailure
        if (@($latest).Count -and @($latest)[0]) { Write-Ok "última release: $(@($latest)[0].tagName) ($(@($latest)[0].publishedAt))" } else { Write-Info 'sin releases' }
    }
}

# Fases 1 a 5 para los repositorios de $Repos. Devuelve los ítems, o $null si
# no hay nada que publicar.
function Invoke-ReleasePhases([string]$System) {
    if (-not (Get-Login)) { throw 'gh no tiene sesión: gh auth login' }
    $items = New-ReleaseItems
    Show-Plan $items $System
    if (-not @($items | Where-Object { $_.State -eq 'pendiente' }).Count) { Write-Note 'No hay nada que publicar.'; return $null }
    Confirm-Step '¿Crear los PR con estas versiones?'
    Open-PullRequests $items $System
    Wait-Checks $items
    Approve-AndMerge $items
    New-Releases $items $System
    Wait-ReleaseWorkflows $items
    , $items
}

function Show-Summary($Items) {
    Write-Step 'Resumen'
    foreach ($i in $Items) { Write-Info ("{0,-13} {1,-9} {2}  {3}" -f $i.Label, $i.Version, $i.State, $i.Detail) }
}

# Bloque de entrada común: $Handlers asocia cada comando con su función.
function Invoke-Main([hashtable]$Handlers) {
    $previousEncoding = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { $previousEncoding = $null }
    try {
        if ($Command -eq 'help') { Get-Help $script:MyScriptPath -Detailed | Out-Host; return }
        $script:Cfg = Read-Config
        & $Handlers[$Command]
    } catch {
        Write-Host ''
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    } finally {
        Remove-Item Env:SPORTAPP_SIGNING_STORE_PASSWORD, Env:SPORTAPP_SIGNING_KEY_PASSWORD -ErrorAction SilentlyContinue
        if ($previousEncoding) { try { [Console]::OutputEncoding = $previousEncoding } catch { } }
    }
}
