// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;


import {Test, console} from "forge-std/Test.sol";

// Core accounts
import {PortfolioManager} from "../../../src/accounts/PortfolioManager.sol";
import {PortfolioFactory} from "../../../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../../../src/accounts/FacetRegistry.sol";

// Config
import {PortfolioFactoryConfig} from "../../../src/facets/account/config/PortfolioFactoryConfig.sol";
import {NFTPortfolioFactoryConfig} from "../../../src/facets/account/config/NFTPortfolioFactoryConfig.sol";
import {VotingConfig} from "../../../src/facets/account/config/VotingConfig.sol";
import {LoanConfig} from "../../../src/facets/account/config/LoanConfig.sol";
import {SwapConfig} from "../../../src/facets/account/config/SwapConfig.sol";

// Facets
import {ClaimingFacet} from "../../../src/facets/account/claim/ClaimingFacet.sol";
import {CollateralFacet} from "../../../src/facets/account/collateral/CollateralFacet.sol";
import {BaseCollateralFacet} from "../../../src/facets/account/collateral/BaseCollateralFacet.sol";
import {LendingFacet} from "../../../src/facets/account/lending/LendingFacet.sol";
import {BaseLendingFacet} from "../../../src/facets/account/lending/BaseLendingFacet.sol";
import {VotingFacet} from "../../../src/facets/account/vote/VotingFacet.sol";
import {VotingEscrowFacet} from "../../../src/facets/account/votingEscrow/VotingEscrowFacet.sol";
import {MigrationFacet} from "../../../src/facets/account/migration/MigrationFacet.sol";
import {IMigrationFacet} from "../../../src/facets/account/migration/IMigrationFacet.sol";
import {MarketplaceFacet} from "../../../src/facets/account/marketplace/MarketplaceFacet.sol";
import {BaseMarketplaceFacet} from "../../../src/facets/account/marketplace/BaseMarketplaceFacet.sol";
import {PortfolioMarketplace} from "../../../src/facets/marketplace/PortfolioMarketplace.sol";
import {RewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/RewardsProcessingFacet.sol";
import {RewardsConfigFacet} from "../../../src/facets/account/rewards_processing/RewardsConfigFacet.sol";
import {VotingEscrowRewardsProcessingFacet} from "../../../src/facets/account/rewards_processing/VotingEscrowRewardsProcessingFacet.sol";

// Loan / Vault
import {Loan} from "../../../src/Loan.sol";
import {Loan as LoanV2} from "../../../src/LoanV2.sol";
import {Vault} from "../../../src/VaultV2.sol";
import {ILoan} from "../../../src/interfaces/ILoan.sol";

// Interfaces
import {IVotingEscrow} from "../../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../../src/interfaces/IVoter.sol";
import {IRewardsDistributor} from "../../../src/interfaces/IRewardsDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Mocks
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockVotingEscrow} from "../../mocks/MockVotingEscrow.sol";
import {MockVoter} from "../../mocks/MockVoter.sol";
import {MockRewardsDistributor} from "../../mocks/MockRewardsDistributor.sol";

// LocalSetup (we override _deployConfigs to use NFTPortfolioFactoryConfig)
import {LocalSetup} from "../utils/LocalSetup.sol";


/**
 * @title NFTPortfolioFactoryConfigTest
 * @dev Tests for NFTPortfolioFactoryConfig's collateral tracking hooks
 *      and view functions. Overrides LocalSetup._deployConfigs() to deploy
 *      the Aerodrome variant instead of the base PortfolioFactoryConfig.
 */
