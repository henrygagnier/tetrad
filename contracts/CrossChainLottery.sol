// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IWETH.sol";

contract TetradLotteryMessenger is CCIPReceiver, OwnerIsCreator {
    using SafeERC20 for IERC20;

    // Custom errors to provide more descriptive revert messages.
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees); // Used to make sure contract has enough balance to cover the fees.

    struct CCIPData {
        address user;
        uint256 call;
        uint32[] tickets;
        uint256[] ticketIds;
        uint256 id;
        uint32[] brackets;
    }

    // Event emitted when a message is sent to another chain.
    event MessageSent(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
        address receiver, // The address of the receiver on the destination chain.
        CCIPData data, // The data being sent.
        address token, // The token address that was transferred.
        uint256 tokenAmount, // The token amount that was transferred.
        address feeToken, // the token address used to pay CCIP fees.
        uint256 fees // The fees paid for sending the message.
    );

    uint64 public destinationChainSelector = 4949039107694359620;
    IWETH public WETH;
    address destinationChainContract;
    mapping(address => bytes32[]) messageIds;

    constructor(address _router, address _destinationChainContract, address _WETH)
        CCIPReceiver(_router)
    {
        destinationChainContract = _destinationChainContract;
        WETH = IWETH(_WETH);
    }

    function buyTicketsWithEther(
        uint32[] calldata _tickets,
        uint256 _amount,
        uint256 _gasLimit,
        address _user
    ) external payable returns (bytes32 messageId) {
        WETH.deposit{value: _amount}();
        messageId = buyTickets(_tickets, _amount, msg.value - _amount, _gasLimit, _user);

        messageIds[_user].push(messageId);
        return (messageId);
    }

    function buyTicketsWithWETH(
        uint32[] calldata _tickets,
        uint256 _amount,
        uint256 _gasLimit,
        address _user
    ) external payable returns (bytes32 messageId) {
        WETH.transferFrom(msg.sender, address(this), _amount);
        messageId = buyTickets(_tickets, _amount, msg.value, _gasLimit, _user);

        messageIds[_user].push(messageId);
        return(messageId);
    }

    function buyTickets(
        uint32[] calldata _tickets,
        uint256 _amount,
        uint256 _CCIPFees,
        uint256 _gasLimit,
        address _user
    ) internal returns (bytes32 messageId) {
        (Client.EVM2AnyMessage memory evm2AnyMessage, CCIPData memory data) = getBuyTicketData(
            _tickets,
            _amount,
            _gasLimit,
            _user
        );

        IRouterClient router = IRouterClient(this.getRouter());

        uint256 fees = router.getFee(destinationChainSelector, evm2AnyMessage);

        if (fees > _CCIPFees) revert NotEnoughBalance(_CCIPFees, fees);

        // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
        WETH.approve(address(router), _amount);

        // Send the message through the router and store the returned message ID
        messageId = router.ccipSend{value: fees}(
            destinationChainSelector,
            evm2AnyMessage
        );

        emit MessageSent(
            messageId,
            destinationChainSelector,
            destinationChainContract,
            data,
            address(WETH),
            _amount,
            address(0),
            fees
        );

        payable(msg.sender).transfer(_CCIPFees - fees);

        messageIds[_user].push(messageId);
        return messageId;
    }

    function getBuyTicketData( //Also used for offchain calculations
        uint32[] calldata _tickets,
        uint256 _amount,
        uint256 _gasLimit,
        address _user
    ) public view returns (Client.EVM2AnyMessage memory evm2AnyMessage, CCIPData memory data) {
        data = CCIPData(
            _user,
            0,
            _tickets,
            new uint256[](0),
            0,
            new uint32[](0)
        );

        evm2AnyMessage = _buildCCIPMessageWithToken(
            data,
            _amount,
            address(0),
            _gasLimit
        );

        return (evm2AnyMessage,data);
    }

    function getClaimTicketData( //Also used for offchain calculations
        uint256 _id,
        uint256[] calldata _ticketIds,
        uint32[] calldata _brackets,
        uint256 _gasLimit,
        address _user
    ) public view returns (Client.EVM2AnyMessage memory evm2AnyMessage, CCIPData memory data) {
        data = CCIPData(
            _user,
            1,
            new uint32[](0),
            _ticketIds,
            _id,
            _brackets
        );

        evm2AnyMessage = _buildCCIPMessage(
            data,
            address(0),
            _gasLimit
        );

        return (evm2AnyMessage,data);
    }

    function estimateFeeBuyTickets(
        uint32[] calldata _tickets,
        uint256 _amount,
        uint256 _gasLimit,
        address _user
    ) public view returns (uint256 fee) {
        CCIPData memory data = CCIPData(
            _user,
            0,
            _tickets,
            new uint256[](0),
            0,
            new uint32[](0)
        );

        Client.EVM2AnyMessage
            memory evm2AnyMessage = _buildCCIPMessageWithToken(
                data,
                _amount,
                address(0),
                _gasLimit
            );

        IRouterClient router = IRouterClient(this.getRouter());

        fee = router.getFee(destinationChainSelector, evm2AnyMessage);

        return fee;
    }

    function estimateFeeClaimTickets(
        uint256 _id,
        uint256[] calldata _ticketIds,
        uint32[] calldata _brackets,
        uint256 _gasLimit,
        address _user
    ) external view returns (uint256 fee) {
        CCIPData memory data = CCIPData(
            _user,
            1,
            new uint32[](0),
            _ticketIds,
            _id,
            _brackets
        );

        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            data,
            address(0),
            _gasLimit
        );

        IRouterClient router = IRouterClient(this.getRouter());

        fee = router.getFee(destinationChainSelector, evm2AnyMessage);

        return fee;
    }

    function claimTickets(
        uint256 _id,
        uint256[] calldata _ticketIds,
        uint32[] calldata _brackets,
        uint256 _gasLimit,
        address _user
    ) external payable returns (bytes32 messageId) {
        CCIPData memory data = CCIPData(
            _user,
            1,
            new uint32[](0),
            _ticketIds,
            _id,
            _brackets
        );

        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            data,
            address(0),
            _gasLimit
        );

        IRouterClient router = IRouterClient(this.getRouter());

        uint256 fees = router.getFee(destinationChainSelector, evm2AnyMessage);

        if (fees > msg.value) revert NotEnoughBalance(msg.value, fees);

        // Send the message through the router and store the returned message ID
        messageId = router.ccipSend{value: fees}(
            destinationChainSelector,
            evm2AnyMessage
        );

        emit MessageSent(
            messageId,
            destinationChainSelector,
            destinationChainContract,
            data,
            address(0),
            0,
            address(0),
            fees
        );

        payable(msg.sender).transfer(msg.value - fees);

        messageIds[_user].push(messageId);
        return messageId;
    }

    /// handle a received message
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage)
        internal
        override
    {}

    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for programmable tokens transfer..
    /// @param _CCIPData The CCIPData data to be sent.
    /// @param _amount The amount of the token to be transferred.
    /// @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function _buildCCIPMessageWithToken(
        CCIPData memory _CCIPData,
        uint256 _amount,
        address _feeTokenAddress,
        uint256 _gasLimit
    ) private view returns (Client.EVM2AnyMessage memory) {
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(WETH),
            amount: _amount
        });
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        return
            Client.EVM2AnyMessage({
                receiver: abi.encode(destinationChainContract), // ABI-encoded receiver address
                data: abi.encode(_CCIPData), // ABI-encoded CCIPData
                tokenAmounts: tokenAmounts, // The amount and type of token being transferred
                extraArgs: Client._argsToBytes(
                    // Additional arguments, setting gas limit
                    Client.EVMExtraArgsV1({gasLimit: _gasLimit})
                ),
                // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
                feeToken: _feeTokenAddress
            });
    }

    function _buildCCIPMessage(
        CCIPData memory _CCIPData,
        address _feeTokenAddress,
        uint256 _gasLimit
    ) private view returns (Client.EVM2AnyMessage memory) {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        return
            Client.EVM2AnyMessage({
                receiver: abi.encode(destinationChainContract), // ABI-encoded receiver address
                data: abi.encode(_CCIPData), // ABI-encoded CCIPData
                tokenAmounts: new Client.EVMTokenAmount[](0),
                extraArgs: Client._argsToBytes(
                    // Additional arguments, setting gas limit
                    Client.EVMExtraArgsV1({gasLimit: _gasLimit})
                ),
                // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
                feeToken: _feeTokenAddress
            });
    }

    function getMessageIds(address _user) external view returns (bytes32[] memory) {
        return (messageIds[_user]);
    }

    function updateDestinationChainContract(address _destinationChainContract)
        external
        onlyOwner
    {
        destinationChainContract = _destinationChainContract;
    }
}