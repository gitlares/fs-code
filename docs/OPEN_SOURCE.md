# Shortlist OSS para el editor macOS

Fecha de revisión: **2026-09-23**.

Objetivo: reutilizar piezas pequeñas para un editor AppKit muy ligero, escrito en Swift 6, con IA como capacidad central y un futuro sistema de plugins aislados. La evaluación parte de los repositorios oficiales y de sus archivos de licencia. **SwiftTerm 1.20.0 está integrado como biblioteca AppKit. Las paletas Dracula/Alucard también se usan con sus avisos MIT incluidos.** Las referencias a rendimiento son capacidades declaradas por cada proyecto; no son una garantía para este producto.

| Proyecto | Papel reutilizable | Licencia verificada y obligaciones | Encaje nativo y criterio de evaluación |
|---|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) · [LICENSE](https://github.com/migueldeicaza/SwiftTerm/blob/main/LICENSE) | Terminal VT100/Xterm: motor sin UI y `TerminalView` reutilizable para AppKit. Útil para terminal integrada, tareas y agentes de IA. | **MIT**. Permite uso comercial y código propietario; al redistribuir hay que conservar copyright y el texto de licencia. El archivo también atribuye código histórico de xterm.js, SourceLair y Christopher Jeffrey. | Tiene frontend AppKit nativo, además de UIKit y headless. Medir consumo, scrollback, PTY, selección y concurrencia dentro de una ventana real; su buen rendimiento declarado no sustituye el benchmark. |
| [Tree-sitter](https://github.com/tree-sitter/tree-sitter) · [LICENSE](https://github.com/tree-sitter/tree-sitter/blob/master/LICENSE) | Parser incremental para árbol sintáctico, resaltado, símbolos, selección estructural y contexto para IA. No dibuja la interfaz. | **MIT** para el runtime/repositorio principal: conservar avisos y licencia al redistribuir. **La licencia del runtime no otorga automáticamente la de cada gramática**; cada `tree-sitter-*` debe auditarse por separado antes de incluirlo. | Núcleo sin UI, adecuado para aislar parsing del hilo de AppKit. Integrar primero una gramática y medir latencia de edición, memoria y cancelación; separar el parser de los plugins y del proceso de IA. |
| [STTextView](https://github.com/krzyzanowskim/STTextView) · [LICENSE.md](https://github.com/krzyzanowskim/STTextView/blob/main/LICENSE.md) | Reemplazo de `NSTextView`/`UITextView` basado en TextKit 2, con líneas, multi-cursor, búsqueda, anotaciones y plugins. | **GPLv3 para software open source compatible**. El propio archivo ofrece una **licencia comercial** para aplicaciones no open source, manteniendo el código propietario; esa licencia debe comprarse y conservarse como evidencia contractual. No tratarlo como MIT. | `STTextView` es `NSView` AppKit; `STTextViewSwiftUI` es un wrapper separado. Encaja técnicamente, pero la ruta propietaria depende de comprar la licencia comercial. Validar primero API, TextKit 2, documentos grandes y compatibilidad con Swift 6. |
| [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) · [LICENSE.md](https://github.com/CodeEditApp/CodeEditTextView/blob/main/LICENSE.md) | `TextView` de líneas para editar y renderizar código, con layout inicial rápido, documentos grandes y strings estilizados. Pieza más pequeña para probar un editor de código. | **MIT**. Uso comercial y propietario permitido; conservar el aviso de copyright y la licencia en copias o partes sustanciales. Revisar también sus dependencias (`TextStory`, `swift-collections`) en el inventario de distribución. | `TextView` es una subclase de `NSView` que maneja teclado, ratón y scroll; renderiza con APIs nativas. No cubre por sí sola indentación ni resaltado semántico. Comparar con `NSTextView` y STTextView usando el mismo corpus; no asumir que “extremely fast” se mantendrá en este editor. |
| [CodeEdit](https://github.com/CodeEditApp/CodeEdit) · [LICENSE.md](https://github.com/CodeEditApp/CodeEdit/blob/main/LICENSE.md) | Aplicación completa macOS: arquitectura, workspace, terminal, tareas, Git, extensiones y editor. Sirve como referencia de integración, no como dependencia mínima. | **MIT** para el repositorio de la aplicación; uso comercial/proprietario permitido con conservación de avisos y licencia. Una adopción real exige auditar sus subrepositorios, paquetes, assets y sus licencias individuales. | Aplicación Swift/macOS nativa, pero su tamaño y alcance pueden añadir complejidad y requieren medición frente al objetivo de ligereza. Estudiar contratos de `CodeEditTextView`/`CodeEditSourceEditor` y el modelo de extensiones; no incorporar la app entera en la primera iteración. |
| [CotEditor](https://github.com/coteditor/CotEditor) · [LICENSE](https://github.com/coteditor/CotEditor/blob/main/LICENSE) | Referencia de producto: editor document-based, integración Cocoa, preferencias, encoding, accesibilidad y flujos macOS. No es una librería pequeña. | El **código fuente es Apache-2.0**, con obligaciones de licencia, avisos y cambios modificados. Las **imágenes son CC BY-NC-ND 4.0**, que no permite uso comercial ni obras derivadas: no copiar sus recursos visuales a un producto comercial. | App macOS puramente nativa en Swift y basada en Cocoa/`NSTextView`; excelente referencia de convenciones, pero no prueba que su arquitectura o rendimiento encajen en el núcleo IA/plugin. Reutilizar ideas y APIs observadas, no el bundle completo sin auditoría. |

## Decisión provisional

Para un producto propietario, la primera evaluación debe quedarse en componentes **MIT** y mantener el host AppKit propio: `CodeEditTextView` para la superficie de edición, `Tree-sitter` para parsing/resaltado y `SwiftTerm` sólo para la terminal. `STTextView` queda como alternativa condicionada a licencia comercial; CotEditor y CodeEdit quedan como referencias de arquitectura y comportamiento macOS.

## Prueba mínima antes de adoptar

Crear un spike temporal (sin cambiar aún `Package.swift`) con una ventana AppKit y tres mediciones repetibles sobre un archivo pequeño, uno de 10 MB y uno con líneas muy largas:

1. abrir y mostrar el documento;
2. insertar/borrar texto en el centro mientras se ejecuta el parseo incremental;
3. desplazarse, seleccionar y deshacer durante 60 segundos.

Registrar tiempo hasta primer frame, latencia de edición, memoria, CPU y cancelación al cambiar de archivo. Para Tree-sitter, fijar una sola gramática y anotar su licencia concreta. Para cualquier binario distribuido, generar un inventario de avisos/licencias de dependencias. Sólo después comparar CodeEditTextView con `NSTextView` y, si la licencia comercial es viable, con STTextView.

Antes de distribuir se revisarán las versiones exactas fijadas y sus avisos. La evaluación de una rama actual no sustituye el inventario de dependencias de la versión que se publique.

## Recurso integrado: Dracula / Alucard

Se usan las paletas del [repositorio oficial](https://github.com/dracula/dracula-theme), licencia MIT, copyright 2023 Dracula Theme. `Resources/ThirdPartyNotices.txt` conserva el texto completo y `scripts/build-app.sh` lo copia al bundle. No se incorpora Dracula PRO ni un motor de temas externo.

## Componente integrado: SwiftTerm 1.20.0

Fijado en `Package.swift` y `Package.resolved`, revisión `5d14406844143538cd8f8851d2d8a67c1fe443e5`. Se integra únicamente el producto `SwiftTerm`, sin incorporar termcast ni sus herramientas a la aplicación. La [licencia MIT de esta versión](https://github.com/migueldeicaza/SwiftTerm/blob/v1.20.0/LICENSE) se conserva íntegra en `Resources/ThirdPartyNotices.txt`, incluido en el paquete. `swift-argument-parser` aparece en la resolución del paquete upstream por su herramienta termcast; no forma parte del producto FSCode.

Se usa `LocalProcessTerminalView` con Core Graphics, una sesión por proyecto, scrollback de 2.000 líneas y Sixel no anunciado. El script empaqueta `SwiftTerm_SwiftTerm.bundle` en `Contents/Resources`. No se ha realizado todavía un benchmark de carga sostenida, memoria o CPU.
