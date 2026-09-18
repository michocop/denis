#!/usr/bin/env python3
"""
A crude conformance checker for the Swift sources.

Not a compiler, and deliberately narrow: it catches the two mistakes this
codebase is most exposed to, having been written without one --

  1. a type that claims to conform to a locally-declared protocol but never
     implements one of its requirements,
  2. two top-level declarations sharing a name, and
  3. a capitalised name used in call or generic position that nothing in the
     module declares and that is not a known SDK type.

(3) exists because deleting a feature once took a shared control out with it
-- LabelledField lived inside the catalogue's wizard file -- and seven other
screens stopped compiling. Nothing here noticed; CI did, two minutes later.
It works off an explicit SDK allowlist, so a genuinely new Apple type has to
be added by hand: the alternative is a check that quietly passes on anything
it does not recognise, which is no check at all.

It tracks brace depth so that a nested type (a private Decodable row struct
inside a repository, say) is attributed to its parent rather than stealing it,
and so that nesting is not mistaken for a name clash.
"""
import re, sys, pathlib, collections

FILES = sorted(pathlib.Path("ios/Sources").rglob("*.swift")) + \
        sorted(pathlib.Path("ios/Tests").rglob("*.swift"))

MODS = r'(?:public |private |internal |fileprivate |final |static |mutating |open )*'
DECL = re.compile(rf'^\s*{MODS}(struct|class|enum|protocol|actor)\s+(\w+)')
EXT  = re.compile(rf'^\s*{MODS}extension\s+(\w+)')
CONF = re.compile(rf'^\s*{MODS}(?:struct|class|enum|actor)\s+(\w+)\s*:\s*([^{{]+)\{{')
PROTO_CONF = re.compile(rf'^\s*{MODS}protocol\s+(\w+)\s*:\s*([^{{]+)\{{')
FUNC = re.compile(rf'^\s*{MODS}func\s+(\w+)')
VAR  = re.compile(rf'^\s*{MODS}var\s+(\w+)')

# Protocols from the SDKs; a conformance to one of these is not ours to check.
EXTERNAL = {
    "View", "App", "Scene", "Identifiable", "Hashable", "Equatable", "Codable",
    "Decodable", "Encodable", "Sendable", "Error", "LocalizedError", "CaseIterable",
    "RawRepresentable", "ExpressibleByNilLiteral", "XCTestCase", "ObservableObject",
    "String", "Int", "Sendable",
}

top_level = collections.defaultdict(list)
protocols = collections.defaultdict(set)      # protocol -> requirement names
inherits  = collections.defaultdict(set)      # protocol -> parent protocols
members   = collections.defaultdict(set)      # fully-qualified type -> members
conform   = []                                # (type, protocol, file, line)
declared  = set()                             # every name declared anywhere,
                                              # nested ones included

def scan(path):
    stack = []          # [(name, depth_at_open)]
    depth = 0
    for lineno, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.split("//")[0]

        # a declaration opening on this line belongs to the CURRENT scope
        m = DECL.match(line) or EXT.match(line)
        if m:
            groups = m.groups()
            kind, name = (groups if len(groups) == 2 else ("extension", groups[0]))
            declared.add(name)
            qualified = name if not stack else f"{stack[-1][0]}.{name}"
            # an extension re-opens the type it names, so it is not nested
            if kind == "extension":
                qualified = name
            elif not stack:
                top_level[name].append(f"{path.name}:{lineno}")

            c = CONF.match(line)
            if c:
                for proto in (p.strip().split("<")[0] for p in c.group(2).split(",")):
                    if proto:
                        conform.append((qualified, proto, path.name, lineno))
            p = PROTO_CONF.match(line)
            if p:
                for parent in (x.strip().split("<")[0] for x in p.group(2).split(",")):
                    if parent and parent not in EXTERNAL:
                        inherits[name].add(parent)
            if kind == "protocol":
                protocols.setdefault(name, set())

            stack.append((qualified, depth, kind))

        elif stack:
            fm = FUNC.match(line) or VAR.match(line)
            if fm:
                owner, _, kind = stack[-1]
                if kind == "protocol":
                    protocols[owner].add(fm.group(1))
                else:
                    members[owner].add(fm.group(1))

        depth += line.count("{") - line.count("}")
        while stack and depth <= stack[-1][1]:
            stack.pop()

for f in FILES:
    scan(f)

def requirements(proto, seen=None):
    seen = seen or set()
    if proto in seen:
        return set()
    seen.add(proto)
    out = set(protocols.get(proto, set()))
    for parent in inherits.get(proto, set()):
        out |= requirements(parent, seen)
    return out

