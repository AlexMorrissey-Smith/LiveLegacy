# Capture Pilot mobile server: working notes

Checked against Capture One 16.8 with a Canon EOS R6 Mark III tethered.

## Servers

Capture One runs two Capture Pilot servers per document (AppleScript `server settings`):

- **Mobile server**: the full protocol, including camera control. Port is automatic by default
  (`mobile port`, 0 = auto) and changes every time the server restarts, so clients need manual
  IP and port entry as well as discovery. Remote capture needs the "Capture images" permission
  (`mobile capture`).
- **Web server**: serves the bundled browser client on port 80 (`web port`). Rating and tagging
  only; capture and adjustments are always disabled.

Both listen on all interfaces. Bonjour type: `_http._tcp`, subtype `_coremote`.

## Calls

All are plain HTTP on the mobile port, with `sessionID` and a `timestamp` query parameter.

| Call | Notes |
| --- | --- |
| `getProtocolVersion` | Returns `2.1`. The web client sends `protocolVersion=2.4` to `connectToService`. |
| `connectToService` | POST with an empty body. Returns the session ID. `password` is the SHA1 hex of the password. |
| `getServerState` | `objects` (server, camera) plus `variants` and `revision`. |
| `getServerChanges` | Long poll with `revision`. Returns changed objects and variants. |
| `getImage` | Base64 JPEG for a variant ID. |
| `getImageMetadata` | `id=<variantID>`. Returns the variant's properties as JSON. |
| `setProperty` | Rating and tag as before. Camera settings: `objectType=kObjectType_Camera&objectID=<id>&propertyID=<kCameraProperty_*>&propertyValue=<value>`. Returns `0` on success. |
| `incrementProperty` / `decrementProperty` | Same object parameters, no value. Steps the setting one notch. Returns `0`. |
| `capture` | No parameters beyond `sessionID`. Fires the shutter; the new image arrives in the change feed. Returns `0`. |
| `getHistogram` | `id=<variantID>&width=256&height=<h>`. Returns 256 big-endian UInt16 bar heights scaled to 0...h. |
| `getHistogramProperty` | `id=<variantID>&propertyID=kHistogramProperty_LensAndCameraName` returns `[lens, camera]`. |
| `setLiveView` | Answers 404 to every parameter tried. |
| `getProperty`, `setGeoTags`, `disconnectFromService` | Exist; parameters not worked out yet. |

## Objects

`kObjectType_CPServer` (ID 0) carries permission properties. `kServerProperty_Capture_Button` is
`enabled` only while a camera is connected.

`kObjectType_Camera` (ID per camera, name includes model and serial) carries
`kCameraProperty_*` entries. Each has `CurrentValue`, `Values` (allowed values joined with `#`),
`Permissions` (`r` or `rw`), `CanIncrement` and `CanDecrement`. Seen on the R6 Mark III:
ExposureISO, ImageCompression, Aperture, ShutterSpeed, ExposureBias, ExposureMode,
WhiteBalanceMode, MirrorUp (read-only), ExposureMeteringMode, DriveMode, and
`kCameraCapability_ShutterRelease` (read-only, `enabled` when capture is possible).
