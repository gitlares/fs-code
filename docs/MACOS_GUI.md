# Organización nativa de macOS

Requisito permanente confirmado por Daniel el 23 de septiembre de 2026. Aplica a toda la GUI y a todas las futuras contribuciones. El documento define criterios del producto; no afirma que el prototipo ya los cumpla todos.

## Organización

- Modos del agente: selector compacto `Build` / `Plan` / `Ask` en el compositor, por conversación; no cambiarlo durante un turno o con mensajes en cola. `Plans` ocupa una pestaña propia del lateral: lista de planes y estado, Markdown editable en el centro, referencias a archivos y `Approve and Run` / `Run`. Al salir con cambios, ofrecer Save / Don’t Save / Cancel.
- `Agent Context → System Prompts` permite consultar y editar Shared y cada modo, mostrando versión y revisión. Restablecer una sección deja un borrador que debe guardarse; editar prompts no concede permisos al agente.

- La biblioteca de proyectos es la entrada de la aplicación. Registrar una carpeta y darle un nombre es el flujo principal. Se oculta al abrir un proyecto y reaparece al cerrarlo o cambiarlo.
- La barra de título y `NSToolbar` orientan sobre el proyecto y reúnen acciones principales. Conservar controles de ventana estándar y espacio para arrastrarla. Las acciones locales permanecen cerca de su contenido.
- El lateral izquierdo permite alternar `Files`, `TODOs` y `Agent Context`, con una única selección reconocible. Listas y árboles usan selección, expansión, desplazamiento y navegación de teclado nativos. Agent Context organiza las fuentes en el lateral y utiliza el centro para editar su detalle; el inspector del archivo activo es una vista de consulta separada.
- Los archivos abiertos usan pestañas alineadas a la izquierda con icono y nombre. La ruta del archivo activo aparece en una fila nativa debajo; conservar el indicador de cambios y proteger borradores al cerrar.
- Las imágenes se abren en pestañas del área central con ajuste proporcional, fondo semántico y dimensiones visibles. SVG y Markdown comparten un selector nativo `Preview / Code`, en la misma fila de la ruta y alineado a la derecha. Alternar conserva el editor, borrador y Undo. SVG comienza en Preview y Markdown en Code. Las imágenes raster son de solo lectura.
- El centro es el contenido principal. Seleccionar un TODO abre su detalle allí: título, estado, prioridad, descripción y comentarios. Fecha, vínculo y eliminación quedan en acciones secundarias. Evitar duplicar títulos, controles o barras sin una función.
- Los cambios de IA se aplican directamente y se revisan después: archivos y rangos identificados por el editor, marca ✦ y resaltado de bloques. El usuario puede navegar entre bloques, consultar su contenido anterior y revertir uno sin aceptar/rechazar el archivo completo. Proteger los borradores y las modificaciones posteriores.
- El árbol muestra también archivos y carpetas ocultos. La lista de TODOs muestra sólo títulos; los vínculos de origen inline son de sólo lectura y abren el archivo y su línea.
- Paneles internos rectos, sin marcos ni esquinas redondeadas decorativas. Separadores finos nativos delimitan navegación, editor, terminal y asistente. Decisión explícita del usuario del 23 de septiembre de 2026; sustituye cualquier propuesta anterior de laterales redondeados.
- Barras de desplazamiento superpuestas y ocultación automática; evitar reservar una columna permanente. Respetar las preferencias de visibilidad y accesibilidad del sistema.
- Terminal debajo del contenido central; asistente a la derecha. El usuario puede dar al asistente más de 460 puntos de ancho; no imponer un máximo arbitrario mientras quede un centro utilizable. Separadores nativos, paneles plegables y conservación de una superficie útil de trabajo al redimensionar.
- Agrupar por función, alinear etiquetas y controles y usar espaciado consistente. Priorizar lectura y edición; mantener visibles las acciones frecuentes y accesibles las secundarias.
- Asistente: pestañas de conversaciones e historial en cabecera; cerrar una pestaña conserva el hilo y el borrador. Mensajes del usuario con fondo discreto y respuestas abiertas alineadas a la izquierda. Compositor integrado en la parte inferior con conexión, modelo, pensamiento y Send/Stop. Pestañas y controles nativos con nombres accesibles; evitar una apariencia de formulario de configuración. El campo de escritura y un mensaje pueden tener un redondeado discreto; los paneles exteriores permanecen rectos. Inspiración aprobada: organización de Cursor, adaptada a AppKit.

