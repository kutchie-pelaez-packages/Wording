import Combine
import Core
import Foundation
import Language
import LocalizationManager
import Logger
import Tweak
import Wording

public final class WordingManagerImpl<Wording>: TweakReceiver where Wording: Wordingable {
    init(
        localizationManager: LocalizationManager,
        logger: Logger,
        provider: WordingManagerProvider
    ) {
        self.localizationManager = localizationManager
        self.logger = logger
        self.provider = provider
        populateCahceWithBundledWording()
        populateCahceWithPersistedWording()
        subscribeToEvents()
        Task {
            try await fetchWordingForAllLocalizations()
        }
    }

    private let localizationManager: LocalizationManager
    private let logger: Logger
    private let provider: WordingManagerProvider

    private var cancellables = [AnyCancellable]()

    private var cache = [Localization: Wording]()
    private let decoder = WordingDecoder<Wording>()
    private let encoder = WordingEncoder<Wording>()

    private lazy var _wordingSubject = MutableValueSubject<Wording>(
        wording(for: localizationManager.languageSubject.value.localization)
    )

    // MARK: - Subscribe to events

    private func subscribeToEvents() {
        localizationManager.languageSubject
            .sink { [weak self] newLanguage in
                self?.syncWording(for: newLanguage.localization)
            }
            .store(in: &cancellables)
    }

    private func syncWording(for localization: Localization) {
        let newWording = wording(for: localization)
        _wordingSubject.value = newWording
    }

    // MARK: - Initial cache populating

    private func populateCahceWithBundledWording() {
        populateCacheForAllLocalizations(
            provider.wordingBundledURL,
            wordingType: .bundled,
            assertOnFailure: true
        )
    }

    private func populateCahceWithPersistedWording() {
        populateCacheForAllLocalizations(
            provider.wordingPersistedURL,
            wordingType: .persisted,
            assertOnFailure: false
        )
    }

    private func populateCacheForAllLocalizations(
        _ urlAccessor: (Localization) -> URL,
        wordingType: WordingType,
        assertOnFailure: Bool
    ) {
        for localization in localizationManager.supportedLocalizations.englishFirst {
            do {
                try populateCache(
                    from: urlAccessor(localization),
                    for: localization
                )

                logger.log("Successfully populated cache with \(wordingType) wording for \(localization) localization", domain: .wording)
            } catch {
                let message = "Failed to populate cache with \(wordingType) wording for \(localization) localization, error: \(error.localizedDescription)"

                switch wordingType {
                case .bundled:
                    logger.error(message, domain: .wording)

                case .persisted:
                    logger.warning(message, domain: .wording)
                }

                if assertOnFailure {
                    safeCrash()
                }

                continue
            }
        }
    }

    private func populateCache(
        from url: URL,
        for localization: Localization
    ) throws {
        let data = try Data(contentsOf: url)
        var wording = try decoder.decode(from: data)

        mutateWordingWithFallbacks(&wording, using: localization)
        cache[localization] = wording
    }

    // MARK: - Providing fallback

    private func mutateWordingWithFallbacks(
        _ wording: inout Wording,
        using localization: Localization
    ) {
        if
            localization != .en,
            let cachedLocalizedWording = cache[localization]
        {
            wording.mutate(using: cachedLocalizedWording)
        }

        if let cachedEnWording = cache[.en] {
            wording.mutate(using: cachedEnWording)
        }
    }

    private func wording(for localization: Localization) -> Wording {
        safeUndefinedIfNil(
            cache[localization],
            undefinedIfNil(
                cache[.en],
                "Failed to get cached en wording"
            ),
            "Failed to get cached wording for \(localization) localization"
        )
    }

    // MARK: - Fetching & persisting

    private func fetchWordingForAllLocalizations() async throws {
        for localization in localizationManager.supportedLocalizations.localizationFirst(localizationManager.languageSubject.value.localization) {
            do {
                let wording = try await fetchWording(for: localization)

                try persistFetchedWording(
                    wording,
                    for: localization
                )

                cache[localization] = wording
                syncWording(for: localization)
            } catch WordingManagerProviderError.noRemoteWordingSupported {
                break
            } catch {
                logger.error("Failed to fetch wording for \(localization) localization, error: \(error.localizedDescription)", domain: .wording)
            }
        }
    }

    private func fetchWording(for localization: Localization) async throws -> Wording {
        let wordingData = try await provider.wordingRemoteData(for: localization)
        var wording = try decoder.decode(from: wordingData)

        logger.log("Successfully fetched wording for \(localization) localization", domain: .wording)
        mutateWordingWithFallbacks(&wording, using: localization)

        return wording
    }

    private func persistFetchedWording(
        _ wording: Wording,
        for localization: Localization
    ) throws {
        let url = provider.wordingPersistedURL(for: localization)
        let data = try encoder.encode(wording)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    // MARK: - TweakReceiver

    public func receive(_ tweak: Tweak) {
        guard tweak.id == .Localization.fetchAndUpdateWording else { return }

        Task {
            try await fetchWordingForAllLocalizations()
        }
    }

    // MARK: - Public interface

    public var wordingSubject: ValueSubject<Wording> { _wordingSubject }
}

extension LogDomain {
    fileprivate static let wording: Self = "wording"
}
