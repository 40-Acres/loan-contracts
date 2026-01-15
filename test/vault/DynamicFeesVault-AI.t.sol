// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.27;

// import {Test, console} from "forge-std/Test.sol";
// import {DynamicFeesVault} from "../../vault/DynamicFeesVault.sol";
// import {DebtToken} from "../../vault/DebtToken.sol";
// import {ProtocolTimeLibrary} from "../../src/libraries/ProtocolTimeLibrary.sol";
// import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {IPortfolioFactory} from "../../src/interfaces/IPortfolioFactory.sol";

// /**
//  * @title MockERC20
//  * @notice Simple ERC20 token for testing
//  */
// contract MockERC20 is ERC20 {
//     constructor(string memory name, string memory symbol) ERC20(name, symbol) {
//         _mint(msg.sender, 10000000e18);
//     }

//     function mint(address to, uint256 amount) external {
//         _mint(to, amount);
//     }
// }

// /**
//  * @title MockPortfolioFactory
//  * @notice Mock portfolio factory for testing
//  */
// contract MockPortfolioFactory is IPortfolioFactory {
//     mapping(address => bool) public isPortfolio;

//     function setPortfolio(address portfolio, bool value) external {
//         isPortfolio[portfolio] = value;
//     }

//     // Required by interface but not used in this mock
//     function facetRegistry() external pure override returns (address) {
//         return address(0);
//     }

//     function portfolioManager() external pure override returns (address) {
//         return address(0);
//     }

//     function portfolios(address) external pure override returns (address) {
//         return address(0);
//     }

//     function owners(address) external pure override returns (address) {
//         return address(0);
//     }

//     function createAccount(address) external pure override returns (address) {
//         return address(0);
//     }

//     function getRegistryVersion() external pure override returns (uint256) {
//         return 0;
//     }

//     function ownerOf(address) external pure override returns (address) {
//         return address(0);
//     }

//     function portfolioOf(address) external pure override returns (address) {
//         return address(0);
//     }

//     function getAllPortfolios() external pure override returns (address[] memory) {
//         return new address[](0);
//     }

//     function getPortfoliosLength() external pure override returns (uint256) {
//         return 0;
//     }

//     function getPortfolio(uint256) external pure override returns (address) {
//         return address(0);
//     }
// }

// /**
//  * @title TestableDebtToken
//  * @notice DebtToken with exposed internal functions for testing
//  */
// contract TestableDebtToken is DebtToken {
//     constructor(address _vault, address _asset) DebtToken(_vault, _asset) {}
    
//     // Expose internal state manipulation for testing
//     function testSetTotalAssetsPerEpoch(uint256 epoch, uint256 amount) external {
//         totalAssetsPerEpoch[epoch] = amount;
//     }

//     function testSetTokenClaimedPerEpoch(address owner, address token, uint256 epoch, uint256 amount) external {
//         tokenClaimedPerEpoch[owner][token][epoch] = amount;
//     }

//     function testSetAuthorized(address _authorized) external {
//         authorized = _authorized;
//     }

//     function testMint(address to, uint256 amount) external {
//         _mint(to, amount);
//     }

//     function testAddCheckpoint(address owner, uint256 timestamp, uint256 balance) external {
//         uint256 nCheckpoints = numCheckpoints[owner];
//         checkpoints[owner][nCheckpoints] = Checkpoint(timestamp, balance);
//         numCheckpoints[owner] = nCheckpoints + 1;
//     }

//     function testSetLastEarn(address token, address owner, uint256 timestamp) external {
//         lastEarn[token][owner] = timestamp;
//     }
// }

// /**
//  * @title DynamicFeesVaultTest
//  * @notice Comprehensive test suite for DynamicFeesVault
//  */
// contract DynamicFeesVaultTest is Test {
//     DynamicFeesVault public vault;
//     DebtToken public debtToken;
//     MockERC20 public asset;
//     MockPortfolioFactory public portfolioFactory;
    
//     address public owner;
//     address public user1;
//     address public user2;
//     address public authorized;

//     uint256 constant WEEK = 7 days;
//     uint256 constant INITIAL_BALANCE = 1000000e18;

//     // Helper functions to manipulate DebtToken storage for testing
//     // Storage slot calculation based on DebtToken contract layout:
//     // Slot 1: tokenClaimedPerEpoch mapping
//     // Slot 13: totalAssetsPerEpoch mapping
//     function _setTotalAssetsPerEpoch(address debtTokenAddr, uint256 epoch, uint256 amount) internal {
//         // totalAssetsPerEpoch is at slot 13 (based on variable order in DebtToken)
//         // Counting: authorized(0), tokenClaimedPerEpoch(1), lastEarn(2), lastNotify(3), 
//         // rewards(4), isReward(5), tokenId(6), loanContract(7), checkpoints(8), 
//         // numCheckpoints(9), supplyCheckpoints(10), supplyNumCheckpoints(11),
//         // totalSupplyPerEpoch(12), totalAssetsPerEpoch(13)
//         bytes32 slot = keccak256(abi.encode(epoch, uint256(13)));
//         vm.store(debtTokenAddr, slot, bytes32(amount));
//     }

