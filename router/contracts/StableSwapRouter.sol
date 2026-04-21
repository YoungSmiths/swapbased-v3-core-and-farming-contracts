// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import './interfaces/IStableSwapRouter.sol';
import './interfaces/IStableSwap.sol';
import './libraries/SmartRouterHelper.sol';
import './libraries/Constants.sol';

import './base/PeripheryPaymentsWithFeeExtended.sol';

/// @title 稳定币曲线池路由
/// @notice 对接 Curve 类 StableSwap（低滑点换锚定资产），与 V2/V3 的恒定乘积不同，这里通过 `IStableSwap.exchange` 在池内换币。
/// @dev 状态变量：
/// - `stableSwapFactory`：登记各稳定池合约的工厂。
/// - `stableSwapInfo`：辅助查询池参数、币索引等元数据。
/// 使用场景：用户要把 10,000 USDT 换成 BUSD，走稳定池而不是通用 V2 池，以获得更小滑点；多跳时 `path` 为 `[USDT, USDC, BUSD]`，`flag` 每段标明对应池是 2 币池还是 3 币池。
abstract contract StableSwapRouter is IStableSwapRouter, PeripheryPaymentsWithFeeExtended, Ownable, ReentrancyGuard {
    /// @notice 稳定池工厂地址（可由 owner 通过 `setStableSwap` 更新）。
    address public stableSwapFactory;
    /// @notice 稳定池信息合约地址（与 factory 配套使用）。
    address public stableSwapInfo;

    /// @notice 管理员更新了稳定池工厂/信息合约。
    event SetStableSwap(address indexed factory, address indexed info);

    /// @param _stableSwapFactory 部署时注入的稳定池工厂，例如主网 Pancake Stable 工厂地址。
    /// @param _stableSwapInfo 与工厂配套的 Info 合约，用于 `getStableInfo` / `getStableAmountsIn`。
    constructor(
        address _stableSwapFactory,
        address _stableSwapInfo
    ) {
        stableSwapFactory = _stableSwapFactory;
        stableSwapInfo = _stableSwapInfo;
    }

    /// @notice 仅 owner 可更新稳定池配置（例如协议升级迁移到新 factory）。
    /// @dev 使用场景：治理通过多签投票后，owner 调用本函数把路由指向新工厂，用户前端无需改路由地址。
    /// @param _factory 新工厂地址，不能为 `address(0)`。
    /// @param _info 新 Info 地址，不能为 `address(0)`。
    function setStableSwap(
        address _factory,
        address _info
    ) external onlyOwner {
        require(_factory != address(0) && _info != address(0));

        stableSwapFactory = _factory;
        stableSwapInfo = _info;

        emit SetStableSwap(stableSwapFactory, stableSwapInfo);
    }

    /// @notice 内部多跳稳定兑换：每一段根据 `path` 与 `flag` 解析池子与 (i,j) 索引，再把本合约持有的 input 全部 approve 后调用 `exchange`。
    /// @dev 使用场景：`path = [USDT, BUSD]`、`flag = [2]` 表示一段 2 池里 USDT→BUSD；若为 `[DAI, USDC, USDT]` 则 `flag` 长度为 2，每段各指一个池类型。
    /// @dev 组合 multicall 时，通常在本函数之后紧跟 `refundETH` 或 `unwrapWETH9`，把剩余 ETH/WETH 退回用户。
    /// @param path 代币地址序列，长度 = 跳数 + 1。
    /// @param flag 与每一跳对齐；`2` 表示该跳为 2 币池，`3` 表示 3 币池（与 `SmartRouterHelper.getStableInfo` 约定一致）。
    function _swap(
        address[] memory path,
        uint256[] memory flag
    ) private {
        // 例：3 个代币 = 2 跳，则 flag 必须恰好 2 个元素，一一对应每一跳池配置。
        require(path.length - 1 == flag.length);
        
        for (uint256 i; i < flag.length; i++) {
            // 当前跳的输入/输出币，例如第一段 USDT→USDC。
            (address input, address output) = (path[i], path[i + 1]);
            // 由工厂+币对+flag 解析出池内币种索引 k,j 以及池合约地址；例：三池中 USDT 可能是索引 0，BUSD 为索引 1。
            (uint256 k, uint256 j, address swapContract) = SmartRouterHelper.getStableInfo(stableSwapFactory, input, output, flag[i]); 
            // 路由合约当前持有的 input 全部用于本跳（上一跳输出或用户刚 pay 进来的钱）。
            uint256 amountIn_ = IERC20(input).balanceOf(address(this));
            // 授权池子从路由拉走 input；额度用当前余额，避免少授权。
            TransferHelper.safeApprove(input, swapContract, amountIn_);
            // `min_dy` 传 0：外层 `exactInputStableSwap` 会用最终余额与 `amountOutMin` 做统一校验；若需每跳滑点保护需在 Helper/池子层扩展。
            IStableSwap(swapContract).exchange(k, j, amountIn_, 0);
        }
    }

    /// @notice 精确输入稳定兑换：用户指定付出 `amountIn` 的 `path[0]`，沿稳定池路径换到最后一币，实际输出 ≥ `amountOutMin`。
    /// @dev 使用场景：用户在 DApp 选择「稳定路由」标签，用 5,000 USDT 换尽可能多的 FDUSD，并设置最小接收 4,995。
    /// @dev `amountIn == Constants.CONTRACT_BALANCE`（0）：表示使用本合约已持有的 `path[0]` 全余额，适合与 `multicall` 组合（先转入再 swap）。
    /// @param path 例：`[USDT, BUSD]` 或 `[USDT, USDC, BUSD]`。
    /// @param flag 每一跳池规模标识：`2` = 双币稳定池，`3` = 三币稳定池；必须与 `path` 段数一致。
    /// @param amountIn 输入数量；0 表示用合约余额全量。
    /// @param amountOutMin 最后一币最小可接受到账量。
    /// @param to 最后一币接收方；可用 `MSG_SENDER`/`ADDRESS_THIS` 魔法地址。
    /// @return amountOut 兑换结束后路由合约持有的最后一币余额（在 `pay` 给用户之前测量），即本次产出。
    function exactInputStableSwap(
        address[] calldata path,
        uint256[] calldata flag,
        uint256 amountIn,
        uint256 amountOutMin,
        address to
    ) external payable override nonReentrant returns (uint256 amountOut) {
        IERC20 srcToken = IERC20(path[0]);
        IERC20 dstToken = IERC20(path[path.length - 1]);

        // 与 V2 路由相同：0 输入表示「合约里已经有钱了」，常见于聚合器批量调用。
        bool hasAlreadyPaid;
        if (amountIn == Constants.CONTRACT_BALANCE) {
            hasAlreadyPaid = true;
            amountIn = srcToken.balanceOf(address(this));
        }

        // 未预付则从用户拉 `amountIn` 到路由合约，再由 `_swap` 分段 approve+exchange。
        if (!hasAlreadyPaid) {
            pay(address(srcToken), msg.sender, address(this), amountIn);
        }

        // 在合约内完成各跳稳定池兑换，输出累积为路由持有的 dstToken。
        _swap(path, flag);

        // 测量本次兑换后路由上的 dst 余额作为产出。
        amountOut = dstToken.balanceOf(address(this));
        // 例：希望至少收到 4,995 FDUSD，若曲线池深度不足只产出 4,990，则此处回滚。
        require(amountOut >= amountOutMin);

        // 解析魔法收款地址：前端可固定传 0x...01 表示「发给调用者」。
        if (to == Constants.MSG_SENDER) to = msg.sender;
        else if (to == Constants.ADDRESS_THIS) to = address(this);

        // 若用户要提到自己钱包，则从路由转 `amountOut` 给 `to`；若 `to` 为本合约则跳过（留给后续 multicall 步骤）。
        if (to != address(this)) pay(address(dstToken), address(this), to, amountOut);
    }

    /// @notice 精确输出稳定兑换：希望最后一币恰好得到 `amountOut`，从用户最多扣 `amountInMax` 的 `path[0]`。
    /// @dev 使用场景：还款需要精确 10,000 BUSD，允许系统反推需要从 USDT 扣多少，但不超过 10,050 USDT。
    /// @dev 实现上先通过 `stableSwapInfo` + 工厂做链上/链下一致的路径询价 `getStableAmountsIn`，再执行 `_swap`。
    /// @param path 与 `exactInput` 相同语义的代币序列。
    /// @param flag 每跳 2/3 池标识，与 `path` 对齐。
    /// @param amountOut 目标精确输出（最后一币）。
    /// @param amountInMax 用户愿意支付的最大输入；若询价结果超出则整笔失败。
    /// @param to 最后一币接收地址（魔法地址规则同上）。
    /// @return amountIn 实际从用户收取的 `path[0]` 数量（数组首元素）。
    function exactOutputStableSwap(
        address[] calldata path,
        uint256[] calldata flag,
        uint256 amountOut,
        uint256 amountInMax,
        address to
    ) external payable override nonReentrant returns (uint256 amountIn) {
        // 例：要精确 1,000 BUSD out，Helper 返回 [1050 USDT, ...] 表示路径上每跳所需输入，这里取第一币 USDT 的数量作为向用户收取的 amountIn。
        amountIn = SmartRouterHelper.getStableAmountsIn(stableSwapFactory, stableSwapInfo, path, flag, amountOut)[0];
        require(amountIn <= amountInMax);

        // 先从用户把计算得到的 input 收到路由，再分段兑换。
        pay(path[0], msg.sender, address(this), amountIn);

        _swap(path, flag);

        if (to == Constants.MSG_SENDER) to = msg.sender;
        else if (to == Constants.ADDRESS_THIS) to = address(this);

        // 精确输出语义：只向用户转约定的 `amountOut`，多余留在路由（通常由后续 refund/管理员处理）；与 V3 exactOutput 行为同类。
        if (to != address(this)) pay(path[path.length - 1], address(this), to, amountOut);    
    }
}
