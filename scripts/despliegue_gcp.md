# Manual de despliegue en GCP (con Strava)

Todo se hace desde el menú principal: `.\scripts\sportapp.ps1`.

## 1. Crear la aplicación de Strava de producción

Escribe `1`, luego `2` (GCP) y el paso `1`. Al terminar, escribe `s`.

## 2. Cargar los secretos

Escribe `1`, luego `2` (GCP) y el paso `2`. Al terminar, escribe `s`.

## 3. Encender producción

Escribe `3`, luego `2` (GCP) y luego `4` (up).

## 4. Copiar el Secret a GKE

Escribe `1`, luego `2` (GCP) y el paso `3`. Al terminar, escribe `s`.

## 5. Promover backend y frontend

Antes, en la terminal: `git switch main; git pull --ff-only`.

Después escribe `3`, luego `2` (GCP) y luego `5` (promote).

## 6. Verificar

Escribe `3`, luego `2` (GCP) y luego `2` (status).
