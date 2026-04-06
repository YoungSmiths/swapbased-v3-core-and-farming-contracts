// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Pool.sol';
import '@pancakeswap/v3-core/contracts/libraries/FixedPoint128.sol';
import '@pancakeswap/v3-core/contracts/libraries/FullMath.sol';

import './interfaces/INonfungiblePositionManager.sol';
import './interfaces/INonfungibleTokenPositionDescriptor.sol';
import './libraries/PositionKey.sol';
import './libraries/PoolAddress.sol';
import './base/LiquidityManagement.sol';
import './base/PeripheryImmutableState.sol';
import './base/Multicall.sol';
import './base/ERC721Permit.sol';
import './base/PeripheryValidation.sol';
import './base/SelfPermit.sol';
import './base/PoolInitializer.sol';

/// @title NonfungiblePositionManager —— V3 集中流动性头寸的 ERC721 封装
/// @notice 把 Pancake V3 池子上的「一个价格区间 + 一份流动性」包装成 **可转账的 NFT**；增删流动性、收手续费都通过本合约与核心池交互。
///
/// **形象理解**：你在某个交易对（如 USDT/BNB）上选了一段价格「格子」（tickLower～tickUpper）往里放双边代币做 LP，链上不直接记你一堆参数，而是 **铸一枚「头寸 NFT」**（tokenId）。NFT 在谁手里，谁就有权操作这笔流动性（或授权给合约/他人）。
///
/// **与 V2 的区别**：V2 是整池按比例份额；V3 是 **集中流动性**，同一池可有多枚 NFT、不同区间、不同手续费档（fee），资本效率更高，但需自己管理区间与无常损失。
///
/// **典型流程（实际案例）**：
/// 1. 池已存在且已初始化价格 → 调 `mint`：转入 token0/token1，得到新 `tokenId` + 池内 liquidity。
/// 2. 想加仓 → `increaseLiquidity`（同一 tokenId、同一 tick 区间）。
/// 3. 想减仓但不收钱 → `decreaseLiquidity`：从池里 burn 流动性，本金与未结算费用记入 `tokensOwed*`，**此时代币还在池侧待领取**。
/// 4. 把应得 token 提到钱包 → `collect`（可指定 `recipient`）。
/// 5. 流动性与欠款都清零后 → `burn(tokenId)` 销毁 NFT，省 gas 与链上 clutter。
///
/// @dev 继承 `LiquidityManagement` 完成实际 `addLiquidity`；`Position` 里用 `poolId` 映射到 `PoolKey` 以省存储；手续费用 `feeGrowthInside*LastX128` 与 core 同步计算。
///
/// =============================================================================
/// **本合约的 `mint` vs `LiquidityManagement.addLiquidity` vs `IPancakeV3Pool.mint`**
/// =============================================================================
/// - **`NonfungiblePositionManager.mint`（本合约，对外函数）**：用户入口。内部先 **`addLiquidity`**（见 `base/LiquidityManagement.sol`），
///   其中会调用 **`IPancakeV3Pool.mint`** 把流动性写入**池合约**并从用户处收款；再回到本合约 **`_mint` ERC721**，给用户 `tokenId`。
/// - **两个「mint」**：`NPM.mint` = 铸 **NFT**；`Pool.mint` = 在 **AMM 核心池**增加流动性（完全不同的合约、不同的状态）。
/// - **为何必须先池 `mint` 再 NFT `_mint`**：池子要先确认收款与区间有效，NPM 才能根据返回的 `liquidity/amount0/amount1` 发 NFT 并记录 `Position`。
/// 详细逐步说明与示例见 `LiquidityManagement.sol` 文件头注释。
contract NonfungiblePositionManager is
    INonfungiblePositionManager,
    Multicall,
    ERC721Permit,
    PeripheryImmutableState,
    PoolInitializer,
    LiquidityManagement,
    PeripheryValidation,
    SelfPermit
{
    /// @notice 单个 NFT 头寸在合约内的存储结构（与链下「头寸详情」一一对应）。
    struct Position {
        /// @notice EIP-712 / permit 等用的随机数，防重放。
        uint96 nonce;
        /// @notice **单枚 NFT 的授权操作员**（本合约覆写 ERC721 的 `_approve`，用此字段存 approved；与 OpenZeppelin 默认 `_tokenApprovals` 二选一式存储）。
        address operator;
        /// @notice 指向内部池表 `_poolIdToPoolKey`：该头寸属于哪个 (token0, token1, fee) 池。
        uint80 poolId;
        /// @notice 集中流动性下界 tick（价格区间低点）。
        int24 tickLower;
        /// @notice 集中流动性上界 tick（价格区间高点）。
        int24 tickUpper;
        /// @notice 当前头寸在核心池 Position 里占的 **流动性数值**（非代币个数，与 V3 公式一致）。
        uint128 liquidity;
        /// @notice 上次操作时，区间内 token0 的 feeGrowthInside 快照（Q128 定点），用于计算未领取手续费。
        uint256 feeGrowthInside0LastX128;
        /// @notice 同上，token1。
        uint256 feeGrowthInside1LastX128;
        /// @notice 已结算、尚未 `collect` 的 token0 数量（含 decrease 产生的本金与费）。
        uint128 tokensOwed0;
        /// @notice 同上，token1。
        uint128 tokensOwed1;
    }

    /// @notice 池合约地址 → 本合约分配的短 id（避免每个 Position 存完整 PoolKey，省 gas）。
    mapping(address => uint80) private _poolIds;

    /// @notice poolId → (token0, token1, fee)，与核心 `PoolAddress.computeAddress` 一致。
    mapping(uint80 => PoolAddress.PoolKey) private _poolIdToPoolKey;

    /// @notice ERC721 tokenId → 头寸数据。
    mapping(uint256 => Position) private _positions;

    /// @notice 下一枚 NFT 的 id，从 1 起（0 保留无效）。
    uint176 private _nextId = 1;
    /// @notice 下一个未使用的池 id，从 1 起。
    uint80 private _nextPoolId = 1;

    /// @notice 元数据合约：为 `tokenURI` 生成展示用 JSON/图片链接（前端展示头寸信息）。
    address private immutable _tokenDescriptor;

    /// @notice 部署时绑定工厂、WETH、元数据合约等全局配置。
    /// @param _deployer V3 池 CREATE2 部署者地址（与 `PoolAddress.computeAddress` 一致）。
    /// @param _factory Pancake V3 工厂，用于解析池地址。
    /// @param _WETH9 链上 WETH，用于 ETH 路径支付等（见父类 `PeripheryImmutableState`）。
    /// @param _tokenDescriptor_ `INonfungibleTokenPositionDescriptor`，生成 NFT 的 `tokenURI`。
    constructor(
        address _deployer,
        address _factory,
        address _WETH9,
        address _tokenDescriptor_
    ) ERC721Permit('Pancake V3 Positions NFT-V1', 'PCS-V3-POS', '1') PeripheryImmutableState(_deployer, _factory, _WETH9) {
        _tokenDescriptor = _tokenDescriptor_;
    }

    /// @notice 按 tokenId 查询头寸详情（池子币对、费率、区间、流动性、费用快照与待领取欠款）。
    /// @param tokenId 头寸 NFT 编号。
    /// @return nonce 该 NFT 的 permit 随机数。
    /// @return operator 当前 ERC721 授权地址（本合约用 Position.operator 实现）。
    /// @return token0 池子排序后的 token0（地址小于 token1）。
    /// @return token1 池子 token1。
    /// @return fee 池费率档（如 500 = 0.05%，以池子枚举为准）。
    /// @return tickLower 区间下 tick。
    /// @return tickUpper 区间上 tick。
    /// @return liquidity 当前头寸流动性。
    /// @return feeGrowthInside0LastX128 token0 上次快照。
    /// @return feeGrowthInside1LastX128 token1 上次快照。
    /// @return tokensOwed0 待 collect 的 token0。
    /// @return tokensOwed1 待 collect 的 token1。
    /// **使用场景**：前端展示头寸、钱包插件、策略机器人读取区间与待领取费用。
    /// @inheritdoc INonfungiblePositionManager
    function positions(uint256 tokenId)
        external
        view
        override
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Position memory position = _positions[tokenId];
        require(position.poolId != 0, 'Invalid token ID');
        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];
        return (
            position.nonce,
            position.operator,
            poolKey.token0,
            poolKey.token1,
            poolKey.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.tokensOwed0,
            position.tokensOwed1
        );
    }

    /// @notice 首次见到某池地址时分配递增 `poolId` 并写入 `token0/token1/fee`；已存在则直接返回已有 id（幂等）。
    /// @dev **核心逻辑**：同一池多枚 NFT 共用同一 `poolId`，节省每个 Position 的存储。
    /// **使用场景**：`mint` 在 `addLiquidity` 后登记池键。
    function cachePoolKey(address pool, PoolAddress.PoolKey memory poolKey) private returns (uint80 poolId) {
        poolId = _poolIds[pool];
        if (poolId == 0) {
            _poolIds[pool] = (poolId = _nextPoolId++);
            _poolIdToPoolKey[poolId] = poolKey;
        }
    }

    /// @notice **新建头寸并铸造 NFT**：在指定池、指定 tick 区间加入流动性，代币从 `msg.sender` 经 `addLiquidity` 转入池子。
    /// @param params.token0 / token1 / fee 定位唯一池（须已创建且已初始化价格）。
    /// @param params.tickLower / tickUpper 集中流动性区间；若当前价格在区间外，可能只消耗单边代币。
    /// @param params.amount0Desired / amount1Desired 希望投入的最大量；实际按当前价格与区间计算。
    /// @param params.amount0Min / amount1Min 滑点保护：实际投入不得低于此（否则 revert）。
    /// @param params.recipient 新 NFT 的接收地址（可为合约或用户）。
    /// @param params.deadline 交易截止时间（`checkDeadline`）。
    /// @return tokenId 新头寸 NFT id。
    /// @return liquidity 本笔写入池子的流动性数值。
    /// @return amount0 / amount1 实际消耗的 token0/token1 数量。
    /// **核心逻辑**：`addLiquidity`（内部会调 **池** `IPancakeV3Pool.mint` + 回调付款）→ **`_mint` 铸 NFT 给 `params.recipient`** → 读池子 `positions(positionKey)` 初始化 `feeGrowth*` → `cachePoolKey` → 写入 `_positions[tokenId]`。
    /// **使用场景**：用户第一次在某 USDT/BNB 池的 [a,b] 区间做 LP；前端常配合 multicall 与 `selfPermit` 先授权。
    ///
    /// **与 `addLiquidity` 的分工（读代码时对照）**：
    /// - 下面第一行调用的 **`addLiquidity`** 里 `recipient: address(this)`：表示 **池内头寸 owner 是 NPM**，与 Uniswap V3 NPM 一致，这样 `PositionKey.compute(address(this), ticks)` 能唯一定位池子记录。
    /// - 用户在 **`addLiquidity` 作为 `msg.sender`**，经 `MintCallbackData.payer` 在 **`pancakeV3MintCallback`** 里向池付款（用户须已 approve NPM）。
    /// - **`_mint(params.recipient, tokenId)`**：把 **NFT** 发给用户指定的 `params.recipient`（可与付款人不同，例如项目方代建头寸发给多签）。
    /// @inheritdoc INonfungiblePositionManager
    function mint(MintParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        IPancakeV3Pool pool;
        // ① 在核心池增加流动性：内部调用 IPancakeV3Pool.mint，并通过回调从 msg.sender（用户）收款
        (liquidity, amount0, amount1, pool) = addLiquidity(
            AddLiquidityParams({
                token0: params.token0,
                token1: params.token1,
                fee: params.fee,
                recipient: address(this), // 池子 positions 的 owner 为 NPM，非用户 EOA
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min
            })
        );

        // ② 再铸 ERC721：用户拿到的 tokenId 仅代表「NPM 名下那一段流动性」的凭证
        _mint(params.recipient, (tokenId = _nextId++));

        bytes32 positionKey = PositionKey.compute(address(this), params.tickLower, params.tickUpper);
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.positions(positionKey);

        // idempotent set
        uint80 poolId =
            cachePoolKey(
                address(pool),
                PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.fee})
            );

        _positions[tokenId] = Position({
            nonce: 0,
            operator: address(0),
            poolId: poolId,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            feeGrowthInside0LastX128: feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: feeGrowthInside1LastX128,
            tokensOwed0: 0,
            tokensOwed1: 0
        });

        emit IncreaseLiquidity(tokenId, liquidity, amount0, amount1);
    }

    /// @notice 仅允许 NFT 持有人或已 approve 的地址调用（`increaseLiquidity` 无此限制，因谁付钱谁加；`decrease/collect/burn` 需授权）。
    /// @param tokenId 头寸 id。
    modifier isAuthorizedForToken(uint256 tokenId) {
        require(_isApprovedOrOwner(msg.sender, tokenId), 'Not approved');
        _;
    }

    /// @notice 返回 OpenSea 等可读的 metadata URI（由 `_tokenDescriptor` 生成）。
    /// **使用场景**：钱包与浏览器展示头寸 SVG/属性。
    function tokenURI(uint256 tokenId) public view override(ERC721, IERC721Metadata) returns (string memory) {
        require(_exists(tokenId));
        return INonfungibleTokenPositionDescriptor(_tokenDescriptor).tokenURI(this, tokenId);
    }

    /// @notice 本实现不返回 baseURI，元数据由 descriptor 全权生成。
    function baseURI() public pure override returns (string memory) {}

    /// @notice **在已有 NFT 上追加流动性**（区间与池不变），代币由 `msg.sender` 支付。
    /// @param params.tokenId 已有头寸 id。
    /// @param params.amount0Desired / amount1Desired 希望再投入的上限。
    /// @param params.amount0Min / amount1Min 滑点下限。
    /// @param params.deadline 截止时间。
    /// @return liquidity 本次**新增**的流动性数量（非总流动性）。
    /// @return amount0 / amount1 本次实际消耗的 token 量。
    /// **核心逻辑**：先根据 `feeGrowthInside* - 上次快照` 把区间手续费增量算进 `tokensOwed`（在加仓前先结算「欠你的费」），再 `addLiquidity`，更新 `liquidity` 与快照。
    /// **使用场景**：池子成交量大、想加大本区间仓位；**无需**持有人权限（任意人可帮该头寸注资，常见于合约集成时注意）。
    /// @inheritdoc INonfungiblePositionManager
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        Position storage position = _positions[params.tokenId];

        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];

        IPancakeV3Pool pool;
        (liquidity, amount0, amount1, pool) = addLiquidity(
            AddLiquidityParams({
                token0: poolKey.token0,
                token1: poolKey.token1,
                fee: poolKey.fee,
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                recipient: address(this) 
            })
        );

        bytes32 positionKey = PositionKey.compute(address(this), position.tickLower, position.tickUpper);

        // this is now updated to the current transaction
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.positions(positionKey);

        position.tokensOwed0 += uint128(
            FullMath.mulDiv(
                feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128,
                position.liquidity,
                FixedPoint128.Q128
            )
        );
        position.tokensOwed1 += uint128(
            FullMath.mulDiv(
                feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128,
                position.liquidity,
                FixedPoint128.Q128
            )
        );

        position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        position.liquidity += liquidity;

        emit IncreaseLiquidity(params.tokenId, liquidity, amount0, amount1);
    }

    /// @notice **从池子撤出部分流动性**，撤出的 token 记入 `tokensOwed0/1`，需再调 `collect` 提到钱包。
    /// @param params.tokenId 头寸 id。
    /// @param params.liquidity 要 burn 的流动性数量（≤ 当前头寸 liquidity）。
    /// @param params.amount0Min / params.amount1Min `pool.burn` 返回的本金下限（防操纵/滑点）。
    /// @param params.deadline 截止时间。
    /// @return amount0 / amount1 对应 burn 产生、记入待领取的本金数量（与 fee 结算一起进 `tokensOwed`）。
    /// **核心逻辑**：`pool.burn` → 用 feeGrowth 差更新未领取手续费 → 加上 burn 本金 → 减少 `position.liquidity`。
    /// **使用场景**：收窄敞口、价格偏离区间想退出部分；**不**自动转币到用户，必须 `collect`。
    /// **权限**：须 `isAuthorizedForToken`。
    /// @inheritdoc INonfungiblePositionManager
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        override
        isAuthorizedForToken(params.tokenId)
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        require(params.liquidity > 0);
        Position storage position = _positions[params.tokenId];

        uint128 positionLiquidity = position.liquidity;
        require(positionLiquidity >= params.liquidity);

        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];
        IPancakeV3Pool pool = IPancakeV3Pool(PoolAddress.computeAddress(deployer, poolKey));
        (amount0, amount1) = pool.burn(position.tickLower, position.tickUpper, params.liquidity);

        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, 'Price slippage check');

        bytes32 positionKey = PositionKey.compute(address(this), position.tickLower, position.tickUpper);
        // this is now updated to the current transaction
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = pool.positions(positionKey);

        position.tokensOwed0 +=
            uint128(amount0) +
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128,
                    positionLiquidity,
                    FixedPoint128.Q128
                )
            );
        position.tokensOwed1 +=
            uint128(amount1) +
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128,
                    positionLiquidity,
                    FixedPoint128.Q128
                )
            );

        position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        // subtraction is safe because we checked positionLiquidity is gte params.liquidity
        position.liquidity = positionLiquidity - params.liquidity;

        emit DecreaseLiquidity(params.tokenId, params.liquidity, amount0, amount1);
    }

    /// @notice 把 `tokensOwed` 与最新手续费从池子 **领取** 到 `recipient`（可部分领取，由 `amount*Max` 限制）。
    /// @param params.tokenId 头寸 id。
    /// @param params.recipient 收款地址；若为 `address(0)` 则领到本合约（便于后续路由）。
    /// @param params.amount0Max / amount1Max 各代币最多领取上限（常用 type(uint128).max 全领）。
    /// @return amount0 / amount1 实际从池 `collect` 转出到 recipient 的量（可能因整除略小于 owed）。
    /// **核心逻辑**：若仍有 liquidity，先 `burn(..., 0)` 触发手续费更新；累加 `tokensOwed`；再 `pool.collect` 转币并扣减本地 `tokensOwed`。
    /// **使用场景**：定期把手续费与 decrease 本金提到钱包；协议方收款到金库地址。
    /// **权限**：须 `isAuthorizedForToken`。
    /// @inheritdoc INonfungiblePositionManager
    function collect(CollectParams calldata params)
        external
        payable
        override
        isAuthorizedForToken(params.tokenId)
        returns (uint256 amount0, uint256 amount1)
    {
        require(params.amount0Max > 0 || params.amount1Max > 0);
        // allow collecting to the nft position manager address with address 0
        address recipient = params.recipient == address(0) ? address(this) : params.recipient;

        Position storage position = _positions[params.tokenId];

        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];

        IPancakeV3Pool pool = IPancakeV3Pool(PoolAddress.computeAddress(deployer, poolKey));

        (uint128 tokensOwed0, uint128 tokensOwed1) = (position.tokensOwed0, position.tokensOwed1);

        // trigger an update of the position fees owed and fee growth snapshots if it has any liquidity
        if (position.liquidity > 0) {
            pool.burn(position.tickLower, position.tickUpper, 0);
            (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) =
                pool.positions(PositionKey.compute(address(this), position.tickLower, position.tickUpper));

            tokensOwed0 += uint128(
                FullMath.mulDiv(
                    feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128,
                    position.liquidity,
                    FixedPoint128.Q128
                )
            );
            tokensOwed1 += uint128(
                FullMath.mulDiv(
                    feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128,
                    position.liquidity,
                    FixedPoint128.Q128
                )
            );

            position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
            position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        }

        // compute the arguments to give to the pool#collect method
        (uint128 amount0Collect, uint128 amount1Collect) =
            (
                params.amount0Max > tokensOwed0 ? tokensOwed0 : params.amount0Max,
                params.amount1Max > tokensOwed1 ? tokensOwed1 : params.amount1Max
            );

        // the actual amounts collected are returned
        (amount0, amount1) = pool.collect(
            recipient,
            position.tickLower,
            position.tickUpper,
            amount0Collect,
            amount1Collect
        );

        // sometimes there will be a few less wei than expected due to rounding down in core, but we just subtract the full amount expected
        // instead of the actual amount so we can burn the token
        (position.tokensOwed0, position.tokensOwed1) = (tokensOwed0 - amount0Collect, tokensOwed1 - amount1Collect);

        emit Collect(params.tokenId, recipient, amount0Collect, amount1Collect);
    }

    /// @notice **销毁 NFT**：仅当流动性为 0 且 `tokensOwed` 均为 0（即已 `collect` 干净）。
    /// @param tokenId 要销毁的头寸 id。
    /// **使用场景**：完全退出该区间头寸后清理链上记录；避免遗留空 NFT。
    /// **权限**：须 `isAuthorizedForToken`。
    /// @inheritdoc INonfungiblePositionManager
    function burn(uint256 tokenId) external payable override isAuthorizedForToken(tokenId) {
        Position storage position = _positions[tokenId];
        require(position.liquidity == 0 && position.tokensOwed0 == 0 && position.tokensOwed1 == 0, 'Not cleared');
        delete _positions[tokenId];
        _burn(tokenId);
    }

    /// @notice `ERC721Permit` 用：读取并递增 `Position.nonce`，使每次 permit 签名唯一。
    function _getAndIncrementNonce(uint256 tokenId) internal override returns (uint256) {
        return uint256(_positions[tokenId].nonce++);
    }

    /// @notice 返回单枚 NFT 的 approved 地址（本合约用 `Position.operator` 存储，与标准 ERC721 行为一致）。
    /// @inheritdoc IERC721
    function getApproved(uint256 tokenId) public view override(ERC721, IERC721) returns (address) {
        require(_exists(tokenId), 'ERC721: approved query for nonexistent token');

        return _positions[tokenId].operator;
    }

    /// @notice 将 ERC721 的 approve 写入 `Position.operator`，与 `nonce` 同槽打包，节省存储。
    function _approve(address to, uint256 tokenId) internal override(ERC721) {
        _positions[tokenId].operator = to;
        emit Approval(ownerOf(tokenId), to, tokenId);
    }
}
