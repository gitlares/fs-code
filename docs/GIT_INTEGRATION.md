# Git integrado — investigación y tareas propuestas

Fecha: 23 de septiembre de 2026. Petición: nuevo botón Git en el selector lateral izquierdo, estado de archivos, stashes, operaciones Git y grafo de commits/ramas. GUI AppKit coherente con FS Editor, ligera e independiente de un LLM. Esta entrega registra la evaluación; no incorpora dependencias ni implementa todavía el panel.

## Candidatos revisados

| Proyecto | Qué aporta | Licencia y encaje |
| --- | --- | --- |
| [Maple](https://github.com/poolcamacho/Maple) | Cliente SwiftUI con Git vía Process, modelos, parsers y algoritmo del grafo en Foundation | [MIT](https://github.com/poolcamacho/Maple/blob/master/LICENSE). Candidato a reutilizar piezas con atribución; no es un componente AppKit listo para incrustar. |
| [SwiftGitX](https://github.com/ibrahimcetin/SwiftGitX) + [libgit2](https://libgit2.org/) | Motor Git enlazable, API Swift, SwiftPM | Wrapper [MIT](https://github.com/ibrahimcetin/SwiftGitX/blob/main/LICENSE); libgit2 GPLv2 con excepción de enlace, permite aplicaciones con otra licencia y comerciales, conservando sus obligaciones. No proporciona GUI ni grafo. |
| [GitUp/GitUpKit](https://github.com/git-up/GitUp) | Componentes AppKit reutilizables, diffs y GIGraphView; usa un fork de libgit2 | [GPLv3](https://github.com/git-up/GitUp/blob/master/LICENSE). Permite comercializar, pero incorporar su código en el ejecutable no encaja con distribuir el conjunto únicamente bajo MIT. No adoptarlo con el esquema actual. |
| [gitoxide](https://github.com/GitoxideLabs/gitoxide) | Bibliotecas Git en Rust | MIT/Apache-2.0. Motor sin GUI; añadir Rust/FFI ahora tiene un coste que no se justifica sin una ventaja medida frente a las opciones anteriores. |

El [Package.swift real de SwiftGitX](https://github.com/ibrahimcetin/SwiftGitX/blob/main/Package.swift) usa Swift tools 6.0 y fija el empaquetado de libgit2 1.9.2 de su mantenedor. No tomar literalmente «sin dependencias» del README: existe esa dependencia. Deben verificarse distribución, compilación, credenciales, operaciones y compatibilidad de la versión elegida antes de adoptarla.

## Recomendación técnica provisional

Comenzar con el ejecutable oficial de Git instalado, invocado directamente mediante argumentos de Process, detrás de un módulo GitCore por repositorio. Interfaz y grafo siguen siendo AppKit nativos; no se muestra una terminal incrustada. Detectar Git y ofrecer seleccionar el ejecutable cuando falte; no asumir que todo macOS trae una instalación operativa ni lanzar instalaciones automáticamente. Si se exige distribución autosuficiente sin Git instalado, evaluar SwiftGitX/libgit2 como alternativa antes de implementar el adaptador, sin mantener dos motores innecesariamente.

El [formato porcelain v2 -z](https://git-scm.com/docs/git-status) sirve para estado estructurado; el [historial](https://git-scm.com/docs/git-log) proporciona IDs y padres. Git conserva la responsabilidad de leer/escribir su índice y objetos. No implementar nuestro propio Git ni editar su base de datos manualmente.

Maple es el candidato concreto para ahorrar trabajo en el grafo. Su [CommitGraphBuilder](https://github.com/poolcamacho/Maple/blob/master/Maple/Services/CommitGraphBuilder.swift) importa Foundation, separado de las vistas, y genera nodos, carriles y conexiones. Su código omite padres fuera del lote; para nuestro historial paginado hay que representar continuaciones y mantener carriles estables, sin aparentar que esas ramas terminaron. Usar orden topológico para evitar que fechas anómalas rompan la lectura. Revisar pruebas y fijar una revisión concreta antes de copiar; conservar copyright/licencia y documentar modificaciones. No se ha compilado ni medido Maple/SwiftGitX en FS Editor.

## Organización de la interfaz propuesta

- Un cuarto botón `Git` junto a Files, TODOs y Agent Context, con nombre accesible y contador discreto.
- Lateral: rama actual y secciones plegables `Changes`, `Staged`, `Branches`, `Stashes`; acceso `History`.
- Centro: diff del archivo elegido; History abre grafo y lista de commits, con detalle del commit seleccionado. No reducir el grafo a la estrecha barra lateral.
- Acciones locales cerca de su contenido: Stage/Unstage, Commit y acciones de stash. Menús secundarios para operaciones menos frecuentes.
- Conservar terminal/asistente, borradores, selección y tamaño de paneles; superficies planas, inglés, colores semánticos, teclado y scroll overlay.
- Cambios Git y cambios IA son estados independientes: M/A/D etc. pueden coexistir con ✦. No confundir Revert Block (historial IA), Discard Changes (árbol de trabajo) y Git revert (nuevo commit).

## Tareas propuestas

| ID | Alcance | Aceptación | Ejecución propuesta |
| --- | --- | --- | --- |
| GIT-01 | GitCore de consulta + botón/lateral Git + diff central | Repo real, carpeta dentro del repo, worktree, sin repo, HEAD sin commits/detached, nombres con espacios/Unicode/saltos de línea, cambios staged/unstaged separados; ninguna escritura | Terra, principal revisa arquitectura y valida |
| GIT-02 | Grafo nativo paginado y detalle de commits; evaluar/adaptar algoritmo MIT de Maple | Ramas, merges, varios padres, fechas fuera de orden, continuación entre páginas; dibujar solo filas visibles y conservar selección | Terra, revisión específica del algoritmo por principal |
| GIT-03 | Stage/Unstage, Commit y stashes (crear/ver/aplicar/eliminar) | Comandos explícitos, estado refrescado, borradores protegidos, conflictos visibles, errores no ocultos y operaciones mutantes serializadas | Terra; principal revisa/valida repos temporales |
| GIT-04 | Fetch/Push/Pull, ramas y resolución de conflictos | Flujos de credenciales/cancelación, upstream, repo cambiado externamente; nunca force-push/reset destructivo implícito | Definir después de GIT-01/03 |

Orden recomendado: GIT-01 → GIT-02 → GIT-03 → GIT-04. El alcance detallado y la adopción concreta se acuerdan antes de ejecutar.

## Rendimiento y pruebas

Cargar historial solo al abrirlo, con paginación; diffs bajo demanda y límites explícitos para archivos grandes/binarios. Actualizaciones por eventos agrupados y por operaciones completadas, evitando sondeo continuo. Trabajo fuera del hilo principal, cancelación al cambiar proyecto, una cola explícita de mutaciones por repo (un actor reentrante por sí solo no serializa procesos durante await), límites de salida y timeout. Medir repos pequeño/grande y mantener interactividad del editor. No prometer consumo nulo ni cifras sin medición.

Probar con repos temporales creados para validación. No inicializar ni modificar el Git del proyecto del usuario para demostrar el panel. Se preserva el registro de cambios IA, independiente de Git.
