pragma solidity ^0.6.12;

interface IAward {

    function addFreeAward(address _user, uint256 _amount) external;

    function addAward(address _user, uint256 _amount) external;

    function withdraw(uint256 _amount) external;

    function destroy(uint256 amount) external;
}
