# Revisión de rendimiento — 23 de septiembre de 2026

## Evidencia y límites

Revisión estática del código actual por el principal y un agente Terra, durante CHAT-04. Los costes descritos abajo se deducen de las rutas de ejecución; no son resultados de un perfilador ni prueban una fuga de memoria. La comparación anterior con Zed no es un benchmark: cargas, antigüedad de procesos y funciones diferentes.

Antes del rediseño, tres muestras `top` del proceso FSCode (PID 88596, 22:22:23–22:22:27) mostraron 66 MiB de huella y 0,0 % CPU; las dos últimas contienen intervalos de dos segundos. Había un proyecto abierto y el chat en reposo. No incluye Codex ni shell; no mide latencia al escribir ni streaming. El historial local de conversaciones ocupaba 8 KiB en disco: no representa el límite de 4 MiB permitido.

## Prioridades

| Prioridad | Hallazgo comprobado en código | Cuándo puede pesar | Siguiente paso verificable |
| --- | --- | --- | --- |
| Alta | `CodePresentation.textDidChange/updateSyntax/invalidateColors` tokeniza todo el texto tras 100 ms y reaplica color a todo el storage. El tokenizador corre fuera del hilo principal y admite cancelación, pero aplicar atributos ocurre en el hilo principal. | Archivos grandes con escritura entre pausas. | Medir 100 KiB/1 MiB/5 MiB y latencia del hilo principal; evaluar recoloreado incremental con estado léxico correcto o un modo explícito para archivos grandes. |
| Alta | `LineNumberRulerView.updateLineIndex` llama a `LineIndex.update`, que reconstruye los comienzos de línea recorriendo UTF-16. | Cada edición, aunque cambie un solo carácter. | Actualizar el índice con el rango editado y diferencia de longitud; conservar reconstrucción para recarga. Probar CRLF, Unicode y 10k/100k líneas. |
| Alta | `TextEditorView.refreshAgentChangeMarkers` llama a `locate(in:)` por cada bloque, buscando coincidencia contextual única en todo el texto. | Escribir en archivos con muchos bloques de IA. | Medir con 10/100/500 bloques. Desplazar rangos conocidos y agrupar la relocalización; antes de Revert validar siempre contra contenido actual. No sacrificar seguridad de reversión por velocidad. |
| Media | `ContextStore.load` recorre fuentes externas; `windowDidBecomeKey` solicita refresco, además del watcher. Hay debounce de 350 ms y límite de exploración. | Repositorios grandes y cambios frecuentes de ventana. | Contar visitas/duración; recargar contenido de una regla conocida y reservar escaneo completo para cambios estructurales o pérdida de eventos. |
| Media | `AgentFileChangeService.persist` enumera y hace lstat de los JSON para contabilizar el historial; `history` carga y valida registros. Límites: 5.000 entradas, 4 MiB por registro y 16 MiB totales. | Historial cercano al límite, aplicar/revertir muchos cambios. | Medir con 100/1.000/5.000 registros. Caché de contabilidad validada con invalidación segura; mantener journal preparado/aplicado para recuperación. |
| Media | `AgentConversationManager.refreshVisibleConversation` filtra/ordena conversaciones con cada delta. `AgentConversationStore.save` valida y reescribe el JSON completo tras una pausa de 100 ms; se ejecuta en un actor, no directamente en AppKit. | Respuestas largas e historiales grandes. | Medir eventos, bytes escritos y duración; evitar ordenar cuando no cambió el conjunto y evaluar checkpoints de persistencia acotados sin perder el flush final. |
| Baja | Cada mutación de archivo completada puede invalidar/releer el árbol y recuperar selección. Ya existen guardas para no repetir marcas de IA idénticas. | Un turno que modifique muchos archivos. | Agrupar actualizaciones breves e invalidar sólo padres afectados. Medir número de reloads; conservar archivos ocultos y selección. |

## Panel del agente — CHAT-04

La implementación anterior reconstruía menús y hacía `transcriptTable.reloadData()` en cada refresh de 80 ms, incluidos borradores que no alteraban los mensajes. El Markdown del mensaje que crece se vuelve a representar en el hilo principal; los mensajes ya representados disponen de caché.

CHAT-04 incorpora guardas para no reconstruir catálogos y pestañas idénticos, no recargar el transcript cuando sólo cambia el borrador, y recargar únicamente una fila cuando sólo esa respuesta cambia. El datasource usa una copia estable de mensajes para proteger cambios entre conversaciones de distinto tamaño. El estado de pestañas no se escribe si no cambió. Compilación y pruebas correctas; esto demuestra el comportamiento del código, no un porcentaje de ahorro de CPU o memoria. El procesamiento incremental de Markdown y la virtualización de respuestas extremadamente largas siguen siendo candidatos a medir, no mejoras declaradas.

## Rutas revisadas

- `Sources/FSCode/CodePresentation.swift`: 33, 65, 91.
- `Sources/FSCode/LineNumberRulerView.swift`: 62, 160; `Sources/EditorCore/LineIndex.swift`: 17.
- `Sources/FSCode/TextEditorView.swift`: 339, 773; `Sources/AgentConnectionCore/AgentFileChangeService.swift`: 94, 133.
- `Sources/FSCode/WorkspaceWindow.swift`: 277, 557; `Sources/AgentContextCore/ContextStore.swift`: 121; `Sources/AgentContextCore/ContextExternalScanner.swift`: 65.
- `Sources/AgentConnectionCore/AgentFileChangeService.swift`: 500, 897.
- `Sources/AgentConnectionCore/AgentConversation.swift`: 344, 1561, 1659, 1731.

Las líneas corresponden a la revisión y pueden desplazarse. No se cambian motores del editor, persistencia ni watchers como parte del acabado visual. Los siguientes trabajos deben partir de mediciones reproducibles con fixtures y pruebas de corrección, no sólo de porcentajes de memoria entre aplicaciones distintas.

Muestra diagnóstica adicional a las 22:36:32: FSCode PID 91714, huella 70,6 MiB, todos los samples del hilo principal en el bucle de espera de eventos de AppKit. La automatización de la ventana dio timeouts; esta muestra no prueba un bloqueo del editor ni sustituye un perfil bajo carga.
