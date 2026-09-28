# RTK — optimización opcional del harness

Fecha: 23 de septiembre de 2026. Decisión del usuario: utilizar Rust Token Killer en el harness cuando esté disponible; funcionar sin él y permitir instalarlo fácilmente. Requisito registrado, integración de aplicación todavía pendiente.

## Evidencia local

Este equipo tiene `/opt/homebrew/bin/rtk`, versión `0.49.0`. Se verificaron `--version`, ubicación y ayudas de rewrite/proxy/gain. La ayuda de `rtk proxy` indica ejecución sin filtrar, con seguimiento de uso: envolver todo en proxy no reduce por sí mismo la salida. `gain` ofrece filtro de proyecto y formato JSON.

Pruebas de reescritura sin ejecutar comandos: `git status` → `rtk git status`; `swift test --build-system native` → `rtk swift test --build-system native`; `rtk git status` permanece igual. También reescribe `git status --porcelain=v2 -z`, por lo que el editor debe excluir explícitamente las salidas destinadas a parsers. En este binario las cuatro pruebas devolvieron código 3 con una reescritura, aunque la ayuda describe 0/1: comprobar el contrato de la versión elegida antes de implementar y no asumir semántica universal de códigos. No se ejecutó ninguna mutación ni instalación.

Las órdenes del asistente que desarrolla FS Editor ya pasan por RTK según AGENTS.md. Eso NO significa que los comandos del agente dentro de FS Editor ya estén integrados con RTK.

## Comportamiento previsto

- Detectar un ejecutable compatible fuera del hilo principal, con timeout, rutas habituales de Homebrew/local y selección manual. No depender únicamente del PATH de una aplicación abierta desde Finder. Distinguir Rust Token Killer de otra herramienta también llamada rtk.
- Un binario compartido en el equipo; preferencia `Use RTK` y comportamiento por proyecto. Estados Available / Not Installed / Unavailable; no bloquear conexión del modelo ni conversación cuando falte.
- Preferencia activada por defecto cuando el binario validado esté disponible; se aplica a los comandos elegibles del harness común, independientemente de la conversación o modelo compatible seleccionado.
- Integración en el ejecutor de herramientas que FS Editor controla, no sólo una instrucción al LLM. No instalar hooks globales ni modificar configuraciones de otros agentes de forma implícita. El runtime Codex actual conserva herramientas internas de lectura; verificar qué llamadas se pueden interceptar/delegar y no anunciar cobertura de herramientas que el host no controla. Mantener el sandbox y el servicio auditado de archivos.
- Si RTK falta, está desactivado o el comando no admite reescritura segura, ejecutar el comando original por la misma ruta de permisos, límites y cancelación. Si RTK o el comando falla DESPUÉS de empezar, no repetirlo automáticamente: podría duplicar commits, migraciones u otros efectos. Registrar error y código de salida, conservando la distinción entre fallo del filtro y fallo del comando.
- Reutilizar `rtk rewrite` cuando su contrato esté verificado; evitar doble prefijo y validar comandos compuestos, redirecciones, quoting, entorno y cwd. No cambiar la semántica del comando ni elevar permisos para compactar su salida.

## Qué optimizar

Compactar salidas compatibles que el agente va a leer: listados, búsquedas y diagnósticos de pruebas/build, resúmenes Git destinados al modelo. Mantener una vía acotada para consultar la salida completa del MISMO intento, cuando el filtro/ejecutor la conserve, sin ejecutar de nuevo la acción para recuperarla. Identificar una salida reducida cuando afecte a la lectura del resultado.

No filtrar JSON-RPC entre editor y Codex, protocolo MCP, stdout de servidores stdio, JSON/NUL que consume GitCore, parches, hashes ni bytes exactos necesarios para localizar/revertir cambios. La terminal interactiva del usuario conserva su comportamiento normal; RTK se aplica al flujo del agente, no se convierte en alias global de su shell. Los resultados MCP estructurados requieren su propio tratamiento; no pasar indiscriminadamente todo resultado por RTK.

## Instalación nativa sencilla

Ubicación propuesta: Settings → AI → Token Optimization. Mostrar disponibilidad/versión, `Use RTK`, `Install RTK…` y `Choose Executable…`; no añadir otro botón al lateral de navegación del proyecto sólo para esta preferencia.

El botón inicia un flujo explícito y cancelable. Si Homebrew está disponible, ofrecer el paquete oficial verificado; si no, ofrecer un binario oficial compatible con la arquitectura, almacenado en Application Support de FS Code, o elegir uno existente. Verificar versión y origen/integridad del artefacto elegido antes de activarlo; no ejecutar scripts remotos cambiantes sin revisión ni instalar Homebrew silenciosamente. Conservar una instalación existente y no actualizarla o reemplazarla automáticamente. Un fallo de instalación deja operativo el harness sin RTK.

La [guía oficial](https://www.rtk-ai.app/docs/getting-started/installation/) y el [repositorio](https://github.com/rtk-ai/rtk) ofrecen Homebrew y binarios macOS. Sus ejemplos de Homebrew no son idénticos entre documentos (tap explícito frente a fórmula corta); resolver y fijar el origen concreto en la tarea de instalación. Evitar el paquete homónimo Rust Type Kit. Respetar la licencia y avisos de la versión distribuida; la [licencia publicada en master](https://github.com/rtk-ai/rtk/blob/master/LICENSE) es Apache-2.0.

## Ahorro medido

[RTK documenta](https://github.com/rtk-ai/rtk) reducción de salida de comandos, no de la factura total, y estima tokens mediante bytes/4. Mostrar `Estimated tokens saved` con alcance claro. Preferir las ejecuciones realizadas por FS Editor y atribuirlas a proyecto/turno; las estadísticas `rtk gain --project` pueden incluir otros agentes o sesiones que trabajaron en esa carpeta, por lo que no deben presentarse como ahorro exclusivo de FS Editor. No mezclar cuotas/coste del proveedor con esta estimación ni prometer un porcentaje fijo.

## Tareas propuestas

| ID | Entrega | Aceptación |
| --- | --- | --- |
| RTK-01 | Detección, preferencia por proyecto y puente en ejecutor controlado | Presente/ausente/desactivado, binario incorrecto, cwd y quoting, sin doble envoltura, bypass de protocolos/parsers y sin duplicar ejecución al fallar |
| RTK-02 | Install RTK / Choose Executable nativos | Con/sin Homebrew, arquitectura correcta, cancelación/fallo, instalación previa intacta; verificación del binario y harness operativo sin RTK |
| RTK-03 | Estadísticas y compatibilidad end-to-end | Salida compacta llega al agente, salida íntegra accesible donde esté soportada, errores conservados, ahorro estimado correctamente atribuido; Git/MCP y registro IA no alterados |

Terra implementa detección/Settings/instalador; Sol implementa o revisa el puente de ejecución si requiere cambios del runtime. Principal define contratos, verifica cobertura real, revisa y valida. No añadir un daemon RTK persistente ni un runtime Rust al proceso AppKit: el ejecutable externo se invoca bajo demanda. El uso de RTK no autoriza herramientas de escritura nuevas en el sandbox del harness.
