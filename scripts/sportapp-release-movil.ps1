<#
.SYNOPSIS
    Publica la release de la aplicación móvil: PR develop -> main, pruebas,
    aprobación, merge, release en GitHub y APK de producción firmado.

.DESCRIPTION
    Va aparte de sportapp-release.ps1 porque el móvil no participa en el
    despliegue: no tiene imagen, Cloud Build ni Cloud Deploy. Se ejecuta desde la
    estación del operador con gh; solo usa gcloud para leer el número del proyecto
    de producción (URL de bff-mobile) si no se define $mobileBffBaseUrl.

      check       Valida gh, ramas, Java, Android SDK, almacén de claves y URL.
      status      Cambios pendientes de develop, PR abierto y última release.
      prepare     Una sola vez: renombra master a main.
      keystore    Una sola vez: crea el almacén de claves del APK (fuera del repo).
      release     PR develop -> main, pruebas, aprobación, merge, release vX.Y.Z,
                  workflow release-mobile, APK firmado adjunto a la release y
                  submódulo components/mobile en el tag.
      apk         Solo compila, firma y adjunta el APK de una release existente.
      submodules  Mueve components/mobile al tag y actualiza release-manifest.yaml.

    Instrucciones: scripts/sportapp-release-movil.md.

.EXAMPLE
    .\scripts\sportapp-release-movil.ps1 release

.EXAMPLE
    .\scripts\sportapp-release-movil.ps1 apk -MobileVersion v0.2.0
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'check', 'status', 'prepare', 'keystore', 'release', 'apk', 'submodules')]
    [string]$Command = 'help',

    # Incremento propuesto desde el último tag.
    [ValidateSet('patch', 'minor', 'major')]
    [string]$Bump = 'minor',

    # Versión explícita (vX.Y.Z); reemplaza la propuesta.
    [string]$MobileVersion,

    # Versión de plataforma (sistema) del APK; por defecto platformVersion de
    # release-manifest.yaml.
    [string]$SystemVersion,

    # release: no compila el APK al final (se puede hacer después con apk).
    [switch]$SkipApk,

    # release: no mueve components/mobile ni release-manifest.yaml.
    [switch]$SkipPlatform,

    # Omite las confirmaciones de rutina. La aprobación del PR siempre se pregunta.
    [switch]$AutoApprove,

    [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'

$PlatformRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigFile) { $ConfigFile = Join-Path $PlatformRoot '.env.ps1' }
elseif (Test-Path -LiteralPath $ConfigFile) { $ConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path }
$script:MyScriptPath = $PSCommandPath
$ReleaseScriptName = 'sportapp-release-movil.ps1'
$Repos = @('mobile')
$BackendVersion = $null
$FrontendVersion = $null

. (Join-Path $PSScriptRoot 'sportapp-release-common.ps1')

# --- APK de producción --------------------------------------------------------

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
    if (-not (Test-Path -LiteralPath $script:Cfg.mobileKeystoreFile)) { throw "No existe el almacén de claves $($script:Cfg.mobileKeystoreFile): ejecuta .\scripts\sportapp-release-movil.ps1 keystore" }
    $release = Invoke-GhJson @('release', 'view', $Tag, '--repo', $repo, '--json', 'tagName,url') -AllowFailure
    if (-not $release) { throw "No existe la release $Tag en $repo." }
    $sdk = Get-AndroidSdk
    if (-not $sdk) { throw 'No se encontró el Android SDK (ANDROID_HOME o local.properties).' }
    $java = Get-Java
    if (-not $java) { throw 'Se requiere Java 17 o superior para iniciar Gradle.' }
    $apksigner = Get-BuildTool $sdk 'apksigner'
    $aapt2 = Get-BuildTool $sdk 'aapt2'
    $bff = Get-BffUrl
    $code = Get-VersionCode $Tag
    $version = $Tag.Substring(1)
    Write-Info "bff-mobile: $bff"
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
                "-Psportapp.versionName=$version", "-Psportapp.versionCode=$code", "-Psportapp.systemVersion=$System", "-Psportapp.bffMobileBaseUrl.release=$bff")
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
            "bffMobileBaseUrl=$bff", "signingCertificateSha256=$certificate", "builtBy=scripts/sportapp-release-movil.ps1"
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
    $keytool = Join-Path (Split-Path -Parent $java) 'keytool.exe'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
    Write-Step "Almacén de claves de firma: $file (alias $($script:Cfg.mobileKeyAlias))"
    Write-Info 'keytool pedirá la contraseña y los datos del certificado. Guarda una copia del archivo y de la'
    Write-Info 'contraseña en un lugar seguro: sin ellos no se pueden publicar actualizaciones de la app.'
    & $keytool -genkeypair -v -keystore $file -storetype PKCS12 -alias $script:Cfg.mobileKeyAlias -keyalg RSA -keysize 4096 -validity 10000
    if ($LASTEXITCODE -ne 0) { throw 'keytool no creó el almacén de claves.' }
    Write-Ok 'almacén de claves creado (fuera del repositorio)'
}

function Invoke-Check {
    $ok = Test-GitHubAccess
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
    else { Write-Bad "no existe el almacén de claves $($script:Cfg.mobileKeystoreFile): .\scripts\sportapp-release-movil.ps1 keystore"; $ok = $false }
    try { Write-Ok "bff-mobile de producción: $(Get-BffUrl)" } catch { Write-Bad $_.Exception.Message; $ok = $false }
    Write-Ok "versión del sistema: $(Get-SystemVersion)"
    Write-Host ''
    if ($ok) { Write-Host 'Todo listo. Siguiente: .\scripts\sportapp-release-movil.ps1 release' -ForegroundColor Green }
    else { throw 'Hay pendientes (marcados con [falta]).' }
}

function Invoke-Prepare {
    if (-not (Get-Login)) { throw 'gh no tiene sesión: gh auth login' }
    $mobile = Get-RepoName 'mobile'
    Write-Step "Rama main en $mobile"
    if (Test-Branch $mobile 'main') { Write-Ok 'ya existe'; return }
    if (-not (Test-Branch $mobile 'master')) { Write-Bad 'no existen main ni master; créala a mano'; return }
    Write-Info 'Se renombra master a main: GitHub conserva los PR, redirige la rama y actualiza la rama por defecto.'
    Confirm-Step "¿Renombrar master a main en $mobile?"
    [void](Invoke-Capture gh @('api', '-X', 'POST', "repos/$mobile/branches/master/rename", '-f', 'new_name=main'))
    if (Test-Path -LiteralPath (Join-Path $script:Cfg.mobileRepoPath '.git')) { [void](Invoke-Capture git @('-C', $script:Cfg.mobileRepoPath, 'fetch', '--prune', 'origin') -AllowFailure) }
    Write-Ok 'master renombrada a main'
    Write-Note 'Protege main como en el backend (Settings -> Rules: PR obligatorio y 1 aprobación).'
}

function Invoke-Release {
    if (-not $SkipApk -and -not (Test-Path -LiteralPath $script:Cfg.mobileKeystoreFile)) {
        throw "Falta el almacén de claves del APK ($($script:Cfg.mobileKeystoreFile)): ejecuta keystore o usa -SkipApk."
    }
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

Invoke-Main @{
    check      = { Invoke-Check }
    status     = { Invoke-Status }
    prepare    = { Invoke-Prepare }
    keystore   = { Invoke-Keystore }
    release    = { Invoke-Release }
    apk        = { Invoke-ApkCommand }
    submodules = { Invoke-SubmodulesCommand }
}