## Detalle del chat — CHAT-05

- Los controles de cuenta, modelo y pensamiento viven en el compositor, como menús compactos con el valor actual visible. Se mantienen en una fila; cuenta/contexto se compactan y el nombre del modelo puede truncarse con tooltip al reducir el ancho (ajuste CHAT-06).
- La utilización de contexto procede del harness: entrada de la última solicitud dividida por capacidad informada. Mostrar un estado desconocido cuando falte información; el detalle explica tokens y capacidad. No es el porcentaje consumido de la suscripción.
- Cada solicitud del usuario se distingue de la respuesta y de la actividad del agente. La actividad puede desplegarse bajo su turno para consultar operaciones, estado, duración y salida limitada. No mezclarla dentro del texto escrito por el usuario ni presentar razonamiento interno.
- Durante streaming, conservar las alturas ya medidas al refrescar mensajes. No reducir una respuesta temporalmente a una altura estimada ni llamar a scrollRowToVisible por cada fragmento. Seguir el final cuando el usuario está allí; si lee más arriba, conservar el mensaje y desplazamiento visibles.
- Conservar posición de lectura al recibir eventos y actualizar sólo las filas que cambiaron. Los controles de conexión deben abrir su menú u hoja desde una vista visible de la ventana.

## Selectores inline — CHAT-06

- Referencia explícita del usuario del 24 de septiembre: selectores tipo Zed (texto/icono y chevron, sin caja individual) y compositor tipo Cursor (una sola superficie con campo arriba y controles abajo).
- Conservar una fila compacta de controles. En ancho estrecho, cuenta y contexto pueden compactarse y el nombre del modelo truncarse con tooltip; pensamiento debe seguir legible. Los menús, foco, teclado y nombres accesibles permanecen nativos.
- Un relleno suave distingue compositor y mensajes del usuario del fondo del transcript. El redondeado corresponde a estos elementos, no al panel exterior. No añadir Plan, Write, voz, adjuntos ni otros controles hasta que exista su función.

## Componentes y comportamiento

- Usar AppKit: `NSWindow`, `NSToolbar`, `NSSplitViewController`, `NSOutlineView`, `NSTableView`, menús, campos y botones del sistema según su propósito.
- Usar tipografía del sistema, SF Symbols y colores semánticos. La apariencia del editor de código es independiente de la GUI.
- Adoptar Liquid Glass con las APIs del sistema y la disponibilidad de cada versión de macOS. La navegación y los controles pueden usar materiales; el texto y el código necesitan fondos legibles. No extender transparencias a todo el contenido.
- Conservar estados activo/inactivo, foco de teclado, selección y estados deshabilitados del sistema. Evitar forzar materiales permanentemente activos cuando deben seguir a la ventana.
- Ofrecer comandos de aplicación mediante la barra de menús y atajos convencionales. Mostrar u ocultar paneles debe ser accesible también desde `View`.
- Preferir hojas asociadas a la ventana para decisiones de su proyecto. Usar paneles del sistema para elegir archivos y carpetas; reservar alertas para errores o decisiones que lo requieran.
- Respetar Undo/Redo cuando corresponda, edición de texto estándar, recorrido de foco, Escape y Return según el contexto. Proteger borradores al navegar o cerrar.
- Soportar claro/oscuro, contraste, reducción de transparencia y reducción de movimiento. Dar nombres accesibles a iconos y controles. No comunicar estado únicamente por color.
- Mantener todos los textos de interfaz en inglés y evitar terminología técnica que no ayude al usuario.

## Revisión de cada cambio visual

Comprobar la vista modificada en la aplicación real: jerarquía y alineación, acciones principales/secundarias, claro/oscuro, tamaño normal y mínimo, teclado y foco, contenido vacío y con datos. Comprobar las preferencias de accesibilidad afectadas. Reutilizar verificaciones recientes cuando el cambio no afecte a esos comportamientos; informar las pendientes sin dar una conformidad total por supuesta.

## Revisión del prototipo — 23 de septiembre de 2026

Evidencia: inspección del código de `WorkspaceWindow`, `AppDelegate` y `ProjectSidebarView`; vista real de TODOs y su árbol de accesibilidad. El detalle de TODOs se verificó en claro/oscuro y con guardado en la revisión anterior.

La estructura principal usa componentes nativos y respeta la distribución acordada. El detalle presenta los cinco elementos principales y un menú para acciones secundarias. Esto no equivale a una validación completa de HIG.

