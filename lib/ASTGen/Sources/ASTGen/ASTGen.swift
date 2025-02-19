//===--- ASTGen.swift -----------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ASTBridging
import BasicBridging
import SwiftIfConfig
// Needed to use BumpPtrAllocator
@_spi(BumpPtrAllocator) @_spi(RawSyntax) @_spi(Compiler) import SwiftSyntax

import struct SwiftDiagnostics.Diagnostic

/// Little utility wrapper that lets us have some mutable state within
/// immutable structs, and is therefore pretty evil.
@propertyWrapper
class Boxed<Value> {
  var wrappedValue: Value

  init(wrappedValue: Value) {
    self.wrappedValue = wrappedValue
  }
}

/// Generate AST from ``SwiftSyntax/Syntax``.
struct ASTGenVisitor {
  let diagnosticEngine: BridgedDiagnosticEngine

  let base: UnsafeBufferPointer<UInt8>

  @Boxed private(set) var declContext: BridgedDeclContext

  let ctx: BridgedASTContext

  let configuredRegions: ConfiguredRegions

  fileprivate let allocator: SwiftSyntax.BumpPtrAllocator = .init(initialSlabSize: 256)

  init(
    diagnosticEngine: BridgedDiagnosticEngine,
    sourceBuffer: UnsafeBufferPointer<UInt8>,
    declContext: BridgedDeclContext,
    astContext: BridgedASTContext,
    configuredRegions: ConfiguredRegions
  ) {
    self.diagnosticEngine = diagnosticEngine
    self.base = sourceBuffer
    self.declContext = declContext
    self.ctx = astContext
    self.configuredRegions = configuredRegions
  }

  func generate(sourceFile node: SourceFileSyntax) -> [BridgedASTNode] {
    var out = [BridgedASTNode]()
    let isTopLevel = self.declContext.isModuleScopeContext

    visitIfConfigElements(
      node.statements,
      of: CodeBlockItemSyntax.self,
      split: Self.splitCodeBlockItemIfConfig
    ) { element in

      func generateStmtOrExpr(_ body: () -> BridgedASTNode) -> BridgedASTNode {
        if !isTopLevel {
          return body()
        }

        let topLevelDecl = BridgedTopLevelCodeDecl.create(self.ctx, declContext: self.declContext)
        let astNode = withDeclContext(topLevelDecl.asDeclContext) {
          body()
        }

        // Diagnose top level code in non-script file.
        if (!declContext.parentSourceFile.isScriptMode) {
          switch element.item {
          case .stmt:
            self.diagnose(.illegalTopLevelStmt(element))
          case .expr:
            self.diagnose(.illegalTopLevelExpr(element))
          case .decl:
            fatalError("unreachable")
          }
        }

        let bodyRange = self.generateImplicitBraceRange(element)
        let body = BridgedBraceStmt.createImplicit(
          self.ctx,
          lBraceLoc: bodyRange.start,
          element: astNode,
          rBraceLoc: bodyRange.end
        )
        topLevelDecl.setBody(body: body)
        return .decl(topLevelDecl.asDecl)
      }

      // TODO: Set semicolon loc.
      switch element.item {
      case .decl(let node):
        if let d = self.generate(decl: node) {
          out.append(.decl(d))

          // Hoist 'VarDecl' to the top-level.
          withBridgedSwiftClosure { ptr in
            let hoisted = ptr!.load(as: BridgedDecl.self)
            out.append(.decl(hoisted))
          } call: { handle in
            d.forEachDeclToHoist(handle)
          }
        }
      case .stmt(let node):
        out.append(generateStmtOrExpr {
          .stmt(self.generate(stmt: node))
        })
      case .expr(let node):
        out.append(generateStmtOrExpr {
          .expr(self.generate(expr: node))
        })
      }
    }

    return out
  }
}

extension ASTGenVisitor {
  /// Obtains a bridged, `ASTContext`-owned "identifier".
  ///
  /// If the token text is `_`, return an empty identifier. If the token is an
  /// escaped identifier, backticks are stripped.
  @inline(__always)
  func generateIdentifier(_ token: TokenSyntax) -> BridgedIdentifier {
    if token.rawTokenKind == .wildcard {
      return nil
    }
    var text = token.rawText
    if text.count > 2 && text.hasPrefix("`") && text.hasSuffix("`") {
      text = .init(rebasing: text.dropFirst().dropLast())
    }
    return self.ctx.getIdentifier(text.bridged)
  }

