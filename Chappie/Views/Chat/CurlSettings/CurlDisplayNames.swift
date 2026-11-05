// CurlDisplayNames.swift
// Chappie
//
// Localized labels for Curl-Chappie model enums and validation issues. The core stays
// free of UI strings; the views only call these properties.

import Foundation
import ChappieCore

extension CurlHostPermission {

    var displayName: String {
        switch self {
        case .readOnly:     return String(localized: "curl.permission.read_only")
        case .readAndLogin: return String(localized: "curl.permission.read_and_login")
        case .full:         return String(localized: "curl.permission.full")
        }
    }

    var hint: String {
        switch self {
        case .readOnly:     return String(localized: "curl.permission.read_only.hint")
        case .readAndLogin: return String(localized: "curl.permission.read_and_login.hint")
        case .full:         return String(localized: "curl.permission.full.hint")
        }
    }
}

extension CurlSecretKind {

    var displayName: String {
        switch self {
        case .loginPassword: return String(localized: "curl.kind.login_password")
        case .token:         return String(localized: "curl.kind.token")
        case .customHeader:  return String(localized: "curl.kind.custom_header")
        case .plain:         return String(localized: "curl.kind.plain")
        }
    }
}

extension CurlSecretField {

    var label: String {
        switch self {
        case .login:    return String(localized: "curl.field.login")
        case .password: return String(localized: "curl.field.password")
        case .value:    return String(localized: "curl.field.value")
        }
    }
}

extension CurlHostIssue {

    var message: String {
        switch self {
        case .emptyName:        return String(localized: "curl.issue.host.empty_name")
        case .invalidOrigin:    return String(localized: "curl.issue.host.invalid_origin")
        case .duplicateOrigin:  return String(localized: "curl.issue.host.duplicate_origin")
        case .missingLoginPath: return String(localized: "curl.issue.host.missing_login_path")
        }
    }
}

extension CurlSecretIssue {

    var message: String {
        switch self {
        case .invalidName:       return String(localized: "curl.issue.secret.invalid_name")
        case .duplicate:         return String(localized: "curl.issue.secret.duplicate")
        case .missingHost:       return String(localized: "curl.issue.secret.missing_host")
        case .missingHeaderName: return String(localized: "curl.issue.secret.missing_header_name")
        }
    }
}
