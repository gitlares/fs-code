# Validación de la primera distribución

Fecha: 2026-09-23.
Equipo de validación: macOS 26.7, Apple Silicon, Swift 6.4, SDK macOS 27.

Estado: prototipo compilado y ejecutado; distribución y flujo alternativo por ruta comprobados. El selector nativo requiere validación manual adicional.

## Resultados

- `swift test`: **5 pruebas, 0 fallos**. Cubren nombre persistente sin renombrar carpeta, conservación de ajustes desconocidos, rechazo de JSON inválido sin sobrescritura, duplicados por enlace simbólico, eliminación solo del índice y orden por uso reciente.
- `bash scripts/build-app.sh`: compilación release correcta y paquete `dist/FS Code.app` generado.
- `codesign --verify --strict`: firma local ad hoc válida.
- Tamaño del paquete inicial sin icono: **436 KB**. El icono añadido después ocupa aproximadamente **1,5 MB** en formato ICNS. Estas cifras son tamaño en disco, no consumo de memoria ni un presupuesto de rendimiento validado.
- Icono elegido por el usuario incorporado al paquete: conversión ICNS comprobada mediante `iconutil`, referencia en Info.plist válida y firma ad hoc verificada después de empaquetarlo. El diseño conserva el fondo negro opaco original; transparencia exterior pendiente.
- Inicio en biblioteca y lectura de su índice comprobados tras reiniciar la aplicación.
- Incorporación desde `Archivo → Añadir carpeta por ruta…` (⇧⌘O), nombre personalizado, creación de `.fscode/project.json` y apertura automática comprobadas con una carpeta temporal real.
- Ventana con árbol izquierdo, editor central superior, terminal central inferior y asistente a la derecha, comprobada visualmente.
- Los tres separadores aceptaron cambios de tamaño. Se comprobó la ocultación de terminal y la apertura del panel derecho.
- Apariencias oscura y clara observadas; etiquetas y fondos usan colores semánticos del sistema.
- La selección de un archivo del árbol actualiza el nombre en el espacio reservado del editor.
- Se corrigió una apertura inicial demasiado estrecha que podía ocultar el asistente: ahora el tamaño inicial es 1200 × 780 puntos de contenido y el cálculo del separador usa el ancho disponible.

## Límites y pendientes

- Durante la automatización del selector nativo, el botón de confirmación permaneció deshabilitado incluso al seleccionar carpetas. Se reprodujo con diálogo modal y hoja, dentro y fuera de `.build`; no se pudo determinar una causa en el código. Hay errores del servicio de selección de macOS en los logs, pero no establecen por sí solos la causa. No se afirma que el selector esté validado. Se conserva la hoja estándar y una alternativa funcional por ruta.
- La persistencia de tamaños está implementada al cerrar ventanas y al salir. Falta completar un recorrido visual de cierre/reapertura con todos los paneles y tamaños extremos. Los estados de plegado no se restauran como preferencia independiente.
- No se completó una prueba de arrastrar carpetas a la biblioteca, ni validación en macOS 14/15.
- No se ejecutó una medición de memoria, CPU, energía o latencia con grandes proyectos.
- La prueba visual se detuvo al detectar interacción del usuario con la app para no interferir. Quedaron dos registros propios de validación: «Prueba de distribución» y «Distribución macOS». Se pueden quitar de la biblioteca sin borrar sus carpetas.

Recorrido de aceptación para repetir manualmente:

1. Abrir la aplicación y comprobar que aparece la biblioteca.
2. Añadir una carpeta real de prueba, asignar un nombre y abrirla.
3. Verificar árbol izquierdo, archivo central superior, terminal central inferior y panel de IA derecho.
4. Arrastrar los tres separadores y redimensionar la ventana sin superposición de contenido.
5. Ocultar y mostrar paneles, restablecer la distribución y comprobar las apariencias clara y oscura.
6. Cerrar y volver a abrir el proyecto y la aplicación; comprobar persistencia de biblioteca y tamaños.
7. Verificar que cancelar la incorporación no registra el proyecto y quitarlo no elimina archivos.

La primera entrega no valida edición, ejecución de terminal, proveedores de IA, plugins ni presupuesto de rendimiento del producto completo.
# Detalle central y listas de TODOs (2026-09-23)

- `swift test`: 15 pruebas correctas. Incluye compatibilidad de JSON anterior sin relevancia/vínculo, persistencia de campos nuevos, orden por relevancia/fechas, desempates estables, 10 tareas por sección y validación de vínculos que intentan salir del proyecto, incluso mediante symlinks.
- Build release recompilado. Verificación UI en `Distribución macOS` con 24 tareas temporales añadidas a la tarea anterior: inicialmente 10 títulos abiertos y 10 cerrados, con botones `Load More` independientes.
- `Load More` de abiertos mostró sus 12 tareas sin ampliar las 10 de cerrados. Orden `Oldest First` verificado desde el menú nativo; reinició ambas secciones a 10 y ordenó por fecha ascendente.
- Selección del título mostró en el centro título editable, creación, estado, relevancia, vínculo, descripción y comentarios. Cambiar a `Closed` y guardar movió la tarea entre secciones y actualizó contadores de 12/13 a 11/14.
- Un título modificado produjo `Save / Discard / Cancel` al intentar ir a `Files`; cancelar conservó el borrador y la vista TODOs. `Open File` de `README.md` llevó al área de archivo con la ruta correspondiente; el editor de código sigue provisional.
- Las 24 tareas de paginación se retiraron al concluir, restaurando los bytes originales del JSON temporal tras comprobar que las tareas originales no habían cambiado. Ninguna tarea de prueba se añadió a proyectos del usuario.
- La paginación limita filas visibles, no el tamaño del JSON cargado en memoria. Pendiente medir grandes historiales y validar visualmente todos los tamaños mínimos de ventana. Detección automática de TODOs del código sigue pendiente.

# TODOs manuales por proyecto (2026-09-23)

- `swift test`: 11 pruebas correctas (5 biblioteca, 6 TODOs). Incluye aislamiento entre proyectos, reapertura, comentarios/estado/eliminación, datos corruptos, versiones desconocidas, IDs duplicados, cambios externos y fallo real de escritura conservando el estado.
- Build release y bundle recompilados. UI probada en `Distribución macOS`, carpeta temporal de la validación anterior.
- Creada desde `New TODO` la tarea `Verify project TODOs`, con descripción multilínea y comentario. Se reabrió para añadir un segundo comentario y marcar `Completed`; contador actualizado a `0 open · 1 done`.
- Aplicación cerrada y abierta nuevamente: la tarea reaparece como completada con los dos comentarios. El JSON real en `.fscode/todos.json` conserva los campos, identificadores y fechas.
- Aplicación dejada abierta en `FS Desktop Leds`, vista `TODOs`, con botón `New TODO` disponible y sin introducir tareas de prueba en ese proyecto. La tarea de prueba permanece únicamente en `Distribución macOS`.
- Eliminación cubierta por pruebas del almacén; no se ejecutó una eliminación permanente desde la UI. Los comentarios pueden añadirse pero no editarse individualmente. Detección en código, filtros, búsqueda y mediciones de listas grandes pendientes.
- No hay procesos adicionales ni sondeo. El JSON se lee/escribe sincrónicamente para esta primera lista local pequeña; no es una solución validada para historiales grandes o escritores concurrentes. Comprobar contenido antes de reemplazar evita conflictos ya existentes, pero no elimina la carrera entre procesos durante la escritura.

# Actualización visual: barra y selector lateral (2026-09-23)

- Build release y paquete `dist/FS Code.app` regenerados correctamente.
- Aplicación reiniciada y proyecto de prueba `Distribución macOS` abierto mediante la biblioteca.
- Barra compacta: nombre del proyecto a la izquierda; controles de lateral, terminal y asistente a la derecha. `Appearance` y `Reset Layout` disponibles desde `View`.
- Selector de iconos `Files` / `TODOs` comprobado por accesibilidad y captura visual. La vista de archivos conserva la selección de `README.md` al volver desde TODOs.
- Apariencia clara y oscura verificadas visualmente. Ocultar terminal desde la barra y recuperarla con `View → Reset Layout` comprobado.
- TODOs muestra un mensaje provisional en inglés. No se ha implementado creación de tareas, persistencia ni detección de comentarios. No hay pestañas ni edición de archivos funcionales todavía.
- No se añaden dependencias. No se han medido consumo ni comportamiento en ventanas estrechas en esta revisión.

