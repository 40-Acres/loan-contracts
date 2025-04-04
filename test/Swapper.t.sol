import { Swapper } from "../src/Swapper.sol";
import {Test, console} from "forge-std/Test.sol";
import { IRouter } from "../src/interfaces/IRouter.sol";


contract SwapperTest is Test {
    Swapper public swapper;
    address[] public supportedTokens;
    address public factory;
    address public router;
    uint256 fork;
    address _aero = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address _usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address _weth = 0x4200000000000000000000000000000000000006;

    function setUp() public {
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(28494354);


        address[] memory _supportedTokens = new address[](3);
        _supportedTokens[0] = _aero; 
        _supportedTokens[1] = _usdc; 
        _supportedTokens[2] = _weth; 
        supportedTokens = _supportedTokens;
        
        swapper = new Swapper(
            address(0x420DD381b31aEf6683db6B902084cB0FFECe40Da),
            address(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43),
            supportedTokens
        );
    }

    function testSwapWethToUsdc() public {
        IRouter.Route[] memory route = swapper.getBestRoute(_weth, _usdc, 1e18); // 1 WETH
        console.log( "Optimal Route from WETH to USDC:");
        for (uint256 i = 0; i < route.length; i++) {
            console.log("Route %d: %s -> %s", i, address(route[i].from), address(route[i].to));
        }
        assertTrue(route.length > 0, "No route found for WETH to USDC");
        uint256 amountOut = IRouter(swapper.router()).getAmountsOut(1e18, route)[route.length];
        console.log("Amount out for 1 WETH to USDC: %s", amountOut);
        assertTrue(amountOut > 1775e6, "Amount out should be greater than $1775");

    }




    function testSwapSuiToUsdc() public {
        IRouter.Route[] memory route = swapper.getBestRoute(0xb0505e5a99abd03d94a1169e638B78EDfEd26ea4, _usdc, 1018); // 1 SUI
        console.log( "Optimal Route from SUI to USDC:");
        for (uint256 i = 0; i < route.length; i++) {
            console.log("Route %d: %s -> %s", i, address(route[i].from), address(route[i].to));
        }
        assertTrue(route.length > 0, "No route found for SUI to USDC");
    }
}