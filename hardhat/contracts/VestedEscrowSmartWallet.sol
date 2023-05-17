// SPDX-License-Identifier: GNU-GPL v3.0 or later

import "./interfaces/IFraxFarmERC20.sol";
import "./interfaces/IFraxFarmBase.sol";
import "./interfaces/IConvexWrapperV2.sol";
import "./interfaces/IRewards.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


pragma solidity ^0.8.0;

/// @author RobAnon
contract VestedEscrowSmartWallet {

    using SafeERC20 for IERC20;

    uint private constant MAX_INT = 2 ** 256 - 1;

    address private immutable MASTER;

    // Hardcoded for MVP
    address public constant CURVE_LP = 0xf43211935C781D5ca1a41d2041F397B8A7366C7A;
    address public constant STAKING_TOKEN = 0x4659d5fF63A1E1EDD6D5DD9CC315e063c95947d0; // ConvexWrapperV2
    address public constant STAKING_ADDRESS = 0xa537d64881b84faffb9Ae43c951EEbF368b71cdA;
    address public constant CONVEX_DEPOSIT_TOKEN = 0xC07e540DbFecCF7431EA2478Eb28A03918c1C30E;
    address public constant REWARDS = 0x3465B8211278505ae9C6b5ba08ECD9af951A6896;

    address public constant FXS = 0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0;
    address public constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address public constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;



    constructor() {
        MASTER = msg.sender;
    }

    modifier onlyMaster() {
        require(msg.sender == MASTER, 'Unauthorized!');
        _;
    }

    function createLock(uint value, uint unlockTime, address user) external onlyMaster returns (bytes32 kek_id) {
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

        //deposit into wrapper
        IConvexWrapperV2(STAKING_TOKEN).deposit(value, address(this));

        //stake
        kek_id = IFraxFarmERC20(STAKING_ADDRESS).stakeLocked(value, unlockTime - block.timestamp);
        _checkpointRewards(user);
    }

    function increaseAmount(uint amount, bytes32 kek_id, address user) external onlyMaster {
        if(amount > 0){
            //deposit into wrapper
            IConvexWrapperV2(STAKING_TOKEN).deposit(amount, address(this));

            //add stake
            IFraxFarmERC20(STAKING_ADDRESS).lockAdditional(kek_id, amount);
        }
        
        //checkpoint rewards
        _checkpointRewards(user);
        _cleanMemory();
    }

    function increaseUnlockTime(uint unlockTime, bytes32 kek_id, address user) external onlyMaster {
        //update time
        IFraxFarmERC20(STAKING_ADDRESS).lockLonger(kek_id, unlockTime);
        //checkpoint rewards
        _checkpointRewards(user);
        _cleanMemory();
    }

    function withdraw(bytes32 kek_id, address user) external onlyMaster returns (uint balance) {
        // Withdraw
        IFraxFarmERC20(STAKING_ADDRESS).withdrawLocked(kek_id, address(this));

        // Unwrap
        IConvexWrapperV2(STAKING_TOKEN).withdrawAndUnwrap(IERC20(STAKING_TOKEN).balanceOf(address(this)));

        // Handle transfer
        balance = IERC20(CURVE_LP).balanceOf(address(this));
        IERC20(CURVE_LP).safeTransfer(user, balance);
        _checkpointRewards(user);
    }

    function claimRewards(address user) external onlyMaster {
        _getReward(true, user); // Since this is just a demo, falling into edge cases acceptable.
        // Full produce will require proper edge-case handling for _getRewards
        _cleanMemory();
    }

    /// Credit to doublesharp for the brilliant gas-saving concept
    /// Self-destructing clone pattern
    function cleanMemory() external onlyMaster {
        _cleanMemory();
    }

    function _cleanMemory() internal {
        selfdestruct(payable(MASTER));
    }

    //get reward with claim option.
    //_claim bool is for the off chance that rewardCollectionPause is true so getReward() fails but
    //there are tokens on this vault for cases such as withdraw() also calling claim.
    //can also be used to rescue tokens on the vault
    function _getReward(bool _claim, address user) internal {

        //claim
        if(_claim){
            //claim frax farm
            IFraxFarmERC20(STAKING_ADDRESS).getReward(address(this));
            //claim convex farm and forward to owner
            IConvexWrapperV2(STAKING_TOKEN).getReward(address(this), user);

            //double check there have been no crv/cvx claims directly to this address
            uint256 b = IERC20(CRV).balanceOf(address(this));
            if(b > 0){
                IERC20(CRV).safeTransfer(user, b);
            }
            b = IERC20(CVX).balanceOf(address(this));
            if(b > 0){
                IERC20(CVX).safeTransfer(user, b);
            }
        }

        //process fxs fees
        _processFxs(user);

        //get list of reward tokens
        address[] memory rewardTokens = IFraxFarmERC20(STAKING_ADDRESS).getAllRewardTokens();

        //transfer
        _transferTokens(rewardTokens, user);

        //extra rewards
        _processExtraRewards(user);
    }

    //checkpoint and add/remove weight to convex rewards contract
    function _checkpointRewards(address user) internal{
        //if rewards are active, checkpoint
        if(IRewards(REWARDS).active()){
            //using liquidity shares from staking contract will handle rebasing tokens correctly
            uint256 userLiq = IFraxFarmBase(STAKING_ADDRESS).lockedLiquidityOf(address(this));
            //get current balance of reward contract
            uint256 bal = IRewards(REWARDS).balanceOf(address(this));
            if(userLiq >= bal){
                //add the difference to reward contract
                IRewards(REWARDS).deposit(user, userLiq - bal);
            }else{
                //remove the difference from the reward contract
                IRewards(REWARDS).withdraw(user, bal - userLiq);
            }
        }
    }

    //apply fees to FXS and send remaining to owner
    function _processFxs(address user) internal{

        // Transfer any FXS present to user
        uint sendAmount = IERC20(FXS).balanceOf(address(this));
        if(sendAmount > 0){
            IERC20(FXS).transfer(user, sendAmount);
        }
    }

    //get extra rewards
    function _processExtraRewards(address user) internal{
        if(IRewards(REWARDS).active()){
            //check if there is a balance because the reward contract could have be activated later
            //dont use _checkpointRewards since difference of 0 will still call deposit() and cost gas
            uint256 bal = IRewards(REWARDS).balanceOf(address(this));
            uint256 userLiq = IFraxFarmBase(STAKING_ADDRESS).lockedLiquidityOf(address(this));
            if(bal == 0 && userLiq > 0){
                //bal == 0 and liq > 0 can only happen if rewards were turned on after staking
                IRewards(REWARDS).deposit(user,userLiq);
            }
            IRewards(REWARDS).getReward(user);
        }
    }

    //transfer other reward tokens besides FXS(which needs to have fees applied)
    function _transferTokens(address[] memory _tokens, address user) internal{
        //transfer all tokens
        for(uint256 i = 0; i < _tokens.length; i++){
            if(_tokens[i] != FXS){
                uint256 bal = IERC20(_tokens[i]).balanceOf(address(this));
                if(bal > 0){
                    IERC20(_tokens[i]).safeTransfer(user, bal);
                }
            }
        }
    }

}
