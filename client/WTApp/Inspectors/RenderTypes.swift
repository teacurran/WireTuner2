import WTRender

// SwiftUI and WTRender both name a `Color`, and the WTRender module's protocol of the same name
// hides the module qualifier, so the editors reach the display list's colour through this alias
// (this file imports WTRender alone).
typealias RenderColor = Color
