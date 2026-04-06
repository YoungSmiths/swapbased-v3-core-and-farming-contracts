// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.5;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import '../interfaces/IPeripheryPayments.sol';
import '../interfaces/external/IWETH9.sol';

import '../libraries/TransferHelper.sol';

import './PeripheryImmutableState.sol';

/// @title PeripheryPayments —— WETH 解包、代币扫仓、ETH 退款与内部支付
/// @notice 与核心池交互时，本合约可能暂存 WETH/ERC20；本模块负责 unwrap、把余额打给 `recipient`，以及 `pay` 三种付款路径。
///
/// **形象理解**：`pay` 像收银台——要么用户用 ETH 经 WETH 包装后付给池子，要么从合约余额转，要么 `transferFrom` 用户。
abstract contract PeripheryPayments is IPeripheryPayments, PeripheryImmutableState {
    /// @notice 仅允许 WETH 合约向本合约转 ETH（unwrap 时 WETH 会先打 ETH 过来）。
    receive() external payable {
        require(msg.sender == WETH9, 'Not WETH9');
    }

    /// @notice 将本合约持有的 WETH 全部 unwrap 成 ETH 并转给 `recipient`（常用于 swap 结束后领 ETH）。
    /// @param amountMinimum 余额下限，防止几乎没收到 WETH 仍 unwrap。
    /// @param recipient ETH 接收方。
    /// @inheritdoc IPeripheryPayments
    function unwrapWETH9(uint256 amountMinimum, address recipient) public payable override {
        uint256 balanceWETH9 = IWETH9(WETH9).balanceOf(address(this));
        require(balanceWETH9 >= amountMinimum, 'Insufficient WETH9');

        if (balanceWETH9 > 0) {
            IWETH9(WETH9).withdraw(balanceWETH9);
            TransferHelper.safeTransferETH(recipient, balanceWETH9);
        }
    }

    /// @notice 把本合约持有的某 ERC20 **全部**转给 `recipient`（清余额，防灰尘锁在合约里）。
    /// @param token 代币合约。
    /// @param amountMinimum 余额下限。
    /// @param recipient 收款地址。
    /// **使用场景**：多跳 swap 后合约里剩一点 token，用户 `sweepToken` 收回。
    /// @inheritdoc IPeripheryPayments
    function sweepToken(
        address token,
        uint256 amountMinimum,
        address recipient
    ) public payable override {
        uint256 balanceToken = IERC20(token).balanceOf(address(this));
        require(balanceToken >= amountMinimum, 'Insufficient token');

        if (balanceToken > 0) {
            TransferHelper.safeTransfer(token, recipient, balanceToken);
        }
    }

    /// @notice 把本合约全部 ETH 余额退给 `msg.sender`（用户多付了 ETH 时领回）。
    /// @inheritdoc IPeripheryPayments
    function refundETH() external payable override {
        if (address(this).balance > 0) TransferHelper.safeTransferETH(msg.sender, address(this).balance);
    }

    /// @notice 内部支付：优先用本合约已有 ETH 换 WETH 付款；否则用合约内 token；否则从 `payer` 拉取。
    /// @param token 支付的 ERC20 地址（WETH9 表示可经 deposit 包装）。
    /// @param payer 付款人（常为 `msg.sender`）。
    /// @param recipient 收款方（常为池子）。
    /// @param value 数量。
    /// **核心逻辑**：`token == WETH9` 且合约 ETH 够 → `deposit` + `transfer`；`payer == this` → 从合约转；否则 `transferFrom(payer, recipient, value)`。
    /// **使用场景**：`pancakeV3MintCallback` 里向池子支付 owed0/owed1。
    function pay(
        address token,
        address payer,
        address recipient,
        uint256 value
    ) internal {
        if (token == WETH9 && address(this).balance >= value) {
            // pay with WETH9
            IWETH9(WETH9).deposit{value: value}(); // wrap only what is needed to pay
            IWETH9(WETH9).transfer(recipient, value);
        } else if (payer == address(this)) {
            // pay with tokens already in the contract (for the exact input multihop case)
            TransferHelper.safeTransfer(token, recipient, value);
        } else {
            // pull payment
            TransferHelper.safeTransferFrom(token, payer, recipient, value);
        }
    }
}
