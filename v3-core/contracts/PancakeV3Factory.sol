// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import './interfaces/IPancakeV3Factory.sol';
import "./interfaces/IPancakeV3PoolDeployer.sol";
import './interfaces/IPancakeV3Pool.sol';

/// @title PancakeV3Factory —— V3 池工厂：创建池、费率档、协议费与 LmPool 绑定
/// @notice 通过 **`createPool(tokenA, tokenB, fee)`** 部署唯一 `(token0, token1, fee)` 池；实体由 **`PancakeV3PoolDeployer.deploy`** CREATE2 创建。部署后需 **`initialize(sqrtPriceX96)`** 才能 swap（见 periphery `PoolInitializer`）。
/// **实例**：项目方为用户常用 USDT/WBNB 开 0.25% 池 → `createPool(USDT, WBNB, 2500)` → 得到 `pool` 地址 → 前端引导首次 `initialize` 定价。
/// **本仓库增量**：`setLmPool` / `lmPoolDeployer` 用于把 **PancakeV3LmPool** 挂到核心池，使交易时累计农场奖励。
contract PancakeV3Factory is IPancakeV3Factory {
    /// @inheritdoc IPancakeV3Factory
    /// @notice 工厂管理员；可转移 `setOwner`。
    address public override owner;

    /// @notice 不可变：`PancakeV3PoolDeployer` 地址；与 NPM/Router 的 `deployer` 一致才能算准池地址。
    address public immutable poolDeployer;

    /// @inheritdoc IPancakeV3Factory
    /// @notice 费率档 → tickSpacing；**为 0 表示未配置**，`createPool` 会失败。
    mapping(uint24 => int24) public override feeAmountTickSpacing;
    /// @inheritdoc IPancakeV3Factory
    /// @notice 双向索引池地址，避免调用方比较 token 顺序。
    mapping(address => mapping(address => mapping(uint24 => address))) public override getPool;
    /// @inheritdoc IPancakeV3Factory
    /// @notice 某档是否启用、是否仅限白名单创建。
    mapping(uint24 => TickSpacingExtraInfo) public override feeAmountTickSpacingExtraInfo;
    /// @notice `whitelistRequested` 为 true 时，仅此处为 true 的地址可创建该档池子。
    mapping(address => bool) private _whiteListAddresses;

    /// @notice 与 owner 一同可 `setLmPool`（通常为 `PancakeV3LmPoolDeployer`）。
    address public lmPoolDeployer;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyOwnerOrLmPoolDeployer() {
        require(msg.sender == owner || msg.sender == lmPoolDeployer, "Not owner or LM pool deployer");
        _;
    }

    /// @param _poolDeployer 已部署的 `PancakeV3PoolDeployer`；随后需 **`Deployer.setFactoryAddress(factory)`** 完成握手。
    constructor(address _poolDeployer) {
        poolDeployer = _poolDeployer;
        owner = msg.sender;
        emit OwnerChanged(address(0), msg.sender);

        feeAmountTickSpacing[100] = 1;
        feeAmountTickSpacingExtraInfo[100] = TickSpacingExtraInfo({whitelistRequested: false, enabled: true});
        emit FeeAmountEnabled(100, 1);
        emit FeeAmountExtraInfoUpdated(100, false, true);
        feeAmountTickSpacing[500] = 10;
        feeAmountTickSpacingExtraInfo[500] = TickSpacingExtraInfo({whitelistRequested: false, enabled: true});
        emit FeeAmountEnabled(500, 10);
        emit FeeAmountExtraInfoUpdated(500, false, true);
        feeAmountTickSpacing[2500] = 50;
        feeAmountTickSpacingExtraInfo[2500] = TickSpacingExtraInfo({whitelistRequested: false, enabled: true});
        emit FeeAmountEnabled(2500, 50);
        emit FeeAmountExtraInfoUpdated(2500, false, true);
        feeAmountTickSpacing[10000] = 200;
        feeAmountTickSpacingExtraInfo[10000] = TickSpacingExtraInfo({whitelistRequested: false, enabled: true});
        emit FeeAmountEnabled(10000, 200);
        emit FeeAmountExtraInfoUpdated(10000, false, true);
    }

    /// @notice 创建 `(token0, token1, fee)` 池；若已存在则 revert。
    /// @param tokenA / tokenB 任意顺序，内部会排序为 token0 < token1。
    /// @param fee 须为已启用且 `feeAmountTickSpacingExtraInfo[fee].enabled` 的档位。
    /// @return pool 新池地址；**尚未 initialize 时不能交易**。
    /// **核心逻辑**：校验费率与白名单 → `poolDeployer.deploy` → 写入 `getPool` 双向映射 → `PoolCreated`。
    /// **使用场景**：上新交易对、为新费率档开池。
    /// @inheritdoc IPancakeV3Factory
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external override returns (address pool) {
        require(tokenA != tokenB);
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0));
        int24 tickSpacing = feeAmountTickSpacing[fee];
        TickSpacingExtraInfo memory info = feeAmountTickSpacingExtraInfo[fee];
        require(tickSpacing != 0 && info.enabled, "fee is not available yet");
        if (info.whitelistRequested) {
            require(_whiteListAddresses[msg.sender], "user should be in the white list for this fee tier");
        }
        require(getPool[token0][token1][fee] == address(0));
        pool = IPancakeV3PoolDeployer(poolDeployer).deploy(address(this), token0, token1, fee, tickSpacing);
        getPool[token0][token1][fee] = pool;
        // populate mapping in the reverse direction, deliberate choice to avoid the cost of comparing addresses
        getPool[token1][token0][fee] = pool;
        emit PoolCreated(token0, token1, fee, tickSpacing, pool);
    }

    /// @notice 转移工厂所有权（管理员权限）。
    /// @inheritdoc IPancakeV3Factory
    function setOwner(address _owner) external override onlyOwner {
        emit OwnerChanged(owner, _owner);
        owner = _owner;
    }

    /// @notice 新增一种 **fee ↔ tickSpacing** 组合（如自定义万分之一费率）；须不与已有 fee 冲突。
    /// **使用场景**：协议升级支持更多档位；配合前端展示新费率池。
    /// @inheritdoc IPancakeV3Factory
    function enableFeeAmount(uint24 fee, int24 tickSpacing) public override onlyOwner {
        require(fee < 1000000);
        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        require(tickSpacing > 0 && tickSpacing < 16384);
        require(feeAmountTickSpacing[fee] == 0);

        feeAmountTickSpacing[fee] = tickSpacing;
        feeAmountTickSpacingExtraInfo[fee] = TickSpacingExtraInfo({whitelistRequested: false, enabled: true});
        emit FeeAmountEnabled(fee, tickSpacing);
        emit FeeAmountExtraInfoUpdated(fee, false, true);
    }

    /// @notice 设置某地址是否在白名单（当某 fee 档 `whitelistRequested` 时使用）。
    /// @inheritdoc IPancakeV3Factory
    function setWhiteListAddress(address user, bool verified) public override onlyOwner {
        require(_whiteListAddresses[user] != verified, "state not change");
        _whiteListAddresses[user] = verified;

        emit WhiteListAdded(user, verified);
    }

    /// @notice 开关某费率档、或要求仅白名单可 `createPool` 该档。
    /// **实例**：临时关闭某档新池创建 `enabled=false`；或对机构开放专用档位 `whitelistRequested=true`。
    /// @inheritdoc IPancakeV3Factory
    function setFeeAmountExtraInfo(
        uint24 fee,
        bool whitelistRequested,
        bool enabled
    ) public override onlyOwner {
        require(feeAmountTickSpacing[fee] != 0);

        feeAmountTickSpacingExtraInfo[fee] = TickSpacingExtraInfo({
            whitelistRequested: whitelistRequested,
            enabled: enabled
        });
        emit FeeAmountExtraInfoUpdated(fee, whitelistRequested, enabled);
    }

    /// @notice 登记可协助绑定 LmPool 的部署器地址（除 owner 外唯一可 `setLmPool` 的一方）。
    /// **使用场景**：`MasterChef` 侧 `add` 矿池时由 `PancakeV3LmPoolDeployer` 部署 LmPool 并需 `setLmPool`。
    /// @inheritdoc IPancakeV3Factory
    function setLmPoolDeployer(address _lmPoolDeployer) external override onlyOwner {
        lmPoolDeployer = _lmPoolDeployer;
        emit SetLmPoolDeployer(_lmPoolDeployer);
    }

    /// @notice 代池子设置**协议费分成**（转发到 `IPancakeV3Pool.setFeeProtocol`）。
    /// @param pool 目标池地址。
    /// **使用场景**：国库调整从交易费中抽成比例。
    function setFeeProtocol(address pool, uint32 feeProtocol0, uint32 feeProtocol1) external override onlyOwner {
        IPancakeV3Pool(pool).setFeeProtocol(feeProtocol0, feeProtocol1);
    }

    /// @notice 从指定池提取累积的**协议费**到 `recipient`（池内 `protocolFees`）。
    /// **使用场景**：定期将协议分成转入金库多签。
    function collectProtocol(
        address pool,
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override onlyOwner returns (uint128 amount0, uint128 amount1) {
        return IPancakeV3Pool(pool).collectProtocol(recipient, amount0Requested, amount1Requested);
    }

    /// @notice 把 **PancakeV3LmPool** 绑定到指定核心池；之后该池 `swap` 会同步累计挖矿状态。
    /// @param pool 已部署的 `PancakeV3Pool`。
    /// @param lmPool 对应 LmPool 合约地址。
    /// **权限**：仅 **owner** 或 **`lmPoolDeployer`**（防用户随意绑恶意合约）。
    /// **使用场景**：新矿池上线前，由部署流程完成 Factory → Pool.setLmPool。
    /// @inheritdoc IPancakeV3Factory
    function setLmPool(address pool, address lmPool) external override onlyOwnerOrLmPoolDeployer {
        IPancakeV3Pool(pool).setLmPool(lmPool);
    }
}
