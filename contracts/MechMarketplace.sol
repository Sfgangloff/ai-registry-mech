// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IErrorsMarketplace} from "./interfaces/IErrorsMarketplace.sol";
import {IBalanceTracker} from "./interfaces/IBalanceTracker.sol";
import {IKarma} from "./interfaces/IKarma.sol";
import {IMech} from "./interfaces/IMech.sol";
import {IServiceRegistry} from "./interfaces/IServiceRegistry.sol";

// Mech Factory interface
interface IMechFactory {
    /// @dev Registers service as a mech.
    /// @param serviceRegistry Service registry address.
    /// @param serviceId Service id.
    /// @param payload Mech creation payload.
    /// @return mech The created mech instance address.
    function createMech(address serviceRegistry, uint256 serviceId, bytes memory payload)
        external returns (address mech);
}

// Signature Validator interface
interface ISignatureValidator {
    /// @dev Should return whether the signature provided is valid for the provided hash.
    /// @notice MUST return the bytes4 magic value 0x1626ba7e when function passes.
    ///         MUST NOT modify state (using STATICCALL for solc < 0.5, view modifier for solc > 0.5).
    ///         MUST allow external calls.
    /// @param hash Hash of the data to be signed.
    /// @param signature Signature byte array associated with hash.
    /// @return magicValue bytes4 magic value.
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue);
}

// Request info struct
struct RequestInfo {
    // Priority mech address
    address priorityMech;
    // Delivery mech address
    address deliveryMech;
    // Requester address
    address requester;
    // Response timeout window
    uint256 responseTimeout;
    // Delivery rate
    uint256 deliveryRate;
    // Payment type
    bytes32 paymentType;
}

