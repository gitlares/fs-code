# Agent Context

Decisión del 23 de septiembre de 2026: el motor y la interfaz funcionan localmente, sin internet, credenciales ni modelos. El usuario ha diferido explícitamente la conexión con IA y el harness. No se simulan solicitudes ni resultados de un agente.

## Responsabilidades

- `AgentContextCore`: detección, almacenamiento, evaluación de alcance, ordenación, diagnósticos y composición exacta del contexto.
- Interfaz AppKit: gestión de fuentes propias, activación explícita de fuentes externas e inspección del archivo abierto. Utiliza el mismo motor; no mantiene una segunda interpretación de las reglas.
- Integración futura del harness: consumir la instantánea resuelta, comprobar sus diagnósticos y registrar las fuentes de una solicitud real. La ayuda para redactar instrucciones será opcional y producirá borradores para revisión.

Los archivos detectados son datos del proyecto. Leerlos para mostrarlos no significa ejecutar instrucciones, comandos, referencias o herramientas que contengan.

## Persistencia y permisos de uso

Las reglas propias del proyecto viven en `.fs/context/`: Markdown para el contenido e índice JSON versionado para nombre, identificador, alcance, destino, prioridad y estado. Las reglas globales propias de la aplicación usan `~/Library/Application Support/FS Code/context/`. La biblioteca de proyectos y los TODOs mantienen sus ubicaciones actuales.

Abrir un proyecto no crea archivos de configuración. Las fuentes externas se detectan inicialmente inactivas y sólo se incluyen al activarlas explícitamente. Su edición se realiza abriendo el archivo original mediante el editor; la detección nunca lo reescribe. Las reglas ignoradas no aportan texto al resultado.

## Orden del contexto

La composición recorre primero las reglas globales propias, después proyecto, carpetas de raíz a hoja, patrones glob, archivo específico y finalmente las fuentes externas activadas. Dentro de cada nivel se utiliza un orden estable y explícito. Para fuentes externas, la precedencia nativa sólo se reproduce en los casos soportados y documentados; no existe una precedencia universal entre herramientas distintas.

Una instrucción más específica se añade después de la general. Esto no autoriza al editor a deducir que dos frases se contradicen ni a eliminar reglas anteriores por su significado. Las sustituciones explícitas y los duplicados exactos se identifican con su procedencia.

Las rutas se evalúan con límites de carpeta, no con coincidencias de prefijo ambiguas. Los patrones no soportados, configuraciones inválidas, escapes por enlaces simbólicos y exploraciones incompletas se muestran como diagnósticos; no deben generar coincidencias aproximadas silenciosas.

## Interfaz

`Agent Context` se incorpora al selector lateral junto a `Files` y `TODOs`. El árbol agrupa las fuentes por alcance/origen; el área central presenta su detalle, contenido y acciones. Las reglas propias permiten crear, editar, cambiar nombre, activar/desactivar y eliminar. Las externas muestran proveedor, ruta, alcance, estado y la acción explícita para abrir su archivo.

El pie del editor conserva los metadatos del documento y añade el resumen de contexto del archivo activo. `View Effective Context` abre el inspector con el orden de fuentes, razones de inclusión/exclusión, contenido individual y texto consolidado exacto. No duplica la gestión de reglas.

La cifra de bytes se calcula sobre el texto consolidado real, incluidas sus cabeceras de procedencia. Los tokens, si se muestran, son una estimación identificada como tal; no son una medida específica de un modelo. El exceso de presupuesto se informa sin truncar silenciosamente.

La actualización usa notificaciones locales de cambios en disco, agrupadas para evitar escaneos repetidos. Cambiar de pestaña reutiliza el catálogo de fuentes y sólo vuelve a resolver el alcance del archivo activo. Un cambio externo no debe reemplazar un borrador abierto; el detalle conserva el texto y señala el conflicto para que el usuario decida.

## Compatibilidad de esta versión

