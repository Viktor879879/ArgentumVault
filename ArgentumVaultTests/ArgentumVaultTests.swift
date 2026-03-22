//
//  ArgentumVaultTests.swift
//  ArgentumVaultTests
//
//  Created by Viktor Parshyn on 2026-02-04.
//

import Foundation
import Testing
@testable import ArgentumVault

@MainActor
struct ArgentumVaultTests {
    @Test func rejectsServerSupabaseKeys() async throws {
        #expect(SecurityValidation.isAllowedSupabaseClientKey("sb_publishable_test_key"))
        #expect(!SecurityValidation.isAllowedSupabaseClientKey("service_role_very_bad"))
        #expect(!SecurityValidation.isAllowedSupabaseClientKey("sb_secret_very_bad"))
    }

    @Test func normalizesAndBoundsUserInput() async throws {
        #expect(SecurityValidation.sanitizeCategoryName("  Groceries \n ") == "Groceries")
        #expect(SecurityValidation.sanitizeWalletName(String(repeating: "A", count: 81)) == nil)
        #expect(SecurityValidation.sanitizeNote(String(repeating: "x", count: 500)) != nil)
        #expect(SecurityValidation.sanitizeNote(String(repeating: "x", count: 501)) == nil)
    }

    @Test func validatesAmountsAndBackupMetadata() async throws {
        #expect(SecurityValidation.isAllowedAmountInput("123.45"))
        #expect(!SecurityValidation.isAllowedAmountInput(String(repeating: "9", count: 41)))
        #expect(SecurityValidation.sanitizePositiveAmount(Decimal(string: "12.50")) == Decimal(string: "12.50"))
        #expect(SecurityValidation.sanitizePositiveAmount(0) == nil)
        #expect(SecurityValidation.sanitizeAccountBucket("0123456789abcdef01234567") == "0123456789abcdef01234567")
        #expect(SecurityValidation.sanitizeAccountBucket("not-a-bucket") == nil)
        #expect(SecurityValidation.sanitizeSHA256Hex(String(repeating: "a", count: 64)) == String(repeating: "a", count: 64))
        #expect(SecurityValidation.sanitizeSHA256Hex("short") == nil)
    }
}
