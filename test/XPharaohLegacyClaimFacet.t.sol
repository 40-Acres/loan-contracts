// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IXLoan} from "src/interfaces/IXLoan.sol";
import {AccountConfigStorage} from "src/storage/AccountConfigStorage.sol";
import {FacetRegistry} from "src/accounts/FacetRegistry.sol";
import {XPharaohLegacyClaimFacet} from "src/facets/account/XPharaohLegacyClaimFacet.sol";
import {XPharaohLoan} from "src/Pharaoh/XPharaohLoan.sol";


contract MockOdosRouterRL {
    address public testContract;

    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    
    function initMock(address _testContract) external { testContract = _testContract; }

    /**
     * @notice Simulates an Odos multi-input swap that consumes all input tokens and outputs USDC
     * @param inputTokens Array of token addresses to consume from msg.sender
     * @param usdcOutput Amount of USDC to mint as output
     */
    function executeSwapMultiInput(
        address[] calldata inputTokens,
        uint256 usdcOutput
    ) external returns (bool) {
        // Pull all input tokens from the caller (simulating Odos consuming them in swap)
        for (uint256 i = 0; i < inputTokens.length; i++) {
            address token = inputTokens[i];
            uint256 balance = IERC20(token).balanceOf(msg.sender);
            if (balance > 0) {
                // Check allowance and transfer
                uint256 allowance = IERC20(token).allowance(msg.sender, address(this));
                if (allowance >= balance) {
                    IERC20(token).transferFrom(msg.sender, address(this), balance);
                }
            }
        }

        // Mint USDC output to the caller
        (bool success,) = testContract.call(
            abi.encodeWithSignature(
                "mintUsdc(address,address,uint256)",
                IUSDC(USDC).masterMinter(),
                msg.sender,
                usdcOutput
            )
        );
        require(success, "mint fail");

        return true;
    }
}

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(
        address minter,
        uint256 minterAllowedAmount
    ) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract XPharaohLegacyClaimFacetForkTest is Test {
    address constant PORTFOLIO = 0xB92DFAeFc24D8d2C7B2c20129A38cAe270D6C190;
    address constant LOAN = 0x6Bf2Fe80D245b06f6900848ec52544FBdE6c8d2C;
    address constant ACCOUNT_CONFIG = 0x17cd3c65daf5b2F806d053D948Ad7d59191fd397;
    address constant FACET_REGISTRY = 0x9bCa68D9c613Dc9B07B2727c28b5ce46204943de;
    address constant ODOS = 0x88de50B233052e4Fb783d4F6db78Cc34fEa3e9FC;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant PHAR = 0x26e9dbe75aed331E41272BEcE932Ff1B48926Ca9;
    address constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address constant P33 = 0x152b9d0FdC40C096757F570A51E494bd4b943E50;
    address constant HEFE = 0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7;

    AccountConfigStorage internal accountConfigStorage;

    function setUp() public {
        uint256 forkId = vm.createFork(vm.envString("AVAX_RPC_URL"));
        vm.selectFork(forkId);

        // Upgrade LOAN proxy to the local implementation that has claimLegacy
        XPharaohLoan newImpl = new XPharaohLoan();
        vm.prank(XPharaohLoan(LOAN).owner());
        XPharaohLoan(LOAN).upgradeToAndCall(address(newImpl), new bytes(0));

        accountConfigStorage = AccountConfigStorage(ACCOUNT_CONFIG);
        address owner = accountConfigStorage.owner();
        vm.prank(owner);
        accountConfigStorage.setApprovedContract(LOAN, true);

        // allow this test contract to mint USDC for the mock router
        vm.prank(IUSDC(USDC).masterMinter());
        IUSDC(USDC).configureMinter(address(this), type(uint256).max);

        // Mock Odos at canonical address with minting behavior
        MockOdosRouterRL mock = new MockOdosRouterRL();
        vm.etch(ODOS, address(mock).code);
        MockOdosRouterRL(ODOS).initMock(address(this));

        // Deploy facet and register its selector in the shared FacetRegistry
        XPharaohLegacyClaimFacet facetImpl =
            new XPharaohLegacyClaimFacet(address(accountConfigStorage));
        FacetRegistry facetRegistry = FacetRegistry(FACET_REGISTRY);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("xPharProcessLegacyRewards(address[],address[][],bytes)"));
        vm.prank(facetRegistry.owner());
        facetRegistry.registerFacet(address(facetImpl), selectors, "XPharaohLegacyClaimFacet");
    }

    function test_claimLegacyRewards_liveFork() public {
        address[] memory feeDistributors = new address[](8);
        feeDistributors[0] = 0xddd26b6df68DAdF5ac7Cde1E8705FFe6263c9743;
        feeDistributors[1] = 0xddd26b6df68DAdF5ac7Cde1E8705FFe6263c9743;
        feeDistributors[2] = 0xEC43cC839D14be8cb319A09f376090Ce18eeBE3E;
        feeDistributors[3] = 0xEC43cC839D14be8cb319A09f376090Ce18eeBE3E;
        feeDistributors[4] = 0x88417CFdc8275131677e557E99D91cF72329Ea54;
        feeDistributors[5] = 0x88417CFdc8275131677e557E99D91cF72329Ea54;
        feeDistributors[6] = 0x8dD18390f4F872F27D11a6851Dc3104091102D3f;
        feeDistributors[7] = 0x8dD18390f4F872F27D11a6851Dc3104091102D3f;

        address[][] memory tokens = new address[][](8);
        tokens[0] = new address[](3);
        tokens[0][0] = 0x0AFdEE8162CcEAD9AC6a30c94F691E6E7d1af670;
        tokens[0][1] = 0xA25EaF2906FA1a3a13EdAc9B9657108Af7B703e3;
        tokens[0][2] = 0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE;

        tokens[1] = new address[](3);
        tokens[1][0] = 0x0AFdEE8162CcEAD9AC6a30c94F691E6E7d1af670;
        tokens[1][1] = 0xA25EaF2906FA1a3a13EdAc9B9657108Af7B703e3;
        tokens[1][2] = 0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE;

        tokens[2] = new address[](2);
        tokens[2][0] = 0x1b7bCd44E77ADBb31BEa105842139d78f352Dc81;
        tokens[2][1] = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;

        tokens[3] = new address[](2);
        tokens[3][0] = 0x1b7bCd44E77ADBb31BEa105842139d78f352Dc81;
        tokens[3][1] = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;

        tokens[4] = new address[](8);
        tokens[4][0] = 0x152b9d0FdC40C096757F570A51E494bd4b943E50;
        tokens[4][1] = 0x18E3605B13F10016901eAC609b9E188CF7c18973;
        tokens[4][2] = 0x2064f67bA4362422EAaE6Ba7689c0CB0fA82c961;
        tokens[4][3] = 0x00697F5F6dc2CA0A17e6c89bCcd1173A61eA24a6;
        tokens[4][4] = 0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7;
        tokens[4][5] = 0x26e9dbe75aed331E41272BEcE932Ff1B48926Ca9;
        tokens[4][6] = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
        tokens[4][7] = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;

        tokens[5] = new address[](8);
        tokens[5][0] = 0x152b9d0FdC40C096757F570A51E494bd4b943E50;
        tokens[5][1] = 0x18E3605B13F10016901eAC609b9E188CF7c18973;
        tokens[5][2] = 0x2064f67bA4362422EAaE6Ba7689c0CB0fA82c961;
        tokens[5][3] = 0x00697F5F6dc2CA0A17e6c89bCcd1173A61eA24a6;
        tokens[5][4] = 0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7;
        tokens[5][5] = 0x26e9dbe75aed331E41272BEcE932Ff1B48926Ca9;
        tokens[5][6] = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
        tokens[5][7] = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;

        tokens[6] = new address[](4);
        tokens[6][0] = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
        tokens[6][1] = 0x2136Ce7d6Bc15daF23A13F70927b17a7dD691aAd;
        tokens[6][2] = 0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7;
        tokens[6][3] = 0x152b9d0FdC40C096757F570A51E494bd4b943E50;

        tokens[7] = new address[](4);
        tokens[7][0] = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
        tokens[7][1] = 0x2136Ce7d6Bc15daF23A13F70927b17a7dD691aAd;
        tokens[7][2] = 0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7;
        tokens[7][3] = 0x152b9d0FdC40C096757F570A51E494bd4b943E50;

        // Build unique list of all input tokens to be swapped
        address[] memory inputTokens = _getUniqueTokens(tokens);

        bytes memory tradeData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwapMultiInput.selector,
            inputTokens,
            100_000_000_000 // 100k USDC output (6 decimals)
        );

        uint256 usdcLoanBefore = IERC20(USDC).balanceOf(LOAN);
        uint256 pharBefore = IERC20(PHAR).balanceOf(PORTFOLIO);
        uint256 wavaxBefore = IERC20(WAVAX).balanceOf(PORTFOLIO);
        uint256 p33Before = IERC20(P33).balanceOf(PORTFOLIO);
        uint256 hefeBefore = IERC20(HEFE).balanceOf(PORTFOLIO);
        (uint256 debtBefore, ) = IXLoan(LOAN).getLoanDetails(PORTFOLIO);

        console.log("before usdcLoan", usdcLoanBefore);
        console.log("before phar", pharBefore);
        console.log("before wavax", wavaxBefore);
        console.log("before p33", p33Before);
        console.log("before hefe", hefeBefore);
        console.log("before debt", debtBefore);

        vm.prank(PORTFOLIO);
        XPharaohLoan(LOAN).claimLegacy(feeDistributors, tokens, tradeData, 0);

        uint256 usdcLoanAfter = IERC20(USDC).balanceOf(LOAN);
        uint256 pharAfter = IERC20(PHAR).balanceOf(PORTFOLIO);
        uint256 wavaxAfter = IERC20(WAVAX).balanceOf(PORTFOLIO);
        uint256 p33After = IERC20(P33).balanceOf(PORTFOLIO);
        uint256 hefeAfter = IERC20(HEFE).balanceOf(PORTFOLIO);
        (uint256 debtAfter, ) = IXLoan(LOAN).getLoanDetails(PORTFOLIO);

        console.log("after usdcLoan", usdcLoanAfter);
        console.log("after phar", pharAfter);
        console.log("after wavax", wavaxAfter);
        console.log("after p33", p33After);
        console.log("after hefe", hefeAfter);
        console.log("after debt", debtAfter);

        assertLt(debtAfter, debtBefore, "Debt should decrease from rewards");
        
        // Verify reward tokens were consumed by the swap (not left on portfolio)
        // After a real Odos swap, the input tokens should be transferred out
        assertEq(pharAfter, pharBefore, "PHAR should be swapped away");
        assertEq(wavaxAfter, wavaxBefore, "WAVAX should be swapped away");
        assertEq(hefeAfter, hefeBefore, "HEFE should be swapped away");
        assertEq(p33After, p33Before, "P33 should be swapped away");
        
        console.log("Debt reduced by:", debtBefore - debtAfter);
    }

    // Called by MockOdosRouterRL to mint USDC to receiver
    function mintUsdc(address /*minter*/, address to, uint256 amount) external {
        IUSDC(USDC).mint(to, amount);
    }

    /// @dev Extracts unique token addresses from a 2D array
    function _getUniqueTokens(address[][] memory tokens) internal pure returns (address[] memory) {
        // First pass: count max possible tokens
        uint256 totalCount = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            totalCount += tokens[i].length;
        }

        // Temporary array to store candidates
        address[] memory temp = new address[](totalCount);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = 0; j < tokens[i].length; j++) {
                address token = tokens[i][j];
                bool found = false;
                for (uint256 k = 0; k < uniqueCount; k++) {
                    if (temp[k] == token) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    temp[uniqueCount] = token;
                    uniqueCount++;
                }
            }
        }

        // Copy to correctly sized array
        address[] memory result = new address[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            result[i] = temp[i];
        }
        return result;
    }
}