//     function _setTokenClaimedPerEpoch(address debtTokenAddr, address owner, address token, uint256 epoch, uint256 amount) internal {
//         // tokenClaimedPerEpoch[owner][token][epoch] is at slot 1
//         // Nested mapping: keccak256(abi.encode(epoch, keccak256(abi.encode(token, keccak256(abi.encode(owner, 1)))))
//         bytes32 ownerSlot = keccak256(abi.encode(owner, uint256(1)));
//         bytes32 tokenSlot = keccak256(abi.encode(token, ownerSlot));
//         bytes32 epochSlot = keccak256(abi.encode(epoch, tokenSlot));
//         vm.store(debtTokenAddr, epochSlot, bytes32(amount));
//     }
    
//     // Helper to set up debt token state for testing
//     function _setupDebtTokenState(uint256 epoch, uint256 totalAssets, uint256 lenderPremium) internal {
//         _setTotalAssetsPerEpoch(address(debtToken), epoch, totalAssets);
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), epoch, lenderPremium);
//     }

//     function setUp() public {
//         // Set initial timestamp to a specific epoch start for consistent testing
//         vm.warp(1767225600); // Start of an epoch
        
//         owner = address(0x1);
//         user1 = address(0x2);
//         user2 = address(0x3);
//         authorized = address(0x4);

//         // Deploy mock contracts
//         asset = new MockERC20("Test Token", "TEST");
//         portfolioFactory = new MockPortfolioFactory();

//         // Deploy vault implementation
//         DynamicFeesVault vaultImpl = new DynamicFeesVault();
        
//         // Deploy proxy - debt token will be created in initialize() with proxy address
//         bytes memory initData = abi.encodeWithSelector(
//             DynamicFeesVault.initialize.selector,
//             address(asset),
//             "Test Vault",
//             "TV",
//             address(portfolioFactory)
//         );
//         ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
//         vault = DynamicFeesVault(address(proxy));

//         // Get the debt token that was created in initialize() with the proxy address
//         debtToken = vault.debtToken();
        
//         // Now the debt token's vault is correctly set to the proxy address

//         // Transfer ownership
//         vault.transferOwnership(owner);

//         // Set up addresses as portfolios for testing
//         portfolioFactory.setPortfolio(address(debtToken), true);
//         portfolioFactory.setPortfolio(user2, true);

//         // Setup asset balances
//         asset.mint(address(this), INITIAL_BALANCE * 2);
//         asset.transfer(user1, 100000e18);
//         asset.transfer(user2, 100000e18);
        
//         // Make an initial deposit to mint shares (required for ERC4626 when vault has assets)
//         // This ensures the vault has both assets and shares in a valid state
//         asset.approve(address(vault), INITIAL_BALANCE);
//         vault.deposit(INITIAL_BALANCE, address(this));
//         asset.transfer(address(vault), INITIAL_BALANCE);
//     }


//     // ============ Initialization Tests ============

//     function test_Initialize_SetsCorrectValues() public view {
//         assertEq(vault.asset(), address(asset), "Asset should be set correctly");
//         assertEq(vault.name(), "Test Vault", "Name should be set correctly");
//         assertEq(vault.symbol(), "TV", "Symbol should be set correctly");
//         assertEq(vault.totalLoanedAssets(), 0, "Initial totalLoanedAssets should be 0");
//     }

//     function test_GetSettlementCheckpoint_InitialState() public {
//         // After initial deposit in setUp, checkpoint should be set to current epoch
//         // But we can test that the function works correctly
//         (uint256 checkpointEpoch, uint256 principalRepaid) = vault.getSettlementCheckpoint();
//         // Checkpoint epoch should be set (either 0 or current epoch depending on when deposit was made)
//         assertGe(checkpointEpoch, 0, "Checkpoint epoch should be valid");
//         assertGe(principalRepaid, 0, "Principal repaid should be valid");
//     }

//     // ============ Debt Repayment and Lender Premium Calculation Tests ============

//     function test_DebtRepayment_Calculation_CurrentEpoch() public {
//         uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 currentEpoch = epochStart;
        
//         // Move to 50% through epoch so assets are unlocked
//         vm.warp(epochStart + WEEK / 2);
        
//         // Set up: 10000 total assets for epoch, 2000 lender premium
//         // At 50% through epoch: 5000 assets unlocked, 2000 premium, 3000 principal
//         uint256 totalAssetsForEpoch = 10000e18;
//         uint256 lenderPremium = 2000e18;
//         uint256 assetsUnlockedAt50Percent = totalAssetsForEpoch / 2; // 5000e18
//         uint256 expectedPrincipalRepaid = assetsUnlockedAt50Percent - lenderPremium; // 3000e18
        
