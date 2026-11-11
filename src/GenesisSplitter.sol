// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

interface ILpDeskForSplitter {
    function token() external view returns (address);
    function registered() external view returns (bool);
}

/// @notice Receives 600,000,000 NOTSTOCK from the project wallet after launch and, once PriceGuard has
/// registered NOTSTOCK, splits its whole balance once: 50/60 to LpDesk, 10/60 to the dev wallet.
contract GenesisSplitter {
    address public immutable lpDesk;
    address public immutable devWallet;
    bool public split_;

    event Split(uint256 toLpDesk, uint256 toDev);

    error AlreadySplit();
    error NotRegistered();
    error NothingToSplit();
    error TransferFailed();

    constructor(address lpDesk_, address devWallet_) {
        lpDesk = lpDesk_;
        devWallet = devWallet_;
    }

    /// @notice Callable once by anyone. Sends 50/60 of the balance to LpDesk and the rest (10/60) to the dev wallet.
    function split() external {
        if (split_) revert AlreadySplit();
        if (!ILpDeskForSplitter(lpDesk).registered()) revert NotRegistered();
        IERC20 token = IERC20(ILpDeskForSplitter(lpDesk).token());
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert NothingToSplit();
        split_ = true;
        uint256 toLpDesk = balance * 50 / 60;
        uint256 toDev = balance - toLpDesk;
        if (!token.transfer(lpDesk, toLpDesk)) revert TransferFailed();
        if (!token.transfer(devWallet, toDev)) revert TransferFailed();
        emit Split(toLpDesk, toDev);
    }

    function hasSplit() external view returns (bool) {
        return split_;
    }
}