# Composición nativa del detalle TODO (2026-09-23)

- Detalle reorganizado alrededor de título, estado, prioridad, descripción y comentarios, con controles AppKit y colores semánticos. Fecha, vínculo y eliminación se trasladan al menú de acciones.
- Corregida una excepción de Auto Layout al mostrar comentarios: las vistas se incorporan a la jerarquía antes de activar restricciones entre ellas. El contenido se mantiene alineado arriba con y sin historial.
- Compilación release correcta y 15 pruebas existentes sin fallos. Sin dependencias nuevas.
- Verificación visual en claro y oscuro. Creación real de una tarea temporal con título, descripción y comentario; cambio a `Closed` y prioridad `High` guardados y comprobados en el JSON. Menú de acciones comprobado con fecha y acciones secundarias.
- Datos originales del proyecto temporal restaurados byte por byte después de validar que no habían sufrido cambios de contenido. No se añadieron tareas a proyectos del usuario.
- No se han medido rendimiento ni todos los tamaños extremos de ventana en esta revisión.

# Primera entrega del editor de texto (2026-09-23)

- `swift test`: 25 pruebas correctas, 15 de ProjectLibrary y 10 de EditorCore. Cobertura nueva: conflictos externos, eliminación, binarios/codificaciones, límite de tamaño, BOM/CRLF, conservación de permisos ejecutables, diferencias Unicode con equivalencia canónica, retargeting de symlinks y conservación del original ante un guardado demasiado grande.
- Release compilado sin avisos y bundle firmado; `codesign --verify --strict` correcto. Sin dependencias nuevas. Módulo `EditorCore` separado de AppKit.
- En el proyecto temporal `Distribución macOS`: abrir texto, editar, guardar y reabrir tras reiniciar mostró el contenido guardado real. `⌘W` inmediato tras escribir mostró Save/Don’t Save/Cancel; Cancel conservó el borrador. Salir mediante `⌘Q` también presentó la hoja y cancelar mantuvo abierta la aplicación.
- Dos pestañas comprobadas con historiales de Undo separados, Redo y punto de cambios pendientes. Guardar separa los grupos de escritura; Undo posterior vuelve al contenido guardado sin borrar la edición previa al guardado.
- `⌘F` mostró la barra nativa y encontró una coincidencia. Pasar a TODOs y volver preservó pestañas y borrador.
- Un cambio externo escrito en el archivo temporal produjo un aviso al guardar: los bytes externos permanecieron intactos y el borrador continuó en la pestaña. Un binario temporal produjo un aviso sin abrirse como texto.
- Verificación visual en claro. Se detuvo el control de la GUI al detectar uso del usuario en `FS Desktop Leds`; no se modificaron archivos de ese proyecto durante las pruebas. Oscuro, tamaño mínimo, accesibilidad, historial largo, muchas pestañas y rendimiento medido quedan pendientes.
- Los archivos `editor-check.txt`, `editor-second.txt` y `editor-binary.dat` son fixtures creados en la carpeta temporal `FSCode-layout-_otlaf3r`. Se conservan por estar aún abiertos en la ventana de validación; `editor-check.txt` mantiene un borrador de conflicto de prueba, que puede descartarse al cerrar esa ventana.
- El límite inicial es UTF-8 y 5 MiB por archivo. No hay autosave ni recuperación de borradores tras fallo, restauración de pestañas, recarga externa automática, resaltado ni indentación por lenguaje. La comparación previa al reemplazo atómico no evita carreras entre escritores independientes.

# Números de línea y resaltado automático (2026-09-23)

- `swift test`: 39 pruebas correctas (15 ProjectLibrary y 24 EditorCore). Nuevas coberturas: índice UTF-16 con Unicode/CRLF/líneas vacías, detección de extensiones/nombres/shebang y tokens de comentarios, cadenas, números, plantillas y marcado.
- Release compilado, firma ad hoc verificada y aviso MIT de Dracula/Alucard presente en el bundle y cotejado con el original local. Sin paquetes ejecutables nuevos.
- GUI real en el proyecto temporal: Swift, JSON y XML reconocidos y coloreados. Dracula oscuro y Alucard claro comprobados; volver a claro conserva pestañas limpias y permite cerrar sin pedir guardar.
- Margen visible: línea 1 en archivo vacío, línea lógica 15 ajustada a varias filas sin números repetidos, desplazamiento hasta la línea 111 vacía y ancho adaptado a tres dígitos. El pie refleja lenguaje, línea y columna.
- Escribir dos líneas en `Empty.swift` actualizó colores y numeración. Undo devolvió el archivo vacío y retiró el punto de cambios; los atributos no añadieron pasos de deshacer. No se guardaron modificaciones de prueba en ese archivo ni se editaron archivos del usuario.
- Los fixtures `Syntax.swift`, `Syntax.json`, `Syntax.xml` y `Empty.swift` permanecen únicamente en el proyecto temporal de validación. El borrador de conflicto de la prueba anterior fue descartado conservando la versión externa en disco.
- Implementación inicial: lexer completo cancelable en segundo plano tras 100 ms, índice lógico reconstruido al editar y atributos de color aplicados por lote sobre NSTextStorage. No hay parser incremental, semántica, autoindentación ni cobertura completa de interpolaciones/lenguajes incrustados. El margen solo dibuja las líneas del viewport; eso no implica que el coste completo de editar sea proporcional al viewport.
- Pendientes: medidas de CPU/memoria/latencia y muchas pestañas, grandes archivos, ventanas mínimas, preferencias de accesibilidad y pruebas exhaustivas de todas las construcciones de cada lenguaje.

# Cabecera de documentos (2026-09-23)

- Barra de pestañas AppKit alineada a la izquierda: icono del sistema, nombre, indicador de cambios y cierre por documento. Contenedor horizontal que lleva a la vista la pestaña seleccionada; `NSTabView` conserva los documentos sin dibujar el antiguo selector centrado.
- Ruta del archivo activo debajo mediante `NSPathControl`, con ruta completa en tooltip. Resistencia horizontal reducida para que una ruta larga se comprima sin ensanchar el panel central ni mover los separadores.
- Release compilado y aplicación principal reiniciada a petición del usuario. Vista comprobada en claro (copia temporal de validación) y oscuro (aplicación principal); selección, iconos, ruta, pestañas que exceden el ancho y cierre de una pestaña distinta de la activa comprobados.
- En `Empty.swift` del proyecto temporal: escribir, cerrar con X, cancelar la hoja, deshacer y cerrar con Cmd-W. Borrador protegido y estado vacío recuperado; no se guardaron ediciones de prueba.
- La copia temporal de validación quedó cerrada. No se modificaron documentos del proyecto del usuario. No se añadieron dependencias ni pruebas unitarias para este cambio de composición; se reutiliza la cobertura de persistencia y se verificaron los flujos afectados en la GUI. Prueba exhaustiva con VoiceOver, acceso a todas las pestañas solo con teclado y cientos de documentos pendiente.

# Sincronización de pestañas y árbol (2026-09-23)

- Release compilado y ejecutado. El punto de cambios se comprobó en pestañas activas e inactivas, con etiqueta accesible `Unsaved changes`. Guardar lo retiró; Undo y nuevo guardado restauraron el fixture `Empty.swift` a su contenido vacío.
- Cambiar de `Syntax.xml` a `Empty.swift` desde las pestañas actualizó la fila seleccionada y mantuvo el foco en el editor. Abrir `Sources/main.swift`, plegar Sources desde otra pestaña y volver a main.swift desplegó la carpeta y seleccionó el archivo.
- Cerrar main.swift activó Syntax.xml y sincronizó el árbol. No hubo aperturas duplicadas. Los cambios programáticos del árbol están protegidos contra el evento de apertura. El recorrido solo carga las carpetas de la ruta, sin búsqueda recursiva de todo el proyecto.
- Verificación visual en oscuro; controles y composición clara reutilizan la validación de TEXT-07. La comprobación de cerrar la última pestaña fue interrumpida por interacción del usuario y no se da por validada. Sin cambios en formatos de almacenamiento ni dependencias nuevas.

# Navegación entre proyectos (2026-09-23)