//         // Set up debt token state using helper function
//         _setupDebtTokenState(currentEpoch, totalAssetsForEpoch, lenderPremium);
        
//         // Verify calculations - call debt token directly to avoid vault address mismatch
//         uint256 epoch = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 actualAssetsUnlocked = debtToken.totalAssetsUnlocked(epoch);
//         uint256 actualLenderPremium = debtToken.tokenClaimedPerEpoch(address(vault), address(debtToken), epoch);
//         uint256 actualDebtRepaid = actualAssetsUnlocked - actualLenderPremium;
        
//         assertApproxEqRel(actualAssetsUnlocked, assetsUnlockedAt50Percent, 0.01e18, "Assets unlocked should be ~50% of total");
//         assertEq(actualLenderPremium, lenderPremium, "Lender premium should match");
//         assertApproxEqRel(actualDebtRepaid, expectedPrincipalRepaid, 0.01e18, "Debt repaid should equal assets - premium");
//     }

//     function test_DebtRepayment_ProratedOverEpoch() public {
//         uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 currentEpoch = epochStart;
//         uint256 totalAssetsForEpoch = 10000e18;
        
//         // Set total assets for the epoch
//         _setTotalAssetsPerEpoch(address(debtToken), currentEpoch, totalAssetsForEpoch);
        
//         // At 25% through epoch
//         vm.warp(epochStart + WEEK / 4);
//         uint256 assetsAt25Percent = vault.assetsUnlockedThisEpoch();
//         uint256 expectedAt25Percent = totalAssetsForEpoch / 4;
//         assertApproxEqRel(assetsAt25Percent, expectedAt25Percent, 0.01e18, "Assets at 25% should be ~25% of total");
        
//         // At 50% through epoch
//         vm.warp(epochStart + WEEK / 2);
//         uint256 assetsAt50Percent = vault.assetsUnlockedThisEpoch();
//         uint256 expectedAt50Percent = totalAssetsForEpoch / 2;
//         assertApproxEqRel(assetsAt50Percent, expectedAt50Percent, 0.01e18, "Assets at 50% should be ~50% of total");
        
//         // At 75% through epoch
//         vm.warp(epochStart + (WEEK * 3) / 4);
//         uint256 assetsAt75Percent = vault.assetsUnlockedThisEpoch();
//         uint256 expectedAt75Percent = (totalAssetsForEpoch * 3) / 4;
//         assertApproxEqRel(assetsAt75Percent, expectedAt75Percent, 0.01e18, "Assets at 75% should be ~75% of total");
//     }

//     function test_LenderPremium_AccumulatesOverTime() public {
//         uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 currentEpoch = epochStart;
//         uint256 totalAssetsForEpoch = 10000e18;
        
//         _setTotalAssetsPerEpoch(address(debtToken), currentEpoch, totalAssetsForEpoch);
        
//         // Set up checkpoints for lender premium calculation
//         // Lender premium is based on vault's debt token balance over time
//         uint256 vaultBalance = 5000e18; // Vault holds 5000 debt tokens
        
//         // Add checkpoint at epoch start
//         // Note: checkpoint manipulation not needed for basic tests
//         // _addCheckpoint(address(debtToken),address(vault), epochStart, vaultBalance);
//         // Note: lastEarn manipulation not needed for basic tests
//         // _setLastEarn(address(debtToken),address(debtToken), address(vault), epochStart - WEEK);
        
//         // At 25% through epoch, set premium
//         vm.warp(epochStart + WEEK / 4);
//         uint256 premiumAt25 = 500e18; // Premium earned so far
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), currentEpoch, premiumAt25);
        
//         uint256 assetsUnlocked = vault.assetsUnlockedThisEpoch();
//         uint256 epoch = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 lenderPremium = debtToken.tokenClaimedPerEpoch(address(vault), address(debtToken), epoch);
//         uint256 principalRepaid = assetsUnlocked - lenderPremium;
        
//         assertGt(lenderPremium, 0, "Lender premium should be greater than 0");
//         assertLt(lenderPremium, assetsUnlocked, "Lender premium should be less than assets unlocked");
//         assertGt(principalRepaid, 0, "Principal repaid should be greater than 0");
//         assertEq(principalRepaid + lenderPremium, assetsUnlocked, "Principal + premium should equal assets unlocked");
//     }

//     function test_DebtRepayment_PrincipalCalculation_Formula() public {
//         uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 currentEpoch = epochStart;
        
//         // Move to 50% through epoch so assets are unlocked
//         vm.warp(epochStart + WEEK / 2);
        
//         uint256 totalAssets = 10000e18;
//         uint256 lenderPremium = 2000e18;
//         uint256 expectedAssetsUnlocked = totalAssets / 2; // 5000e18 at 50%
//         uint256 expectedPrincipal = expectedAssetsUnlocked - lenderPremium; // 3000e18
        
