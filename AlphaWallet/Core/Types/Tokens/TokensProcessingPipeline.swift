//
//  TokensProcessingPipeline.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 09.07.2022.
//

import Foundation
import Combine
import CombineExt

protocol TokenViewModelState {
    var tokenViewModels: AnyPublisher<[TokenViewModel], Never> { get }

    func tokenViewModelPublisher(for contract: AlphaWallet.Address, server: RPCServer) -> AnyPublisher<TokenViewModel?, Never>
    func tokenViewModel(for contract: AlphaWallet.Address, server: RPCServer) -> TokenViewModel?
    func refresh()
}

protocol TokenBalanceRefreshable {
    func refreshBalance(updatePolicy: TokenBalanceFetcher.RefreshBalancePolicy)
}

protocol TokensProcessingPipeline: TokenViewModelState, TokenProvidable, TokenAddable, TokenHidable, TokenBalanceRefreshable, PipelineTests {
    func start()
}

typealias TokenCollection = TokenViewModelState & TokenProvidable & TokenAddable & TokenHidable & TokenBalanceRefreshable

class WalletDataProcessingPipeline: TokensProcessingPipeline {

//    func start() -> WalletData {
//        let walletApiData = await callWalletApi(mostChains)
//        let unsupportedOrPrivateChainData = await callInfuraAndEtherscan(unsupportedByWalletApiChains)
//        let walletData = combineData(walletApiData, unsupportedOrPrivateChainData)
//        let contracts = contractsFrom(walletData)
//        let withCoinGeckoData = await callAndApplyCoinGecko(contracts)
//        let withTokenScript = await applyTokenScriptAndFetch()
//        return withTokenScript
//    }

    var tokenViewModels: AnyPublisher<[TokenViewModel], Never> {
        return tokenViewModelsSubject.eraseToAnyPublisher()
    }

    private let coinTickersFetcher: CoinTickersFetcher
    private let tokensService: TokensService
    private let assetDefinitionStore: AssetDefinitionStore
    private var cancelable = Set<AnyCancellable>()
    private let tokenViewModelsSubject = CurrentValueSubject<[TokenViewModel], Never>([])
    private let eventsDataStore: NonActivityEventsDataStore
    private let wallet: Wallet

    init(wallet: Wallet, tokensService: TokensService, coinTickersFetcher: CoinTickersFetcher, assetDefinitionStore: AssetDefinitionStore, eventsDataStore: NonActivityEventsDataStore) {
        self.wallet = wallet
        self.eventsDataStore = eventsDataStore
        self.tokensService = tokensService
        self.coinTickersFetcher = coinTickersFetcher
        self.assetDefinitionStore = assetDefinitionStore
    }

    func tokens(for servers: [RPCServer]) -> [Token] {
        tokensService.tokens(for: servers)
    }

    func mark(token: TokenIdentifiable, isHidden: Bool) {
        tokensService.mark(token: token, isHidden: isHidden)
    }

    func refresh() {
        tokensService.refresh()
    }
    
    func start() {
        cancelable.cancellAll()
        tokensService.start()
        startTickersHandling()
        preparePipeline()
    }

    deinit {
        tokensService.stop()
    }

    func refreshBalance(updatePolicy: TokenBalanceFetcher.RefreshBalancePolicy) {
        tokensService.refreshBalance(updatePolicy: updatePolicy)
    }

    func tokenViewModel(for contract: AlphaWallet.Address, server: RPCServer) -> TokenViewModel? {
        return tokensService.token(for: contract, server: server)
            .flatMap { TokenViewModel(token: $0) }
            .flatMap { [weak self] in self?.applyTicker(token: $0) }
            .flatMap { [weak self] in self?.applyTokenScriptOverrides(token: $0) }
    }

    func tokenViewModelPublisher(for contract: AlphaWallet.Address, server: RPCServer) -> AnyPublisher<TokenViewModel?, Never> {
        let whenTickersHasChanged: AnyPublisher<Token?, Never> = coinTickersFetcher.tickersDidUpdate.dropFirst()
            //NOTE: filter coin ticker events, allow only if ticker has change
            .compactMap { [coinTickersFetcher] _ in coinTickersFetcher.ticker(for: .init(address: contract, server: server)) }
            .removeDuplicates()
            .map { [tokensService] _ in tokensService.token(for: contract, server: server) }
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()

        let whenSignatureOrBodyChanged: AnyPublisher<Token?, Never> = assetDefinitionStore
            .assetsSignatureOrBodyChange(for: contract)
            .map { [tokensService] _ in tokensService.token(for: contract, server: server) }
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()

        let whenEventHasChanged: AnyPublisher<Token?, Never> = eventsDataStore
            .recentEventsChangeset(for: contract)
            .filter({ changeset in
                switch changeset {
                case .update(let events, _, let insertions, let modifications):
                    return !insertions.map { events[$0] }.isEmpty || !modifications.map { events[$0] }.isEmpty
                case .initial, .error:
                    return false
                }
            }).map { [tokensService] _ in tokensService.token(for: contract, server: server) }
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()

        return Publishers.Merge4(tokensService.tokenPublisher(for: contract, server: server), whenTickersHasChanged, whenSignatureOrBodyChanged, whenEventHasChanged)
            .map { $0.flatMap { TokenViewModel(token: $0) } }
            .map { [weak self] in self?.applyTicker(token: $0) }
            .map { [weak self] in self?.applyTokenScriptOverrides(token: $0) }
            .eraseToAnyPublisher()
    }

