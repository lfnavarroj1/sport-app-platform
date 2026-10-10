# Arquitectura Terraform de SportApp

## Decisión

Terraform se centraliza en `sport-app-platform`, bajo `infra/terraform/`. No vive dentro de backend, frontend ni móvil porque administra capacidades compartidas: ambientes, red, identidades, registro de artefactos, ejecución, datos, mensajería, secretos y observabilidad.

Esta decisión no convierte la plataforma en un monorepositorio con una sola versión. Cada componente conserva su repositorio, historial y release; la plataforma consume artefactos inmutables y declara qué combinación despliega.

## Dónde clonarlo y qué descarga

Se recomienda clonar la plataforma como una carpeta hermana de los repositorios actuales:

```text
aplicacion_proyecto_final/
├── backend/
├── frontend/
├── movil/
├── documentacion/
└── platform/          # sport-app-platform
```

Para comenzar solo con Terraform, documentación o automatización:

```text
cd "D:\04 - Mestría en Ingeniería de Software\08 - Ciclo 8\Proyecto final II\aplicacion_proyecto_final"
git clone https://github.com/lfnavarroj1/sport-app-platform.git platform
cd platform
```

El clonado normal trae únicamente el repositorio de plataforma. Registra los punteros de `components/backend`, `components/frontend` y `components/mobile`, pero no descarga su contenido. Para traer también los tres repositorios:

```text
git clone --recurse-submodules https://github.com/lfnavarroj1/sport-app-platform.git platform
```

Si la plataforma ya está clonada:

```text
git submodule update --init --recursive
```

Los submódulos son árboles adicionales fijados a versiones de integración; no reemplazan las carpetas `backend`, `frontend` y `movil` donde se desarrolla cada producto.

## Distribución de responsabilidades

| Repositorio | Conserva | No debe administrar |
| --- | --- | --- |
| `sport-app-backend` | código, dependencias, `Dockerfile`, migraciones, pruebas y manifiestos estrictamente internos | estado Terraform, red, GCP compartido o despliegue web |
| `sport-app-frontend` | código Angular, pruebas, empaquetado y `Dockerfile` si aplica | estado Terraform o infraestructura del backend |
| `sport-app-movil` | código Android, pruebas, APK/AAB y metadatos de versión | infraestructura compartida o despliegues de servidor |
| `sport-app-platform` | Terraform, composición local, Kubernetes compartido, ambientes, manifiesto de release y promoción | código funcional interno de cada componente |

```mermaid
flowchart TB
    P["sport-app-platform<br/>Terraform y release"]
    B["Backend<br/>imagen OCI y migraciones"]
    W["Frontend<br/>imagen o paquete web"]
    M["Móvil<br/>APK o AAB"]
    L["Ambiente local<br/>desechable"]
    G["Ambientes GCP<br/>dev, staging y producción"]

    B -. digest .-> P
    W -. digest o checksum .-> P
    M -. versión y checksum .-> P
    P --> L
    P --> G
```

## Estructura objetivo

```text
sport-app-platform/
├── infra/
│   ├── terraform/
│   │   ├── bootstrap/gcp-state/
│   │   ├── modules/
│   │   │   ├── common/
│   │   │   ├── local/
│   │   │   └── gcp/
│   │   └── environments/
│   │       ├── local/
│   │       ├── development/
│   │       ├── staging/
│   │       └── production/
│   ├── kubernetes/
│   │   ├── base/
│   │   └── overlays/
│   └── policies/
├── orchestration/local/
└── release-manifest.yaml
```

Cada carpeta de `environments/` es una raíz independiente. Los ambientes no se separan mediante workspaces de una única raíz; esto permite aislar estado, variables, identidad y aprobaciones.

## Pruebas en local

El perfil local valida la integración sin conectarse a GCP. Terraform compone un Kubernetes local desechable —por ejemplo Docker Desktop— con frontend, BFF, microservicios, PostgreSQL y emulador de Pub/Sub.

```mermaid
flowchart LR
    DEV[Desarrollador o CI] --> TF[Terraform local]
    subgraph K8S[Kubernetes local]
      WEB[Frontend]
      BFF[BFF]
      API[Microservicios]
      DB[(PostgreSQL)]
      PS[Emulador Pub/Sub]
    end
    TF --> WEB
    TF --> BFF
    TF --> API
    TF --> DB
    TF --> PS
    WEB --> BFF --> API --> DB
    API <--> PS
```

El estado local es desechable y se excluye de Git. Este ambiente prueba composición, conectividad, migraciones, outbox, eventos y flujos E2E; no pretende reproducir IAM, cuotas, alta disponibilidad ni comportamiento regional de GCP.

## Arquitectura en GCP

