// // SPDX-License-Identifier: GNU-GPL v3.0 or later

// pragma solidity ^0.8.0;

// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import '@openzeppelin/contracts/utils/introspection/ERC165Checker.sol';
// import "./interfaces/IRevest.sol";
// import "./interfaces/IAddressRegistry.sol";
// import "./interfaces/ILockManager.sol";
// import "./interfaces/IInterestHandler.sol";
// import "./interfaces/ITokenVault.sol";
// import "./interfaces/IRewardsHandler.sol";
// import "./interfaces/IOracleDispatch.sol";
// import "./interfaces/IOutputReceiver.sol";
// import "./interfaces/IOutputReceiverV2.sol";
// import "./interfaces/IOutputReceiverV3.sol";
// import "./interfaces/IAddressLock.sol";
// // import "./utils/RevestAccessControl.sol";
// import "./utils/RevestReentrancyGuard.sol";
// import "./lib/IUnicryptV2Locker.sol";
// import "./lib/IWETH.sol";
// import "./FNFTHandler.sol";

// /**
//  * This is the entrypoint for the frontend, as well as third-party Revest integrations.
//  * Solidity style guide ordering: receive, fallback, external, public, internal, private - within a grouping, view and pure go last - https://docs.soliditylang.org/en/latest/style-guide.html
//  */
// contract RevestA2 is IRevest, RevestAccessControl, RevestReentrancyGuard {
//     using SafeERC20 for IERC20;
//     using ERC165Checker for address;

//     bytes4 public constant ADDRESS_LOCK_INTERFACE_ID = type(IAddressLock).interfaceId;
//     bytes4 public constant OUTPUT_RECEIVER_INTERFACE_V2_ID = type(IOutputReceiverV2).interfaceId;
//     bytes4 public constant OUTPUT_RECEIVER_INTERFACE_V3_ID = type(IOutputReceiverV3).interfaceId;

//     address immutable WETH;

//     uint public erc20Fee; // out of 1000
//     uint private constant erc20multiplierPrecision = 1000;
//     uint public flatWeiFee;
//     uint private constant MAX_INT = 2**256 - 1;

//     mapping(address => bool) private approved;

//     mapping(address => bool) public whitelisted;

//     /**
//      * @dev Primary constructor to create the Revest controller contract
//      * Grants ADMIN and MINTER_ROLE to whoever creates the contract
//      *
//      */
//     constructor(address provider, address weth) RevestAccessControl(provider) {
//         WETH = weth;
//     }

//     // PUBLIC FUNCTIONS

//     /**
//      * @dev creates a single time-locked NFT with <quantity> number of copies with <amount> of <asset> stored for each copy
//      * asset - the address of the underlying ERC20 token for this bond
//      * amount - the amount to store per NFT if multiple NFTs of this variety are being created
//      * unlockTime - the timestamp at which this will unlock
//      * quantity – the number of FNFTs to create with this operation     */
//     function mintTimeLock(
//         uint endTime,
//         address[] memory recipients,
//         uint[] memory quantities,
//         IRevest.FNFTConfig memory fnftConfig
//     ) external payable override returns (uint) {
//         // Get the next id
//         uint fnftId = getFNFTHandler().getNextId();
//         // Get or create lock based on time, assign lock to ID
//         {
//             IRevest.LockParam memory timeLock;
//             timeLock.lockType = IRevest.LockType.TimeLock;
//             timeLock.timeLockExpiry = endTime;
//             getLockManager().createLock(fnftId, timeLock);
//         }
//         doMint(recipients, quantities, fnftId, fnftConfig, msg.value);

//         emit FNFTTimeLockMinted(fnftConfig.asset, _msgSender(), fnftId, endTime, quantities, fnftConfig);

//         return fnftId;
//     }

//     function mintValueLock(
//         address primaryAsset,
//         address compareTo,
//         uint unlockValue,
//         bool unlockRisingEdge,
//         address oracleDispatch,
//         address[] memory recipients,
//         uint[] memory quantities,
//         IRevest.FNFTConfig memory fnftConfig
//     ) external payable override returns (uint) {
//         // copy the fnftId
//         uint fnftId = getFNFTHandler().getNextId();
//         // Initialize the lock structure
//         {
//             IRevest.LockParam memory valueLock;
//             valueLock.lockType = IRevest.LockType.ValueLock;
//             valueLock.valueLock.unlockRisingEdge = unlockRisingEdge;
//             valueLock.valueLock.unlockValue = unlockValue;
//             valueLock.valueLock.asset = primaryAsset;
//             valueLock.valueLock.compareTo = compareTo;
//             valueLock.valueLock.oracle = oracleDispatch;

