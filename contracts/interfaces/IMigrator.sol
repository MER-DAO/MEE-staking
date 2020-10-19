// SPDX-License-Identifier: SimPL-2.0
pragma solidity >=0.5.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMigrator {
    function migrate(IERC20 token) external returns (IERC20);
}