  /// Obtains a bridged, `ASTContext`-owned "identifier".
  ///
  /// If the `token` text is `nil`, return an empty identifier.
  @inline(__always)
  func generateIdentifier(_ token: TokenSyntax?) -> BridgedIdentifier {
    token.map(generateIdentifier(_:)) ?? nil
  }

  /// Obtains the start location of the node excluding leading trivia in the
  /// source buffer.
  @inline(__always)
  func generateSourceLoc(_ node: some SyntaxProtocol) -> BridgedSourceLoc {
    BridgedSourceLoc(at: node.positionAfterSkippingLeadingTrivia, in: self.base)
  }

  /// Obtains the start location of the node excluding leading trivia in the
  /// source buffer. If the `node` is nil returns an invalid source location.
  @inline(__always)
  func generateSourceLoc(_ node: (some SyntaxProtocol)?) -> BridgedSourceLoc {
    node.map(generateSourceLoc(_:)) ?? nil
  }

  /// Obtains a pair of bridged identifier and the bridged source location.
  @inline(__always)
  func generateIdentifierAndSourceLoc(_ token: TokenSyntax) -> (
    identifier: BridgedIdentifier, sourceLoc: BridgedSourceLoc
  ) {
    return (
      self.generateIdentifier(token),
      self.generateSourceLoc(token)
    )
  }

  /// Obtains a pair of bridged identifier and the bridged source location.
  /// If `token` is `nil`, returns a pair of an empty identifier and an invalid
  /// source location.
  @inline(__always)
  func generateIdentifierAndSourceLoc(_ token: TokenSyntax?) -> (
    identifier: BridgedIdentifier, sourceLoc: BridgedSourceLoc
  ) {
    token.map(generateIdentifierAndSourceLoc(_:)) ?? (nil, nil)
  }

  /// Obtains a pair of bridged identifier and the bridged source location.
  @inline(__always)
  func generateLocatedIdentifier(_ token: TokenSyntax) -> BridgedLocatedIdentifier {
    BridgedLocatedIdentifier(
      name: self.generateIdentifier(token),
      nameLoc: self.generateSourceLoc(token)
    )
  }

  /// Obtains bridged token source range from a pair of token nodes.
  @inline(__always)
  func generateSourceRange(start: TokenSyntax, end: TokenSyntax) -> BridgedSourceRange {
    BridgedSourceRange(
      start: self.generateSourceLoc(start),
      end: self.generateSourceLoc(end)
    )
  }

  /// Obtains bridged token source range of a syntax node.
  @inline(__always)
  func generateSourceRange(_ node: some SyntaxProtocol) -> BridgedSourceRange {
    guard let start = node.firstToken(viewMode: .sourceAccurate) else {
      return BridgedSourceRange(start: nil, end: nil)
    }
    return generateSourceRange(start: start, end: node.lastToken(viewMode: .sourceAccurate)!)
  }

  /// Obtains bridged token source range of a syntax node.
  @inline(__always)
  func generateSourceRange(_ node: (some SyntaxProtocol)?) -> BridgedSourceRange {
    guard let node = node else {
      return BridgedSourceRange(start: nil, end: nil)
    }
    return generateSourceRange(node)
  }

  /// Obtains bridged token source range for a syntax node.
  /// Unlike `generateSourceRange(_:)`, this correctly emulates the string/regex literal token SourceLoc in AST.
  func generateImplicitBraceRange(_ node: some SyntaxProtocol) -> BridgedSourceRange {
    let loc = self.generateSourceLoc(node)
    if let endTok = node.lastToken(viewMode: .sourceAccurate) {
      switch endTok.parent?.kind {
      case .stringLiteralExpr, .regexLiteralExpr:
        // string/regex literal are single token in AST.
        return BridgedSourceRange(start:loc, end: self.generateSourceLoc(endTok.parent))
      default:
        return BridgedSourceRange(start:loc, end: self.generateSourceLoc(endTok))
      }
    } else {
      return BridgedSourceRange(start:loc, end: loc)
    }
  }

  /// Obtains bridged character source range.
  @inline(__always)
  func generateCharSourceRange(start: AbsolutePosition, length: SourceLength) -> BridgedCharSourceRange {
    BridgedCharSourceRange(
      start: BridgedSourceLoc(at: start, in: self.base),
      byteLength: UInt32(length.utf8Length)
    )
  }