    func token(for contract: AlphaWallet.Address) -> Token? {
        tokensService.token(for: contract)
    }

    func token(for contract: AlphaWallet.Address, server: RPCServer) -> Token? {
        tokensService.token(for: contract, server: server)
    }

    func addCustom(tokens: [ERCToken], shouldUpdateBalance: Bool) -> [Token] {
        tokensService.addCustom(tokens: tokens, shouldUpdateBalance: shouldUpdateBalance)
    }

    func tokenPublisher(for contract: AlphaWallet.Address, server: RPCServer) -> AnyPublisher<Token?, Never> {
        tokensService.tokenPublisher(for: contract, server: server)
    }

    func addOrUpdateTestsOnly(ticker: CoinTicker?, for token: TokenMappedToTicker) {
        coinTickersFetcher.addOrUpdateTestsOnly(ticker: ticker, for: token)
    }

    private func preparePipeline() {
        let whenTickersChange: AnyPublisher<[Token], Never> = coinTickersFetcher.tickersDidUpdate.dropFirst()
            .map { [tokensService] _ in tokensService.tokens }
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()

        let whenSignatureOrBodyChange: AnyPublisher<[Token], Never> = assetDefinitionStore
            .assetsSignatureOrBodyChange
            .map { [tokensService] _ in tokensService.tokens }
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()

        Publishers.Merge3(tokensService.tokensPublisher, whenTickersChange, whenSignatureOrBodyChange)
            .map { $0.map { TokenViewModel(token: $0) } }
            .flatMapLatest { [weak self] in self?.applyTickers(tokens: $0) ?? .empty() }
            .flatMapLatest { [weak self] in self?.applyTokenScriptOverrides(tokens: $0) ?? .empty() }
            .assign(to: \.value, on: tokenViewModelsSubject, ownership: .weak)
            .store(in: &cancelable)
    }

    private func startTickersHandling() {
        //NOTE: To don't block start method, and apply delay to fetch tickers, inital only
        Publishers.Merge(Just(tokensService.tokens).delay(for: .seconds(2), scheduler: RunLoop.main), tokensService.newTokens)
            .removeDuplicates()
            .eraseToAnyPublisher()
            .sink { [coinTickersFetcher, tokensService] tokens in
                let nativeCryptoForAllChains = RPCServer.allCases.map { MultipleChainsTokensDataStore.functional.etherToken(forServer: $0) }
                let tokens = (tokens + nativeCryptoForAllChains).filter { !$0.server.isTestnet }
                let uniqueTokens = Set(tokens).map { TokenMappedToTicker(symbol: $0.symbol, name: $0.name, contractAddress: $0.contractAddress, server: $0.server, coinGeckoId: nil) }

                coinTickersFetcher.fetchTickers(for: uniqueTokens, force: false)
                tokensService.refreshBalance(updatePolicy: .tokens(tokens: tokens))
            }.store(in: &cancelable)

        coinTickersFetcher.updateTickerId.sink { [tokensService] data in
            guard let token = tokensService.token(for: data.key.address, server: data.key.server) else { return }
            tokensService.update(token: token, value: .coinGeckoTickerId(data.tickerId))
        }.store(in: &cancelable)
    }

    private func applyTokenScriptOverrides(tokens: [TokenViewModel]) -> AnyPublisher<[TokenViewModel], Never> {
        let overrides = tokens.map { token -> TokenViewModel in
            let overrides = TokenScriptOverrides(token: token, assetDefinitionStore: assetDefinitionStore, wallet: wallet, eventsDataStore: eventsDataStore)
            return token.override(tokenScriptOverrides: overrides)
        }
        return .just(overrides)
    }

    private func applyTokenScriptOverrides(token: TokenViewModel?) -> TokenViewModel? {
        guard let token = token else { return token }

        let overrides = TokenScriptOverrides(token: token, assetDefinitionStore: assetDefinitionStore, wallet: wallet, eventsDataStore: eventsDataStore)
        return token.override(tokenScriptOverrides: overrides)
    }

    private func applyTickers(tokens: [TokenViewModel]) -> AnyPublisher<[TokenViewModel], Never> {
        return .just(tokens.compactMap { applyTicker(token: $0) })
    }

    private func applyTicker(token: TokenViewModel?) -> TokenViewModel? {
        guard let token = token else { return nil }
        let ticker = coinTickersFetcher.ticker(for: .init(address: token.contractAddress, server: token.server))
        let balance: BalanceViewModel
        switch token.type {
        case .nativeCryptocurrency:
            balance = .init(balance: NativecryptoBalanceViewModel(token: token, ticker: ticker))
        case .erc20:
            balance = .init(balance: Erc20BalanceViewModel(token: token, ticker: ticker))
        case .erc875, .erc721, .erc721ForTickets, .erc1155:
            balance = .init(balance: NFTBalanceViewModel(token: token, ticker: ticker))
        }

        return token.override(balance: balance)
    }
}

extension TokenViewModelState {

    func tokenViewModelPublisher(for token: Token) -> AnyPublisher<TokenViewModel?, Never> {
        return tokenViewModelPublisher(for: token.contractAddress, server: token.server)
    }

    func tokenViewModel(for token: Token) -> TokenViewModel? {
        return tokenViewModel(for: token.contractAddress, server: token.server)
    }
}