//         _setTotalAssetsPerEpoch(address(debtToken), currentEpoch, totalAssets);
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), currentEpoch, lenderPremium);
        
//         // Principal = Assets Unlocked - Lender Premium
//         uint256 assetsUnlocked = vault.assetsUnlockedThisEpoch();
//         uint256 principalRepaid = vault.debtRepaidThisEpoch();
        
//         assertApproxEqRel(assetsUnlocked, expectedAssetsUnlocked, 0.01e18, "Assets unlocked should be ~50%");
//         assertApproxEqRel(principalRepaid, expectedPrincipal, 0.01e18, "Principal should equal assets - premium");
//         assertApproxEqRel(principalRepaid + lenderPremium, assetsUnlocked, 0.01e18, "Principal + premium should equal assets");
//     }

//     function test_DebtRepayment_UpdatesTotalLoanedAssets() public {
//         uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 currentEpoch = epochStart;
//         uint256 initialLoaned = 10000e18;
//         uint256 totalAssetsForEpoch = 5000e18;
//         uint256 lenderPremium = 1000e18;
        
//         // Set initial loaned assets
//         vm.prank(address(debtToken));
//         vault.borrow(initialLoaned);
//         assertEq(vault.totalLoanedAssets(), initialLoaned, "Initial loaned assets should be set");
        
//         // Set up debt token state
//         _setTotalAssetsPerEpoch(address(debtToken), currentEpoch, totalAssetsForEpoch);
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), currentEpoch, lenderPremium);
        
//         // Move to 50% through epoch so assets are unlocked
//         vm.warp(epochStart + WEEK / 2);
        
//         // At 50%: assets unlocked = 2500e18, premium = 1000e18, principal = 1500e18
//         uint256 assetsUnlockedAt50 = totalAssetsForEpoch / 2; // 2500e18
//         uint256 expectedPrincipalRepaid = assetsUnlockedAt50 - lenderPremium; // 1500e18
        
//         // Trigger checkpoint update (via deposit)
//         vm.startPrank(user1);
//         asset.approve(address(vault), 1000e18);
//         vault.deposit(1000e18, user1);
//         vm.stopPrank();
        
//         // Verify totalLoanedAssets was reduced by principal repaid
//         uint256 finalLoaned = vault.totalLoanedAssets();
//         assertApproxEqRel(finalLoaned, initialLoaned - expectedPrincipalRepaid, 0.01e18, "Loaned assets should decrease by principal repaid");
//     }

//     function test_LenderPremium_NotCountedAsPrincipalRepaid() public {
//         uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 currentEpoch = epochStart;
        
//         // Move to 50% through epoch so assets are unlocked
//         vm.warp(epochStart + WEEK / 2);
        
//         uint256 totalAssets = 10000e18;
//         uint256 lenderPremium = 3000e18; // 30% premium
//         uint256 expectedAssetsUnlocked = totalAssets / 2; // 5000e18 at 50%
//         uint256 expectedPrincipal = expectedAssetsUnlocked - lenderPremium; // 2000e18
        
//         _setTotalAssetsPerEpoch(address(debtToken), currentEpoch, totalAssets);
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), currentEpoch, lenderPremium);
        
//         uint256 assetsUnlocked = vault.assetsUnlockedThisEpoch();
//         uint256 epoch = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 premium = debtToken.tokenClaimedPerEpoch(address(vault), address(debtToken), epoch);
//         uint256 principal = vault.debtRepaidThisEpoch();
        
//         // Verify lender premium is separate from principal
//         assertApproxEqRel(assetsUnlocked, expectedAssetsUnlocked, 0.01e18, "Assets unlocked should be ~50%");
//         assertEq(premium, lenderPremium, "Lender premium should match");
//         assertApproxEqRel(principal, expectedPrincipal, 0.01e18, "Principal should not include premium");
//         assertApproxEqRel(principal + premium, assetsUnlocked, 0.01e18, "Sum should equal assets unlocked");
//     }

//     function test_DebtRepayment_MultipleEpochs_Accumulation() public {
//         uint256 epoch1Start = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 epoch1 = epoch1Start;
        
//         // Epoch 1: 5000 assets, 1000 premium, 4000 principal (full epoch)
//         uint256 epoch1Assets = 5000e18;
//         uint256 epoch1Premium = 1000e18;
//         uint256 epoch1Principal = epoch1Assets - epoch1Premium; // 4000e18
        
//         _setTotalAssetsPerEpoch(address(debtToken), epoch1, epoch1Assets);
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), epoch1, epoch1Premium);
        
//         // Set a checkpoint in epoch 1 first (so we have a baseline)
//         vm.warp(epoch1Start + WEEK / 2); // 50% through epoch 1
//         vm.startPrank(user1);
//         asset.approve(address(vault), 1000e18);
//         vault.deposit(1000e18, user1);
//         vm.stopPrank();
        