- Release recompilado y aplicación principal reiniciada. `File` muestra `Switch Project…` (⇧⌘L) y `Close Project` (⇧⌘W); habilitados solo para un proyecto disponible para cerrar.
- `Switch Project…` volvió a la biblioteca; se pudo abrir otro proyecto guardado. `Close Project` y el botón rojo devolvieron la ventana inicial al frente, sin cerrar la aplicación ni eliminar datos.
- Con un borrador en Empty.swift del proyecto temporal, Close Project mostró Save/Don’t Save/Cancel. Cancel mantuvo el proyecto y el texto. Switch Project también pidió una decisión; se descartó exclusivamente ese borrador de prueba y apareció la biblioteca. No se guardaron cambios en documentos del usuario.
- Se reutiliza el flujo existente de cierre y guardado de documentos/TODOs. No se añadieron pruebas unitarias para esta composición de menús; verificación manual de flujos afectados. No se repitió el guardado de TODOs ni la combinación de varios proyectos con borradores en esta revisión. La app queda abierta en la biblioteca con la compilación actual.

# Biblioteca simplificada y línea activa (2026-09-23)

- Biblioteca AppKit reducida a Projects, Open Folder…, búsqueda y filas con icono, nombre, ruta y botón de tres puntos. Se retiraron la cabecera grande, el filtro visible de favoritos y los botones inferiores Open/Edit. Los favoritos se conservan en el menú. Return abre la fila seleccionada.
- Los menús llevan el UUID del proyecto; prueba real con FS editor seleccionado y Edit en el menú de Distribución macOS mostró el nombre de Distribución macOS. Se canceló sin modificar datos. Clic derecho fuera de una fila no presenta acciones antiguas; los IDs explícitos desconocidos no usan otro proyecto como alternativa.
- Rutas y botones alineados al ancho de la fila mediante restricciones AppKit. Captura final en oscuro comprobada. Open Folder usa el panel estándar y permite crear carpetas; no se repitió la confirmación del selector ni la eliminación de un proyecto desde esta GUI. La eliminación de biblioteca sigue usando el almacén ya probado y no borra archivos.
- Fila del cursor resaltada suavemente en el código y el margen numérico mediante dibujo de fondo TextKit 2. En Syntax.xml, mover el cursor hasta la línea 3 mostró una sola franja correcta sin marcar el documento modificado. No se editó ningún archivo durante esta prueba. El fondo se calcula solo para la fila del cursor y no agrega atributos al documento.
- Compilación release correcta y firma local verificada. `swift test`: 39 pruebas correctas. Las comprobaciones de claro, selección de texto, archivo vacío, línea final y ajuste de líneas quedan pendientes de prueba visual en esta revisión; se detuvo el control de la ventana al detectar interacción del usuario.

## TERM-01 — Terminal local integrada (2026-09-23)

- SwiftTerm 1.20.0 fijado en manifiesto y lockfile. Build release con SwiftPM `--build-system native` correcto; paquete de aproximadamente 5,2 MB y firma ad hoc verificada con `codesign --verify --deep --strict`. Recurso y licencia MIT incluidos. El backend nativo evita la compilación Metal que falla con el SDK local; SwiftPM advierte que está obsoleto.
- 39 pruebas existentes correctas (ProjectLibrary/EditorCore). No se presentan como pruebas de terminal.
- Prueba interactiva en el proyecto temporal Distribución macOS: shell zsh real, `pwd` devuelve su carpeta, `stty size` devuelve 14×58, ejecución de Python con colores ANSI rojo/verde/azul, pegado mediante ⌘V, apertura/cierre de búsqueda con ⌘F.
- Inspección visual real en oscuro y claro: fondo y fuente coherentes con el editor, cabecera nativa compacta y controles alineados. Salida conservada al ocultar/mostrar. Se observó adaptación de líneas al ampliar la ventana.
- Revisión de código: sesión por workspace; ocultar no termina el proceso; salida del shell habilita reinicio; cierre/aplicación terminan el PTY. Una hoja protege comandos en primer plano usando `tcgetpgrp`; no enumera procesos separados de la sesión ni jobs en segundo plano.
- Pendiente de verificación interactiva final: Cancel/Stop and Close durante un comando activo, reinicio tras `exit`, Ctrl-C, cambio de tamaño consultado nuevamente con `stty`, límite de scrollback bajo carga y accesibilidad con VoiceOver. Las comprobaciones de UI se intercalaron con el uso de la aplicación por el usuario.
- Sin benchmark de CPU/memoria ni garantía de consumo bajo carga sostenida. El límite de 2.000 líneas evita crecimiento ilimitado del historial de texto; no limita la memoria de los comandos ejecutados.

## IMAGE-01 — Imágenes y SVG (2026-09-23)

- Compilación release y empaquetado correctos. Suite completa de 42 pruebas aprobada; tras el ajuste final de tamaño y validación SVG, se repitieron las 3 pruebas afectadas con resultado correcto.
- Nuevas pruebas: PNG nunca editable/guardable como texto; reutilización y cierre de pestañas mixtas; decodificación reducida de 3.000 × 1.000 a máximo 2.048 píxeles y ajuste dentro del panel; SVG conserva borrador, Undo y guardado al cambiar de vista; XML inválido y referencias externas incluidas las escapadas retiran la imagen anterior.
- Se corrigió el indicador de cambios tras Undo/Redo mediante notificaciones del UndoManager del documento.
- Revisión visual real en oscuro, en `.build/manual-project`: PNG de 1.254 × 1.254 se muestra completo y proporcional con dimensiones; SVG abre con selector nativo `Preview / Code`, código XML y número de línea. Cambiar azul a naranja en el XML y volver a Preview mostró inmediatamente el nuevo color y conservó el punto de cambios sin guardar.
- Pendiente de validación visual específica en claro, ventana mínima y VoiceOver. No se afirma compatibilidad con todas las construcciones SVG; se utiliza el renderizador estático nativo y se muestra error cuando no puede generar la vista previa. Los archivos grandes están limitados según README.
- La comprobación visual se intercaló con interacción del usuario en la aplicación; el ciclo completo de guardado/Undo está cubierto también por las pruebas de integración AppKit.

## MD-01 — Markdown y selector compartido (2026-09-23)

- Implementación delegada a Terra, revisada y verificada por el agente principal. Foundation analiza Markdown y AppKit presenta el texto; sin nuevas dependencias. SVG y Markdown usan un único selector nativo en la fila de la ruta, alineado a la derecha.
- Suite completa: 47 pruebas correctas. Las pruebas afectadas comprueban apertura de Markdown solo en Code, texto renderizado con separación de bloques y marcadores de listas, fuentes de énfasis, descarte de resultados anteriores y conservación del borrador, Undo y guardado al alternar vistas.
- Revisión real en `.build/manual-project/Markdown Preview.md`: apertura inicial en Code; alternancia a Preview y regreso; títulos, negrita, cursiva, listas, cita, enlace y código visibles en claro/oscuro. Selector en la fila de ruta y a la derecha, sin barra adicional. Al cambiar de pestaña se actualizan selector y árbol.
- Vista de lectura inicial: imágenes sin carga, HTML sin ejecución, sin presentación dedicada de tablas ni garantía de compatibilidad completa con extensiones Markdown. Texto fuente Markdown conserva el resaltado Plain Text actual. Límite de 5 MiB; análisis fuera del hilo principal y aplicación de estilos nativos en la interfaz.
- Pendientes: VoiceOver, listas anidadas complejas, tablas, imágenes, grandes documentos y mediciones de consumo. No se afirma equivalencia visual con GitHub ni con un navegador.

## LAYOUT-02 — Conservación de tamaños (2026-09-23)