/// @title Mech Marketplace - Marketplace for posting and delivering requests served by mechs
/// @author Aleksandr Kuperman - <aleksandr.kuperman@valory.xyz>
/// @author Andrey Lebedev - <andrey.lebedev@valory.xyz>
/// @author Silvere Gangloff - <silvere.gangloff@valory.xyz>
contract MechMarketplace is IErrorsMarketplace {
    event CreateMech(address indexed mech, uint256 indexed serviceId);
    event OwnerUpdated(address indexed owner);
    event ImplementationUpdated(address indexed implementation);
    event MarketplaceParamsUpdated(uint256 fee, uint256 minResponseTimeout, uint256 maxResponseTimeout);
    event SetMechFactoryStatuses(address[] mechFactories, bool[] statuses);
    event SetPaymentTypeBalanceTrackers(bytes32[] paymentTypes, address[] balanceTrackers);
    event MarketplaceRequest(address indexed priorityMech, address indexed requester, uint256 numRequests,
        bytes32[] requestIds);
    event MarketplaceDelivery(address indexed deliveryMech, address[] indexed requesters, uint256 numDeliveries,
        bytes32[] requestIds, bool[] deliveredRequests);
    event Deliver(address indexed mech, address indexed mechServiceMultisig, bytes32 requestId, bytes data);
    event MarketplaceDeliveryWithSignatures(address indexed deliveryMech, address indexed requester,
        uint256 numRequests, bytes32[] requestIds);
    event RequesterHashApproved(address indexed requester, bytes32 hash);

    enum RequestStatus {
        DoesNotExist,
        RequestedPriority,
        RequestedExpired,
        Delivered
    }

    // Contract version number
    string public constant VERSION = "1.1.0";
    // Value for the contract signature validation: bytes4(keccak256("isValidSignature(bytes32,bytes)")
    bytes4 constant internal MAGIC_VALUE = 0x1626ba7e;
    // Code position in storage is keccak256("MECH_MARKETPLACE_PROXY") = "0xe6194b93a7bff0a54130ed8cd277223408a77f3e48bb5104a9db96d334f962ca"
    bytes32 public constant MECH_MARKETPLACE_PROXY = 0xe6194b93a7bff0a54130ed8cd277223408a77f3e48bb5104a9db96d334f962ca;
    // Domain separator type hash
    bytes32 public constant DOMAIN_SEPARATOR_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    // Max marketplace fee factor (100%)
    uint256 public constant MAX_FEE_FACTOR = 10_000;

    // Original domain separator value
    bytes32 public immutable domainSeparator;
    // Original chain Id
    uint256 public immutable chainId;
    // Mech karma contract address
    address public immutable karma;
    // Service registry contract address
    address public immutable serviceRegistry;

    // Universal mech marketplace fee (max of 10_000 == 100%)
    uint256 public fee;
    // Minimum response time
    uint256 public minResponseTimeout;
    // Maximum response time
    uint256 public maxResponseTimeout;
    // Number of undelivered requests
    uint256 public numUndeliveredRequests;
    // Number of total requests
    uint256 public numTotalRequests;
    // Number of mechs
    uint256 public numMechs;
    // Reentrancy lock
    uint256 internal _locked;

    // Contract owner
    address public owner;

    // Map of request counts for corresponding requester
    mapping(address => uint256) public mapRequestCounts;
    // Map of delivery counts for corresponding requester
    mapping(address => uint256) public mapDeliveryCounts;
    // Map of delivery counts for mechs
    mapping(address => uint256) public mapMechDeliveryCounts;
    // Map of delivery counts for corresponding mech service multisig
    mapping(address => uint256) public mapMechServiceDeliveryCounts;
    // Mapping of request Id => request information
    mapping(bytes32 => RequestInfo) public mapRequestIdInfos;
    // Mapping of whitelisted mech factories
    mapping(address => bool) public mapMechFactories;
    // Map of mech => its creating factory
    mapping(address => address) public mapAgentMechFactories;
    // Map of payment type => balanceTracker address
    mapping(bytes32 => address) public mapPaymentTypeBalanceTrackers;
    // Mapping of account nonces
    mapping(address => uint256) public mapNonces;
    // Mapping of service ids to mechs
    mapping(uint256 => address) public mapServiceIdMech;


    /// @dev MechMarketplace constructor.
    /// @param _serviceRegistry Service registry contract address.
    /// @param _karma Karma proxy contract address.
    constructor(address _serviceRegistry, address _karma) {
        // Check for zero address
        if (_serviceRegistry == address(0) || _karma == address(0)) {
            revert ZeroAddress();
        }

        serviceRegistry = _serviceRegistry;
        karma = _karma;

        // Record chain Id
        chainId = block.chainid;
        // Compute domain separator
        domainSeparator = _computeDomainSeparator();
    }

    /// @dev Computes domain separator hash.
    /// @return Hash of the domain separator based on its name, version, chain Id and contract address.
    function _computeDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_SEPARATOR_TYPE_HASH,
                keccak256("MechMarketplace"),
                keccak256(abi.encode(VERSION)),
                block.chainid,
                address(this)
            )
        );
    }

    /// @dev Changes marketplace params.
    /// @param newFee New marketplace fee.
    /// @param newMinResponseTimeout New min response time in sec.
    /// @param newMaxResponseTimeout New max response time in sec.
    function _changeMarketplaceParams(
        uint256 newFee,
        uint256 newMinResponseTimeout,
        uint256 newMaxResponseTimeout
    ) internal {
        // Check for zero values
        if (newMinResponseTimeout == 0 || newMaxResponseTimeout == 0) {
            revert ZeroValue();
        }

        // Check for fee value
        if (newFee > MAX_FEE_FACTOR) {
            revert Overflow(newFee, MAX_FEE_FACTOR);
        }

        // Check for sanity values
        if (newMinResponseTimeout > newMaxResponseTimeout) {
            revert Overflow(newMinResponseTimeout, newMaxResponseTimeout);
        }

        // responseTimeout limits
        if (newMaxResponseTimeout > type(uint32).max) {
            revert Overflow(newMaxResponseTimeout, type(uint32).max);
        }

        fee = newFee;
        minResponseTimeout = newMinResponseTimeout;
        maxResponseTimeout = newMaxResponseTimeout;
    }

    /// @dev Registers batch of requests.
    /// @notice The request is going to be registered for a specified priority mech.
    /// @param requestDatas Set of self-descriptive opaque request data-blobs.
    /// @param priorityMechServiceId Priority mech service Id.
    /// @param requesterServiceId Requester service Id, or zero if EOA.
    /// @param responseTimeout Relative response time in sec.
    /// @param paymentData Additional payment-related request data (optional).
    /// @return requestIds Set of request Ids.
    function _requestBatch(
        bytes[] memory requestDatas,
        uint256 priorityMechServiceId,
        uint256 requesterServiceId,
        uint256 responseTimeout,
        bytes memory paymentData
    ) internal returns (bytes32[] memory requestIds) {
        // Response timeout limits
        if (responseTimeout + block.timestamp > type(uint32).max) {
            revert Overflow(responseTimeout + block.timestamp, type(uint32).max);
        }

        // Response timeout bounds
        if (responseTimeout < minResponseTimeout || responseTimeout > maxResponseTimeout) {
            revert OutOfBounds(responseTimeout, minResponseTimeout, maxResponseTimeout);
        }

        uint256 numRequests = requestDatas.length;
        // Check for zero value
        if (numRequests == 0) {
            revert ZeroValue();
        }

        // Check priority mech
        address priorityMech = mapServiceIdMech[priorityMechServiceId];
        if (priorityMech == address(0)) {
            revert ZeroAddress();
        }

        // Check requester
        checkRequester(msg.sender, requesterServiceId);

        // Allocate set of requestIds
        requestIds = new bytes32[](numRequests);

        // Get deliveryRate as priority mech max delivery rate
        uint256 deliveryRate = IMech(priorityMech).maxDeliveryRate();

        // Get priority mech payment type
        bytes32 paymentType = IMech(priorityMech).paymentType();

        // Get nonce
        uint256 nonce = mapNonces[msg.sender];

        // Traverse all requests
        for (uint256 i = 0; i < requestDatas.length; ++i) {
            // Check for non-zero data
            if (requestDatas[i].length == 0) {
                revert ZeroValue();
            }

            // Calculate request Id
            requestIds[i] = getRequestId(msg.sender, requestDatas[i], nonce);

            // Get request info struct
            RequestInfo storage requestInfo = mapRequestIdInfos[requestIds[i]];

            // Check for request Id record
            if (requestInfo.priorityMech != address(0)) {
                revert AlreadyRequested(requestIds[i]);
            }

            // Record priorityMech and response timeout
            requestInfo.priorityMech = priorityMech;
            // responseTimeout from relative time to absolute time
            requestInfo.responseTimeout = responseTimeout + block.timestamp;
            // Record request account
            requestInfo.requester = msg.sender;
            // Record deliveryRate for request as priority mech max delivery rate
            requestInfo.deliveryRate = deliveryRate;
            // Record priority mech payment type
            requestInfo.paymentType = paymentType;

            nonce++;
        }

        // Update requester nonce
        mapNonces[msg.sender] = nonce;

        // Get balance tracker address
        address balanceTracker = mapPaymentTypeBalanceTrackers[paymentType];

        // Check and record mech delivery rate
        IBalanceTracker(balanceTracker).checkAndRecordDeliveryRates{value: msg.value}(msg.sender, numRequests,
            deliveryRate, paymentData);

        // Increase mech requester karma
        IKarma(karma).changeRequesterMechKarma(msg.sender, priorityMech, int256(numRequests));

        // Record the request count
        mapRequestCounts[msg.sender] += numRequests;
        // Increase the number of undelivered requests
        numUndeliveredRequests += numRequests;
        // Increase the total number of requests
        numTotalRequests += numRequests;

        // Process request by a specified priority mech
        IMech(priorityMech).requestFromMarketplace(requestIds, requestDatas);

        emit MarketplaceRequest(priorityMech, msg.sender, numRequests, requestIds);
    }

    /// @dev Verifies provided request hash against its signature.
    /// @param requester Requester address.
    /// @param requestHash Request hash.
    /// @param signature Signature bytes associated with the signed request hash.
    function _verifySignedHash(address requester, bytes32 requestHash, bytes memory signature) internal view {
        // Check for zero address
        if (requester == address(0)) {
            revert ZeroAddress();
        }

        // Check EIP-1271 signature validity if requester is a contract
        if (requester.code.length > 0) {
            if (ISignatureValidator(requester).isValidSignature(requestHash, signature) == MAGIC_VALUE) {
                return;
            } else {
                revert SignatureNotValidated(requester, requestHash, signature);
            }
        }

        // Check for the signature length
        if (signature.length != 65) {
            revert IncorrectSignatureLength(signature, signature.length, 65);
        }

        // Decode the signature
        uint8 v = uint8(signature[64]);

        // For the correct ecrecover() function execution, the v value must be set to {0,1} + 27
        // Although v in a very rare case can be equal to {2,3} (with a probability of 3.73e-37%)
        // If v is set to just 0 or 1 when signing by the EOA, it is most likely signed by the ledger and must be adjusted
        if (v < 4) {
            // In case of a non-contract, adjust v to follow the standard ecrecover case
            v += 27;
        }

        bytes32 r;
        bytes32 s;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
        }

        // Case of ecrecover with the request hash for EOA signatures
        address recRequester = ecrecover(requestHash, v, r, s);

        // Final check is for the requester address itself
        if (recRequester != requester) {
            revert SignatureNotValidated(requester, requestHash, signature);
        }
    }

    /// @dev MechMarketplace initializer.
    /// @param _fee Marketplace fee.
    /// @param _minResponseTimeout Min response time in sec.
    /// @param _maxResponseTimeout Max response time in sec.
    function initialize(uint256 _fee, uint256 _minResponseTimeout, uint256 _maxResponseTimeout) external {
        if (owner != address(0)) {
            revert AlreadyInitialized();
        }

        _changeMarketplaceParams(_fee, _minResponseTimeout, _maxResponseTimeout);

        owner = msg.sender;
        _locked = 1;
    }

    /// @dev Changes contract owner address.
    /// @param newOwner Address of a new owner.
    function changeOwner(address newOwner) external virtual {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check for the zero address
        if (newOwner == address(0)) {
            revert ZeroAddress();
        }

        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    /// @dev Changes the mechMarketplace implementation contract address.
    /// @param newImplementation New implementation contract address.
    function changeImplementation(address newImplementation) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check for zero address
        if (newImplementation == address(0)) {
            revert ZeroAddress();
        }

        // Store the mechMarketplace implementation address
        // solhint-disable-next-line no-inline-assembly
        assembly {
            sstore(MECH_MARKETPLACE_PROXY, newImplementation)
        }

        emit ImplementationUpdated(newImplementation);
    }

    /// @dev Changes marketplace params.
    /// @param newFee New marketplace fee.
    /// @param newMinResponseTimeout New min response time in sec.
    /// @param newMaxResponseTimeout New max response time in sec.
    function changeMarketplaceParams(
        uint256 newFee,
        uint256 newMinResponseTimeout,
        uint256 newMaxResponseTimeout
    ) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        _changeMarketplaceParams(newFee, newMinResponseTimeout, newMaxResponseTimeout);

        emit MarketplaceParamsUpdated(newFee, newMinResponseTimeout, newMaxResponseTimeout);
    }

    /// @dev Registers service as a mech.
    /// @param serviceId Service id.
    /// @param mechFactory Mech factory address.
    /// @return mech The created mech instance address.
    function create(uint256 serviceId, address mechFactory, bytes memory payload) external returns (address mech) {
        // Check for factory status
        if (!mapMechFactories[mechFactory]) {
            revert UnauthorizedAccount(mechFactory);
        }

        mech = IMechFactory(mechFactory).createMech(serviceRegistry, serviceId, payload);

        // This should never be the case
        if (mech == address(0)) {
            revert ZeroAddress();
        }

        // Record factory that created a mech
        mapAgentMechFactories[mech] = mechFactory;
        // Add mapping
        mapServiceIdMech[serviceId] = mech;
        numMechs++;

        emit CreateMech(mech, serviceId);
    }

    /// @dev Sets mech factory statues.
    /// @param mechFactories Mech marketplace contract addresses.
    /// @param statuses Corresponding whitelisting statues.
    function setMechFactoryStatuses(address[] memory mechFactories, bool[] memory statuses) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        if (mechFactories.length != statuses.length) {
            revert WrongArrayLength(mechFactories.length, statuses.length);
        }

        // Traverse all the mech marketplaces and statuses
        for (uint256 i = 0; i < mechFactories.length; ++i) {
            if (mechFactories[i] == address(0)) {
                revert ZeroAddress();
            }

            mapMechFactories[mechFactories[i]] = statuses[i];
        }

        emit SetMechFactoryStatuses(mechFactories, statuses);
    }

    /// @dev Sets mech payment type balanceTrackers.
    /// @param paymentTypes Mech types.
    /// @param balanceTrackers Corresponding balanceTracker addresses.
    function setPaymentTypeBalanceTrackers(bytes32[] memory paymentTypes, address[] memory balanceTrackers) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        if (paymentTypes.length != balanceTrackers.length) {
            revert WrongArrayLength(paymentTypes.length, balanceTrackers.length);
        }

        // Traverse all the mech types and balanceTrackers
        for (uint256 i = 0; i < paymentTypes.length; ++i) {
            // Check for zero value
            if (paymentTypes[i] == 0) {
                revert ZeroValue();
            }

            // Check for zero address
            if (balanceTrackers[i] == address(0)) {
                revert ZeroAddress();
            }

            mapPaymentTypeBalanceTrackers[paymentTypes[i]] = balanceTrackers[i];
        }

        emit SetPaymentTypeBalanceTrackers(paymentTypes, balanceTrackers);
    }

    /// @dev Registers a request.
    /// @notice The request is going to be registered for a specified priority mech.
    /// @param requestData Self-descriptive opaque request data-blob.
    /// @param priorityMechServiceId Priority mech service Id.
    /// @param requesterServiceId Requester service Id, or zero if EOA.
    /// @param responseTimeout Relative response time in sec.
    /// @param paymentData Additional payment-related request data (optional).
    /// @return requestId Request Id.
    function request(
        bytes memory requestData,
        uint256 priorityMechServiceId,
        uint256 requesterServiceId,
        uint256 responseTimeout,
        bytes memory paymentData
    ) external payable returns (bytes32 requestId) {
        // Reentrancy guard
        if (_locked == 2) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Allocate arrays
        bytes[] memory requestDatas = new bytes[](1);
        bytes32[] memory requestIds = new bytes32[](1);

        requestDatas[0] = requestData;
        requestIds = _requestBatch(requestDatas, priorityMechServiceId, requesterServiceId, responseTimeout, paymentData);

        requestId = requestIds[0];

        _locked = 1;
    }

    /// @dev Registers batch of requests.
    /// @notice The request is going to be registered for a specified priority mech.
    /// @param requestDatas Set of self-descriptive opaque request data-blobs.
    /// @param priorityMechServiceId Priority mech service Id.
    /// @param requesterServiceId Requester service Id, or zero if EOA.
    /// @param responseTimeout Relative response time in sec.
    /// @param paymentData Additional payment-related request data (optional).
    /// @return requestIds Set of request Ids.
    function requestBatch(
        bytes[] memory requestDatas,
        uint256 priorityMechServiceId,
        uint256 requesterServiceId,
        uint256 responseTimeout,
        bytes memory paymentData
    ) external payable returns (bytes32[] memory requestIds) {
        // Reentrancy guard
        if (_locked == 2) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        requestIds = _requestBatch(requestDatas, priorityMechServiceId, requesterServiceId, responseTimeout, paymentData);

        _locked = 1;
    }

    /// @dev Delivers requests.
    /// @notice This function can only be called by the mech delivering the request.
    /// @param requestIds Set of request ids.
    /// @param deliveryRates Corresponding set of actual charged delivery rates for each request.
    /// @param deliveryDatas Set of corresponding self-descriptive opaque delivery data-blobs.
    function deliverMarketplace(
        bytes32[] memory requestIds,
        uint256[] memory deliveryRates,
        bytes[] memory deliveryDatas
    ) external returns (bool[] memory deliveredRequests) {
        // Reentrancy guard
        if (_locked == 2) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Check array lengths
        if (requestIds.length == 0 || requestIds.length != deliveryRates.length ||
            requestIds.length != deliveryDatas.length) {
            revert WrongArrayLength3(requestIds.length, deliveryRates.length, deliveryDatas.length);
        }

        // Check delivery mech and get its service multisig
        address mechServiceMultisig = checkMech(msg.sender);

        uint256 numDeliveries;
        uint256 numRequests = requestIds.length;
        // Allocate delivered requests array
        deliveredRequests = new bool[](numRequests);
        // Allocate requester related arrays
        address[] memory requesters = new address[](numRequests);
        uint256[] memory requesterDeliveryRates = new uint256[](numRequests);

        // Get delivery mech payment type
        bytes32 paymentType = IMech(msg.sender).paymentType();

        // Traverse all requests being delivered
        for (uint256 i = 0; i < numRequests; ++i) {
            // Get request info struct
            RequestInfo storage requestInfo = mapRequestIdInfos[requestIds[i]];
            address priorityMech = requestInfo.priorityMech;

            // Check for request existence
            if (priorityMech == address(0)) {
                revert ZeroAddress();
            }

            // Check payment type
            if (requestInfo.paymentType != paymentType) {
                revert WrongPaymentType(paymentType);
            }

            // Check if request has been delivered
            if (requestInfo.deliveryMech != address(0)) {
                continue;
            }

            // Check for actual mech delivery rate
            // If the rate of the mech is higher than set by the requester, the request is ignored and considered
            // undelivered, such that it's cleared from mech's records and delivered by other mechs matching the rate
            requesterDeliveryRates[i] = requestInfo.deliveryRate;
            if (deliveryRates[i] > requesterDeliveryRates[i]) {
                continue;
            }

            // If delivery mech is different from the priority one
            if (priorityMech != msg.sender) {
                // Within the defined response time only a chosen priority mech is able to deliver
                if (block.timestamp > requestInfo.responseTimeout) {
                    // Decrease priority mech karma as the mech did not deliver
                    // Needs to stay atomic as each different priorityMech can be any address
                    IKarma(karma).changeMechKarma(priorityMech, -1);
                } else {
                    // Priority mech responseTimeout is still >= block.timestamp
                    revert PriorityMechResponseTimeout(requestInfo.responseTimeout, block.timestamp);
                }
            }

            // Record the actual delivery mech
            requestInfo.deliveryMech = msg.sender;

            // Record requester
            requesters[i] = requestInfo.requester;

            // Increase the amount of requester delivered requests
            mapDeliveryCounts[requesters[i]]++;

            // Mark request as delivered
            deliveredRequests[i] = true;
            numDeliveries++;
        }

        if (numDeliveries > 0) {
            // Decrease the number of undelivered requests
            numUndeliveredRequests -= numDeliveries;
            // Increase the amount of mech delivery counts
            mapMechDeliveryCounts[msg.sender] += numDeliveries;
            // Increase the amount of mech service multisig delivered requests
            mapMechServiceDeliveryCounts[mechServiceMultisig] += numDeliveries;

            // Increase mech karma that delivers the request
            IKarma(karma).changeMechKarma(msg.sender, int256(numDeliveries));

            // Get balance tracker address
            address balanceTracker = mapPaymentTypeBalanceTrackers[paymentType];

            // Process payment
            IBalanceTracker(balanceTracker).finalizeDeliveryRates(msg.sender, requesters, deliveredRequests,
                deliveryRates, requesterDeliveryRates);
        }

        emit MarketplaceDelivery(msg.sender, requesters, numDeliveries, requestIds, deliveredRequests);

        _locked = 1;
    }
    
    /// @dev Delivers signed requests.
    /// @notice This function must be called by mech delivering requests.
    /// @param requester Requester address.
    /// @param requesterServiceId Requester service Id, or zero if EOA.
    /// @param requestDatas Corresponding set of self-descriptive opaque request data-blobs.
    /// @param signatures Corresponding set of signatures.
    /// @param deliveryRates Corresponding set of actual charged delivery rates for each request.
    /// @param deliveryDatas Corresponding set of self-descriptive opaque delivery data-blobs.
    /// @param paymentData Additional payment-related request data, if applicable.
    function deliverMarketplaceWithSignatures(
        address requester,
        uint256 requesterServiceId,
        bytes[] memory requestDatas,
        bytes[] memory signatures,
        bytes[] memory deliveryDatas,
        uint256[] memory deliveryRates,
        bytes memory paymentData
    ) external {
        // Reentrancy guard
        if (_locked == 2) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Array length checks
        if (requestDatas.length == 0 || requestDatas.length != signatures.length ||
            requestDatas.length != deliveryDatas.length || requestDatas.length != deliveryRates.length) {
            revert WrongArrayLength4(requestDatas.length, signatures.length, deliveryDatas.length, deliveryRates.length);
        }

        // Check mech
        address mechServiceMultisig = checkMech(msg.sender);

        // Check requester
        checkRequester(requester, requesterServiceId);

        uint256 numRequests = requestDatas.length;

        // Get number of requests
        // Allocate set for request Ids
        bytes32[] memory requestIds = new bytes32[](numRequests);

        // Get current nonce
        uint256 nonce = mapNonces[requester];

        // Traverse all request Ids
        for (uint256 i = 0; i < numRequests; ++i) {
            // Calculate request Id
            requestIds[i] = getRequestId(requester, requestDatas[i], nonce);

            // Verify the signed hash against the operator address
            _verifySignedHash(requester, requestIds[i], signatures[i]);

            // Get request info struct
            RequestInfo storage requestInfo = mapRequestIdInfos[requestIds[i]];

            // Check for request Id record
            if (requestInfo.priorityMech != address(0)) {
                revert AlreadyRequested(requestIds[i]);
            }

            // Record all the request info
            requestInfo.priorityMech = msg.sender;
            requestInfo.deliveryMech = msg.sender;
            requestInfo.requester = requester;
            requestInfo.deliveryRate = deliveryRates[i];

            // Increase nonce
            nonce++;

            // Symmetrical delivery mech event that in general happens when delivery is called directly through the mech
            emit Deliver(msg.sender, mechServiceMultisig, requestIds[i], deliveryDatas[i]);
        }

        // Adjust requester nonce values
        mapNonces[requester] = nonce;

        // Increase the amount of requester delivered requests
        mapDeliveryCounts[requester]++;
        // Increase the amount of mech delivery counts
        mapMechDeliveryCounts[msg.sender]++;
        // Increase the amount of mech service multisig delivered requests
        mapMechServiceDeliveryCounts[mechServiceMultisig]++;

        // Increase mech requester karma
        IKarma(karma).changeRequesterMechKarma(requester, msg.sender, int256(numRequests));
        // Increase mech karma that delivers the request
        IKarma(karma).changeMechKarma(msg.sender, int256(numRequests));

        // Get balance tracker address
        address balanceTracker = mapPaymentTypeBalanceTrackers[IMech(msg.sender).paymentType()];

        // Process mech payment
        IBalanceTracker(balanceTracker).adjustMechRequesterBalances(msg.sender, requester, deliveryRates, paymentData);

        // Update mech stats
        IMech(msg.sender).updateNumRequests(numRequests);

        emit MarketplaceDeliveryWithSignatures(msg.sender, requester, numRequests, requestIds);

        _locked = 1;
    }

    /// @dev Gets the already computed domain separator of recomputes one if the chain Id is different.
    /// @return Original or recomputed domain separator.
    function getDomainSeparator() public view returns (bytes32) {
        return block.chainid == chainId ? domainSeparator : _computeDomainSeparator();
    }

    /// @dev Gets the request Id.
    /// @param account Account address.
    /// @param data Self-descriptive opaque data-blob.
    /// @param nonce Nonce.
    /// @return requestId Corresponding request Id.
    function getRequestId(
        address account,
        bytes memory data,
        uint256 nonce
    ) public view returns (bytes32 requestId) {
        requestId = keccak256(
            abi.encodePacked(
                "\x19\x01",
                getDomainSeparator(),
                keccak256(
                    abi.encode(
                        address(this),
                        account,
                        data,
                        nonce
                    )
                )
            )
        );
    }

    /// @dev Checks for mech validity.
    /// @param mech Mech contract address.
    /// @return multisig Mech service multisig address.
    function checkMech(address mech) public view returns (address multisig) {
        // Check for zero address
        if (mech == address(0)) {
            revert ZeroAddress();
        }

        uint256 mechServiceId = IMech(mech).tokenId();

        // Check mech validity as it must be created and recorded via this marketplace
        if (mapServiceIdMech[mechServiceId] != mech) {
            revert UnauthorizedAccount(mech);
        }

        // Check mech service Id and get its multisig
        multisig = IMech(mech).getOperator();
    }

    /// @dev Checks for requester validity.
    /// @notice Explicitly allows to proceed for EOAs without service id.
    /// @param requester Requester address.
    /// @param requesterServiceId Requester service Id.
    function checkRequester(address requester, uint256 requesterServiceId) public view {
        // Check for requester service
        if (requesterServiceId > 0) {
            (, address multisig, , , , , IServiceRegistry.ServiceState state) =
                IServiceRegistry(serviceRegistry).mapServices(requesterServiceId);

            // Check for correct service state
            if (state != IServiceRegistry.ServiceState.Deployed) {
                revert WrongServiceState(uint256(state), requesterServiceId);
            }

            // Check staked service multisig
            if (multisig != requester) {
                revert OwnerOnly(requester, multisig);
            }
        }
    }

    /// @dev Gets the request Id status.
    /// @param requestId Request Id.
    /// @return status Request status.
    function getRequestStatus(bytes32 requestId) external view returns (RequestStatus status) {
        // Request exists if it has a record in the mapRequestIdInfos
        RequestInfo memory requestInfo = mapRequestIdInfos[requestId];
        if (requestInfo.priorityMech != address(0)) {
            // Check if the request Id was already delivered: delivery mech address is not zero
            if (requestInfo.deliveryMech == address(0)) {
                if (block.timestamp > requestInfo.responseTimeout) {
                    status = RequestStatus.RequestedExpired;
                } else {
                    status = RequestStatus.RequestedPriority;
                }
            } else {
                status = RequestStatus.Delivered;
            }
        }
    }
}

