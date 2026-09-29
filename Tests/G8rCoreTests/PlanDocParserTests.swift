import XCTest
@testable import G8rCore

final class PlanDocParserTests: XCTestCase {
    /// The repo's own plan, read from the checkout the tests run in.
    private func thisReposPlan() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("PLAN.md"), encoding: .utf8)
    }

    private func parse(_ text: String) -> (title: String, components: [PlanComponent], retired: [RetiredComponent]) {
        PlanDocParser.parse(text: text, doc: "PLAN.md")
    }

    // MARK: - This repo's plan

    func testReadsEveryComponentOfThisReposPlanWithItsNeeds() throws {
        let plan = try thisReposPlan()
        let parsed = parse(plan)
        XCTAssertEqual(parsed.title, "g8r: the living map")

        let needs: [String: [String]] = [
            // Built
            "setup": [],
            "terminal": ["setup"],
            "worktrees": [],
            "eventlog": [],
            "eventbus": ["eventlog"],
            "hooks": ["eventbus", "eventlog", "worktrees"],
            "trust": ["eventlog"],
            "globs": [],
            "symbols": ["eventlog", "worktrees"],
            "references": ["symbols", "eventlog"],
            "integration": ["worktrees"],
            "panes": ["terminal", "worktrees", "hooks", "trust", "eventlog"],
            "app": ["panes", "eventbus", "eventlog", "worktrees"],
            // To build
            "plandoc": ["globs"],
            "swiftsymbols": ["symbols"],
            "codemap": ["plandoc", "symbols", "swiftsymbols", "globs", "worktrees"],
            "drift": ["codemap", "plandoc"],
            "timeline": ["codemap"],
            "evidence": ["codemap", "integration"],
            "graphview": ["codemap", "panes", "app"],
            "clickbuild": ["graphview", "evidence", "plandoc", "codemap", "panes", "worktrees", "hooks",
                           "trust", "integration", "eventlog"],
        ]
        let read = Dictionary(parsed.components.map { ($0.id, $0.needs) }, uniquingKeysWith: { first, _ in first })
        for (id, expected) in needs {
            XCTAssertEqual(read[id], expected, "needs of \(id)")
        }

        // The plan grows. Whatever it holds by now, each of its component
        // headings has to come out as a component.
        var fenced = false
        var headings: [String] = []
        for line in plan.components(separatedBy: "\n") {
            if line.hasPrefix("```") { fenced.toggle() }
            if line == "## Retired" { break }
            if !fenced, line.range(of: "^#{2,4} [a-z][a-z0-9-]*: ", options: .regularExpression) != nil {
                headings.append(String(line.drop { $0 == "#" || $0 == " " }))
            }
        }
        XCTAssertEqual(parsed.components.map(\.heading), headings)
        XCTAssertGreaterThanOrEqual(headings.count, needs.count)
    }

    func testReadsTheRestOfAComponentFromThisReposPlan() throws {
        let plandoc = try XCTUnwrap(parse(try thisReposPlan()).components.first { $0.id == "plandoc" })
        XCTAssertEqual(plandoc.name, "Plan doc reader")
        XCTAssertEqual(plandoc.heading, "plandoc: Plan doc reader")
        XCTAssertEqual(plandoc.doc, "PLAN.md")
        XCTAssertEqual(plandoc.summary, "Reads plan docs into a plan graph: the components, what each needs, "
            + "what each changes, and where its code lives.")
        XCTAssertEqual(plandoc.changes, ["integration"])
        XCTAssertEqual(plandoc.paths, ["Sources/G8rCore/PlanDoc/", "Sources/G8rCore/Config/"])
        XCTAssertTrue(plandoc.text.hasPrefix("Reads plan docs into a plan graph"))
        XCTAssertTrue(plandoc.text.contains("public enum PlanDocParser {"), "the code in the section is part of it")
        let doneWhen = try XCTUnwrap(plandoc.doneWhen)
        XCTAssertTrue(doneWhen.hasPrefix("parsing this file yields every component under Built and To build"))
        XCTAssertTrue(doneWhen.hasSuffix("override each other in that order."), "the bullet runs over six lines")

        // A Code bullet that runs onto a second line.
        let hooks = try XCTUnwrap(parse(try thisReposPlan()).components.first { $0.id == "hooks" })
        XCTAssertEqual(hooks.paths, ["Sources/g8r-hook/", "Sources/G8rCore/Hooks/HookProcessor.swift",
                                     "Sources/G8rCore/Hooks/HookInstaller.swift"])
    }

    func testReadsEveryRetiredEntryOfThisReposPlan() throws {
        let retired = parse(try thisReposPlan()).retired
        let names = retired.map(\.name)
        for name in ["Delegation protocol", "Plan store", "Ownership classifier", "Overlap detector", "Map UI",
                     "Lifecycle messages"] {
            XCTAssertTrue(names.contains(name), "\(name) is retired")
        }
        let store = try XCTUnwrap(retired.first { $0.name == "Plan store" })
        XCTAssertEqual(store.why, "Plans now come from plan docs, not from delegation messages.")
        XCTAssertEqual(store.doc, "PLAN.md")
        XCTAssertFalse(retired.contains { $0.why.isEmpty })
        XCTAssertFalse(parse(try thisReposPlan()).components.contains { names.contains($0.name) })
    }

    // MARK: - The format

    func testAComponentSection() {
        let parsed = parse("""
            # Shop

            Prose for people.

            ## auth: Sign in

            Checks who is asking. It keeps
            a session! Nothing else.

            More prose.

            - NEEDS: `db`, mail-2
            - changes: db
            - Code: `src/auth/`, `src/login.ts`,
              `src/**/*.auth.ts`
            - Done When: a wrong password is refused, and `login()`
              says why.
            - Owner: someone

            ## Notes
            """)

        XCTAssertEqual(parsed.title, "Shop")
        XCTAssertEqual(parsed.components.count, 1)
        let auth = parsed.components[0]
        XCTAssertEqual(auth.id, "auth")
        XCTAssertEqual(auth.name, "Sign in")
        XCTAssertEqual(auth.heading, "auth: Sign in")
        XCTAssertEqual(auth.line, 5)
        XCTAssertEqual(auth.doc, "PLAN.md")
        XCTAssertEqual(auth.summary, "Checks who is asking.")
        XCTAssertEqual(auth.needs, ["db", "mail-2"])
        XCTAssertEqual(auth.changes, ["db"])
        XCTAssertEqual(auth.paths, ["src/auth/", "src/login.ts", "src/**/*.auth.ts"])
        XCTAssertEqual(auth.doneWhen, "a wrong password is refused, and `login()` says why.")
        XCTAssertTrue(auth.text.hasPrefix("Checks who is asking. It keeps\na session! Nothing else."))
        XCTAssertTrue(auth.text.hasSuffix("- Owner: someone"), "verbatim, up to the next heading")
    }

    func testABulletEndsAtTheFirstLineThatIsNotIndented() {
        let parsed = parse("""
            ## a: A

            - Needs: b,
              c
            d, e
            - Code: src/a/

              src/not-this/
            """)
        XCTAssertEqual(parsed.components[0].needs, ["b", "c"])
        XCTAssertEqual(parsed.components[0].paths, ["src/a/"])
        XCTAssertNil(parsed.components[0].doneWhen)
    }

    func testOnlyLevelsTwoToFourWithAnIdMakeAComponent() {
        let parsed = parse("""
            # top: Level one
            ## two: Level two
            ### three: Level three
            #### four: Level four
            ##### five: Level five
            ## Two: capital letter
            ## 2fa: starts with a digit
            ## under_score: not in an id
            ## spaced out: not an id
            ## bare:
            ## close:together
            ## Just a heading
            ##nospace: Not a heading
            """)
        XCTAssertEqual(parsed.components.map(\.id), ["two", "three", "four"])
        XCTAssertEqual(parsed.title, "top: Level one")
    }

    func testHeadingsInsideCodeFencesDontCount() {
        let parsed = parse("""
            ## real: Real

            Shown as an example:

            ```markdown
            ## fake: Fake
            - Needs: nothing-real
            ```

            ~~~
            ## tilde: Fenced with tildes
            ```
            ## still: Inside, because a fence closes with the mark that opened it
            ~~~

            ````
            ```swift
            ## nested: A shorter fence inside a longer one is code
            ```
            ````

            - Needs: other

            ## other: Other
            """)
        XCTAssertEqual(parsed.components.map(\.id), ["real", "other"])
        XCTAssertEqual(parsed.components[0].needs, ["other"], "a bullet in a fence is code, not a bullet")
        XCTAssertTrue(parsed.components[0].text.contains("## fake: Fake"), "the text keeps the fence")
    }

    func testASectionRunsToTheNextHeadingOfTheSameOrAHigherLevel() {
        let parsed = parse("""
            ### a: A

            About a.

            #### Details

            Still a.

            ### b: B

            About b.

            ## Later

            Not b.
            """)
        XCTAssertEqual(parsed.components.map(\.id), ["a", "b"])
        XCTAssertEqual(parsed.components[0].text, "About a.\n\n#### Details\n\nStill a.")
        XCTAssertEqual(parsed.components[1].text, "About b.")
    }

    func testAComponentInsideAnotherKeepsItsOwnBulletsAndSummary() {
        let parsed = parse("""
            ## shop: Shop

            - Needs: bank

            ### Opening hours

            Nine to five. Closed on Sundays.

            ### till: Till

            Takes the money.

            - Needs: shop
            - Code: src/till/

            ### door: Door

            - Needs: till
            """)
        XCTAssertEqual(parsed.components.map(\.id), ["shop", "till", "door"])
        XCTAssertEqual(parsed.components.map(\.needs), [["bank"], ["shop"], ["till"]])
        XCTAssertEqual(parsed.components.map(\.paths), [[], ["src/till/"], []])
        XCTAssertEqual(parsed.components.map(\.summary), ["Nine to five.", "Takes the money.", ""])
        XCTAssertTrue(parsed.components[0].text.hasSuffix("- Needs: till"), "the section still holds them")
    }

    func testTheSummaryIsTheFirstSentenceOfTheFirstParagraph() {
        let parsed = parse("""
            ## a: A

            - Code: src/a/

            | Table | Row |
            |---|---|

            ```
            code
            ```

            Reads v1.2 files, e.g. the old ones. Then more.

            ## b: B

            One line with no full stop

            ## c: C

            - Needs: a
            """)
        XCTAssertEqual(parsed.components.map(\.summary),
                       ["Reads v1.2 files, e.g.", "One line with no full stop", ""])
    }

    func testRetired() {
        let parsed = parse("""
            ## live: Live

            Still here.

            ## Retired

            These are gone.

            ### Plan store

            Plans come from docs
            now.

            ### old: Old thing

            Replaced.

            ## after: After

            Here again.
            """)
        XCTAssertEqual(parsed.components.map(\.id), ["live", "after"])
        XCTAssertEqual(parsed.retired, [
            RetiredComponent(name: "Plan store", why: "Plans come from docs now.", doc: "PLAN.md", line: 9),
            RetiredComponent(name: "old: Old thing", why: "Replaced.", doc: "PLAN.md", line: 14),
        ])
    }

    func testADocWithNoTitleIsNamedAfterItsPath() {
        let parsed = PlanDocParser.parse(text: "## a: A\n\nText.\n", doc: "plans/auth.md")
        XCTAssertEqual(parsed.title, "plans/auth.md")
        XCTAssertEqual(parsed.components[0].doc, "plans/auth.md")
    }

    func testAFreeFormDocHasNoComponents() {
        let parsed = parse("# Ideas\n\nWe should build a thing that does stuff.\n\n## Why\n\nBecause.\n")
        XCTAssertEqual(parsed.title, "Ideas")
        XCTAssertTrue(parsed.components.isEmpty)
        XCTAssertTrue(parsed.retired.isEmpty)
    }

    func testWindowsLineEndings() {
        let parsed = parse("# Shop\r\n\r\n## a: A\r\n\r\nAbout a. More.\r\n\r\n- Needs: b,\r\n  c\r\n")
        XCTAssertEqual(parsed.title, "Shop")
        XCTAssertEqual(parsed.components.map(\.id), ["a"])
        XCTAssertEqual(parsed.components[0].line, 3)
        XCTAssertEqual(parsed.components[0].summary, "About a.")
        XCTAssertEqual(parsed.components[0].needs, ["b", "c"])
    }
}