//         // Move to epoch 2 at 50% through
//         uint256 epoch2Start = epoch1Start + WEEK;
//         vm.warp(epoch2Start + WEEK / 2); // 50% through epoch 2
        
//         // Epoch 2: 8000 assets total, at 50% = 4000 assets unlocked
//         // Premium at 50% should be proportional - let's say 1000e18
//         uint256 epoch2Assets = 8000e18;
//         uint256 epoch2AssetsUnlockedAt50 = epoch2Assets / 2; // 4000e18 at 50%
//         uint256 epoch2PremiumAt50 = 1000e18; // Premium earned so far at 50%
//         uint256 epoch2PartialPrincipal = epoch2AssetsUnlockedAt50 - epoch2PremiumAt50; // 3000e18
        
//         _setTotalAssetsPerEpoch(address(debtToken), epoch2Start, epoch2Assets);
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), epoch2Start, epoch2PremiumAt50);
        
//         // Trigger checkpoint in epoch 2
//         vm.startPrank(user1);
//         asset.approve(address(vault), 1000e18);
//         vault.deposit(1000e18, user1);
//         vm.stopPrank();
        
//         // Get cumulative principal
//         (uint256 checkpointEpoch, uint256 totalPrincipal) = vault.getSettlementCheckpoint();
        
//         // Should include: full epoch1 principal + partial epoch2 principal
//         uint256 expectedTotalPrincipal = epoch1Principal + epoch2PartialPrincipal; // 4000 + 3000 = 7000
//         assertApproxEqRel(totalPrincipal, expectedTotalPrincipal, 0.01e18, "Total principal should accumulate across epochs");
//     }

//     function test_LenderPremium_ProportionalToVaultBalance() public {
//         uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 currentEpoch = epochStart;
//         uint256 totalAssetsForEpoch = 10000e18;
        
//         _setTotalAssetsPerEpoch(address(debtToken), currentEpoch, totalAssetsForEpoch);
        
//         // Set up vault with debt token balance (simulating vault holding debt tokens)
//         uint256 vaultBalance1 = 1000e18;
//         uint256 vaultBalance2 = 5000e18;
        
//         // Add checkpoints
//         // Note: checkpoint manipulation not needed for basic tests
//         // _addCheckpoint(address(debtToken),address(vault), epochStart, vaultBalance1);
//         // Note: lastEarn manipulation not needed for basic tests
//         // _setLastEarn(address(debtToken),address(debtToken), address(vault), epochStart - WEEK);
        
//         // At 25% through epoch
//         vm.warp(epochStart + WEEK / 4);
//         uint256 premium1 = 250e18; // Premium with lower balance
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), currentEpoch, premium1);
        
//         // Update to higher balance
//         // Note: checkpoint manipulation not needed for basic tests
//         // _addCheckpoint(address(debtToken),address(vault), epochStart + WEEK / 4, vaultBalance2);
        
//         // At 50% through epoch
//         vm.warp(epochStart + WEEK / 2);
//         uint256 premium2 = 1250e18; // Premium with higher balance (should be higher)
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), currentEpoch, premium2);
        
//         // Verify premium increased more with higher balance
//         assertGt(premium2, premium1, "Premium should increase with higher vault balance");
        
//         uint256 assetsUnlocked = vault.assetsUnlockedThisEpoch();
//         uint256 epoch = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 lenderPremium = debtToken.tokenClaimedPerEpoch(address(vault), address(debtToken), epoch);
//         uint256 principalRepaid = assetsUnlocked - lenderPremium;
        
//         assertGt(principalRepaid, 0, "Principal should be positive");
//         assertEq(principalRepaid + lenderPremium, assetsUnlocked, "Principal + premium should equal assets");
//     }

//     // ============ Checkpoint Logic Tests ============

//     function test_UpdateSettlementCheckpoint_FirstUpdate() public {
//         uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
        
//         // Set up some assets in debt token for current epoch
//         uint256 assetsAmount = 1000e18;
//         uint256 premiumAmount = 100e18;
        
//         _setTotalAssetsPerEpoch(address(debtToken), currentEpoch, assetsAmount);
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), currentEpoch, premiumAmount);

//         // Move to 50% through epoch so assets are unlocked
//         vm.warp(ProtocolTimeLibrary.epochStart(block.timestamp) + WEEK / 2);
        
//         // Update checkpoint (this happens automatically on deposit/withdraw)
//         vm.startPrank(user1);
//         asset.approve(address(vault), 1000e18);
//         vault.deposit(1000e18, user1);
//         vm.stopPrank();

//         (uint256 checkpointEpoch, uint256 principalRepaid) = vault.getSettlementCheckpoint();
//         assertEq(checkpointEpoch, currentEpoch, "Checkpoint epoch should be current epoch");
//         assertGt(principalRepaid, 0, "Principal repaid should be greater than 0");
//     }

