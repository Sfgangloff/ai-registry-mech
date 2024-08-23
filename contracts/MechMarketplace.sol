// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// Agent Mech interface
interface IMech {
    /// @dev Checks if the signer is the mech operator.
    function isOperator(address signer) external view returns (bool);

    /// @dev Registers a request.
    /// @param account Requester account address.
    /// @param data Self-descriptive opaque data-blob.
    /// @param requestId Request Id.
    function requestMarketplace(address account, bytes memory data, uint256 requestId) external payable;

    /// @dev Revokes the request from the mech that does not deliver it.
    /// @notice Only marketplace can call this function if the request is not delivered by the chosen priority mech.
    /// @param requestId Request Id.
    function revokeRequest(uint256 requestId) external;
}

// Karma interface
interface IKarma {
    /// @dev Changes agent mech karma.
    /// @param mech Agent mech address.
    /// @param karmaChange Karma change value.
    function changeMechKarma(address mech, int256 karmaChange) external;

    /// @dev Changes requester -> agent mech karma.
    /// @param requester Requester address.
    /// @param mech Agent mech address.
    /// @param karmaChange Karma change value.
    function changeRequesterMechKarma(address requester, address mech, int256 karmaChange) external;
}

// Staking interface
interface IStaking {
    enum StakingState {
        Unstaked,
        Staked,
        Evicted
    }

    // Service Info struct
    struct ServiceInfo {
        // Service multisig address
        address multisig;
        // Service owner
        address owner;
        // Service multisig nonces
        uint256[] nonces;
        // Staking start time
        uint256 tsStart;
        // Accumulated service staking reward
        uint256 reward;
        // Accumulated inactivity that might lead to the service eviction
        uint256 inactivity;
    }

    /// @dev Gets the service staking state.
    /// @param requesterServiceId.
    /// @return stakingState Staking state of the service.
    function getStakingState(uint256 requesterServiceId) external view returns (StakingState stakingState);
    /// @dev Gets staked service info.
    /// @param requesterServiceId Service Id.
    /// @return sInfo Struct object with the corresponding service info.
    function getServiceInfo(uint256 requesterServiceId) external view returns (ServiceInfo memory);
}

/// @dev Only `owner` has a privilege, but the `sender` was provided.
/// @param sender Sender address.
/// @param owner Required sender address as an owner.
error OwnerOnly(address sender, address owner);

/// @dev Provided zero address.
error ZeroAddress();

/// @dev Provided zero value.
error ZeroValue();

/// @dev Agent does not exist.
/// @param agentId Agent Id.
error AgentNotFound(uint256 agentId);

/// @dev Not enough value paid.
/// @param provided Provided amount.
/// @param expected Expected amount.
error NotEnoughPaid(uint256 provided, uint256 expected);

/// @dev Request Id not found.
/// @param requestId Request Id.
error RequestIdNotFound(uint256 requestId);

/// @dev Value overflow.
/// @param provided Overflow value.
/// @param max Maximum possible value.
error Overflow(uint256 provided, uint256 max);

/// @dev Provided account is not a contract.
/// @param account Account address.
error NotContract(address account);

/// @dev Caught reentrancy violation.
error ReentrancyGuard();

/// @dev Account is unauthorized.
/// @param account Account address.
error UnauthorizedAccount(address account);

/// @dev Provided value is out of bounds.
/// @param provided value.
/// @param min Minimum possible value.
/// @param max Maximum possible value.
error OutOfBounds(uint256 provided, uint256 min, uint256 max);

/// @dev The request is already delivered.
/// @param requestId Request Id.
error AlreadyDelivered(uint256 requestId);

/// @dev Priority mech response timeout is not yet met.
/// @param expected Expected timestamp.
/// @param current Current timestamp.
error PriorityMechResponseTimeout(uint256 expected, uint256 current);

// Mech delivery info struct
struct MechDelivery {
    // Priority mech address
    address priorityMech;
    // Delivery mech address
    address deliveryMech;
    // Account address sending the request
    address account;
    // Response timeout window
    uint32 responseTimeout;
}