  /// Extract `SyntaxText` of the node.
  @inline(__always)
  func extractRawText(_ node: some SyntaxProtocol) -> SyntaxText {
    SyntaxText(
      baseAddress: self.base.baseAddress! + node.positionAfterSkippingLeadingTrivia.utf8Offset,
      count: node.trimmedLength.utf8Length
    )
  }
}

extension ASTGenVisitor {
  /// Replaces the current declaration context with `declContext` for the duration of its execution, and calls `body`.
  @inline(__always)
  func withDeclContext<T>(_ declContext: BridgedDeclContext, _ body: () -> T) -> T {
    let oldDeclContext = self.declContext
    self.declContext = declContext
    defer {
      self.declContext = oldDeclContext
    }
    return body()
  }
}

// Forwarding overloads that take optional syntax nodes. These are defined on demand to achieve a consistent
// 'self.generate(foo: FooSyntax)' recursion pattern between optional and non-optional inputs.
extension ASTGenVisitor {
  @inline(__always)
  func generate(type node: TypeSyntax?) -> BridgedNullableTypeRepr {
    node.map(generate(type:)).asNullable
  }

  @inline(__always)
  func generate(expr node: ExprSyntax?) -> BridgedNullableExpr {
    node.map(generate(expr:)).asNullable
  }

  @inline(__always)
  func generate(pattern node: PatternSyntax?) -> BridgedNullablePattern {
    node.map(generate(pattern:)).asNullable
  }

  @inline(__always)
  func generate(genericParameterClause node: GenericParameterClauseSyntax?) -> BridgedNullableGenericParamList {
    node.map(generate(genericParameterClause:)).asNullable
  }

  @inline(__always)
  func generate(genericWhereClause node: GenericWhereClauseSyntax?) -> BridgedNullableTrailingWhereClause {
    node.map(generate(genericWhereClause:)).asNullable
  }

  @inline(__always)
  func generate(enumCaseParameterClause node: EnumCaseParameterClauseSyntax?) -> BridgedNullableParameterList {
    node.map(generate(enumCaseParameterClause:)).asNullable
  }

  @inline(__always)
  func generate(accessorParameters node: AccessorParametersSyntax?) -> BridgedNullableParameterList {
    node.map(generate(accessorParameters:)).asNullable
  }

  @inline(__always)
  func generate(inheritedTypeList node: InheritedTypeListSyntax?) -> BridgedArrayRef {
    node.map(generate(inheritedTypeList:)) ?? .init()
  }

  @inline(__always)
  func generate(precedenceGroupNameList node: PrecedenceGroupNameListSyntax?) -> BridgedArrayRef {
    node.map(generate(precedenceGroupNameList:)) ?? .init()
  }
}

extension Collection {
  /// Like ``Sequence.compactMap(_:)``, but returns a `BridgedArrayRef` with a lifetime tied to that of `astgen`.
  ///
  /// - Note: The purpose of this method is to make up for the performance toll of calling ``Collection.bridgedArray``
  ///   on a ``LazyFilterSequence`` due to the `count` access.
  func compactMap<T>(in astgen: ASTGenVisitor, _ transform: (Element) -> T?) -> BridgedArrayRef {
    if self.isEmpty {
      return .init()
    }

    let baseAddress = astgen.allocator.allocate(T.self, count: self.count).baseAddress!
    do {
      // A loop instead of `initialize(from: self.lazy.compactMap(transform))` because we aren't
      // doing a great job optimizing the latter.
      var currentAddress = baseAddress
      for element in self {
        guard let transformed = transform(element) else {
          continue
        }

        currentAddress.initialize(to: transformed)
        currentAddress += 1
      }
    }

    return .init(data: baseAddress, count: self.count)
  }
}

extension CollectionOfOne {
  /// Returns a single element as a `BridgedArrayRef` with a lifetime tied to that of `astgen`.
  func bridgedArray(in astgen: ASTGenVisitor) -> BridgedArrayRef {
    let buffer = astgen.allocator.allocate(Element.self, count: 1)
    _ = buffer.initialize(from: self)
    return .init(data: buffer.baseAddress, count: 1)
  }
}