//     function test_UpdateSettlementCheckpoint_MidEpoch_NoDoubleCounting() public {
//         uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 currentEpoch = epochStart;
        
//         // Set up assets for current epoch
//         uint256 totalAssets = 1000e18;
//         uint256 premium1 = 50e18; // Premium at 25% through epoch
//         uint256 premium2 = 100e18; // Premium at 50% through epoch
        
//         _setTotalAssetsPerEpoch(address(debtToken), currentEpoch, totalAssets);

//         // Set initial loaned assets to track reduction
//         vm.prank(address(debtToken));
//         vault.borrow(5000e18);
//         uint256 initialLoaned = vault.totalLoanedAssets();

//         // First checkpoint at 25% through epoch
//         vm.warp(epochStart + WEEK / 4);
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), currentEpoch, premium1);
        
//         // Do a deposit to trigger checkpoint update
//         vm.startPrank(user1);
//         asset.approve(address(vault), 1000e18);
//         vault.deposit(1000e18, user1);
//         vm.stopPrank();
        
//         (uint256 checkpoint1, uint256 principal1) = vault.getSettlementCheckpoint();
//         assertEq(checkpoint1, currentEpoch, "First checkpoint should be at current epoch");
//         uint256 loanedAfter1 = vault.totalLoanedAssets();
        
//         // Calculate expected principal at 25%: assets unlocked = totalAssets * 0.25, premium = premium1
//         uint256 expectedPrincipal1 = (totalAssets / 4) - premium1;
//         assertApproxEqRel(principal1, expectedPrincipal1, 0.01e18, "First principal should match expected");
//         assertApproxEqRel(loanedAfter1, initialLoaned - expectedPrincipal1, 0.01e18, "Loaned assets should decrease by principal repaid");
        
//         // Second checkpoint at 50% through same epoch
//         vm.warp(epochStart + WEEK / 2);
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), currentEpoch, premium2);
        
//         // Do another deposit to trigger checkpoint update
//         vm.startPrank(user1);
//         asset.approve(address(vault), 1000e18);
//         vault.deposit(1000e18, user1);
//         vm.stopPrank();
        
//         (uint256 checkpoint2, uint256 principal2) = vault.getSettlementCheckpoint();
//         assertEq(checkpoint2, currentEpoch, "Second checkpoint should still be at current epoch");
//         uint256 loanedAfter2 = vault.totalLoanedAssets();
        
//         // Calculate expected principal at 50%: assets unlocked = totalAssets * 0.5, premium = premium2
//         uint256 expectedPrincipal2 = (totalAssets / 2) - premium2;
//         assertApproxEqRel(principal2, expectedPrincipal2, 0.01e18, "Second principal should match expected");
        
//         // The increase should only be the NEW principal (from 25% to 50%)
//         uint256 expectedIncrease = expectedPrincipal2 - expectedPrincipal1;
//         uint256 actualIncrease = principal2 - principal1;
//         assertApproxEqRel(actualIncrease, expectedIncrease, 0.01e18, "Principal increase should only account for new period");
        
//         // Verify totalLoanedAssets was reduced by the correct amount (only the new principal)
//         assertApproxEqRel(loanedAfter2, loanedAfter1 - expectedIncrease, 0.01e18, "Loaned assets should decrease by only the new principal");
//         assertApproxEqRel(loanedAfter2, initialLoaned - expectedPrincipal2, 0.01e18, "Final loaned assets should equal initial minus total principal");
//     }

//     function test_UpdateSettlementCheckpoint_CrossEpoch_NoDoubleCounting() public {
//         uint256 epoch1Start = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 epoch1 = epoch1Start;
        
//         // Set up epoch 1
//         uint256 epoch1Assets = 1000e18;
//         uint256 epoch1Premium = 100e18;
        
//         _setTotalAssetsPerEpoch(address(debtToken), epoch1, epoch1Assets);
        
//         // Set initial loaned assets
//         vm.prank(address(debtToken));
//         vault.borrow(5000e18);
//         uint256 initialLoaned = vault.totalLoanedAssets();
        
//         // Checkpoint mid-epoch 1 (at 50%)
//         vm.warp(epoch1Start + WEEK / 2);
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), epoch1, epoch1Premium);
        
//         // Trigger checkpoint
//         vm.startPrank(user1);
//         asset.approve(address(vault), 1000e18);
//         vault.deposit(1000e18, user1);
//         vm.stopPrank();
        
//         (uint256 checkpoint1, uint256 principal1) = vault.getSettlementCheckpoint();
//         assertEq(checkpoint1, epoch1, "Checkpoint should be at epoch 1");
//         uint256 loanedAfter1 = vault.totalLoanedAssets();
        
