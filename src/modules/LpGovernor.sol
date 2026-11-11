// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";
import {IOFT} from "../interfaces/IVenues.sol";
import {ILpDesk, IPriceGuard, OpenParams} from "../interfaces/IFirm.sol";

/// @title LpGovernor (LpDesk module)
/// @notice NOTSTOCK staking with block checkpoints, and proposals of kind OpenPosition, AddAsset,
/// AddVenue, AddBridge and BridgeOut: 3-day vote, 3% quorum, 2-day operator veto, 3-day execution window.
contract LpGovernor {
    enum Kind {
        OpenPosition,
        AddAsset,
        AddVenue,
        AddBridge,
        BridgeOut
    }

    enum State {
        Active,
        Failed,
        VetoWindow,
        Executable,
        Expired,
        Vetoed,
        Executed
    }

    struct Checkpoint {
        uint64 blockNumber;
        uint192 balance;
    }

    struct Proposal {
        Kind kind;
        address author;
        bool byOperator;
        bool executed;
        bool vetoed;
        uint64 checkpointBlock;
        uint64 voteEnd;
        uint64 vetoEnd;
        uint64 expiry;
        uint256 quorumBase;
        uint256 forWeight;
        uint256 againstWeight;
        bytes data;
    }

    struct Bridge {
        address adapter;
        uint32 dstChainId;
        address dstLpDesk;
    }

    uint256 public constant VOTE_SECONDS = 3 days;
    uint256 public constant VETO_SECONDS = 2 days;
    uint256 public constant EXECUTE_SECONDS = 259_200;
    uint256 public constant QUORUM_BPS = 300; // 3%
    uint256 public constant THRESHOLD_BPS = 10; // 0.1%

    ILpDesk public immutable lpDesk;

    mapping(address => uint256) public staked;
    uint256 public totalStaked;
    mapping(address => Checkpoint[]) internal _checkpoints;
    Checkpoint[] internal _totalCheckpoints;

    Proposal[] internal _proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    /// @dev kind => byOperator => id + 1 of the latest proposal of that class.
    mapping(Kind => mapping(bool => uint256)) internal _latest;

    Bridge[] internal _bridges;
    mapping(uint256 => uint256) public bridgedOut;

    event Staked(address indexed staker, uint256 amount);
    event Unstaked(address indexed staker, uint256 amount);
    event ProposalCreated(uint256 indexed id, Kind kind, address indexed author, bool byOperator);
    event Voted(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event Vetoed(uint256 indexed id);
    event Executed(uint256 indexed id);
    event BridgeAdded(uint256 indexed id, address adapter, uint32 dstChainId, address dstLpDesk);

    error TransferFailed();
    error AboveStaked();
    error BelowThreshold();
    error KindOpen();
    error NotActive();
    error AlreadyVoted();
    error NoWeight();
    error NotOperator();
    error NotVetoWindow();
    error NotExecutable();
    error AboveFree();
    error WrongAdapter();
    error UnknownBridge();
    error ZeroAmount();

    constructor() {
        lpDesk = ILpDesk(msg.sender);
    }

    // ================================================================ staking

    function stake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        IERC20 token = IERC20(lpDesk.token());
        uint256 before = token.balanceOf(address(this));
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        uint256 received = token.balanceOf(address(this)) - before;
        staked[msg.sender] += received;
        totalStaked += received;
        _write(_checkpoints[msg.sender], staked[msg.sender]);
        _write(_totalCheckpoints, totalStaked);
        emit Staked(msg.sender, received);
    }

    function unstake(uint256 amount) external {
        if (amount > staked[msg.sender]) revert AboveStaked();
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        _write(_checkpoints[msg.sender], staked[msg.sender]);
        _write(_totalCheckpoints, totalStaked);
        if (!IERC20(lpDesk.token()).transfer(msg.sender, amount)) revert TransferFailed();
        emit Unstaked(msg.sender, amount);
    }

    function stakedAt(address account, uint256 blockNumber) public view returns (uint256) {
        return _lookup(_checkpoints[account], blockNumber);
    }

    function totalStakedAt(uint256 blockNumber) public view returns (uint256) {
        return _lookup(_totalCheckpoints, blockNumber);
    }

    function _write(Checkpoint[] storage cps, uint256 value) internal {
        uint256 n = cps.length;
        if (n > 0 && cps[n - 1].blockNumber == uint64(block.number)) {
            cps[n - 1].balance = uint192(value);
        } else {
            cps.push(Checkpoint({blockNumber: uint64(block.number), balance: uint192(value)}));
        }
    }

    /// @dev Value at the end of `blockNumber`: the last checkpoint written at or before it.
    function _lookup(Checkpoint[] storage cps, uint256 blockNumber) internal view returns (uint256) {
        uint256 lo;
        uint256 hi = cps.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (cps[mid].blockNumber > blockNumber) hi = mid;
            else lo = mid + 1;
        }
        return lo == 0 ? 0 : cps[lo - 1].balance;
    }

    // ================================================================ proposals

    function proposalCount() external view returns (uint256) {
        return _proposals.length;
    }

    function proposal(uint256 id) external view returns (Proposal memory) {
        return _proposals[id];
    }

    function state(uint256 id) public view returns (State) {
        Proposal storage p = _proposals[id];
        if (p.executed) return State.Executed;
        if (p.vetoed) return State.Vetoed;
        if (block.timestamp < p.voteEnd) return State.Active;
        if ((p.forWeight + p.againstWeight) * 10_000 < p.quorumBase * QUORUM_BPS || p.forWeight <= p.againstWeight) {
            return State.Failed;
        }
        if (block.timestamp < p.vetoEnd) return State.VetoWindow;
        if (block.timestamp < p.expiry) return State.Executable;
        return State.Expired;
    }

    function isOpen(uint256 id) public view returns (bool) {
        State s = state(id);
        return s == State.Active || s == State.VetoWindow || s == State.Executable;
    }

    function proposeOpenPosition(OpenParams calldata params) external returns (uint256) {
        if (params.amount > lpDesk.freeBalance(lpDesk.token())) revert AboveFree();
        return _create(Kind.OpenPosition, abi.encode(params));
    }

    function proposeAddAsset(address asset) external returns (uint256) {
        IPriceGuard(lpDesk.priceGuard()).checkAsset(asset);
        return _create(Kind.AddAsset, abi.encode(asset));
    }

    function proposeAddVenue(address manager, uint8 kind) external returns (uint256) {
        IPriceGuard(lpDesk.priceGuard()).checkVenue(manager, kind);
        return _create(Kind.AddVenue, abi.encode(manager, kind));
    }

    function proposeAddBridge(address adapter, uint32 dstChainId, address dstLpDesk) external returns (uint256) {
        _checkAdapter(adapter);
        return _create(Kind.AddBridge, abi.encode(adapter, dstChainId, dstLpDesk));
    }

    function proposeBridgeOut(uint256 bridgeId, uint256 amount) external returns (uint256) {
        if (bridgeId >= _bridges.length) revert UnknownBridge();
        if (amount == 0) revert ZeroAmount();
        if (amount > lpDesk.freeBalance(lpDesk.token())) revert AboveFree();
        return _create(Kind.BridgeOut, abi.encode(bridgeId, amount));
    }

    function _create(Kind kind, bytes memory data) internal returns (uint256 id) {
        bool byOperator = msg.sender == lpDesk.operator();
        if (!byOperator && staked[msg.sender] * 10_000 < totalStaked * THRESHOLD_BPS) revert BelowThreshold();
        if (!byOperator && staked[msg.sender] == 0) revert BelowThreshold();
        uint256 latest = _latest[kind][byOperator];
        if (latest != 0 && isOpen(latest - 1)) revert KindOpen();
        id = _proposals.length;
        uint64 checkpoint = uint64(block.number - 1);
        _proposals.push(
            Proposal({
                kind: kind,
                author: msg.sender,
                byOperator: byOperator,
                executed: false,
                vetoed: false,
                checkpointBlock: checkpoint,
                voteEnd: uint64(block.timestamp + VOTE_SECONDS),
                vetoEnd: uint64(block.timestamp + VOTE_SECONDS + VETO_SECONDS),
                expiry: uint64(block.timestamp + VOTE_SECONDS + VETO_SECONDS + EXECUTE_SECONDS),
                quorumBase: totalStakedAt(checkpoint),
                forWeight: 0,
                againstWeight: 0,
                data: data
            })
        );
        _latest[kind][byOperator] = id + 1;
        emit ProposalCreated(id, kind, msg.sender, byOperator);
    }

    function vote(uint256 id, bool support) external {
        if (state(id) != State.Active) revert NotActive();
        if (hasVoted[id][msg.sender]) revert AlreadyVoted();
        Proposal storage p = _proposals[id];
        uint256 weight = stakedAt(msg.sender, p.checkpointBlock);
        if (weight == 0) revert NoWeight();
        hasVoted[id][msg.sender] = true;
        if (support) p.forWeight += weight;
        else p.againstWeight += weight;
        emit Voted(id, msg.sender, support, weight);
    }

    function veto(uint256 id) external {
        if (msg.sender != lpDesk.operator()) revert NotOperator();
        if (state(id) != State.VetoWindow) revert NotVetoWindow();
        _proposals[id].vetoed = true;
        emit Vetoed(id);
    }

    /// @notice Performs the proposal's action once after an unvetoed veto window, before expiry.
    function execute(uint256 id) external payable {
        if (state(id) != State.Executable) revert NotExecutable();
        Proposal storage p = _proposals[id];
        p.executed = true;
        if (p.kind == Kind.OpenPosition) {
            OpenParams memory params = abi.decode(p.data, (OpenParams));
            if (params.amount > lpDesk.freeBalance(lpDesk.token())) revert AboveFree();
            lpDesk.openFromGovernor(params);
        } else if (p.kind == Kind.AddAsset) {
            lpDesk.addAsset(abi.decode(p.data, (address)));
        } else if (p.kind == Kind.AddVenue) {
            (address manager, uint8 kind) = abi.decode(p.data, (address, uint8));
            lpDesk.addVenue(manager, kind);
        } else if (p.kind == Kind.AddBridge) {
            (address adapter, uint32 dstChainId, address dstLpDesk) = abi.decode(p.data, (address, uint32, address));
            _checkAdapter(adapter);
            _bridges.push(Bridge({adapter: adapter, dstChainId: dstChainId, dstLpDesk: dstLpDesk}));
            emit BridgeAdded(_bridges.length - 1, adapter, dstChainId, dstLpDesk);
        } else {
            (uint256 bridgeId, uint256 amount) = abi.decode(p.data, (uint256, uint256));
            Bridge memory b = _bridges[bridgeId];
            bridgedOut[bridgeId] += amount;
            lpDesk.bridgeOut{value: msg.value}(b.adapter, b.dstChainId, b.dstLpDesk, amount, msg.sender);
        }
        emit Executed(id);
    }

    // ================================================================ bridges

    function bridges() external view returns (Bridge[] memory) {
        return _bridges;
    }

    function bridgeCount() external view returns (uint256) {
        return _bridges.length;
    }

    function _checkAdapter(address adapter) internal view {
        if (adapter.code.length == 0 || IOFT(adapter).token() != lpDesk.token()) revert WrongAdapter();
    }
}
