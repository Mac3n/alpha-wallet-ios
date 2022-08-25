//
//  SwapTokenNativeProvider.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 10.05.2022.
//

import Foundation
import Combine

final class SwapTokenNativeProvider: SupportedTokenActionsProvider, TokenActionProvider {
    private let tokenSwapper: TokenSwapper

    var objectWillChange: AnyPublisher<Void, Never> {
        return tokenSwapper.objectWillChange
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }
    let analyticsName: String = "Native Swap"
    let analyticsNavigation: Analytics.Navigation = .fallback
    let action: String = "Native Swap"

    init(tokenSwapper: TokenSwapper) {
        self.tokenSwapper = tokenSwapper
    }

    func isSupport(token: TokenActionsIdentifiable) -> Bool {
        guard Features.default.isAvailable(.isSwapEnabled) else { return false }
        return tokenSwapper.supports(contractAddress: token.contractAddress, server: token.server)
    }

    func actions(token: TokenActionsIdentifiable) -> [TokenInstanceAction] {
        return [.init(type: .swap(service: self))]
    }

    func start() {
        tokenSwapper.start()
    }
}
