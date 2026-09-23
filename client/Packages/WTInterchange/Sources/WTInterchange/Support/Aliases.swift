// Foundation declares its own `AffineTransform`; inside this package (and in its public
// signatures) the name means the display list's, as in WTRender.  WTGeometry's `StrokeStyle`,
// `LineCap` and `LineJoin` are shadowed by scoped imports of WTRender's in the files using them.

import WTGeometry

public typealias AffineTransform = WTGeometry.AffineTransform
