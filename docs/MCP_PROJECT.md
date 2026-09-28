# MCP centralizado por proyecto

Fecha: 23 de septiembre de 2026. Requisito del usuario: un botón MCP en el selector lateral izquierdo, con gestión de servidores y credenciales por proyecto; todas las conversaciones y modelos compatibles usan las conexiones del proyecto a través del harness de FS Editor. Esta entrega define arquitectura y tareas; no conecta servidores ni añade código/dependencias.

## Decisión de producto

La conexión MCP pertenece al proyecto, no a una cuenta de modelo ni a una conversación. Cambiar de modelo/conversación dentro del proyecto conserva configuración y credenciales MCP. Otro proyecto tiene conexiones y autorizaciones propias; no hereda cuentas automáticamente. Las credenciales MCP y las credenciales del proveedor del modelo son independientes.

FS Editor actúa como host MCP. Un servicio MCPProjectCore administra catálogo, transportes, procesos, autenticación y permisos, y el registro de herramientas del harness lo consume. Este modelo encaja con la [arquitectura host/client/server de MCP](https://modelcontextprotocol.io/specification/2025-11-25/architecture). No presupone que una aplicación externa como Claude Code o Cursor herede nuestras conexiones: cada runtime que incorporemos necesita un adaptador y soporte de herramientas.

## Interfaz AppKit propuesta

Nuevo botón `MCP` junto a Files, TODOs, Agent Context y el Git solicitado. Lista lateral de nombres con estado discreto (Connected, Disconnected, Needs Sign In, Error) y `Add Server…`. Detalle en el centro: conexión local/remota, herramientas y permisos, Connect/Disconnect/Reconnect/Remove y diagnósticos sin secretos. Configuración de URL/comando y autenticación en hoja nativa, con campos según tipo. No convertir el panel de conversación en otra pantalla de configuración.

Soportar servidores locales stdio (ejecutable/argumentos/entorno) y remotos Streamable HTTP (URL). Mostrar dependencias faltantes de servidores locales; centralizar configuración no elimina su posible requisito de Node, Python u otro runtime. Añadir un servidor y autorizar ejecutar su comando son acciones explícitas; abrir un repositorio con configuración nueva no debe ejecutar código automáticamente.

## Persistencia y credenciales

- `.fscode/mcp.json`: formato versionado con identificadores de servidor, nombre, transporte, URL o comando/argumentos no secretos, nombres de variables y política deseada. Nunca tokens, contraseñas, cabeceras Authorization ni credenciales incrustadas en URL/argumentos.
- Keychain de macOS: API keys, cabeceras secretas y access/refresh tokens; referencias resueltas mediante identidad local del proyecto + servidor + recurso/cuenta. Copiar o clonar el JSON no concede acceso a credenciales existentes.
- Application Support: consentimientos locales, asociaciones al proyecto y cachés acotadas, fuera del repositorio. Cambios externos en URL/comando/configuración invalidan el consentimiento afectado.
- OAuth cuando el servidor lo soporte; API key/token/entorno cuando lo requiera. No prometer OAuth universal ni reutilizar el token de ChatGPT para otro servicio.
- Desconectar detiene el uso; quitar elimina la asociación local según la opción elegida. Diferenciar borrar la credencial local de revocarla en el proveedor cuando éste lo permita.

La [autorización MCP](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization) define el flujo HTTP; stdio recibe credenciales por entorno del proceso. Se entregan únicamente los secretos necesarios al servidor elegido y nunca al contexto del modelo, historial ni logs.

## Enlace con el harness existente

El código actual registra `fs_edit_file` mediante dynamicTools y atiende `item/tool/call`; todavía no hay administrador MCP propio. El [App Server oficial](https://learn.chatgpt.com/docs/app-server) ofrece herramientas dinámicas experimentales. El adaptador Codex puede usar esa vía para delegar llamadas al servicio MCP de FS Editor; futuros adaptadores usarían el mismo contrato interno.

No usar los archivos globales de configuración de cada agente como fuente principal. Evaluar un puente de descubrimiento/descripción/ejecución con catálogo acotado para evitar inyectar todas las herramientas al prompt y para soportar altas/bajas sin recrear conversaciones innecesariamente. La versión instalada conserva dynamicTools al crear/reanudar hilos; no asumir actualización en caliente de una lista ya registrada. Validar schema real y lifecycle antes de implementar.

Cada llamada conserva identidad de proyecto, servidor, conexión, conversación y turno. Las respuestas tardías de proyectos/sesiones cerrados se descartan. Nombres de herramientas sin colisiones; validar argumentos contra el schema y revalidar habilitación/permisos al ejecutar, también si el modelo conserva una herramienta antigua. Mostrar llamadas, progreso, resultado/error y cancelación en el chat. Recursos y prompts son capacidades distintas de herramientas; incorporarlos por fases y no declararlos soportados sin implementación.

## Compatibilidad con el registro de cambios IA

La política de aplicación directa de `fs_edit_file` no concede acceso irrestricto a todos los MCP. Las escrituras de código que FS Editor presenta como auditadas/reversibles deben seguir pasando por AgentFileChangeService. Un servidor local arbitrario puede escribir fuera de esa ruta si el sistema operativo se lo permite: anunciar un directorio mediante MCP roots NO es un sandbox.

Por ello, los servidores con escritura requieren mediación/adaptador al servicio de archivos o aislamiento efectivo verificado antes de prometer trazabilidad y reversión por bloques. Un watcher detecta una modificación externa, pero no demuestra quién la produjo ni puede reconstruir siempre su contenido anterior. Las acciones remotas (p. ej. crear un issue) tampoco son reversibles mediante nuestro historial de archivos; aplicar la política de la herramienta y presentar el resultado real.

## Reutilización

Candidato principal: [SDK oficial MCP para Swift](https://github.com/modelcontextprotocol/swift-sdk). Su README actual describe cliente/servidor, stdio, Streamable HTTP y OAuth; encaja con Swift 6. La [licencia actual](https://github.com/modelcontextprotocol/swift-sdk/blob/main/LICENSE) anuncia transición MIT → Apache-2.0, conservando MIT para aportes aún no relicenciados. Es compatible con una distribución comercial manteniendo avisos/licencias aplicables; no etiquetar toda la dependencia como código propio MIT.

Fijar una versión/revisión concreta, comprobar dependencias transitivas y la API real de OAuth/Keychain antes de adoptarlo. El README declara protocolo 2025-11-25, mientras la especificación publicada incluye una versión 2026-07-28: definir y probar explícitamente las versiones/transporte soportados, no anunciar compatibilidad universal basándose en main. La integración no ha sido compilada todavía.

## Tareas y aceptación

| ID | Entrega | Comprobación |
| --- | --- | --- |
| MCP-01 | Configuración por proyecto, Keychain y panel AppKit | Crear/editar/quitar; proyecto B sin heredar A; copiar JSON sin trasladar credenciales; JSON/logs libres de secretos |
| MCP-02 | Cliente MCP, stdio y Streamable HTTP | Conexión real, catálogo, llamada, cancelación, fallo/reinicio, binario faltante; servidor lento no bloquea editor |
| MCP-03 | Autenticación HTTP y secretos locales | OAuth con callback/PKCE/renovación según versión elegida, token/API key, fallo/cancelación y aislamiento por recurso/proyecto |
| MCP-04 | Puente al harness, permisos y trazabilidad | Dos conversaciones/modelos compatibles usan la misma conexión; resultado al hilo correcto; herramienta deshabilitada rechazada; política de escritura conserva garantías IA |
| MCP-05 | Recursos/prompts, importación explícita y acabado | Importar configuraciones seleccionadas sin ejecutar; resolver rutas/secrets; evaluar capacidades adicionales y mantener diagnósticos claros |

Reparto propuesto: Terra para panel y persistencia; Sol para transporte/autenticación/puente por concurrencia y límites de seguridad; principal define contratos, revisa y verifica. Implementación por tareas acotadas, sin cambios simultáneos de archivos compartidos.

Activación bajo demanda y reutilización de conexiones compatibles dentro del proyecto, sin iniciar otro servidor por cada chat. Algunos servidores requieren sesiones separadas: el administrador conserva la configuración central sin asumir que su estado interno sea compartible. Limitar concurrencia, tamaño de respuestas/catálogos, reintentos y tiempo; cerrar procesos al cerrar proyecto. Medir consumo conjunto del editor y servidores: un MCP externo sigue consumiendo recursos aunque la UI sea nativa.
