# Plan de implementación — peticiones recientes

Actualizado el 23 de septiembre de 2026. Alcance: peticiones recientes de esta conversación de FS Editor, según la aclaración del usuario; no se incorporan tareas de otros proyectos. Las tareas reales están registradas en `.fscode/todos.json`; se conserva el TODO previo `Accesos Directos`.

| Orden | Tarea | Modelo / reparto | Criterio de aceptación | Estado |
| --- | --- | --- | --- | --- |
| 1 | TODO-03: lista sólo con título | Luna | Una línea nativa compacta; ordenación y páginas de 10 conservadas | Completado y verificado |
| 2 | TODO-04: vínculo sólo para origen inline | Luna | Ningún campo editable para TODO manual; procedencia real de comentario como enlace de sólo lectura | Completado y verificado |
| 3 | FILES-02: archivos ocultos | Terra | `.env`, `.git`, `.fs` visibles; carga perezosa conservada | Completado y verificado |
| 4 | NAV-02: ocultar biblioteca | Terra | Abrir proyecto oculta Projects; cierre/cambio exitoso la muestra; Cancel conserva la ventana | Completado y verificado |
| 5 | LAYOUT-03: asistente ancho | Terra | Superar 460 puntos y conservar ancho al ocultar/mostrar/reabrir; respetar centro mínimo | Completado; pruebas de persistencia y asistente ancho correctas |
| 6 | LLM-01: Connect Model | Terra UI / Sol transporte | OAuth y API por el mismo motor, cuentas y sesiones por proyecto, catálogo real, cancelación y errores | ChatGPT autenticado; aislamiento por proyecto verificado en pruebas y app; API key real pendiente |
| 7 | CHAT-01: conversaciones | Terra UI / Sol sesiones | New Chat, hilos por proyecto, persistencia, entrada abajo, turnos, streaming y Stop | Completado: turnos reales, historial y Markdown nativo |
| 8 | CHAT-02: modelo y pensamiento | Terra | Capacidades del catálogo real y selección por hilo | Completado: catálogo real y controles inferiores |
| 9 | CTX-02: contexto efectivo al harness | Sol | Instantánea exacta, sin reglas ignoradas, trazabilidad y control de límites | Pendiente de CHAT-01 |
| 10 | TODO-05: detección inline | Terra; revisión Sol si afecta indexación | Comentarios reales según lenguaje, ubicación, actualización y deduplicación | Pendiente |
| 11 | MAC-05: uniones y contenedores nativos | Terra + revisión visual principal | Márgenes y radios coherentes con AppKit, claro/oscuro y paneles ajustables | Paneles rectos y NSScrollView overlay verificados; acabado SwiftTerm/accesibilidad pendiente |
| 12 | AGENT-01: escrituras y revisión | Sol + Terra UI | Servicio único, aprobación, hashes, diff, marca ✦ y reversión segura | Completado en alcance inicial: dos ediciones/reversiones reales, hashes y ✦ verificados |
| 13 | MODEL-01: evaluar Spark | Principal | Confirmar acceso delegable y ejecutar una tarea pequeña verificable | Disponibilidad no confirmada |
| 14 | APP-01: About y licencia | Luna | Panel AppKit, 0.1.0 Alpha, crédito Daniel Lares/Codex y MIT empaquetada | Completado y verificado en About y paquete |

## Reparto y consumo

El principal define contratos y criterios, revisa y verifica. Luna se utiliza para cambios pequeños y delimitados; Terra para componentes AppKit y comportamientos acotados. Sol se reserva para OAuth, procesos, concurrencia, sesiones y persistencia con riesgo de pérdida de datos. Son asignaciones de trabajo, no una comparación de precios ni una afirmación de ahorro medido.

El usuario propone GPT-5.3-Codex-Spark. No está expuesto entre los modelos que las herramientas de delegación de esta sesión permiten seleccionar. La consulta de uso tampoco devuelve un cupo separado de Spark; eso no demuestra que la cuenta carezca de acceso. No se sustituirá silenciosamente otro modelo llamándolo Spark. Cuando esté disponible, probarlo primero con una tarea pequeña y criterios objetivos antes de ampliar su responsabilidad.

## Coherencia macOS

Decisión del usuario: eliminar marcos redondeados de todos los paneles internos. Usar superficies rectas AppKit y separadores finos; mantener márgenes de controles y scroll superpuesto sin columna permanente. Esta decisión sustituye la propuesta anterior de laterales redondeados. SwiftTerm ya usa `scrollerStyle = .overlay`; su implementación mantiene un cálculo interno de anchura para el indicador. No se modifica la dependencia en este ajuste.

Fuente: [Get to know the new design system, Apple WWDC25](https://developer.apple.com/videos/play/wwdc2025/356/).

Las tareas sólo se marcarán cerradas tras verificar su resultado. El soporte de conversaciones, detección inline y escrituras del agente no se presenta como implementado por el hecho de que existan estos TODOs.

## Siguiente acabado del chat

- Comprobar seguimiento del último mensaje en historiales largos: durante la validación, el último mensaje podía quedar debajo del área visible. Conservar la posición cuando el usuario consulta mensajes anteriores.
- Añadir presentación dedicada de tablas Markdown cuando se aborde el siguiente acabado, sin un navegador ni dependencias innecesarias.

## AGENT-02 — revisión posterior por bloques (implementado; revisión visual pendiente)

Sustituye la aprobación previa del parche: aplicar directamente, identificar archivos/rangos en cada conversación, resaltar bloques en el editor y ofrecer Show Original / Revert Block. La reversión individual debe conservar otros bloques y ediciones posteriores independientes. La implementación pasó 124 pruebas completas y 2 nuevas pruebas UI enfocadas, además de la compilación release. Los casos de dos bloques y edición manual intermedia están cubiertos automáticamente. La aceptación visual con modelo real sigue pendiente porque el Mac estaba bloqueado.


## Git — propuesta registrada

- GIT-01: motor local de consulta, botón Git, estado y diff nativo.
- GIT-02: historial y grafo paginado; evaluar algoritmo MIT de Maple.
- GIT-03: stage/unstage, commit y stashes.
- GIT-04: remotos, ramas y conflictos.

Criterios, licencias y reparto en [GIT_INTEGRATION.md](GIT_INTEGRATION.md). Pendientes de acordar implementación; investigación realizada, sin dependencias nuevas.


## MCP — gestión por proyecto

MCP-01 configuración/Keychain/panel; MCP-02 transportes locales/remotos; MCP-03 autenticación; MCP-04 integración del harness y trazabilidad; MCP-05 recursos/prompts/importación. Arquitectura y aceptación en [MCP_PROJECT.md](MCP_PROJECT.md). Requisito registrado; tareas propuestas, todavía sin implementación.


## RTK — optimización opcional

RTK-01 detección/preferencia/ejecutor; RTK-02 instalación nativa y selección de binario; RTK-03 métricas y compatibilidad Git/MCP/harness. [Plan](RTK_INTEGRATION.md). Requisito registrado; no implementado en FS Editor. RTK local 0.49.0 detectado y comportamiento básico revisado.
