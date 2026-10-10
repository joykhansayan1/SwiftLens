// A macro implementation you are iterating on — no package, no macro target, no Xcode project.
//   swiftlens lab Examples/MacroLab/AutoCodingKeys.swift --usage Examples/MacroLab/Usage.swift

import SwiftSyntax
import SwiftSyntaxMacros

/// `@CodingKeys` → generates a `CodingKeys` enum with snake_case raw values.
public struct CodingKeysMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let names = declaration.memberBlock.members.compactMap { member -> String? in
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  variable.bindings.first?.accessorBlock == nil
            else { return nil }
            return variable.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
        }
        let cases = names.map { name -> String in
            // displayName → display_name, avatarURL → avatar_url
            var snake = ""
            var previous: Character?
            for character in name {
                if character.isUppercase, let previous, previous.isLowercase { snake += "_" }
                snake += character.lowercased()
                previous = character
            }
            return snake == name ? "    case \(name)" : "    case \(name) = \"\(snake)\""
        }
        return ["enum CodingKeys: String, CodingKey {\n\(raw: cases.joined(separator: "\n"))\n}"]
    }
}
