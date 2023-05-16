// SPDX-License-Identifier: GNU-GPL v3.0 or later

import "./interfaces/IFraxFarmERC20.sol";
import "./interfaces/IFraxFarmBase.sol";
import "./interfaces/IConvexWrapperV2.sol";
import "./interfaces/IRewards.sol";

import "./interfaces/IDistributor.sol";
import "./interfaces/IRewardsHandler.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


pragma solidity ^0.8.0;

/// @author RobAnon
contract VestedEscrowSmartWallet {

    using SafeERC20 for IERC20;

    uint private constant MAX_INT = 2 ** 256 - 1;

    address private immutable MASTER;

    address public constant CURVE_LP = 0xf43211935c781d5ca1a41d2041f397b8a7366c7a;

    address public constant STAKING_TOKEN = 0x4659d5ff63a1e1edd6d5dd9cc315e063c95947d0; // ConvexWrapperV2

    address public constant STAKING_ADDRESS = 0xa537d64881b84faffb9Ae43c951EEbF368b71cdA;

    address public constant CONVEX_DEPOSIT_TOKEN = 0xC07e540DbFecCF7431EA2478Eb28A03918c1C30E;

    address public constant REWARDS = 0x3465b8211278505ae9c6b5ba08ecd9af951a6896;



    constructor() {
        MASTER = msg.sender;
    }

    modifier onlyMaster() {
        require(msg.sender == MASTER, 'Unauthorized!');
        _;
    }

    function createLock(uint value, uint unlockTime) external onlyMaster returns (bytes32 kek_id) {
        // Set all approvals up, don't if they're already set
        if(IERC20(STAKING_TOKEN).allowance(address(this), STAKING_ADDRESS) != MAX_INT) {
            IERC20(STAKING_TOKEN).approve(STAKING_ADDRESS, MAX_INT);
        }
        if(IERC20(CURVE_LP).allowance(address(this), STAKING_TOKEN) != MAX_INT) {
            IERC20(CURVE_LP).approve(STAKING_TOKEN, MAX_INT);
        }
        if(IERC20(CONVEX_DEPOSIT_TOKEN).allowance(address(this), STAKING_TOKEN) != MAX_INT) {
            IERC20(CONVEX_DEPOSIT_TOKEN).approve(STAKING_TOKEN, MAX_INT);
        }

        // Create the lock
        IConvexWrapperV2(stakingToken).deposit(_addl_liq, address(this));

        // Create stake and return kek_id
        kek_id = IFraxFarmERC20(stakingAddress).lockAdditional(_kek_id, _addl_liq);
        _checkpointRewards();
    }

    function increaseAmount(uint amount, bytes32 kek_id) external onlyMaster {
        if(amount > 0){
            //deposit into wrapper
            IConvexWrapperV2(stakingToken).deposit(amount, address(this));

            //add stake
            IFraxFarmERC20(stakingAddress).lockAdditional(kek_id, amount);
        }
        
        //checkpoint rewards
        _checkpointRewards();
        _cleanMemory();
    }

    function increaseUnlockTime(uint unlockTime, address votingEscrow) external onlyMaster {
        //update time
        IFraxFarmERC20(stakingAddress).lockLonger(_kek_id, new_ending_ts);
        //checkpoint rewards
        _checkpointRewards();
        _cleanMemory();
    }

    function withdraw(address votingEscrow) external onlyMaster {
        // Withdraw
        IFraxFarmERC20(stakingAddress).withdrawLocked(_kek_id, address(this));

        // Unwrap
        IConvexWrapperV2(stakingToken).withdrawAndUnwrap(IERC20(stakingToken).balanceOf(address(this)));

        // Handle transfer
        uint bal = IERC20(CURVE_LP).balanceOf(address(this));
        IERC20(CURVE_LP).safeTransfer(MASTER, bal);
        _checkpointRewards();
        _cleanMemory();
    }

    function claimRewards(
        address distributor, 
        address votingEscrow, 
        address[] memory tokens, 
        address caller, 
        address rewards
    ) external onlyMaster {
        uint[] memory balances = new uint[](tokens.length);
        bool exitFlag;
        while(!exitFlag) {
            IDistributor(distributor).claim();
            exitFlag = IDistributor(distributor).user_epoch_of(address(this)) + 50 >= IVotingEscrow(votingEscrow).user_point_epoch(address(this));
        }   
        for(uint i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint bal = IERC20(token).balanceOf(address(this));

            // Handle fee transfer
            // Built-in assumption that we have approved rewards handler
            uint fee = bal * feeNumerator / feeDenominator;
            bal -= fee;
            IRewardsHandler(rewards).receiveFee(token, fee);

            // Handle transfer to owner
            balances[i] = bal;
            IERC20(token).safeTransfer(caller, bal);
        }
        _cleanMemory();
    }

    // Proxy function for ease of use and gas-savings
    function proxyApproveAll(address[] memory tokens, address spender) external onlyMaster {
        for(uint i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).approve(spender, MAX_INT);
        }
    }

    /// Proxy function to send arbitrary messages. Useful for delegating votes and similar activities
    function proxyExecute(
        address destination,
        bytes memory data
    ) external payable onlyMaster returns (bytes memory dataOut) {
        (bool success, bytes memory dataTemp)= destination.call{value:msg.value}(data);
        require(success, 'Proxy call failed!');
        dataOut = dataTemp;
    }

    /// Credit to doublesharp for the brilliant gas-saving concept
    /// Self-destructing clone pattern
    function cleanMemory() external onlyMaster {
        _cleanMemory();
    }

    function _cleanMemory() internal {
        selfdestruct(payable(MASTER));
    }

    //checkpoint and add/remove weight to convex rewards contract
    function _checkpointRewards() internal{
        //if rewards are active, checkpoint
        if(IRewards(REWARDS).active()){
            //using liquidity shares from staking contract will handle rebasing tokens correctly
            uint256 userLiq = IFraxFarmBase(STAKING_ADDRESS).lockedLiquidityOf(address(this));
            //get current balance of reward contract
            uint256 bal = IRewards(REWARDS).balanceOf(address(this));
            if(userLiq >= bal){
                //add the difference to reward contract
                IRewards(REWARDS).deposit(owner, userLiq - bal);
            }else{
                //remove the difference from the reward contract
                IRewards(REWARDS).withdraw(owner, bal - userLiq);
            }
        }
    }

}
