// SPDX-License-Identifier: SimPL-2.0
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IMigrator.sol";
import "./interfaces/IAward.sol";

contract LPStaking is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        uint256 lockRewards;    // 90% lock rewards when not migrated
        uint256 stakeBlocks;    // number of blocks containing staking;
        uint256 lastBlock;      // the last block.number when update shares;
        uint256 accStakeShares; // accumulate stakes: ∑(amount * stakeBlocks);
        // Basically, any point in time, the amount of ETF
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accEtfPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accEtfPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. ETF to distribute per block.
        uint256 lastRewardBlock;  // Last block number that ETF distribution occurs.
        uint256 accEtfPerShare; // Accumulated ETF per share, times 1e12. See below.
    }

    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigrator public migrator;
    // ETF tokens created per block.
    uint256 public etfPerBlock = 755 * 10 ** 16;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    bool public migrated;
    IAward award;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        IAward _award,
        uint256 _etfPerBlock,
        uint256 _startBlock,
        uint256 _endBlock
    ) public {
        award = _award;
        etfPerBlock = _etfPerBlock;
        startBlock = _startBlock;
        endBlock = _endBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            batchUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken : _lpToken,
            allocPoint : _allocPoint,
            lastRewardBlock : lastRewardBlock,
            accEtfPerShare : 0
            }));
    }

    // Update the given pool's ETF allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            batchUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigrator _migrator) public onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    function setMigrated() onlyOwner public{
        migrated = true;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) private view returns (uint256) {
        if (_to <= endBlock) {
            return _to.sub(_from);
        } else if (_from >= endBlock) {
            return 0;
        } else {
            return endBlock.sub(_from);
        }
    }

    // View function to see pending ETF on frontend.
    function pendingETF(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accEtfPerShare = pool.accEtfPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 etfReward = multiplier.mul(etfPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accEtfPerShare = accEtfPerShare.add(etfReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accEtfPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function batchUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 etfReward = multiplier.mul(etfPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        pool.accEtfPerShare = pool.accEtfPerShare.add(etfReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    function shareAwards(uint256 _pid) private {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        uint256 pending = 0;
        if (user.amount > 0) {
            pending = user.amount.mul(pool.accEtfPerShare).div(1e12).sub(user.rewardDebt);

            uint256 num = block.number - user.lastBlock;
            user.stakeBlocks = user.stakeBlocks.add(num);
            user.accStakeShares = user.accStakeShares.add(user.amount.mul(num));
        }
        if (migrated) {
            uint256 locked = user.lockRewards.add(pending);
            user.lockRewards = 0;
            uint256 audit = user.stakeBlocks.mul(user.amount);
            if (user.accStakeShares > audit) {
                uint256 _locked = locked.mul(audit).div(user.accStakeShares);
                award.destroy(locked.sub(_locked));
                locked = _locked;
            }
            if (locked > 0) {
                award.addAward(msg.sender, locked);
            }
        } else {
            user.lockRewards = user.lockRewards.add(pending);
        }
    }

    // Deposit LP tokens to Staking for ETF allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        shareAwards(_pid);
        pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accEtfPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from LPStaking.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        shareAwards(_pid);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accEtfPerShare).div(1e12);
        user.lastBlock = block.number;
        pool.lpToken.safeTransfer(msg.sender, _amount);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(msg.sender, user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }
}