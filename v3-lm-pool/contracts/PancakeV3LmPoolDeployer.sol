// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import '@pancakeswap/v3-core/contracts/interfaces/IPancakeV3Factory.sol';
import '@pancakeswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';

import './PancakeV3LmPool.sol';

/// @title PancakeV3LmPoolDeployer
/// @notice Deploys one `PancakeV3LmPool` per V3 pool when MasterChef registers a farm, then wires it on the core factory via `setLmPool`.
/// @dev Kept separate from MasterChef because Solidity 0.7 (LM pool) and 0.8 (MasterChef) cannot live in one contract cleanly.
contract PancakeV3LmPoolDeployer {
    address public immutable masterChef;

    modifier onlyMasterChef() {
        require(msg.sender == masterChef, "Not MC");
        _;
    }

    constructor(address _masterChef) {
        masterChef = _masterChef;
    }

    /// @notice Deploys a new LM pool and registers it on `PancakeV3Factory` so the canonical pool invokes LM hooks during swaps.
    /// @param pool The V3 pool that will own this LM ledger
    function deploy(IPancakeV3Pool pool) external onlyMasterChef returns (IPancakeV3LmPool lmPool) {
        lmPool = new PancakeV3LmPool(address(pool), masterChef, uint32(block.timestamp));
        IPancakeV3Factory(INonfungiblePositionManager(IMasterChefV3(masterChef).nonfungiblePositionManager()).factory()).setLmPool(address(pool), address(lmPool));
    }
}
