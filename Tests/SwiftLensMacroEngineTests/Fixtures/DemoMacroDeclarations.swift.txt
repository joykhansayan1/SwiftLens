// Macro declarations for the SwiftLens demo plugin. In a real project these live in your macro library target;
// SwiftLens reads them to learn each macro's roles and implementation type.

@freestanding(expression)
public macro stringify<T>(_ value: T) -> (T, String) = #externalMacro(module: "SwiftLensDemoMacros", type: "StringifyMacro")

@attached(member, names: named(init))
public macro MemberwiseInit() = #externalMacro(module: "SwiftLensDemoMacros", type: "MemberwiseInitMacro")

@attached(extension, conformances: CustomStringConvertible, names: named(description))
public macro AutoDescription() = #externalMacro(module: "SwiftLensDemoMacros", type: "AutoDescriptionMacro")

@attached(peer, names: overloaded)
public macro AddAsync() = #externalMacro(module: "SwiftLensDemoMacros", type: "AddAsyncMacro")

@attached(accessor)
public macro UserDefault(_ key: String) = #externalMacro(module: "SwiftLensDemoMacros", type: "UserDefaultMacro")

@freestanding(declaration, names: arbitrary)
public macro constants(_ names: String...) = #externalMacro(module: "SwiftLensDemoMacros", type: "ConstantsMacro")
