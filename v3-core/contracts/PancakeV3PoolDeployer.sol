// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import './interfaces/IPancakeV3PoolDeployer.sol';

import './PancakeV3Pool.sol';

/// @title PancakeV3PoolDeployer —— 用 CREATE2 **确定性地址**部署单口 `PancakeV3Pool`
/// @notice 与 Uniswap V3 同构：**池构造函数无参**，部署时在 `constructor()` 内通过 `IPancakeV3PoolDeployer(msg.sender).parameters()` 读取本合约临时写入的 `factory/token0/token1/fee/tickSpacing`，部署结束 `delete parameters`。
///
/// **为何单独 Deployer**：保证 `new PancakeV3Pool{salt: keccak256(token0,token1,fee)}` 与外围 **`PoolAddress.computeAddress(deployer, poolKey)`** 算出的地址一致，Router/NPM 可离线预测池地址。
///
/// **实例**：`createPool(USDT,WBNB,2500)` → Factory 调 `deploy(...)` → 新池部署完成 → 需再 **`initialize(sqrtPriceX96)`** 才能交易。
contract PancakeV3PoolDeployer is IPancakeV3PoolDeployer {
    /// @notice 仅 `deploy` 执行期间有效；供 `PancakeV3Pool` 构造函数读取一次。
    struct Parameters {
        address factory;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
    }

    /// @inheritdoc IPancakeV3PoolDeployer
    Parameters public override parameters;

    /// @notice 唯一有权调用 `deploy` 的 Factory；`setFactoryAddress` 仅允许设一次。
    address public factoryAddress;

    /// @notice Factory 地址完成绑定时触发。
    event SetFactoryAddress(address indexed factory);

    modifier onlyFactory() {
        require(msg.sender == factoryAddress, "only factory can call deploy");
        _;
    }

    /// @notice 登记唯一 Factory；若已设置则 revert。
    /// @param _factoryAddress `PancakeV3Factory` 地址。
    /// **使用场景**：部署顺序一般为 Deployer → Factory(constructor 传入本 Deployer 地址) → **本函数**绑定 Factory → 之后仅该 Factory 可 `deploy`。
    function setFactoryAddress(address _factoryAddress) external {
        require(factoryAddress == address(0), "already initialized");

        factoryAddress = _factoryAddress;

        emit SetFactoryAddress(_factoryAddress);
    }

    /// @notice 部署一口新池并返回其地址；**仅 Factory** 会调用（见 `onlyFactory`）。
    /// @param factory Factory 自身地址（写入池子不可变 `factory`）
    /// @param token0 已排序的小地址
    /// @param token1 已排序的大地址
    /// @param fee 费率档（须与 Factory 已启用的档位一致）
    /// @param tickSpacing 该档对应的 tick 间距（Factory 从 `feeAmountTickSpacing[fee]` 传入）
    /// @return pool 新部署的 `PancakeV3Pool` 地址（CREATE2，salt = `keccak256(abi.encode(token0, token1, fee))`）。
    /// **核心逻辑**：`parameters` 临时赋值 → `new PancakeV3Pool{salt:...}` → `delete parameters`。
    /// **部署后下一步**：池子 `sqrtPriceX96==0`，需 **`initialize(sqrtPriceX96)`**（通常由外围 `createAndInitializePoolIfNecessary` 或首笔初始化交易）后才能 `swap`/`mint`。
    function deploy(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing
    ) external override onlyFactory returns (address pool) {
        // 写入临时存储，供即将创建的 PancakeV3Pool 构造函数读取
        parameters = Parameters({factory: factory, token0: token0, token1: token1, fee: fee, tickSpacing: tickSpacing});
        // CREATE2：salt 仅含 (token0,token1,fee)，与 periphery PoolAddress 规则一致
        pool = address(new PancakeV3Pool{salt: keccak256(abi.encode(token0, token1, fee))}());
        // 释放存储，避免下次 deploy 误用旧参数
        delete parameters;
    }
}
