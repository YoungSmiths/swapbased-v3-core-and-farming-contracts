// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./libraries/SafeCast.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/INonfungiblePositionManagerStruct.sol";
import "./interfaces/IPancakeV3Pool.sol";
import "./interfaces/ILMPool.sol";
import "./interfaces/ILMPoolDeployer.sol";
import "./interfaces/IFarmBooster.sol";
import "./interfaces/IWETH.sol";
import "./utils/Multicall.sol";
import "./Enumerable.sol";

interface IERC20Mintable is IERC20 {
    /// @notice 奖励币必须实现的铸币接口。
    /// @param recipient_ 收币地址（用户或协议地址）。
    /// @param amount_ 铸造数量。
    /// @return 是否铸造成功。
    function mint(address recipient_, uint256 amount_) external returns (bool);
}

/// @title MasterChefV3
/// @notice V3 挖矿中枢：托管仓位 NFT、联动 `ILMPool` 记录奖励增长，并按池配置铸造多奖励代币。
/// @dev 通过 tokenId 对应区间的 `rewardGrowthInside` 快照 + `boostLiquidity` 做增量结算；不是 V2 LP 风格 MasterChef。
contract MasterChefV3 is INonfungiblePositionManagerStruct, Multicall, Ownable, ReentrancyGuard, Enumerable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    /// @notice 挖矿池元信息：将某个 V3 池与权重、奖励代币配置绑定。
    struct PoolInfo {
        uint256 allocPoint;
        // V3 核心池地址
        IPancakeV3Pool v3Pool;
        // V3 池 token0 地址
        address token0;
        // V3 池 token1 地址
        address token1;
        // V3 池费率档
        uint24 fee;
        // 池内已质押的总真实流动性
        uint256 totalLiquidity;
        // 池内已质押的总加权流动性（含 boost）
        uint256 totalBoostLiquidity;

        uint256[] rewardsRatio;
        address[] rewardsAddresses;
    }

    /// @notice 单 NFT 质押状态：记录真实流动性、加权流动性与奖励快照，用于做增量结算。
    struct UserPositionInfo {
        /// @notice 当前 NFT 在核心池中的真实流动性（未乘 boost）。
        uint128 liquidity;
        /// @notice 参与挖矿结算用的“加权流动性”（真实流动性 * boostMultiplier）。
        uint128 boostLiquidity;
        /// @notice 仓位下边界 tick。
        int24 tickLower;
        /// @notice 仓位上边界 tick。
        int24 tickUpper;
        /// @notice 上次结算后的区间奖励累计快照（来自 LMPool）。
        uint256 rewardGrowthInside;
        /// @notice 已缓存但尚未发放的奖励（例如 update 时先缓存，后续 harvest 再领）。
        uint256 reward;
        /// @notice 该 NFT 的实际拥有者（质押人）。
        address user;
        /// @notice 对应主池 pid。
        uint256 pid;
        /// @notice 当前 boost 倍率（1x~2x）。
        uint256 boostMultiplier;
    }

    /// @notice 当前已创建的挖矿池数量（pid 从 1 开始）。
    uint256 public poolLength;
    /// @notice 每个 MCV3 池的配置信息。
    mapping(uint256 => PoolInfo) public poolInfo;

    /// @notice userPositionInfos[tokenId] => UserPositionInfo。
    /// @dev tokenId 全局唯一，可直接反查对应 pid。
    mapping(uint256 => UserPositionInfo) public userPositionInfos;

    /// @notice v3PoolPid[token0][token1][fee] => pid。
    mapping(address => mapping(address => mapping(uint24 => uint256))) v3PoolPid;
    /// @notice v3PoolAddressPid[v3PoolAddress] => pid。
    mapping(address => uint256) public v3PoolAddressPid;

    /// @notice WETH 合约地址。
    address public immutable WETH;
    
    /// @notice 奖励比例计算精度（万分比，10000）。
    uint256 public immutable REWARDS_PRECISION = 10000;

    /// @notice 团队额外排放比例（当前常量 2%，预留用途）。
    uint256 public constant ownerFee = 200; // 2%

    /// @notice 全局每秒排放总量（会按各池 allocPoint 比例分摊）。
    uint256 public globalCakePerSecond;

    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @notice LMPool 部署器地址。
    ILMPoolDeployer public LMPoolDeployer;
    
    /// @notice Farm Booster 合约地址。
    IFarmBooster public FARM_BOOSTER;

    /// @notice 紧急模式开关（仅紧急场景使用）。
    bool public emergency;

    /// @notice 全部池子权重总和（应等于所有池 allocPoint 之和）。
    uint256 public totalAllocPoint;

    uint256 public latestPeriodNumber;
    uint256 public latestPeriodStartTime;
    uint256 public latestPeriodEndTime;
    uint256 public latestPeriodCakePerSecond;

    /// @notice 运维操作员地址（owner 之外可执行部分维护操作）。
    address public operatorAddress;
    /// @notice 默认排放周期时长。
    uint256 public PERIOD_DURATION = 1 days;
    uint256 public constant MAX_DURATION = 365 days;
    uint256 public constant MIN_DURATION = 1 days;
    uint256 public constant PRECISION = 1e12;
    /// @notice 基础 boost 精度（1x；未加成用户使用该值）。
    uint256 public constant BOOST_PRECISION = 100 * 1e10;
    /// @notice boost 上限（2x），必须大于 BOOST_PRECISION。
    uint256 public constant MAX_BOOST_PRECISION = 200 * 1e10;
    uint256 constant Q128 = 0x100000000000000000000000000000000;

    error ZeroAddress();
    error NotOwnerOrOperator();
    error NoBalance();
    error NotPancakeNFT();
    error InvalidNFT();
    error NotOwner();
    error NoLiquidity();
    error InvalidPeriodDuration();
    error NoLMPool();
    error InvalidPid();
    error DuplicatedPool(uint256 pid);
    error NotEmpty();
    error WrongReceiver();
    error InconsistentAmount();
    error InsufficientAmount();

    event AddPool(uint256 indexed pid, uint256 allocPoint, IPancakeV3Pool indexed v3Pool, ILMPool indexed lmPool);
    event SetPool(uint256 indexed pid, uint256 allocPoint);
    event Deposit(
        address indexed from,
        uint256 indexed pid,
        uint256 indexed tokenId,
        uint256 liquidity,
        int24 tickLower,
        int24 tickUpper
    );
    event Withdraw(address indexed from, address to, uint256 indexed pid, uint256 indexed tokenId);
    event UpdateLiquidity(
        address indexed from,
        uint256 indexed pid,
        uint256 indexed tokenId,
        int128 liquidity,
        int24 tickLower,
        int24 tickUpper
    );
    event NewOperatorAddress(address operator);
    event NewLMPoolDeployerAddress(address deployer);
    event NewPeriodDuration(uint256 periodDuration);
    event Harvest(address indexed sender, address to, uint256 indexed pid, uint256 indexed tokenId, uint256 reward);
    event NewUpkeepPeriod(
        uint256 indexed periodNumber,
        uint256 startTime,
        uint256 endTime,
        uint256 cakePerSecond
    );
    event UpdateUpkeepPeriod(
        uint256 indexed periodNumber,
        uint256 oldEndTime,
        uint256 newEndTime
    );
    event UpdateFarmBoostContract(address indexed farmBoostContract);
    event SetEmergency(bool emergency);
    event NewCakePerSecond(uint256 globalCakePerSecond);

    /// @notice 仅 owner 或 operator 可调用。
    modifier onlyOwnerOrOperator() {
        if (msg.sender != operatorAddress && msg.sender != owner()) revert NotOwnerOrOperator();
        _;
    }

    /// @notice 校验 pid 合法性（pid=0 视为无效，且不能超过 poolLength）。
    modifier onlyValidPid(uint256 _pid) {
        if (_pid == 0 || _pid > poolLength) revert InvalidPid();
        _;
    }

    /// @notice 仅 boost 合约可调用。
    /// @dev 若调用者不是 FARM_BOOSTER 则回滚。
    modifier onlyBoostContract() {
        require(address(FARM_BOOSTER) == msg.sender, "Not farm boost contract");
        _;
    }

    /// @notice 构造函数：绑定 NPM 与 WETH。
    /// @param _nonfungiblePositionManager V3 PositionManager 地址（本合约通过它接收/管理 NFT 仓位）。
    /// @param _WETH WETH 地址（处理 ETH/WETH 转换与退款）。
    /// @param initialOwner 初始管理员地址。
    /// @dev 场景示例：部署后由多签作为 owner，运营地址作为 operator，统一管理挖矿池与排放参数。
    constructor(INonfungiblePositionManager _nonfungiblePositionManager, address _WETH, address initialOwner) Ownable(initialOwner) {
        nonfungiblePositionManager = _nonfungiblePositionManager;
        WETH = _WETH;
    }

    /// @notice 按 pid 查询该池当前每秒排放与本期结束时间。
    /// @param _pid 池子 pid。
    /// @return cakePerSecond 该池每秒奖励（按权重分摊后）。
    /// @return endTime 当前周期结束时间。
    function getLatestPeriodInfoByPid(uint256 _pid) public view returns (uint256 cakePerSecond, uint256 endTime) {
        if (totalAllocPoint > 0) {
            cakePerSecond = (globalCakePerSecond * poolInfo[_pid].allocPoint) / totalAllocPoint;
        }
        endTime = latestPeriodEndTime;
    }

    function getRewardsRatioInfoByPid(uint256 _pid) public view returns (uint256[] memory rewardsRatio, address[] memory rewardsAddresses) {
        PoolInfo memory info = poolInfo[_pid];
        rewardsRatio = info.rewardsRatio;
        rewardsAddresses = info.rewardsAddresses;
    }

    /// @notice 设置某池的多奖励比例与代币地址。
    /// @param _pid 池子 pid。
    /// @param _rewardsRatio 奖励比例数组（总和一般为 10000，即 REWARDS_PRECISION）。
    /// @param _rewardsAddresses 奖励代币地址数组（需实现 mint）。
    /// @dev 示例：`[8000,2000] + [CAKE,xCAKE]` 表示用户奖励 80% 发 CAKE，20% 发 xCAKE。
    function setRewardsRatioInfoByPid(uint256 _pid, uint256[] memory _rewardsRatio, address[] memory _rewardsAddresses) public onlyOwner {
        PoolInfo storage info = poolInfo[_pid];
        info.rewardsRatio = _rewardsRatio;
        info.rewardsAddresses = _rewardsAddresses;
    }

    /// @notice 按 V3 池地址查询该池每秒排放与结束时间（供 LMPool 调用）。
    /// @param _v3Pool V3 池地址。
    /// @return cakePerSecond 该池每秒奖励。
    /// @return endTime 当前周期结束时间。
    function getLatestPeriodInfo(address _v3Pool) public view returns (uint256 cakePerSecond, uint256 endTime) {
        if (totalAllocPoint > 0) {
            cakePerSecond =
                (globalCakePerSecond * poolInfo[v3PoolAddressPid[_v3Pool]].allocPoint) /
                totalAllocPoint;
        }
        endTime = latestPeriodEndTime;
    }

    /// @notice 查询某 NFT 当前可领取奖励（预估值）。
    /// @dev 该值基于 LMPool 当前状态计算，最终实际到账以触发 harvest/update 时结算结果为准。
    /// @param _tokenId NFT tokenId。
    /// @return reward 待领取奖励。
    function pendingCake(uint256 _tokenId) external view returns (uint256 reward) {
        UserPositionInfo memory positionInfo = userPositionInfos[_tokenId];
        if (positionInfo.pid != 0) {
            PoolInfo memory pool = poolInfo[positionInfo.pid];
            ILMPool LMPool = ILMPool(pool.v3Pool.lmPool());
            if (address(LMPool) != address(0)) {
                uint256 rewardGrowthInside = LMPool.getRewardGrowthInside(
                    positionInfo.tickLower,
                    positionInfo.tickUpper
                );

                uint256 rewardGrowthInsideDelta;
                unchecked {
                    rewardGrowthInsideDelta = rewardGrowthInside - positionInfo.rewardGrowthInside;
                }
                reward = (rewardGrowthInsideDelta * positionInfo.boostLiquidity) / Q128;
            }
            reward += positionInfo.reward;
        }
    }

    /// @notice 紧急开关：打开后会跳过部分 LMPool 结算路径，便于应对异常。
    /// @dev 仅应急使用，恢复后应尽快回到正常模式。
    function setEmergency(bool _emergency) external onlyOwner {
        emergency = _emergency;
        emit SetEmergency(emergency);
    }

    /// @notice 设置 LMPool 部署器地址。
    /// @param _LMPoolDeployer 部署器地址。
    /// @dev 新增池时需要通过它创建/绑定对应 LMPool。
    function setLMPoolDeployer(ILMPoolDeployer _LMPoolDeployer) external onlyOwner {
        if (address(_LMPoolDeployer) == address(0)) revert ZeroAddress();
        LMPoolDeployer = _LMPoolDeployer;
        emit NewLMPoolDeployerAddress(address(_LMPoolDeployer));
    }

    /// @notice 新增一个挖矿池（一个 V3 池只能映射一个 pid）。
    /// @param _allocPoint 新池权重（用于分摊全局每秒排放）。
    /// @param _v3Pool V3 核心池地址。
    /// @param _withUpdate 是否先全量刷新各池奖励。
    /// @param _rewardsRatio 多奖励比例数组（通常总和=10000）。
    /// @param _rewardsAddresses 多奖励代币地址数组。
    /// @dev 使用场景：运营要上线一个新交易对农场（如 USDT/BNB 0.25%），先 add 池，再让用户质押 NFT。
    function add(uint256 _allocPoint, IPancakeV3Pool _v3Pool, bool _withUpdate, uint256[] memory _rewardsRatio, address[] memory _rewardsAddresses) external onlyOwner {
        // 若要求先更新，先把旧池奖励累计到最新时间点，避免新池加入导致历史分摊失真。
        if (_withUpdate) massUpdatePools();

        // 为该 V3 池部署并绑定对应的 LMPool（负责按 tick 区间记录奖励累计）。
        ILMPool lmPool = LMPoolDeployer.deploy(_v3Pool);

        totalAllocPoint += _allocPoint;
        address token0 = _v3Pool.token0();
        address token1 = _v3Pool.token1();
        uint24 fee = _v3Pool.fee();
        // 同一 token0/token1/fee 的池子只能注册一次，避免重复计奖。
        if (v3PoolPid[token0][token1][fee] != 0) revert DuplicatedPool(v3PoolPid[token0][token1][fee]);
        // 预先给 NPM 最大授权，便于后续 increase/decrease/collect 等流程无须重复 approve。
        if (IERC20(token0).allowance(address(this), address(nonfungiblePositionManager)) == 0)
            IERC20(token0).safeApprove(address(nonfungiblePositionManager), type(uint256).max);
        if (IERC20(token1).allowance(address(this), address(nonfungiblePositionManager)) == 0)
            IERC20(token1).safeApprove(address(nonfungiblePositionManager), type(uint256).max);
        unchecked {
            poolLength++;
        }
        poolInfo[poolLength] = PoolInfo({
            allocPoint: _allocPoint,
            v3Pool: _v3Pool,
            token0: token0,
            token1: token1,
            fee: fee,
            totalLiquidity: 0,
            totalBoostLiquidity: 0,
            rewardsRatio: _rewardsRatio,
            rewardsAddresses: _rewardsAddresses
        });

        v3PoolPid[token0][token1][fee] = poolLength;
        v3PoolAddressPid[address(_v3Pool)] = poolLength;
        emit AddPool(poolLength, _allocPoint, _v3Pool, lmPool);
    }

    /// @notice 更新某池权重 allocPoint。
    /// @param _pid 池子 pid。
    /// @param _allocPoint 新权重。
    /// @param _withUpdate 是否先全量刷新。
    /// @dev 使用场景：调整活动池激励强度（例如新池活动期临时提高权重）。
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyOwner onlyValidPid(_pid) {
        uint32 currentTime = uint32(block.timestamp);
        PoolInfo storage pool = poolInfo[_pid];
        ILMPool LMPool = ILMPool(pool.v3Pool.lmPool());
        if (address(LMPool) != address(0)) {
            // 先累计到当前时间，确保改权重前的奖励已经按旧权重入账。
            LMPool.accumulateReward(currentTime);
        }

        if (_withUpdate) massUpdatePools();
        totalAllocPoint = totalAllocPoint - pool.allocPoint + _allocPoint;
        pool.allocPoint = _allocPoint;
        emit SetPool(_pid, _allocPoint);
    }

    struct DepositCache {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @notice ERC721 回调：用户把 V3 NFT 转入本合约即视为“质押”。
    /// @dev 核心流程（逐行）：
    /// 1) 只接受来自 NPM 的 NFT；
    /// 2) 读取 NFT 的 token0/token1/fee/tick/liquidity；
    /// 3) 定位 pid 并检查对应 LMPool 存在；
    /// 4) 累计一次 LMPool 奖励到当前时间；
    /// 5) 调 `updateLiquidityOperation` 把本 NFT 的 boost 流动性写入 LMPool；
    /// 6) 保存 rewardGrowthInside 快照，作为后续增量结算基线。
    /// @dev 案例：用户把 tokenId=123（USDT/BNB 区间仓位）转进来后，就开始参与该池挖矿计奖。
    function onERC721Received(
        address,
        address _from,
        uint256 _tokenId,
        bytes calldata
    ) external nonReentrant returns (bytes4) {
        // 仅接受 NPM 发来的仓位 NFT，防止恶意 ERC721 混入。
        if (msg.sender != address(nonfungiblePositionManager)) revert NotPancakeNFT();
        DepositCache memory cache;
        (
            ,
            ,
            cache.token0,
            cache.token1,
            cache.fee,
            cache.tickLower,
            cache.tickUpper,
            cache.liquidity,
            ,
            ,
            ,

        ) = nonfungiblePositionManager.positions(_tokenId);
        // 零流动性 NFT 不允许质押（无法产生奖励）。
        if (cache.liquidity == 0) revert NoLiquidity();
        uint256 pid = v3PoolPid[cache.token0][cache.token1][cache.fee];
        // 该 NFT 对应池未被 add 到 MasterChef，拒绝质押。
        if (pid == 0) revert InvalidNFT();
        PoolInfo memory pool = poolInfo[pid];
        ILMPool LMPool = ILMPool(pool.v3Pool.lmPool());
        if (address(LMPool) == address(0)) revert NoLMPool();

        UserPositionInfo storage positionInfo = userPositionInfos[_tokenId];

        positionInfo.tickLower = cache.tickLower;
        positionInfo.tickUpper = cache.tickUpper;
        positionInfo.user = _from;
        positionInfo.pid = pid;
        // 先更新 LMPool 全局累计，确保本次入金时基线正确。
        LMPool.accumulateReward(uint32(block.timestamp));
        // 写入当前 NFT 的流动性与 boost 流动性到 LMPool。
        updateLiquidityOperation(positionInfo, _tokenId, 0);

        positionInfo.rewardGrowthInside = LMPool.getRewardGrowthInside(cache.tickLower, cache.tickUpper);

        // 更新可枚举持仓集合
        addToken(_from, _tokenId);
        emit Deposit(_from, pid, _tokenId, cache.liquidity, cache.tickLower, cache.tickUpper);

        return this.onERC721Received.selector;
    }

    /// @notice 领取指定 NFT 的奖励。
    /// @param _tokenId NFT tokenId。
    /// @param _to 奖励接收地址。
    /// @return reward 本次领取奖励。
    function harvest(uint256 _tokenId, address _to) external nonReentrant returns (uint256 reward) {
        UserPositionInfo storage positionInfo = userPositionInfos[_tokenId];
        if (positionInfo.user != msg.sender) revert NotOwner();
        if (positionInfo.liquidity == 0 && positionInfo.reward == 0) revert NoLiquidity();
        reward = harvestOperation(positionInfo, _tokenId, _to);
    }

    /// @notice harvest 的内部实现：先算增量奖励，再决定是立即发放还是仅缓存。
    /// @param positionInfo NFT 对应用户仓位信息（storage）。
    /// @param _tokenId NFT id。
    /// @param _to 发奖接收地址；传 0 表示只更新缓存不转账。
    /// @return reward 本次可领取总奖励（含历史缓存）。
    /// @dev 案例：`updateLiquidity` 调用时会传 `_to=0`，先把奖励记账；用户手动 harvest 再真实 mint 到钱包。
    function harvestOperation(
        UserPositionInfo storage positionInfo,
        uint256 _tokenId,
        address _to
    ) internal returns (uint256 reward) {
        PoolInfo memory pool = poolInfo[positionInfo.pid];
        ILMPool LMPool = ILMPool(pool.v3Pool.lmPool());
        if (address(LMPool) != address(0) && !emergency) {
            // 1) 先把 LMPool 累计到当前时间点，避免漏算时间奖励。
            LMPool.accumulateReward(uint32(block.timestamp));
            // 2) 读取当前区间累计值，与上次快照做差。
            uint256 rewardGrowthInside = LMPool.getRewardGrowthInside(positionInfo.tickLower, positionInfo.tickUpper);

            uint256 rewardGrowthInsideDelta;
            unchecked {
                rewardGrowthInsideDelta = rewardGrowthInside - positionInfo.rewardGrowthInside;
            }
            // 3) 增量奖励 = 区间累计增量 * boost流动性 / Q128。
            reward = (rewardGrowthInsideDelta * positionInfo.boostLiquidity) / Q128;
            positionInfo.rewardGrowthInside = rewardGrowthInside;
        }
        // 4) 叠加历史缓存奖励（上次未提走）。
        reward += positionInfo.reward;

        if (reward > 0) {
            if (_to != address(0)) {
                // 真实发放路径：清缓存并 mint 多奖励币到目标地址。
                positionInfo.reward = 0;
                _safeTransfer(_to, reward, positionInfo.pid);
                emit Harvest(msg.sender, _to, positionInfo.pid, _tokenId, reward);
            } else {
                // 仅记账路径：不转账，等待后续 harvest/withdraw 再发放。
                positionInfo.reward = reward;
            }
        }
    }

    /// @notice 退出质押并取回 NFT；退出前会自动结算并发放奖励。
    /// @param _tokenId 待退出的 NFT tokenId。
    /// @param _to 提回 NFT 的接收地址。
    /// @return reward 本次结算奖励。
    function withdraw(uint256 _tokenId, address _to) external nonReentrant returns (uint256 reward) {
        if (_to == address(this) || _to == address(0)) revert WrongReceiver();
        UserPositionInfo storage positionInfo = userPositionInfos[_tokenId];
        if (positionInfo.user != msg.sender) revert NotOwner();
        // 1) 先 harvest，避免退出后遗留奖励无法结算。
        reward = harvestOperation(positionInfo, _tokenId, _to);
        uint256 pid = positionInfo.pid;
        PoolInfo storage pool = poolInfo[pid];
        ILMPool LMPool = ILMPool(pool.v3Pool.lmPool());
        if (address(LMPool) != address(0) && !emergency) {
            // 2) 从 LMPool 移除本 NFT 的全部 boost 流动性，停止后续计奖。
            int128 liquidityDelta = -int128(positionInfo.boostLiquidity);
            LMPool.updatePosition(positionInfo.tickLower, positionInfo.tickUpper, liquidityDelta);
            emit UpdateLiquidity(
                msg.sender,
                pid,
                _tokenId,
                liquidityDelta,
                positionInfo.tickLower,
                positionInfo.tickUpper
            );
        }
        pool.totalLiquidity -= positionInfo.liquidity;
        pool.totalBoostLiquidity -= positionInfo.boostLiquidity;

        // 3) 清理本地仓位记录与可枚举集合，再把 NFT 还给用户指定地址。
        delete userPositionInfos[_tokenId];
        // 更新可枚举持仓集合
        removeToken(msg.sender, _tokenId);
        // 在 farm booster 中移除该 tokenId 的 boost 记录
        if (address(FARM_BOOSTER) != address(0)) FARM_BOOSTER.removeBoostMultiplier(msg.sender, _tokenId, pid);
        nonfungiblePositionManager.safeTransferFrom(address(this), _to, _tokenId);
        emit Withdraw(msg.sender, _to, pid, _tokenId);
    }

    /// @notice 同步指定 NFT 的流动性变化（例如用户在外部对该 NFT 做了增减流动性）。
    /// @param _tokenId 需要同步的 NFT tokenId。
    function updateLiquidity(uint256 _tokenId) external nonReentrant {
        UserPositionInfo storage positionInfo = userPositionInfos[_tokenId];
        if (positionInfo.pid == 0) revert InvalidNFT();
        harvestOperation(positionInfo, _tokenId, address(0));
        updateLiquidityOperation(positionInfo, _tokenId, 0);
    }
    
    /// @notice 由 Boost 合约回调更新某 NFT 的 boost 倍率。
    /// @param _tokenId 需要更新 boost 的 NFT tokenId。
    /// @param _newMultiplier 新 boost 倍率。
    function updateBoostMultiplier(uint256 _tokenId, uint256 _newMultiplier) external onlyBoostContract {
        UserPositionInfo storage positionInfo = userPositionInfos[_tokenId];
        if (positionInfo.pid == 0) revert InvalidNFT();
        harvestOperation(positionInfo, _tokenId, address(0));
        updateLiquidityOperation(positionInfo, _tokenId, _newMultiplier);
    }

    /// @notice 核心流动性同步逻辑：刷新 liquidity、计算 boostLiquidity、把差值写入 LMPool。
    /// @param positionInfo NFT 对应仓位信息（storage）。
    /// @param _tokenId NFT id。
    /// @param _newMultiplier 外部指定的新 boost 倍率（0 表示从 FARM_BOOSTER 读取最新）。
    /// @dev 核心步骤（逐行）：
    /// 1) 从 NPM 读取最新 liquidity/tick；
    /// 2) 若真实 liquidity 变化，更新池总流动性；
    /// 3) 获取并裁剪 boost 倍率到 [1x,2x]；
    /// 4) 计算新 boostLiquidity，与旧值做 delta；
    /// 5) delta != 0 时写入 LMPool.updatePosition，同步挖矿有效流动性。
    /// @dev 案例：用户从 1.0x 提升到 1.5x，真实 liquidity=1000，则 boostLiquidity 从 1000 变 1500，delta=+500。
    function updateLiquidityOperation(
        UserPositionInfo storage positionInfo,
        uint256 _tokenId,
        uint256 _newMultiplier
    ) internal {
        (, , , , , int24 tickLower, int24 tickUpper, uint128 liquidity, , , , ) = nonfungiblePositionManager.positions(
            _tokenId
        );
        PoolInfo storage pool = poolInfo[positionInfo.pid];
        // 若 NFT 在 NPM 中真实流动性已变化（比如用户增加了流动性），先同步主池统计。
        if (positionInfo.liquidity != liquidity) {
            pool.totalLiquidity = pool.totalLiquidity - positionInfo.liquidity + liquidity;
            positionInfo.liquidity = liquidity;
        }
        uint256 boostMultiplier = BOOST_PRECISION;
        if (address(FARM_BOOSTER) != address(0) && _newMultiplier == 0) {
            // 常规路径：向 FARM_BOOSTER 拉取最新倍率，并让 booster 侧同步状态。
            boostMultiplier = FARM_BOOSTER.updatePositionBoostMultiplier(_tokenId);
        } else if (_newMultiplier != 0) {
            // booster 主动回调路径：直接使用传入倍率。
            boostMultiplier = _newMultiplier;
        }

        // 保底 1x，封顶 2x，避免越界导致奖励异常。
        if (boostMultiplier < BOOST_PRECISION) {
            boostMultiplier = BOOST_PRECISION;
        } else if (boostMultiplier > MAX_BOOST_PRECISION) {
            boostMultiplier = MAX_BOOST_PRECISION;
        }

        positionInfo.boostMultiplier = boostMultiplier;
        uint128 boostLiquidity = ((uint256(liquidity) * boostMultiplier) / BOOST_PRECISION).toUint128();
        int128 liquidityDelta = int128(boostLiquidity) - int128(positionInfo.boostLiquidity);
        if (liquidityDelta != 0) {
            // 更新池级 boost 总量，并将 delta 同步到 LMPool（真正影响 rewardGrowthInside 分母）。
            pool.totalBoostLiquidity = pool.totalBoostLiquidity - positionInfo.boostLiquidity + boostLiquidity;
            positionInfo.boostLiquidity = boostLiquidity;
            ILMPool LMPool = ILMPool(pool.v3Pool.lmPool());
            if (address(LMPool) == address(0)) revert NoLMPool();
            LMPool.updatePosition(tickLower, tickUpper, liquidityDelta);
            emit UpdateLiquidity(msg.sender, positionInfo.pid, _tokenId, liquidityDelta, tickLower, tickUpper);
        }
    }

    /// @notice 增加已质押 NFT 的流动性（代币由调用者支付）。
    /// @param params NPM 的 increaseLiquidity 参数（含 tokenId、投入期望量、最小量、截止时间）。
    /// @return liquidity 本次新增流动性。
    /// @return amount0 实际消耗 token0。
    /// @return amount1 实际消耗 token1。
    /// @dev 使用场景：用户已有仓位表现好，希望“加仓同一区间”扩大挖矿份额。
    /// @dev 逻辑：收款 -> 调 NPM 增流动性 -> 退回未用完资金 -> 缓存奖励 -> 同步 boost 流动性。
    function increaseLiquidity(
        IncreaseLiquidityParams memory params
    ) external payable nonReentrant returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        UserPositionInfo storage positionInfo = userPositionInfos[params.tokenId];
        if (positionInfo.pid == 0) revert InvalidNFT();
        PoolInfo memory pool = poolInfo[positionInfo.pid];
        pay(pool.token0, params.amount0Desired);
        pay(pool.token1, params.amount1Desired);
        // 若两个币都不是 WETH，却带了 ETH，判定为异常输入。
        if (pool.token0 != WETH && pool.token1 != WETH && msg.value > 0) revert();
        (liquidity, amount0, amount1) = nonfungiblePositionManager.increaseLiquidity{value: msg.value}(params);
        uint256 token0Left = params.amount0Desired - amount0;
        uint256 token1Left = params.amount1Desired - amount1;
        if (token0Left > 0) {
            refund(pool.token0, token0Left);
        }
        if (token1Left > 0) {
            refund(pool.token1, token1Left);
        }
        // 增仓后先结算一次奖励到缓存，再更新 liquidity/boost。
        harvestOperation(positionInfo, params.tokenId, address(0));
        updateLiquidityOperation(positionInfo, params.tokenId, 0);
    }

    /// @notice 收取用户本次操作所需代币。
    /// @param _token 代币地址。
    /// @param _amount 需要支付数量。
    /// @dev 若是 WETH 路径且带 ETH，则要求 msg.value 与 _amount 一致，避免金额错配。
    function pay(address _token, uint256 _amount) internal {
        if (_token == WETH && msg.value > 0) {
            if (msg.value != _amount) revert InconsistentAmount();
        } else {
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        }
    }

    /// @notice 退还本次未用完代币给调用者。
    /// @param _token 代币地址。
    /// @param _amount 退款数量。
    /// @dev 若是 WETH 路径且用户走 ETH，先从 NPM 退回 ETH，再转给用户。
    function refund(address _token, uint256 _amount) internal {
        if (_token == WETH && msg.value > 0) {
            nonfungiblePositionManager.refundETH();
            safeTransferETH(msg.sender, address(this).balance);
        } else {
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }
    }

    /// @notice 减少 NFT 流动性（仅 owner），并同步挖矿侧流动性。
    /// @param params NPM 的 decreaseLiquidity 参数。
    /// @return amount0 本次减仓对应 token0 数量。
    /// @return amount1 本次减仓对应 token1 数量。
    /// @dev 使用场景：用户缩减仓位或准备退出。
    function decreaseLiquidity(
        DecreaseLiquidityParams memory params
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        UserPositionInfo storage positionInfo = userPositionInfos[params.tokenId];
        if (positionInfo.user != msg.sender) revert NotOwner();
        (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(params);
        harvestOperation(positionInfo, params.tokenId, address(0));
        updateLiquidityOperation(positionInfo, params.tokenId, 0);
    }

    /// @notice 领取仓位手续费/本金到指定接收地址。
    /// @param params NPM collect 参数。
    /// @return amount0 实际领取 token0。
    /// @return amount1 实际领取 token1。
    /// @dev 注意：recipient=0 时资金先留在本合约，通常应搭配 multicall 再 `unwrapWETH9/sweepToken` 转走。
    function collect(CollectParams memory params) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        UserPositionInfo memory positionInfo = userPositionInfos[params.tokenId];
        if (positionInfo.user != msg.sender) revert NotOwner();
        if (params.recipient == address(0)) params.recipient = address(this);
        (amount0, amount1) = nonfungiblePositionManager.collect(params);
    }

    /// @notice collect 增强版：当 recipient=0 时，自动把本合约里的 token/WETH 退到 `to`。
    /// @param params NPM collect 参数。
    /// @param to 退款接收地址（0 表示默认 msg.sender）。
    /// @return amount0 实际领取 token0。
    /// @return amount1 实际领取 token1。
    /// @dev 使用场景：前端不想写复杂 multicall，可直接用 collectTo 一次性提到用户钱包。
    function collectTo(
        CollectParams memory params,
        address to
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        UserPositionInfo memory positionInfo = userPositionInfos[params.tokenId];
        if (positionInfo.user != msg.sender) revert NotOwner();
        if (params.recipient == address(0)) params.recipient = address(this);
        (amount0, amount1) = nonfungiblePositionManager.collect(params);
        // recipient=本合约时，说明 collect 资金暂存在本合约，这里自动转给用户。
        if (params.recipient == address(this)) {
            PoolInfo memory pool = poolInfo[positionInfo.pid];
            if (to == address(0)) to = msg.sender;
            transferToken(pool.token0, to);
            transferToken(pool.token1, to);
        }
    }

    /// @notice 把本合约持有的指定代币余额全部转给目标地址。
    /// @param _token 代币地址。
    /// @param _to 接收地址。
    /// @dev 若 _token=WETH，会先 unwrap 成 ETH 再转账。
    function transferToken(address _token, address _to) internal {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance > 0) {
            if (_token == WETH) {
                IWETH(WETH).withdraw(balance);
                safeTransferETH(_to, balance);
            } else {
                IERC20(_token).safeTransfer(_to, balance);
            }
        }
    }

    /// @notice 把本合约中的 WETH 全部解包为 ETH 并发送给 recipient。
    /// @param amountMinimum 最小解包量（防止被恶意调用偷小额余额）。
    /// @param recipient ETH 接收地址。
    function unwrapWETH9(uint256 amountMinimum, address recipient) external nonReentrant {
        uint256 balanceWETH = IWETH(WETH).balanceOf(address(this));
        if (balanceWETH < amountMinimum) revert InsufficientAmount();

        if (balanceWETH > 0) {
            IWETH(WETH).withdraw(balanceWETH);
            safeTransferETH(recipient, balanceWETH);
        }
    }

    /// @notice 把本合约中的某 ERC20 余额全部扫给 recipient。
    /// @param token 代币地址。
    /// @param amountMinimum 最小扫出量（防恶意小额盗扫）。
    /// @param recipient 接收地址。
    function sweepToken(address token, uint256 amountMinimum, address recipient) external nonReentrant {
        uint256 balanceToken = IERC20(token).balanceOf(address(this));
        if (balanceToken < amountMinimum) revert InsufficientAmount();

        if (balanceToken > 0) {
            IERC20(token).safeTransfer(recipient, balanceToken);
        }
    }

    /// @notice 销毁已清空仓位的 NFT（必须无流动性且无未领奖励）。
    /// @param _tokenId NFT id。
    /// @dev 使用场景：用户彻底退出策略后，清理 NFT 记录，避免残留状态。
    function burn(uint256 _tokenId) external nonReentrant {
        UserPositionInfo memory positionInfo = userPositionInfos[_tokenId];
        if (positionInfo.user != msg.sender) revert NotOwner();
        if (positionInfo.reward > 0 || positionInfo.liquidity > 0) revert NotEmpty();
        delete userPositionInfos[_tokenId];
        // 更新可枚举持仓集合
        removeToken(msg.sender, _tokenId);
        // 在 farm booster 中移除该 tokenId 的 boost 记录
        if (address(FARM_BOOSTER) != address(0))
            FARM_BOOSTER.removeBoostMultiplier(msg.sender, _tokenId, positionInfo.pid);
        nonfungiblePositionManager.burn(_tokenId);
        emit Withdraw(msg.sender, address(0), positionInfo.pid, _tokenId);
    }

    /// @notice 开启新一期排放周期（更新周期元数据与每秒排放快照）。
    /// @param _amount 预留参数（当前逻辑未直接使用）。
    /// @param _duration 周期时长；不合法时回退默认 PERIOD_DURATION。
    /// @param _withUpdate 是否先更新全部池奖励累计。
    /// @dev 使用场景：每日/每周运维滚动排放窗口，便于前端展示“本期结束时间”。
    function upkeep(uint256 _amount, uint256 _duration, bool _withUpdate) external onlyOwner {
        if (_withUpdate) massUpdatePools();

        uint256 duration = PERIOD_DURATION;
        // 仅当 _duration 在合法区间 [MIN_DURATION, MAX_DURATION] 时才使用它。
        if (_duration >= MIN_DURATION && _duration <= MAX_DURATION) duration = _duration;
        uint256 currentTime = block.timestamp;
        uint256 endTime = currentTime + duration;
        uint256 cakePerSecond = globalCakePerSecond;
        unchecked {
            latestPeriodNumber++;
            latestPeriodStartTime = currentTime + 1;
            latestPeriodEndTime = endTime;
            latestPeriodCakePerSecond = cakePerSecond;
        }
        emit NewUpkeepPeriod(latestPeriodNumber, currentTime + 1, endTime, cakePerSecond);
    }

    /// @notice 更新所有池的 LMPool 累计奖励到当前时间。
    /// @dev 池子较多时 gas 可能较高，一般用于关键参数变更前后的一次全量同步。
    function massUpdatePools() internal {
        uint32 currentTime = uint32(block.timestamp);
        for (uint256 pid = 1; pid <= poolLength; pid++) {
            PoolInfo memory pool = poolInfo[pid];
            ILMPool LMPool = ILMPool(pool.v3Pool.lmPool());
            if (pool.allocPoint != 0 && address(LMPool) != address(0)) {
                LMPool.accumulateReward(currentTime);
            }
        }
    }

    /// @notice 按 pid 列表批量更新池奖励（分批替代全量更新，节省 gas）。
    function updatePools(uint256[] calldata pids) external onlyOwnerOrOperator {
        uint32 currentTime = uint32(block.timestamp);
        for (uint256 i = 0; i < pids.length; i++) {
            PoolInfo memory pool = poolInfo[pids[i]];
            ILMPool LMPool = ILMPool(pool.v3Pool.lmPool());
            if (pool.allocPoint != 0 && address(LMPool) != address(0)) {
                LMPool.accumulateReward(currentTime);
            }
        }
    }

    /// @notice 设置全局每秒排放。
    /// @dev 仅 owner 可调用。
    /// @param _globalCakePerSecond 新的每秒排放值。
    function setGlobalCakePerSecond(uint256 _globalCakePerSecond) external onlyOwner {
        globalCakePerSecond = _globalCakePerSecond;
        emit NewCakePerSecond(_globalCakePerSecond);
    }

    /// @notice 设置 operator 地址。
    /// @dev 仅 owner 可调用。
    /// @param _operatorAddress 新 operator 地址。
    function setOperator(address _operatorAddress) external onlyOwner {
        if (_operatorAddress == address(0)) revert ZeroAddress();
        operatorAddress = _operatorAddress;
        emit NewOperatorAddress(_operatorAddress);
    }

    /// @notice 设置默认周期时长。
    /// @dev 仅 owner 可调用。
    /// @param _periodDuration 新周期时长。
    function setPeriodDuration(uint256 _periodDuration) external onlyOwner {
        if (_periodDuration < MIN_DURATION || _periodDuration > MAX_DURATION) revert InvalidPeriodDuration();
        PERIOD_DURATION = _periodDuration;
        emit NewPeriodDuration(_periodDuration);
    }
    
    /// @notice 更新 farm boost 合约地址。
    /// @param _newFarmBoostContract 新 farm booster 地址。
    function updateFarmBoostContract(address _newFarmBoostContract) external onlyOwner {
        // 允许设置为零地址，用于移除 booster 功能。
        FARM_BOOSTER = IFarmBooster(_newFarmBoostContract);
        emit UpdateFarmBoostContract(_newFarmBoostContract);
    }

    /// @notice 安全转 ETH。
    /// @param to 接收 ETH 的地址。
    /// @param value 转账金额（wei）。
    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}("");
        if (!success) revert();
    }

    /// @notice 安全发放奖励：按池配置比例 mint 多奖励代币给用户。
    /// @param _to 奖励接收地址。
    /// @param _amount 本次应发总奖励量。
    /// @param _pid 池子 pid。
    function _safeTransfer(address _to, uint256 _amount, uint256 _pid) internal {
        if (_amount > 0) {
            (uint256[] memory rewardsRatio, address[] memory rewardsAddresses) = getRewardsRatioInfoByPid(_pid);
            for (uint256 i = 0; i < rewardsRatio.length; i++) {
                // 示例：_amount=100，ratio=8000，则发 80。
                uint256 rewardsAmount =  (rewardsRatio[i] * _amount) / REWARDS_PRECISION;
                require(
                    IERC20Mintable(rewardsAddresses[i]).mint(address(_to), rewardsAmount),
                    'MasterChef: mint rewardsToken failed user'
                );
            }
        }
    }

    receive() external payable {
        if (msg.sender != address(nonfungiblePositionManager) && msg.sender != WETH) revert();
    }
}
