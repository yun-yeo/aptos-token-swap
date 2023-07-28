module token_swap::pool {
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::fixed_point64;
    use aptos_framework::string;
    use aptos_framework::signer;
    use aptos_framework::type_info;
    
    use std::option;

    struct Pool<phantom CoinA, phantom CoinB, phantom CoinLP> has key {
        coin_a: Coin<CoinA>,
        coin_b: Coin<CoinB>,
    }

    struct CoinCapabilityStore<phantom CoinLP> has key {
        burn_cap: coin::BurnCapability<CoinLP>,
        freeze_cap: coin::FreezeCapability<CoinLP>,
        mint_cap: coin::MintCapability<CoinLP>,
    }

    //
    // Errors
    //

    /// returned when the resource is already exists.
    const EALREADY_EXISTS: u64 = 1;

    /// returned when the resource is not exists.
    const ENOT_EXISTS: u64 = 1;

    /// returned when the result amount is smaller than
    /// the expected.
    const EMINIMUM_AMOUNT: u64 = 2;

    /// returned when the given coin type is not one of pool coins.
    const EINVALID_COIN_TYPE: u64 = 3;

    //
    // Helper Functions
    //

    /// A helper function that returns the address of CoinLP.
    fun pool_address<CoinLP>(): address {
        let type_info = type_info::type_of<CoinLP>();
        type_info::account_address(&type_info)
    }

    //
    // Entry Functions
    //

    /// initialize swap pool and create liquidity token. 
    public entry fun initialize_pool<CoinA, CoinB, CoinLP>(
        account: &signer,
        coin_a_amount: u64,
        coin_b_amount: u64,
    ) {
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<CoinLP>(
            account,
            string::utf8(b"CoinLP"),
            string::utf8(b"CoinLP"),
            8,
            true,
        );
        let coin_lp_amount = if (coin_a_amount > coin_b_amount) {
            coin_a_amount
        } else {
            coin_b_amount
        };

        let coin_lp = coin::mint(coin_lp_amount, &mint_cap);
        coin::register<CoinLP>(account);
        coin::deposit<CoinLP>(signer::address_of(account), coin_lp);

        move_to<CoinCapabilityStore<CoinLP>>(account, CoinCapabilityStore<CoinLP> {
            burn_cap,
            freeze_cap,
            mint_cap,
        });

        let coin_a = coin::withdraw<CoinA>(account, coin_a_amount);
        let coin_b = coin::withdraw<CoinB>(account, coin_b_amount);

        assert!(!exists<Pool<CoinA, CoinB, CoinLP>>(signer::address_of(account)), EALREADY_EXISTS);
        move_to<Pool<CoinA, CoinB, CoinLP>>(account, Pool<CoinA, CoinB, CoinLP> {
            coin_a,
            coin_b,
        });
    }

    public entry fun provide_liquidty<CoinA, CoinB, CoinLP>(
        account: &signer,
        coin_a_amount: u64,
        coin_b_amount: u64,
        min_coin_lp_amount: u64,
    ) acquires CoinCapabilityStore, Pool {
        assert!(exists<Pool<CoinA, CoinB, CoinLP>>(signer::address_of(account)), ENOT_EXISTS);

        let coin_a = coin::withdraw<CoinA>(account, coin_a_amount);
        let coin_b = coin::withdraw<CoinB>(account, coin_b_amount);

        let pool_addr = pool_address<CoinLP>();
        let pool = borrow_global_mut<Pool<CoinA, CoinB, CoinLP>>(pool_addr);
        
        // load pool amounts
        let pool_coin_a_amount = coin::value(&pool.coin_a);
        let pool_coin_b_amount = coin::value(&pool.coin_b);
        let pool_coin_lp_supply = *option::borrow<u128>(&coin::supply<CoinLP>());
        
        // compute min ratio to calculate mint lp coin amount
        let ratio = fixed_point64::min(
            fixed_point64::create_from_rational((coin_a_amount as u128), (pool_coin_a_amount as u128)),
            fixed_point64::create_from_rational((coin_b_amount as u128), (pool_coin_b_amount as u128))
        );

        // compute mint lp coin amount
        let coin_lp_amount = (fixed_point64::multiply_u128(pool_coin_lp_supply, ratio) as u64);
        
        // load capabilities for lp coin mint
        let coin_caps = borrow_global<CoinCapabilityStore<CoinLP>>(signer::address_of(account));
        let coin_lp = coin::mint<CoinLP>(coin_lp_amount, &coin_caps.mint_cap);

        assert!(coin_lp_amount >= min_coin_lp_amount, EMINIMUM_AMOUNT);

        // deposit the minted lp coin
        coin::deposit<CoinLP>(signer::address_of(account), coin_lp);

        // put the user coins to pool
        coin::merge<CoinA>(&mut pool.coin_a, coin_a);
        coin::merge<CoinB>(&mut pool.coin_b, coin_b);
    }

    public entry fun withdraw_liquidity<CoinA, CoinB, CoinLP>(
        account: &signer,
        coin_lp_amount: u64,
    ) acquires CoinCapabilityStore, Pool {
        assert!(exists<Pool<CoinA, CoinB, CoinLP>>(signer::address_of(account)), ENOT_EXISTS);

        let pool = borrow_global_mut<Pool<CoinA, CoinB, CoinLP>>(signer::address_of(account));
        
        let pool_coin_a_amount = coin::value(&pool.coin_a);
        let pool_coin_b_amount = coin::value(&pool.coin_b);
        let pool_coin_lp_supply = *option::borrow<u128>(&coin::supply<CoinLP>());

        let ratio = fixed_point64::create_from_rational((coin_lp_amount as u128), (pool_coin_lp_supply as u128));

        let coin_a_amount = (fixed_point64::multiply_u128((pool_coin_a_amount as u128), ratio) as u64);
        let coin_b_amount = (fixed_point64::multiply_u128((pool_coin_b_amount as u128), ratio) as u64);

        let coin_a = coin::extract(&mut pool.coin_a, coin_a_amount);
        let coin_b = coin::extract(&mut pool.coin_b, coin_b_amount);
        let coin_lp = coin::withdraw<CoinLP>(account, coin_lp_amount);

        coin::deposit(signer::address_of(account), coin_a);
        coin::deposit(signer::address_of(account), coin_b);

        let coin_caps = borrow_global<CoinCapabilityStore<CoinLP>>(signer::address_of(account));
        coin::burn(coin_lp, &coin_caps.burn_cap);
    }

    public entry fun swap<CoinA, CoinB, CoinLP>(
        account: &signer,
        offer_coin_type: string::String,
        offer_amount: u64,
        min_return_amount: u64,
    ) acquires Pool {
        let coin_a_type = type_info::type_name<CoinA>();
        let coin_b_type = type_info::type_name<CoinB>();
        
        let pool_addr = pool_address<CoinLP>();
        let pool = borrow_global_mut<Pool<CoinA, CoinB, CoinLP>>(pool_addr);
        let pool_coin_a_amount = coin::value(&pool.coin_a);
        let pool_coin_b_amount = coin::value(&pool.coin_b);

        let (offer_pool_amount, ask_pool_amount) = if (string::bytes(&coin_a_type) == string::bytes(&offer_coin_type)) {
            (pool_coin_a_amount, pool_coin_b_amount)
        } else if (string::bytes(&coin_b_type) == string::bytes(&offer_coin_type)) {
            (pool_coin_b_amount, pool_coin_a_amount)
        } else {
            abort EINVALID_COIN_TYPE
        };

        // x * y = k
        // (x + x') * (y - y') = k
        // return_amount = y' = y - (x * y) / (x + x')
        let return_amount = ask_pool_amount - (
            (
                (offer_pool_amount as u128) * (ask_pool_amount as u128)
            ) / (
                (offer_pool_amount as u128) + (offer_amount as u128)
            ) as u64
        );

        // check minimum return amount
        assert!(return_amount > min_return_amount, EMINIMUM_AMOUNT);

        let return_coin = coin::extract(&mut pool.coin_b, return_amount);
        coin::deposit(signer::address_of(account), return_coin);

        let offer_coin = coin::withdraw(account, offer_amount);
        coin::merge(&mut pool.coin_a, offer_coin);
    }

    //
    // Tests
    //

    #[test_only]
    use aptos_framework::aggregator_factory;

    #[test_only]
    use aptos_framework::account;

    #[test_only]
    struct TokenA {}

    #[test_only]
    struct TokenB {}

    #[test_only]
    struct TokenLP {}

    #[test_only]
    struct TestCapabilities<phantom CoinType> has key {
        burn_cap: coin::BurnCapability<CoinType>,
        freeze_cap: coin::FreezeCapability<CoinType>,
        mint_cap: coin::MintCapability<CoinType>,
    }

    #[test_only]
    fun setup_test(
        chain: &signer,
        account: &signer,
    ) {
        aggregator_factory::initialize_aggregator_factory_for_test(chain);
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<TokenA>(
            account,
            string::utf8(b"TokenA"),
            string::utf8(b"TOKENA"),
            8,
            true,
        );
        let token_a = coin::mint<TokenA>(10000000000, &mint_cap);
        move_to<TestCapabilities<TokenA>>(account, TestCapabilities<TokenA> {
            burn_cap,
            freeze_cap,
            mint_cap,
        });

        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<TokenB>(
            account,
            string::utf8(b"TokenB"),
            string::utf8(b"TOKENB"),
            8,
            true,
        );
        let token_b = coin::mint<TokenB>(10000000000, &mint_cap);
        move_to<TestCapabilities<TokenB>>(account, TestCapabilities<TokenB> {
            burn_cap,
            freeze_cap,
            mint_cap,
        });

        coin::register<TokenA>(account);
        coin::register<TokenB>(account);

        coin::deposit(signer::address_of(account), token_a);
        coin::deposit(signer::address_of(account), token_b);
    }

    #[test(chain = @aptos_framework, creator = @token_swap, trader = @0x222)]
    public fun test_e2e(chain: &signer, creator: &signer, trader: &signer) acquires CoinCapabilityStore, Pool {
        let creator_addr = signer::address_of(creator);
        account::create_account_for_test(creator_addr);
        let trader_addr = signer::address_of(trader);
        account::create_account_for_test(trader_addr);
        
        setup_test(chain, creator);

        initialize_pool<TokenA, TokenB, TokenLP>(
            creator,
            100000000,
            200000000,
        );

        let pool = borrow_global<Pool<TokenA, TokenB, TokenLP>>(creator_addr);
        assert!(coin::value(&pool.coin_a) == 100000000, 1);
        assert!(coin::value(&pool.coin_b) == 200000000, 2);

        // coin::register<TokenA>(trader);
        // coin::register<TokenB>(trader);

        // coin::deposit<TokenA>(trader_addr, coin::withdraw<TokenA>(creator, 100000000));
        // coin::deposit<TokenB>(trader_addr, coin::withdraw<TokenB>(creator, 200000000));

        provide_liquidty<TokenA, TokenB, TokenLP>(
            creator,
            100000000,
            200000000,
            0,
        );

        let pool = borrow_global<Pool<TokenA, TokenB, TokenLP>>(creator_addr);
        assert!(coin::value(&pool.coin_a) == 200000000, 1);
        assert!(coin::value(&pool.coin_b) == 400000000, 2);
    }
}