- Regresión inicial reproducida: ocultar y mostrar terminal cambiaba su altura. NSSplitViewItem usa ahora prioridades de conservación dentro del rango permitido por AppKit; el centro/editor absorbe el espacio disponible. Se desactiva la fracción automática del lateral.
- Persistencia guarda los marcos de `NSSplitView.arrangedSubviews`, no el contenido interior de cada controlador. La diferencia era visible en el lateral nativo: perdía 8 puntos al reabrir. Restauración del panel derecho/inferior considera el grosor real de los separadores.
- Prueba enfocada final correcta: tamaños personalizados de lateral, asistente 350 y terminal 310; ocultación/reaparición y dos reaperturas consecutivas. Suite global de 47 pruebas correcta antes del último ajuste del marco del lateral; se repitió la prueba afectada después del ajuste.
- GUI final: fijados por controles accesibles nativos lateral 275, asistente 350 y terminal 310. Cerrar y reabrir el proyecto conservó exactamente las posiciones AX 275 / 574 / 469,5 (el segundo valor es ancho central, el tercero altura superior). Confirmado que abrir Markdown mantiene esa distribución.
- Comprobados también ocultar/mostrar asistente y terminal, y pasar de pantalla completa a ventana normal conservando sus dimensiones mientras el centro se reduce. Arrastre físico automatizado no completado; ajuste mediante AXValue nativo y persistencia sí comprobados. Siguen aplicándose los límites mínimos/máximos de los paneles.
- Release final empaquetado, firma ad hoc verificada y aplicación abierta con la muestra Markdown en Preview. No se descartaron borradores ni se editaron documentos del usuario durante la validación.

## UI-03 — Recorte del dibujo del editor (2026-09-23)

- Cambio visual acotado: `NSScrollView.clipsToBounds = true` para contener el dibujo del margen de números dentro del documento. Sin capas adicionales ni cambios de geometría, paletas o sidebar nativo.
- Release compilado y abierto. Revisión real en oscuro de Markdown Code y JSON: la cabecera queda libre de la prolongación vertical del margen; numeración, fila activa, pestañas y ruta permanecen visibles. Posiciones AX de paneles conservadas en 275 / 574 / 469,5.
- No se añadieron pruebas que reproduzcan una propiedad de AppKit; se verificó visualmente el efecto del cambio. La vista clara y VoiceOver no se repitieron para este ajuste de recorte.

## TERM-02 — Color funcional del prompt (2026-09-23)

- Implementación Terra, revisión e inspección GUI por el principal. Prompt estándar de zsh con carpeta violeta, símbolo verde o rojo y código de salida no nulo; cursor violeta. ANSI indexado se adapta a Dracula/Alucard. No se añade resaltado de comandos ni se reinterpreta la salida de programas.
- Bootstrap temporal por sesión: restaura ZDOTDIR y carga el .zshenv original antes del arranque normal. Un hook de una sola ejecución configura el prompt únicamente si sigue siendo el predeterminado de macOS y no hay hooks personalizados. Conserva bash/fish y NO_COLOR; CLICOLOR sólo recibe un valor por defecto si no hay preferencia heredada. Se limpia el temporal al terminar, cerrar o reiniciar.
- Seis pruebas con `/bin/zsh -ilc` y archivos temporales: prompt estándar, prompt/precmd personalizados, NO_COLOR declarado durante inicio, CLICOLOR personalizado, orden de los cuatro archivos de inicio y ausencia de marcadores exportados, representación ANSI y código de error. Suite completa ejecutada por el implementador: 53 pruebas correctas; código de las pruebas revisado por el principal.
- GUI real, proyecto `.build/manual-project`: prompt violeta/verde, ejecución de `false` con indicador rojo `[1]`, siguiente comando correcto devuelve verde; `ls` en TTY diferencia Sources en violeta. El proxy RTK sin TTY no fuerza colores, por lo que el listado se comprobó a través de `script -q /dev/null` conservando la detección TTY de BSD ls.
- Revisado en claro y oscuro sin reiniciar la sesión: los colores se adaptan y el contraste resulta legible. Se conserva el fondo del editor y los tamaños de paneles. Release empaquetado, firma ad hoc verificada, aplicación abierta en oscuro.
- Límites: sólo se personaliza automáticamente el prompt stock de zsh; los programas conservan su política de color. No hay resaltado de sintaxis mientras se escribe ni datos Git en el prompt. No se midió latencia/CPU; la integración no añade procesos por prompt. VoiceOver y shells de terceros sin zsh no se recorrieron en la GUI.

## CTX-01 — Agent Context local (2026-09-23)

- Motor determinista y panel AppKit implementados mediante agentes delegados, con revisión e integración del principal. Tercer botón `Agent Context` junto a `Files` y `TODOs`: fuentes en el lateral y detalle en el centro. Sin conexión de IA, credenciales ni nuevas dependencias.
- Suite completa: 81 pruebas correctas, incluidas 26 del motor y 2 de integración del panel. Cubren persistencia Markdown/JSON, activaciones, prioridad estable, herencia AGENTS, límites de carpeta/glob, Unicode por bytes, conflictos, enlaces simbólicos y presupuestos compartidos del catálogo. También pasan las pruebas existentes de tamaños personalizados de paneles. Tras el último ajuste de Escape se repitieron las 2 pruebas de UI; build release final y firma ad hoc verificados.
- GUI real en `.build/context-manual`: detección de 14 fuentes externas, creación y guardado de `Project Style`, activación explícita del AGENTS raíz y persistencia tras cerrar/reabrir. El archivo README muestra dos reglas y 704 bytes; el inspector muestra procedencia, exclusiones y el texto consolidado real. Escape cierra el inspector y devuelve el foco al editor en la compilación final.
- Cambiar de panel con metadatos sin guardar presenta Save/Don’t Save/Cancel; Cancel conserva el borrador. Una modificación externa del Markdown se detecta automáticamente, conserva el borrador abierto y evita sobrescribir el contenido nuevo. Se descartó únicamente el borrador creado para esta prueba. Datos persistidos comprobados en disco.
- Formulario revisado visualmente en claro y oscuro; inspector final revisado en oscuro con tamaño legible de 760 × 580. Se corrigieron restricciones de anchura, tamaño inicial del inspector y restricciones de una vista oculta que alteraban los paneles. Reabrir el proyecto conservó posiciones AX de separadores 250 / 649 / 579.
- Aplicación final empaquetada en `dist/FS Code.app` (aproximadamente 6 MB en disco). Para preservar la sesión de Codex en la terminal de la instancia original, la comprobación se hizo con una copia local de identificador independiente, `FS Code Context Validation.app`. La instancia original mantiene su ejecutable anterior hasta que el usuario la reinicie.
- Límites explícitos: importaciones Claude/Copilot, YAML complejo, resolución Gemini y ajustes Codex detectados pero no interpretados quedan señalados como no soportados; no se simula compatibilidad. Detalle en `docs/AGENT_CONTEXT.md`. No se realizaron benchmarks de CPU/RAM ni recorrido VoiceOver, alto contraste o ventana mínima. El tamaño en disco no representa consumo de memoria.


## Peticiones recientes y LLM-01 — validación en curso (2026-09-23)

- TODOs reales: 13 tareas añadidas a `.fscode/todos.json`, conservando `Accesos Directos`. Inspección GUI: 14 tareas abiertas, títulos en una sola línea, diez entradas iniciales y `Load More`.
- GUI de la compilación intermedia: árbol con `.build`, `.codebase-memory`, `.fscode`, `.DS_Store` y `.gitignore` visibles; carpetas contraídas sin expansión recursiva inicial.
- Biblioteca oculta al abrir FS editor. `Close Project` devuelve la biblioteca; reabrir conserva la disposición. Panel derecho ampliado a unos 539 puntos en una ventana de 1.200, superior al límite anterior de 460; posiciones AX de separadores conservadas tras cerrar/reabrir.
- `Connect Model…` y hoja nativa comprobados en oscuro; opciones ChatGPT OAuth/API Key y campo seguro sólo para API. No se introdujeron claves ni se completó OAuth en esta comprobación intermedia. La copia explicativa del formulario y la navegación a línea de TODO inline requieren revisión de la compilación final.
- Codex local 0.156.1: prueba real de App Server en un directorio temporal independiente, `initialize`/`initialized` y `account/read` correctos con cuenta vacía. No se leyó ni reutilizó la autenticación de Codex del usuario.
- Esta validación utiliza `.build/FS Code LLM Preview.app`, con identificador propio, para preservar la sesión de terminal de la aplicación original. La prueba del protocolo sin cuenta no demuestra autenticación completa, disponibilidad del catálogo de una cuenta ni una solicitud de conversación.

