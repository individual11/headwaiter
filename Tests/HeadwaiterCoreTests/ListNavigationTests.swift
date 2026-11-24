import Foundation
import Testing
@testable import HeadwaiterCore

@Suite("Keyboard navigation and filter")
struct ListNavigationTests {
    let texts = ["@shop/web", "my-shop › checkout-fix", "Next.js", "node", "apps/web", ":3000", ":9229"]

    @Test(arguments: ["web", "WEB", "shop next", "3000", ":3000", "checkout", "9229 node", "  web  "])
    func matches(_ text: String) { #expect(ListFilter(text).matches(texts)) }

    @Test(arguments: ["api", "web vite", "3001", "3000 5173"])
    func doesNotMatch(_ text: String) { #expect(!ListFilter(text).matches(texts)) }

    @Test func emptyFilterMatchesEverything() {
        #expect(ListFilter("  ").isEmpty)
        #expect(ListFilter("").matches([]))
    }

    @Test func accentsAreIgnored() { #expect(ListFilter("cafe").matches(["Café"])) }

    @Test func movingStopsAtTheEnds() {
        let ids = ["a", "b", "c"]
        #expect(ListSelection.move("a", by: 1, in: ids) == "b")
        #expect(ListSelection.move("c", by: 1, in: ids) == "c")
        #expect(ListSelection.move("a", by: -1, in: ids) == "a")
        #expect(ListSelection.move(nil, by: 1, in: ids) == "a")
        #expect(ListSelection.move(nil, by: -1, in: ids) == "c")
        #expect(ListSelection.move("gone", by: 1, in: ids) == "a")
        #expect(ListSelection.move("a", by: 1, in: []) == nil)
    }

    @Test func selectionSurvivesListChanges() {
        let old = ["a", "b", "c"]
        #expect(ListSelection.keep("b", from: old, to: ["b", "d"]) == "b")
        #expect(ListSelection.keep("b", from: old, to: ["a", "c"]) == "c")
        #expect(ListSelection.keep("c", from: old, to: ["a", "b"]) == "b")
        #expect(ListSelection.keep("b", from: old, to: ["x"]) == nil)
        #expect(ListSelection.keep("b", from: old, to: []) == nil)
        #expect(ListSelection.keep(nil, from: old, to: ["a"]) == nil)
    }
}
