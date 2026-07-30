enum TranslationResponseMembership {
    static func validateAndOrder(
        _ results: [TranslationResult],
        expectedIdentifiers: [String]
    ) throws -> [TranslationResult] {
        let expectedIdentifierSet = Set(expectedIdentifiers)
        let unknownCount = results.count { !expectedIdentifierSet.contains($0.requestID) }
        guard unknownCount == 0 else {
            throw TranslationFailure.invalidResponseMembership(
                .unknownIdentifiers(count: unknownCount)
            )
        }

        var resultsByIdentifier: [String: TranslationResult] = [:]
        resultsByIdentifier.reserveCapacity(results.count)
        var duplicateCount = 0
        for result in results {
            if resultsByIdentifier.updateValue(result, forKey: result.requestID) != nil {
                duplicateCount += 1
            }
        }
        guard duplicateCount == 0 else {
            throw TranslationFailure.invalidResponseMembership(
                .duplicateIdentifiers(count: duplicateCount)
            )
        }

        let missingCount = expectedIdentifiers.count { resultsByIdentifier[$0] == nil }
        guard missingCount == 0 else {
            throw TranslationFailure.invalidResponseMembership(
                .missingIdentifiers(count: missingCount)
            )
        }

        return expectedIdentifiers.map { identifier in
            guard let result = resultsByIdentifier[identifier] else {
                preconditionFailure("Validated result membership must be complete.")
            }
            return result
        }
    }
}
