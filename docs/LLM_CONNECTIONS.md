# LLM-01 — Conexiones de modelos

Entrega priorizada el 23 de septiembre de 2026: conectar cuentas, conservar varias conexiones y conversar desde el panel derecho, con elección de modelo y pensamiento. Las modificaciones de archivos se implementan en AGENT-01/02, descritos al final; no se presentan respuestas simuladas.

## Decisión técnica

ChatGPT y OpenAI API utilizan un único adaptador de Codex App Server mediante stdio. El flujo de navegador y la renovación OAuth los gestiona Codex oficialmente. La suscripción ChatGPT no es una API key y el consumo por API tiene facturación independiente. No se extraen credenciales de la aplicación Codex ni de su configuración existente.

Decisión del usuario: **las cuentas se conectan por proyecto**, no globalmente. El proyecto A puede usar una cuenta de Codex y el B otra; B comienza sin conexiones, sin heredar las de A. Cada proyecto posee su administrador, selección, sesión y catálogo. Cerrar sesión en uno no afecta al otro. Los metadatos se guardan en `.fscode/connections.json` del proyecto; no contienen secretos.

Cada conexión tiene un UUID y un directorio privado del runtime bajo Application Support de FS Code. Codex recibe `cli_auth_credentials_store="keyring"` para conservar las credenciales en Keychain, sin fallback a texto plano. Cambiar de conexión dentro del proyecto detiene su proceso anterior sin cerrar su sesión guardada. Sólo se inicia el runtime cuando se utiliza la conexión, no uno por cada perfil guardado. La conexión global del prototipo se migra únicamente al proyecto FS editor donde el usuario acaba de crearla; otros proyectos no la importan automáticamente.

El ejecutable Codex se descubre localmente o se selecciona con un panel nativo. Esta primera versión no descarga ni incluye ese ejecutable dentro de la aplicación. Ambos tipos de conexión usan el mismo runtime; la futura incorporación de otros proveedores necesitará un adaptador compatible y validación propia.

## Tareas y aceptación

- LLM-01A: módulo `AgentConnectionCore`, perfiles, persistencia atómica sin secretos, transporte JSON-RPC acotado, autenticación oficial, cancelación, desconexión y catálogo real de modelos paginado.
- LLM-01B: reemplazar el placeholder derecho por `AssistantConnectionView`, selector de conexión/modelo y hoja nativa para añadir ChatGPT u OpenAI API. Mantener tamaños de paneles, claro/oscuro, inglés y accesibilidad.
- Aclaración de interfaz: botón permanente `Connect Model…` en el panel derecho y hoja `Connect Model`; lista de tipos `Codex — ChatGPT OAuth` / `Codex — API Key`. El formulario pide los datos correspondientes y comienza ese flujo tras confirmarlo. No usar `Add LLM`.
- LLM-01C: verificar aislamiento entre perfiles, que un fallo no aparezca como conexión válida, finalización/cancelación del proceso, ausencia de credenciales en el índice y build/GUI real. Autenticación final requiere que el usuario complete el navegador o introduzca su API key en la aplicación.

No se envían archivos ni reglas al conectar o listar modelos. El primer chat permite consultas sobre el proyecto en un sandbox de sólo lectura. La integración de la resolución exacta de `AgentContextCore`, respetando exclusiones y registrando fuentes, corresponde a CTX-02.

## Contrato de implementación

Los implementadores coordinan las firmas concretas antes de integrar. El módulo de conexiones expone perfiles identificados por UUID con nombre, método (`chatGPT` / `openAIAPI`) y modelo seleccionado; un administrador observable en MainActor pertenece a un único proyecto. Operaciones: cargar, añadir, renombrar, seleccionar, quitar, conectar, cancelar login, desconectar sesión, refrescar cuenta/modelos, seleccionar modelo y configurar ruta del ejecutable. La interfaz no interpreta JSON-RPC ni maneja tokens OAuth.

Los callbacks del proceso se reciben fuera del actor principal y actualizan la interfaz sólo al volver a MainActor. Cada operación usa una generación de sesión para descartar respuestas tardías. EOF, error y timeout resuelven todas las solicitudes pendientes. No se registra el contenido de mensajes de autenticación ni stderr sin filtrar.

## Fuentes oficiales

