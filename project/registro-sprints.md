# Registro de sprints

## Línea base histórica importada

Datos verificados el 9 de octubre de 2026 en el [Project 2 de SportApp-G9](https://github.com/users/lfnavarroj1/projects/2). La asignación y el estado `Done` pertenecen al ciclo de 2024; no representan el cierre de la reimplementación actual.

| Sprint | Inicio histórico | Duración | HU asignadas | PHU de HU | Estado en Project 2 |
| --- | --- | ---: | ---: | ---: | --- |
| Sprint 1 | 2024-04-01 | 14 días | 8 | 20 | 8 `Done` |
| Sprint 2 | 2024-04-15 | 14 días | 10 | 25 | 10 `Done` |
| Sprint 3 | 2024-04-29 | 21 días | 15 | 36 | 15 `Done` |
| Sin asignar | — | — | 7 | 19 | Ausentes del Project 2 |
| **Total** | — | **49 días** | **40** | **100** | **33 históricas; 7 sin asignar** |

La relación detallada de HU por sprint está en [Planeación y sprints](https://github.com/lfnavarroj1/sport-app-platform/wiki/02-planeacion-y-sprints#historias-por-sprint).

## Cierres

Esta tabla pertenece al ciclo actual. Se completa exclusivamente con aceptación y evidencia de la reimplementación.

| Sprint | Objetivo | Inicio | Fin | Capacidad PHU | PHU comprometidos | PHU aceptados | HU aceptadas | Valor entregado | Predictibilidad | Evidencia |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Sprint 1 | Pendiente | `N/D` | `N/D` | 28 | `N/D` | `N/D` | `N/D` | `N/D` | `N/D` | — |
| Sprint 2 | Pendiente | `N/D` | `N/D` | 28 | `N/D` | `N/D` | `N/D` | `N/D` | `N/D` | — |
| Sprint 3 | Pendiente | `N/D` | `N/D` | 42 | `N/D` | `N/D` | `N/D` | `N/D` | `N/D` | — |

## Cómo cerrar una fila

1. Congele la lista de HU comprometidas al terminar la planeación.
2. Registre por separado cualquier cambio de alcance.
3. Cuente solo HU aceptadas.
4. Calcule `Predictibilidad = PHU aceptados / PHU comprometidos`.
5. Enlace la revisión del sprint y las ejecuciones de CI.

La capacidad 28/28/42 es histórica y debe recalibrarse después de obtener velocidad real.

## Gráfico de capacidad planificada

```mermaid
xychart-beta
    title "Capacidad histórica por sprint"
    x-axis ["Sprint 1", "Sprint 2", "Sprint 3"]
    y-axis "PHU" 0 --> 45
    bar [28, 28, 42]
```

Al cerrar el Sprint 1 se agrega una serie de PHU aceptados para convertirlo en un velocity chart planificado frente a real.

## Gráfico de la asignación histórica

```mermaid
xychart-beta
    title "PHU de HU en Project 2"
    x-axis ["Sprint 1", "Sprint 2", "Sprint 3", "Sin asignar"]
    y-axis "PHU" 0 --> 40
    bar [20, 25, 36, 19]
```
