# Formatos de contexto de agentes

Revisión: **2026-09-23**. Esta nota recoge únicamente comportamientos publicados por documentación o código oficial de cada proveedor. La semántica de prioridad entre proveedores es una política de FS Editor propuesta, no una regla universal.

**Límite de la primera versión:** el detector inspecciona el workspace/proyecto abierto y sus archivos de configuración de proyecto. No lee credenciales, configuración global del host ni carpetas de usuario para decidir el contexto: no se escanean `$CODEX_HOME`, `~/.claude`, `$HOME/.copilot` ni políticas administradas. Las rutas globales de la tabla sólo documentan la semántica nativa que el panel debe mostrar como “fuera del alcance del proyecto”.

## Reglas nativas verificadas

| Proveedor | Detección y alcance | Metadatos y activación | Precedencia que puede reproducirse |
|---|---|---|---|
| **Codex** — [AGENTS.md](https://developers.openai.com/codex/guides/agents-md) y [implementación oficial](https://github.com/openai/codex/blob/main/codex-rs/core/src/agents_md.rs) | En el directorio global de `$CODEX_HOME`, usa `AGENTS.override.md` si existe; si no, `AGENTS.md`, sólo el primer archivo no vacío. En el proyecto recorre desde la raíz del proyecto hasta el `cwd`; en cada carpeta busca `AGENTS.override.md`, después `AGENTS.md` y luego nombres configurados en `project_doc_fallback_filenames`. Carga como máximo uno por carpeta. | Markdown sin frontmatter nativo. `project_doc_max_bytes` limita el documento agregado (32 KiB por defecto en la guía). | Concatena de raíz hacia `cwd`; las carpetas más cercanas aparecen después y prevalecen ante conflicto. En la misma carpeta, `AGENTS.override.md` reemplaza a `AGENTS.md`; no se suman ambos. |
| **Claude Code** — [memory](https://code.claude.com/docs/en/memory) y [settings](https://code.claude.com/docs/en/settings) | `CLAUDE.md`, `.claude/CLAUDE.md` y `CLAUDE.local.md` en `cwd` y ancestros; archivos bajo subdirectorios se cargan cuando Claude lee esa zona. Reglas Markdown en `.claude/rules/**/*.md` y `~/.claude/rules/**/*.md`. Claude también puede leer `AGENTS.md`; por defecto, si hay `CLAUDE.md`/`CLAUDE.local.md` en la ruta, usa éstos en lugar de `AGENTS.md`, salvo configuración `claude-md-and-agents-md`. | Importaciones `@ruta` relativas al archivo que importa o absolutas, recursivas hasta 4 saltos; no se interpretan dentro de código inline ni fenced. En `.claude/rules`, sólo se reconoce `paths` en frontmatter YAML; sin `paths` la regla es global, y un frontmatter inválido se carga como regla sin `paths`. | En la jerarquía de archivos, el contenido se concatena de raíz a `cwd`; `CLAUDE.local.md` queda después de `CLAUDE.md` en la misma carpeta. Para reglas de usuario/proyecto, la documentación advierte que el contenido posterior no constituye un override semántico garantizado. |
| **Cursor** — [Rules](https://docs.cursor.com/context/rules) | Reglas de proyecto en `.cursor/rules/**/*.mdc`, también en directorios anidados; `.cursorrules` en la raíz sigue soportado pero está obsoleto. Las reglas de usuario se configuran en Cursor Settings y son texto plano, no MDC; el proveedor no publica ahí una ruta de archivo estable para que FS Editor la invente. | Frontmatter MDC con `description`, `globs` y `alwaysApply`. Tipos: **Always** (`alwaysApply: true`), **Auto Attached** (glob), **Agent Requested** (requiere `description`, el agente decide), y **Manual** (se invoca con `@ruleName`). | Los tipos definen cuándo puede entrar una regla, pero la documentación no establece un orden total general entre reglas de proyecto, usuario y memorias. Conservar el tipo y el resultado nativo conocido; no fabricar una prioridad numérica entre fuentes Cursor. |
| **GitHub Copilot** — [custom instructions](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions) | Repo-wide: `.github/copilot-instructions.md`. Modulares: `.github/instructions/**/*.instructions.md`; se descubren en ubicaciones estándar (raíz, `cwd`, directorios intermedios y subdirectorios del archivo trabajado). También reconoce `AGENTS.md`, `CLAUDE.md`, `.claude/CLAUDE.md` y `GEMINI.md`. Hay ubicaciones personales en `$HOME/.copilot/` y directorios adicionales mediante `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`. | Frontmatter modular: `applyTo` con uno o varios globs separados por comas; `excludeAgent` puede ser `code-review` o `cloud-agent`. `@ruta` importa archivos relativos sólo en `copilot-instructions.md`, `AGENTS.md` o `CLAUDE.md`; puede encadenar imports, pero deben permanecer dentro del repositorio o del directorio de instrucciones configurado. | Copilot combina instrucciones aplicables y elimina copias idénticas de algunas fuentes. Declara que no hay un orden general entre archivos repo-wide, de agente y de usuario; por tanto, los conflictos de texto quedan sin resolver automáticamente. |

## Settings que deben detectarse aparte

Los settings no son instrucciones Markdown y no deben inyectarse como texto de contexto. El panel puede mostrarlos como fuentes de configuración y explicar su alcance:

- **Codex:** dentro del proyecto, considerar sólo `<project-root>/.codex/config.toml` para leer de forma read-only `project_doc_fallback_filenames` y `project_doc_max_bytes`; el cargador oficial identifica esa capa como configuración `Project`. No usarla para cargar credenciales, proveedores, permisos ni instrucciones adicionales. La configuración de usuario queda fuera de esta versión.
- **Claude Code:** dentro del proyecto, mostrar `.claude/settings.json` y `.claude/settings.local.json` como configuración, nunca como texto de instrucciones. Las rutas de usuario (`~/.claude/settings.json`, `~/.claude.json`) y administradas se etiquetan fuera de alcance y no se leen.
- **Cursor:** sólo `.cursor/rules` y `.cursorrules` del workspace. Las reglas de usuario de Settings no tienen una ruta de archivo estable publicada y quedan fuera de alcance.
- **Copilot CLI:** sólo `.github/copilot-instructions.md` y `.github/instructions/**/*.instructions.md` del workspace. Las ubicaciones personales y `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` quedan fuera de alcance.

## Estados sin inferencia semántica

El motor offline puede decidir existencia, ruta, hashes, frontmatter acotado, alcance por glob y sustituciones explícitas del proveedor. No puede decidir si una regla `Agent Requested` es relevante para una tarea, si dos frases naturales se contradicen, ni si un contexto amplio es “útil”. Esas decisiones requieren acción del usuario o del agente nativo.

El modelo de presentación debe conservar los estados pedidos por el producto y añadir una razón visible cuando la activación no sea determinista:

| Estado | Uso determinista |
|---|---|
| `activa` | El proveedor la carga según una condición comprobable: jerarquía aplicable, `alwaysApply`, glob que coincide o `applyTo` que coincide. |
| `reemplazada` | Sólo cuando la semántica nativa lo dice, por ejemplo `AGENTS.override.md` frente a `AGENTS.md` en la misma carpeta. |
| `ignorada` | El usuario la desactivó, el proveedor la excluye para la superficie seleccionada (`excludeAgent`) o el setting correspondiente está deshabilitado. |
| `conflicto` | Sólo conflicto estructural explícito, como dos definiciones propias con la misma identidad. No afirmar conflicto semántico por coincidencia de palabras. |
| `manual` | Requiere invocación explícita, por ejemplo regla Cursor de tipo Manual o una fuente externa que el usuario aún no activó. |
| `unknown` | El proveedor decide relevancia u orden de forma no observable para el motor offline, como Cursor Agent Requested o una prioridad externa no documentada. |
| `unsupported` | Sintaxis, campo o importación fuera del subconjunto implementado; mostrar la razón y conservar el archivo como fuente detectada inactiva. |

Las condiciones manuales, desconocidas o no soportadas se muestran con una razón explícita y no se incluyen por aproximación. Activar una fuente no hace compatible una sintaxis no soportada. La procedencia del contexto consolidado identifica proveedor, ruta, identidad y hash. Esta tabla describe las distinciones semánticas; la interfaz puede reunirlas bajo un estado con diagnóstico.

## Persistencia propia acordada

La persistencia propia vive en `.fs/context/`, con un archivo Markdown por regla y un manifiesto JSON versionado que conserva identidad, nombre, alcance, destino, prioridad y activación. El contenido del usuario permanece separado de los metadatos. El almacén global propio usa Application Support. Abrir un proyecto no crea estos archivos.

Orden de resolución, independiente de la semántica externa:

1. contexto global propio de FS Editor;
2. contexto de proyecto;
3. carpetas, desde la raíz hasta la carpeta del archivo;
4. patrones glob coincidentes;
5. archivo exacto;
6. fuentes externas, usando su activación nativa cuando esté documentada.

Dentro del mismo nivel se utiliza la prioridad explícita y un desempate estable por procedencia e identidad. Cada bloque del resultado conserva su origen. Un manifiesto inválido se informa y no se sobrescribe silenciosamente. El soporte real de cada formato externo se documenta por separado del comportamiento nativo investigado.

## Límite entre proveedores

No existe una prioridad universal entre Codex, Claude Code, Cursor y Copilot. FS Editor debe mostrar una cadena por proveedor y luego una cadena consolidada propia, indicando qué orden es nativo y qué orden es una decisión del host. No debe presentar una fuente externa como “activa” sólo porque el archivo existe, ni convertir automáticamente instrucciones de una herramienta en reglas propias.

## Fuentes primarias consultadas

- [OpenAI Codex: Custom instructions with AGENTS.md](https://developers.openai.com/codex/guides/agents-md)
- [OpenAI Codex: `agents_md.rs`](https://github.com/openai/codex/blob/main/codex-rs/core/src/agents_md.rs)
- [OpenAI Codex: project config loader](https://github.com/openai/codex/blob/main/codex-rs/config/src/loader/mod.rs)
- [Claude Code: How Claude remembers your project](https://code.claude.com/docs/en/memory)
- [Claude Code: Settings files and precedence](https://code.claude.com/docs/en/settings)
- [Cursor: Rules](https://docs.cursor.com/context/rules)
- [GitHub Copilot CLI: Adding custom instructions](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions)
