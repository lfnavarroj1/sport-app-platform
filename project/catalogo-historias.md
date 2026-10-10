# Catálogo de historias para seguimiento

## Convenciones

- `Valor`: ponderación relativa de negocio; el backlog completo suma 100 puntos. No representa esfuerzo y solo se reconoce cuando la HU es aceptada.
- `Sprint vigente`: asignación operativa del Project 4. Partió de la referencia de 2024, pero registra los cambios reales del ciclo actual; HU001 pasó a Sprint 1 el 2026-10-09.
- `Estado`: uno de los estados definidos en la [guía](../docs/guia-de-actualizacion.md#estados-permitidos).
- `Aceptada`: fecha de aceptación; es la fecha que permite sumar PHU y valor.

El estado `Done` del Project 2 es evidencia histórica y no reemplaza el estado verificable de la reimplementación actual. Las 40 HU se crearon de nuevo en el Project 4; siete permanecen `Sin asignar` hasta que el responsable de producto defina su sprint. La definición funcional se conserva también en `documentacion/arquitectura/historias/catalogo-historias.md`.

HU003 incluye inicio de sesión web y móvil como una sola capacidad de negocio. Sus PHU y su valor no se duplican por canal.

| HU | Nombre | Dominio | Canal | PHU | Valor | Sprint vigente | Estado al 2026-10-10 | Aceptada | Evidencia |
| --- | --- | --- | --- | ---: | ---: | --- | --- | --- | --- |
| HU001 | Registrar usuario | Usuarios | Web | 5 | 5 | Sprint 1 | En curso (50 %): backend/BFF verificados; web y E2E pendientes | — | [Issue #1](https://github.com/lfnavarroj1/sport-app-platform/issues/1), [PR backend #1](https://github.com/lfnavarroj1/sport-app-backend/pull/1) |
| HU002 | Editar información del usuario | Usuarios | Web | 3 | 1 | `N/D` | No iniciada | — | — |
| HU003 | Iniciar sesión | Usuarios | Web y móvil | 2 | 5 | Sprint 1 | No iniciada | — | — |
| HU004 | Cerrar sesión | Usuarios | Web | 2 | 1 | Sprint 3 | No iniciada | — | — |
| HU005 | Registrar datos demográficos y fisiológicos | Usuarios | Web | 2 | 3 | Sprint 2 | No iniciada | — | — |
| HU006 | Registrar hábitos deportivos | Usuarios | Web | 2 | 3 | Sprint 2 | No iniciada | — | — |
| HU007 | Consultar estado de cuenta | Afiliación | Web | 5 | 3 | `N/D` | No iniciada | — | — |
| HU008 | Actualizar hábitos deportivos | Usuarios | Web | 2 | 2 | `N/D` | No iniciada | — | — |
| HU009 | Registrar hábitos alimenticios | Usuarios | Web | 2 | 2 | Sprint 3 | No iniciada | — | — |
| HU010 | Crear plan de entrenamiento | Entrenamientos | Web | 5 | 5 | Sprint 1 | No iniciada | — | — |
| HU011 | Ver historial de entrenamiento | Entrenamientos | Web | 2 | 2 | Sprint 1 | No iniciada | — | — |
| HU012 | Ver historial de molestias o lesiones | Entrenamientos | Web | 2 | 2 | `N/D` | No iniciada | — | — |
| HU013 | Ver historial de alimentación | Entrenamientos | Web | 2 | 2 | `N/D` | No iniciada | — | — |
| HU014 | Crear plan de alimentación | Entrenamientos | Web | 3 | 4 | Sprint 2 | No iniciada | — | — |
| HU015 | Crear servicio | Servicios | Web | 3 | 4 | Sprint 2 | No iniciada | — | — |
| HU016 | Seleccionar plan de afiliación | Afiliación | Web | 2 | 4 | Sprint 2 | No iniciada | — | — |
| HU017 | Asociar servicios médicos deportivos | Servicios | Web | 2 | 3 | Sprint 3 | No iniciada | — | — |
| HU018 | Integrar servicios y eventos en calendario | Eventos | Web | 3 | 3 | Sprint 3 | No iniciada | — | — |
| HU019 | Publicar servicios | Servicios | Web | 2 | 3 | Sprint 2 | No iniciada | — | — |
| HU020 | Visualizar disponibilidad | Servicios | Web | 2 | 3 | Sprint 1 | No iniciada | — | — |
| HU021 | Crear evento masivo | Eventos | Web | 3 | 4 | Sprint 1 | No iniciada | — | — |
| HU022 | Consultar inscritos | Eventos | Web | 2 | 2 | Sprint 3 | No iniciada | — | — |
| HU023 | Consultar calendario de eventos | Eventos | Web | 2 | 3 | Sprint 1 | No iniciada | — | — |
| HU024 | Publicar evento | Eventos | Web | 2 | 3 | Sprint 2 | No iniciada | — | — |
| HU025 | Asignar tarifa | Eventos | Web | 2 | 2 | Sprint 3 | No iniciada | — | — |
| HU026 | Sugerir rutas | Entrenamientos | Móvil | 2 | 2 | Sprint 3 | No iniciada | — | — |
| HU027 | Sugerir eventos | Eventos | Móvil | 2 | 2 | Sprint 3 | No iniciada | — | — |
| HU028 | Sugerir planes de entrenamiento | Entrenamientos | Móvil | 2 | 3 | Sprint 2 | No iniciada | — | — |
| HU029 | Sugerir servicios de acompañamiento | Servicios | Móvil | 2 | 2 | Sprint 3 | No iniciada | — | — |
| HU030 | Sugerir rutinas alimenticias | Entrenamientos | Móvil | 2 | 2 | `N/D` | No iniciada | — | — |
| HU031 | Integrar SportApp con Strava | Terceros | Móvil | 3 | 3 | Sprint 3 | No iniciada | — | — |
| HU032 | Iniciar o finalizar entrenamiento | Entrenamientos | Móvil | 2 | 3 | Sprint 1 | No iniciada | — | — |
| HU033 | Ver tablero de entrenamientos | Entrenamientos | Móvil | 2 | 2 | Sprint 2 | No iniciada | — | — |
| HU034 | Calcular FTP y VO2max | Entrenamientos | Móvil | 2 | 1 | Sprint 1 | No iniciada | — | — |
| HU035 | Ver calendario deportivo | Eventos | Móvil | 2 | 1 | Sprint 1 | No iniciada | — | — |
| HU036 | Monitorear una práctica en tiempo real | Entrenamientos | Móvil | 3 | 1 | Sprint 3 | No iniciada | — | — |
| HU037 | Conectar dispositivos de medición | Entrenamientos | Móvil | 5 | 1 | Sprint 3 | No iniciada | — | — |
| HU038 | Notificar alimentos y bebidas | Entrenamientos | Móvil | 2 | 1 | Sprint 3 | No iniciada | — | — |
| HU039 | Notificación múltiple de eventos | Eventos | Móvil | 2 | 1 | Sprint 3 | No iniciada | — | — |
| HU040 | Programar sesiones virtuales | Servicios | Móvil | 3 | 1 | `N/D` | No iniciada | — | — |
| **Total** | **40 historias** | — | — | **100** | **100** | **33 asignadas; 7 `N/D`** | **0 aceptadas registradas** | — | — |

## Gráficos del backlog

```mermaid
xychart-beta
    title "PHU por dominio"
    x-axis ["Usuarios", "Afiliación", "Servicios", "Entrenamientos", "Eventos", "Terceros"]
    y-axis "PHU" 0 --> 40
    bar [20, 7, 14, 36, 20, 3]
```

```mermaid
pie showData
    title Distribución de PHU por canal
    "Solo web" : 62
    "Solo móvil" : 36
    "Web y móvil - HU003" : 2
```

```mermaid
xychart-beta
    title "PHU por sprint histórico y sin asignar"
    x-axis ["Sprint 1", "Sprint 2", "Sprint 3", "N/D"]
    y-axis "PHU" 0 --> 40
    bar [27, 20, 34, 19]
```

```mermaid
xychart-beta
    title "Puntos de valor por dominio"
    x-axis ["Usuarios", "Afiliación", "Servicios", "Entrenamientos", "Eventos", "Terceros"]
    y-axis "Valor" 0 --> 35
    bar [22, 7, 16, 31, 21, 3]
```

```mermaid
xychart-beta
    title "Puntos de valor por sprint inicial"
    x-axis ["Sprint 1", "Sprint 2", "Sprint 3", "Sin asignar"]
    y-axis "Valor" 0 --> 40
    bar [32, 29, 26, 13]
```
