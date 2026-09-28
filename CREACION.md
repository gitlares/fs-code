## TOKEN-01 / CHAT-14 — RTK, contexto, caché y detalles de tarea

- RTK debe usarse cuando esté disponible; adaptación determinista de comandos compatibles, sin repetir una ejecución fallida.
- Distinguir ventana por defecto y máximo anunciado por el proveedor. No reemplazar datos de ChatGPT por límites publicados para otra vía API.
- Mostrar tokens de entrada, lectura y escritura de caché reportados. Ausencia de datos no es cero; no atribuir caché a un archivo específico sin evidencia del proveedor.
- Auditoría: el SDK agrupa mensajes system en instructions, incluidos metadatos variables del host; no está garantizada la estabilidad del prefijo completo.
- El footer textual Checkpoint del prompt es un resumen generado por el modelo, distinto de los restore points deterministas. Mostrar como Task details plegado, conservar contenido original y decisiones relevantes visibles.

## DEV-TOOLS — permisos y herramientas por proyecto

- Solicitud confirmada: herramientas normales de desarrollo, terminal general y computer use; activación/desactivación por proyecto.
- `Permissions` en el selector lateral izquierdo muestra capacidades activas e inactivas.
- Solicitudes del agente desde el chat requieren decisión del host; un prompt no concede permisos.
- La terminal usa acceso del usuario de macOS: cwd no es sandbox. Computer use puede actuar en otras apps.
- Restauración determinista de ediciones por servicio no se extiende automáticamente a escrituras de comandos.
- Implementación en curso; no incluida aún en la alpha publicada.

# FS Code — documento vivo de creación

## CHAT-13 — legibilidad de respuestas y siguiente etapa de herramientas

- Ajustar renderizado Markdown del chat: separación de párrafos/listas, jerarquía tipográfica y ancho de texto, conservando la semántica y el seguimiento de scroll.
- Herramientas de comandos/Git/firma/publicación aún no implementadas. Diseño acotado y criterios de aceptación en docs/AGENT_EXECUTION_PLAN.md; el acceso a credenciales permanece en el host, no en el modelo.

## RELEASE-01 — publicación 0.1.0 Alpha

- Repositorio público MIT: https://github.com/gitlares/fs-code. Publicación inicial mediante lista explícita de fuentes, pruebas, dependencias vendorizadas y documentación pública; se excluyen chats/estado local e historial interno.
- README en inglés recoge motivación, funciones actuales y roadmap; privacidad diferencia ausencia de analytics propios del tráfico a proveedores.
- Suite: 178 XCTest (1 omitida, 0 fallos) + 33 Swift Testing.
- Scripts portables sin RTK obligatorio; firma Developer ID con runtime endurecido, Sparkle inside-out y notarización opcional.
- Binario publicado: v0.1.0-alpha.1, arm64, Developer ID y notarización Apple Accepted (16d594dc-d39b-4412-aeed-334b0600cb58), ticket stapled validado y Gatekeeper accepted. ZIP + SHA256SUMS en GitHub Releases. Firma usa el certificado y llavero dedicado v2 de FS PDF Compressor, no login.

## WINDOW-01 — varios proyectos en ventanas independientes (implementado)

- File → New Window (Command-Shift-N) muestra la biblioteca sin cerrar el proyecto actual. Seleccionar otra carpeta/proyecto abre su propia ventana.
- Cada proyecto mantiene editor, terminal, conexión y conversaciones independientes. Un proyecto ya abierto se enfoca para evitar duplicar sesiones sobre la misma carpeta.
- Menú Window nativo para cambiar entre ventanas. Los comandos actúan sobre la ventana activa; cerrar una conserva las demás y sus protecciones de guardado.
- Validación: compilación debug y release correctas, firma local verificada. Probado en la aplicación: abrir FS editor, Command-Shift-N, abrir Prueba de distribución, ver ambos proyectos en Window, cerrar sólo el segundo y regresar al primero. Se conserva el flujo previo de mostrar la biblioteca tras cerrar un proyecto.

## PREVIEW-02 — binarios sin alertas y Quick Look (implementado)

- Seleccionar un formato no editable muestra una pestaña de sólo lectura con un estado integrado; no una alerta modal por archivo.
- Aprovechar QuickLookUI/QLPreviewView de macOS para tipos comunes compatibles; mantener los visores existentes de imágenes, SVG y Markdown.
- Activar el visor nativo sólo para la pestaña visible y liberar su contenido al salir/cerrar. Sin reproducción automática ni dependencias externas.
- Formatos opacos muestran No preview available; errores reales de acceso conservan su tratamiento. No confundir codificación no compatible o límite de tamaño con corrupción.
- Validación: 42 XCTest (1 omitida, 0 fallos) y 4 Swift Testing aprobadas; release empaquetada y firma local verificada. En la aplicación real se comprobó una pestaña binaria sin alertas, un PDF renderizado por Quick Look y el cierre de ambas. La compatibilidad de otros documentos/medios depende del visor de macOS; no se verificaron todos los formatos.

## PLAN-02 — lectura visual de planes (implementado)

- Abrir cada plan en Preview usando el mismo renderizador Markdown nativo del editor.
- Selector Preview / Code en la cabecera; Code muestra el Markdown completo para editar, Preview refleja el borrador sin guardarlo ni perder cambios.
- La previsualización oculta los metadatos YAML; estado/revisión y acciones de aprobación siguen visibles en la interfaz.
- Validación: tres pruebas de formato aprobadas, release compilada; comprobados en la app real la apertura en Preview y el cambio Code → Preview, dejando el plan en lectura sin modificarlo.

## CHAT-12 — posición estable al redimensionar el chat (implementado)

- Conservar alturas anteriores como estimaciones durante el cambio de ancho, sin colapsar todo el historial a filas mínimas.
- Agrupar mediciones y actualizar la posición del viewport sin animación: al final permanece abajo; leyendo historial conserva mensaje visible y desplazamiento.
- Evitar cadenas de scroll diferido por cada fila. Conservar las protecciones contra recursión de layout de CHAT-11.
- Validar reflow estrecho/ancho, seguimiento del final y conservación de lectura con historial largo.
- Validación: 40 XCTest de FSCode (1 omitida, 0 fallos), incluidas pruebas de anclaje inferior y mensaje/offset al leer historial; 3 pruebas Swift Testing adicionales. Release empaquetada y firma local verificada.

## MODES-01 — Build, Plan, Ask y planes del proyecto (integrado)

Especificación suministrada por el usuario conservada íntegra en `docs/AGENT_PROFILES_V3_3.md`. Sus notas de integración son requisitos del host; no se inyectan al modelo. Cada turno usa Shared y sólo el perfil activo, seguido del contexto resuelto y del historial; los metadatos variables del host quedan separados.

- Selector compacto en chat, modo por conversación. No cambiar permisos de un turno ya iniciado ni reinterpretar mensajes en cola silenciosamente.
- Ask: herramientas de lectura. Plan: lectura y escritura dedicada exclusivamente de planes Markdown en `.fs/plans/`. Build: servicio auditado de edición, con permisos comprobados por el host aun si el modelo solicita una herramienta oculta.
- Panel izquierdo Plans: listado real con estado, detalle central editable, referencias de archivos navegables y acción Approve and Run / Run. Editar invalida la aprobación; ejecutar vincula una versión por hash, cambia a Build y pasa selección explícita del host. `status: approved` en el repositorio no autoriza por sí solo.
- Agent Context: System Prompts (Shared, Build, Plan, Ask), versión y revisión, guardar cambios y restablecer. Personalización por proyecto en Application Support; archivos del repositorio no reemplazan silenciosamente perfiles aprobados.
- Validar persistencia, compatibilidad de historiales anteriores, aislamiento de modos, rutas de planes, aprobación obsoleta, integridad de texto v3.3 y ejecución real por botón.
- Los comandos, subagentes y otras capacidades aún ausentes del motor no se habilitan por incluirlos en un prompt. Registrar explícitamente la cobertura de límites, checkpoints y RTK antes de declarar equivalencia con todas las notas de integración.

Implementación integrada: AppKit nativo, perfiles v3.3 exactos y configuraciones fuera del repositorio; planes `.fs/plans/*.md` y aprobaciones locales externas vinculadas al hash. El runtime recibe sólo Shared + modo activo, contexto del proyecto y metadatos del host por ronda. Permisos comprobados al ejecutar herramientas; límites de operaciones Build 40, Plan 15, Ask 4 y rondas 16/8/4, con reserva para cierre. Build actualiza progreso mediante `fs_update_plan`; no puede usar la escritura genérica para modificar planes.

Cobertura pendiente de las notas de integración: límites agregados de tokens/coste, detector de fallos repetidos, checkpoint estructurado con comparación al reanudar, shell/RTK y subagentes. La aprobación por mensaje libre todavía no sustituye la acción explícita del editor. Estas capacidades no se consideran implementadas por aparecer en los perfiles. Los planes se actualizan en la lista al entrar en Plans; la actualización continua mientras permanece abierto queda pendiente.

Validación del 24 de septiembre: suite completa 173 XCTest (1 omitida, 0 fallos) y 32 Swift Testing; después se añadieron dos pruebas de integración de ejecución aprobada/no aprobada y pasaron las 26 pruebas de conversación. Release empaquetada y firma local verificada. App real: selector Plan, creación real de `.fs/plans/modulo-freir-huevos.md`, listado con estado, detalle central y enlaces de archivos visibles, editor Shared con versión 3.3/revisión 1. No se ejecutó el plan de prueba del usuario durante la inspección; el envío desde Approve and Run se verificó con transporte simulado para no modificar su proyecto.


## CHAT-11 — regresión al redimensionar respuestas (corregido; prueba final en app pendiente)

- Corregir el texto comprimido a una columna estrecha y el cierre de AppKit al arrastrar el divisor o redimensionar después de una respuesta.
- Evidencia: informes reales del 24 de septiembre, 12:18, 12:21 y 12:32; NSTableRowData/CoreAutoLayout durante actualización de anchos.
- Incluir seguimiento del final durante streaming y al enviar, una vez actualizadas las alturas; conservar la lectura si el usuario desplaza el historial hacia arriba.
- Terra implementa y añade prueba de varios anchos; principal revisa, compila y valida en la app real. Conservar enlaces, adjuntos y restauración.

## CHAT-10 — archivos, contexto y restauración (implementado; validación visual parcial)

- Enlaces a archivos del proyecto en respuestas abren la pestaña del editor. Resolver rutas reales, sin inventar destinos ni interpretar cualquier palabra como archivo.
- Cada turno que escribe archivos muestra un desplegable `Modified Files (N)` con todos los archivos únicos y navegación al editor. El historial conserva la asociación turno/archivos.
- Arrastrar archivos al compositor añade referencias visibles y removibles de contexto, aisladas por conversación. Los archivos externos de texto pueden aportarse como contenido acotado de sólo lectura; adjuntar no implica autorización automática de escritura.
- Cada turno con escrituras auditadas define un punto anterior a sus cambios. Restauración determinista basada en snapshots y hashes locales, no un LLM ni Git. Proteger borradores, cambios externos y cambios de otra conversación, y comprobar el conjunto antes de escribir.
- Implementación: Terra para servicio y pruebas de restauración; Terra para AppKit, enlaces, adjuntos y controles por turno. El orquestador revisa, integra, compila y verifica la app real.
- Aceptación: click abre archivo, todos los archivos aparecen bajo su turno, drop envía contexto real sin contaminación entre chats, restauración revierte creación y ediciones repetidas, conflicto bloquea sin sobrescribir, persistencia tras reapertura.

Decisión de adjuntos de esta entrega: archivos del proyecto como referencias a su versión guardada; texto externo UTF-8 como copia de sólo lectura de hasta 64 KiB por archivo, máximo 8 referencias y 256 KiB de copias por borrador. Metadatos por chat en `.fscode/chat-attachments/`, permisos privados. No se añaden dependencias. Queda fuera de esta tanda adjuntar imágenes al proveedor como entrada multimodal.

Estado: prototipo de biblioteca, paneles y TODOs; primera entrega del editor de texto implementada y comprobada en los flujos principales. Selector nativo y resto del producto con pendientes registrados.
Actualizado: 23 de septiembre de 2026.