//             getLockManager().createLock(fnftId, valueLock);
//         }

//         doMint(recipients, quantities, fnftId, fnftConfig, msg.value);

//         emit FNFTValueLockMinted(fnftConfig.asset,  _msgSender(), fnftId, compareTo, oracleDispatch, quantities, fnftConfig);

//         return fnftId;
//     }

//     function mintAddressLock(
//         address trigger,
//         bytes memory arguments,
//         address[] memory recipients,
//         uint[] memory quantities,
//         IRevest.FNFTConfig memory fnftConfig
//     ) external payable override returns (uint) {
//         uint fnftId = getFNFTHandler().getNextId();

//         {
//             IRevest.LockParam memory addressLock;
//             addressLock.addressLock = trigger;
//             addressLock.lockType = IRevest.LockType.AddressLock;
//             // Get or create lock based on address which can trigger unlock, assign lock to ID
//             uint lockId = getLockManager().createLock(fnftId, addressLock);

//             if(trigger.supportsInterface(ADDRESS_LOCK_INTERFACE_ID)) {
//                 IAddressLock(trigger).createLock(fnftId, lockId, arguments);
//             }
//         }
//         // This is a public call to a third-party contract. Must be done after everything else.
//         // Safe for reentry
//         doMint(recipients, quantities, fnftId, fnftConfig, msg.value);

//         emit FNFTAddressLockMinted(fnftConfig.asset, _msgSender(), fnftId, trigger, quantities, fnftConfig);

//         return fnftId;
//     }

//     function withdrawFNFT(uint fnftId, uint quantity) public override revestNonReentrant(fnftId) {
//         address fnftHandler = addressesProvider.getRevestFNFT();
//         // TODO: Can optimize these checks for better gas efficiency and less external calls

//         // Check if this many FNFTs exist in the first place for the given ID
//         require(quantity > 0, "E044");
//         // Burn the FNFTs being exchanged
//         IFNFTHandler(fnftHandler).burn(_msgSender(), fnftId, quantity);
//         require(getLockManager().unlockFNFT(fnftId, _msgSender()), 'E077');
        
//         getTokenVault().withdrawToken(fnftId, quantity, _msgSender());
//         emit FNFTWithdrawn(_msgSender(), fnftId, quantity);
//     }

    
//     function withdrawFNFTPassthrough(uint fnftId, uint quantity, bytes memory args) external payable revestNonReentrant(fnftId) {
//         // Pull pipe location prior to withdrawal
//         IRevest.FNFTConfig memory config = getTokenVault().getFNFT(fnftId);
//         withdrawFNFT(fnftId, quantity);
//         if(config.pipeToContract.supportsInterface(OUTPUT_RECEIVER_INTERFACE_V2_ID)) {
//             // Callback to OutputReceiverV2
//             IOutputReceiverV2(config.pipeToContract).receiveSecondaryCallback{value:msg.value}(fnftId, payable(_msgSender()), quantity, config, args);
//         }
//     }

//     function unlockFNFT(uint fnftId) external override {
//         // Works for value locks or time locks
//         IRevest.LockType lock = getLockManager().lockTypes(fnftId);
//         require(lock == IRevest.LockType.AddressLock || lock == IRevest.LockType.ValueLock, "E008");
//         require(getLockManager().unlockFNFT(fnftId, _msgSender()), "E056");

//         emit FNFTUnlocked(_msgSender(), fnftId);
//     }

//     // Transactional layer function
//     function withdrawAndRemap(uint fnftId, IRevest.FNFTConfig memory fnftConfig) external {
//         ITokenVault vault = getTokenVault();
//         {
//             IRevest.FNFTConfig memory config = vault.getFNFT(fnftId);
//             // Only the output receiver itself can make this call
//             require(config.pipeToContract == _msgSender() && config.pipeToContract != address(0), 'E079');
//         }
//         //Must perform on an entire series, series must exist
//         uint quantity = getFNFTHandler().getSupply(fnftId);
//         require(quantity > 0, 'E044');
//         // Note well: this will forward value to output receiver and call 'receiveRevestOutput' method on it
//         // Must catch and ignore that call on the output receiver side using a boolean flag (or do something with it)
//         vault.withdrawToken(fnftId, quantity, _msgSender());

