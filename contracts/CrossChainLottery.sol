// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";

// DO NOT DEPLOY THIS CONTRACT INTO PRODUCTION, IT IS CURRENTLY BEING WORKED ON FOR BETTER CCIP IMPLEMENTATION

contract ProgrammableTokenTransfers is CCIPReceiver, OwnerIsCreator {
    using SafeERC20 for IERC20;

    // Custom errors to provide more descriptive revert messages.
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees); // Used to make sure contract has enough balance to cover the fees.
    error NothingToWithdraw(); // Used when trying to withdraw Ether but there's nothing to withdraw.
    error FailedToWithdrawEth(address owner, address target, uint256 value); // Used when the withdrawal of Ether fails.
    error DestinationChainNotAllowed(uint64 destinationChainSelector); // Used when the destination chain has not been allowlisted by the contract owner.
    error SourceChainNotAllowed(uint64 sourceChainSelector); // Used when the source chain has not been allowlisted by the contract owner.
    error SenderNotAllowed(address sender); // Used when the sender has not been allowlisted by the contract owner.
    error InvalidReceiverAddress(); // Used when the receiver address is 0.

    struct CCIPData {
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

    // Event emitted when a message is received from another chain.
    event MessageReceived(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed sourceChainSelector, // The chain selector of the source chain.
        address sender, // The address of the sender from the source chain.
        CCIPData data, // The text that was received.
        address token, // The token address that was transferred.
        uint256 tokenAmount // The token amount that was transferred.
    );

    bytes32 private s_lastReceivedMessageId; // Store the last received messageId.
    address private s_lastReceivedTokenAddress; // Store the last received token address.
    uint256 private s_lastReceivedTokenAmount; // Store the last received amount.
    CCIPData private s_lastReceivedText; // Store the last received text.

    // Mapping to keep track of allowlisted destination chains.
    mapping(uint64 => bool) public allowlistedDestinationChains;

    // Mapping to keep track of allowlisted source chains.
    mapping(uint64 => bool) public allowlistedSourceChains;

    // Mapping to keep track of allowlisted senders.
    mapping(address => bool) public allowlistedSenders;

    uint64 public destinationChainSelector = 3478487238524512106;
    address public token = 0x8aF4204e30565DF93352fE8E1De78925F6664dA7;
    address destinationChainContract = 0xA80815BfD81C97119a6868BF4B7029904De15E0C;

    constructor(address _router) CCIPReceiver(_router) {}

    /// @dev Modifier that checks the receiver address is not 0.
    /// @param destinationChainContract The receiver address.
    modifier validateReceiver(address destinationChainContract) {
        if (destinationChainContract == address(0)) revert InvalidReceiverAddress();
        _;
    }

    /// @dev Modifier that checks if the chain with the given sourceChainSelector is allowlisted and if the sender is allowlisted.
    /// @param _sourceChainSelector The selector of the destination chain.
    /// @param _sender The address of the sender.
    modifier onlyAllowlisted(uint64 _sourceChainSelector, address _sender) {
        if (!allowlistedSourceChains[_sourceChainSelector])
            revert SourceChainNotAllowed(_sourceChainSelector);
        if (!allowlistedSenders[_sender]) revert SenderNotAllowed(_sender);
        _;
    }

    /// @dev Updates the allowlist status of a source chain
    /// @notice This function can only be called by the owner.
    /// @param _sourceChainSelector The selector of the source chain to be updated.
    /// @param allowed The allowlist status to be set for the source chain.
    function allowlistSourceChain(
        uint64 _sourceChainSelector,
        bool allowed
    ) external onlyOwner {
        allowlistedSourceChains[_sourceChainSelector] = allowed;
    }

    /// @dev Updates the allowlist status of a sender for transactions.
    /// @notice This function can only be called by the owner.
    /// @param _sender The address of the sender to be updated.
    /// @param allowed The allowlist status to be set for the sender.
    function allowlistSender(address _sender, bool allowed) external onlyOwner {
        allowlistedSenders[_sender] = allowed;
    }

    function buyTickets(
        uint32[] calldata _tickets,
        uint256 _amount
    )
        external
        payable
        validateReceiver(destinationChainContract)
        returns (bytes32 messageId)
    {
        CCIPData memory data = CCIPData(
            0,
            _tickets,
            new uint256[](0),
            0,
            new uint32[](0)
        );

        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessageWithToken(
            data,
            token,
            _amount,
            address(0)
        );

        IRouterClient router = IRouterClient(this.getRouter());

        uint256 fees = router.getFee(destinationChainSelector, evm2AnyMessage);

        if (fees > msg.value)
            revert NotEnoughBalance(msg.value, fees);

        // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
        IERC20(token).approve(address(router), _amount);

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
            token,
            _amount,
            address(0),
            fees
        );

        payable(msg.sender).transfer(msg.value - fees);

        return messageId;
    }

    function estimateFeesBuyTickets(
        uint32[] calldata _tickets,
        uint256 _amount
    ) public view returns(uint256 fee) {
        CCIPData memory data = CCIPData(
            0,
            _tickets,
            new uint256[](0),
            0,
            new uint32[](0)
        );

        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessageWithToken(
            data,
            token,
            _amount,
            address(0)
        );

        IRouterClient router = IRouterClient(this.getRouter());

        fee = router.getFee(destinationChainSelector, evm2AnyMessage);

        return fee;
    }

     function claimTickets(
         uint256 _id,
        uint256[] calldata _ticketIds,
        uint32[] calldata _brackets
    )
        external
        payable
        validateReceiver(destinationChainContract)
        returns (bytes32 messageId)
    {
        CCIPData memory data = CCIPData(
            1,
            new uint32[](0),
            _ticketIds,
            _id,
            _brackets
        );

        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            data,
            address(0)
        );

        IRouterClient router = IRouterClient(this.getRouter());

        uint256 fees = router.getFee(destinationChainSelector, evm2AnyMessage);

        if (fees > msg.value)
            revert NotEnoughBalance(msg.value, fees);

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

        return messageId;
    }

    /// handle a received message
    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    )
        internal
        override
    {}

    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for programmable tokens transfer..
    /// @param _CCIPData The CCIPData data to be sent.
    /// @param _token The token to be transferred.
    /// @param _amount The amount of the token to be transferred.
    /// @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function _buildCCIPMessageWithToken(
        CCIPData memory _CCIPData,
        address _token,
        uint256 _amount,
        address _feeTokenAddress
    ) private view returns (Client.EVM2AnyMessage memory) {
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: _token,
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
                    Client.EVMExtraArgsV1({gasLimit: 200_000})
                ),
                // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
                feeToken: _feeTokenAddress
            });
    }

    function _buildCCIPMessage(
        CCIPData memory _CCIPData,
        address _feeTokenAddress
    ) private view returns (Client.EVM2AnyMessage memory) {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        return
            Client.EVM2AnyMessage({
                receiver: abi.encode(destinationChainContract), // ABI-encoded receiver address
                data: abi.encode(_CCIPData), // ABI-encoded CCIPData
                tokenAmounts: new Client.EVMTokenAmount[](0),
                extraArgs: Client._argsToBytes(
                    // Additional arguments, setting gas limit
                    Client.EVMExtraArgsV1({gasLimit: 200_000})
                ),
                // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
                feeToken: _feeTokenAddress
            });
    }
}