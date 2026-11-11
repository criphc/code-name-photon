import ContractKit

/// `ContractKit` (repo root `contract/`) is the **single definition** of the shared contract:
/// the recipe schema/validation, the highlight mask/gain maths, `Rec.709` luma, the linear
/// working-buffer types and (from P1) the HTTP wire types. Both the Mac package and the iPad app
/// compile it, so this file must stay a pure re-export — it holds no implementation.
///
/// The typealiases below keep every existing `import EngineKit` call site (the Mac pipeline, the
/// server, the tests) resolving the same names, now backed by the one shared module (docs/reference/client.md, architecture).
public typealias PixelSize = ContractKit.PixelSize
public typealias RGBA = ContractKit.RGBA
public typealias LinearImage = ContractKit.LinearImage
public typealias Recipe = ContractKit.Recipe
public typealias HighlightShape = ContractKit.HighlightShape
public typealias HDRRendition = ContractKit.HDRRendition
public typealias HeadroomCap = ContractKit.HeadroomCap
public typealias PhotonError = ContractKit.PhotonError
