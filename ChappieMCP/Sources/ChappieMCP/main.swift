// main.swift — entry point for ChappieMCP
//
// All logic lives in the ChappieMCPCore library so it can be unit-tested (an executable target
// cannot be imported by a test bundle reliably). See ChappieMCPCore/Sources/ChappieMCPCore/HelperEntry.swift
// for the command-line contract.
//
// MANUAL LAUNCH (for debugging):
//   ChappieMCP /path/to/workspace /tmp/com.chappie.mcp.test.sock \
//     '{"Chappie":"xcode"}' '{"Chappie":"/path/to/Chappie"}'

import ChappieMCPCore

ChappieMCPHelper.run(arguments: CommandLine.arguments)