//         // Create the FNFT and update accounting within TokenVault
//         vault.createFNFT(fnftId, fnftConfig, quantity, _msgSender());

//         // Now, we move the funds to token vault from the message sender
//         // Implicit assumption that setApproval has been properly configured for the OutputReceiver
//         if(fnftConfig.asset != address(0) && fnftConfig.depositAmount > 0){
//             IERC20(fnftConfig.asset).safeTransferFrom(_msgSender(), address(vault), quantity * fnftConfig.depositAmount);
//         }
//     }

//     function splitFNFT(
//         uint fnftId,
//         uint[] memory proportions,
//         uint quantity
//     ) external override returns (uint[] memory) {
//         // Check if the user making this call has ANY FNFT's
//         IFNFTHandler fnftHandler = IFNFTHandler(addressesProvider.getRevestFNFT());
//         ITokenVault vault = ITokenVault(addressesProvider.getTokenVault());
//         ILockManager lockMan = ILockManager(addressesProvider.getLockManager());
//         address output;
//         {
//             FNFTConfig memory config = vault.getFNFT(fnftId);
//             require(config.split > 0, "E023");
//             output = config.pipeToContract;
//         }
//         require(fnftHandler.getBalance(_msgSender(), fnftId) > 0, "E032");
//         // Checking if the FNFT is allowing splitting
        
//         uint[] memory newFNFTIds = new uint[](proportions.length);
//         {        
//             uint start = fnftHandler.getNextId();
//             uint lockId = lockMan.fnftIdToLockId(fnftId);
//             fnftHandler.burn(_msgSender(), fnftId, quantity);
//             for(uint i = 0; i < proportions.length; i++) {
//                 newFNFTIds[i] = start + i;
//                 fnftHandler.mint(_msgSender(), newFNFTIds[i], quantity, "");
//                 lockMan.pointFNFTToLock(newFNFTIds[i], lockId);
//             }
//         }
//         vault.splitFNFT(fnftId, newFNFTIds, proportions, quantity);
//         // Trigger copying any data on the output receiver here
//         // May not be as simple as just copy-pasting data, and it will be left up to devs
//         // To determine how to (and if) to implement this method
//         if(output != address(0) && output.supportsInterface(OUTPUT_RECEIVER_INTERFACE_V2_ID)) {
//             // Callback to OutputReceiverV2
//             IOutputReceiverV2(output).handleFNFTRemaps(fnftId, newFNFTIds, _msgSender(), fnftHandler.getSupply(fnftId) == 0);
//             if(output.supportsInterface(OUTPUT_RECEIVER_INTERFACE_V3_ID)) {
//                 IOutputReceiverV3(output).handleSplitOperation(fnftId, proportions, quantity, msg.sender);
//             }
//         }

//         emit FNFTSplit(_msgSender(), newFNFTIds, proportions, quantity);

//         return newFNFTIds;
//     }

//     /// @return the new (or reused) ID
//     function extendFNFTMaturity(
//         uint fnftId,
//         uint endTime
//     ) external override returns (uint) {
//         IFNFTHandler fnftHandler = getFNFTHandler();
//         uint supply = fnftHandler.getSupply(fnftId);
//         uint balance = fnftHandler.getBalance(_msgSender(), fnftId);

//         require(fnftId < fnftHandler.getNextId(), "E007");
//         require(balance == supply , "E022");
//         IRevest.FNFTConfig memory config = getTokenVault().getFNFT(fnftId);
//         ILockManager manager = getLockManager();
//         // If it can't have its maturity extended, revert
//         // Will also return false on non-time lock locks
//         require(config.maturityExtension &&
//             manager.lockTypes(fnftId) == IRevest.LockType.TimeLock, "E029");
//         // If desired maturity is below existing date, reject operation
//         require(manager.fnftIdToLock(fnftId).timeLockExpiry < endTime, "E030");

//         // Update the lock
//         IRevest.LockParam memory lock;
//         lock.lockType = IRevest.LockType.TimeLock;
//         lock.timeLockExpiry = endTime;

//         manager.createLock(fnftId, lock);

//         // Callback to IOutputReceiverV3
//         if(config.pipeToContract != address(0) && config.pipeToContract.supportsInterface(OUTPUT_RECEIVER_INTERFACE_V3_ID)) {
//             IOutputReceiverV3(config.pipeToContract).handleTimelockExtensions(fnftId, endTime, msg.sender);
//         }

