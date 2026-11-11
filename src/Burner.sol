// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

interface ILpDeskToken {
    function token() external view returns (address);
}

/// @notice Created by LpDesk's constructor. Holds NOTSTOCK sent to it by plain transfers until
/// anyone calls burn(), which sends its whole NOTSTOCK balance to the dead address.
contract Burner {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public immutable lpDesk;

    event Burned(uint256 amount);

    error NothingToBurn();
    error TransferFailed();

    constructor(address lpDesk_) {
        lpDesk = lpDesk_;
    }

    /// @notice Sends the whole NOTSTOCK balance to the dead address. Reverts on a zero balance.
    function burn() external {
        IERC20 token = IERC20(ILpDeskToken(lpDesk).token());
        uint256 amount = token.balanceOf(address(this));
        if (amount == 0) revert NothingToBurn();
        if (!token.transfer(DEAD, amount)) revert TransferFailed();
        emit Burned(amount);
    }
}