/// @title Mech Marketplace - Marketplace for posting and delivering requests served by agent mechs
contract MechMarketplace {
    event OwnerUpdated(address indexed owner);
    event FactoryUpdated(address indexed factory);
    event MinMaxResponseTimeoutUpdated(uint256 minResponseTimeout, uint256 maxResponseTimeout);
    event MechRegistrationStatusChanged(address indexed mech, bool status);
    event MarketplaceRequest(address indexed requester, address indexed requestedMech, uint256 requestId, bytes data);
    event MarketplaceDeliver(address indexed priorityMech, address indexed actualMech, address indexed requester,
        uint256 requestId, bytes data);

    enum RequestStatus {
        DoesNotExist,
        RequestedPriority,
        RequestedExpired,
        Delivered
    }

    // Contract version number
    string public constant VERSION = "1.0.0";
    // Domain separator type hash
    bytes32 public constant DOMAIN_SEPARATOR_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    // Original domain separator value
    bytes32 public immutable domainSeparator;
    // Original chain Id
    uint256 public immutable chainId;
    // Minimum response time
    uint256 public immutable minResponseTimeout;
    // Maximum response time
    uint256 public immutable maxResponseTimeout;
    // Approved mech bytecode hash
    bytes32 public immutable mechBytecodeHash;
    // Mech karma contract address
    address public immutable karmaProxy;
    // Agent mech factory contract address
    address public immutable mechStakingInstance;

    // Number of undelivered requests
    uint256 public numUndeliveredRequests;
    // Number of total requests
    uint256 public numTotalRequests;
    // Number of total deliveries
    uint256 public numTotalDeliveries;
    // Reentrancy lock
    uint256 internal _locked = 1;

    // Mapping of request Id => mech delivery information
    mapping(uint256 => MechDelivery) public mapRequestIdDeliveries;
    // Mapping of account nonces
    mapping(address => uint256) public mapNonces;

    /// @dev MechMarketplace constructor.
    /// @param _mechStakingInstance Agent mech staking instance address.
    /// @param _karmaProxy Karma proxy contract address.
    /// @param _minResponseTimeout Min response time in sec.
    /// @param _maxResponseTimeout Max response time in sec.
    /// @param _agentMechBytecodeHash Approved agent mech bytecode hash.
    constructor(
        address _mechStakingInstance,
        address _karmaProxy,
        uint256 _minResponseTimeout,
        uint256 _maxResponseTimeout,
        bytes32 _agentMechBytecodeHash
    ) {
        // Check for zero address
        if (_mechStakingInstance == address(0) || _karmaProxy == address(0)) {
            revert ZeroAddress();
        }

        // Check for zero values
        if (_minResponseTimeout == 0 || _maxResponseTimeout == 0 || mechBytecodeHash == 0) {
            revert ZeroValue();
        }

        // Check for sanity values
        if (_minResponseTimeout > _maxResponseTimeout) {
            revert Overflow(_minResponseTimeout, _maxResponseTimeout);
        }

        // responseTimeout limits
        if (_maxResponseTimeout > type(uint32).max) {
            revert Overflow(_maxResponseTimeout, type(uint32).max);
        }

        mechStakingInstance = _mechStakingInstance;
        karmaProxy = _karmaProxy;
        minResponseTimeout = _minResponseTimeout;
        maxResponseTimeout = _maxResponseTimeout;
        mechBytecodeHash = _agentMechBytecodeHash;

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

    /// @dev Checks agent mech for contract validity.
    /// @param mech Agent mech address.
    /// @param mechServiceId Mech operator service Id.
    function checkMech(address mech, uint256 mechServiceId) public view {
        // Check that the mech address corresponds to the authorized bytecode hash
        bytes32 mechHash = keccak256(mech.code);
        if (mechHash != mechBytecodeHash) {
            revert UnauthorizedAccount(mech);
        }

        // Check if the mech service is staked
        IStaking.StakingState state = IStaking(mechStakingInstance).getStakingState(mechServiceId);
        if (state != IStaking.StakingState.Staked) {
            revert();
        }

        // Get the staked service info
        IStaking.ServiceInfo memory serviceInfo = IStaking(mechStakingInstance).getServiceInfo(mechServiceId);
        // Check that staked service multisig is the priority mech operator
        if (!IMech(mech).isOperator(serviceInfo.multisig)) {
            revert UnauthorizedAccount(mech);
        }
    }

    /// @dev Registers a request.
    /// @notice The request is going to be registered by a specified priority agent mech.
    /// @param data Self-descriptive opaque data-blob.
    /// @param priorityMech Address of a priority mech.
    /// @param priorityMechServiceId Priority mech operator service Id.
    /// @param responseTimeout Relative response time in sec.
    /// @param requesterStakingInstance Staking instance of a service whose multisig posts a request.
    /// @param requesterServiceId Corresponding service Id in the staking contract.
    /// @return requestId Request Id.
    function request(
        bytes memory data,
        address priorityMech,
        uint256 priorityMechServiceId,
        uint256 responseTimeout,
        address requesterStakingInstance,
        uint256 requesterServiceId
    ) external payable returns (uint256 requestId) {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Check for zero address
        if (priorityMech == address(0)) {
            revert ZeroAddress();
        }
        // responseTimeout bounds
        if (responseTimeout < minResponseTimeout || responseTimeout > maxResponseTimeout) {
            revert OutOfBounds(responseTimeout, minResponseTimeout, maxResponseTimeout);
        }
        // responseTimeout limits
        if (responseTimeout + block.timestamp > type(uint32).max) {
            revert Overflow(responseTimeout + block.timestamp, type(uint32).max);
        }
        // Check for non-zero data
        if (data.length == 0) {
            revert ZeroValue();
        }

        // Check agent mech
        checkMech(priorityMech, priorityMechServiceId);

        // Check if the requester service is staked
        IStaking.StakingState state = IStaking(requesterStakingInstance).getStakingState(requesterServiceId);
        if (state != IStaking.StakingState.Staked) {
            revert();
        }

        // Get the staked service info
        IStaking.ServiceInfo memory serviceInfo = IStaking(requesterStakingInstance).getServiceInfo(requesterServiceId);
        // Check staked service multisig
        if (serviceInfo.multisig != msg.sender) {
            revert OwnerOnly(msg.sender, serviceInfo.multisig);
        }

        // Get the request Id
        requestId = getRequestId(msg.sender, data, mapNonces[msg.sender]);

        // Update sender's nonce
        mapNonces[msg.sender]++;

        // Get mech delivery info struct
        MechDelivery storage mechDelivery = mapRequestIdDeliveries[requestId];

        // Record priorityMech and response timeout
        mechDelivery.priorityMech = priorityMech;
        // responseTimeout from relative time to absolute time
        mechDelivery.responseTimeout = uint32(responseTimeout + block.timestamp);
        // Record request account
        mechDelivery.account = msg.sender;

        // Increase mech requester karma
        IKarma(karmaProxy).changeRequesterMechKarma(msg.sender, priorityMech, 1);

        // Increase the number of undelivered requests
        numUndeliveredRequests++;
        // Increase the total number of requests
        numTotalRequests++;

        // Process request by a specified priority mech
        IMech(priorityMech).requestMarketplace{value: msg.value}(msg.sender, data, requestId);

        emit MarketplaceRequest(msg.sender, priorityMech, requestId, data);

        _locked = 1;
    }

    /// @dev Delivers a request.
    /// @notice This function can only be called by the agent mech delivering the request.
    /// @param requestId Request id.
    /// @param requestData Self-descriptive opaque data-blob.
    /// @param deliveryMechServiceId Mech operator service Id.
    function deliverMarketplace(uint256 requestId, bytes memory requestData, uint256 deliveryMechServiceId) external {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Check delivery agent mech
        checkMech(msg.sender, deliveryMechServiceId);

        // Get mech delivery info struct
        MechDelivery storage mechDelivery = mapRequestIdDeliveries[requestId];
        address priorityMech = mechDelivery.priorityMech;

        // Check for request existence
        if (priorityMech == address(0)) {
            revert ZeroAddress();
        }

        address account = mechDelivery.account;
        // Check that the request is not already delivered
        if (mechDelivery.deliveryMech != address(0)) {
            revert AlreadyDelivered(requestId);
        }

        // If delivery mech is different from the priority one
        if (priorityMech != msg.sender) {
            // Within the defined response time only a chosen priority mech is able to deliver
            if (block.timestamp > mechDelivery.responseTimeout) {
                // Decrease priority mech karma as the mech did not deliver
                IKarma(karmaProxy).changeMechKarma(priorityMech, -1);
                // Revoke request from the priority mech
                IMech(priorityMech).revokeRequest(requestId);
            } else {
                // Priority mech responseTimeout is still >= block.timestamp
                revert PriorityMechResponseTimeout(mechDelivery.responseTimeout, block.timestamp);
            }
        }

        // Record the actual delivery mech
        mechDelivery.deliveryMech = msg.sender;

        // Decrease the number of undelivered requests
        numUndeliveredRequests--;
        // Increase the number of deliveries
        numTotalDeliveries++;

        // Increase mech karma that delivers the request
        IKarma(karmaProxy).changeMechKarma(msg.sender, 1);

        emit MarketplaceDeliver(priorityMech, msg.sender, account, requestId, requestData);

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
    ) public view returns (uint256 requestId) {
        requestId = uint256(keccak256(
            abi.encodePacked(
                "\x19\x01",
                getDomainSeparator(),
                keccak256(
                    abi.encode(
                        account,
                        data,
                        nonce
                    )
                )
            )
        ));
    }

    /// @dev Gets the request Id status.
    /// @param requestId Request Id.
    /// @return status Request status.
    function getRequestStatus(uint256 requestId) external view returns (RequestStatus status) {
        // Request exists if it has a record in the mapRequestIdDeliveries
        MechDelivery memory mechDelivery = mapRequestIdDeliveries[requestId];
        if (mechDelivery.priorityMech != address(0)) {
            // Check if the request Id was already delivered: delivery mech address is not zero
            if (mechDelivery.deliveryMech == address(0)) {
                if (block.timestamp > mechDelivery.responseTimeout) {
                    status = RequestStatus.RequestedExpired;
                } else {
                    status = RequestStatus.RequestedPriority;
                }
            } else {
                status = RequestStatus.Delivered;
            }
        }
    }

    /// @dev Gets mech delivery info.
    /// @param requestId Request Id.
    /// @return Mech delivery info.
    function getMechDeliveryInfo(uint256 requestId) external view returns (MechDelivery memory) {
        return mapRequestIdDeliveries[requestId];
    }
}

