# Harness de IA: evaluación para FS Editor

Fecha: 23 de septiembre de 2026. Estado: propuesta para discutir; sin implementación ni dependencias nuevas.

## Criterio del producto

Código ordenado, experiencia plenamente macOS y reutilización de lo que aporte capacidades y ahorre tiempo dentro de nuestra visión. No optimizar por número de líneas propias. Medir el consumo completo del editor, agentes y procesos auxiliares. Más funcionalidad reutilizada puede compensar una dependencia mayor; debe demostrarse.

El texto aportado por el usuario es material de análisis. Sus recomendaciones no se consideran decisiones aprobadas.

## Qué estamos eligiendo

- **Modelo:** genera respuestas y solicitudes de herramientas.
- **Harness o motor de agente:** organiza turnos, contexto, herramientas, permisos, recuperación y continuidad de la tarea.
- **Integración del editor:** aporta documentos abiertos, selección, interfaz de conversación, revisión de cambios y coordinación con el trabajo del usuario.
- **Protocolo:** comunica esos componentes; no sustituye al motor ni garantiza aislamiento.

Un selector de modelos y un selector de agentes son decisiones distintas. No hay que prometer que cambiar de agente conservará automáticamente historial, herramientas, autenticación y comportamiento.

## Evaluación de las opciones citadas