| Fuente | Comportamiento local |
| --- | --- |
| FS Code | Global, proyecto, carpeta recursiva, patrón y archivo. Orden por alcance; dentro del mismo nivel, menor prioridad primero y mayor después, con desempate estable. |
| `AGENTS.md` / `AGENTS.override.md` | Herencia por carpetas. El primer archivo no vacío según la precedencia nativa sustituye al otro en la misma carpeta; no elimina las instrucciones de carpetas superiores. |
| Claude | `CLAUDE.md`, `CLAUDE.local.md`, `.claude/CLAUDE.md` y `.claude/rules/**/*.md`. Alcance por carpeta y metadatos `paths` en el subconjunto soportado. |
| Cursor | `.cursorrules` de raíz y `.cursor/rules/**/*.mdc`. `alwaysApply`, `globs` y distinción de reglas manuales o solicitadas por el agente. La activación explícita sigue siendo necesaria. |
| Copilot | `.github/copilot-instructions.md` y `.github/instructions/**/*.instructions.md` de raíz. `applyTo`; `excludeAgent` se muestra como no soportado porque todavía no hay una superficie de harness seleccionada. |
| `GEMINI.md` | Detectado para inspección; sus reglas nativas de resolución todavía no están implementadas y el contenido no se incluye. |

Los globs admiten `*`, `**` y `?`; `**/*.swift` incluye archivos de raíz y de subcarpetas. No se admiten negaciones, clases de caracteres, llaves ni escapes. Los metadatos admiten valores simples y listas acotadas; YAML complejo, claves duplicadas y tipos inválidos se señalan sin ampliar el alcance por aproximación.

Las importaciones de instrucciones de Claude/Copilot no se expanden en esta versión; esas fuentes quedan señaladas como no soportadas. Los ajustes `project_doc_fallback_filenames` y `project_doc_max_bytes` de `.codex/config.toml` se detectan pero todavía no se interpretan: se informa que la resolución nativa está incompleta. No se leen configuraciones globales de esas herramientas ni credenciales.

Límites predeterminados: 20.000 archivos recorridos, profundidad 64, 1 MiB por archivo de instrucciones y 4 MiB por manifiesto. El catálogo admite hasta 512 fuentes y 16 MiB de contenido total, compartidos entre fuentes propias y externas; alcanzar estos límites señala exploración incompleta y bloquea el uso del resultado. El contexto consolidado tiene presupuesto de 64 KiB, una política de FS Code que no representa la ventana de ningún modelo ni el límite nativo de todas las herramientas. Exceder ese presupuesto conserva el texto consolidado completo para inspección y marca que no debe enviarse. Se excluyen `.git`, `.build`, `node_modules`, `dist`, `vendor` y el almacén propio del escaneo externo.

Las escrituras utilizan reemplazos atómicos por archivo y validación del contenido existente. No se ofrece una transacción de base de datos entre procesos ni recuperación de borradores tras un cierre inesperado.

## Entrega y validación

Implementación delegada: contrato e integración inicial con Terra; finalización con Sol tras la revisión y cierre del motor con GPT-5.5 cuando Sol dejó de estar disponible por capacidad. Investigación de formatos externos y pruebas de aceptación separadas. El principal revisa el código, las exclusiones, el formato consolidado y los flujos reales en macOS.

Casos de aceptación local: persistencia entre reaperturas, reglas por proyecto/carpeta/glob/archivo, prioridad estable, herencia, activación externa, exclusión de ignoradas, sustitución AGENTS documentada, duplicados, límites, cambios externos, guardado con conflicto y conservación de borradores. Verificar también que la selección de pestaña actualiza el inspector sin perder números de línea, estado del archivo, terminal ni tamaños de paneles.

Motor y panel local implementados. Las comprobaciones efectivas y límites de la revisión visual se registran en `docs/VALIDACION.md`. La integración de IA y harness sigue diferida.
