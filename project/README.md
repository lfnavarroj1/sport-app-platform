# Fuente local para GitHub Projects

## Propósito

Esta carpeta prepara y respalda los datos que se administrarán en GitHub Projects. Los gráficos se actualizan a partir de estos registros; no se corrigen cifras directamente en una diapositiva o captura y el contenido local no sustituye el tablero remoto.

Cada registro incluye, cuando hay datos suficientes, un gráfico Mermaid junto con la tabla fuente. La tabla conserva el detalle auditable y el gráfico facilita la presentación. Si ambos difieren, la tabla debe corregirse primero y luego regenerarse el gráfico.

## Destino remoto

El repositorio público `sport-app-platform` está asociado exclusivamente al [Project 4: SportApp Platform](https://github.com/users/lfnavarroj1/projects/4), creado desde cero para la reimplementación. El Project 2 pertenece al equipo anterior, no está asociado al repositorio nuevo y no se reutilizan sus ítems ni sus estados. Sus datos solo pueden conservarse como referencia histórica explícita en la documentación.

La propiedad de los ítems será:

| Tipo de trabajo | Repositorio del issue | Presencia en Project |
| --- | --- | --- |
| HU y épica transversal | `sport-app-platform` | obligatoria |
| Tarea backend | `sport-app-backend` | enlazada con su HU |
| Tarea web | `sport-app-frontend` | enlazada con su HU |
| Tarea móvil | `sport-app-movil` | enlazada con su HU |
| Infraestructura compartida | `sport-app-platform` | enlazada con HU, release o deuda técnica |
| Documentación de wiki o release | `sport-app-platform` | cuando forme parte del sprint |

Una HU no se duplica en los tres repositorios. El issue central representa el valor; las tareas técnicas y PR de componentes aportan la evidencia.

## Campos requeridos

| Campo | Tipo | Uso |
| --- | --- | --- |
| Estado | Selección | Backlog, Preparada, En curso, En revisión, Aceptada, Bloqueada, Retirada |
| Sprint | Iteración | periodo comprometido |
| PHU | Número | estimación estable de la HU |
| Valor | Número | prioridad/valor de negocio |
| Ciclo | Selección | Reimplementación 2026; otros ciclos se agregarán solo cuando existan |
| Repositorios afectados | Selección múltiple o etiquetas | backend, frontend, móvil, plataforma |
| Versión objetivo | Texto/selección | tag de plataforma esperado |
| Versión entregada | Texto | tag real que contiene la HU |
| Fecha de inicio | Fecha | inicio del tiempo de ciclo |
| Fecha de aceptación | Fecha | cierre verificable |
| Evidencia | Texto/URL | PR, CI, artefacto, demo o informe |

## Vistas mínimas

- Backlog priorizado por valor y PHU.
- Sprint actual por estado.
- Roadmap por versión objetivo.
- HU bloqueadas y dependencias.
- Trabajo por repositorio afectado.
- Release actual con HU aceptadas y evidencia.
- Referencias históricas fuera del tablero operativo vigente.

| Registro | Contenido | Frecuencia |
| --- | --- | --- |
| [Catálogo de historias](catalogo-historias.md) | PHU, sprint, valor, estado y evidencia de las 40 HU | Al planear o cambiar estado |
| [Registro de sprints](registro-sprints.md) | Compromiso, aceptación, velocidad y predictibilidad | Planeación y cierre |
| [Registro de burndown](registro-burndown.md) | Saldo diario y cambios de alcance | Diario |
| [Registro de calidad](registro-calidad.md) | Pruebas, cobertura, defectos y seguridad | Cada ejecución relevante de CI |

## Reglas

- Use fechas ISO `AAAA-MM-DD`.
- Use `N/D` cuando no exista medición; use `0` solamente cuando la medición exista y su resultado sea cero.
- Enlace siempre la evidencia: PR, ejecución de CI, reporte, demo o acta.
- No borre cambios de alcance; registre el valor anterior, el nuevo y el motivo.
- No cambie PHU durante el sprint.
- No marque una HU como aceptada sin cumplir la definición de terminado.
- Cada HU aceptada debe indicar la versión de plataforma donde fue entregada.
- Cada sprint aceptado debe corresponder con una release según el [manual de versiones](../documentacion/docs/manual-versionado.md).