- [Codex App Server](https://learn.chatgpt.com/docs/app-server): integración en productos, stdio, inicialización, cuentas y catálogo de modelos.
- [Autenticación](https://learn.chatgpt.com/docs/auth): ChatGPT, API key, facturación y almacenamiento en Keychain.

## Estado

En implementación. Las comprobaciones realizadas se registrarán en `docs/VALIDACION.md`.

## CHAT-01 — Conversaciones

El usuario confirma que este mismo panel será el espacio de conversación con el agente, inspirado en la organización de Codex/Cursor y realizado con controles AppKit. Entrada en la parte inferior; mensajes agrupados por turno arriba; progreso, respuesta incremental y detención visibles. `New Chat` crea una conversación independiente dentro del proyecto y un selector permite volver a otras conversaciones.

Cada conversación conservará identificador propio, historial, conexión, modelo y nivel de pensamiento. Las capacidades y valores disponibles proceden del catálogo real; no se presentan niveles que el modelo no soporte. Cambiar de modelo conserva el hilo cuando el proveedor lo permite. Cambiar de conexión requiere conservar la separación de sesiones y explicar cualquier transferencia de historial; no se reutiliza un identificador de otro perfil silenciosamente.

La capa común de FS Editor gestionará conversaciones, contexto efectivo, permisos y registro de operaciones. El primer motor es Codex App Server. El chat inicial permite herramientas de consulta bajo sandbox de sólo lectura, sin acceso de red para comandos. Las escrituras del agente requieren primero el servicio de modificaciones y su trazabilidad.

El historial y los borradores se almacenan en `.fscode/conversations.json`, separados por proyecto y perfil de conexión; no contiene credenciales. El cierre de proyecto y de aplicación guarda explícitamente el borrador. Si falla ese guardado, la ventana permanece abierta para permitir recuperarlo. Los límites iniciales son 100 conversaciones, 500 mensajes por conversación, 512 KiB por texto y 4 MiB para el archivo de historial; un borrador excesivo no se recorta silenciosamente.


## Prioridad de uso — 23 de septiembre de 2026

El usuario pide llegar ya a una versión utilizable. Se prioriza CHAT-01/02 inmediatamente después de estabilizar autenticación, en paralelo con la UI: conversación real con historial por proyecto, respuestas incrementales, selección de modelo/pensamiento y Stop. Primera entrega en modo de sólo lectura; la escritura autónoma depende de AGENT-01. No se anuncian conversaciones operativas hasta probar el envío y la recepción con el runtime real.

El chat inicial no integra todavía el contexto efectivo administrado en Agent Context. Debe evitar cargar reglas ignoradas por vías implícitas del runtime; los parámetros y límites comprobados se registrarán en la validación. CTX-02 sigue separado.

## Revisión de uso y trabajo real

La cuenta se autenticó y el modelo respondió realmente `FS Editor conectado.` dentro de la aplicación. El usuario señaló dos problemas de uso: el final del login conducía a una pantalla de Codex y los controles parecían deshabilitados al no existir un chat. Se cambia al final local oficial de OAuth, se muestra la carga del catálogo y se prepara automáticamente la primera conversación sin duplicar las existentes. Sólo la ventana que inició el acceso recupera el foco al completarlo.

La organización del panel toma Cursor como referencia: historial y nueva conversación arriba, mensajes en el centro, entrada abajo y selectores compactos de conexión/modelo/pensamiento en su pie. Gestión de cuentas en un menú secundario; sin bloques de configuración, email, facturación ni etiquetas repetidas en la conversación.

Incremento AGENT-01 autorizado: `fs_edit_file` como herramienta dinámica del harness. Codex mantiene su sandbox de sólo lectura; el editor recibe la propuesta, muestra el diff y escribe mediante un único servicio tras aprobación. Registro con conversación/turno, hashes, fecha y cambio, y reversión que rechaza sobrescribir modificaciones posteriores. La API dinámica es experimental y se comprueba contra la versión local de Codex; no se habilitan comandos arbitrarios del host ni escrituras directas del runtime.


## AGENT-02 — aplicación directa y revisión posterior

La decisión posterior del usuario sustituye la aprobación previa por parche. `fs_edit_file` aplica los cambios directamente una vez comprobados el archivo, el borrador del editor y la identidad vigente de proyecto, conexión, conversación y turno. Las instrucciones del harness describen este comportamiento en `thread/start` y `thread/resume`; las demás herramientas mantienen el sandbox de lectura.

El registro local produce bloques deterministas, sin pedir al modelo que calcule diferencias. El chat muestra los archivos y líneas afectados. El editor ofrece resaltado, marcas ✦, navegación, `Original` y `Revert` sobre el bloque seleccionado. El original y el texto aplicado por IA permanecen consultables aunque una edición posterior impida localizar el bloque. No se necesita Git.

Una reversión individual identifica el texto aplicado y su contexto único, conserva el contenido ajeno y registra el resultado. Si el archivo tiene un borrador sin guardar o el bloque fue modificado/queda ambiguo, no lo sobrescribe. Los registros antiguos se adaptan desde sus instantáneas; una reversión interrumpida se reconcilia con hashes. Para limitar memoria, un diff superior al presupuesto de comparación se agrupa en un bloque mayor.

Implementado y compilado; la validación automatizada y el estado de la prueba visual constan en `docs/VALIDACION.md`.