| Opción | Evidencia actual | Encaje propuesto |
| --- | --- | --- |
| Codex | [Código Apache-2.0](https://github.com/openai/codex/blob/main/LICENSE). [App Server](https://developers.openai.com/codex/app-server) permite integrar autenticación, conversaciones, aprobaciones y eventos en un cliente propio. | Primer candidato para una integración profunda con Codex. Ejecutarlo como proceso auxiliar y mantener la UI AppKit; no exige incorporar VS Code. No declararlo ganador de rendimiento sin medir. |
| OpenCode | [Licencia MIT](https://github.com/anomalyco/opencode/blob/dev/LICENSE), [proveedores configurables](https://opencode.ai/docs/providers/) y [ACP sobre stdio](https://opencode.ai/docs/acp/). | Candidato real a motor si varios proveedores son una prioridad temprana. Evaluar su ejecución sin adoptar su interfaz completa. Reducirlo a inspiración de UX descartaría una capacidad útil. |
| Aider | [Apache-2.0](https://github.com/Aider-AI/aider/blob/main/LICENSE.txt). Su [mapa de repositorio](https://aider.chat/docs/repomap.html) selecciona símbolos y relaciones dentro de un presupuesto de contexto. | Referencia útil para contexto y edición. Reutilizar componentes si su integración ahorra trabajo; no añadir otro motor solo para disponer de un repo-map. |
| Continue | Su [README](https://github.com/continuedev/continue) declara que el repositorio ya no se mantiene activamente, está en solo lectura y tuvo una versión final 2.0.0; licencia Apache-2.0. | La advertencia del texto está confirmada. Puede servir de referencia, pero adoptarlo implica asumir mantenimiento propio. |

MIT y Apache-2.0 permiten uso comercial bajo sus condiciones. Conservar licencias, atribuciones y los avisos aplicables; Apache requiere además atender a los cambios y a NOTICE cuando corresponda. Antes de redistribuir, revisar las versiones exactas y sus dependencias. La licencia del harness no concede acceso gratuito a los modelos, suscripciones ni derechos de marca. La licencia de un adaptador tampoco sustituye los términos del agente que ejecuta.

## ACP, MCP y App Server

[ACP](https://github.com/agentclientprotocol/agent-client-protocol) conecta editores con agentes. [MCP](https://modelcontextprotocol.io/docs/getting-started/intro) conecta aplicaciones de IA con herramientas y fuentes de datos. No son alternativas equivalentes. [Zed](https://zed.dev/docs/ai/external-agents) usa ACP con agentes externos en procesos separados; configuración, autenticación y capacidades siguen dependiendo del agente.

Para Codex existen dos rutas a comparar:

1. **App Server directo:** FS Editor habla con `codex app-server`. La documentación ofrece JSONL por stdio y generación de esquemas por versión. Es una ruta específica de Codex, apropiada para integrar sus capacidades.
2. **ACP:** FS Editor habla un protocolo compartido con distintos agentes. El [adaptador codex-acp](https://github.com/agentclientprotocol/codex-acp/blob/main/README.md) inicia App Server y traduce solicitudes y eventos. Añade una pieza que mantener y medir, a cambio de interoperabilidad.

OpenCode expone directamente `opencode acp`. Tener ACP no implica que todos los agentes soporten las mismas operaciones ni que una integración funcione sin verificar capacidades.

La documentación de App Server contiene superficies experimentales y advierte sobre el comando/transporte WebSocket. La prueba propuesta usaría stdio local y una versión fijada; debe verificar estabilidad de las operaciones necesarias y compatibilidad de actualizaciones antes de distribución. No asumir estabilidad de todo el protocolo ni abrir un servidor de red por defecto.

## Recomendación de arquitectura

Mantener una integración propia por responsabilidades, reutilizando el motor que mejor resuelva el trabajo:

| Responsabilidad | Propietario propuesto |
| --- | --- |
| UI nativa, selección y contenido sin guardar, pestañas y navegación | FS Editor |
| Sesiones visibles, progreso, cancelación y presentación de permisos | FS Editor, mediante un adaptador del agente |
| Bucle del agente, gestión de contexto e invocación de herramientas | Harness reutilizado, según capacidades verificadas |
| Aplicación al proyecto de cambios aprobados, atribución y reversión | Servicio de documentos/archivos de FS Editor |
| Proveedores, autenticación y modelos admitidos | Harness elegido; reflejar sus posibilidades reales en la UI |

El límite entre FS Editor y un agente es una razón concreta para crear un contrato interno. No hace falta construir simultáneamente un harness propio y varios motores externos. Un agente propio queda como opción si una necesidad demostrada no se resuelve adecuadamente con los candidatos.

Propuesta inicial: evaluar primero Codex App Server para integración profunda y OpenCode vía ACP para amplitud de proveedores. Si varios agentes deben estar disponibles desde la primera entrega, ACP gana prioridad. La elección final depende de la prueba de escrituras, experiencia y consumo, no de que el motor esté escrito en Rust o TypeScript.

No adoptar LangChain en esta fase porque aún no hemos identificado una función necesaria que lo justifique. No dar por probada la afirmación general de que los agentes serios siguen todos una arquitectura determinada.

## Condición decisiva: control de las escrituras

Nuestro requisito sigue siendo que todas las escrituras de IA sobre el proyecto pasen por el servicio de FS Editor, con ruta, turno, hashes, fecha y parche. Un evento de cambio o una aprobación del agente no prueban que la escritura haya pasado por ese servicio. Un comando de shell puede modificar archivos sin utilizar la herramienta de edición.

Dos alcances posibles, por validar:

- **Primera conversación y propuestas:** contexto explícito y acceso de lectura controlado, sin herramientas con escritura sobre el proyecto ni comandos que eludan esa restricción. El agente devuelve propuestas; FS Editor valida y aplica las aceptadas. El modo de lectura debe estar aplicado por permisos efectivos, no solo por instrucciones al modelo.
- **Trabajo autónomo con comandos:** entorno de trabajo separado y aislamiento efectivo que impida escribir directamente en el proyecto original. FS Editor revisa e importa los cambios aceptados mediante su servicio. Un worktree por sí solo no es un sandbox; para carpetas sin Git también debe existir un recorrido definido. Hay que incluir procesos hijos y herramientas externas en la política.

No se ha demostrado todavía que ninguno de los candidatos cumpla este contrato. Si se propone permitir escrituras directas y registrarlas después, eso cambia el requisito y debe acordarse explícitamente. Un watcher puede detectar cambios externos, pero no garantiza su autoría ni recupera todas las operaciones intermedias.

Para no perder trabajo: enviar una instantánea identificada del documento, incluida la selección y el texto sin guardar; comprobar revisión/hash al aplicar. Si ha cambiado, presentar conflicto o recalcular. Revertir debe preservar cambios posteriores del usuario. El diff de Git no equivale al historial de modificaciones de IA.

## Rendimiento y experiencia

Iniciar el agente al necesitarlo. No cargar todos los motores instalados al abrir la biblioteca. Limitar concurrencia, salida acumulada y actualizaciones visuales; leer eventos fuera del hilo principal. Definir cierre de sesiones y procesos hijos sin cancelar silenciosamente tareas al ocultar un panel.

Medir editor más agentes, adaptadores, servidores MCP, diagnósticos y, cuando corresponda, modelos locales. Aislar procesos protege la interfaz frente a fallos, pero siguen compitiendo por recursos. No prometer impacto cero ni asumir que un binario nativo es ligero.

Comparar en el mismo equipo: biblioteca sin IA, agente inactivo, primer turno, streaming prolongado, tarea con muchas herramientas, cancelación y cierre. Registrar memoria total, CPU en reposo, latencia de edición, tiempo de respuesta y procesos que permanecen vivos. Usar el mismo modelo cuando sea posible y separar las diferencias del modelo de las del harness. Presupuestos pendientes de acordar.

## Tareas propuestas, aún sin autorización de implementación

| ID | Resultado | Criterio de aceptación |
| --- | --- | --- |
| H-01 | Definir experiencia y alcance inicial | Agente/proveedores iniciales, contexto enviado, permisos y modalidad de escritura acordados |
| H-02 | Comparar integraciones acotadas: Codex App Server y OpenCode ACP | Mismo recorrido: iniciar, contexto, respuesta progresiva, cancelar, recuperar fallo; consumo y dependencias registrados |
| H-03 | Validar atribución y escrituras | Parche aceptado, documento sin guardar, edición concurrente, creación/borrado y comando que intenta escribir: todos respetan el contrato acordado |
| H-04 | Seleccionar y conectar el motor al panel AppKit | Decisión documentada con medidas; contexto visible, progreso, permisos y errores comprensibles |
| H-05 | Ampliar capacidades justificadas | Herramientas, instrucciones de proyecto, diagnósticos y otros agentes mediante tareas independientes |

H-02 y H-03 requieren definir una prueba pequeña con H-01 antes de delegar código. Los diagnósticos necesitan una fuente real —compilador, analizador o LSP— y no aparecen por conectar un modelo. El soporte de AGENTS.md y otras reglas debe verificar alcance y precedencia por agente, evitando duplicar instrucciones.

Esta revisión modifica documentación únicamente; no añade un harness al prototipo.
