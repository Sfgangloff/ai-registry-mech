// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMechMarketplace {
    function deliverMarketplace(bytes32[] calldata requestIds, uint256[] calldata deliveryRates) external;
    function request(bytes memory data, uint256 maxDeliveryRate, bytes32 paymentType, uint256 priorityMechServiceId,
        uint256 responseTimeout, bytes memory paymentData) external payable returns (uint256);
}

contract MockMech {
    // Mech payment type
    bytes32 public constant paymentType = 0xba699a34be8fe0e7725e93dcbce1701b0211a8ca61330aaeb8a05bf2ec7abed1;

    address public immutable mechMarketplace;

    uint256 public maxDeliveryRate = 1;
    uint256 public serviceId = 99;
    bool public isNotSelf;

    constructor(address _mechMarketplace) {
        mechMarketplace = _mechMarketplace;
    }

    function setServiceId(uint256 _serviceId) external {
        serviceId = _serviceId;
    }

    function setNotSelf(bool _isNotSelf) external {
        isNotSelf = _isNotSelf;
    }

    function deliverMarketplace(bytes32[] calldata requestIds, uint256[] calldata deliveryRates) external {
        IMechMarketplace(mechMarketplace).deliverMarketplace(requestIds, deliveryRates);
    }

    function request(
        bytes memory data,
        uint256 priorityMaxDeliveryRate,
        bytes32 priorityPaymentType,
        uint256 priorityMechServiceId,
        uint256 responseTimeout,
        bytes memory paymentData
    ) external payable returns (uint256) {
        return IMechMarketplace(mechMarketplace).request{value: msg.value}(data, priorityMaxDeliveryRate,
            priorityPaymentType, priorityMechServiceId, responseTimeout, paymentData);
    }

    /// @dev Registers marketplace requests.
    function requestFromMarketplace(bytes32[] calldata, bytes[] calldata) external {}

    function tokenId() external view returns (uint256) {
        return serviceId;
    }

    function getOperator() external view returns (address) {
        if (isNotSelf) {
            return address(1);
        }

        return address(this);
    }

    function getFinalizedDeliveryRates(uint256) external pure returns (uint256) {
        return 1;
    }

    function isOperator(address) external pure returns (bool) {
        return true;
    }

    /// @dev Deposits funds for mech.
    receive() external payable {}
}