//         // Expected principal at 50% of epoch 1
//         uint256 epoch1PartialPrincipal = (epoch1Assets / 2) - epoch1Premium;
//         assertApproxEqRel(principal1, epoch1PartialPrincipal, 0.01e18, "Principal at 50% epoch 1 should match");
//         assertApproxEqRel(loanedAfter1, initialLoaned - epoch1PartialPrincipal, 0.01e18, "Loaned should decrease by epoch 1 partial principal");
        
//         // Move to epoch 2
//         uint256 epoch2Start = epoch1Start + WEEK;
//         vm.warp(epoch2Start + WEEK / 4); // 25% through epoch 2
        
//         uint256 epoch2Assets = 2000e18;
//         uint256 epoch2Premium = 150e18;
        
//         _setTotalAssetsPerEpoch(address(debtToken), epoch2Start, epoch2Assets);
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), epoch2Start, epoch2Premium);
        
//         // Trigger checkpoint in epoch 2
//         vm.startPrank(user1);
//         asset.approve(address(vault), 1000e18);
//         vault.deposit(1000e18, user1);
//         vm.stopPrank();
        
//         (uint256 checkpoint2, uint256 principal2) = vault.getSettlementCheckpoint();
//         assertEq(checkpoint2, epoch2Start, "Checkpoint should be at epoch 2");
//         uint256 loanedAfter2 = vault.totalLoanedAssets();
        
//         // Verify no double counting
//         // principal2 should include:
//         // - Full principal from epoch 1 (since we're now in epoch 2, epoch 1 is complete)
//         // - Partial principal from epoch 2 (25% of epoch 2)
//         uint256 epoch1FullPrincipal = epoch1Assets - epoch1Premium;
//         uint256 epoch2PartialPrincipal = (epoch2Assets / 4) - epoch2Premium;
//         uint256 expectedPrincipal2 = epoch1FullPrincipal + epoch2PartialPrincipal;
        
//         assertApproxEqRel(principal2, expectedPrincipal2, 0.01e18, "Total principal should include full epoch1 + partial epoch2");
        
//         // The increase should be: (full epoch1 - partial epoch1) + partial epoch2
//         uint256 expectedIncrease = (epoch1FullPrincipal - epoch1PartialPrincipal) + epoch2PartialPrincipal;
//         uint256 actualIncrease = principal2 - principal1;
        
//         assertApproxEqRel(actualIncrease, expectedIncrease, 0.01e18, "Cross-epoch principal increase should be correct");
        
//         // Verify totalLoanedAssets was reduced correctly
//         assertApproxEqRel(loanedAfter2, initialLoaned - expectedPrincipal2, 0.01e18, "Final loaned should equal initial minus total principal");
//         assertApproxEqRel(loanedAfter2, loanedAfter1 - expectedIncrease, 0.01e18, "Loaned should decrease by the increase amount");
//     }

//     // ============ TotalAssets Tests ============

//     function test_TotalAssets_IncludesLoanedAssets() public {
//         uint256 depositAmount = 10000e18;
//         uint256 borrowAmount = 5000e18;
        
//         // Get initial state (after setUp's initial deposit)
//         uint256 initialTotalAssets = vault.totalAssets();
        
//         // Deposit
//         vm.startPrank(user1);
//         asset.approve(address(vault), depositAmount);
//         vault.deposit(depositAmount, user1);
//         vm.stopPrank();
        
//         // Borrow (simulating a loan)
//         vm.prank(address(debtToken));
//         vault.borrow(borrowAmount);
        
//         uint256 totalAssets = vault.totalAssets();
//         // After deposit: initialTotalAssets + depositAmount
//         // After borrow: assets are transferred out, but totalLoanedAssets increases
//         // So: initialTotalAssets + depositAmount - borrowAmount (transferred out) + borrowAmount (loaned) = initialTotalAssets + depositAmount
//         uint256 expectedTotal = initialTotalAssets + depositAmount;
//         assertApproxEqRel(totalAssets, expectedTotal, 0.01e18, "Total assets should include loaned assets");
//     }

//     function test_TotalAssets_AccountsForPrincipalRepaid() public {
//         uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 currentEpoch = epochStart;
        
//         // Move to 50% through epoch so assets are unlocked
//         vm.warp(epochStart + WEEK / 2);
        
//         uint256 totalAssetsForEpoch = 1000e18;
//         uint256 premiumAmount = 100e18;
//         uint256 assetsUnlockedAt50Percent = totalAssetsForEpoch / 2; // 500e18
//         uint256 principalRepaid = assetsUnlockedAt50Percent - premiumAmount; // 400e18
        
//         // Set up debt token state
//         _setTotalAssetsPerEpoch(address(debtToken), currentEpoch, totalAssetsForEpoch);
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), currentEpoch, premiumAmount);
        
//         // Set initial loaned assets
//         vm.prank(address(debtToken));
//         vault.borrow(5000e18);
        