Este archivo será la referencia para acordar funcionalidades, decisiones, tareas y criterios de aceptación. Una propuesta no equivale a una decisión aprobada. Antes de programar, Daniel y Codex definirán las tareas; después, Codex coordinará su ejecución con modelos más económicos acordados.

## 1. Visión y prioridades acordadas

FS Code es el nombre provisional de un editor de código nativo para macOS, diseñado para trabajar intensivamente con inteligencia artificial y ser extremadamente ligero.

- La rapidez y el consumo mínimo de memoria, CPU y energía son requisitos del producto.
- Código legible y ordenado. Reutilizar lo que aporte a nuestra visión y ahorre tiempo; la cantidad de código propio no es el objetivo. Cada módulo y dependencia debe justificar su utilidad y su coste de mantenimiento y rendimiento.
- La escritura, navegación y apertura de archivos deben mantenerse fluidas durante las tareas de IA.
- Interfaz sencilla, limpia y consistente con macOS; la complejidad aparece cuando se necesita.
- Inglés como único idioma de la aplicación por ahora: menús, botones, paneles, diálogos y mensajes. No añadir selector de idioma ni traducciones en esta etapa. Los nombres y etiquetas escritos por el usuario conservan su contenido original.
- Apariencia y comportamiento plenamente nativos de macOS, incluido Liquid Glass donde corresponda, con soporte completo de modo claro y oscuro.
- La GUI es macOS nativa en AppKit: usar los controles, tipografía, colores semánticos, accesibilidad e interacción del sistema. El cuidado del diseño se aplica a su composición; no se plantea como una simulación visual de macOS.
- Regla permanente de organización: toda pantalla y cambio visual debe seguir `docs/MACOS_GUI.md`, enlazado desde `AGENTS.md` para futuras contribuciones. La revisión del 23 de septiembre identifica las tareas de acabado MAC-01 a MAC-04; no implica que estén implementadas.
- Sin VS Code, Electron ni Monaco.
- Por ahora solo macOS. Windows, Linux y la portabilidad del núcleo quedan fuera del alcance actual.
- Extensible mediante plugins de terceros, sin permitir que bloqueen o degraden perceptiblemente la edición.
- Primero definir tareas juntos; después implementar con delegación y revisión.

## 2. Experiencia principal

Al iniciar aparece una biblioteca de proyectos, nunca un editor vacío. Un proyecto representa una carpeta real del sistema.

**Flujo inicial acordado:**

1. Mostrar la lista de proyectos registrados y la acción «Añadir proyecto».
2. Al añadir, seleccionar una carpeta mediante el selector nativo de macOS.
3. Asignar un nombre visible al proyecto; como propuesta, precargar el nombre de la carpeta para poder confirmarlo directamente.
4. Confirmar para registrar el proyecto y abrir su ventana de trabajo.

«Crear un proyecto» significa registrar una carpeta elegida y darle un nombre. Este flujo no genera código, plantillas, repositorios Git ni cambia el nombre de la carpeta. Si la biblioteca está vacía, la acción de añadir será el elemento principal. Arrastrar una carpeta debe llevar al mismo paso de nombre y confirmación.

La ventana de trabajo tendrá (distribución acordada):

- Izquierda: un único panel con iconos para alternar entre `Files` (árbol de archivos) y `TODOs` (tareas del proyecto). Solo una vista se muestra a la vez, ocupando el mismo espacio. Incluye gestión manual de TODOs; la detección en código sigue pendiente.
- Centro superior: editor de texto con pestañas, números de línea, detección automática y resaltado léxico; indentación por lenguaje pendiente.
- Derecha: panel de interacción con IA, plegable y a toda la altura del área de trabajo.
- Centro inferior: terminal, plegable, situada debajo del archivo y entre los dos laterales.
- Arriba: barra compacta con proyecto y acciones principales; pestañas del archivo activo debajo, según la propuesta de barra superior.

Los separadores permiten cambiar el ancho de los laterales y la proporción vertical entre archivo y terminal. En esta primera versión «movimiento» significa arrastrar estos separadores y mostrar u ocultar paneles. Reordenar o desprender paneles en ventanas independientes queda pendiente de definición.

**Alcance inicial:** biblioteca con carpetas reales y ventana con esta distribución ajustable. Posteriormente se autorizaron TODOs manuales y, el 23 de septiembre, avanzar con el editor de texto. La terminal funcional se incorpora en TERM-01; la conexión con IA se trabajará después.

### Primera entrega del editor de texto

Inicio autorizado el 23 de septiembre de 2026. Se prepara una base AppKit con `NSTextView` y TextKit 2. Distribución conservada: archivos en pestañas dentro del centro superior; TODOs alterna esa misma área sin perder los documentos abiertos.

| Tarea | Alcance | Estado |
| --- | --- | --- |
| TEXT-01 | Abrir archivos reales UTF-8, preservar BOM y finales CRLF uniformes, guardado atómico y detección de cambios previos en disco | Implementado |
| TEXT-02 | Pestañas nativas, edición monoespaciada, selección, desplazamiento y Undo/Redo independientes por archivo | Implementado |
| TEXT-03 | Save, Close, Find y atajos convencionales; punto de cambios pendientes y hojas Save/Don't Save/Cancel para documentos | Implementado |
| TEXT-04 | Verificación real de editar/guardar/reabrir, cancelación de cierre, conflictos externos y apariencias clara/oscura | Flujos principales, claro y oscuro comprobados; ventanas mínimas y accesibilidad pendientes |
| TEXT-05 | Números de línea siempre visibles, detección automática y resaltado Dracula/Alucard | Implementado; validación visual y pruebas de lenguaje/índice |
| TEXT-06 | Autoindentación, parser incremental y medición de archivos grandes | Pendiente; concretar siguiente entrega |

La primera entrega limita cada archivo a 5 MiB, rechaza binarios y codificaciones diferentes de UTF-8 y no incorpora dependencias. Este límite es provisional y no demuestra rendimiento con archivos grandes. El guardado compara bytes antes de reemplazar: detecta cambios ya presentes pero no proporciona una transacción entre escritores independientes. No incluye autosave, recuperación tras cierre inesperado ni creación de archivos nuevos.

### Barra superior: referencia visual Nova

**Preferencia indicada por el usuario:** una barra superior similar a la captura aportada de Nova: sencilla, limpia y compacta. La imagen sirve como referencia visual; no incorpora automáticamente funciones de ejecución o Git al alcance actual.

**Distribución propuesta para acordar antes de implementar:**

- Izquierda: controles de ventana nativos y nombre del proyecto. Una segunda línea discreta puede mostrar la rama de Git cuando esa función exista; la ruta completa se consulta desde el proyecto sin ocupar permanentemente la barra.
- Zona intermedia: espacio flexible y, cuando exista una tarea activa, estado breve y acción para detenerla. Los controles de ejecución se incorporarán cuando haya una función real que los utilice.
- Derecha: iconos para mostrar u ocultar `Sidebar`, `Terminal` y `Assistant`, con estado activo visible, tooltips y nombres accesibles en inglés. Dentro del lateral izquierdo, un selector de iconos alterna entre `Files` y `TODOs`; ocultar el lateral afecta a la vista activa.
- Debajo: fila de pestañas alineada con el área del editor. La pestaña identifica el archivo activo; no repetir su nombre en varios lugares de la cabecera sin necesidad.
- Mover el selector permanente `System / Light / Dark` y `Reset Layout` a los menús o ajustes correspondientes para liberar espacio.
- Mantener materiales, tipografía y controles propios de macOS, con acabado claro y oscuro. La captura orienta la jerarquía y distribución; la paleta final sigue pendiente de diseño.
- En ventanas estrechas, priorizar el nombre del proyecto y los controles de paneles; truncar información secundaria y permitir acceso a acciones que no quepan. Conservar una zona útil para arrastrar la ventana.

**Tarea UI-01, primera entrega visual:** barra AppKit compacta con nombre del proyecto y controles de paneles a la derecha; apariencia y restauración de distribución en el menú `View`. Compilada y comprobada en claro y oscuro junto con el selector lateral `Files` / `TODOs`. Las pestañas funcionales y los estados de tareas activas se incorporarán con sus funcionalidades. La adaptación detallada a ventanas estrechas sigue pendiente de validación.

### Apariencia nativa y temas

**Icono elegido por el usuario:** `Resources/AppIcon.png`, recibido el 23 de septiembre de 2026. Se conserva el diseño original de 1254 × 1254 píxeles y se generan las representaciones de 16 a 1024 píxeles para empaquetarlas en `AppIcon.icns`. El archivo original tiene fondo negro opaco; es utilizable como icono provisional, con adaptación del exterior a transparencia pendiente para el acabado final. No es todavía un icono por capas para Icon Composer.

**Requisitos acordados:** aspecto plenamente macOS, Liquid Glass y soporte de modo claro y oscuro. Usaremos los componentes y materiales del sistema. La versión mínima de macOS compatible con esta experiencia queda por acordar.

**Propuesta de diseño pendiente de aprobación:**

- Seguir la apariencia del sistema por defecto, con opciones Sistema / Claro / Oscuro.
- Aplicar Liquid Glass a controles y navegación según las guías de Apple; mantener un fondo estable y legible en el área de código.
- Respetar las preferencias de accesibilidad del sistema, incluidos reducción de transparencia, reducción de movimiento y mayor contraste.
- Conservar controles, menús, tipografía de interfaz, espaciados y comportamientos propios de macOS.
- Medir el coste de los efectos visuales dentro del presupuesto de rendimiento; evitar efectos personalizados o animaciones continuas.
- Separar la apariencia de la aplicación del esquema de colores del código.
- **Dracula** es el esquema oscuro del editor y **Alucard** su compañero claro. Ambos están integrados; revisión completa de contraste/accesibilidad y futuros diffs pendiente.
- Los temas de color deben ser datos declarativos; no necesitan ejecutar código de plugins.

**Licencia verificada:** el repositorio oficial publica las paletas Dracula y Alucard como OSS bajo MIT. Permite uso, modificación y distribución comercial conservando el aviso de copyright y la licencia. El aviso se incluye en `Resources/ThirdPartyNotices.txt` y en el bundle generado. Dracula PRO es un producto separado y no forma parte de esta propuesta.

