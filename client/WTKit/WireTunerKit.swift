// WireTunerKit.framework (decisions.adoc D-084; building.adoc, "The shared framework") has no code
// of its own.  It exists to link the shared packages -- WTModel, WTSync, WTCRDT, WTProto,
// WTInterchange, WTRender, WTText, WTGeometry and their dependencies -- once, as a dynamic
// framework in WireTuner.app/Contents/Frameworks that the app and the Spotlight importer both
// load, instead of each executable carrying its own static copy.  Import the packages' modules,
// never this one.