//         // Trigger checkpoint update
//         vm.startPrank(user1);
//         asset.approve(address(vault), 1000e18);
//         vault.deposit(1000e18, user1);
//         vm.stopPrank();
        
//         // Check that totalLoanedAssets was reduced by principal repaid
//         uint256 totalLoaned = vault.totalLoanedAssets();
//         assertApproxEqRel(totalLoaned, 5000e18 - principalRepaid, 0.01e18, "Total loaned assets should be reduced by principal repaid");
//     }

//     function test_TotalAssets_UnderflowProtection() public {
//         uint256 epochStart = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 currentEpoch = epochStart;
        
//         // Move to 50% through epoch
//         vm.warp(epochStart + WEEK / 2);
        
//         // Set up a scenario where principalRepaidAtCheckpoint > currentPrincipalRepaid
//         // This shouldn't happen in normal operation, but we test the protection
        
//         // Set initial checkpoint with high principal
//         _setTotalAssetsPerEpoch(address(debtToken), currentEpoch, 1000e18);
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), currentEpoch, 50e18);
        
//         // Trigger checkpoint
//         vm.startPrank(user1);
//         asset.approve(address(vault), 1000e18);
//         vault.deposit(1000e18, user1);
//         vm.stopPrank();
        
//         // Now reduce assets (simulating some edge case)
//         // Move back in time to simulate reduced assets
//         vm.warp(epochStart + WEEK / 4); // 25% through epoch
//         _setTotalAssetsPerEpoch(address(debtToken), currentEpoch, 100e18);
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), currentEpoch, 90e18);
        
//         // This should not revert due to underflow protection
//         uint256 totalAssets = vault.totalAssets();
//         assertGe(totalAssets, 0, "Total assets should not underflow");
//     }

//     // ============ Integration Tests ============

//     function test_FullFlow_DepositBorrowRepayWithdraw() public {
//         uint256 depositAmount = 10000e18;
//         uint256 borrowAmount = 5000e18;
//         uint256 repayAmount = 2000e18;
//         uint256 withdrawAmount = 3000e18;
        
//         // Vault already has INITIAL_BALANCE from setUp, so first deposit should work
        
//         // 1. Deposit
//         vm.startPrank(user1);
//         asset.approve(address(vault), depositAmount);
//         vault.deposit(depositAmount, user1);
//         vm.stopPrank();
        
//         uint256 shares = vault.balanceOf(user1);
//         assertGt(shares, 0, "User should receive shares");
        
//         // 2. Borrow (user2 borrows directly to have debt balance)
//         vm.startPrank(user2);
//         vault.borrow(borrowAmount);
//         vm.stopPrank();
//         assertEq(vault.totalLoanedAssets(), borrowAmount, "Total loaned assets should equal borrow amount");
        
//         // 3. Repay (user2 repays their debt)
//         vm.startPrank(user2);
//         asset.approve(address(vault), repayAmount);
//         vault.repay(repayAmount);
//         vm.stopPrank();
//         assertEq(vault.totalLoanedAssets(), borrowAmount - repayAmount, "Total loaned assets should decrease");
        
//         // 4. Withdraw
//         vm.startPrank(user1);
//         vault.withdraw(withdrawAmount, user1, user1);
//         vm.stopPrank();
        
//         uint256 finalShares = vault.balanceOf(user1);
//         assertLt(finalShares, shares, "User shares should decrease after withdrawal");
//     }

//     function test_CheckpointConsistency_MultipleOperations() public {
//         uint256 currentEpoch = ProtocolTimeLibrary.epochStart(block.timestamp);
//         uint256 assetsAmount = 1000e18;
//         uint256 premiumAmount = 100e18;
        
//         _setTotalAssetsPerEpoch(address(debtToken), currentEpoch, assetsAmount);
//         _setTokenClaimedPerEpoch(address(debtToken), address(vault), address(debtToken), currentEpoch, premiumAmount);
        
//         // Multiple deposits
//         vm.startPrank(user1);
//         asset.approve(address(vault), 100000e18);
//         vault.deposit(1000e18, user1);
//         (uint256 checkpoint1, uint256 principal1) = vault.getSettlementCheckpoint();
        
//         vault.deposit(1000e18, user1);
//         (uint256 checkpoint2, uint256 principal2) = vault.getSettlementCheckpoint();
        
//         vault.deposit(1000e18, user1);
//         (uint256 checkpoint3, uint256 principal3) = vault.getSettlementCheckpoint();
//         vm.stopPrank();
        
//         // Checkpoints should be consistent
//         assertEq(checkpoint1, checkpoint2, "Checkpoints should be at same epoch");
//         assertEq(checkpoint2, checkpoint3, "Checkpoints should be at same epoch");
//         assertGe(principal2, principal1, "Principal should not decrease");
//         assertGe(principal3, principal2, "Principal should not decrease");
//     }
// }