//         emit FNFTMaturityExtended(_msgSender(), fnftId, endTime);

//         // Need to handle fracture into multiple FNFTs with same value as original but different locks
//         return fnftId;
//     }

//     /**
//      * Amount will be per FNFT. So total ERC20s needed is amount * quantity.
//      * We don't charge an ETH fee on depositAdditional, but do take the erc20 percentage.
//      * Users can deposit additional into their own
//      * Otherwise, if not an owner, they must distribute to all FNFTs equally
//      */
//     function depositAdditionalToFNFT(
//         uint fnftId,
//         uint amount,
//         uint quantity
//     ) external override returns (uint) {
//         address vault = addressesProvider.getTokenVault();
//         IRevest.FNFTConfig memory fnft = ITokenVault(vault).getFNFT(fnftId);
//         require(fnftId < getFNFTHandler().getNextId(), "E007");
//         require(fnft.isMulti, "E034");
//         require(fnft.depositStopTime < block.timestamp || fnft.depositStopTime == 0, "E035");
//         require(quantity > 0, "E070");

//         address handler = addressesProvider.getRevestFNFT();
//         address lockHandler = addressesProvider.getLockManager();

//         bool createNewSeries = false;
//         {
//             uint supply = IFNFTHandler(handler).getSupply(fnftId);

//             uint balance = IFNFTHandler(handler).getBalance(_msgSender(), fnftId);

//             if (quantity > balance) {
//                 require(quantity == supply, "E069");
//             }
//             else if (quantity < balance || balance < supply) {
//                 createNewSeries = true;
//             }
//         }

//         // Transfer the ERC20 fee to the admin address, leave it at that
//         if(!whitelisted[_msgSender()]) {
//             uint totalERC20Fee = erc20Fee * quantity * amount / erc20multiplierPrecision;
//             if(totalERC20Fee > 0) {
//                 IERC20(fnft.asset).safeTransferFrom(_msgSender(), addressesProvider.getAdmin(), totalERC20Fee);
//             }
//         }
        
//         uint lockId = ILockManager(lockHandler).fnftIdToLockId(fnftId);

//         // Whether to split the new deposits into their own series, or to simply add to an existing series
//         uint newFNFTId;
//         if(createNewSeries) {
//             // Split into a new series
//             newFNFTId = IFNFTHandler(handler).getNextId();
//             ILockManager(lockHandler).pointFNFTToLock(newFNFTId, lockId);
//             burn(_msgSender(), fnftId, quantity);
//             IFNFTHandler(handler).mint(_msgSender(), newFNFTId, quantity, "");
//         } else {
//             // Stay the same
//             newFNFTId = 0; // Signals to handleMultipleDeposits()
//         }

//         // Will call updateBalance
//         ITokenVault(vault).depositToken(fnftId, amount, quantity);
//         // Now, we transfer to the token vault
//         if(fnft.asset != address(0)){
//             IERC20(fnft.asset).safeTransferFrom(_msgSender(), vault, quantity * amount);
//         }

//         ITokenVault(vault).handleMultipleDeposits(fnftId, newFNFTId, fnft.depositAmount + amount);

//         // Trigger copying any data on the output receiver here
//         // May not be as simple as just copy-pasting data, and it will be left up to devs
//         // To determine how to (and if) to implement this method
//         // Performed last to give outputRecevier acccess to all new state data
//         if(fnft.pipeToContract != address(0) && fnft.pipeToContract.supportsInterface(OUTPUT_RECEIVER_INTERFACE_V2_ID)) {
//             if(createNewSeries) {
//                 // Callback to OutputReceiverV2
//                 uint[] memory newIds = new uint[](1);
//                 newIds[0] = newFNFTId;
//                 // Cleanup arg is false because this operation will never result in an empty series of FNFTs
//                 IOutputReceiverV2(fnft.pipeToContract).handleFNFTRemaps(fnftId, newIds, _msgSender(), false);
//             }
//             if(fnft.pipeToContract.supportsInterface(OUTPUT_RECEIVER_INTERFACE_V3_ID)) {
//                 IOutputReceiverV3(fnft.pipeToContract).handleAdditionalDeposit(fnftId, amount, quantity, msg.sender);
//             }
//         }
//         emit FNFTAddionalDeposited(_msgSender(), newFNFTId, quantity, amount);

