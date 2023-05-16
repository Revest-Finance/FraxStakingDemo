// SPDX-License-Identifier: GNU-GPL v3.0 or later

pragma solidity ^0.8.0;

import "./interfaces/IAddressRegistry.sol";
import "./interfaces/IOutputReceiverV3.sol";
import "./interfaces/ITokenVault.sol";
import "./interfaces/IRevest.sol";
import "./interfaces/IFNFTHandler.sol";
import "./interfaces/ILockManager.sol";

import "./interfaces/IFraxFarmERC20.sol";
import "./interfaces/IFraxFarmBase.sol";
import "./interfaces/IConvexWrapperV2.sol";
import "./interfaces/IRewards.sol";

import "./VestedEscrowSmartWallet.sol";

// OZ imports
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

// Libraries
import "./lib/RevestHelper.sol";

interface ITokenVaultTracker {
    function tokenTrackers(address token) external view returns (IRevest.TokenTracker memory);
}

interface IWETH {
    function deposit() external payable;
}

/**
 * @title LiquidDriver <> Revest integration for tokenizing xLQDR positions
 * @author RobAnon
 * @dev 
 */
contract RevestLiquidDriver is IOutputReceiverV3, Ownable, ERC165, IFeeReporter {
    
    using SafeERC20 for IERC20;

    address public constant CURVE_LP = 0xf43211935c781d5ca1a41d2041f397b8a7366c7a;

    address public constant STAKING_TOKEN = 0x4659d5ff63a1e1edd6d5dd9cc315e063c95947d0; // ConvexWrapperV2

    address public constant STAKING_ADDRESS = 0xa537d64881b84faffb9Ae43c951EEbF368b71cdA;

    address public constant CONVEX_DEPOSIT_TOKEN = 0xC07e540DbFecCF7431EA2478Eb28A03918c1C30E;

    address public constant REWARDS = 0x3465b8211278505ae9c6b5ba08ecd9af951a6896;


    // Where to find the Revest address registry that contains info about what contracts live where
    address public addressRegistry;

    // Address of voting escrow contract
    address public immutable VOTING_ESCROW;

    // Token used for voting escrow
    address public immutable TOKEN;  

    // Template address for VE wallets
    address public immutable TEMPLATE;

    // The file which tells our frontend how to visually represent such an FNFT
    string public METADATA = "https://revest.mypinata.cloud/ipfs/Qmcy4NZmfefKAJ81w9ahwBWp3tX6f8B6i7r9xEzV4RbrdE";

    // Constant used for approval
    uint private constant MAX_INT = 2 ** 256 - 1;

    uint private constant DAY = 86400;

    uint private constant MAX_LOCKUP = 2 * 365 days;

    // Fee tracker
    uint private weiFee = 1 ether;

    // For tracking if a given contract has approval for token
    mapping (address => mapping (address => bool)) private approvedContracts;

    // For tracking wallet approvals for tokens
    // Works for up to 256 tokens
    mapping (address => mapping (uint => uint)) private walletApprovals;

    mapping (uint => bytes32) public kekIds;


    // Initialize the contract with the needed valeus
    constructor(address _provider, address _vE, address _distro, uint N_COINS) {
        addressRegistry = _provider;
        TOKEN = IVotingEscrow(_vE).token();
        VestedEscrowSmartWallet wallet = new VestedEscrowSmartWallet();
        TEMPLATE = address(wallet);
    }

    modifier onlyRevestController() {
        require(msg.sender == IAddressRegistry(addressRegistry).getRevest(), 'Unauthorized Access!');
        _;
    }

    modifier onlyTokenHolder(uint fnftId) {
        IAddressRegistry reg = IAddressRegistry(addressRegistry);
        require(IFNFTHandler(reg.getRevestFNFT()).getBalance(msg.sender, fnftId) > 0, 'E064');
        _;
    }

    // Allows core Revest contracts to make sure this contract can do what is needed
    // Mandatory method
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IOutputReceiver).interfaceId
            || interfaceId == type(IOutputReceiverV2).interfaceId
            || interfaceId == type(IOutputReceiverV3).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function lockTokens(
        uint endTime,
        uint amountToLock
    ) external payable returns (uint fnftId) {    

        /// Mint FNFT
        {
            // Initialize the Revest config object
            IRevest.FNFTConfig memory fnftConfig;

            // Want FNFT to be extendable and support multiple deposits
            fnftConfig.isMulti = true;

            fnftConfig.maturityExtension = true;

            // Will result in the asset being sent back to this contract upon withdrawal
            // Results solely in a callback
            fnftConfig.pipeToContract = address(this);  

            // Set these two arrays according to Revest specifications to say
            // Who gets these FNFTs and how many copies of them we should create
            address[] memory recipients = new address[](1);
            recipients[0] = _msgSender();

            uint[] memory quantities = new uint[](1);
            quantities[0] = 1;

            address revest = IAddressRegistry(addressRegistry).getRevest();

            
            fnftId = IRevest(revest).mintTimeLock(endTime, recipients, quantities, fnftConfig);
        }

        address smartWallAdd;
        {
            // We deploy the smart wallet
            smartWallAdd = Clones.cloneDeterministic(TEMPLATE, keccak256(abi.encode(TOKEN, fnftId)));
            VestedEscrowSmartWallet wallet = VestedEscrowSmartWallet(smartWallAdd);

            // Transfer the tokens from the user to this wallet
            IERC20(CURVE_LP).safeTransferFrom(msg.sender, smartWallAdd, amountToLock);

            // We deposit our funds into the wallet, store kek_id
            kekIds[smartWallAdd] = wallet.createLock(amountToLock, endTime, msg.sender);
            wallet.cleanMemory();
            emit DepositERC20OutputReceiver(msg.sender, TOKEN, amountToLock, fnftId, abi.encode(smartWallAdd));
        }
    }


    function receiveRevestOutput(
        uint fnftId,
        address,
        address payable owner,
        uint
    ) external override  {
        
        // Security check to make sure the Revest vault is the only contract that can call this method
        address vault = IAddressRegistry(addressRegistry).getTokenVault();
        require(_msgSender() == vault, 'E016');

        address smartWallAdd = Clones.cloneDeterministic(TEMPLATE, keccak256(abi.encode(TOKEN, fnftId)));
        VestedEscrowSmartWallet wallet = VestedEscrowSmartWallet(smartWallAdd);

        wallet.withdraw(VOTING_ESCROW);
        uint balance = IERC20(TOKEN).balanceOf(address(this));
        IERC20(TOKEN).safeTransfer(owner, balance);

        // Clean up memory
        SmartWalletWhitelistV2(IVotingEscrow(VOTING_ESCROW).smart_wallet_checker()).revokeWallet(smartWallAdd);

        emit WithdrawERC20OutputReceiver(owner, TOKEN, balance, fnftId, abi.encode(smartWallAdd));
    }

    // Not applicable, as these cannot be split
    // Why not? We don't enable it in IRevest.FNFTConfig
    function handleFNFTRemaps(uint, uint[] memory, address, bool) external pure override {
        require(false, 'Not applicable');
    }
    
    // Allows custom parameters to be passed during withdrawals
    // This and the proceeding method are both parts of the V2 output receiver interface
    // and not typically necessary. For the sake of demonstration, they are included
    function receiveSecondaryCallback(
        uint fnftId,
        address payable owner,
        uint quantity,
        IRevest.FNFTConfig memory config,
        bytes memory args
    ) external payable override {}

    // Callback from Revest.sol to extend maturity
    function handleTimelockExtensions(uint fnftId, uint expiration, address) external override onlyRevestController {
        require(expiration - block.timestamp <= MAX_LOCKUP, 'Max lockup is 2 years');
        address smartWallAdd = Clones.cloneDeterministic(TEMPLATE, keccak256(abi.encode(TOKEN, fnftId)));
        VestedEscrowSmartWallet wallet = VestedEscrowSmartWallet(smartWallAdd);
        wallet.increaseUnlockTime(expiration, VOTING_ESCROW);
    }

    /// Prerequisite: User has approved this contract to spend tokens on their behalf
    function handleAdditionalDeposit(uint fnftId, uint amountToDeposit, uint, address caller) external override onlyRevestController {
        address smartWallAdd = Clones.cloneDeterministic(TEMPLATE, keccak256(abi.encode(TOKEN, fnftId)));
        VestedEscrowSmartWallet wallet = VestedEscrowSmartWallet(smartWallAdd);
        IERC20(TOKEN).safeTransferFrom(caller, smartWallAdd, amountToDeposit);
        wallet.increaseAmount(amountToDeposit, VOTING_ESCROW);
    }

    // Not applicable
    function handleSplitOperation(uint fnftId, uint[] memory proportions, uint quantity, address caller) external override {}

    // Claims REWARDS on user's behalf
    function triggerOutputReceiverUpdate(
        uint fnftId,
        bytes memory
    ) external override onlyTokenHolder(fnftId) {
        address rewardsAdd = IAddressRegistry(addressRegistry).getRewardsHandler();
        address smartWallAdd = Clones.cloneDeterministic(TEMPLATE, keccak256(abi.encode(TOKEN, fnftId)));
        VestedEscrowSmartWallet wallet = VestedEscrowSmartWallet(smartWallAdd);
        { 
            // Want this to be re-run if we change fee distributors or REWARDS handlers
            address virtualAdd = address(uint160(uint256(keccak256(abi.encodePacked(DISTRIBUTOR, rewardsAdd)))));
            if(!_isApproved(smartWallAdd, virtualAdd)) {
                wallet.proxyApproveAll(REWARD_TOKENS, rewardsAdd);
                _setIsApproved(smartWallAdd, virtualAdd, true);
            }
        }
        wallet.claimRewards(DISTRIBUTOR, VOTING_ESCROW, REWARD_TOKENS, msg.sender, rewardsAdd);
    }       

    function proxyExecute(
        uint fnftId,
        address destination,
        bytes memory data
    ) external onlyTokenHolder(fnftId) returns (bytes memory dataOut) {
        require(globalProxyEnabled || proxyEnabled[fnftId], 'Proxy access not enabled!');
        address smartWallAdd = Clones.cloneDeterministic(TEMPLATE, keccak256(abi.encode(TOKEN, fnftId)));
        VestedEscrowSmartWallet wallet = VestedEscrowSmartWallet(smartWallAdd);
        dataOut = wallet.proxyExecute(destination, data);
        wallet.cleanMemory();
    }

    // Utility functions

    function _isApproved(address wallet, address feeDistro) internal view returns (bool) {
        uint256 _id = uint256(uint160(feeDistro));
        uint256 _mask = 1 << _id % 256;
        return (walletApprovals[wallet][_id / 256] & _mask) != 0;
    }

    function _setIsApproved(address wallet, address feeDistro, bool _approval) internal {
        uint256 _id = uint256(uint160(feeDistro));
        if (_approval) {
            walletApprovals[wallet][_id / 256] |= 1 << _id % 256;
        } else {
            walletApprovals[wallet][_id / 256] &= 0 << _id % 256;
        }
    }


    /// Admin Functions

    function setAddressRegistry(address addressRegistry_) external override onlyOwner {
        addressRegistry = addressRegistry_;
    }

    function setDistributor(address _distro, uint nTokens) external onlyOwner {
        DISTRIBUTOR = _distro;
        REWARD_TOKENS = new address[](nTokens);
        for(uint i = 0; i < nTokens; i++) {
            REWARD_TOKENS[i] = IDistributor(_distro).tokens(i);
        }
    }

    function setWeiFee(uint _fee) external onlyOwner {
        weiFee = _fee;
    }

    function setMetadata(string memory _meta) external onlyOwner {
        METADATA = _meta;
    }

    function setGlobalProxyEnabled(bool enable) external onlyOwner {
        globalProxyEnabled = enable;
    }

    function setProxyStatusForFNFT(uint fnftId, bool status) external onlyOwner {
        proxyEnabled[fnftId] = status;
    }

    /// If funds are mistakenly sent to smart wallets, this will allow the owner to assist in rescue
    function rescueNativeFunds() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    /// Under no circumstances should this contract ever contain ERC-20 tokens at the end of a transaction
    /// If it does, someone has mistakenly sent funds to the contract, and this function can rescue their tokens
    function rescueERC20(address token) external onlyOwner {
        uint amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// View Functions

    function getCustomMetadata(uint) external view override returns (string memory) {
        return METADATA;
    }
    
    // Will give balance in xLQDR
    // TODO: Implement
    function getValue(uint fnftId) public view override returns (uint) {
        return IVotingEscrow(VOTING_ESCROW).balanceOf(Clones.predictDeterministicAddress(TEMPLATE, keccak256(abi.encode(TOKEN, fnftId))));
    }

    // Must always be in native token
    function getAsset(uint) external view override returns (address) {
        return CURVE_LP;
    }

    function getOutputDisplayValues(uint fnftId) external view override returns (bytes memory displayData) {
        (address[] memory tokens, uint256[] memory rewardAmounts) = earned(fnftId);
        string[] memory rewardsDesc = new string[](REWARD_TOKENS.length);
        if(hasRewards) {
            for(uint i = 0; i < tokens.length; i++) {
                address token = tokens[i];
                string memory par1 = string(abi.encodePacked(RevestHelper.getName(token),": "));
                string memory par2 = string(abi.encodePacked(RevestHelper.amountToDecimal(rewardAmounts[i], token), " [", RevestHelper.getTicker(token), "] Tokens Available"));
                rewardsDesc[i] = string(abi.encodePacked(par1, par2));
            }
        }
        address smartWallet = getAddressForFNFT(fnftId);
        uint maxExtension = block.timestamp / (1 days) * (1 days) + MAX_LOCKUP; //Ensures no confusion with time zones and date-selectors
        displayData = abi.encode(smartWallet, rewardsDesc, hasRewards, maxExtension, TOKEN);
    }

    function getAddressRegistry() external view override returns (address) {
        return addressRegistry;
    }

    function getRevest() internal view returns (IRevest) {
        return IRevest(IAddressRegistry(addressRegistry).getRevest());
    }

    function getFlatWeiFee(address) external view override returns (uint) {
        return weiFee;
    }

    function getERC20Fee(address) external pure override returns (uint) {
        return 0;
    }

    function getAddressForFNFT(uint fnftId) public view returns (address smartWallAdd) {
        smartWallAdd = Clones.predictDeterministicAddress(TEMPLATE, keccak256(abi.encode(TOKEN, fnftId)));
    }

    
    //helper function to combine earned tokens on staking contract and any tokens that are on this vault
    function earned(uint fnftId) external view override returns (address[] memory token_addresses, uint256[] memory total_earned) {
        //get list of reward tokens
        address smartWallAdd = getAddressForFNFT(fnftId);

        address[] memory rewardTokens = IFraxFarmERC20(STAKING_ADDRESS).getAllRewardTokens();
        uint256[] memory stakedearned = IFraxFarmERC20(STAKING_ADDRESS).earned(smartWallet);
        IConvexWrapperV2.EarnedData[] memory convexrewards = IConvexWrapperV2(STAKING_TOKEN).earnedView(smartWallet);

        uint256 extraRewardsLength = IRewards(REWARDS).rewardTokenLength();
        token_addresses = new address[](rewardTokens.length + extraRewardsLength + convexrewards.length);
        total_earned = new uint256[](rewardTokens.length + extraRewardsLength + convexrewards.length);

        //add any tokens that happen to be already claimed but sitting on the vault
        //(ex. withdraw claiming REWARDS)
        for(uint256 i = 0; i < rewardTokens.length; i++){
            token_addresses[i] = rewardTokens[i];
            total_earned[i] = stakedearned[i] + IERC20(rewardTokens[i]).balanceOf(smartWallet);
        }

        IRewards.EarnedData[] memory extraRewards = IRewards(REWARDS).claimableRewards(smartWallet);
        for(uint256 i = 0; i < extraRewards.length; i++){
            token_addresses[i+rewardTokens.length] = extraRewards[i].token;
            total_earned[i+rewardTokens.length] = extraRewards[i].amount;
        }

        //add convex farm earned tokens
        for(uint256 i = 0; i < convexrewards.length; i++){
            token_addresses[i+rewardTokens.length+extraRewardsLength] = convexrewards[i].token;
            total_earned[i+rewardTokens.length+extraRewardsLength] = convexrewards[i].amount;
        }
    }

    // Implementation of Binary Search
    function findTimestampUserEpoch(address user, uint timestamp, uint maxUserEpoch) private view returns (uint timestampEpoch) {
        uint min;
        uint max = maxUserEpoch;
        for(uint i = 0; i < 128; i++) {
            if(min >= max) {
                break;
            }
            uint mid = (min + max + 2) / 2;
            uint ts = IVotingEscrow(VOTING_ESCROW).user_point_history(user, mid).ts;
            if(ts <= timestamp) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    
}
