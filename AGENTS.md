# FS Code — instrucciones del proyecto

@/Users/daniellares/.codex/RTK.md

## Orquestación e implementación: requisito permanente

- El agente principal planifica la solución, define tareas concretas y criterios de aceptación, coordina e integra el trabajo mediante los agentes, revisa el código y verifica el resultado.
- Toda implementación o corrección de código se delega a modelos más económicos disponibles. El agente principal no escribe directamente código de la aplicación ni pruebas; devuelve las correcciones al agente implementador.
- Usar tareas acotadas con propiedad explícita de archivos y evitar modificaciones simultáneas de los mismos archivos. No crear tareas visibles nuevas cuando basta un subagente del trabajo actual.
- Selección actual: Terra para implementación; Luna para cambios pequeños y bien delimitados cuando proceda. No escalar a modelos más costosos sin una necesidad concreta. No afirmar ahorros medidos sin datos de uso/precio.
- El agente principal puede mantener documentación, decisiones, tareas y estas instrucciones. Conserva la responsabilidad de revisar y validar: delegar no equivale a dar el trabajo por terminado.
- Regla confirmada por el usuario el 23 de septiembre de 2026; aplica siempre a este proyecto y a futuras sesiones.

## GUI nativa de macOS: requisito permanente

- Leer `docs/MACOS_GUI.md` antes de diseñar, implementar o revisar cualquier interfaz.
- Construir la GUI con AppKit y las convenciones de macOS: organización, controles, menús, teclado, foco, ventanas y accesibilidad. Esta regla se aplica también a las contribuciones de otros agentes.
- Preservar la distribución acordada: biblioteca al iniciar; selector lateral `Files` / `TODOs` / `Agent Context`, con su árbol o lista en el mismo lateral y el detalle en el centro; terminal inferior central; asistente derecho. No cambiarla sin una decisión del usuario.
- Usar componentes del sistema y colores semánticos; adoptar Liquid Glass mediante APIs nativas donde corresponda. Mantener legible el contenido en claro y oscuro y respetar accesibilidad.
- Interfaz en inglés. Mantener el contenido del usuario en su idioma original.
- Revisar visualmente las vistas modificadas en la aplicación real. Informar lo verificado y lo pendiente; compilar no demuestra calidad visual ni accesibilidad.
- Mantener el código ordenado y ligero. No añadir frameworks de UI, efectos personalizados ni dependencias sin una necesidad concreta.
- Registrar decisiones y tareas en `CREACION.md`. Mantener el alcance acordado; esta guía no autoriza implementar funciones nuevas.

## Descubrimiento de código

Preferir las herramientas de codebase-memory-mcp: `search_graph`, `trace_path`, `get_code_snippet`, `query_graph` y `get_architecture`. Indexar si el proyecto no está indexado. Usar búsqueda textual para literales, configuración, documentación o cuando el grafo no cubra el código necesario.