//         return newFNFTId;
//     }

//     //
//     // INTERNAL FUNCTIONS
//     //

//     function doMint(
//         address[] memory recipients,
//         uint[] memory quantities,
//         uint fnftId,
//         IRevest.FNFTConfig memory fnftConfig,
//         uint weiValue
//     ) internal {
//         bool isSingular;
//         uint totalQuantity = quantities[0];
//         {
//             uint rec = recipients.length;
//             uint quant = quantities.length;
//             require(rec == quant, "recipients and quantities arrays must match");
//             // Calculate total quantity
//             isSingular = rec == 1;
//             if(!isSingular) {
//                 for(uint i = 1; i < quant; i++) {
//                     totalQuantity += quantities[i];
//                 }
//             }
//             require(totalQuantity > 0, "E003");
//         }

//         // Gas optimization
//         address vault = addressesProvider.getTokenVault();

//         // Take fees
//         if(weiValue > 0) {
//             // Immediately convert all ETH to WETH
//             IWETH(WETH).deposit{value: weiValue}();
//         }

//         // For multi-chain deployments, will relay through RewardsHandlerSimplified to end up in admin wallet
//         // Whitelist system will charge fees on all but approved parties, who may charge them using negotiated
//         // values with the Revest Protocol
//         if(!whitelisted[_msgSender()]) {
//             if(flatWeiFee > 0) {
//                 require(weiValue >= flatWeiFee, "E005");
//                 address reward = addressesProvider.getRewardsHandler();
//                 if(!approved[reward]) {
//                     IERC20(WETH).approve(reward, MAX_INT);
//                     approved[reward] = true;
//                 }
//                 IRewardsHandler(reward).receiveFee(WETH, flatWeiFee);
//             }
            
//             // If we aren't depositing any value, no point running this
//             if(fnftConfig.depositAmount > 0) {
//                 uint totalERC20Fee = erc20Fee * totalQuantity * fnftConfig.depositAmount / erc20multiplierPrecision;
//                 if(totalERC20Fee > 0) {
//                     IERC20(fnftConfig.asset).safeTransferFrom(_msgSender(), addressesProvider.getAdmin(), totalERC20Fee);
//                 }
//             }

//             // If there's any leftover ETH after the flat fee, convert it to WETH
//             weiValue -= flatWeiFee;
//         }
        
//         // Convert ETH to WETH if necessary
//         if(weiValue > 0) {
//             // If the asset is WETH, we also enable sending ETH to pay for the tx fee. Not required though
//             require(fnftConfig.asset == WETH, "E053");
//             require(weiValue >= fnftConfig.depositAmount, "E015");
//         }
        

//         // Create the FNFT and update accounting within TokenVault
//         ITokenVault(vault).createFNFT(fnftId, fnftConfig, totalQuantity, _msgSender());

//         // Now, we move the funds to token vault from the message sender
//         if(fnftConfig.asset != address(0)){
//             IERC20(fnftConfig.asset).safeTransferFrom(_msgSender(), vault, totalQuantity * fnftConfig.depositAmount);
//         }
//         // Mint NFT
//         // Gas optimization
//         if(!isSingular) {
//             getFNFTHandler().mintBatchRec(recipients, quantities, fnftId, totalQuantity, '');
//         } else {
//             getFNFTHandler().mint(recipients[0], fnftId, quantities[0], '');
//         }

//     }

//     function burn(
//         address account,
//         uint id,
//         uint amount
//     ) internal {
//         address fnftHandler = addressesProvider.getRevestFNFT();
//         require(IFNFTHandler(fnftHandler).getSupply(id) - amount >= 0, "E025");
//         IFNFTHandler(fnftHandler).burn(account, id, amount);
//     }

//     function setFlatWeiFee(uint wethFee) external override onlyOwner {
//         flatWeiFee = wethFee;
//     }

//     function setERC20Fee(uint erc20) external override onlyOwner {
//         erc20Fee = erc20;
//     }

//     function getFlatWeiFee() external view override returns (uint) {
//         return flatWeiFee;
//     }

//     function getERC20Fee() external view override returns (uint) {
//         return erc20Fee;
//     }

//     // Used to whitelist a contract for custom fee behavior
//     function modifyWhitelist(address contra, bool listed) external onlyOwner {
//         whitelisted[contra] = listed;
//     }
// }