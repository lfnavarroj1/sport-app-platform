# Configuración de SportApp en GCP para scripts/sportapp-gcp.ps1.
#
#   Copy-Item .env.example.ps1 .env.ps1      (desde la carpeta platform)
#   .\scripts\sportapp-gcp.ps1 check         (dice qué falta o qué está mal)
#
# .env.ps1 está ignorado por Git. Solo identificadores y decisiones: nunca
# tokens, contraseñas, llaves JSON ni el contenido de una clave privada.

# --- Obligatorias -------------------------------------------------------------

# Cuenta de facturación (gcloud billing accounts list).
$billing = "XXXXXX-XXXXXX-XXXXXX"

# ID globalmente único del proyecto de gestión: estado Terraform, Cloud Build,
# Cloud Deploy y cuentas de servicio de entrega.
$mgmt = "sportapp-mgmt-1234"

# ID globalmente único del proyecto de producción: GKE, Cloud SQL, Cloud Run.
$production = "sportapp-prod-1234"

# Región; debe coincidir con environments/production/terraform.tfvars.
$region = "us-central1"

# Persona que ejecuta Terraform (cuenta activa de gcloud).
$operator = "usuario@dominio.com"

# Presupuesto mensual y moneda de la cuenta de facturación (USD, COP...).
$budgetAmount = 1000
$budgetCurrency = "USD"

# Versión vigente del consentimiento de datos de salud (ADR-034).
$healthDataConsentVersion = "<versión aprobada>"

# Imagen por digest con gcloud, kubectl y gke-gcloud-auth-plugin
# (docs/preparacion-terraform-gcp.md, sección 9.1, paso 5).
$deployToolsImage = "gcr.io/google.com/cloudsdktool/google-cloud-cli:588.0.0@sha256:<64 hex>"

# --- Opcionales ---------------------------------------------------------------

# Avisos del presupuesto en montos absolutos (vacío = 50 %, 90 % y 100 %).
# $budgetAlertAmounts = @(50, 100, 250, 500)

# Clave Ed25519 de users-management, guardada fuera del repositorio. Solo se
# usa si el secreto users-jwt-private-key todavía no tiene versión.
# $jwtPrivateKeyFile = "C:\ruta-segura\sportapp-users-jwt.pem"

# Por defecto user:$operator / $operator.
# $approvers = @("user:aprobador@dominio.com")
# $alertEmails = @("equipo@dominio.com")
# $operators = @("user:usuario@dominio.com")

# $true cuando backend y frontend tengan cloudbuild.release.yaml en main.
# $releaseTriggersEnabled = $true

# Release con la que se crea Cloud Run la primera vez (por defecto la más reciente).
# $initialBackendVersion = "v1.0.0"
# $initialFrontendVersion = "v1.0.0"

# --- Releases (scripts/sportapp-release.ps1 y sportapp-release-movil.ps1) ----

# Dueño de los repositorios en GitHub (por defecto lfnavarroj1).
# $githubOwner = "lfnavarroj1"

# Cuenta de GitHub de un compañero que aprueba los PR. Debe tener sesión en gh en
# esta estación (gh auth login). Alternativa: la variable de entorno
# SPORTAPP_REVIEWER_TOKEN. Sin ninguna, el script fusiona con --admin.
# $releaseReviewer = "companero-github"

# Almacén de claves del APK de producción, fuera del repositorio. Lo crea
# ".\scripts\sportapp-release-movil.ps1 keystore". Las contraseñas se piden al compilar.
# $mobileKeystoreFile = "$env:USERPROFILE\.sportapp\sportapp-release.jks"
# $mobileKeyAlias = "sportapp"

# Clones locales (por defecto ..\movil y ..\frontend junto a platform).
# $mobileRepoPath = "..\movil"
# $frontendRepoPath = "..\frontend"

# URL de bff-mobile para el APK (por defecto la de Cloud Run de $production).
# $mobileBffBaseUrl = "https://bff-mobile-<número>.us-central1.run.app/"