| Tarea | Hallazgo y resultado esperado | Estado |
| --- | --- | --- |
| MAC-01 | Save, Close, Undo/Redo y Find incorporados con el editor. Pendientes gestión estándar de ventanas y comandos de paneles en View. | Parcial |
| MAC-02 | Los diálogos de TODO usan `NSAlert.runModal()`. Pasar decisiones del proyecto a hojas de su ventana, conservando guardado, descarte y cancelación. | Pendiente |
| MAC-03 | Revisión 2026-09-25: los 3 `NSVisualEffectView` del proyecto (`TerminalPaneView.swift`, `EditorTabBar.swift`, `ProjectSidebarView.swift`) ya usan `.followsWindowActiveState`, no `.active`. Validación de Liquid Glass con el SDK objetivo sigue pendiente por separado. | Resuelto (seguimiento de ventana); Liquid Glass pendiente |
| MAC-04 | El detalle puede requerir desplazamiento para alcanzar el nuevo comentario; descripción y comentario tienen alturas fijas. Revisar composición con terminal abierta, centro estrecho, títulos largos y comentarios extensos, preservando la distribución acordada. | Pendiente |

Son tareas de acabado identificadas por revisión, no funcionalidades implementadas ni cambios de distribución aprobados.

## Referencias

- [Apple: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Apple: Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Apple: Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/)

## Cola y steering — CHAT-07

- El compositor permanece editable durante el trabajo. Enviar pasa a `Queue message`; Command-Return mantiene esa misma acción. Stop sigue disponible por separado.
- Pendientes en una lista compacta y de altura acotada sobre el compositor. Texto identificable, `Steer` para incorporarlo al turno activo y acción de quitar con nombre accesible. No mostrar pendientes como enviados.
- La cola pertenece a cada conversación. Si se pausa por Stop, error, desconexión o reapertura, mostrar `Resume` cuando sea posible continuar; conservar mensajes y borrador.
- Steer no cambia modelo, pensamiento, permisos ni conversación. El mensaje se muestra como enviado tras la aceptación del runtime. Un fallo conserva el texto y explica el estado sin duplicar automáticamente la solicitud.

## Entrada y seguimiento del chat — CHAT-08

- Enter envía; Shift+Enter inserta una nueva línea. Durante un turno, enviar añade a la cola. Command-Return permanece como alias. Respetar texto marcado/confirmación IME y mantener foco en el compositor.
- Al enviar, revelar el nuevo mensaje del usuario después del layout. Si se encola, revelar la fila nueva en la cola. Steer aceptado revela su mensaje. No saltar por errores ni por operaciones pertenecientes a otra conversación.
- La llegada de texto del asistente conserva la lectura cuando el usuario se ha desplazado hacia mensajes anteriores. Mantener seguimiento si ya estaba al final.

## Progreso y formato de respuestas — CHAT-09

- Resumen público de progreso en texto secundario que se actualiza durante el turno, asociado a la solicitud activa. Respuesta final en contraste normal. Limpiar el resumen transitorio al terminar; conservar las operaciones en el desplegable existente.
- Comentarios intermedios distinguibles de la respuesta final cuando el runtime indique su fase. No presentar razonamiento bruto ni simular contenido que no haya informado el proveedor.
- Enlaces seguros con color y subrayado; código y rutas reconocibles mediante tipografía y color semántico. Respetar claro/oscuro. Evitar texto recortado al estrechar el panel y celdas de tablas fusionadas.
- Las referencias opacas sin URL se indican como no disponibles; no inventar destinos. El formato visual no altera el mensaje original guardado.

## Archivos del chat — CHAT-10

- Las referencias reales a archivos del proyecto abren el editor, conservando navegación y borradores. Los enlaces web siguen siendo enlaces web.
- `Modified Files (N)` vive junto a la respuesta de su turno y despliega todos los archivos únicos. No repetir la lista bajo cada fragmento de progreso ni separarla en un panel global sin asociación al turno.
- Archivos arrastrados aparecen como referencias compactas removibles encima de la entrada. Conservarlos al cambiar de chat y explicar límites de formatos/tamaño. Adjuntar aporta contexto, no ejecuta una modificación.
- `Restore Point…` es una acción explícita por turno. La hoja explica que restaura archivos al estado anterior a ese turno y deshace los cambios posteriores del mismo chat; no elimina la conversación. Si hay conflicto con otras ediciones o borradores, informar el bloqueo sin sobrescribirlos.
