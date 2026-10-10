# Guía de clonado seguro de `sport-app-platform`

## Objetivo

Clonar y trabajar en Terraform, documentación u orquestación de `sport-app-platform` sin descargar, modificar ni publicar accidentalmente backend, frontend o móvil.

La plataforma registra esos repositorios como submódulos fijados a commits. Sus punteros forman parte de la composición, pero sus árboles de trabajo permanecen desactivados salvo durante una integración autorizada.

## Ubicación recomendada

Clone la plataforma como carpeta hermana de los proyectos actuales:

```text
aplicacion_proyecto_final/
├── backend/
├── frontend/
├── movil/
├── documentacion/
└── platform/
```

No la clone dentro de `backend`, `frontend`, `movil` o `documentacion`.

## Clonado para Terraform y plataforma

Ejecute en PowerShell:

```powershell
cd "D:\04 - Mestría en Ingeniería de Software\08 - Ciclo 8\Proyecto final II\aplicacion_proyecto_final"

git clone --no-recurse-submodules https://github.com/lfnavarroj1/sport-app-platform.git platform
cd platform

git config --local submodule.recurse false
git config --local fetch.recurseSubmodules false
git config --local push.recurseSubmodules no

git submodule status
```

Resultado esperado: las líneas de backend, frontend y móvil comienzan con `-`.

```text
-<commit> components/backend
-<commit> components/frontend
-<commit> components/mobile
```

El prefijo `-` significa que el puntero está registrado, pero el repositorio correspondiente no fue inicializado ni descargado.

## Protección incluida en el repositorio

Cada entrada de `.gitmodules` contiene:

```ini
update = none
fetchRecurseSubmodules = false
```

Por ello, incluso una actualización recursiva genérica omite los componentes. Solo `--checkout` autoriza explícitamente su inicialización.

## Trabajo diario seguro

Actualizar la plataforma sin traer componentes:

```powershell
git switch main
git pull --no-recurse-submodules origin main
git submodule status
```

Crear una rama para Terraform:

```powershell
git switch -c feature/HUxxx-terraform
```

Agregar únicamente los archivos de plataforma modificados:

```powershell
git add infra/terraform
git status --short
git diff --cached --submodule=log
```

Antes del commit, `git diff --cached --submodule=log` no debe mostrar cambios en `components/backend`, `components/frontend` o `components/mobile`.

Publicar solamente la rama de plataforma:

```powershell
git commit -m "feat(infra): describir cambio Terraform"
git push --no-recurse-submodules -u origin feature/HUxxx-terraform
```

## Comandos prohibidos en el trabajo ordinario

No use estos comandos para desarrollar Terraform o documentación:

```text
git clone --recurse-submodules ...
git submodule update --init --recursive
git push --recurse-submodules=on-demand ...
git add components
```

Tampoco desarrolle una HU dentro de `platform/components/*`. Las funcionalidades se implementan y publican primero en su repositorio propietario.

## Inicialización autorizada para integración

Solo una prueba de integración/E2E o un proceso de release puede descargar los componentes:

```powershell
git submodule sync --recursive
git submodule update --init --checkout components/backend components/frontend components/mobile
```

`--checkout` reemplaza de manera explícita la protección `update = none`. El acceso del pipeline debe ser de solo lectura.

Después de validar una integración, un cambio de puntero se publica únicamente mediante un PR de release que actualice también `release-manifest.yaml` con versión, commit y digest/checksum.

## Qué ocurre si cambia un componente remoto

Una actualización en `sport-app-backend`, `sport-app-frontend` o `sport-app-movil` no modifica automáticamente la plataforma. `sport-app-platform` conserva el commit que ya tenía fijado hasta que un PR de release cambie deliberadamente ese puntero.

Por tanto:

- un push de plataforma no sobrescribe el historial de un componente;
- un push de un componente no actualiza la plataforma;
- no existen fusiones automáticas entre los cuatro historiales;
- la combinación compatible solo cambia mediante revisión del manifiesto y los punteros.

## Lista de comprobación

- [ ] La carpeta `platform` es hermana de los demás repositorios.
- [ ] El clon utilizó `--no-recurse-submodules`.
- [ ] `git submodule status` muestra `-` en las tres líneas.
- [ ] La configuración local deshabilita recursión para submódulos.
- [ ] La rama corresponde a una HU o tarea de plataforma.
- [ ] El área preparada no contiene cambios bajo `components/`.
- [ ] El push utiliza `--no-recurse-submodules`.
- [ ] Todo cambio de puntero tiene PR y actualización del manifiesto.
