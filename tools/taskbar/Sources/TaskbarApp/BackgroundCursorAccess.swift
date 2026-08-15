import CoreGraphics

typealias CGSConnectionID = Int32
typealias CGSSetConnectionPropertyFunction = (
    CGSConnectionID,
    CGSConnectionID,
    CFString,
    CFTypeRef
) -> CGError

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(
    _ source: CGSConnectionID,
    _ target: CGSConnectionID,
    _ key: CFString,
    _ value: CFTypeRef
) -> CGError

/// Accessory apps receive pointer events while inactive, but WindowServer
/// ignores their cursor changes unless this connection property is enabled.
func enableTaskbarBackgroundCursorUpdates(
    mainConnectionID: () -> CGSConnectionID = CGSMainConnectionID,
    setConnectionProperty: CGSSetConnectionPropertyFunction = CGSSetConnectionProperty
) -> CGError {
    let connection = mainConnectionID()
    return setConnectionProperty(
        connection,
        connection,
        "SetsCursorInBackground" as CFString,
        kCFBooleanTrue
    )
}