# Everything the app uses from Foundation, SwiftUI, XCTest, Security,
# CryptoKit, LocalAuthentication, CoreGraphics and UIKit. Add to it when a new
# framework type is introduced.
SDK = {
    "Array", "AsyncStream", "Binding", "Button", "CGFloat", "CGPoint", "CGRect",
    "CGSize", "Calendar", "Capsule", "Circle", "Color", "Data", "Date",
    "DateComponents", "DateFormatter", "DatePicker", "Dictionary", "Divider",
    "Double", "EdgeInsets", "Environment", "ForEach", "GridItem", "HMAC",
    "HStack", "HTTPURLResponse", "ISO8601DateFormatter", "Image", "Int",
    "JSONDecoder", "JSONEncoder", "LAContext", "Label", "LazyVGrid",
    "LazyVStack", "Link", "List", "Locale", "NSMutableParagraphStyle",
    "NumberFormatter", "Picker", "Preview", "ProgressView", "Rectangle",
    "RoundedRectangle", "SHA256", "ScrollView", "ScrollViewReader", "SecItemAdd",
    "SecItemCopyMatching", "SecItemDelete", "SecureField", "Sendable", "Set",
    "ShareLink", "Spacer", "State", "String", "SymmetricKey", "TabView", "Task",
    "Text", "TextEditor", "TextField", "TimeZone", "Toggle", "ToolbarItem",
    "UIBezierPath", "UIColor", "UIFont", "UIGraphicsPDFRenderer",
    "UIGraphicsPDFRendererFormat", "URL", "URLQueryItem", "URLRequest",
    "URLSession", "UUID", "VStack", "ViewBuilder", "XCTFail", "XCTSkipUnless",
    "XCTUnwrap", "ZStack", "NSString", "NSAttributedString", "NSDecimalNumber",
    "FileManager", "NavigationStack", "NavigationLink", "Menu", "Section",
    "Form", "Group", "GeometryReader", "Font", "Angle", "Animation",
    "DispatchQueue", "NWPathMonitor", "UNUserNotificationCenter",
    "UNMutableNotificationContent", "UNCalendarNotificationTrigger",
    "UNNotificationRequest", "UNTimeIntervalNotificationTrigger", "Notification",
    "NotificationCenter", "Bundle", "Data", "Timer",
    "RelativeDateTimeFormatter", "UNAuthorizationOptions", "UNNotificationSound", "ToolbarContentBuilder", "ToolbarContent", "UIApplication",
    "PropertyListSerialization", "MainActor",
}

# Strings hold French prose, and "TVA (" or "Email :" is not a type.
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
COMMENT = re.compile(r'//.*')
USE = re.compile(r'(?<![\w.])([A-Z][A-Za-z0-9_]*)\s*[(<]')

undeclared = collections.defaultdict(list)
for f in FILES:
    for lineno, line in enumerate(f.read_text().splitlines(), 1):
        line = STRING.sub('""', COMMENT.sub('', line))
        for m in USE.finditer(line):
            name = m.group(1)
            # a nested type is recorded as Parent.Child, and is referred to
            # by its short name from inside the parent
            if name in declared or name in SDK or name.startswith("XCTAssert"):
                continue
            undeclared[name].append(f"{f.name}:{lineno}")

problems = []

for name, where in sorted(undeclared.items()):
    problems.append(f"UNDECLARED {name} — used at {where[0]}"
                    + (f" and {len(where) - 1} more" if len(where) > 1 else ""))

for name, where in top_level.items():
    if len(where) > 1:
        problems.append(f"DUPLICATE  top-level {name} — {', '.join(where)}")

for tname, proto, f, lineno in conform:
    if proto in EXTERNAL or proto not in protocols:
        continue
    have = set(members.get(tname, set()))
    # a member declared on an extension of the same type, or a default in a
    # protocol extension, satisfies the requirement too
    have |= members.get(tname.split(".")[-1], set())
    have |= members.get(proto, set())
    missing = sorted(requirements(proto) - have)
    if missing:
        problems.append(f"MISSING    {tname}: {proto} — no {', '.join(missing)}  ({f}:{lineno})")

print(f"checked {len(FILES)} files · {len(top_level)} top-level types · "
      f"{len(protocols)} local protocols · {len(conform)} conformances")
if problems:
    print()
    for p in sorted(set(problems)):
        print(p)
    sys.exit(1)
print("no conformance, duplicate or undeclared-name problems found")
