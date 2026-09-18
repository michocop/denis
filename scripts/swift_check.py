#!/usr/bin/env python3
"""
A crude conformance checker for the Swift sources.

Not a compiler, and deliberately narrow: it catches the two mistakes this
codebase is most exposed to, having been written without one --

  1. a type that claims to conform to a locally-declared protocol but never
     implements one of its requirements, and
  2. two top-level declarations sharing a name.

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

problems = []

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
print("no conformance or duplicate problems found")
