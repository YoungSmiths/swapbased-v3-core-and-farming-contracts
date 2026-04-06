// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Factory.sol';
import '@pancakeswap/v3-core/contracts/interfaces/callback/IPancakeV3MintCallback.sol';
import '@pancakeswap/v3-core/contracts/libraries/TickMath.sol';

import '../libraries/PoolAddress.sol';
import '../libraries/CallbackValidation.sol';
import '../libraries/LiquidityAmounts.sol';

import './PeripheryPayments.sol';
import './PeripheryImmutableState.sol';

/// @title LiquidityManagement —— 安全加减 V3 流动性（含 mint 回调付款）
/// @notice 封装 **核心池** `IPancakeV3Pool.mint` 与回调付款；`addLiquidity` 负责算 liquidity、调池子、滑点检查。
///
/// =============================================================================
/// **和 NonfungiblePositionManager.mint 是什么关系？（两个「mint」别混）**
/// =============================================================================
/// - **NPM.mint**（`NonfungiblePositionManager.sol`）：面向用户的入口，做两件事：
///   (1) 内部调用本合约的 **`addLiquidity`**，把代币打进**池合约**并在池里创建/增加流动性；
///   (2) 再 **`_mint` 铸 ERC721**（头寸 NFT），把 `tokenId` 发给用户，并在 NPM 里记录 `Position`。
///   名字都叫 mint，但 **一个是铸 NFT**，**一个是池子记账**（见下）。
/// - **addLiquidity**（本文件）：**不铸 NFT**。它只负责调用 **`IPancakeV3Pool.mint`**，因为 **流动性的真实状态只存在核心池**（tick、liquidity、feeGrowth 等），外围合约不能自己「假装」加流动性。
///
/// =============================================================================
/// **为什么 addLiquidity 必须调用 IPancakeV3Pool.mint？**
/// =============================================================================
/// - V3 的 AMM 状态机写在 **PancakeV3Pool** 里：在某个 tick 区间增加 liquidity，必须更新池内 `ticks`、`positions`、token 余额等。
/// - 外围（NPM / Router）**没有**这份状态，只能通过池子对外暴露的 **`pool.mint(recipient, tickLower, tickUpper, liquidity, data)`** 来改状态。
/// - 池子算完需要收多少 token0/token1 后，会 **回调** 本合约的 `pancakeV3MintCallback`，此时才从用户（`payer`）把币 **转进池子**（Pull 模式，防重入与余额检查）。
///
/// =============================================================================
/// **一条完整调用链（结合实际案例）**
/// =============================================================================
/// 用户 Alice 在网页上「添加流动性」，选 USDT/BNB 池、某 fee 档、区间 [tickLower, tickUpper]，并授权 NPM。
/// 1) Alice 调 **NPM.mint(...)**，`msg.sender` = Alice。
/// 2) NPM 内部 **`addLiquidity(AddLiquidityParams{..., recipient: address(this), ...})`**：
///    - `recipient = address(this)`：**流动性记在 NPM 名下**（池内 `positions[NPM][tickLower][tickUpper]`），这样同一合约可管理多用户的 NFT；
///    - `payer` 在 `pool.mint` 的 data 里被设为 **`msg.sender`（此处即 Alice）**，回调里从 **Alice** 扣款。
/// 3) **`pool.mint`** 更新池状态 → 调 **`pancakeV3MintCallback(amount0Owed, amount1Owed, data)`**。
/// 4) 回调里 **`pay(token, Alice, pool, amount)`**：Alice 的 USDT/BNB 进池。
/// 5) 回到 NPM：`addLiquidity` 返回后，NPM **`_mint(Alice, tokenId)`**，Alice 拿到 **头寸 NFT**。
///
/// 小结：**池子 `.mint` = 链上 AMM 加流动性；NPM `.mint` = 给用户铸代表该头寸的 NFT。** 本合约的 `addLiquidity` 是二者的桥梁。
abstract contract LiquidityManagement is IPancakeV3MintCallback, PeripheryImmutableState, PeripheryPayments {
    /// @notice mint 回调里解码的数据：哪口池、谁付钱。
    struct MintCallbackData {
        PoolAddress.PoolKey poolKey; // 用于 verifyCallback 与 pay 时取 token0/token1 地址
        address payer; // 实际付款人：addLiquidity 调用者（须已 approve 本合约或走 ETH/WETH 支付路径）
    }

    /// @notice 池子在 `mint` 后回调本合约，索要应支付的 token0/token1。
    /// @param amount0Owed / amount1Owed 须支付数量。
    /// @param data ABI 编码的 `MintCallbackData`。
    /// **核心逻辑**：`CallbackValidation.verifyCallback` 防伪造池 → `pay(token, payer, pool, amount)`。
    /// **使用场景**：仅由真实 Pancake V3 池在 mint 流程中调用；用户不直接调。
    /// @inheritdoc IPancakeV3MintCallback
    function pancakeV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external override {
        // 解码 mint 时传入的附带数据：池键 + 实际付款人（一般为调用 addLiquidity 的 msg.sender）
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));
        // 确认 msg.sender 确为该 poolKey 对应的真池地址，防止恶意合约冒充池子骗款
        CallbackValidation.verifyCallback(deployer, decoded.poolKey);

        // 此处完成「加流动性」的真实支付：从 payer 拉 token 给池子（本回调里 msg.sender 即池地址）
        if (amount0Owed > 0) pay(decoded.poolKey.token0, decoded.payer, msg.sender, amount0Owed);
        if (amount1Owed > 0) pay(decoded.poolKey.token1, decoded.payer, msg.sender, amount1Owed);
    }

    /// @notice 加流动性参数（与 NPM `mint` / `increaseLiquidity` 上层传入对应）。
    struct AddLiquidityParams {
        address token0; // 池子排序后较小地址
        address token1; // 池子排序后较大地址
        uint24 fee; // 费率档，须与已存在池一致
        address recipient; // 流动性记在谁名下（NPM 加池时常为 address(this)）
        int24 tickLower; // 区间下界 tick
        int24 tickUpper; // 区间上界 tick
        uint256 amount0Desired; // 愿意投入的 token0 上限（用于算 liquidity）
        uint256 amount1Desired; // 愿意投入的 token1 上限
        uint256 amount0Min; // 滑点：实际消耗 token0 不得低于此
        uint256 amount1Min; // 滑点：实际消耗 token1 不得低于此
    }

    /// @notice 在**已初始化**的池上增加流动性；用 `LiquidityAmounts.getLiquidityForAmounts` 按当前价与区间算 liquidity，再 `pool.mint`。
    /// @return liquidity 写入头寸的流动性数值。
    /// @return amount0 / amount1 实际支付的 token 量（经 callback 结算）。
    /// @return pool 池实例。
    /// **核心逻辑**：`computeAddress` 得池地址 → `slot0` 取当前价 → 算 liquidity → `mint` 并校验 `amount* >= amount*Min`。
    /// **使用场景**：`NonfungiblePositionManager.mint` / `increaseLiquidity` 内部调用。
    /// @dev 本函数体内无直接 transfer；代币在 `pool.mint` 内部通过 `pancakeV3MintCallback` 支付（见上）。
    function addLiquidity(AddLiquidityParams memory params)
        internal
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1,
            IPancakeV3Pool pool
        )
    {
        // 与工厂 CREATE2 规则一致，用于算池地址与回调验池
        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.fee});

        // 由 deployer + poolKey 确定性得到池合约地址（须已部署）
        pool = IPancakeV3Pool(PoolAddress.computeAddress(deployer, poolKey));

        // 根据当前价与 [tickLower, tickUpper) 计算：在不超过 amount0/1Desired 前提下能加多少 liquidity
        {
            (uint160 sqrtPriceX96, , , , , , ) = pool.slot0(); // 当前池内 sqrt 价格
            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                params.amount0Desired,
                params.amount1Desired
            );
        }

        // mint 内部会回调本合约 pancakeV3MintCallback，在回调里从 payer 支付 token0/token1 给池子
        // payer 编码为当前调用者 msg.sender（如 NPM 用户）；recipient 为流动性记在谁名下（常为 NPM 自身）
        (amount0, amount1) = pool.mint(
            params.recipient,
            params.tickLower,
            params.tickUpper,
            liquidity,
            abi.encode(MintCallbackData({poolKey: poolKey, payer: msg.sender}))
        );

        // 实际消耗若低于用户滑点下限则整笔回滚（防价格被夹或区间理解错误）
        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, 'Price slippage check');
    }
}
