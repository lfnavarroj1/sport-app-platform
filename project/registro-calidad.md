# Registro de calidad

Este registro conserva la evidencia que se enlaza desde el tablero y la wiki.

## Línea base disponible

| Fecha | Repositorio | Revisión | Entorno | Unitarias | Integración | Contrato | Componente/E2E | Total | Cobertura | Seguridad | Resultado | Evidencia |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |
| 2026-10-08 | Backend | `f4ff77f` + árbol sin commit | Local | 117 | 26 | 12 | 2 | 157 | 96 % | Bandit y pip-audit sin hallazgos bloqueantes; Gitleaks sin fugas | Aprobado localmente | `backend/docs/retorno-documental-backend.md` |

## Mediciones de sprint

| Fecha | Sprint | Repositorio | Commit | Ejecución CI | Pruebas aprobadas/total | Cobertura sentencias | Cobertura ramas | Vulnerabilidades bloqueantes | Defectos abiertos | Artefacto | Resultado |
| --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| 2026-10-09 | Sprint 1 | Backend | `d13587d` (merge simulado con `develop`: `aaac9cf`) | [PR #1, ejecución 38017064718](https://github.com/lfnavarroj1/sport-app-backend/actions/runs/38017064718) | 157/157 (117 unitarias, 26 integración, 12 contrato, 2 componente) | 96,9 % | 89,2 % | 0 | `N/D` | 8 imágenes construidas sin publicar; `coverage.xml` como artefacto (expira 2026-11-09) | Aprobado en CI; HU001 sigue abierta al 50 % |

Cada fila debe corresponder a una revisión inmutable. No combine cobertura de commits distintos ni copie un porcentaje sin conservar el reporte que lo produjo.

## Gráfico de cobertura disponible

La barra representa la cobertura backend verificada localmente y la línea el umbral configurado de 80 %.

```mermaid
xychart-beta
    title "Cobertura backend"
    x-axis ["Backend"]
    y-axis "Cobertura (%)" 0 --> 100
    bar [96]
    line [80]
```

Web y móvil se agregan solamente cuando exista un reporte reproducible asociado a una revisión.
