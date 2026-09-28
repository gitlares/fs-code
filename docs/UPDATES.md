# Actualizaciones de FS Code

## Canal acordado

Distribución fuera de la App Store mediante GitHub Releases y un catálogo público HTTPS de Sparkle. Falta confirmar el repositorio y la URL definitiva del catálogo; no se incluyen endpoints de ejemplo en la aplicación.

## Integración

Sparkle 2.10.0 está fijado en SwiftPM. El menú `FS Code → Check for Updates…` usa la interfaz nativa de Sparkle. Sin `SUFeedURL` y `SUPublicEDKey` válidos, el controlador no arranca y el menú queda deshabilitado. Las comprobaciones e instalaciones automáticas están desactivadas por defecto.

`scripts/build-app.sh` incluye `Sparkle.framework`, sus componentes auxiliares y los avisos de licencia en el paquete. La compilación local mantiene firma ad hoc; no equivale a un producto notarizado para distribución pública.

## Configuración de distribución

El script acepta estas variables de entorno, siempre juntas:

- `FS_CODE_SU_FEED_URL`: URL HTTPS real del catálogo público.
- `FS_CODE_SU_PUBLIC_ED_KEY`: clave pública Ed25519 de Sparkle, Base64 de 32 bytes.

Los valores se incorporan a `Contents/Info.plist` del paquete generado; no se guardan credenciales ni claves privadas en el repositorio. Una compilación sin ambas variables produce una aplicación con actualizaciones desactivadas.

## Primera publicación pendiente — UPD-02

1. Confirmar el repositorio de GitHub y una URL estable del catálogo público. Los archivos de actualización se publicarán como assets de Releases.
2. Crear y custodiar la clave privada de actualizaciones mediante las herramientas oficiales de Sparkle. Incorporar únicamente su clave pública a las builds.
3. Configurar firma Developer ID y notarización del paquete y sus componentes. El script actual sólo sirve para firma de desarrollo local.
4. Incrementar `CFBundleVersion` en cada publicación. El estado actual es versión 0.1.0, build 1.
5. Generar el archivo distribuible y su appcast firmado con las herramientas oficiales de Sparkle. Publicar los archivos antes de exponer el catálogo que los anuncia.
6. Probar una actualización real entre dos versiones, la cancelación y el cierre con documentos modificados. Mantener el flujo normal de guardar/cancelar de AppKit.

No se han generado claves de producción, creado repositorios, publicado releases ni probado la instalación de una actualización real.

## Referencias

- [Integración oficial de Sparkle](https://sparkle-project.org/documentation/).
- [Configuración programática](https://sparkle-project.org/documentation/programmatic-setup/).
- [Publicación de actualizaciones](https://sparkle-project.org/documentation/publishing/).
- [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0).