contract NFTPortfolioFactoryConfigTest is Test, LocalSetup {

    NFTPortfolioFactoryConfig public _aeroConfig;

    // Second user for multi-portfolio tests
    address public _user2 = address(0x50ac2e);
    address public _portfolioAccount2;
    uint256 public _user2TokenId;

    // ──────────────────────────────────────────────
    // Override _deployConfigs to use NFTPortfolioFactoryConfig
    // ──────────────────────────────────────────────

    function _deployConfigs() internal override {
        vm.startPrank(FORTY_ACRES_DEPLOYER);

        // Deploy NFTPortfolioFactoryConfig as the portfolioFactoryConfig
        NFTPortfolioFactoryConfig configImpl = new NFTPortfolioFactoryConfig();
        _aeroConfig = NFTPortfolioFactoryConfig(
            address(new ERC1967Proxy(
                address(configImpl),
                abi.encodeCall(PortfolioFactoryConfig.initialize, (FORTY_ACRES_DEPLOYER, address(_portfolioFactory)))
            ))
        );
        // Assign to parent's _portfolioFactoryConfig so the rest of setup uses it
        _portfolioFactoryConfig = PortfolioFactoryConfig(address(_aeroConfig));

        VotingConfig votingConfigImpl = new VotingConfig();
        _votingConfig = VotingConfig(
            address(new ERC1967Proxy(
                address(votingConfigImpl),
                abi.encodeCall(VotingConfig.initialize, (FORTY_ACRES_DEPLOYER))
            ))
        );

        LoanConfig loanConfigImpl = new LoanConfig();
        _loanConfig = LoanConfig(
            address(new ERC1967Proxy(
                address(loanConfigImpl),
                abi.encodeCall(LoanConfig.initialize, (FORTY_ACRES_DEPLOYER))
            ))
        );

        SwapConfig swapConfigImpl = new SwapConfig();
        _swapConfig = SwapConfig(
            address(new ERC1967Proxy(
                address(swapConfigImpl),
                abi.encodeCall(SwapConfig.initialize, (FORTY_ACRES_DEPLOYER))
            ))
        );

        _portfolioFactoryConfig.setVoteConfig(address(_votingConfig));
        _portfolioFactoryConfig.setLoanConfig(address(_loanConfig));

        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    /// @dev Add collateral via PortfolioManager.multicall (user1)
    function addCollateralViaMulticall(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /// @dev Remove collateral via PortfolioManager.multicall (user1)
    function removeCollateralViaMulticall(uint256 tokenId) internal {
        vm.startPrank(_user);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /// @dev Add collateral for user2 via PortfolioManager.multicall
    function addCollateralViaMulticallUser2(uint256 tokenId) internal {
        vm.startPrank(_user2);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseCollateralFacet.addCollateral.selector, tokenId);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /// @dev Remove collateral for user2 via PortfolioManager.multicall
    function removeCollateralViaMulticallUser2(uint256 tokenId) internal {
        vm.startPrank(_user2);
        address[] memory factories = new address[](1);
        factories[0] = address(_portfolioFactory);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSelector(BaseCollateralFacet.removeCollateral.selector, tokenId);
        _portfolioManager.multicall(calldatas, factories);
        vm.stopPrank();
    }

    /// @dev Create a second user portfolio and a veNFT for them
    function _setupUser2() internal {
        _portfolioAccount2 = _portfolioFactory.createAccount(_user2);
        // Mint veNFT for user2 and transfer to their portfolio
        _user2TokenId = _mockVe.mintTo(_user2, int128(uint128(3000e18)));
    }

    // ════════════════════════════════════════════════════════════════════
    //  ACCESS CONTROL TESTS
    // ════════════════════════════════════════════════════════════════════

    /// @dev onCollateralAdded reverts when called by a non-portfolio address
    function test_onCollateralAdded_revertsWhenCallerIsNotPortfolio() public {
        address randomCaller = address(0xBAD);
        vm.prank(randomCaller);
        vm.expectRevert(abi.encodeWithSelector(NFTPortfolioFactoryConfig.NotPortfolio.selector, randomCaller));
        _aeroConfig.onCollateralAdded(address(_ve), 1);
    }

    /// @dev onCollateralRemoved reverts when called by a non-portfolio address
    function test_onCollateralRemoved_revertsWhenCallerIsNotPortfolio() public {
        address randomCaller = address(0xBAD);
        vm.prank(randomCaller);
        vm.expectRevert(abi.encodeWithSelector(NFTPortfolioFactoryConfig.NotPortfolio.selector, randomCaller));
        _aeroConfig.onCollateralRemoved(address(_ve), 1);
    }

    /// @dev Even the owner cannot call the hooks directly
    function test_onCollateralAdded_revertsWhenCallerIsOwner() public {
        vm.prank(FORTY_ACRES_DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(NFTPortfolioFactoryConfig.NotPortfolio.selector, FORTY_ACRES_DEPLOYER));
        _aeroConfig.onCollateralAdded(address(_ve), 1);
    }

    /// @dev The portfolio owner (user) cannot call the hooks directly either
    function test_onCollateralAdded_revertsWhenCallerIsPortfolioOwner() public {
        vm.prank(_user);
        vm.expectRevert(abi.encodeWithSelector(NFTPortfolioFactoryConfig.NotPortfolio.selector, _user));
        _aeroConfig.onCollateralAdded(address(_ve), 1);
    }

    /// @dev The hooks should succeed when called from a valid portfolio address
    function test_onCollateralAdded_succeedsFromPortfolioAccount() public {
        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 42);

        // Verify the token was tracked
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 42), "Portfolio should have token 42");
        assertTrue(_aeroConfig.factoryHasToken(address(_ve),42), "Factory should have token 42");
    }

    /// @dev onCollateralRemoved should succeed when called from a valid portfolio address
    function test_onCollateralRemoved_succeedsFromPortfolioAccount() public {
        // First add
        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 42);

        // Then remove
        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralRemoved(address(_ve), 42);

        assertFalse(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 42), "Portfolio should not have token 42");
        assertFalse(_aeroConfig.factoryHasToken(address(_ve),42), "Factory should not have token 42");
    }

    // ════════════════════════════════════════════════════════════════════
    //  onCollateralAdded: BASIC FUNCTIONALITY
    // ════════════════════════════════════════════════════════════════════

    /// @dev Adding a single token updates both portfolio and factory sets
    function test_onCollateralAdded_singleToken_updatesAllState() public {
        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 100);

        // Portfolio-level checks
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 1, "Portfolio token count should be 1");
        uint256[] memory tokens = _aeroConfig.getTokensByPortfolio(_portfolioAccount, address(_ve));
        assertEq(tokens.length, 1, "Portfolio tokens array length should be 1");
        assertEq(tokens[0], 100, "Portfolio should contain token 100");
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 100), "hasToken should return true");

        // Factory-level checks
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 1, "Factory token count should be 1");
        uint256[] memory factoryTokens = _aeroConfig.getFactoryTokens(address(_ve));
        assertEq(factoryTokens.length, 1, "Factory tokens array length should be 1");
        assertEq(factoryTokens[0], 100, "Factory should contain token 100");
        assertTrue(_aeroConfig.factoryHasToken(address(_ve),100), "factoryHasToken should return true");
    }

    /// @dev Adding multiple distinct tokens increments counts correctly
    function test_onCollateralAdded_multipleTokens_incrementsCorrectly() public {
        vm.startPrank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 10);
        _aeroConfig.onCollateralAdded(address(_ve), 20);
        _aeroConfig.onCollateralAdded(address(_ve), 30);
        vm.stopPrank();

        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 3, "Portfolio should have 3 tokens");
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 3, "Factory should have 3 tokens");

        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 10), "Should have token 10");
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 20), "Should have token 20");
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 30), "Should have token 30");
        assertTrue(_aeroConfig.factoryHasToken(address(_ve),10), "Factory should have token 10");
        assertTrue(_aeroConfig.factoryHasToken(address(_ve),20), "Factory should have token 20");
        assertTrue(_aeroConfig.factoryHasToken(address(_ve),30), "Factory should have token 30");
    }

    // ════════════════════════════════════════════════════════════════════
    //  IDEMPOTENCY: Adding same token twice
    // ════════════════════════════════════════════════════════════════════

    /// @dev Adding the same token twice to the same portfolio should be idempotent.
    ///      EnumerableSet.add returns false if the element already exists, so
    ///      the factory set add is skipped on duplicate. No double-counting.
    function test_onCollateralAdded_idempotent_samePortfolioSameToken() public {
        vm.startPrank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 42);
        _aeroConfig.onCollateralAdded(address(_ve), 42); // duplicate
        vm.stopPrank();

        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 1, "Portfolio count should still be 1");
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 1, "Factory count should still be 1");
    }

    // ════════════════════════════════════════════════════════════════════
    //  onCollateralRemoved: BASIC FUNCTIONALITY
    // ════════════════════════════════════════════════════════════════════

    /// @dev Removing a token that was added clears both sets
    function test_onCollateralRemoved_clearsState() public {
        vm.startPrank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 55);
        _aeroConfig.onCollateralRemoved(address(_ve), 55);
        vm.stopPrank();

        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 0, "Portfolio count should be 0");
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 0, "Factory count should be 0");
        assertFalse(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 55), "Should not have token 55");
        assertFalse(_aeroConfig.factoryHasToken(address(_ve),55), "Factory should not have token 55");
    }

    /// @dev Removing a token that was never added is a no-op
    ///      EnumerableSet.remove returns false, so factory remove is skipped.
    function test_onCollateralRemoved_noop_whenTokenNeverAdded() public {
        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralRemoved(address(_ve), 999);

        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 0, "Portfolio count should be 0");
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 0, "Factory count should be 0");
    }

    /// @dev Removing the same token twice is a no-op on the second call
    function test_onCollateralRemoved_idempotent_doubleRemove() public {
        vm.startPrank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 77);
        _aeroConfig.onCollateralRemoved(address(_ve), 77);
        _aeroConfig.onCollateralRemoved(address(_ve), 77); // second remove
        vm.stopPrank();

        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 0);
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 0);
    }

    /// @dev Add/remove/add cycle should work correctly (not leave stale state)
    function test_addRemoveAdd_cycle() public {
        vm.startPrank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 88);
        _aeroConfig.onCollateralRemoved(address(_ve), 88);
        _aeroConfig.onCollateralAdded(address(_ve), 88);
        vm.stopPrank();

        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 1, "Should have 1 token after re-add");
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 1, "Factory should have 1 token after re-add");
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 88));
        assertTrue(_aeroConfig.factoryHasToken(address(_ve),88));
    }

    // ════════════════════════════════════════════════════════════════════
    //  MULTI-PORTFOLIO TESTS
    // ════════════════════════════════════════════════════════════════════

    /// @dev Two portfolios adding different tokens: both tracked at factory level
    function test_multiPortfolio_differentTokens_bothTracked() public {
        _setupUser2();

        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 100);

        vm.prank(_portfolioAccount2);
        _aeroConfig.onCollateralAdded(address(_ve), 200);

        // Portfolio-level isolation
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 1);
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount2, address(_ve)), 1);
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 100));
        assertFalse(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 200), "Portfolio1 should not have portfolio2's token");
        assertTrue(_aeroConfig.hasToken(_portfolioAccount2, address(_ve), 200));
        assertFalse(_aeroConfig.hasToken(_portfolioAccount2, address(_ve), 100), "Portfolio2 should not have portfolio1's token");

        // Factory-level aggregation
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 2, "Factory should track 2 tokens total");
        assertTrue(_aeroConfig.factoryHasToken(address(_ve),100));
        assertTrue(_aeroConfig.factoryHasToken(address(_ve),200));
    }

    /// @dev Two portfolios: removing one portfolio's token does not affect the other
    function test_multiPortfolio_removeOneDoesNotAffectOther() public {
        _setupUser2();

        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 100);

        vm.prank(_portfolioAccount2);
        _aeroConfig.onCollateralAdded(address(_ve), 200);

        // Remove portfolio1's token
        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralRemoved(address(_ve), 100);

        // Portfolio1 state cleared
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 0);
        assertFalse(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 100));
        assertFalse(_aeroConfig.factoryHasToken(address(_ve),100), "Factory should no longer have token 100");

        // Portfolio2 unaffected
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount2, address(_ve)), 1);
        assertTrue(_aeroConfig.hasToken(_portfolioAccount2, address(_ve), 200));
        assertTrue(_aeroConfig.factoryHasToken(address(_ve),200));
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 1, "Factory should have 1 token remaining");
    }

    /// @dev BUG: Two portfolios adding the SAME tokenId. When one removes it,
    ///      factoryTokens incorrectly removes it even though the other portfolio
    ///      still has it. This documents a known design limitation.
    ///
    ///      In practice, veNFT IDs are unique (an NFT can only be in one place),
    ///      so this scenario should not occur in production. But the data structure
    ///      does NOT enforce this, so we document the behavior.
    function test_multiPortfolio_sameTokenId_factoryTrackingBug() public {
        _setupUser2();

        // Both portfolios "add" the same token ID (shouldn't happen with real NFTs
        // but the config contract has no such check)
        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 42);

        vm.prank(_portfolioAccount2);
        _aeroConfig.onCollateralAdded(address(_ve), 42);

        // Both portfolios track token 42
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 42));
        assertTrue(_aeroConfig.hasToken(_portfolioAccount2, address(_ve), 42));

        // factoryTokens.add(42) was called twice, but EnumerableSet deduplicates,
        // so factory count is 1
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 1, "Factory should have 1 entry (deduplicated)");

        // Now portfolio1 removes token 42
        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralRemoved(address(_ve), 42);

        // Portfolio1 no longer has it
        assertFalse(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 42));
        // Portfolio2 still has it
        assertTrue(_aeroConfig.hasToken(_portfolioAccount2, address(_ve), 42));

        // BUG: factoryTokens was unconditionally removed when portfolio1 removed it.
        //       Portfolio2 still has the token, but factoryHasToken returns false.
        //       This is the documented design limitation.
        assertFalse(
            _aeroConfig.factoryHasToken(address(_ve),42),
            "BUG: factoryHasToken is false even though portfolio2 still has the token"
        );
        assertEq(
            _aeroConfig.getFactoryTokenCount(address(_ve)),
            0,
            "BUG: factory count is 0 even though portfolio2 still holds the token"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS: EMPTY STATE
    // ════════════════════════════════════════════════════════════════════

    /// @dev All view functions return sensible defaults on empty state
    function test_viewFunctions_emptyState() public view {
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 0);
        assertEq(_aeroConfig.getTokensByPortfolio(_portfolioAccount, address(_ve)).length, 0);
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 0);
        assertEq(_aeroConfig.getFactoryTokens(address(_ve)).length, 0);
        assertFalse(_aeroConfig.factoryHasToken(address(_ve),1));
        assertFalse(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 1));
    }

    /// @dev View functions for a non-existent portfolio return zeros/empty
    function test_viewFunctions_nonExistentPortfolio() public view {
        address nonExistent = address(0xDEAD);
        assertEq(_aeroConfig.getTokenCountByPortfolio(nonExistent, address(_ve)), 0);
        assertEq(_aeroConfig.getTokensByPortfolio(nonExistent, address(_ve)).length, 0);
        assertFalse(_aeroConfig.hasToken(nonExistent, address(_ve), 1));
    }

    // ════════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS: POPULATED STATE
    // ════════════════════════════════════════════════════════════════════

    /// @dev getTokensByPortfolio returns all tokens for the portfolio
    function test_getTokensByPortfolio_returnsAllTokens() public {
        vm.startPrank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 5);
        _aeroConfig.onCollateralAdded(address(_ve), 15);
        _aeroConfig.onCollateralAdded(address(_ve), 25);
        vm.stopPrank();

        uint256[] memory tokens = _aeroConfig.getTokensByPortfolio(_portfolioAccount, address(_ve));
        assertEq(tokens.length, 3);

        // EnumerableSet does not guarantee order, so check containment
        bool has5;
        bool has15;
        bool has25;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == 5) has5 = true;
            if (tokens[i] == 15) has15 = true;
            if (tokens[i] == 25) has25 = true;
        }
        assertTrue(has5, "Should contain token 5");
        assertTrue(has15, "Should contain token 15");
        assertTrue(has25, "Should contain token 25");
    }

    /// @dev getFactoryTokens returns tokens from all portfolios
    function test_getFactoryTokens_aggregatesAcrossPortfolios() public {
        _setupUser2();

        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 1);

        vm.prank(_portfolioAccount2);
        _aeroConfig.onCollateralAdded(address(_ve), 2);

        uint256[] memory factoryTokens = _aeroConfig.getFactoryTokens(address(_ve));
        assertEq(factoryTokens.length, 2);

        bool has1;
        bool has2;
        for (uint256 i = 0; i < factoryTokens.length; i++) {
            if (factoryTokens[i] == 1) has1 = true;
            if (factoryTokens[i] == 2) has2 = true;
        }
        assertTrue(has1, "Factory should contain token 1");
        assertTrue(has2, "Factory should contain token 2");
    }

    /// @dev Verify view state after partial removal
    function test_viewFunctions_afterPartialRemoval() public {
        vm.startPrank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 10);
        _aeroConfig.onCollateralAdded(address(_ve), 20);
        _aeroConfig.onCollateralAdded(address(_ve), 30);
        _aeroConfig.onCollateralRemoved(address(_ve), 20);
        vm.stopPrank();

        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 2);
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 2);

        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 10));
        assertFalse(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 20), "Token 20 should be removed");
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 30));

        assertTrue(_aeroConfig.factoryHasToken(address(_ve),10));
        assertFalse(_aeroConfig.factoryHasToken(address(_ve),20));
        assertTrue(_aeroConfig.factoryHasToken(address(_ve),30));
    }

    // ════════════════════════════════════════════════════════════════════
    //  EDGE CASES: TOKEN ID BOUNDARIES
    // ════════════════════════════════════════════════════════════════════

    /// @dev tokenId 0 is a valid uint256 value: verify it is tracked correctly
    function test_tokenIdZero_trackedCorrectly() public {
        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 0);

        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 0), "Should track tokenId 0");
        assertTrue(_aeroConfig.factoryHasToken(address(_ve),0), "Factory should track tokenId 0");
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 1);

        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralRemoved(address(_ve), 0);

        assertFalse(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 0));
        assertFalse(_aeroConfig.factoryHasToken(address(_ve),0));
    }

    /// @dev type(uint256).max as tokenId: verify no overflow issues
    function test_tokenIdMaxUint256_trackedCorrectly() public {
        uint256 maxId = type(uint256).max;

        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), maxId);

        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), maxId));
        assertTrue(_aeroConfig.factoryHasToken(address(_ve),maxId));
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 1);

        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralRemoved(address(_ve), maxId);

        assertFalse(_aeroConfig.hasToken(_portfolioAccount, address(_ve), maxId));
        assertFalse(_aeroConfig.factoryHasToken(address(_ve),maxId));
    }

    // ════════════════════════════════════════════════════════════════════
    //  INTEGRATION: COLLATERAL ADD/REMOVE VIA FULL MULTICALL FLOW
    // ════════════════════════════════════════════════════════════════════

    /// @dev Adding collateral through the full multicall flow triggers the
    ///      onCollateralAdded hook and updates NFTPortfolioFactoryConfig.
    function test_integration_addCollateral_triggersHook() public {
        // _tokenId is already transferred to _portfolioAccount in setUp
        addCollateralViaMulticall(_tokenId);

        // Verify the hook was called and tracked the token
        assertTrue(
            _aeroConfig.hasToken(_portfolioAccount, address(_ve), _tokenId),
            "Token should be tracked after addCollateral"
        );
        assertTrue(
            _aeroConfig.factoryHasToken(address(_ve),_tokenId),
            "Factory should track token after addCollateral"
        );
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 1);
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 1);
    }

    /// @dev Removing collateral through the full multicall flow triggers the
    ///      onCollateralRemoved hook and clears tracking.
    function test_integration_removeCollateral_triggersHook() public {
        addCollateralViaMulticall(_tokenId);

        // Verify tracked before removal
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), _tokenId));

        removeCollateralViaMulticall(_tokenId);

        // Verify cleared after removal
        assertFalse(
            _aeroConfig.hasToken(_portfolioAccount, address(_ve), _tokenId),
            "Token should be untracked after removeCollateral"
        );
        assertFalse(
            _aeroConfig.factoryHasToken(address(_ve),_tokenId),
            "Factory should not track token after removeCollateral"
        );
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 0);
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 0);
    }

    /// @dev Full add/remove cycle with multiple tokens via multicall
    function test_integration_multiToken_addRemoveCycle() public {
        // _tokenId is in portfolio account; transfer _tokenId2 there too
        vm.prank(_tokenId2Owner);
        _mockVe.transferFrom(_tokenId2Owner, _portfolioAccount, _tokenId2);

        addCollateralViaMulticall(_tokenId);
        addCollateralViaMulticall(_tokenId2);

        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 2);
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 2);
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), _tokenId));
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), _tokenId2));

        // Remove just one
        removeCollateralViaMulticall(_tokenId2);

        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 1);
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 1);
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), _tokenId));
        assertFalse(_aeroConfig.hasToken(_portfolioAccount, address(_ve), _tokenId2));
    }

    /// @dev Integration: Two different users each add collateral; verify
    ///      factory-level view aggregates both.
    function test_integration_multiUser_factoryAggregation() public {
        _setupUser2();

        // Transfer user2's token to their portfolio
        vm.prank(_user2);
        _mockVe.transferFrom(_user2, _portfolioAccount2, _user2TokenId);

        // User1 adds collateral
        addCollateralViaMulticall(_tokenId);

        // User2 adds collateral
        addCollateralViaMulticallUser2(_user2TokenId);

        // Factory tracks both
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 2);
        assertTrue(_aeroConfig.factoryHasToken(address(_ve),_tokenId));
        assertTrue(_aeroConfig.factoryHasToken(address(_ve),_user2TokenId));

        // Portfolio-level isolation
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 1);
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount2, address(_ve)), 1);
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), _tokenId));
        assertFalse(_aeroConfig.hasToken(_portfolioAccount, address(_ve), _user2TokenId));
        assertTrue(_aeroConfig.hasToken(_portfolioAccount2, address(_ve), _user2TokenId));
        assertFalse(_aeroConfig.hasToken(_portfolioAccount2, address(_ve), _tokenId));
    }

    // ════════════════════════════════════════════════════════════════════
    //  INTEGRATION: addCollateral twice (idempotency through full flow)
    // ════════════════════════════════════════════════════════════════════

    /// @dev addCollateral called twice with the same token should not double-count
    ///      in the tracker. CollateralManager.addLockedCollateral returns early
    ///      if token is already registered, so the hook is NOT called a second time.
    function test_integration_addCollateralTwice_noDoubleCount() public {
        addCollateralViaMulticall(_tokenId);
        addCollateralViaMulticall(_tokenId);

        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 1, "Should not double-count");
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 1, "Factory should not double-count");
    }

    // ════════════════════════════════════════════════════════════════════
    //  STORAGE ISOLATION: Verify UUPS proxy storage is correct
    // ════════════════════════════════════════════════════════════════════

    /// @dev Verify that the portfolioFactory is correctly stored and readable
    function test_storageIsolation_factoryIsSet() public view {
        assertEq(
            _aeroConfig.getPortfolioFactory(),
            address(_portfolioFactory),
            "Factory should be set from initialize"
        );
    }

    /// @dev Verify that the parent config settings (loanContract, loanConfig, etc.)
    ///      are accessible through the Aerodrome variant
    function test_storageIsolation_parentConfigAccessible() public view {
        assertEq(address(_aeroConfig.getLoanConfig()), address(_loanConfig));
        assertEq(_aeroConfig.getVoteConfig(), address(_votingConfig));
        assertEq(_aeroConfig.getLoanContract(), _loanContract);
    }

    // ════════════════════════════════════════════════════════════════════
    //  FUZZ TESTS
    // ════════════════════════════════════════════════════════════════════

    /// @dev Fuzz: Adding any tokenId from a valid portfolio should be tracked
    function testFuzz_onCollateralAdded_anyTokenId(uint256 tokenId) public {
        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), tokenId);

        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), tokenId));
        assertTrue(_aeroConfig.factoryHasToken(address(_ve),tokenId));
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 1);
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 1);
    }

    /// @dev Fuzz: Add then remove any tokenId should leave clean state
    function testFuzz_addThenRemove_cleanState(uint256 tokenId) public {
        vm.startPrank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), tokenId);
        _aeroConfig.onCollateralRemoved(address(_ve), tokenId);
        vm.stopPrank();

        assertFalse(_aeroConfig.hasToken(_portfolioAccount, address(_ve), tokenId));
        assertFalse(_aeroConfig.factoryHasToken(address(_ve),tokenId));
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 0);
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 0);
    }

    /// @dev Fuzz: Multiple distinct tokens should all be tracked
    function testFuzz_multipleDistinctTokens(uint256 id1, uint256 id2, uint256 id3) public {
        // Ensure distinct
        vm.assume(id1 != id2 && id2 != id3 && id1 != id3);

        vm.startPrank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), id1);
        _aeroConfig.onCollateralAdded(address(_ve), id2);
        _aeroConfig.onCollateralAdded(address(_ve), id3);
        vm.stopPrank();

        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 3);
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 3);
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), id1));
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), id2));
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), id3));
    }

    /// @dev Fuzz: Non-portfolio callers always revert
    function testFuzz_accessControl_nonPortfolioReverts(address caller, uint256 tokenId) public {
        // Ensure caller is not a registered portfolio
        vm.assume(caller != _portfolioAccount);
        vm.assume(_portfolioFactory.owners(caller) == address(0));

        vm.prank(caller);
        vm.expectRevert();
        _aeroConfig.onCollateralAdded(address(_ve), tokenId);
    }

    // ════════════════════════════════════════════════════════════════════
    //  MANY TOKENS: gas and correctness for larger sets
    // ════════════════════════════════════════════════════════════════════

    /// @dev Adding and retrieving 10 tokens: verifies scaling behavior
    function test_manyTokens_addAndRetrieve() public {
        vm.startPrank(_portfolioAccount);
        for (uint256 i = 1; i <= 10; i++) {
            _aeroConfig.onCollateralAdded(address(_ve), i);
        }
        vm.stopPrank();

        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 10);
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 10);

        uint256[] memory tokens = _aeroConfig.getTokensByPortfolio(_portfolioAccount, address(_ve));
        assertEq(tokens.length, 10);

        uint256[] memory factoryTokens = _aeroConfig.getFactoryTokens(address(_ve));
        assertEq(factoryTokens.length, 10);

        // Verify all tokens present
        for (uint256 i = 1; i <= 10; i++) {
            assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), i), "Missing portfolio token");
            assertTrue(_aeroConfig.factoryHasToken(address(_ve),i), "Missing factory token");
        }
    }

    /// @dev Remove all tokens one by one, verifying counts decrease
    function test_manyTokens_removeAll() public {
        vm.startPrank(_portfolioAccount);
        for (uint256 i = 1; i <= 5; i++) {
            _aeroConfig.onCollateralAdded(address(_ve), i);
        }
        for (uint256 i = 1; i <= 5; i++) {
            _aeroConfig.onCollateralRemoved(address(_ve), i);
        }
        vm.stopPrank();

        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 0);
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 0);
        assertEq(_aeroConfig.getTokensByPortfolio(_portfolioAccount, address(_ve)).length, 0);
        assertEq(_aeroConfig.getFactoryTokens(address(_ve)).length, 0);
    }

    // ════════════════════════════════════════════════════════════════════
    //  CROSS-PORTFOLIO VIEW ISOLATION
    // ════════════════════════════════════════════════════════════════════

    /// @dev Portfolio tokens are isolated: querying one portfolio does not
    ///      return the other's tokens.
    function test_crossPortfolio_viewIsolation() public {
        _setupUser2();

        vm.prank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 111);

        vm.prank(_portfolioAccount2);
        _aeroConfig.onCollateralAdded(address(_ve), 222);

        uint256[] memory p1Tokens = _aeroConfig.getTokensByPortfolio(_portfolioAccount, address(_ve));
        uint256[] memory p2Tokens = _aeroConfig.getTokensByPortfolio(_portfolioAccount2, address(_ve));

        assertEq(p1Tokens.length, 1);
        assertEq(p1Tokens[0], 111);
        assertEq(p2Tokens.length, 1);
        assertEq(p2Tokens[0], 222);
    }

    // ════════════════════════════════════════════════════════════════════
    //  ADDRESS PARAMETER: Verify the ignored `address` parameter
    // ════════════════════════════════════════════════════════════════════

    /// @dev The first parameter (address) scopes tracking by asset.
    ///      Tokens added under different assets are tracked independently.
    function test_addressParameter_scopesTracking() public {
        address asset2 = address(0xBEEF);
        vm.startPrank(_portfolioAccount);
        _aeroConfig.onCollateralAdded(address(_ve), 1);
        _aeroConfig.onCollateralAdded(asset2, 2);
        _aeroConfig.onCollateralAdded(address(_ve), 3);
        vm.stopPrank();

        // VE asset: tokens 1 and 3
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, address(_ve)), 2);
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 1));
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 3));
        assertFalse(_aeroConfig.hasToken(_portfolioAccount, address(_ve), 2));

        // asset2: token 2 only
        assertEq(_aeroConfig.getTokenCountByPortfolio(_portfolioAccount, asset2), 1);
        assertTrue(_aeroConfig.hasToken(_portfolioAccount, asset2, 2));

        // Factory-level also scoped
        assertEq(_aeroConfig.getFactoryTokenCount(address(_ve)), 2);
        assertEq(_aeroConfig.getFactoryTokenCount(asset2), 1);
    }
}
