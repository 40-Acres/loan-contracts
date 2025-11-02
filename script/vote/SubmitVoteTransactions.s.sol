// // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {XPharaohLoan as Loan} from "src/Pharaoh/XPharaohLoan.sol";
import {IVoter} from "src/interfaces/IVoter.sol";
import {Vault} from "src/Vault.sol";
import {Vault as VaultV2} from "src/VaultV2.sol";
// import { XPharaohSwapper as Swapper } from "../src/XPharaoh/XPharaohSwapper.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Swapper} from "../../src/Swapper.sol";
import {AccountConfigStorage} from "../../src/storage/AccountConfigStorage.sol";
import {FacetRegistry} from "../../src/accounts/FacetRegistry.sol";
import {XPharaohFacet} from "../../src/facets/account/XPharaohFacet.sol";
import {PortfolioFactory} from "../../src/accounts/PortfolioFactory.sol";
import {IXLoan} from "../../src/interfaces/IXLoan.sol";
import {PharaohLoanV2} from "../../src/Pharaoh/PharaohLoanV2.sol";

interface IOwnable {
    function owner() external view returns (address);
}


contract XPharaohVote is Script {
    address[] public supportedTokens;
    uint256 fork;
    AccountConfigStorage _accountConfigStorage = AccountConfigStorage(0x17cd3c65daf5b2F806d053D948Ad7d59191fd397);
    FacetRegistry _facetRegistry = FacetRegistry(0x9bCa68D9c613Dc9B07B2727c28b5ce46204943de);
    PortfolioFactory _portfolioFactory = PortfolioFactory(0x52d43C377e498980135C8F2E858f120A18Ea96C2);
    Loan _loan = Loan(0x6Bf2Fe80D245b06f6900848ec52544FBdE6c8d2C);

    function run() external  {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        vote();
    }

    function mock() public {
        vm.startPrank(0x40FecA5f7156030b78200450852792ea93f7c6cd);
        vote();
        vm.stopPrank();
    }

    function vote() public {

        address[] memory portfolios = _portfolioFactory.getAllPortfolios();

        for (uint256 i; i < portfolios.length; i++) {
            address owner = _portfolioFactory.ownerOf(portfolios[i]);
            console.log(",", portfolios[i]);
            XPharaohFacet(payable(portfolios[i])).xPharVote(address(_loan));
        }
    }


}

// forge script script/vote/SubmitVoteTransactions.s.sol:XPharaohVote  --chain-id 43114 --rpc-url $AVAX_RPC_URL --etherscan-api-key $AVAXSCAN_API_KEY --broadcast --verify --via-ir
