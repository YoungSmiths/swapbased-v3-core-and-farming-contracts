// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import './interfaces/IPancakeV3PoolDeployer.sol';

import './PancakeV3Pool.sol';

contract PancakeV3PoolDeployer is IPancakeV3PoolDeployer {
    // 参数集合：用于在部署 PancakeV3Pool 时临时保存所需参数，部署完成后清除。
    // 示例：在调用 deploy 时，将 factory/token0/token1/fee/tickSpacing 写入该结构，之后通过 salt 生成合约地址并完成部署。
    struct Parameters {
        address factory;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
    }

    /// @inheritdoc IPancakeV3PoolDeployer
    Parameters public override parameters;

    address public factoryAddress;

    /// @notice Factory address set by setFactoryAddress
    /// @dev Initializes the deployer with the authoritative factory address. Once set, it cannot be changed.
    event SetFactoryAddress(address indexed factory);

    modifier onlyFactory() {
        require(msg.sender == factoryAddress, "only factory can call deploy");
        _;
    }

    function setFactoryAddress(address _factoryAddress) external {
        require(factoryAddress == address(0), "already initialized");

        factoryAddress = _factoryAddress;

        emit SetFactoryAddress(_factoryAddress);
    }

    /// @dev 部署一个池子，过程为：在参数存储中临时写入参数，然后通过盐创建 PancakeV3Pool 实例，部署完成后清空参数存储。
    /// @param factory PancakeSwap V3 工厂合约地址
    /// @param token0 按地址排序的第一个代币地址
    /// @param token1 按地址排序的第二个代币地址
    /// @param fee 池子交易费率，单位为百分之一百比（bps 的单位，示例：3000 表示 0.30%）
    /// @param tickSpacing 可用刻度之间的间距
    function deploy(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing
    ) external override onlyFactory returns (address pool) {
        parameters = Parameters({factory: factory, token0: token0, token1: token1, fee: fee, tickSpacing: tickSpacing});
        pool = address(new PancakeV3Pool{salt: keccak256(abi.encode(token0, token1, fee))}());
        delete parameters;
    }
}
