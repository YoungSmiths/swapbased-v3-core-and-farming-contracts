// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@pancakeswap/v3-core/contracts/libraries/SafeCast.sol';
import '@pancakeswap/v3-core/contracts/libraries/TickMath.sol';
import '@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Pool.sol';

import './interfaces/ISwapRouter.sol';
import './base/PeripheryImmutableState.sol';
import './base/PeripheryValidation.sol';
import './base/PeripheryPaymentsWithFee.sol';
import './base/Multicall.sol';
import './base/SelfPermit.sol';
import './libraries/Path.sol';
import './libraries/PoolAddress.sol';
import './libraries/CallbackValidation.sol';
import './interfaces/external/IWETH9.sol';

/// @title Pancake V3 SwapRouter
/// @notice V3 交易路由器：对接一个或多个池子执行换币（精确输入 / 精确输出）。
/// @dev 使用场景：
/// - 普通用户前端换币（单跳）：如 USDT -> WBNB；
/// - 聚合路径换币（多跳）：如 CAKE -> USDT -> WBNB；
/// - 需要“最多花多少”约束的精确输出订单。
contract SwapRouter is
    ISwapRouter,
    PeripheryImmutableState,
    PeripheryValidation,
    PeripheryPaymentsWithFee,
    Multicall,
    SelfPermit
{
    using Path for bytes;
    using SafeCast for uint256;

    /// @notice `amountInCached` 的哨兵初始值。
    /// @dev 取 `uint256.max`，因为真实计算出的输入金额不可能是这个值。
    uint256 private constant DEFAULT_AMOUNT_IN_CACHED = type(uint256).max;

    /// @notice 精确输出多跳场景下临时缓存“最终实际消耗输入金额”。
    /// @dev 仅用于 `exactOutput` 调用链末尾回读结果。
    uint256 private amountInCached = DEFAULT_AMOUNT_IN_CACHED;

    /// @notice 构造函数：注入 deployer/factory/WETH9（由基类 `PeripheryImmutableState` 保存）。
    constructor(address _deployer, address _factory, address _WETH9) PeripheryImmutableState(_deployer, _factory, _WETH9) {}

    /// @notice 按 token 对和 fee 计算池地址并返回池实例。
    /// @param tokenA 代币A。
    /// @param tokenB 代币B。
    /// @param fee 费率档（如 500/2500/10000）。
    /// @return 对应 V3 池实例（地址按规则计算，池可能尚未部署）。
    /// @dev 使用场景：在 swap 前定位目标池。
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) private view returns (IPancakeV3Pool) {
        return IPancakeV3Pool(PoolAddress.computeAddress(deployer, PoolAddress.getPoolKey(tokenA, tokenB, fee)));
    }

    struct SwapCallbackData {
        /// @notice 当前（或剩余）路径编码。
        bytes path;
        /// @notice 最终付款人地址。
        /// @dev 多跳时第一跳通常是用户，后续中间跳通常是路由器自身。
        address payer;
    }

    /// @inheritdoc IPancakeV3SwapCallback
    /// @notice V3 池回调入口：池子要求路由器在回调里支付本步应付 token。
    /// @param amount0Delta token0 维度净变化（池子视角，正数表示路由器需支付给池）。
    /// @param amount1Delta token1 维度净变化（同上）。
    /// @param _data 编码的 `SwapCallbackData`。
    /// @dev 核心逻辑（逐行）：
    /// 1) 解析路径并校验回调来源池合法；
    /// 2) 判断当前是精确输入路径还是精确输出反向路径；
    /// 3) 精确输入：直接支付本步应付 token；
    /// 4) 精确输出多跳：递归触发下一跳反向交换，直到最后一跳再支付；
    /// 5) 最后一跳把本次输入金额写入 `amountInCached` 供外层读取。
    /// @dev 例子（精确输出多跳）：
    /// 想“刚好买到 1 WBNB”，路径 USDT->CAKE->WBNB。
    /// 回调会先从 WBNB 侧倒推到 CAKE，再倒推到 USDT，最终只让用户支付刚好够的 USDT。
    function pancakeV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external override {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported
        // 解码回调上下文（路径 + 实际付款人）。
        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));
        // 拿到当前这一步池子的 tokenIn/tokenOut/fee。
        (address tokenIn, address tokenOut, uint24 fee) = data.path.decodeFirstPool();
        // 校验 msg.sender 确实是该池，防止恶意合约伪造回调骗转账。
        CallbackValidation.verifyCallback(deployer, tokenIn, tokenOut, fee);

        // 判断这一步属于精确输入还是精确输出倒序路径，并提取本步应付金额。
        (bool isExactInput, uint256 amountToPay) =
            amount0Delta > 0
                ? (tokenIn < tokenOut, uint256(amount0Delta))
                : (tokenOut < tokenIn, uint256(amount1Delta));
        if (isExactInput) {
            // 精确输入：直接从 payer 支付 tokenIn 给池子。
            pay(tokenIn, data.payer, msg.sender, amountToPay);
        } else {
            // 精确输出：要么继续倒推下一跳，要么已到最后一跳执行支付。
            if (data.path.hasMultiplePools()) {
                // 跳过当前池的前缀，继续下一跳倒推。
                data.path = data.path.skipToken();
                exactOutputInternal(amountToPay, msg.sender, 0, data);
            } else {
                // 最后一跳：记录最终输入金额，并支付给池子。
                amountInCached = amountToPay;
                tokenIn = tokenOut; // swap in/out because exact output swaps are reversed
                pay(tokenIn, data.payer, msg.sender, amountToPay);
            }
        }
    }

    /// @notice 单跳精确输入交换内部实现。
    /// @param amountIn 本步精确输入数量。
    /// @param recipient 本步输出接收方（中间跳常为路由器自身）。
    /// @param sqrtPriceLimitX96 价格边界（0 表示用默认极限边界）。
    /// @param data 回调所需上下文（路径+付款人）。
    /// @return amountOut 本步输出数量。
    /// @dev 使用场景：`exactInputSingle` 直接调用；`exactInput` 多跳中循环调用。
    /// @dev 例子：USDT->WBNB 单跳，输入 1000 USDT，返回实际拿到的 WBNB 数量。
    function exactInputInternal(
        uint256 amountIn,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountOut) {
        // 允许 caller 用 address(0) 表示“先打给路由器自己”（中间跳托管用）。
        if (recipient == address(0)) recipient = address(this);

        // 解码本步池信息。
        (address tokenIn, address tokenOut, uint24 fee) = data.path.decodeFirstPool();

        // token 顺序决定 swap 方向。
        bool zeroForOne = tokenIn < tokenOut;

        // 调池子 swap，回调里由本合约完成付款。
        (int256 amount0, int256 amount1) =
            getPool(tokenIn, tokenOut, fee).swap(
                recipient,
                zeroForOne,
                amountIn.toInt256(),
                // 若没传价格限制，使用靠近最小/最大边界的默认值，避免触碰极值常量本身。
                sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : sqrtPriceLimitX96,
                abi.encode(data)
            );

        // 把池子返回的 signed delta 转成“用户视角输出数量”。
        return uint256(-(zeroForOne ? amount1 : amount0));
    }

    /// @inheritdoc ISwapRouter
    /// @notice 单跳精确输入：固定输入数量，尽量换出更多目标币。
    /// @param params `ExactInputSingleParams`：
    /// - tokenIn/tokenOut/fee：目标池；
    /// - amountIn：输入数量；
    /// - amountOutMinimum：最少可接受输出（滑点保护）；
    /// - recipient：收款地址；
    /// - deadline：过期时间。
    /// @return amountOut 实际输出数量。
    /// @dev 使用场景：普通兑换按钮最常用接口。
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        amountOut = exactInputInternal(
            params.amountIn,
            params.recipient,
            params.sqrtPriceLimitX96,
            SwapCallbackData({path: abi.encodePacked(params.tokenIn, params.fee, params.tokenOut), payer: msg.sender})
        );
        require(amountOut >= params.amountOutMinimum, 'Too little received');
    }

    /// @inheritdoc ISwapRouter
    /// @notice 多跳精确输入：路径正向执行，前一步输出作为后一步输入。
    /// @param params `ExactInputParams`：
    /// - path：多跳编码路径（tokenIn,fee,tokenMid,fee,tokenOut...）；
    /// - amountIn：总输入；
    /// - amountOutMinimum：最少输出；
    /// - recipient/deadline：收款人与有效期。
    /// @return amountOut 最终输出数量。
    /// @dev 使用场景：没有直连流动性时走中间币提高成交效果。
    /// @dev 例子：CAKE -> USDT -> WBNB，第一跳输出 USDT 由路由器托管，第二跳再换成 WBNB 给用户。
    function exactInput(ExactInputParams memory params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        address payer = msg.sender; // msg.sender pays for the first hop

        while (true) {
            bool hasMultiplePools = params.path.hasMultiplePools();

            // 前一跳输出直接作为下一跳输入。
            params.amountIn = exactInputInternal(
                params.amountIn,
                hasMultiplePools ? address(this) : params.recipient, // 中间跳资金先托管在路由器
                0,
                SwapCallbackData({
                    path: params.path.getFirstPool(), // only the first pool in the path is necessary
                    payer: payer
                })
            );

            // 是否继续下一跳。
            if (hasMultiplePools) {
                payer = address(this); // 第一跳之后由路由器自己作为付款人
                params.path = params.path.skipToken();
            } else {
                amountOut = params.amountIn;
                break;
            }
        }

        require(amountOut >= params.amountOutMinimum, 'Too little received');
    }

    /// @notice 单跳精确输出交换内部实现（按反向路径思路执行）。
    /// @param amountOut 希望精确拿到的输出数量。
    /// @param recipient 输出接收方。
    /// @param sqrtPriceLimitX96 价格边界（0=默认边界）。
    /// @param data 回调上下文（通常包含反向 path 与付款人）。
    /// @return amountIn 为拿到 `amountOut` 实际花费的输入数量。
    /// @dev 使用场景：希望“买到固定数量目标币”，并限制最多花多少输入币。
    function exactOutputInternal(
        uint256 amountOut,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountIn) {
        // 允许 address(0) 代表路由器自身。
        if (recipient == address(0)) recipient = address(this);

        // 精确输出路径是反向编码：先 decode 出 tokenOut，再得到 tokenIn。
        (address tokenOut, address tokenIn, uint24 fee) = data.path.decodeFirstPool();

        bool zeroForOne = tokenIn < tokenOut;

        // 注意这里 amountSpecified 传负数，表示“精确输出模式”。
        (int256 amount0Delta, int256 amount1Delta) =
            getPool(tokenIn, tokenOut, fee).swap(
                recipient,
                zeroForOne,
                -amountOut.toInt256(),
                sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : sqrtPriceLimitX96,
                abi.encode(data)
            );

        uint256 amountOutReceived;
        // 把 signed delta 转成 “花了多少/收了多少”。
        (amountIn, amountOutReceived) = zeroForOne
            ? (uint256(amount0Delta), uint256(-amount1Delta))
            : (uint256(amount1Delta), uint256(-amount0Delta));
        // 若没设置价格限制，要求实际收到 = 目标输出，避免“少收”。
        if (sqrtPriceLimitX96 == 0) require(amountOutReceived == amountOut);
    }

    /// @inheritdoc ISwapRouter
    /// @notice 单跳精确输出：目标输出固定，输入不超过 `amountInMaximum`。
    /// @param params `ExactOutputSingleParams`（tokenIn/tokenOut/fee/amountOut/amountInMaximum 等）。
    /// @return amountIn 实际消耗输入数量。
    /// @dev 使用场景：例如“我要刚好买 1 WBNB，最多花 3200 USDT”。
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        // avoid an SLOAD by using the swap return data
        amountIn = exactOutputInternal(
            params.amountOut,
            params.recipient,
            params.sqrtPriceLimitX96,
            SwapCallbackData({path: abi.encodePacked(params.tokenOut, params.fee, params.tokenIn), payer: msg.sender})
        );

        require(amountIn <= params.amountInMaximum, 'Too much requested');
        // has to be reset even though we don't use it in the single hop case
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    }

    /// @inheritdoc ISwapRouter
    /// @notice 多跳精确输出：按反向路径倒推每一跳需要的输入，最终得到总输入。
    /// @param params `ExactOutputParams`：
    /// - path：反向编码路径（tokenOut,fee,tokenMid,fee,tokenIn...）；
    /// - amountOut：目标输出；
    /// - amountInMaximum：最大输入上限；
    /// - recipient/deadline：收款人与有效期。
    /// @return amountIn 实际总输入。
    /// @dev 使用场景：跨池买入固定数量目标币并严控成本上限。
    function exactOutput(ExactOutputParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        // 多跳精确输出中，外层 payer 固定为用户。
        // 第一笔（反向路径中的“最后一跳”）先执行，后续由回调嵌套继续倒推支付。
        exactOutputInternal(
            params.amountOut,
            params.recipient,
            0,
            SwapCallbackData({path: params.path, payer: msg.sender})
        );

        amountIn = amountInCached;
        require(amountIn <= params.amountInMaximum, 'Too much requested');
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    }
}