extension LazyCollectionProtocol {
  /// Returns a copy of the collection's elements as a `BridgedArrayRef` with a lifetime tied to that of `astgen`.
  func bridgedArray(in astgen: ASTGenVisitor) -> BridgedArrayRef {
    if self.isEmpty {
      return .init()
    }

    let buffer = astgen.allocator.allocate(Element.self, count: self.count)
    _ = buffer.initialize(from: self)

    return .init(data: buffer.baseAddress, count: self.count)
  }
}

// 'ReversedCollection' does not conform to 'LazyCollectionProtocol', and cannot here because it only
// conditionally conforms to 'LazySequenceProtocol' in the standard library.
// FIXME: We could make it conform unconditionally
extension ReversedCollection {
  /// Returns a copy of the collection's elements as a `BridgedArrayRef` with a lifetime tied to that of `astgen`.
  @inline(__always)
  func bridgedArray(in astgen: ASTGenVisitor) -> BridgedArrayRef {
    self.lazy.bridgedArray(in: astgen)
  }
}

extension Optional where Wrapped: LazyCollectionProtocol {
  /// Returns a copy of the collection's elements as a `BridgedArrayRef` with a lifetime tied to that of `astgen`.
  @inline(__always)
  func bridgedArray(in astgen: ASTGenVisitor) -> BridgedArrayRef {
    guard let self else {
      return .init()
    }

    return self.bridgedArray(in: astgen)
  }
}

extension TokenSyntax {
  /// Get `Keyword` kind if the token is a keyword.
  var keywordKind: Keyword? {
    // Performance note:
    // This is faster than `token.tokenKind == .keyword(.true)` because
    // `TokenKind.tokenKind` may instantiate `Swift.String`.
    // That being said, `SwiftSyntax.Keyword` is a non-SPI public type, so it
    // cannot be `@frozen`. Also `Keyword(_:SyntaxText)` itself is heavier than
    // simple `token.rawText == "true"`.
    // We should ensure `token.keywordKind == .true` is optimized out to
    // a simple `cmp` instruction.
    guard rawTokenKind == .keyword else {
      return nil
    }
    return Keyword(self.rawText)
  }
}

/// Generate AST nodes for all top-level entities in the given source file.
@_cdecl("swift_ASTGen_buildTopLevelASTNodes")
public func buildTopLevelASTNodes(
  diagEngine: BridgedDiagnosticEngine,
  sourceFilePtr: UnsafeMutableRawPointer,
  dc: BridgedDeclContext,
  attachedDecl: BridgedNullableDecl,
  ctx: BridgedASTContext,
  outputContext: UnsafeMutableRawPointer,
  callback: @convention(c) (BridgedASTNode, UnsafeMutableRawPointer) -> Void
) {
  let sourceFile = sourceFilePtr.assumingMemoryBound(to: ExportedSourceFile.self)
  let visitor = ASTGenVisitor(
    diagnosticEngine: diagEngine,
    sourceBuffer: sourceFile.pointee.buffer,
    declContext: dc,
    astContext: ctx,
    configuredRegions: sourceFile.pointee.configuredRegions(astContext: ctx)
  )

  switch sourceFile.pointee.syntax.as(SyntaxEnum.self) {
  case .sourceFile(let node):
    for elem in visitor.generate(sourceFile: node) {
      callback(elem, outputContext)
    }

  case .memberBlockItemListFile(let node):
    for elem in visitor.generate(memberBlockItemList: node.members) {
      callback(.decl(elem), outputContext)
    }

  case .codeBlockFile(let node):
    let block = visitor.generate(codeBlock: node.body)
    callback(.stmt(block.asStmt), outputContext)

  case .attributeClauseFile(let node):
    let decl = visitor.generate(generatedAttributeClauseFile: node)
    callback(.decl(decl), outputContext)

  case .accessorBlockFile(let node):
    // For 'accessor' macro, 'attachedDecl' must be a 'AbstractStorageDecl'.
    let storage = BridgedAbstractStorageDecl(raw: attachedDecl.raw!)

    for elem in visitor.generate(accessorBlockFile: node, for: storage) {
      callback(.decl(elem.asDecl), outputContext)
    }

  default:
    fatalError("invalid syntax for a source file")
  }

  // Diagnose any errors from evaluating #ifs.
  visitor.diagnoseAll(visitor.configuredRegions.diagnostics)
}
