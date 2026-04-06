// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/drafts/IERC20Permit.sol';

import '../interfaces/ISelfPermit.sol';
import '../interfaces/external/IERC20PermitAllowed.sol';

/// @title Self Permit —— 在路由合约内代用户调用 ERC20 `permit`
/// @notice 与 `Multicall` 搭配：同一笔交易里先 `selfPermit` 再 `swap`/`mint`，EOA 无需先发 `approve`。
///
/// **形象理解**：用户签好 EIP-2612 授权本合约花他的 USDT，交易里第一条调 `selfPermit`，第二条调需要 `transferFrom` 的函数。
///
/// **注意**：`DAI` 等旧式 `permit` 用 `selfPermitAllowed`（`IERC20PermitAllowed`）。
abstract contract SelfPermit is ISelfPermit {
    /// @notice 调用 `token.permit(msg.sender, address(this), value, deadline, v, r, s)`。
    /// @param token 支持 EIP-2612 的 ERC20。
    /// @param value 授权额度。
    /// @param deadline permit 截止时间。
    /// **使用场景**：NPM `multicall` 里先于 `mint` 授权代币。
    /// @inheritdoc ISelfPermit
    function selfPermit(
        address token,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public payable override {
        IERC20Permit(token).permit(msg.sender, address(this), value, deadline, v, r, s);
    }

    /// @notice 若当前 allowance 已 ≥ `value` 则跳过；否则执行与 `selfPermit` 相同（省 gas、兼容重复 multicall）。
    /// @inheritdoc ISelfPermit
    function selfPermitIfNecessary(
        address token,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable override {
        if (IERC20(token).allowance(msg.sender, address(this)) < value) selfPermit(token, value, deadline, v, r, s);
    }

    /// @notice 兼容 **Permit Allowed**（nonce/expiry 模型）的代币，如 DAI 风格。
    /// @inheritdoc ISelfPermit
    function selfPermitAllowed(
        address token,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public payable override {
        IERC20PermitAllowed(token).permit(msg.sender, address(this), nonce, expiry, true, v, r, s);
    }

    /// @notice 对 Permit Allowed：若 allowance 已是 `type(uint256).max` 则跳过，否则 `selfPermitAllowed`。
    /// @inheritdoc ISelfPermit
    function selfPermitAllowedIfNecessary(
        address token,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable override {
        if (IERC20(token).allowance(msg.sender, address(this)) < type(uint256).max)
            selfPermitAllowed(token, nonce, expiry, v, r, s);
    }
}