- Primera tanda nativa UI/ProjectLibrary: 38 pruebas ejecutadas; 36 correctas y dos fallos de persistencia detectados al cambiar el panel derecho a inspector nativo. La resta duplicada del separador causaba una deriva acumulativa de un punto por reapertura. Corregida la fórmula; repetición enfocada de `WorkspaceLayoutTests`: 2/2 correctas. No se aumentó la tolerancia de las pruebas.
- Se cerraron TODO-03, TODO-04, FILES-02 y NAV-02 en la lista real. La procedencia inline y el salto de línea están cubiertos; el scanner automático sigue pendiente en TODO-05.
- Diagnóstico de la nueva suite: la prueba mínima dejó de abortar al sustituir la sobrecarga `Task.sleep(for:)` por `Task.sleep(nanoseconds:)`, conservando duración/cancelación. Existe un [reporte relacionado en Swift](https://github.com/swiftlang/swift/issues/86204). Toolchain local: Apple Swift 6.4; esta coincidencia no se presenta como garantía de que todo fallo de concurrencia esté resuelto. Se continúa con la suite completa y el transporte real.

- Prueba real adicional contra Codex 0.156.1 en `CODEX_HOME` temporal: `thread/start` acepta `sandbox: "read-only"`, `approvalPolicy: "never"` y configuración `project_doc_max_bytes: 0` / proyecto no confiable. Devuelve un hilo real, `sandbox.type: readOnly`, `networkAccess: false` e `instructionSources: []`. No se inició un turno ni se utilizaron credenciales; el proceso y los datos temporales se retiraron. Esto valida la configuración inicial, no una respuesta del modelo.

### Cierre de pruebas de conexiones y chat

- Suite completa ejecutada por el principal con `rtk proxy swift test --build-system native`: **108 pruebas correctas**, 95 de XCTest y 13 de Swift Testing, sin fallos. Incluye 7 casos de conversaciones, el transporte con procesos simulados y la regresión de anchura/persistencia de paneles.
- El aborto de las pruebas de conexión se aisló al wrapper asíncrono de XCTest: el mismo caso, con las mismas operaciones y aserciones en Swift Testing, pasó. Se migró esa suite; el transporte de producción conserva continuaciones por eventos, sin polling diagnóstico. Se retiraron los logs y residuos de diagnóstico.
- Cubiertos: mensajes JSON parciales/coalescidos, colisión entre identificadores de solicitudes del servidor/cliente, cancelación, timeout, EOF/salida inesperada, cambio de perfil, OAuth simulado y catálogo paginado, metadatos sin secretos, almacenamiento corrupto y rollback de escritura. Conversaciones: streaming antes de confirmar el turno, hilos independientes, Stop, descarte de eventos de otra cuenta, persistencia/reanudación, reglas inesperadas, borrador excesivo e identificador de turno inválido.
- Cierre: `flush()` antes de cerrar proyecto o terminar la aplicación; errores de guardado mantienen la ventana abierta. Cmd-Q espera la liberación de los asistentes sólo después de que todas las ventanas hayan aprobado cerrar. Estas rutas se revisaron en código; la prueba GUI con un borrador autenticado queda pendiente.
- La suite usa procesos y respuestas controlados para autenticación y turnos. No sustituye la verificación con la cuenta real; todavía no se declara un turno autenticado satisfactorio.
- Release final construido con `scripts/build-app.sh`; firma ad hoc verificada con `codesign --verify --deep --strict`. Se cerró sólo la copia LLM Preview sin trabajo activo. La aplicación principal, que ya no estaba ejecutándose, se abrió desde `dist/FS Code.app` y se dejó en el proyecto FS editor.
- GUI final en oscuro: biblioteca oculta, árbol con archivos ocultos, panel Assistant, disclosure Connection rotulado y chat visible. Se creó el perfil ChatGPT desde la hoja real. Codex devolvió el flujo OAuth y abrió la página oficial de acceso en `auth.openai.com`; la aplicación muestra `Finish sign-in in your browser.` Se solicitó al usuario completar el acceso. API real, catálogo autenticado y turno real siguen pendientes.

### Primer turno autenticado y nueva revisión

- El usuario completó el acceso. La aplicación mostró la cuenta conectada y catálogo real con GPT-6-Astra y pensamiento Medium. Desde `New Chat` se envió una petición breve sin leer archivos ni usar herramientas; el estado pasó por Thinking y terminó con la respuesta real `FS Editor conectado.`. La conversación quedó en el historial local. Esta prueba reemplaza la limitación anterior sobre ausencia de turno autenticado; API key real no se probó.
- El usuario detectó un flujo confuso al volver del navegador y criticó la distribución de controles. Se está revisando el final de OAuth, la primera conversación automática y el panel inspirado en Cursor. También pide cuentas separadas por proyecto y edición real revisable; las 108 pruebas corresponden a la compilación previa a estos nuevos cambios.
- Sondeo real sin cuenta en un `CODEX_HOME` temporal: `initialize.capabilities.experimentalApi: true` y `thread/start.dynamicTools` con la función `fs_edit_file` son aceptados por Codex 0.156.1; devuelve sandbox readOnly, networkAccess false e instructionSources vacío. Se generaron esquemas con `generate-json-schema --experimental`, ya que el esquema normal omite ese campo. No se usaron credenciales ni se inició un turno en este sondeo.

## Conexiones por proyecto y About — 23 de septiembre de 2026, actualización

- Cuenta e historial de FS editor recuperados tras migrar únicamente sus metadatos globales a `.fscode/connections.json`; no se leyeron ni copiaron secretos.
- Proyecto de prueba distinto abierto: muestra Connect Model sin heredar conexiones. Volver a FS editor conserva su cuenta.
- About estándar verificado visualmente: icono, 0.1.0 Alpha, autoría, copyright y enlaces. MIT y avisos de terceros coinciden con archivos fuente; firma ad hoc verificada.
- Suite anterior a rich Markdown/paneles rectos: 118 pruebas correctas.
- Primera prueba real de fs_edit_file detectó fallo antes de aprobación: JSON-RPC ID 0 se confundía con Bool. Corregido con discriminación CoreFoundation y regresiones 0/1/string/Int64/true; el archivo temporal quedó intacto. Repetición end-to-end pendiente.
- Suite con rich Markdown/paneles rectos: 118 de 119 correctas; detectó mínimo intrínseco del asistente (366 frente a 350 solicitados). Corrección en curso; no se declara validación final.

## Flujo real del agente y presentación — actualización final en curso

- Tras corregir IDs JSON-RPC, GPT-5.6-Luna llamó `fs_edit_file` desde el chat real sobre `.fscode-agent-check.txt`.
- Antes de aprobar, el archivo seguía intacto. La hoja nativa mostró el diff exacto; Apply escribió el reemplazo y el editor abierto se recargó. SHA-256 coincide con el registro aplicado.
- Change history → Revert restauró exactamente contenido y hash originales, conservando el registro con estado reverted.
- Respuesta real con título, lista y bloque de código se verificó visualmente en claro y oscuro; sin centrado ni selección azul de la fila. Barras nativas de chat/árbol/editor superpuestas sin columna permanente; paneles internos rectos.
- 119 pruebas correctas (101 XCTest +18 Swift Testing); release optimizada y firma válidas. El inicializador del botón Copy requirió evitar una ruta del optimizador Swift 6.4; compilación release comprobada tras el ajuste.
- La prueba visual detectó que faltaba conectar el estado ✦ con Workspace; se añadió el enlace y queda por comprobar en el paquete final.

## Paquete final verificado

La segunda edición real confirmó ✦ en árbol y pestaña, con selección del archivo conservada. Revert eliminó ambas marcas y restauró el contenido; el archivo temporal se retiró después, conservando los dos registros reverted. La corrección final de conexión visual pasó 7 pruebas enfocadas (UI, Markdown, layout), release optimizada y codesign. El código completo previo pasó 119 pruebas. No se afirma validación de API key real, tablas Markdown avanzadas, todas las preferencias de accesibilidad ni shell con escritura. Se registró el seguimiento de respuestas largas como acabado pendiente.


## AGENT-02 — revisión por bloques (2026-09-23)

- Suite completa: 124 pruebas correctas (101 XCTest + 23 Swift Testing), ejecutadas con `swift test --build-system native`.
- Pruebas del servicio: bloques separados en ambos órdenes de reversión; edición manual intermedia que desplaza líneas; inserciones, eliminaciones, archivo nuevo, Unicode/CRLF, coincidencias ambiguas, historial anterior, fallback acotado y recuperación de reversión parcial.
- Pruebas de conversación: aplicación automática sin callback de revisión, trazabilidad por turno, reversión individual, protección de borrador y rechazo de respuesta obsoleta al cambiar de cuenta.
- Compilación optimizada, empaquetado y `codesign --verify --deep --strict` correctos.
- La verificación GUI del flujo nuevo sigue pendiente: el Mac estaba bloqueado al intentar acceder. El flujo de aprobación anterior sí se verificó antes; no equivale a validar esta interfaz nueva.

- Después de la revisión final: 2 pruebas UI enfocadas adicionales correctas (`AgentChangePresentationTests`): marcadores de dos bloques, refresco tras revertir uno, controles dentro de 340 pt, acceso a Original con bloque invalidado, reversión deshabilitada y rango vacío al final del archivo. Total cubierto en esta entrega: 126 pruebas (suite completa de 124 más 2 nuevas enfocadas). Estas pruebas no sustituyen la inspección visual en pantalla.


## UPD-01 — Sparkle (23 de septiembre de 2026)

- Suite nativa completa: 129 pruebas correctas (106 XCTest y 23 Swift Testing); incluye tres casos de configuración ausente, parcial/inválida y válida sin arrancar conexiones.
- Compilación release y empaquetado correctos; firma ad hoc verificada con `codesign --verify --deep --strict`.
- Verificados enlace a Sparkle, rpath de Frameworks, symlinks conservados, copia idéntica de avisos y plist sin endpoint ni clave ficticios. Comprobaciones e instalaciones automáticas desactivadas por defecto.
- Se cerró la copia anterior usando Cmd-Q y se abrió el paquete nuevo: mostró la biblioteca sin error de carga ni alerta de actualización. Mediante el árbol de accesibilidad se confirmó `Check for Updates…` deshabilitado después de About. No se obtuvo captura visual del menú.
- Revisión de código: se conserva la protección existente de cierre con documentos modificados; Sparkle solicita cierre normal de macOS. Esto no sustituye una prueba real de actualización con borradores.
- Pendiente UPD-02: repositorio/URL real, clave de firma, distribución Developer ID/notarizada y prueba de actualización entre versiones. No se publicaron artefactos ni se instaló una actualización real.


## CHAT-04 — pestañas y composición del asistente

- Implementación delegada a Terra, revisión del principal y segunda revisión independiente de Terra. Sin nuevas dependencias ni cambios en el protocolo/harness.
- Suite completa: 131 pruebas correctas (108 XCTest + 23 Swift Testing). Tras ajustes finales exclusivamente visuales, 29 pruebas FSCodeTests correctas, incluyendo límites del panel de 340 y 760 puntos y estado aislado por proyecto/perfil.
- Release optimizada empaquetada; `codesign --verify --deep --strict` correcto.
- GUI real: crear pestaña, cambiar conversación, escribir borrador, cerrar pestaña y reabrirla desde historial conserva el texto. Cmd-Q, relanzar y abrir el proyecto restaura ambas pestañas, selección y borrador. El catálogo real permitió cambiar a GPT-5.6-Luna.
- La revisión visual en oscuro identificó superficies inconsistentes por la vibrancia de NSVisualEffectView. La corrección final cambia el contenedor de contenido a NSView opaco y usa colores semánticos coherentes. Esa corrección compila y pasa pruebas, pero aún no fue inspeccionada en pantalla.
- CUA dejó de responder al intentar una prueba nueva de envío; también dieron timeout los intentos de reconectar la ventana por bundle ID y ruta, incluso tras reiniciar la sesión de control. La muestra del proceso mostró el hilo principal en espera normal de eventos y 70,6 MiB de huella. El borrador de verificación seguía guardado y no se creó el mensaje de prueba. No se afirma haber validado un turno real nuevo.
- Pendiente: relanzar la última build para inspeccionar fondos finales en claro/oscuro, redimensionado y scroll con streaming. La copia que quedó abierta precede al último ajuste de fondos; no se forzó su cierre.
- Límites deliberados: el último tab no se cierra; cerrar uno no elimina el hilo. Cambiar hilo/crear otro permanece deshabilitado durante respuesta activa según el motor actual; no se añadió ejecución simultánea.


## CHAT-05 — selectores, contexto y actividad por turno

- Núcleo implementado por Terra y revisado independientemente; acabado de UI y fixture por Sol tras detectar entregables incompletos. Principal revisa, ejecuta las pruebas e inspecciona imágenes. Sin dependencias nuevas.
- Suite completa: 138 pruebas correctas (115 XCTest + 23 Swift Testing). Tras corregir presentación y despliegue de actividad, 30 pruebas FSCodeTests correctas.
- Contexto real: `thread/tokenUsage/updated`, entrada de `last` dividida por `modelContextWindow`. Desconocido si falta la capacidad; no representa consumo de suscripción. Pruebas de JSON numérico 0/1/boolean/fraction, aislamiento, eventos tardíos, cambio de modelo e historial anterior. No se envió un turno nuevo con la cuenta real durante esta revisión.
- Comentarios y respuesta final se conservan como mensajes distintos según item del runtime. Actividad vinculada al mensaje de usuario y turno: fase/operación, estado, duración observada y salida final limitada; sin contenido interno de razonamiento. Las salidas de comandos se presentan al completar el item, no como streaming de cada fragmento.
- Selectores de cuenta, modelo y pensamiento mediante menús nativos en el compositor; distribución de una fila amplia y dos estrechas. Connect Model abre directamente su hoja y Manage Connections usa el control visible como ancla.
- Fixture de AppKit con almacenamiento temporal, transporte simulado, dos turnos, Markdown y actividad/contexto. Exporta PNG de 340/760 puntos claro/oscuro y un estado plegado; inspección encontró y corrigió altura del desplegado y placeholder. Prueba de crecimiento de fila al expandir y presencia de salida seleccionable. Los datos de ejemplo son exclusivamente de prueba, no respuestas reales.
- Artefactos reproducibles: `FS_CODE_RENDER_CHAT_PREVIEWS=1 swift test --build-system native --filter FSCodeTests`; imágenes en `.build/chat05-previews`. No equivalen a un recorrido completo en la app abierta ni a verificar VoiceOver.
- CUA continúa agotando el tiempo de espera al acceder a FS Code. No se forzó el cierre ni se alteró la sesión abierta. Pendiente: abrir la última aplicación y comprobar menús/teclado, respuesta autenticada con telemetría y scroll durante streaming. La ejecución en reposo del proceso anterior no prueba rendimiento del nuevo panel.

Paquete CHAT-05 final: compilación release y `codesign --verify --deep --strict` correctos; aplicación en `dist/FS Code.app`. Última tanda de 30 pruebas UI correcta, con Extra High legible a340 puntos y capturas estabilizadas antes del primer render. No se relanzó la copia abierta debido al bloqueo de CUA.


## CHAT-06 — controles inline y compositor compacto (24 de septiembre)

- Implementación visual delegada a Terra; principal revisa código, pruebas y capturas. Sin cambios en el núcleo del agente ni dependencias nuevas.
- Un único contenedor con relleno semántico, entrada de 48 puntos y una fila de controles. Selectores nativos sin cajas individuales y chevrons para modelo/pensamiento; mensajes del usuario con relleno sutil.
- Pruebas enfocadas: 30 FSCodeTests correctas. Fixture temporal con GPT-5.6-Sol y Extra High, claro/oscuro, 340/760 puntos, actividad plegada/desplegada. Se verifican controles sin borde, alineación, límites y crecimiento de actividad; revisión visual corrigió recorte del nivel de pensamiento. No se vuelve a ejecutar el motor completo por tratarse de cambios locales de presentación.
- Capturas en `.build/chat06-previews`, generadas con `FS_CODE_RENDER_CHAT_PREVIEWS=1 swift test --build-system native --filter FSCodeTests`. Son vistas AppKit con datos de prueba, no un turno autenticado.
- La consulta de la ventana con CUA sigue dando timeout. Pendiente revisión en la aplicación abierta de foco, menús y sesión real. No se fuerza cierre ni se afirma haber relanzado la aplicación.

CHAT-06 implementada y empaquetada: 30 pruebas UI correctas en la ejecución final; release y verificación de firma correctos. Controles en una fila, Extra High completo, contexto como anillo a 340 puntos y porcentaje visible al ampliar. Capturas AppKit revisadas en claro/oscuro y actividad plegada/desplegada. Pendiente recorrido en ventana real por timeout de CUA; no se relanzó la app.

Limitación del fixture: una captura estrecha clara todavía omite el dibujo de la pestaña aunque la vista existe y sus límites son correctos; otras capturas sí la muestran. La estabilización del primer render no permite declarar resuelta esta discrepancia sin revisar la ventana real. No se cambió el código de pestañas en CHAT-06.

## CHAT-07 — cola por conversación y Steer (24 de septiembre)

- Implementación delegada a Terra con propiedad separada de núcleo y UI/pruebas; principal verifica esquema, revisa carreras e integración y ejecuta SwiftPM. Sin dependencias nuevas.
- La entrada sigue editable durante el turno. Enviar/Command-Return encola; lista acotada sobre el compositor con Steer y eliminación individual. Stop permanece separado. Cola persistida por conversación/perfil/proyecto, compatible con JSON previo. Reinicio restaura en pausa; Resume es explícito.
- Steer usa `turn/steer`, identidad capturada de perfil/sesión/turno, `expectedTurnId` y UUID del mensaje en `clientUserMessageId`. No cambia modelo, esfuerzo ni permisos, ni interrumpe/reinicia el turno. Fuente: [Codex App Server](https://learn.chatgpt.com/docs/app-server), contrastada con los esquemas locales instalados.
- La revisión corrigió bloqueo del avance por su propio cerrojo, estado visible atrasado tras aceptación, errores/drain aplicados a selección equivocada, notificación tras liberar operaciones y drenado durante cierre de la ventana.
- Suite final completa: 147 pruebas correctas (124 XCTest + 23 Swift Testing). Nueve pruebas nuevas cubren FIFO, Steer aceptado, finalización antes de respuesta de Steer, rechazo manteniendo turno activo, cambio de perfil con respuesta tardía, envío concurrente, Stop, restauración pausada y fallo al iniciar un mensaje pendiente. Transporte simulado, sin solicitudes pagadas.
- Fixture AppKit inspeccionado a340/760 puntos, claro/oscuro, con dos mensajes pendientes y borrador adicional. Verifica compositor editable, Send/Stop, Steer, Resume y Remove mediante callbacks reales de las vistas con transporte simulado. Imágenes: `.build/chat07-previews`; comando: `FS_CODE_RENDER_CHAT_PREVIEWS=1 swift test --build-system native`.
- CUA volvió a agotar su espera al consultar FS Code. Pendiente recorrido autenticado en la aplicación abierta; los renders y las pruebas no sustituyen esa comprobación. No se forzó el cierre ni se relanzó la sesión del usuario. La discrepancia ocasional del dibujo de pestañas en el fixture claro continúa documentada en CHAT-06.

CHAT-07: paquete release generado en `dist/FS Code.app`; `codesign --verify --deep --strict` correcto. No se relanzó automáticamente la aplicación abierta.

## CHAT-08 — Enter y visibilidad del mensaje enviado (24 de septiembre)

- Implementación UI/pruebas delegada a Terra; principal revisa y ejecuta la validación. Sin cambios en el núcleo ni dependencias.
- Enter envía o encola; Shift+Enter inserta una línea; Command-Return sigue disponible. Return con texto marcado permanece en el manejo nativo del método de entrada. Ayuda accesible en inglés.
- Envío y Steer aceptado revelan el mensaje propio por UUID y conversación/perfil. La corrección de layout contempla las alturas automáticas del NSTableView con hasta tres pasadas acotadas, sin temporizadores periódicos ni recálculo del historial completo. La devolución del foco ocurre al pulsar la acción, no cuando llega una respuesta tardía.
- 31 FSCodeTests correctas. Después del último ajuste de visibilidad completa para filas menores que el viewport, las dos AssistantChatPreviewTests vuelven a pasar. Regresión con 34 mensajes previos: desplazarse al inicio, enviar por el botón real y comprobar que la fila nueva queda completamente visible sin scroll manual del test. Enter ocupado, Shift-Enter y texto marcado se ejercitan mediante eventos AppKit locales y transporte simulado.
- Logs: `.build/chat08-ui-tests.log` y `.build/chat08-final-tests.log`. Fixture generado en `.build/chat07-previews`; no representa una conversación autenticada. El seguimiento de streaming desde historial antiguo y la cola que excede su altura visible no tienen una nueva prueba dedicada en esta entrega.
- CUA permanece bloqueado por timeout en intentos previos. No se repite ni se fuerza el cierre de la sesión del usuario; queda pendiente la comprobación en la ventana real, especialmente foco y scroll durante streaming.

CHAT-08: paquete release generado en `dist/FS Code.app`; verificación `codesign --verify --deep --strict` correcta. No se relanzó automáticamente la aplicación abierta.

## CHAT-09 — progreso público y respuestas con color (24 de septiembre)

- Dos Terra implementaron núcleo y renderer/UI; principal revisó protocolo, aislamiento, formato y ejecutó la suite. Sin nuevas dependencias para esta entrega.
- Resúmenes públicos transitorios, limitados a 4 KiB, asociados al turno y reemplazados por sección; no se consume `reasoning/textDelta` ni contenido bruto. Comentarios y final conservan fase opcional compatible con historiales anteriores. Stop, final y cambio de perfil limpian el progreso; eventos tardíos no lo reactivan.
- Enlaces seguros con color y subrayado nativos, rutas/código distinguibles, citas opacas indicadas como `Source unavailable` sin inventar URLs y tablas como texto con separadores. Se conservan tablas literales dentro de bloques de código. No es un renderer de tablas con cuadrícula ni resaltado completo de sintaxis de código.
- Suite completa: 156 pruebas correctas (133 XCTest + 23 Swift Testing), log `.build/chat09-full-tests.log`. Pruebas de fases, límite, Stop, reemplazo, eventos tardíos, almacenamiento antiguo, atributos de Markdown y eventos reales del transporte simulado hacia AppKit. La prueba de render recorre 340/760 puntos, claro/oscuro.
- Capturas de progreso/final en `.build/chat09-previews`; principal inspecciona los fixtures. Persisten las limitaciones conocidas del dibujo de pestañas en algunas capturas. No equivalen a conversación autenticada ni recorrido en la app real; CUA agotó su espera en intentos anteriores.
- Paquete release CHAT-09 y verificación de firma correctos. No se relanzó la sesión del usuario. La migración posterior a AgentRunKit es una tarea separada autorizada después de esta validación.


## HARNESS-01 — primer motor nativo, 24 septiembre 2026

- Producción: AgentEngine → NativeAgentRuntime → clientes AgentRunKit 6.0.0, sin proceso Codex para las ventanas de proyecto.
- `swift test --build-system native`: 144 pruebas XCTest (1 visual omitida), 23 Swift Testing; cero fallos. Log `.build/native-integration-tests.log`.
- Prueba integral con proveedor/vault simulados: conexión, conversación, modificación real de `sample.txt` mediante servicio auditado, y rechazo de credenciales de otro projectID. Catálogo respeta capacidades recibidas. Persistencia: restauración de llamada interrumpida sin ejecutarla, aislamiento por perfil y comienzo sin historial previo.
- `bash scripts/build-app.sh`: release generado; `codesign --verify --deep --strict` aprobado. Log `.build/native-integration-package.log`.
- Aplicación lanzada desde `dist/FS Code.app`; CUA confirmó ventana `FS Code — Projects` y biblioteca existente. No se completó revisión visual del chat ni recorrido autenticado con cuenta real.
- OAuth, cancelación y renovación comprobados parcialmente con dobles; el flujo real y el catálogo de ChatGPT requieren prueba del usuario. No se importaron credenciales de Codex.
- Subagentes, comandos aprobados, preguntas interactivas y resúmenes públicos de pensamiento del motor nuevo siguen pendientes. No hay medición comparativa de RAM.


## OAuth de navegador — 24 septiembre 2026

Sustituido el flujo predeterminado por autorización de navegador con PKCE S256 y callback local `localhost:1455/auth/callback`. Listener exclusivo de loopback, state por intento, cancelación y expiración; error de puerto ocupado y denegación sin datos sensibles. La aplicación recupera el foco al conectar o fallar. No inicia device-auth ni requiere activar ese ajuste.

Validación: 9 pruebas enfocadas aprobadas, incluidas vuelta por HTTP local e intercambio simulado a través del gestor de conexiones. Suite completa: 150 XCTest (1 visual omitida) + 23 Swift Testing, cero fallos. Logs `.build/browser-oauth-tests.log` y `.build/browser-oauth-full-tests.log`. Release generado y firma local verificada; app cerrada normalmente y relanzada desde `dist/FS Code.app`. Log de paquete `.build/browser-oauth-package.log`.

Pendiente: completar autorización real con la cuenta del usuario. Las pruebas usan credenciales y respuestas simuladas y no acreditan todavía el acceso real al servicio.


## Catálogo ChatGPT real — 24 septiembre 2026

Separado `client_version` del catálogo (compatibilidad 0.153.4) de la versión de FS Editor (0.1.0). Se conserva el listado obtenido del servicio; no hay modelos inventados ni lectura de credenciales desde herramientas. Seis pruebas enfocadas aprobadas (`.build/catalog-fix-tests.log`); release empaquetado y firma verificada (`.build/catalog-fix-package.log`).

App reiniciada normalmente, proyecto FS editor abierto: CUA confirmó chat conectado, selector GPT-5.6-Luna y respuestas visibles. No se repitió OAuth ni se enviaron mensajes de prueba adicionales; el usuario estaba interactuando con el chat. El error de catálogo vacío desapareció.


## Validación real del streaming corregido — 24 septiembre 2026

La reconstrucción desde output_item.done resolvió el fallo real con GPT-5.6-Luna y la cuenta ChatGPT del proyecto. La app compilada quedó abierta. CUA confirmó varios turnos completados sin banner de error ni cola pausada; New chat y el compositor volvieron a estar disponibles. El usuario pidió crear test.txt con hola mundo: el agente ejecutó la edición, mostró Changed files y el editor marcó ✦ 1/1. Se verificó en disco que test.txt contiene exactamente hola mundo. Ese archivo pertenece a la prueba solicitada por el usuario y se conserva.

Suite final: 157 XCTest (1 visual omitida) + 23 Swift Testing, cero fallos. Nueve pruebas específicas de NativeAgentRuntime incluyen terminal vacío reconstruido desde elementos completos, rechazo de contenido divergente y rechazo de response.incomplete. Logs: `.build/lite-stream-tests.log`, `.build/lite-stream-full-tests.log`, `.build/lite-stream-package.log`. Firma verificada con codesign --verify --deep --strict. No se usó Codex CLI para ejecutar el chat.

## Reconciliación de reasoning — 24 septiembre 2026

Una prueba real posterior al primer parche devolvió OK pero terminó en `stream-state-mismatch`. Se corrigió en la copia fijada de AgentRunKit la publicación prematura de reasoningDetails: ahora proceden de la respuesta terminal, sin comparar metadatos provisionales que pueden cambiar. Texto y herramientas conservan reconciliación estricta. La prueba SSE reproduce metadatos distintos entre output_item.done y response.completed y comprueba persistencia única del objeto final.

Suite completa: 154 XCTest (1 visual omitida) + 23 Swift Testing, cero fallos. Logs: `.build/responses-reconcile-full-tests.log` y `.build/responses-reconcile-package.log`. Release empaquetado y firma verificada. La app nueva está abierta, pero la comprobación real de cierre queda pendiente: macOS bloquea SecItemCopyMatching esperando autorización del llavero tras cambiar la compilación de desarrollo. No se acredita todavía como resuelto en uso real.

## Cierre de Responses — 24 septiembre 2026

Verificación posterior al acceso al llavero: el parche de metadatos de reasoning no basta. Un turno real GPT-5.6-Luna devolvió OK y falló todavía. Diagnóstico por campo confirmó `stream-mismatch-content`. Se está incorporando reconstrucción estricta desde los eventos output_item.done cuando el terminal omite output; no aceptar EOF ni texto parcial como cierre correcto.

Se corrigió la validación que exigía `.streamClosed` al cliente Responses de AgentRunKit, que emite `.finished` y termina el stream sin ese evento adicional. Se sigue exigiendo terminación semántica y se rechaza un marcador explícitamente negativo; las herramientas sólo se ejecutan después de validar el stream.

Prueba de regresión mediante ResponsesAPIClient real con transporte URLProtocol/SSE: respuesta completada sin marcador adicional, sin error y sin duplicar el texto. También cubierto el marcador negativo persistente y la prohibición de ejecutar herramientas en un stream sin finalización. Seis pruebas enfocadas y suite completa aprobadas: 154 XCTest (1 visual omitida) + 23 Swift Testing, cero fallos. Logs `.build/stream-fix-tests.log`, `.build/stream-fix-full-tests.log`; paquete `.build/stream-fix-package.log`, firma local verificada.


## CHAT-10 — archivos, adjuntos y restore points (24 septiembre 2026)

- Enlaces locales en respuestas abren el editor mediante callback de la ventana; cada turno auditado presenta `Modified Files (N)` y `Restore Point`. Contexto arrastrado visible en chips removibles y persistido por conversación. Sin nuevas dependencias.
- Restauración al estado anterior al turno seleccionado, incluyendo cambios posteriores del mismo chat sobre los archivos afectados. Snapshots y hashes auditados, preflight de todos los archivos, protección de borradores y cambios externos/de otra conversación. Preparación persistente y recuperación guardada ante fallos; no se promete atomicidad del sistema de archivos entre varios archivos.
- Suite completa: 162 XCTest (1 visual omitida) y 28 Swift Testing, cero fallos. Log `.build/chat10-tests.log`. Cubre múltiples archivos, ediciones repetidas, creación/reversión, persistencia, conflictos, borradores, aislamiento de chats y límites de adjuntos. Release en `.build/chat10-package.log`, firma local verificada.
- App real abierta: comprobado el listado de archivos modificados en historial antiguo. Durante validación el usuario arrastró `test.txt` y recibió una respuesta que muestra su contenido y enlace local; el archivo estaba abierto en el editor. Se detectó que el título automático incluía el sobre de contexto y se solicitó corrección. No se atribuye al test automatizado un clic de enlace real ni una restauración desde el diálogo: ambos recorridos GUI quedan pendientes, dado que el usuario retomó la aplicación. Los dos archivos temporales de validación se retiraron intactos; `test.txt` del usuario se conserva.
- Adjuntos externos: sólo texto UTF-8 acotado (1 MB por archivo, 4 MB por borrador, máximo 8). Archivos del proyecto como referencias a su versión guardada; imágenes multimodales pendientes.

Ajuste final CHAT-10: títulos automáticos excluyen el sobre de adjuntos y se reparan al cargar los títulos antiguos que contienen ese marcador. 33 pruebas enfocadas aprobadas, cero fallos (`.build/chat10-title-tests.log`). Release recompilado y firma verificada (`.build/chat10-title-package.log`). No se reinició la sesión activa del usuario; ese último ajuste estará disponible al volver a abrir la app.


## CHAT-11 — ancho, redimensionado y seguimiento (24 septiembre 2026)

- Regresión real confirmada por informes 12:18, 12:21 y 12:32: NSTableRowData/CoreAutoLayout al mover el divisor. El primer parche de altura automática no resolvió el cierre; no se considera validado.
- Corrección final: NSTextView con altura medida fuera de intrinsicContentSize, sin cambio de geometría síncrono desde el cálculo intrínseco. Filas con altura explícita cacheada y medición asíncrona de la celda configurada; invalidación por contenido, ancho y desplegables; protección contra callbacks de celdas anteriores.
- Seguimiento persistente del final, restaurado al enviar, con scroll después de medir. Intención de desplazamiento manual mediante didLiveScrollNotification, no por cambios de geometría de la vista.
- Validación final: 39 FSCodeTests, 1 visual omitida, cero fallos. Regresión 340/760 repetida en claro/oscuro, ancho del contenedor, texto sin recorte, filas que crecen/reducen y visibilidad final tras streaming. Log `.build/chat-resize-final-tests.log`. Release y codesign correctos, `.build/chat-resize-final-package.log`.
- No se acredita todavía el recorrido final de divisor en la app real: al intentar relanzar la compilación final, CUA informa que el Mac está bloqueado y requiere desbloqueo manual. Paquete actualizado en `dist/FS Code.app`; queda pendiente relanzarlo y comprobar la sesión real.
