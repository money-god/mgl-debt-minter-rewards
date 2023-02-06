pragma solidity 0.6.7;

abstract contract TokenLike {
    function balanceOf(address) virtual public view returns (uint256);
    function transfer(address, uint256) virtual external returns (bool);
}
abstract contract RewardDripperLike {
    function dripReward(address) virtual external;
    function rewardPerBlock() virtual external view returns (uint256);
    function rewardToken() virtual external view returns (TokenLike);
}

// Stores tokens, owned by DebtRewards
contract TokenPool {
    TokenLike public immutable token;
    address   public immutable owner;

    constructor(address token_) public {
        token = TokenLike(token_);
        owner = msg.sender;
    }

    // @notice Transfers tokens from the pool (callable by owner only)
    function transfer(address to, uint256 wad) public {
        require(msg.sender == owner, "unauthorized");
        require(token.transfer(to, wad), "TokenPool/failed-transfer");
    }

    // @notice Returns token balance of the pool
    function balance() public view returns (uint256) {
        return token.balanceOf(address(this));
    }
}

// @notice Do not use tokens with transfer callbacks with this contract
contract DebtRewards {
    // Staked Supply (== sum of all debt balances)
    uint256                     public totalDebt; 
    // Amount of rewards per share accumulated (total, see rewardDebt for more info)
    uint256                     public accTokensPerShare;
    // Balance of the rewards token in this contract since last update
    uint256                     public rewardsBalance;    
    // Last block when a reward was pulled
    uint256                     public lastRewardBlock;    
    // Balances
    mapping(address => uint256) public debtBalanceOf;
    // The amount of tokens inneligible for claiming rewards (see formula below)
    mapping(address => uint256) internal rewardDebt;
    // Pending reward = (descendant.balanceOf(user) * accTokensPerShare) - rewardDebt[user]    

    // Contract that drips rewards
    RewardDripperLike immutable public rewardDripper;        
    // Reward Pool
    TokenPool         immutable public rewardPool;      

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event DebtSet(address indexed safe, uint256 amount);
    event RewardsPaid(address account, uint256 amount);
    event PoolUpdated(uint256 accTokensPerShare, uint256 stakedSupply);    

    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) virtual external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }

    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) virtual external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }

    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "DebtRewards/account-not-authorized");
        _;
    }

    // --- Math ---
    uint256 public constant WAD = 10 ** 18;
    uint256 public constant RAY = 10 ** 27;

    function addition(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x, "DebtRewards/add-overflow");
    }
    function subtract(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x, "DebtRewards/sub-underflow");
    }
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, "DebtRewards/mul-overflow");
    }

    constructor(
        address rewardDripper_
    ) public {
        require(rewardDripper_ != address(0), "DebtRewards/null-reward-dripper");

        rewardDripper = RewardDripperLike(rewardDripper_);
        rewardPool    = new TokenPool(address(RewardDripperLike(rewardDripper_).rewardToken()));

        authorizedAccounts[msg.sender] = 1;
        emit AddAuthorization(msg.sender);
    }

    /*
    * @notice Returns unclaimed rewards for a given user
    */
    function pendingRewards(address user) public view returns (uint256) {
        uint accTokensPerShare_ = accTokensPerShare;
        if (block.number > lastRewardBlock && totalDebt != 0) {
            uint increaseInBalance = multiply(subtract(block.number, lastRewardBlock), rewardDripper.rewardPerBlock());
            accTokensPerShare_ = addition(accTokensPerShare_, multiply(increaseInBalance, RAY) / totalDebt);
        }
        return subtract(multiply(debtBalanceOf[user], accTokensPerShare_) / RAY, rewardDebt[user]);
    }

    /*
    * @notice Returns rewards earned per block for each token deposited (WAD)
    */
    function rewardRate() public view returns (uint256) {
        if (totalDebt == 0) return 0;
        return multiply(rewardDripper.rewardPerBlock(), WAD) / totalDebt;
    }

    // --- Core Logic ---
    /*
    * @notify Updates the pool and pays rewards (if any)
    * @dev Must be included in deposits and withdrawals
    */
    modifier computeRewards(address who) {
        updatePool();

        if (debtBalanceOf[who] > 0 && rewardPool.balance() > 0) {
            // Pays the reward
            uint256 pending = subtract(multiply(debtBalanceOf[who], accTokensPerShare) / RAY, rewardDebt[who]);

            rewardPool.transfer(who, pending);
            rewardsBalance = rewardPool.balance();

            emit RewardsPaid(who, pending);
        }
        _;
        rewardDebt[who] = multiply(debtBalanceOf[who], accTokensPerShare) / RAY;
    }

    /*
    * @notify Pays outstanding rewards to msg.sender
    */
    function getRewards() external computeRewards(msg.sender) {}

    /*
    * @notify Pull funds from the dripper
    */
    function pullFunds() public {
        rewardDripper.dripReward(address(rewardPool));
    }

    /*
    * @notify Updates pool data
    */
    function updatePool() public {
        if (block.number <= lastRewardBlock) return;
        lastRewardBlock = block.number;
        if (totalDebt == 0) return;

        pullFunds();
        uint256 increaseInBalance = subtract(rewardPool.balance(), rewardsBalance);
        rewardsBalance = addition(rewardsBalance, increaseInBalance);

        // Updates distribution info
        accTokensPerShare = addition(accTokensPerShare, multiply(increaseInBalance, RAY) / totalDebt);
        emit PoolUpdated(accTokensPerShare, totalDebt);
    }

    /*
    * @notify Set a safe debt
    * @param who Owner of the safe
    * @param wad Current debt of the safe
    * @dev Only safeEngine can call this function
    */
    function setDebt(address who, uint256 wad) external computeRewards(who) isAuthorized {
        if (debtBalanceOf[who] > wad)
            totalDebt = subtract(totalDebt, debtBalanceOf[who] - wad);
        else
            totalDebt = addition(totalDebt, wad - debtBalanceOf[who]);
        
        debtBalanceOf[who] = wad;

        emit DebtSet(who, wad);
    }
}
