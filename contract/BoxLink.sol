//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "hardhat/console.sol";

import "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

contract BoxLink is ReentrancyGuard, ERC721Holder, VRFConsumerBaseV2 {
    VRFCoordinatorV2Interface COORDINATOR;
    LinkTokenInterface LINKTOKEN;
    //bsc test-net
    uint64 s_subscriptionId = 48;
    address vrfCoordinator = 0xc587d9053cd1118f25F645F9E08BB98c9712A4EE;
    address link = 0x404460C6A5EdE2D891e8297795264fDe62ADBB75;
    bytes32 keyHash =
        0x114f3da0a805b6a67d6e9cd2ec746f7028f1b7376365af575cfea3550dd1aa04;
    uint32 callbackGasLimit1 = 100000;
    uint32 callbackGasLimit5 = 500000;
    uint16 requestConfirmations = 3;

    using Counters for Counters.Counter;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct VRF {
        uint256 requestId;
        address user;
        uint256 num;
        bool isRev;
        bool isClaim;
    }

    address public admin;
    bool public isStart;

    IERC721 public nft_token;
    IERC20 public erc_token;

    uint256 public amount_once;
    uint256 public amount_more;
    uint32 public constant amount_more_quantity = 5;
    /// <requestID,VRF>
    mapping(uint256 => VRF) public s_vrf;
    /// <requestID,index[] return nftId[]
    mapping(uint256 => uint256[]) public s_vrf_nftId;
    /// <requestID,index[]> return randowWords[]
    mapping(uint256 => uint256[]) public s_vrf_randowWords;
    /// <user,requestID[]>
    mapping(address => uint256[]) public s_requestId;
    // <radomword,nftId>
    mapping(uint256 => uint256) public s_randowWords_nftId;

    /// @dev tokenid , total
    uint256[] public ids;
    uint256 public ids_len;
    uint256 public box_len;

    event BuyOne(address indexed seller, uint256 requestId);
    event Claim(address indexed seller, uint256 requestId);
    event BuyMore(address indexed seller, uint256 requestId);

    modifier onlyAdmin() {
        require(admin == msg.sender, "ONLY_ADMIN_ALLOWED");
        _;
    }

    constructor(
        address _admin,
        address _erc20_address,
        address _nft_address
    ) VRFConsumerBaseV2(vrfCoordinator) {
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        LINKTOKEN = LinkTokenInterface(link);

        admin = _admin;
        erc_token = IERC20(_erc20_address);
        nft_token = IERC721(_nft_address);
        isStart = false;
    }

    function setIds(uint256[] memory _ids) external onlyAdmin {
        require(isStart == false, "err:started");
        require(ids_len == 0, "err:already setIds");
        ids = _ids;
        ids_len = _ids.length;
        box_len = _ids.length;
    }

    function setAmount(uint256 _amount_once, uint256 _amount_more)
        external
        onlyAdmin
    {
        require(isStart == false, "err:started");
        amount_once = _amount_once;
        amount_more = _amount_more;
    }

    function start() external onlyAdmin {
        require(isStart == false, "err:started");
        require(amount_once > 0, "err:amount_once");
        require(amount_more > 0, "err:amount_more");
        require(ids.length > 0, "err:ids.length");
        require(ids_len > 0, "err:ids_len");
        isStart = true;
    }

    function stop() external onlyAdmin {
        require(isStart == true, "err:started");
        isStart = false;
    }

    function withdrawERC() external onlyAdmin {
        require(erc_token.balanceOf(address(this)) > 0, "balance zero");
        erc_token.safeTransfer(
            address(admin),
            erc_token.balanceOf(address(this))
        );
    }

    function withdrawNft(uint256[] memory _nftIds) external onlyAdmin {
        require(isStart == false, "err:started");
        require(nft_token.balanceOf(address(this)) > 0, "balance zero");

        for (uint256 index = 0; index < _nftIds.length; index++) {
            uint256 nftId = _nftIds[index];
            nft_token.safeTransferFrom(address(this), msg.sender, nftId);
        }
    }

    function canBuy(uint256 _quantity) private view returns (bool) {
        if (box_len == 0) return false;
        if (box_len < _quantity) return false;
        if (isStart == false) return false;

        return true;
    }

    function buyOne() external nonReentrant returns (uint256) {
        require(isStart == true, "err:not start");
        require(box_len > 0, "err:zero");
        require(canBuy(1) == true, "err:quantity");

        box_len = box_len.sub(1);
        erc_token.safeTransferFrom(msg.sender, address(this), amount_once);
        uint256 requestId = requestRandomWords(1, callbackGasLimit1);
        s_vrf[requestId] = VRF(requestId, msg.sender, 1, false, false);
        s_requestId[msg.sender].push(requestId);

        emit BuyOne(msg.sender, requestId);
        return requestId;
    }

    function claim(uint256 requestId) external nonReentrant returns (uint256) {
        require(isStart == true, "err:not start");
        require(s_vrf[requestId].user == msg.sender, "err:not owner");
        require(s_vrf[requestId].isRev == true, "err:not rev");
        require(s_vrf[requestId].isClaim == false, "err:already claimed");
        require(
            s_vrf[requestId].num == s_vrf_randowWords[requestId].length,
            "err:length"
        );

        for (uint256 index = 0; index < s_vrf[requestId].num; index++) {
            s_vrf[requestId].isClaim = true;
            uint256 rand = _psuedoRandomness(
                ids_len,
                s_vrf_randowWords[requestId][index]
            );
            uint256 nftId = ids[rand];
            ids[rand] = ids[ids_len - 1];
            delete ids[ids_len - 1];
            ids_len = ids_len.sub(1);
            s_randowWords_nftId[s_vrf_randowWords[requestId][index]] = nftId;
            s_vrf_nftId[requestId].push(nftId);
            nft_token.safeTransferFrom(address(this), msg.sender, nftId);
        }
        emit Claim(msg.sender, requestId);
        return requestId;
    }

    function buyMore() external nonReentrant returns (uint256) {
        require(isStart == true, "err:not start");
        require(box_len > 0, "err:zero");
        require(canBuy(amount_more_quantity) == true, "err:quantity");
        box_len = box_len.sub(amount_more_quantity);
        erc_token.safeTransferFrom(msg.sender, address(this), amount_more);
        uint256 requestId = requestRandomWords(
            amount_more_quantity,
            callbackGasLimit5
        );
        s_vrf[requestId] = VRF(
            requestId,
            msg.sender,
            amount_more_quantity,
            false,
            false
        );
        s_requestId[msg.sender].push(requestId);

        emit BuyMore(msg.sender, requestId);
        return requestId;
    }

    function _psuedoRandomness(uint256 mod, uint256 randomWord)
        internal
        view
        returns (uint256)
    {
        uint256 rand = uint256(
            keccak256(
                abi.encodePacked(
                    randomWord,
                    block.timestamp,
                    block.difficulty,
                    block.gaslimit,
                    block.number,
                    msg.sender
                )
            )
        ) % mod;
        return rand;
    }

    function destroy() external onlyAdmin {
        address payable addr = payable(address(admin));
        selfdestruct(addr);
    }

    // Assumes the subscription is funded sufficiently.
    function requestRandomWords(uint32 _numWords, uint32 _callbackGasLimit)
        internal
        returns (uint256)
    {
        // Will revert if subscription is not set and funded.
        uint256 requestId = COORDINATOR.requestRandomWords(
            keyHash,
            s_subscriptionId,
            requestConfirmations,
            _callbackGasLimit,
            _numWords
        );

        return requestId;
    }

    function sRequestIdLen(address _addr) external view returns (uint256) {
        return s_requestId[_addr].length;
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords)
        internal
        override
    {
        if (s_vrf[requestId].isRev == false) {
            s_vrf[requestId].isRev = true;
            s_vrf_randowWords[requestId] = randomWords;
        }
    }
}
