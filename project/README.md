# Fuente local para GitHub Projects

## Propósito

Esta carpeta prepara y respalda los datos que se administrarán en GitHub Projects. Los gráficos se actualizan a partir de estos registros; no se corrigen cifras directamente en una diapositiva o captura y el contenido local no sustituye el tablero remoto.

Cada registro incluye, cuando hay datos suficientes, un gráfico Mermaid junto con la tabla fuente. La tabla conserva el detalle auditable y el gráfico facilita la presentación. Si ambos difieren, la tabla debe corregirse primero y luego regenerarse el gráfico.

## Destino remoto

El repositorio público `sport-app-platform` está asociado exclusivamente al [Project 4: SportApp Platform](https://github.com/users/lfnavarroj1/projects/4), creado desde cero para la reimplementación. El Project 2 pertenece al equipo anterior, no está asociado al repositorio nuevo y no se reutilizan sus ítems ni sus estados. Sus datos solo pueden conservarse como referencia histórica explícita en la documentación.

La propiedad de los ítems será:

| Tipo de trabajo | Identificador | Repositorio del issue | Presencia en Project |
| --- | --- | --- | --- |
| Historia de usuario | `HUxxx` | `sport-app-platform` | obligatoria; elemento padre con PHU y valor |
| Tarea backend (microservicio y BFF) | `T-HUxxx-BE` | `sport-app-backend` | enlazada con su HU, justo a tiempo |
| Tarea web | `T-HUxxx-WEB` | `sport-app-frontend` | enlazada con su HU, justo a tiempo |
| Tarea móvil | `T-HUxxx-MOB` | `sport-app-movil` | enlazada con su HU, justo a tiempo |
| Tarea de plataforma | `T-HUxxx-PLAT` | `sport-app-platform` | solo cuando la HU requiere trabajo real en la plataforma |
| Trabajo transversal | `TEC-xxx` | repositorio propietario | enlazado con HU, release o deuda técnica |
| Documentación de wiki o release | — | `sport-app-platform` | cuando forme parte del sprint |

Una HU no se duplica en los repositorios. El issue central representa el valor; las tareas técnicas y los PR de componentes aportan la evidencia.

## Historias y tareas técnicas

La regla canónica está en el modelo de descomposición y entrega de la documentación central (`documentacion/arquitectura/guias-desarrollo/modelo-descomposicion-y-entrega.md`). En este repositorio se aplica así:

- El backlog conserva exactamente **40 HU (HU001–HU040), 100 PHU y 100 puntos de valor**. Cada HU aparece una sola vez, aunque participen varios repositorios.
- Las responsabilidades técnicas son tareas hijas: `T-HUxxx-BE`, `T-HUxxx-WEB`, `T-HUxxx-MOB` y, solo cuando aplique, `T-HUxxx-PLAT`. No son historias: no tienen PHU ni puntos de valor y ninguna puede cerrar la HU por separado.
- Tareas obligatorias por canal:

  | HU | Tareas | Total |
  | --- | --- | ---: |
  | HU001–HU025, salvo HU003 | `T-HUxxx-BE` + `T-HUxxx-WEB` | 48 |
  | HU003 | `T-HU003-BE` + `T-HU003-WEB` + `T-HU003-MOB` | 3 |
  | HU026–HU040 | `T-HUxxx-BE` + `T-HUxxx-MOB` | 30 |
  | **Total** | 40 BE + 25 WEB + 16 MOB | **81** |

- Las tareas se crean en el Project **justo a tiempo**: al preparar o iniciar la HU, asignar un componente o seguir un bloqueo. No se crean las 81 tarjetas por anticipado.
- Ramas, commits, PR, ejecuciones de CI, versiones de contrato y evidencia se enlazan bajo la **HU padre**; cada tarea aporta los suyos y la HU conserva la evidencia conjunta.
- Solo una HU `Aceptada` suma velocidad, throughput y valor entregado. El avance de una tarea orienta el porcentaje de flujo de la HU, pero no entrega una fracción de PHU ni de valor.
- Backend, frontend y móvil conservan su versionado independiente; la plataforma registra qué versiones son compatibles.

## Campos requeridos

| Campo | Tipo | Uso |
| --- | --- | --- |
| Estado | Selección | Backlog, Preparada, En curso, En revisión, Aceptada, Bloqueada, Retirada |
| Sprint | Selección | Sprint 1, Sprint 2, Sprint 3 o Sin asignar |
| Inicio del sprint | Fecha | inicio de la ventana temporal asignada |
| Fin del sprint | Fecha | cierre de la ventana temporal asignada |
| PHU | Número | estimación estable; solo en HU, nunca en tareas ni PR |
| Valor | Número | valor de negocio; solo en HU, nunca en tareas ni PR |
| Tipo de elemento | Selección | Historia de usuario, pull request o actividad técnica; evita mezclar métricas funcionales y técnicas |
| Tipo | Selección | `Historia`, `Tarea BE`, `Tarea WEB`, `Tarea MOB`, `Tarea PLAT` o `Técnica transversal` |
| HU | Texto | identificador `HUxxx`; vacío para trabajo transversal sin HU |
| Historia padre | Relación `Parent issue` (nativa) | cada tarea es sub-issue de su HU en `sport-app-platform`, el único elemento que conserva PHU, valor y aceptación; el campo `HU` repite el identificador |
| Avance verificable (%) | Número | indicador de flujo: Backlog 0, Preparada 10, En curso 50, En revisión 80, Aceptada 100 |
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
- Avance verificable por tipo de elemento, sin convertir trabajo parcial en PHU o valor entregado.

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
- Los PR y actividades técnicas pueden mostrar avance, pero no reciben PHU ni puntos de valor; esas métricas pertenecen exclusivamente a la HU aceptada.
- Todas las HU deben tener responsable. Un cambio de responsable se registra en el issue, no solo en una vista.
- Cada HU aceptada debe indicar la versión de plataforma donde fue entregada.
- Cada sprint aceptado debe corresponder con una release según el [manual de versiones](../docs/manual-versionado.md).
