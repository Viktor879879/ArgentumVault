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
        #expect(
            SecurityValidation.sanitizeWalletName(String(repeating: "A", count: 81))
            == String(repeating: "A", count: SecurityValidation.maxWalletNameLength)
        )
        #expect(SecurityValidation.sanitizeNote(String(repeating: "x", count: 500)) != nil)
        #expect(
            SecurityValidation.sanitizeNote(String(repeating: "x", count: 501))
            == String(repeating: "x", count: SecurityValidation.maxNoteLength)
        )
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

    @Test func parsesAmountsWithCommaDotAndGroupingSeparators() async throws {
        let swedish = Locale(identifier: "sv_SE")
        let us = Locale(identifier: "en_US")

        #expect(DecimalFormatter.parse("132,14", locale: swedish) == Decimal(string: "132.14"))
        #expect(DecimalFormatter.parse("132.14", locale: swedish) == Decimal(string: "132.14"))
        #expect(DecimalFormatter.parse("0,99", locale: swedish) == Decimal(string: "0.99"))
        #expect(DecimalFormatter.parse("1,5", locale: swedish) == Decimal(string: "1.5"))
        #expect(DecimalFormatter.parse("1000,25", locale: swedish) == Decimal(string: "1000.25"))
        #expect(DecimalFormatter.parse("1 000,25", locale: swedish) == Decimal(string: "1000.25"))
        #expect(DecimalFormatter.parse("1\u{00A0}000,25", locale: swedish) == Decimal(string: "1000.25"))
        #expect(DecimalFormatter.parse("1.000,25", locale: swedish) == Decimal(string: "1000.25"))
        #expect(DecimalFormatter.parse("1,000.25", locale: us) == Decimal(string: "1000.25"))
        #expect(DecimalFormatter.parse("132,14", locale: us) == Decimal(string: "132.14"))
    }

    @Test func rejectsMalformedMixedSeparatorAmounts() async throws {
        let swedish = Locale(identifier: "sv_SE")

        #expect(DecimalFormatter.parse("1,000.2,5", locale: swedish) == nil)
        #expect(DecimalFormatter.parse("1.000,2.5", locale: swedish) == nil)
        #expect(DecimalFormatter.parse("1..25", locale: swedish) == nil)
    }

    @Test func exportsDecimalAmountsWithoutFloatingPointConversion() async throws {
        #expect(DecimalFormatter.exportString(from: Decimal(string: "132.14")!) == "132.14")
        #expect(DecimalFormatter.exportString(from: Decimal(string: "1000.25")!) == "1000.25")
    }

    @Test func appleNonceHelpersStayStableAndBounded() async throws {
        let nonce = AppleSignInCoordinator.randomNonceString(length: 32)
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")

        #expect(nonce.count == 32)
        #expect(nonce.allSatisfy { allowed.contains($0) })
        #expect(AppleSignInCoordinator.sha256("argentum").count == 64)
        #expect(AppleSignInCoordinator.sha256("argentum") == AppleSignInCoordinator.sha256("argentum"))
    }

    @Test func quickExpenseRouteMatchesExpectedDeepLink() async throws {
        #expect(QuickExpenseRoute.matches(URL(string: "argentumvault://expense/new")!))
        #expect(!QuickExpenseRoute.matches(URL(string: "argentumvault://expense/edit")!))
        #expect(!QuickExpenseRoute.matches(URL(string: "otherapp://expense/new")!))
    }
}
