// JSONEditPlanner+Delete.swift
// ChappieCore
//
// Removing members. A run of neighbouring members is cut out together with ONE comma:
//   - run is not the last: from the start of its first member to the start of the member after it;
//   - run reaches the last member: from the end of the member before it to the end of the run;
//   - run is everything: the container becomes empty, written the way the file writes empty ones.
// A comment in any gap the cut touches is refused: it almost certainly describes the removed member.

import Foundation

extension JSONEditPlanner {

    mutating func planDeletions() {
        for (parent, members) in deletions.sorted(by: { $0.key < $1.key }) {
            let children = doc.nodes[parent].children
            var position: [Int: Int] = [:]
            for (offset, child) in children.enumerated() { position[child] = offset }
            let sorted = members.sorted { (position[$0.node] ?? 0) < (position[$1.node] ?? 0) }

            var runs: [[(node: Int, op: Int)]] = []
            for member in sorted {
                if let last = runs.last?.last, (position[member.node] ?? 0) == (position[last.node] ?? 0) + 1 {
                    runs[runs.count - 1].append(member)
                } else {
                    runs.append([member])
                }
            }
            for run in runs { planRun(parent: parent, children: children, run: run, position: position) }
        }
    }

    private mutating func planRun(
        parent: Int, children: [Int], run: [(node: Int, op: Int)], position: [Int: Int]
    ) {
        let first = position[run[0].node] ?? 0
        let last = position[run[run.count - 1].node] ?? 0
        let count = children.count
        let container = doc.nodes[parent]
        let ops = run.map(\.op)
        let name = ops.count == 1 ? "edit \(ops[0])" : "edits \(JSONSplicer.numbers(ops))"

        // Gaps the cut touches, as byte ranges between tokens.
        var gaps: [(Int, Int)] = []
        gaps.append((first == 0 ? container.start + 1 : doc.nodes[children[first - 1]].end, doc.nodes[children[first]].memberStart))
        for index in first..<last {
            gaps.append((doc.nodes[children[index]].end, doc.nodes[children[index + 1]].memberStart))
        }
        gaps.append((doc.nodes[children[last]].end, last + 1 < count ? doc.nodes[children[last + 1]].memberStart : container.end - 1))
        if gaps.contains(where: { hasComment(from: $0.0, to: $0.1) }) {
            problem("\(name) (delete): there is a comment next to the member being removed, and it would be lost or left pointing at the wrong thing. Remove that part with patch_file instead.")
            return
        }

        if first == 0 && last == count - 1 {
            let text = renderer.emptyContainer(isObject: container.kind == .object, baseIndent: lineIndent(at: container.memberStart))
            addSplice(JSONSplice(start: container.start, end: container.end, text: Array(text.utf8), ops: ops))
        } else if last < count - 1 {
            addSplice(JSONSplice(start: doc.nodes[children[first]].memberStart, end: doc.nodes[children[last + 1]].memberStart, text: [], ops: ops))
        } else {
            addSplice(JSONSplice(start: doc.nodes[children[first - 1]].end, end: doc.nodes[children[last]].end, text: [], ops: ops))
        }
    }
}