```mermaid
flowchart TB
    GH[GitHub Actions mediante OIDC/WIF]
    TF[Terraform del ambiente]
    STATE[(Estado GCS separado<br/>proyecto de gestión)]

    subgraph GCP[Proyecto GCP del ambiente]
      NET[VPC]
      AR[Artifact Registry]
      RUN[Cloud Run]
      GKE[GKE]
      SQL[(Cloud SQL)]
      PS[Pub/Sub]
      SM[Secret Manager]
      OBS[Logging y Monitoring]
    end

    GH --> TF
    TF <--> STATE
    TF --> NET
    TF --> AR
    TF --> RUN
    TF --> GKE
    TF --> SQL
    TF --> PS
    TF --> SM
    TF --> OBS
    AR -. imágenes por digest .-> RUN
    AR -. imágenes por digest .-> GKE
```

| Raíz | Estado | Forma de aplicación |
| --- | --- | --- |
| `local` | local, ignorado por Git | desarrollador o CI desechable |
| `development` | GCS exclusivo | aprobación técnica |
| `staging` | GCS exclusivo | ambiente protegido y ensayo de release |
| `production` | GCS exclusivo, protección reforzada | aprobación independiente sobre plan revisado |

El bootstrap crea los buckets de estado, versionado, bloqueo y permisos mínimos. Terraform crea recursos y referencias a secretos, pero no guarda valores secretos. Las imágenes se despliegan por digest tomado de `release-manifest.yaml`.

## Validación y promoción

```mermaid
flowchart LR
    PR[Pull request] --> FMT[fmt y validate]
    FMT --> TEST[terraform test y análisis]
    TEST --> PLAN[plan]
    PLAN --> REVIEW[revisión]
    REVIEW --> APPLY[apply autorizado]
    APPLY --> SMOKE[smoke y evidencia]
```

- En ramas se ejecutan controles sin credenciales privilegiadas.
- En pull requests se genera un plan seguro; nunca se ejecuta `apply` desde código no confiable.
- `development`, `staging` y `production` usan identidades y estados diferentes.
- Si cambia el commit o el estado después de revisar el plan, se genera y aprueba uno nuevo.
- Las pruebas que crean recursos deben usar destinos efímeros y ejecutar limpieza incluso ante fallos.

## Encendido, apagado y control de costos

«Apagar» tiene dos modos operativos:

| Modo | Cuándo usarlo | Qué ocurre |
| --- | --- | --- |
| `suspend` | pausa corta | Cloud Run usa mínimo `0`, GKE reduce nodos y Cloud SQL se detiene; pueden continuar cobros de almacenamiento, IP, balanceadores, control plane, imágenes y logs |
| `destroy` | ambiente no productivo recreable | se revisa `terraform plan -destroy` y se eliminan los recursos administrados por la raíz del ambiente |

`development` se crea bajo demanda y se destruye al terminar la ventana de trabajo. `staging` se destruye después del ensayo y de conservar la evidencia necesaria. Producción nunca se incluye en una destrucción programada.

El estado Terraform y la automatización se conservan en un proyecto de gestión separado de las cargas desechables. Así se puede reconstruir un ambiente después de destruirlo. Las copias, imágenes o datos que se decida conservar pueden seguir generando costos.

Secuencia segura para un ambiente desechable:

```text
terraform plan -destroy -out=tfplan-destroy
terraform show tfplan-destroy
terraform apply tfplan-destroy
```

La deshabilitación de facturación se reserva para una emergencia: Google detiene los servicios y algunos recursos podrían eliminarse o no recuperarse. Tampoco se asume que una alerta de presupuesto limita el gasto; se configurarán presupuestos, límites cuando estén disponibles, fechas de caducidad, cuotas, máximos de escalamiento y limpieza de artefactos.

## Estado de implementación

La decisión y la arquitectura están aprobadas. La creación de los módulos, raíces, bootstrap y workflows todavía está pendiente; por tanto, los diagramas describen el destino verificable y no un despliegue GCP ya operativo.

## Referencias

- [Google Cloud: prácticas recomendadas para módulos raíz](https://docs.cloud.google.com/docs/terraform/best-practices/root-modules)
- [HashiCorp: backend GCS](https://developer.hashicorp.com/terraform/language/backend/gcs)
- [HashiCorp: comando `terraform test`](https://developer.hashicorp.com/terraform/cli/commands/test)
- [Google Cloud: presupuestos y alertas](https://docs.cloud.google.com/billing/docs/how-to/budgets)
- [Google Cloud: deshabilitar facturación](https://docs.cloud.google.com/billing/docs/how-to/modify-project)
- [Cloud SQL: iniciar y detener instancias](https://docs.cloud.google.com/sql/docs/postgres/start-stop-restart-instance)
- [HashiCorp: `terraform destroy`](https://developer.hashicorp.com/terraform/cli/commands/destroy)