Fuentes consultadas el 23 de septiembre de 2026: [Apple: adoptar Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass), [paletas oficiales Dracula y Alucard](https://github.com/dracula/dracula-theme), [licencia MIT](https://github.com/dracula/dracula-theme/blob/main/LICENSE).

## 3. Funcionalidades previstas

### Biblioteca de proyectos

- Añadir una carpeta desde el selector o arrastrándola a la ventana.
- Mostrar proyectos guardados con nombre visible independiente del nombre de su carpeta.
- Añadir y editar etiquetas; buscar por nombre, ruta o etiqueta.
- Ordenar por última apertura y marcar favoritos.
- Mostrar carpeta en Finder y copiar su ruta.
- Quitar de la biblioteca sin borrar archivos.
- Detectar carpetas movidas o eliminadas y permitir volver a localizarlas.
- Evitar registros duplicados de una misma carpeta.

### Configuración por proyecto y biblioteca global

Dirección propuesta por el usuario: guardar la configuración de cada proyecto en una carpeta oculta dentro de su carpeta. Nombre propuesto: `.fscode/`; archivo inicial propuesto: `.fscode/project.json`. El nombre y esquema definitivos quedan por cerrar en DEF-06.

Propuesta de reparto:

| Ubicación | Contenido y propósito |
| --- | --- |
| `<carpeta>/.fscode/project.json` | Versión del formato, nombre del proyecto y ajustes compartibles, como indentación y preferencias por lenguaje |
| `~/Library/Application Support/FS Code/projects.json` | Índice local para la biblioteca: identificador de registro, ruta/bookmark, nombre en caché, etiquetas personales, última apertura y favorito |
| Almacenamiento local de la aplicación, por registro | Estado personal: pestañas, disposición de paneles, historial de conversaciones y registro de cambios de IA; detalles pendientes |
| Llavero de macOS | Credenciales; nunca en la configuración compartible del proyecto |

El índice global sigue siendo necesario: permite mostrar los proyectos al iniciar sin recorrer el disco para descubrir carpetas ocultas. El archivo del proyecto conserva los ajustes al mover o compartir la carpeta. Cuando esté disponible, será la fuente del nombre; el índice mantiene una copia para mostrarlo si la carpeta no está accesible.

Comportamientos propuestos para definir en DEF-06:

- Si existe una configuración compatible, leerla y precargar su nombre al añadir el proyecto; conservar los ajustes existentes.
- Escribir `.fscode/project.json` al confirmar, no al explorar carpetas o cancelar el selector.
- Permitir abrir carpetas sin permiso de escritura mediante un registro local; explicar que los ajustes no se podrán guardar dentro del proyecto.
- Quitar un registro de la biblioteca no borra `.fscode/` ni el contenido de la carpeta.
- Una carpeta movida se vuelve a localizar; una copia en otra ubicación puede registrarse como proyecto independiente. No usar un identificador copiado en el JSON como único criterio para detectar duplicados.
- La configuración compartible puede versionarse en Git si el usuario lo desea; no modificar `.gitignore` automáticamente.
- La configuración de un proyecto no concede permisos ni autoriza por sí sola comandos, plugins o acceso a credenciales.
- Usar formato versionado y escrituras atómicas. Si el archivo es inválido o de una versión no compatible, conservarlo y ofrecer recuperación sin sobrescribirlo silenciosamente.

La elección de sandbox y bookmarks con alcance de seguridad queda pendiente. La primera versión implementará únicamente el nombre en la configuración del proyecto y el índice local necesario para la biblioteca; conversaciones, credenciales y ajustes del editor siguen fuera de alcance.

### Editor

- Abrir, editar y guardar archivos en pestañas.
- Resaltado incremental y autoindentación según el lenguaje.
- Módulos de lenguaje que definan extensiones, parser, indentación, comentarios y resaltado.
- Lenguajes previstos: Swift, Python, JavaScript, TypeScript, JSON, HTML, CSS, Rust y Shell.
- El subconjunto del primer MVP se elegirá conjuntamente.

### Terminal

- Terminal local integrada y plegable.
- Política pendiente para comandos ejecutados por IA, sesiones y procesos activos.

### TODOs integrados por proyecto

**Requisito solicitado:** gestor de TODOs incluido en la aplicación, con dos vías de creación y una lista por proyecto. Debe permitir nombre, descripción y comentarios. Comparte el lateral izquierdo con el árbol de archivos: iconos `Files` y `TODOs` permiten alternar entre ambas vistas. Esta decisión sustituye la propuesta anterior de un subpanel debajo del árbol. No requiere instalar un plugin ni conectarse a un modelo.

| Origen | Creación | Presentación |
| --- | --- | --- |
| Manual | Acción `New TODO`; introducir nombre, descripción y comentarios | Entrada del proyecto, sin necesidad de asociarla a un archivo |
| Código | Escribir `TODO: Hacer esto` dentro de un comentario del lenguaje | Entrada detectada con el texto, archivo y ubicación; abrirla lleva al comentario |

Los controles estarán en inglés (`Files`, `TODOs`, `New TODO`, `Title`, `Description`, `Comments`). El contenido escrito por el usuario conserva su idioma. Las dos vías alimentan la misma lista de TODOs; no implican sincronizar automáticamente cada tarea manual con un comentario de código.

**Propuesta de experiencia para acordar:**

- Cabecera `TODOs` y botón `+`. El lateral muestra únicamente títulos en dos secciones: `Open` arriba y `Closed` debajo, con sus contadores.
- Selector compacto de iconos en la parte superior del lateral: carpeta para `Files` y lista de tareas para `TODOs`, con selección visible, tooltips y nombres accesibles. La ubicación superior y los símbolos concretos son propuestas de presentación.
- Ambas vistas utilizan todo el espacio disponible debajo del selector, con el mismo ancho ajustable del lateral. La terminal conserva su posición central inferior. Proponer conservar selección y desplazamiento de cada vista al alternar, y abrir `Files` por defecto en un proyecto nuevo.
- Seleccionar una entrada muestra su detalle en el área central superior con cinco elementos principales: título, `Status`, `Priority`, `Description` y `Comments`. Composición AppKit con tipografía y colores semánticos del sistema. El menú de acciones reúne fecha de creación, vínculo opcional a archivo y eliminación. `Files` vuelve al contenido de archivo; la terminal mantiene su sitio.
- Cada sección muestra inicialmente 10 tareas y añade 10 con su propio `Load More`. Orden compartido por relevancia (alta primero, después fecha reciente), fecha más reciente o fecha más antigua; los empates tienen un orden estable. Cambiar de orden reinicia ambos límites a 10.
- Relevancia editable `Low`, `Normal`, `High` (predeterminada `Normal`). Estados `Open` y `Closed`; guardar el cambio de estado mueve la tarea entre secciones. Se conserva la fecha de creación original, distinta de la de actualización.
- El vínculo usa una ruta relativa al proyecto; guardar y abrir validan que no escape de esa carpeta. Los campos nuevos son opcionales al leer archivos antiguos. Guardar/descartar/cancelar protege los borradores al navegar o cerrar.
- Buscar y filtrar por origen `All`, `Manual` y `Code` sigue pendiente. No añadir fechas límite ni asignaciones en esta entrega.
- Las tareas manuales admiten edición, finalización, reapertura y eliminación. Para tareas del código, acordar qué significa completar: modificar el marcador, retirar el comentario o mantener un estado asociado. No modificar ni borrar código automáticamente al pulsar una casilla.

**Persistencia de la primera implementación:** `.fscode/todos.json`, JSON legible con versión de formato, para tareas manuales. Cada tarea tiene identificador estable, título, descripción, estado, fechas y una lista de comentarios con identificador, texto y fecha. Se crea al guardar la primera tarea; abrir la vista no escribe archivos. No se utiliza SQLite ni se incorporan dependencias.

JSON se elige por la facilidad de inspeccionar y versionar las tareas junto con el proyecto. SQLite también es adecuado para [almacenamiento local de aplicaciones](https://www.sqlite.org/whentouse.html); no se descarta por ser pesado. Se reevaluará si aparecen consultas complejas, mucho historial o necesidades de concurrencia que justifiquen el cambio.

Las escrituras son atómicas. Archivos dañados o versiones incompatibles muestran error y se conservan. Se comprueban cambios externos antes de guardar; se solicita recargar ante discrepancias, sin sobreescribir a ciegas. Esta comparación no es un bloqueo transaccional entre procesos y no elimina la carrera entre comprobación y reemplazo. En una carpeta sin permisos de escritura, se muestra el error y la tarea no se da por guardada; no se desvía silenciosamente a un almacenamiento global. La acción `Refresh TODOs` y volver a la vista recargan los datos; no hay sondeo periódico.

Los TODOs del código y sus metadatos siguen pendientes: el comentario será la fuente del texto detectado y el índice se podrá reconstruir. No incluir su detección en la primera entrega manual.

**Detección y rendimiento propuestos:**

- Reconocer `TODO:` en comentarios reales del lenguaje soportado, incluidos comentarios de línea o bloque; evitar coincidencias dentro de strings. Ejemplos: `// TODO: Validate input`, `# TODO: Add tests`, `<!-- TODO: Improve navigation -->`.
- El texto que sigue a `TODO:` será el título inicial. El formato para descripciones multilínea y otros marcadores como `FIXME` queda fuera de la primera definición.
- Explorar el proyecto en segundo plano con límites, cancelación y exclusiones para binarios, dependencias y archivos generados. Concretar reglas de exclusión y archivos ignorados antes del desarrollo.
- Actualizar únicamente archivos afectados y agrupar cambios de escritura; no recorrer todo el proyecto en cada pulsación. En documentos abiertos, usar el contenido sin guardar y reconciliarlo al guardar o descartar para no duplicar entradas.
- Mantener las ubicaciones al insertar líneas, renombrar o eliminar archivos. Dos comentarios con el mismo texto en lugares distintos son tareas distintas. No usar únicamente el número de línea como identidad para conservar comentarios o estados añadidos; definir una estrategia y tratar coincidencias ambiguas sin reasignar datos silenciosamente.
- Retirar del índice los marcadores que desaparezcan. Acordar conservación de metadatos e historial antes de borrar datos asociados. Un error de lectura o un análisis incompleto no equivale a que una tarea haya sido eliminada.

**Tareas y alcance de la entrega manual:**

| ID | Entregable | Aceptación |
| --- | --- | --- |
| TODO-01 | Definir campos, detalle y ciclo de vida | Creación manual y desde código, comentarios, finalización y persistencia acordados |
| TODO-02 | Selector AppKit `Files` / `TODOs` y tareas manuales | Implementado: crear, editar título/descripción, añadir comentarios, completar/reabrir y eliminar con confirmación; JSON por proyecto. Filtros y búsqueda pendientes |
| TODO-05 | Detalle central, relevancia y listas paginadas | Implementado: solo títulos en el lateral, secciones `Open`/`Closed`, 10 por sección y carga independiente, orden por relevancia/fecha, vínculo de archivo y compatibilidad con TODOs anteriores |
| TODO-03 | Detección para los lenguajes iniciales acordados | Comentarios válidos, strings excluidos, navegación a ubicación y actualización sin duplicados |
| TODO-04 | Integración y rendimiento | Ediciones sin guardar, cambios externos, renombrados, marcadores idénticos y proyectos grandes comprobados |

La integración futura con IA —por ejemplo, enviar un TODO como encargo— se discutirá aparte. La detección de un comentario no autoriza ejecutar tareas automáticamente. El usuario autorizó implementar TODOs manuales; la detección en código, filtros y funciones de IA quedan fuera de esta entrega.

### Inteligencia artificial

La IA es una parte central del producto, no una función secundaria.

- Leer archivos y buscar nombres y contenido dentro del proyecto.
- Proponer cambios y aplicar parches autorizados.
- Ejecutar comandos conforme a la política que se acuerde.
- Explicar errores y mostrar el progreso de las tareas.
- Presentar diferencias antes o después de una modificación.
- Permitir revisar y revertir individualmente sus propios cambios.
- Usar una capa de proveedores intercambiable; API y proveedor inicial pendientes de elección.

Evaluación del harness: [análisis y tareas propuestas](docs/HARNESS.md). Distinguir el modelo del motor que organiza su trabajo y del protocolo que lo conecta al editor. Se propone evaluar Codex App Server y OpenCode como motores reutilizables en procesos separados; no se ha seleccionado ni integrado ninguno. ACP conecta editor y agente; MCP conecta el agente con herramientas y datos. Son complementarios.

Todas las escrituras de IA deberán pasar por un único servicio de archivos. Cada operación registrará ruta, conversación o turno, hash anterior, hash posterior, fecha y parche aplicado. El diseño deberá contemplar creación, eliminación, renombrado y cambios externos concurrentes, además de modificaciones de texto.

**Problema por resolver antes de implementar:** los comandos de terminal también pueden escribir archivos. No basta con registrar los parches del modelo. Debemos acordar cómo controlar y atribuir estas escrituras para cumplir el requisito del servicio único.

Estados independientes y combinables de cada archivo:

| Indicador | Significado |
| --- | --- |
| Punto normal | Cambios sin guardar |
| ✦ | Modificado por IA |
| M | Modificado respecto a Git |
| ! | Conflicto o modificación externa |

Revertir un cambio de IA debe preservar las modificaciones posteriores del usuario o detectar el conflicto antes de sobrescribirlas.

## 4. Plugins: propuesta por discutir

Objetivo acordado: permitir extensiones de otras personas sin sacrificar la ligereza del editor.

Impacto cero no es una garantía técnica realista: un plugin consume recursos. La garantía de producto debe expresarse mediante presupuestos medibles, aislamiento y capacidad de suspensión.

Propuesta inicial, todavía no aprobada:

1. Ningún código de terceros se ejecuta en el proceso de la interfaz o en su hilo principal.
2. Los plugins se ejecutan en procesos auxiliares, con mensajes asíncronos y una API limitada y versionada.
3. Se activan solo cuando se necesitan: un comando, un lenguaje o una acción explícita. Los plugins inactivos no mantienen procesos ni temporizadores.
4. El editor sigue funcionando si un plugin se bloquea, falla o no responde.
5. Límites de concurrencia, tamaño de mensajes, tiempos de respuesta y frecuencia de eventos. Control y medición de memoria y CPU; suspensión o terminación al superar la política acordada.
6. Permisos explícitos para archivos, red, terminal y credenciales. Separar procesos no sustituye al aislamiento de permisos.
7. Las contribuciones visuales se describen mediante datos y las dibuja AppKit; evitar interfaces web completas por plugin.
8. Panel sencillo para activar, desactivar y ver el consumo de cada extensión. Modo sin plugins para diagnóstico.
9. Las escrituras de plugins pasan por los servicios del editor cuando corresponda; no deben eludir la atribución de IA.

Decisiones pendientes: primeros tipos de extensión, lenguajes/runtime admitidos, mecanismo de aislamiento, un proceso por plugin o grupos, distribución, confianza y actualización. Procesos separados mejoran el aislamiento pero añaden memoria: mediremos antes de elegir.

Candidatos para un primer alcance pequeño: comandos explícitos, herramientas de IA o módulos declarativos de lenguaje. No se da por aprobado un marketplace ni ejecución arbitraria de código en el MVP.

### Propuesta concreta para empezar pequeño

Separar dos tipos de extensión:

| Tipo | Ejemplos | Ejecución propuesta |
| --- | --- | --- |
| Declarativa | Temas de color, snippets, asociación de extensiones de archivo | Archivos de datos validados; sin procesos propios ni código ejecutable |
| Ejecutable | Formatear un documento, analizar una selección, aportar una herramienta a la IA | Proceso auxiliar iniciado al invocar la acción, con respuesta asíncrona |

Una gramática compilada, un script de indentación o una expresión costosa no se considera automáticamente una extensión declarativa segura por estar empaquetada junto a JSON. Su ejecución requiere evaluación aparte.

Para el primer plugin ejecutable, proponer únicamente un comando manual: recibir texto y devolver texto o un parche. FS Code revisa la versión del documento antes de aplicar la respuesta mediante su servicio de documentos/archivos. Si el usuario editó entretanto, se rechaza o presenta el conflicto; no se sobrescribe su trabajo.

El paquete de terceros tendría un manifiesto pequeño (identificador, versión, versión de API, comandos y capacidades solicitadas) y un ejecutable. La interfaz pública se limitaría inicialmente a ejecutar, cancelar y devolver resultado/error; sin acceso directo a objetos AppKit ni callbacks por cada tecla. Un ejemplo de plugin y una especificación corta serían suficientes para empezar a documentar su desarrollo.

El editor no esperaría al plugin para dibujar o aceptar escritura. Las peticiones tendrían plazo, tamaño máximo y concurrencia limitada; las respuestas tardías se descartan. Al terminar, el proceso se cierra o permanece solo durante un período breve acordado. Medir CPU y memoria y detener plugins que excedan la política es un requisito por implementar, no una garantía que ya ofrezca el prototipo. Incluso fuera del proceso principal, un plugin puede competir por CPU, memoria o disco.

Transporte pendiente de una prueba pequeña: mensajes estructurados por entrada/salida estándar o un servicio auxiliar propio con XPC. Apple ofrece [servicios XPC iniciados bajo demanda](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html). Esto no resuelve automáticamente la instalación de plugins arbitrarios de terceros. Antes de admitirlos se debe cerrar firma, distribución y aislamiento real de permisos; un manifiesto no restringe por sí solo los accesos de un ejecutable.

No incorporar por anticipado Node, Python, un navegador, un motor WebAssembly o un marketplace. La primera prueba debe demostrar que un comando de terceros puede fallar, tardar o producir demasiada salida sin bloquear el editor. El SDK y los tipos adicionales solo crecen cuando exista un caso de uso acordado.

## 5. Tecnología: estado de las decisiones

| Elemento | Estado |
| --- | --- |
| macOS nativo | Acordado; única plataforma actual |
| Swift 6 + AppKit | Base técnica propuesta en el planteamiento original |
| NSTextView + TextKit 2 | Candidato; validar edición y archivos grandes antes de consolidar |
| Tree-sitter | Candidato para análisis incremental y resaltado |
| SwiftTerm 1.20.0 | Integrado para terminal local AppKit |
| Núcleo Rust compartido | Reevaluar; ya no se justifica por portabilidad futura dentro del alcance actual |
| API/SDK de IA | Pendiente; elegir tras definir capacidades y permisos |
| Runtime y protocolo de plugins | Pendiente; prototipo medido antes de adoptarlos |

La organización modular debe responder a necesidades presentes: interfaz, proyectos, documentos, lenguajes, terminal, IA, modificaciones y extensiones. No añadiremos capas solo para preparar otras plataformas.

### Código ordenado y reutilización con propósito

La aclaración del usuario prevalece sobre el énfasis anterior en «código mínimo»: buscamos orden, utilidad y ahorro de tiempo dentro de la visión del producto. Es válido escribir más código propio o adoptar un componente amplio cuando el resultado lo justifique. La ligereza se verifica midiendo el producto completo.

- Usar los componentes de AppKit y Foundation antes de crear equivalentes propios.
- Organizar por responsabilidad; separar biblioteca, ventana de trabajo y persistencia. Dividir archivos cuando mezclen responsabilidades, no por un número arbitrario de líneas.
- Añadir protocolos o abstracciones cuando exista una frontera real, como proveedor de IA o comunicación con plugins; no crear una interfaz por cada clase.
- Reutilizar dependencias cuando aporten capacidades necesarias, ahorren tiempo y tengan costes aceptables de integración, mantenimiento y consumo. Pocas líneas propias no garantizan una aplicación ligera.
- No introducir Rust ni una arquitectura multiplataforma sin una necesidad actual demostrada.
- Conservar validación de datos, tratamiento de errores y pruebas de riesgos reales; la claridad prima sobre comprimir el código.
- Revisar cada cambio por alcance, claridad, dependencias, actividad en reposo y efecto en las mediciones acordadas.

El prototipo actual es una base de validación visual, no prueba aún de consumo mínimo. Ordenar sus responsabilidades y medir una base de rendimiento se propone como siguiente tarea antes de ampliar funcionalidades; no se ejecuta esta refactorización ni el runtime de plugins en esta actualización documental.

## 6. Rendimiento como criterio de aceptación

Antes del código acordaremos equipo y versión de macOS de referencia, conjuntos de archivos y presupuestos para:

- Tiempo hasta mostrar la biblioteca y abrir un proyecto.
- Memoria y CPU en reposo, edición, terminal e IA activa.
- Latencia de escritura y navegación con resaltado y plugins.
- Apertura de archivos grandes y árboles de proyectos grandes.
- Recursos por plugin activo y comportamiento al excederlos.
- Actividad en segundo plano y consumo energético.

No hay cifras aprobadas todavía. Las comparaciones usarán el mismo equipo, datos y condiciones. Un ensayo de aceptación debe incluir un plugin lento, uno que falla y otro que produce demasiados eventos.

## 7. Tareas para definir entre ambos

Las tareas de definición siguientes continúan pendientes salvo los aspectos ya acordados. La autorización actual se limita a las tareas de primera versión indicadas debajo.

| ID | Tarea | Resultado para aprobar | Dependencias |
| --- | --- | --- | --- |
| DEF-01 | Cerrar alcance del primer MVP | Funciones incluidas, excluidas y recorrido principal | Ninguna |
| DEF-02 | Definir qué significa «extremadamente ligero» | Equipo, escenarios y presupuestos de rendimiento | DEF-01 |
| DEF-03 | Diseñar el trabajo intensivo con IA | Conversaciones, contexto, permisos, progreso y revisión | DEF-01 |
| DEF-04 | Definir el primer sistema de plugins | Casos admitidos, API, aislamiento y límites | DEF-02, DEF-03 |
| DEF-05 | Elegir arquitectura y dependencias | Módulos, tecnologías, distribución y justificación de cada dependencia | DEF-02 a DEF-04 |
| DEF-06 | Especificar biblioteca y navegación | Flujo carpeta → nombre → abrir; configuración `.fscode/`, índice global, estados y recuperación | DEF-01 |
| DEF-07 | Especificar editor y lenguajes iniciales | Comportamiento de documentos, guardado y autoindentación | DEF-01, DEF-02 |
| DEF-08 | Diseñar escrituras, atribución y reversión de IA | Modelo de operaciones, conflictos y cobertura de comandos | DEF-03, DEF-04 |
| DEF-09 | Convertir decisiones en tareas de implementación | Tareas pequeñas con entradas, entregables y pruebas | DEF-05 a DEF-08 |
| DEF-10 | Acordar orquestación con modelos económicos | Modelos, reparto, revisión, presupuesto y escalado | DEF-09 |
| DEF-11 | Definir apariencia nativa y temas | Liquid Glass, versión mínima de macOS, modos claro/oscuro, temas del código y aceptación de accesibilidad y rendimiento | DEF-01, DEF-02 |
| DEF-12 | Definir TODOs por proyecto | Vista alternable con `Files` mediante iconos en el lateral izquierdo, creación manual y detección en comentarios; detalle, finalización y persistencia | DEF-01, DEF-02, DEF-07 |

Orden sugerido para conversar: DEF-01 → DEF-02 → DEF-03 → DEF-04. Después cerrar arquitectura y desglosar el trabajo.

### Primera versión autorizada: distribución

El usuario autorizó comenzar y encargó a Codex elegir entre los modelos disponibles. GPT-5.6 Terra se usa para código AppKit y persistencia por su equilibrio entre capacidad y coste; GPT-5.6 Luna para una investigación acotada. La integración y verificación quedan a cargo del agente principal. Son subagentes de esta tarea, no nuevas tareas independientes de la aplicación.

| ID | Encargo | Ejecutor | Aceptación | Estado |
| --- | --- | --- | --- | --- |
| V01-01 | Biblioteca: seleccionar carpeta, nombrar y abrir; persistencia mínima | GPT-5.6 Terra | Carpetas reales, cancelación sin cambios, duplicados y conservación de archivos | Implementada; flujo por ruta validado, selector nativo pendiente |
| V01-02 | Distribución AppKit de cuatro áreas | GPT-5.6 Terra | Separadores ajustables, mínimos útiles, visibilidad y apariencia nativa | Implementada y comprobada visualmente; límites en informe |
| V01-03 | Investigación de componentes open source | GPT-5.6 Luna | Licencias verificadas, uso comercial, encaje técnico y límites | Terminada: `docs/OPEN_SOURCE.md` |
| V01-04 | Integración, paquete de aplicación y validación | Agente principal | Compilación, pruebas de datos y recorrido visual | Release generado, 5 pruebas correctas; pendientes documentados |

La elección de modelos se apoya en la [guía oficial de OpenAI](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-5.6). No se fija un coste monetario de esta sesión a partir de tarifas API.

### Plantilla de cada tarea acordada

- ID y título:
- Estado: propuesta / definida / aprobada / en curso / en revisión / terminada.
- Problema y resultado esperado:
- Alcance y exclusiones:
- Decisiones necesarias:
- Dependencias:
- Criterios de aceptación, incluidos rendimiento y fallos:
- Modelo ejecutor y presupuesto acordados:
- Archivos o módulos a cargo:
- Evidencias de validación:
- Revisión y decisión final:

## 8. Reglas para la futura ejecución

- No implementar tareas aún no acordadas.
- Delegar a modelos económicos solo después de definir el trabajo y seleccionar los modelos conjuntamente.
- Cada encargo tendrá límites claros y criterios verificables.
- Codex coordinará, revisará e integrará los resultados; la salida de un subagente no equivale a tarea terminada.
- Medir el efecto de las dependencias y de los plugins sobre el rendimiento.
- Actualizar este archivo cuando cambien las decisiones o el alcance.

## 9. Estado real del repositorio

Antes de la pausa se creó un borrador Swift Package con `ProjectLibrary` y una interfaz AppKit. Con la nueva autorización se está reutilizando y corrigiendo para entregar la biblioteca y la distribución acordada.

En la entrega inicial no había editor funcional. La actualización TEXT-01 a TEXT-03 incorpora edición de texto; terminal, IA, plugins y Rust siguen sin implementarse. Se ha delegado código a dos subagentes Terra y la investigación de licencias a Luna.

La compilación del borrador anterior falló por un directorio de pruebas ausente. La entrega integrada corrige ese problema, compila y pasa cinco pruebas. El paquete ejecutable está en `dist/FS Code.app`. El alcance verificado y los pendientes están en `docs/VALIDACION.md`; el editor de texto se incorporó posteriormente en TEXT-01 a TEXT-03; todavía no hay terminal activa ni conexión con modelos.

## 10. Registro de decisiones

| Fecha | Decisión |
| --- | --- |
| 2026-09-23 | Mostrar el detalle del TODO en el centro y solo títulos en el lateral; listas `Open` y `Closed`, 10 iniciales por lista y `Load More`, orden por relevancia/fecha y vínculo opcional de archivo |
| 2026-09-23 | Implementar TODOs manuales por proyecto: título, descripción, comentarios y estado; persistencia JSON en `.fscode/todos.json`. Detección en código pendiente |
| 2026-09-23 | Llevar los cambios visuales al prototipo a petición del usuario: barra compacta, menú `View` y selector lateral `Files` / `TODOs`. Vista TODOs provisional; creación y detección pendientes |
| 2026-09-23 | Usar la captura de Nova como referencia para una barra superior sencilla, limpia y compacta; propuesta UI-01 documentada, sin implementar todavía |
| 2026-09-23 | Usar inglés como único idioma soportado por la aplicación; traducir la interfaz del prototipo y declarar `en` en el bundle |
| 2026-09-23 | Crear este documento vivo para evolucionar el producto y sus tareas |
| 2026-09-23 | Priorizar uso intensivo de IA, macOS nativo y consumo mínimo |
| 2026-09-23 | Sacar otras plataformas del alcance actual |
| 2026-09-23 | Incluir extensibilidad como requisito; diseño concreto pendiente |
| 2026-09-23 | Pausar implementación y definir tareas conjuntamente antes de delegar código |
| 2026-09-23 | Exigir apariencia plenamente macOS con Liquid Glass y soporte claro/oscuro; proponer Dracula y Alucard para el código, pendientes de aprobación |
| 2026-09-23 | Concretar el inicio como biblioteca → seleccionar carpeta → asignar nombre → abrir; proponer configuración oculta `.fscode/` más índice global local |
| 2026-09-23 | Autorizar primera versión con cuatro áreas ajustables y contenido funcional diferido; delegar con modelos seleccionados por Codex e investigar componentes de uso comercial |
| 2026-09-23 | Reforzar código mínimo, ordenado y consumo mínimo; concretar propuesta gradual de plugins declarativos y comandos en procesos auxiliares, sin implementar aún el runtime |
| 2026-09-23 | Aclaración posterior: priorizar código ordenado y reutilizar lo que aporte a la visión y ahorre tiempo; reducir código propio no es un objetivo en sí mismo. Mantener la exigencia de bajo consumo |
| 2026-09-23 | Analizar harnesses y protocolos en `docs/HARNESS.md`; candidatos y tareas propuestos, sin autorizar aún implementación ni adoptar dependencias |
| 2026-09-23 | Incorporar TODOs por proyecto como requisito: creación manual con nombre, descripción y comentarios, y detección de `TODO:` en comentarios del código. La ubicación inicial debajo del árbol fue sustituida por la decisión siguiente |
| 2026-09-23 | Usar un único lateral izquierdo con iconos `Files` y `TODOs` para alternar entre las dos vistas; sustituye el subpanel inferior propuesto. Implementación pendiente |

### Actualización TEXT-05 — 2026-09-23

Autorizada por la petición de números de línea, Dracula y reconocimiento automático. Terra implementó el índice/margen y el detector/lexer en subtareas separadas; el agente principal integró, revisó y comprobó la aplicación. No se incorporaron paquetes externos. El resaltado léxico completo en segundo plano es una primera versión, no un parser incremental ni resaltado semántico. Estiliza mediante atributos nativos sin modificar texto guardado o historial Undo. Ver límites y pruebas en `docs/VALIDACION.md`.

### TEXT-07 — Cabecera de documentos (2026-09-23)

Petición aprobada: pestañas alineadas a la izquierda con icono y nombre, y debajo la ruta en disco del archivo activo. Implementación AppKit: barra horizontal de documentos, controles de selección/cierre y ruta nativa `NSPathControl`; conservar borradores, Undo y protección de cierre. Terra implementa el componente de pestañas; el agente principal integra y valida. Sin dependencias nuevas. Estado: implementado y verificado en claro/oscuro; selección, cierre con cancelación, Undo, ruta y desbordamiento de pestañas comprobados.

### TEXT-08 — Estado y selección de documentos (2026-09-23)

Implementado: punto visible junto al nombre de cada pestaña con cambios sin guardar, incluido cuando está inactiva; selección del árbol sincronizada con la pestaña activa y con el cierre que activa otro documento. Las carpetas necesarias se expanden sin quitar el foco del editor. La selección programática evita reabrir documentos o crear un ciclo de eventos. Validado en la aplicación compilada con archivos temporales.

### NAV-01 — Cambiar y cerrar proyecto (2026-09-23)

Petición aprobada: `File → Switch Project…` (⇧⌘L) y `File → Close Project` (⇧⌘W) cierran el proyecto actual y vuelven a la biblioteca. Reutilizar el control de borradores de archivos y TODOs; cancelar conserva el proyecto abierto. El botón rojo también vuelve a la biblioteca tras cerrar. `Project Library` (⌘L) conserva su función de mostrar la biblioteca sin cerrar el proyecto. Estado: implementado; menús, atajos, cancelación de borrador, cambio entre proyectos y regreso con botón rojo comprobados.

### UI-02 — Inicio simplificado y línea activa (2026-09-23)

Autorizado: biblioteca reducida a proyectos y acción principal `Open Folder…`; menú de tres puntos por proyecto para editar o quitar de la biblioteca, manteniendo la carpeta intacta. Abrir/registrar carpeta conserva el significado actual de proyecto. Terra implementa la biblioteca; el agente principal integra y valida.

El editor resalta suavemente la fila visual del cursor y su margen de números en claro/oscuro. Es un fondo dibujado mediante TextKit 2; no modifica texto ni estado de guardado, y se oculta al seleccionar texto para conservar la selección nativa. Estado: implementado; biblioteca y línea activa comprobadas en oscuro, modo claro y casos adicionales pendientes de recorrido visual.

### TERM-01 — Terminal integrada nativa (2026-09-23)

Petición aprobada: terminal real con estilo coherente con la aplicación. SwiftTerm 1.20.0 fijado como componente AppKit, una sesión local por proyecto iniciada en su carpeta, fuente monoespaciada del editor y paletas Dracula/Alucard. Cabecera nativa compacta; ocultar conserva la sesión, reiniciar solo tras salida. Historial de pantalla limitado a 2.000 líneas.

Terra implementa el panel; el agente principal integra dependencia, empaquetado, menús y ciclo de vida. Antes de cerrar con un comando en primer plano se ofrece cancelar; la sesión solo termina tras confirmar el cierre real. Sin integración de IA ni gestión múltiple de terminales en esta entrega. Estado: implementado y compilado; sesión real, apariencia clara/oscura y comandos básicos comprobados. Validación de cierre con proceso activo, reinicio y accesibilidad pendiente; detalles en `docs/VALIDACION.md`.

### IMAGE-01 — Imágenes y edición SVG (2026-09-23)

Petición aprobada: mostrar imágenes en las pestañas del área central; para SVG alternar `Preview / Code` sin perder el borrador, selección ni Undo. AppKit/NSImage para SVG e ImageIO para vistas raster reducidas; sin dependencias nuevas ni motor web. Las imágenes raster son de solo lectura. Conservar pestañas, ruta y selección del árbol existentes. Terra implementó el visor y revisó/terminó los ajustes delegados; la integración inicial del principal precedió a la reafirmación de delegar todo el código. Estado: implementado y compilado; PNG y edición/vista previa SVG comprobados en la aplicación. 42 pruebas y validación detallada en `docs/VALIDACION.md`.

### Regla permanente de ejecución — 2026-09-23

El usuario reafirma que el agente principal debe planificar y orquestar, delegando siempre la implementación de código y pruebas a modelos más económicos. El principal revisa y verifica el resultado, y mantiene la documentación. La regla queda incorporada a `AGENTS.md`; para IMAGE-01 el ajuste final y cualquier corrección adicional pasan al implementador Terra.

### LAYOUT-02 — Conservar tamaños y compactar controles SVG (2026-09-23)

El usuario detecta que los paneles no conservan el tamaño elegido. Reproducido en la aplicación: ocultar y mostrar terminal cambió su altura aproximada de 348 a 261 puntos. Criterios: el arrastre nativo conserva la medida elegida; ocultar/mostrar recupera la última medida visible; cambiar Files/TODOs y contenido no redistribuye el espacio; el área central absorbe el cambio de tamaño de ventana cuando los mínimos lo permiten; persistencia conserva medidas válidas. Reset Layout mantiene su acción explícita de restaurar valores iniciales.

Además, el usuario pide colocar `Preview / Code` en la fila de la ruta, alineado totalmente a la derecha y solo visible para SVG, eliminando su fila separada.

Plan y revisión: agente principal. Implementación delegada: Terra `panel_sizes` para distribución y regresiones; Terra `svg_path_controls` para selector SVG. Archivos separados y compilación coordinada. Estado: implementado y validado. Se guardan las dimensiones de los paneles completos de NSSplitView, evitando perder el margen del lateral nativo; prioridades de conservación válidas para AppKit y centro flexible. Comprobados ocultación/reaparición de terminal y asistente, cambio de tamaño de ventana y restauración de medidas personalizadas al reabrir. Detalles en `docs/VALIDACION.md`.

### MD-01 — Vista previa Markdown (2026-09-23)

Petición aprobada durante LAYOUT-02: los archivos `.md` y `.markdown` deben permitir alternar el texto fuente y su presentación procesada con el mismo selector `Preview / Code` de los SVG, en la fila de la ruta y a la derecha. Markdown abre inicialmente en Code; la vista previa usa el borrador actual sin escribir el archivo. Conservar Undo, selección, pestañas y avisos de guardado. Preferir análisis de Markdown del sistema y presentación AppKit, sin navegador ni nuevas dependencias.

Implementación delegada a Terra `markdown_preview`, incluyendo la integración común de documentos con vista previa. El principal mantiene plan, revisión y validación. Compilación coordinada con el implementador de LAYOUT-02. Estado: implementado y comprobado en claro/oscuro, con apertura en Code y selector compartido alineado a la derecha. Vista de lectura nativa con títulos, párrafos, listas, énfasis, citas, enlaces y código; imágenes y presentación de tablas pendientes. Pruebas de borrador, Undo, guardado y formato correctas.

### UI-03 — Unión entre cabecera y editor (2026-09-23)

El usuario señala una línea adicional junto a la cabecera del archivo en una captura del lateral nativo redondeado. En Code aparecía una línea tenue del margen prolongada sobre la ruta/pestañas; en Preview no aparecía. Implementación delegada a Terra `markdown_preview`: limitar el dibujo del NSScrollView del código mediante `clipsToBounds`, sin capas adicionales. El principal recompiló y comprobó cabeceras de Markdown y JSON en oscuro: margen contenido y números visibles, medidas de paneles conservadas. Estado: corregida la línea vertical; la consulta sobre una posible franja horizontal adicional sigue sin respuesta y no se cambió ese espaciado. El redondeado del lateral sigue siendo el nativo de macOS.

### TERM-02 — Color funcional en la terminal (2026-09-23)

El usuario aclara que el texto de la terminal resulta demasiado uniforme; no pide cambiar el fondo. Conservar Dracula/Alucard y la composición nativa. Usar color para orientar: carpeta del prompt, resultado correcto/error con código de salida visible, cursor y tipos de archivo al listar. La salida de cada programa conserva sus secuencias ANSI; no colorear arbitrariamente todo stderr ni añadir decoración sin función.

Implementado: personalizar únicamente el prompt estándar de zsh por sesión, conservando prompts personalizados, configuración y archivos del usuario. Colores mediante índices ANSI de la paleta actual, sin procesos Git por prompt, plugins de shell ni dependencias nuevas. Respeta NO_COLOR y opciones existentes. Implementación delegada a Terra `panel_sizes`; el principal revisó el arranque del shell y verificó la aplicación. Estado: completado, 53 pruebas correctas; prompt, error con código, cursor y directorios comprobados en claro/oscuro. El archivo temporal de inicio restaura ZDOTDIR antes de continuar el arranque normal; no se editan dotfiles.

### CTX-01 — Agent Context local (2026-09-23)

Especificación aprobada: motor determinista de instrucciones, administración global y por proyecto, detección de formatos externos e inspector del archivo activo. El usuario elige expresamente entregar ahora el motor y panel local; conexión con IA y harness después. No se necesita LLM para detectar, resolver precedencia, evaluar globs, medir ni componer contexto.

Plan presentado antes de implementar: nuevo módulo `AgentContextCore` y pruebas; integración AppKit en `ProjectSidebarView`, `WorkspaceWindow`, `TextEditorView` y nuevas vistas de gestión/inspección. Persistencia propia en `.fs/context/`, sin cambiar los TODOs ni la biblioteca. Fuentes externas inactivas hasta activación explícita. Conservar metadatos y distribución actual.

Delegación: Terra prepara el contrato y la integración inicial; Sol completa motor/persistencia y flujos AppKit; GPT-5.5 termina el detector y sus pruebas. Investigación de formatos con fuentes oficiales y pruebas de aceptación independientes. El principal define contratos, revisa y valida. Detalle en `docs/AGENT_CONTEXT.md`. Estado: motor y panel local implementados; 81 pruebas correctas, persistencia e inspección comprobadas en macOS. Conexión de IA/harness diferida por decisión del usuario. El botón Agent Context comparte el lateral con Files y TODOs, según su aclaración expresa.

### LLM-01 — Conectar cuentas y seleccionar modelos (2026-09-23)

El usuario autoriza comenzar la integración LLM: varias conexiones guardadas y selector dentro del panel derecho, utilizando el mismo harness. Primera prueba con su suscripción ChatGPT mediante OAuth; ofrecer también OpenAI API key. La autorización sustituye el aplazamiento de la conexión, empezando por autenticación y selección de modelos.

Primera entrega: perfiles independientes, login oficial de ChatGPT, API key, estado real, cierre/cancelación de sesión y catálogo dinámico. Ambos métodos utilizan Codex App Server por stdio; credenciales en Keychain, índice local sin secretos y directorios del runtime separados de la instalación Codex del usuario. Ejecución de conversaciones/herramientas será la siguiente tarea, con el contexto determinista existente. No se promete soporte automático para APIs de otros proveedores.

Plan presentado y definido en `docs/LLM_CONNECTIONS.md`. Dos implementadores Terra: módulo `AgentConnectionCore` y pruebas; controles AppKit del asistente y composición en `WorkspaceWindow`. El principal verifica documentación oficial, protocolo instalado, revisión, compilación y GUI. Estado: en implementación.

Revisión: el transporte inicial requirió una segunda implementación con Sol para completar cancelación, notificaciones OAuth y limpieza de procesos. El usuario concreta un botón permanente `Connect Model…` en el panel derecho, con lista de tipos `Codex — ChatGPT OAuth` / `Codex — API Key` y formulario específico. Sustituye expresamente el texto `Add LLM`.

Siguiente etapa CHAT-01: conversaciones independientes por proyecto en ese mismo panel, selector de hilos, `New Chat`, entrada abajo, mensajes por turno arriba, progreso y detención, modelo y pensamiento por conversación según capacidades reales. Compartir gestión de FS Editor y motor inicial Codex; pendiente de implementación tras las conexiones.


### Prioridad: trabajar desde FS Editor

Ante la petición de una versión utilizable, la prioridad pasa a completar el recorrido Connect Model → ChatGPT → enviar mensaje → respuesta real en el panel. CHAT-01 y CHAT-02 se desarrollan como siguiente incremento inmediato: Sol implementa el servicio de conversación y Terra la UI AppKit, con contratos y archivos separados. Acabados restantes quedan en el backlog. Las escrituras de IA siguen supeditadas al servicio de trazabilidad; el primer chat será explícitamente de sólo lectura.

Incremento integrado: conexión, conversaciones persistentes por proyecto/perfil, streaming, Stop, catálogo y pensamiento por hilo. Suite completa de 108 pruebas correcta; release firmado y abierto en `dist/FS Code.app`. El flujo OAuth oficial está iniciado y espera el acceso del usuario para verificar un turno real. No se marca esa validación como concluida ni se habilitan escrituras automáticas. El contexto efectivo administrado, revisión de cambios y acabados pendientes conservan sus tareas separadas.

### APP-01 — About y licencia MIT

Petición del usuario: About con versión alpha, crédito de creación conjunta y licencia MIT. Versión visible `0.1.0 Alpha`, versión numérica de bundle `0.1.0` y build `1`. Panel estándar de AppKit accesible desde `FS Code → About FS Code`, con el icono propio, crédito `Created by Daniel Lares with Codex.` y copyright de Daniel Lares. Codex figura como asistencia de creación, no como titular del copyright.

Se incluye `LICENSE.txt` en el repositorio y una copia en la aplicación; se conservan los avisos de terceros de SwiftTerm y Dracula/Alucard. Referencia del texto: [MIT, Open Source Initiative](https://opensource.org/license/mit). Implementación delegada a Luna; el principal revisa, compila y verifica el panel nativo. Sin dependencias nuevas ni ventana de About personalizada.

### LLM-02 / CHAT-03 / AGENT-01 — Flujo de trabajo del agente

Decisiones explícitas: las conexiones de cuentas pertenecen a cada proyecto, con sesiones independientes y credenciales en Keychain; abrir otro proyecto comienza sin cuentas asociadas. No basta con recordar sólo el modelo. UI inspirada en la organización de Cursor y construida con AppKit: historial arriba, conversación, entrada y controles compactos debajo; configuración fuera del flujo principal.

El usuario solicita trabajo real del agente. Se implementa edición propuesta mediante herramienta dinámica del harness, con revisión nativa, aprobación, servicio único de escritura, hashes e historial reversible. El runtime mantiene las herramientas directas dentro del sandbox de lectura. Reparto: Terra para panel y revisión AppKit; Sol para aislamiento de proyectos/transporte/servicio de cambios; Sol para integración de herramientas en conversaciones. El principal define contratos, verifica protocolo, revisa y valida. La primera respuesta autenticada ya fue comprobada; los nuevos comportamientos no se declaran terminados hasta probarlos.

## Decisiones de chat y contenedores — 23 de septiembre de 2026

- Conexiones y cuentas independientes por proyecto: A puede usar una cuenta Codex y B otra; ningún proyecto nuevo hereda una cuenta global.
- Referencia de organización del chat: Cursor/Zed; respuestas alineadas a la izquierda con Markdown, código y jerarquía legible; controles compactos junto al compositor. Implementación nativa AppKit.
- Paneles internos rectos, sin esquinas redondeadas decorativas; separadores finos.
- Scroll superpuesto y ocultación automática, conservando preferencias de accesibilidad de macOS.

## AGENT-02: cambios directos y revisión por bloques

Decisión del usuario: los cambios de IA se aplican directamente, sin una aceptación previa por parche. El editor debe informar de forma determinista qué documentos y qué bloques se modificaron; señalar los bloques en el código, mostrar su versión anterior y permitir revertir un bloque individual. La reversión debe conservar cambios posteriores ajenos y bloquearse si el bloque ya no puede identificarse con seguridad. Esta decisión sustituye el flujo de aprobación previa de AGENT-01. Se conservan aislamiento por proyecto, registro local, límites de archivos, protección de borradores y sandbox de las demás herramientas.

Reparto: Sol implementa hunks/persistencia/reversión segura y coordinación del harness; Terra implementa historial por turno, navegación, resaltado y revisión nativa de bloques. El principal revisa y prueba el flujo real. Sin dependencias nuevas.

Estado AGENT-02: motor, conversación y controles implementados; 124 pruebas completas y 2 pruebas UI adicionales correctas, paquete release generado. La inspección visual del flujo automático queda pendiente hasta desbloquear el Mac; no se marca la tarea terminada antes de esa comprobación.


## GIT-01/04 — panel Git y grafo nativo

Petición del usuario: añadir Git al selector lateral izquierdo, visualizar cambios/staged, ramas, stashes y grafo de commits, con operaciones Git integradas. Investigación y tareas propuestas en [GIT_INTEGRATION.md](docs/GIT_INTEGRATION.md). Candidatos: Git oficial vía Process + piezas MIT de Maple para el grafo; SwiftGitX/libgit2 si se prioriza motor enlazado. GitUpKit es AppKit pero GPLv3, no se incorpora al esquema MIT actual. La funcionalidad se registra; selección final y ejecución pendientes de acordar. No se añadieron dependencias ni código de aplicación en esta evaluación.


## MCP — conexiones centralizadas por proyecto

Decisión del usuario: añadir MCP al selector lateral izquierdo; administrar servidores, conexión, autenticación y herramientas por proyecto. Las conversaciones y modelos compatibles del harness comparten esta configuración sin reinstalar por agente. Credenciales en Keychain, metadatos no secretos en `.fscode/mcp.json`; otros proyectos no heredan las cuentas. Plan y criterios en [MCP_PROJECT.md](docs/MCP_PROJECT.md). Propuesta de ejecución registrada; todavía no se añadieron dependencias ni conexiones. Mantener trazabilidad de archivos IA: un MCP con escritura directa no puede saltarse el servicio auditado bajo una promesa de reversión.


## RTK — requisito del harness

El usuario pide Rust Token Killer integrado como optimización opcional: usarlo cuando esté disponible y permitir instalarlo fácilmente, manteniendo el harness operativo sin él. Ejecutable compartido en el equipo y preferencia por proyecto. Se confirmó RTK 0.49.0 en este Mac, pero la integración dentro de FS Editor aún no está implementada. Plan/criterios: [RTK_INTEGRATION.md](docs/RTK_INTEGRATION.md). Filtrar únicamente salidas elegibles para el modelo; conservar datos de Git/MCP, parches y códigos de error. No repetir acciones con efectos por un fallo posterior del filtro.


## UPD-01 — actualizaciones con Sparkle fuera de la App Store

El usuario autoriza añadir Sparkle para distribuir actualizaciones directamente, sin App Store por ahora. Integrar Sparkle 2 y `Check for Updates…` en el menú de la aplicación; preservar cierre con borradores y mostrar UI nativa. Terra implementa controlador, dependencia y empaquetado; principal revisa y valida. Sin feed HTTPS ni clave pública de actualizaciones definidos todavía, el updater permanece inactivo y no realiza peticiones. Preparar configuración de distribución sin inventar alojamiento, generar claves privadas ni publicar artefactos. Estado: en implementación.

UPD-01 integrada: Sparkle 2.10.0, configuración validada, menú nativo y framework empaquetado. Canal elegido: GitHub Releases + catálogo público; repositorio concreto aún sin confirmar. Suite completa de 129 pruebas correcta, release y firma ad hoc verificados, aplicación relanzada y Check for Updates deshabilitado confirmado mediante accesibilidad. UPD-02 continúa pendiente de feed/clave/firma de distribución y prueba real entre versiones. Configuración: [UPDATES.md](docs/UPDATES.md).


## CHAT-04 — composición del asistente y revisión de rendimiento

El usuario autoriza rediseñar el panel derecho inspirándose en la captura de Cursor: pestañas para varias conversaciones, historial para recuperar pestañas cerradas, cabecera compacta y compositor integrado con conexión, modelo, pensamiento y envío. AppKit nativo, panel exterior recto, inglés, colores semánticos y claro/oscuro. Cerrar una pestaña no borra el hilo ni su borrador. Preservar aislamiento por proyecto/cuenta, streaming, Stop y revisión de cambios por bloques. No añadir controles de funciones inexistentes.

Terra implementa el panel y pruebas; el principal define criterios, revisa y valida el paquete/GUI. Otro Terra revisa rendimiento de editor, árbol, contexto y persistencia sin modificar código; el principal revisa actualización del chat. Medir o etiquetar expresamente como hipótesis cada oportunidad. Evitar prometer rendimiento relativo a Zed a partir de sesiones distintas.

Criterios: abrir/cambiar/cerrar/reabrir conversaciones sin pérdida de borradores; controles utilizables a 340 puntos y en ancho amplio; contenido alineado a la izquierda, scroll estable al leer mensajes anteriores, menús conectados al catálogo real, sin recargar contenido que no cambió durante streaming. Revisión de rendimiento con rutas concretas, desencadenantes y plan de medición. Estado: en implementación.

CHAT-04 implementada y compilada; 131 pruebas completas y 29 UI tras acabado final correctas. Verificado en GUI cierre/reapertura de pestañas, borradores y restauración al reiniciar. Acabado final de superficies pendiente de inspección claro/oscuro por timeouts persistentes de CUA; no se fuerza cierre. Revisión de rendimiento completada en docs/PERFORMANCE_REVIEW.md, con PERF-02/03/04 pendientes de medición.


## CHAT-05 — controles, contexto y turnos del agente

El usuario pide acercar la calidad del panel a Cursor/Zed: selectores de agente/cuenta, modelo y pensamiento legibles; porcentaje de contexto; separación de turnos y actividad visible. Se autoriza mejorar la composición y conectar telemetría real del harness, conservando AppKit, aislamiento, pestañas y borradores.

Contrato: porcentaje derivado de `thread/tokenUsage/updated.tokenUsage.last.inputTokens / modelContextWindow`, rotulado como contexto de entrada de la última solicitud. No usar `total` acumulado, inferir capacidad por nombre del modelo ni presentar ausencia como cero. Mostrar detalle y estado no disponible. Actividad por turno enlazada a mensaje de usuario e item: fases reales de razonamiento (sin contenido interno), comandos/herramientas, estado y salida limitada. No añadir botones de modos, adjuntos o voz que no funcionen.

Reparto: Terra para UI y controles adaptables a 340/760 puntos; Terra para core y pruebas de telemetría con revisión independiente. Principal verifica esquema local y documentación oficial, integración, pruebas y presentación. Sin dependencias nuevas. Compatibilidad de historiales antiguos y descarte de eventos de otro hilo/cuenta/modelo requeridos.

La inspección automatizada de la ventana sigue dando timeout; se consulta al usuario si responde manualmente. Preparar renders de las vistas AppKit con datos de prueba sólo en tests permite revisar composición claro/oscuro sin afirmar validación del flujo real. Estado: en implementación.

CHAT-05, revisión de integración: el núcleo conserva mensajes de respuesta por item para que comentarios y respuesta final no se sobrescriban. Se endurece la lectura de números JSON (0/1 no son booleanos) y se descartan eventos tardíos al cambiar de modelo/cuenta. Actividad opcional acotada antes de persistir; nunca se almacena contenido interno de razonamiento. Fuente del protocolo: esquema del Codex instalado y [App Server](https://learn.chatgpt.com/docs/app-server).

El primer acabado de UI delegado a Terra no completó el desplegado de actividad ni la composición adaptable; Sol toma exclusivamente ese remate y el fixture visual. Esta escalada se limita a corregir esos incumplimientos verificables; el principal conserva revisión y compilación.

CHAT-05 implementada: menús de conexión/modelo/pensamiento y compositor adaptable; contexto informado por el runtime; mensajes por item y actividad desplegable por solicitud. 138 pruebas completas y 30 UI tras últimos ajustes correctas. Inspección de fixture AppKit en claro/oscuro, 340/760 puntos y estado plegado detectó y permitió corregir recorte, placeholder y captura inicial de pestañas. La app real sigue inaccesible mediante CUA; revisión autenticada pendiente y tarea conservada abierta por ese motivo.

## CHAT-06 — compositor único y selectores inline

24 de septiembre: el usuario aporta nuevas referencias de Zed/Cursor y pide quitar la apariencia de botones grandes separados. Selectores nativos de texto/icono sin caja individual, compactos y alineados en una fila dentro del compositor; el modelo puede truncarse con tooltip y la cuenta/contexto compactarse a iconos en anchos estrechos. Un único contenedor con fondo discreto, entrada superior y controles inferiores. Mensajes del usuario con fondo sutil y respuestas abiertas. Mantener funciones reales, accesibilidad, catálogo, contexto y aislamiento, sin añadir controles ficticios. Terra implementa alcance visual; principal revisa fuentes, render y paquete. Estado: en implementación.

CHAT-06 implementada y empaquetada: 30 pruebas UI correctas en la ejecución final; release y verificación de firma correctos. Controles en una fila, Extra High completo, contexto como anillo a 340 puntos y porcentaje visible al ampliar. Capturas AppKit revisadas en claro/oscuro y actividad plegada/desplegada. Pendiente recorrido en ventana real por timeout de CUA; no se relanzó la app.

## CHAT-07 — cola de mensajes y Steer

24 de septiembre: permitir escribir y enviar mientras el agente trabaja. Enviar durante un turno añade a una cola FIFO propia de la conversación, proyecto y conexión. Una lista compacta sobre el compositor muestra pendientes con `Steer` y eliminación individual. `Steer` incorpora ese mensaje al turno activo mediante `turn/steer` con `expectedTurnId`, sin detenerlo ni crear otro. La cola avanza después de una finalización correcta; Stop, error o desconexión la pausan conservando texto. Al reabrir la aplicación queda pausada hasta `Resume`. No enviar nuevamente un mensaje de resultado incierto de manera automática.

Persistencia compatible con historiales existentes, límites de tamaño/cantidad, identidad estable de mensaje y comprobación de perfil/sesión/turno. No mostrar como enviado un mensaje aún pendiente; conservar borrador si falla el guardado. Manejar finalización del turno mientras Steer está pendiente sin duplicar, mezclar hilos o enviar al siguiente turno por accidente.

Implementación delegada a Terra: núcleo y pruebas de transporte; UI AppKit y fixtures con propiedad separada. Principal valida protocolo instalado, revisa aislamiento/carreras y ejecuta pruebas/paquete. Criterios: FIFO, Steer aceptado/rechazado, doble acción, finalización concurrente, Stop, reconexión, reinicio y JSON antiguo; compositor editable y cola usable a340/760 puntos, claro/oscuro. Estado: en implementación.

Fuente de protocolo: [Codex App Server](https://learn.chatgpt.com/docs/app-server), sección Steer an active turn; esquema local `.build/llm-protocol/v2/TurnSteerParams.json` y `TurnSteerResponse.json`.

CHAT-07 implementada: cola persistente, avance FIFO, Steer real del protocolo y acciones nativas compactas. Suite completa147 pruebas correctas; fixtures claro/oscuro a340/760 revisados. Recorrido autenticado pendiente por bloqueo de CUA; sin cambios en credenciales ni permisos del harness.

CHAT-07: paquete release generado en `dist/FS Code.app`; `codesign --verify --deep --strict` correcto. No se relanzó automáticamente la aplicación abierta.

## CHAT-08 — Enter para enviar y revelar el mensaje propio

24 de septiembre: Enter envía (o encola durante el trabajo), Shift+Enter inserta un salto de línea. Command-Return se conserva como alias. Mantener composición IME, edición nativa y foco del compositor. Actualizar ayuda/placeholder en inglés.

Una acción de envío revela el mensaje realmente incorporado al transcript después del layout aunque se estuviera leyendo arriba. Un pendiente nuevo se revela en su lista acotada, y Steer aceptado revela su mensaje en el chat. No desplazar la lectura de mensajes anteriores por simples fragmentos de la respuesta, ni por una acción fallida o una respuesta tardía de otra conversación. Implementación acotada UI/pruebas delegada a Terra; principal revisa y verifica. Estado: en implementación.

CHAT-08 implementada: teclado nativo y revelado por identidad de mensaje y conversación, con corrección acotada de alturas automáticas de AppKit. 31 pruebas FSCodeTests correctas; tras reforzar visibilidad completa de filas que caben en la ventana, las dos pruebas AssistantChatPreviewTests vuelven a pasar. Sin cambios en el núcleo ni dependencias. Pendiente recorrido en la ventana real; no se relanzó la sesión abierta.

CHAT-08: compilación release y verificación de firma correctas; paquete actualizado en `dist/FS Code.app`.

## CHAT-09 — progreso legible y color en respuestas

24 de septiembre: mostrar durante el turno un resumen público de progreso en texto secundario, actualizado en su lugar, y la respuesta definitiva con contraste normal. Consumir únicamente resúmenes públicos del runtime, nunca bloques de razonamiento bruto; sin texto inventado cuando el proveedor no informa un resumen. Mantener aislamiento de conversación/perfil/turno y limpiar el estado transitorio al finalizar o cambiar de sesión. Los comentarios del agente se distinguen de las respuestas finales cuando el protocolo informa su fase.

Enlaces con color semántico y subrayado; código inline y referencias a archivos distinguibles, sin forzar una paleta oscura sobre la interfaz clara. Revisar líneas largas y cambios de ancho. Corregir la presentación de tablas sin juntar celdas y mostrar una indicación honesta para referencias opacas sin URL, conservando el mensaje original. AppKit, sin nuevas dependencias ni recursos remotos.

Terra implementa núcleo y pruebas, otro Terra el renderer Markdown; luego se integra la UI con propiedad separada de archivos. Principal revisa, valida y empaqueta. Fuente del protocolo: [Codex App Server](https://learn.chatgpt.com/docs/app-server), eventos summaryTextDelta/summaryPartAdded y fase de agentMessage. Estado: en implementación.

### Evaluación del motor — 24 de septiembre

CHAT-09 implementada y validada con 156 pruebas; paquete release firmado localmente. Progreso temporal, fases y formato ya disponibles; revisión en ventana real pendiente. Ver `docs/VALIDACION.md`.

Pregunta del usuario: por qué Codex frente a Pi o AgentRunKit. Estado real: FS Code integra el motor Codex App Server mediante transporte JSON-RPC; todavía no dispone de un bucle de agente propio común para todos los proveedores. Su elección inicial resuelve el acceso ChatGPT del usuario, no demuestra superioridad sobre otras opciones.

[Pi](https://pi.dev/) ofrece un harness multiproveedor extensible y RPC; [AgentRunKit](https://github.com/Tom-Ryder/AgentRunKit) ofrece un SDK Swift con núcleo sin dependencias de otros targets y proveedores API. El usuario aprobó migrar a AgentRunKit con autenticación propia el 24 de septiembre. El manifiesto completo declara paquetes opcionales aunque el target del núcleo no los enlace. No se midió memoria comparativa. Comparación futura sobre la misma tarea: memoria total incluyendo procesos hijos, arranque, streaming, herramientas auditadas, Stop/Steer, aislamiento por proyecto, persistencia y OAuth. Mantener los datos/UI del editor separados del protocolo del motor.

## HARNESS-01 — AgentRunKit y cuentas por proyecto

Decisión aprobada: AgentRunKit como base Swift del motor común. Versión examinada: v6.0.0, commit `c5bce5d70d3b3b57415beee9f7f4522ab53e6d88`. Requiere macOS 15 y Swift 6.1; enlazar únicamente el producto principal, sin MLX. No presentar una reducción de RAM como medida hasta comparar ejecutables y procesos equivalentes.

La autenticación pertenece a FS Editor. La identidad local estable del proyecto y el UUID de conexión forman el ámbito de las credenciales en Keychain. Un proyecto puede tener varias conexiones al mismo servicio; crear otro proyecto no hereda sus cuentas. Los archivos del proyecto guardan metadatos, nunca tokens ni API keys. Mover una carpeta conserva la identidad del proyecto en la biblioteca; copiar metadatos a otro proyecto no comparte credenciales.

| Tarea | Criterio de aceptación | Estado |
| --- | --- | --- |
| HARNESS-01A | SDK fijado, compilación nativa, licencia y requisitos documentados. | Implementado; ver validación del corte |
| HARNESS-01B | OAuth propio por código de dispositivo, cancelación, renovación y Keychain aislados; API keys en el mismo esquema. | Implementado; ver validación del corte |
| HARNESS-01C | Adaptador del motor con historial, streaming, herramientas auditadas, Stop, cola y Steer sin duplicaciones. | Implementado; ver validación del corte |
| HARNESS-01D | Conectar desde la hoja nativa, modelos de la cuenta seleccionada y reconexión explícita de perfiles anteriores. | Implementado; recorrido real pendiente |
| HARNESS-01E | Pruebas de aislamiento/races/herramientas, paquete y recorrido autenticado. | Pruebas y paquete aprobados; recorrido autenticado pendiente |

El SDK incluye `ResponsesAPIClient.chatGPTBaseURL`, pero no nuestro login. El flujo por dispositivo se contrasta con las fuentes públicas de OpenAI; usar el cliente público existente es una vía de compatibilidad, no una garantía de registro propio ni de autorización comercial de terceros. Conservar las credenciales antiguas sin leerlas, importarlas ni borrarlas automáticamente. La renovación no puede restaurar credenciales eliminadas o sustituidas mientras una solicitud estaba en vuelo.

La API `Agent` examinada no expone inyección de mensajes durante un turno. Resolver Steer en un límite real del bucle y conservarlo en el historial; no simularlo cancelando y reiniciando una tarea. Conservar controles de rutas y servicio de escritura auditado: un runtime en proceso no implica por sí mismo el sandbox de Codex.

### Alcance confirmado de la prueba

AgentRunKit debe quedar detrás de un protocolo interno `AgentEngine`. El editor conserva cuentas, permisos, resolución determinista de instrucciones, sesiones, herramientas y auditoría. Cambiar el motor no debe requerir reescribir la GUI. No se presupone soporte comercial ni capacidad del equipo mantenedor; tampoco una reducción de memoria sin mediciones.

Prueba acotada de una semana como referencia de alcance, no ejecución programada:

1. Abrir un proyecto y resolver `AGENTS.md` y reglas para el archivo de trabajo; mostrar el contexto efectivo sin LLM.
2. Ejecutar un agente implementador y un subagente revisor, con responsabilidades separadas, límites de trabajo y resultados visibles.
3. Ejecutar comandos con aprobación explícita y mostrar los cambios mediante diff. Las escrituras de IA conservan el registro y la reversión por bloque.
4. Persistir y restaurar la sesión, manteniendo conversación, configuración y resultados; las operaciones interrumpidas no se repiten automáticamente.

Primero cerrar una base compilable y verificable; después completar estas cuatro pruebas de extremo a extremo. Las mejoras genéricas del adaptador podrán prepararse para upstream, pero no se publican automáticamente. El quinto punto del texto enviado estaba vacío y no añade alcance.

Estado del primer corte (24 de septiembre, cierre): el usuario autorizó terminar directamente esta integración como excepción a la delegación. Producción utiliza `NativeAgentRuntime` detrás de `AgentEngine`, con clientes AgentRunKit y bucle controlado por FS Editor. CodexRuntime permanece para compatibilidad y pruebas, no como motor de las ventanas de proyecto.

Incluye OAuth por dispositivo, API key y Keychain por projectID/profileID; catálogo de cuenta; contexto local al iniciar/restaurar; historial nativo persistente; lectura/búsqueda fuera de AppKit; edición mediante el servicio auditado; Stop y Steer entre solicitudes del mismo turno. Las llamadas interrumpidas no se repiten al restaurar. El historial se almacena en Application Support, separado por proyecto y conexión. La nueva conexión requiere iniciar sesión explícitamente: no importa credenciales antiguas.

Validación automatizada: 167 pruebas, una visual omitida y cero fallos. Una prueba integral atraviesa conexión, conversación, motor y servicio de edición real; otra prueba verifica restauración y aislamiento del historial. Proveedor y credenciales simulados: no equivale a una prueba autenticada. Pendientes: recorrido OAuth/modelo real y revisión visual en ventana, subagentes, comandos con aprobación, preguntas interactivas y resúmenes públicos de pensamiento en el nuevo motor. No declarar completo el piloto ni ahorro de memoria medido.


### HARNESS-01B — corregir acceso de escritorio

El usuario rechazó el código de dispositivo como acceso predeterminado. Sustituirlo por autorización en navegador con PKCE S256, state aleatorio y callback HTTP en loopback, iniciando el listener antes de abrir el navegador. Regresar a FS Editor sin redirigir a otra aplicación. Mantener credenciales aisladas por projectID/profileID, cancelar al cambiar conexión y mostrar un error claro si el puerto está ocupado. El flujo de dispositivo no se inicia automáticamente. Implementado: pruebas enfocadas de PKCE, callback, state incorrecto, denegación, cancelación, puerto ocupado e integración con conexión por proyecto aprobadas. El navegador muestra una página local y la aplicación recupera el foco; no redirige a Codex. Recorrido con cuenta real pendiente de autorización del usuario.


### HARNESS-01D — versión del catálogo

Corrección: el parámetro `client_version` de ChatGPT pertenece al protocolo de catálogo de Codex, no a la versión 0.1.0 de FS Editor. Se separa como compatibilidad explícita 0.153.4, respaldada por el catálogo local exitoso de Codex. No ejecutar Codex para descubrirla ni copiar su caché como sustituto del servicio. Endpoint API sin cambios. Pruebas enfocadas aprobadas (6); release y firma local aprobados. Verificación CUA de la app real: proyecto abierto, chat conectado, selector GPT-5.6-Luna y respuestas visibles; sin repetir OAuth.


### HARNESS-01C — cierre del streaming Responses

Estado final validado: el adaptador reconstruye un output terminal vacío usando únicamente eventos output_item.done completos, contiguos y tipados; reutiliza la proyección del SDK y mantiene reconciliación estricta. response.incomplete falla explícitamente. GPT-5.6-Luna conectado por OAuth respondió y ejecutó la creación de test.txt solicitada por el usuario; CUA y lectura de disco confirmaron hola mundo y el indicador de cambio IA. Suite final: 157 XCTest (1 omitida) + 23 Swift Testing sin fallos. App release abierta y firma verificada. Los párrafos siguientes conservan la secuencia de diagnóstico; el límite anterior sobre response.incomplete queda corregido por este parche local.

Regresión detectada en uso real: llegaba texto y el turno terminaba con error. AgentRunKit 6.0.0 Responses emite `.finished` y cierra normalmente, sin `.streamClosed`; nuestro adaptador exigía ambos eventos. Corregir la condición por proveedor, mantener rechazo de un marcador explícitamente negativo o de EOF sin `.finished`, y verificar el cliente real del SDK con SSE simulado además de una conversación real que llegue a estado completado. No considerar texto parcial como evidencia de éxito.


Corrección implementada: Responses admite `.finished` + EOF normal sin marcador adicional; un `.streamClosed(false)` permanece inválido y EOF sin `.finished` no habilita herramientas. Prueba con ResponsesAPIClient y SSE real simulado aprobada. Límite conocido de AgentRunKit 6: el contrato público expone `response.incomplete` también como `.finished`; distinguir ese estado requiere ampliar el contrato del proveedor. No se modificó el SDK ni se relajó la validación de argumentos o autorización de escrituras.


Validación real posterior al primer parche: respondió OK pero falló con categoría `stream-state-mismatch`. Se mantiene una copia local fijada del núcleo AgentRunKit 6.0.0 en Vendor/AgentRunKit (licencia y procedencia incluidas) para aplicar la corrección de reconciliación sin editar archivos temporales de SwiftPM. No se añade otro runtime ni se publica un fork. Sustituir por versión upstream sólo después de repetir las pruebas. La copia contiene únicamente el target core utilizado, no MLX ni targets opcionales.

### DEVTOOLS / TOKEN-01 / CHAT-14 — verificación

24 septiembre 2026: suite nativa completa sin fallos: 188 XCTest (1 omitido) + 33 Swift Testing. Checkpoint reconocido pasa a Task details cerrado; siguiente acción real visible, valores vacíos/None/Ninguno ocultos. No equivale al restore point de archivos. RTK automático para comandos directos compatibles; permisos por proyecto y herramientas Build implementados. Accesibilidad requiere permiso macOS. Comandos arbitrarios no ofrecen aún restore auditado por bloque. Sin publicación de release en esta tanda.

### CHAT-15 — desplazamiento estable durante streaming

Solicitud: evitar saltos mientras se escribe la respuesta. Diagnóstico: al refrescar una fila se descartaba su altura y caía temporalmente a 52 puntos; scrollRowToVisible se repetía por actualización. Criterios: conservar alturas de mensajes existentes, seguir el final únicamente cuando el lector estaba allí, conservar mensaje y desplazamiento al leer arriba y mantener el comportamiento al redimensionar. Implementación delegada; verificar con deltas simulados sin llamadas al proveedor.

CHAT-15 implementado: alturas conservadas por prefijo estable de IDs, callbacks de medición invalidados en cada recarga, ancla restaurada y eliminado scrollRowToVisible repetido. Cuatro pruebas AppKit pasaron con exportación visual: deltas, seguimiento al final, lectura arriba y reflow. Revisión de captura estrecha; sin llamadas reales al modelo para esta validación.

### UI-16 — colores nativos de macOS

Especificación del usuario guardada en docs/NATIVE_MACOS_COLORS.md. Chrome usa colores semánticos y materiales AppKit; únicamente editor y terminal conservan Dracula/Alucard. Delegado en dos bloques sin solapamiento: interfaz general y editor/terminal. Verificar apariencias, selección, callbacks de capas, tamaños persistidos y capturas claro/oscuro con archivo y cambio de agente.

UI-16 validation: 191 XCTest and 33 Swift Testing tests passed with both visual artifact flags enabled. Source scan found no hex/RGB literals or disabled focus rings in FSCode chrome. Editor appearance tests verify semantic focus-color mapping and unchanged text/Undo; they do not replace real key-window lifecycle inspection. Inspector geometry now persists from the middle pane trailing edge plus divider thickness; repeated save/reopen is covered. Native material bitmap exports are not accepted as visual evidence because offscreen AppKit composition produces artifacts. Per-step plan statuses and a font settings screen are not added in this chrome-only change; existing whole-plan statuses receive semantic symbols.

UI-16 real-window verification: CUA inspected the release executable in a temporary review bundle, with test.txt open, agent inspector visible and audited change markers in the gutter. Light/Dark switched without restart and both screenshots were inspected. This exposed titlebar overlap; content now respects safe areas while sidebar material extends underneath. Workspace layout tests were rerun successfully after that correction, and the local release app was rebuilt. The review copy was restored to System appearance and closed. It did not validate authenticated chat (separate bundle identity remained Connecting), system accent changes, or the full Increase Contrast/Reduce Transparency OS matrix. Those checks remain pending. Local app: dist/FS Code.app; no release publication in this turn.

### THEME-01 — local Base16 editor and terminal themes

User specification: docs/BASE16_THEMES.md. Independent color-only themes for light/dark slots; built-in Dracula/Alucard preserve exact existing rendered values and terminal palettes. Imported Base16/Base24 YAML follows the explicit role mapping, validates every required color and never changes chrome, fonts, system selection, find highlights or change markers. Native Settings with local Import Theme, explicit replacement and missing-selection notice. Implementation delegated to core/parser/store, editor/terminal integration and native settings agents. Main agent reviews, verifies and packages. No bundled third-party schemes or network theme downloads.

THEME-01 validation: 205 XCTest executed (2 optional screenshot tests skipped), zero failures; 33 Swift Testing passed. Real-window checks imported both current and legacy YAML, rejected an incomplete file with its missing key, and confirmed editor/terminal changes while native chrome stayed unchanged. Dracula/Alucard were visually compared in both app appearances; exact palette values, unchanged font/Undo and no re-lexing are covered by tests. Final Settings preview displays colored syntax tokens and the local release was rebuilt. Synthetic imported themes were removed, default slots restored and the review copy closed. Direct switching through macOS System Settings, the OS accessibility matrix and pixel-level screenshot comparison remain unverified. No release or push in this task.

### DEVTOOLS-02 — executable lookup regression

2026-09-25: Published 0.1.1 rejected bare `git` argv before spawn, then replaced the validation error with a generic command-start failure. Confirmed against saved conversation activity for status, diff and remote. Fix delegated: deterministic executable lookup outside the project, actionable launch errors, regression test using bare Git through commit and a local bare-remote push. Existing WorkspaceWindow.swift edits belong to the user and remain untouched. Absolute `/usr/bin/git` is a workaround for the published binary.

DEVTOOLS-02 validation: `swift test --build-system native --filter "ProjectCapabilityStoreTests|NativeAgentRuntimeTests"` passed 22 tests, zero failures. Includes bare Git command execution, local commit/push, minimal PATH fallback, project-path exclusion and actionable runtime launch diagnostics. No installed binary replacement, release publication, commit or push in this fix; the user is actively developing from the installed editor.

Release 0.1.2 / build 3: user requested Git fix publication. Includes user-authored rectangular sidebar change and command launcher fix. Full suite: 208 XCTest (2 skipped), 33 Swift Testing, zero failures. Deploy context verified enabled and injected; it contains an unconditional release task and actually caused release operations after a greeting. No context-loader patch justified; waiting for clarification about intended behavior, preserving user context.
