// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import './BlockTimestamp.sol';

/// @title PeripheryValidation —— 交易截止时间校验
/// @notice 与 `block.timestamp`（经 `_blockTimestamp`）比较，防止用户签名或 mempool 里的交易在很久以后才上链导致价格偏离。
///
/// **使用场景**：`mint` / `increaseLiquidity` / `decreaseLiquidity` 等带 `deadline` 参数的函数；用户在前端选「5 分钟内有效」。
abstract contract PeripheryValidation is BlockTimestamp {
    /// @notice 要求当前时间 ≤ `deadline`，否则 revert `Transaction too old`。
    /// @param deadline Unix 时间戳（秒）。
    modifier checkDeadline(uint256 deadline) {
        require(_blockTimestamp() <= deadline, 'Transaction too old');
        _;
    }
}
