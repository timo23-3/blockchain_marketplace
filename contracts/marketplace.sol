// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.20;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract TaskMarketplace {
    enum TaskStatus { Open, Submitted, Verified, Disputed, Accepted, Rejected }

    struct Task {
        address creator;
        address solver;
        address verifier;
        uint256 bounty;
        string descriptionHash;
        string solutionHash;
        bool approved;
        uint256 deadline;
        TaskStatus status;
        // add: verifier percentage?, time for objection?, stake amount
    }

    struct Dispute {
        bool exists;
        address objector;
        uint256 startTime;            // dispute start timestamp
        uint256 totalYesWeight;       // weighted sum for "solution is correct"
        uint256 totalNoWeight;        // weighted sum for "solution is incorrect"
        uint256 totalJurorWeight;     // total tokens staked 
        bool finalized;
        mapping(address => bool) voted; // have they voted
        mapping(address => uint256) jurorStake; // tokens staked by juror (per dispute)
        mapping(address => bool) choice; //voted yes or no
        address[] jurors;
    }


    uint256 taskCount;
    mapping(uint256 => Task) tasks;

    mapping(uint256 => Dispute) internal disputes;

    uint256 submitCost = 0.01 ether;
    uint256 verifyCost = 0.01 ether;
    uint256 public minJurorStake = 100;
    uint256 public disputePeriod = 3 minutes;

    IERC20 public governanceToken;

    event TaskPosted(uint256 taskId, address creator, uint256 bounty, string descriptionHash);
    event SolutionSubmitted(uint256 taskId, address solver, string solutionHash);
    event SolutionVerified(uint256 taskId, address verifier, bool approved);
    event DisputeCreated(uint256 taskId, address objector, uint256 deposit, uint256 startTime);
    event JurorVoted(uint256 taskId, address juror, bool supportsSolution, uint256 weight);
    event DisputeFinalized(uint256 taskId, bool finalDecision);
    event TaskFinalized(uint256 taskId, bool success);

    constructor(address _governanceToken) {
        governanceToken = IERC20(_governanceToken);
    }

    // constructor() {
    // }

    //posting a task
    function postTask(string calldata _descriptionHash) external payable {
        require(msg.value > 0, "Must send bounty");

        taskCount++;
        Task storage t = tasks[taskCount];
        t.creator = msg.sender;
        t.bounty = msg.value;
        t.descriptionHash = _descriptionHash;
        t.approved = false;
        t.status = TaskStatus.Open;

        emit TaskPosted(taskCount, msg.sender, msg.value, _descriptionHash);
    }

    //submitting a solution
    function submitSolution(uint256 _taskId, string calldata _solutionHash) external payable {
        require(_taskId > 0 && _taskId <= taskCount, "Invalid task id");
        
        Task storage t = tasks[_taskId];
        require(t.status == TaskStatus.Open, "Task not open (yet)");
        require(msg.value == submitCost, "Stake required");
        require(t.solver == address(0), "A solution has already been submitted");

        t.solutionHash = _solutionHash;
        t.solver = msg.sender;
        t.status = TaskStatus.Submitted;

        emit SolutionSubmitted(_taskId, msg.sender, _solutionHash);
    }

    //verifying a solution
    function verifySolution(uint256 _taskId, bool _approved) external payable {
        require(_taskId > 0 && _taskId <= taskCount, "Invalid task id");

        Task storage t = tasks[_taskId];
        require(t.status == TaskStatus.Submitted, "Task not submitted (yet)");
        require(msg.value == verifyCost, "Stake required");
        require(t.verifier == address(0), "Already verified"); // redundant

        t.verifier = msg.sender;
        t.approved = _approved;
        t.deadline = block.timestamp + 1 minutes;
        t.status = TaskStatus.Verified;
        emit SolutionVerified(_taskId, msg.sender, _approved);
    }

    function createDispute(uint256 _taskId) external payable {
        require(_taskId > 0 && _taskId <= taskCount, "Invalid task id");
        Task storage t = tasks[_taskId];

        require(t.status == TaskStatus.Verified, "Task not in review (yet)");
        require(block.timestamp < t.deadline, "Deadline passed");
        require(msg.value == verifyCost, "Incorrect dispute deposit");
        require(!disputes[_taskId].exists || disputes[_taskId].finalized, "Existing dispute active");

        // initialize dispute
        t.status = TaskStatus.Disputed;
        Dispute storage d = disputes[_taskId];
        d.exists = true;
        d.objector = msg.sender;
        d.startTime = block.timestamp;
        d.finalized = false;
        // juror arrays / maps are empty initially

        emit DisputeCreated(_taskId, msg.sender, msg.value, d.startTime);
    }


    function jurorVote(uint256 _taskId, uint256 _tokenAmount, bool supportsSolution) external {
        require(_taskId > 0 && _taskId <= taskCount, "Invalid task id");
        Dispute storage d = disputes[_taskId];
        require(d.exists && !d.finalized, "No active dispute");
        require(block.timestamp <= d.startTime + disputePeriod, "Voting period ended");
        require(_tokenAmount >= minJurorStake, "Stake too small");
        require(d.jurorStake[msg.sender] == 0, "Already registered");
        require(!d.voted[msg.sender], "Already voted");

        // transfer tokens from juror to contract
        bool ok = governanceToken.transferFrom(msg.sender, address(this), _tokenAmount);
        require(ok, "Token transfer failed");
        
        d.choice[msg.sender] = supportsSolution;
        d.jurorStake[msg.sender] = _tokenAmount;
        d.totalJurorWeight += _tokenAmount;
        d.jurors.push(msg.sender);
        d.voted[msg.sender] = true;

        if (supportsSolution) {
            d.totalYesWeight += _tokenAmount;
        } else {
            d.totalNoWeight += _tokenAmount;
        }

        emit JurorVoted(_taskId, msg.sender, supportsSolution, _tokenAmount);
    }

    function finalizeDispute(uint256 _taskId) external {
        require(_taskId > 0 && _taskId <= taskCount, "Invalid task id");
        Dispute storage d = disputes[_taskId];
        Task storage t = tasks[_taskId];

        require(d.exists, "No dispute");
        require(!d.finalized, "Already finalized");
        require(block.timestamp > d.startTime + disputePeriod, "Voting window still open");

        d.finalized = true;

        uint256 yes = d.totalYesWeight;
        uint256 no = d.totalNoWeight;


        if (yes >= no) {
            _distributeRewards(_taskId, true);
            _payoutAccepted(_taskId);
        } else {
            _distributeRewards(_taskId, false);
        }

        // return all juror token stakes
        for (uint256 i = 0; i < d.jurors.length; i++) {
            address jur = d.jurors[i];
            uint256 st = d.jurorStake[jur];
            if (st > 0) {
                d.jurorStake[jur] = 0;
                governanceToken.transfer(jur, st);
            }
        }
        if (yes < no) {
            // revert to Open and clear solver & verifier
            
            t.status = TaskStatus.Rejected;
            
            taskCount++;
            Task storage t2 = tasks[taskCount];
            t2.creator = t.creator;
            t2.bounty = t.bounty;
            t2.descriptionHash = t.descriptionHash;
            t2.approved = false;
            t2.status = TaskStatus.Open;


            // t.status = TaskStatus.Open;
            // t.solver = address(0);
            // t.verifier = address(0);
            // t.solutionHash = "";
            // t.deadline = 0;
            // t.approved = false;
            // d.exists = false;
            // d.finalized = false;
            // d.jurors = new address[](0);
            // d.objector = address(0);
            // d.startTime = 0;
        }
        emit DisputeFinalized(_taskId, yes >= no);
    }

    // distribute ETH deposit among jurors who sided with majority and possibly to objector/others.
    function _distributeRewards(uint256 _taskId, bool majoritySaysCorrect) internal {
        Dispute storage d = disputes[_taskId];
        Task storage t = tasks[_taskId];

        uint256 refundToObjector; 
        uint256 jurorPool = (verifyCost * 40) / 100;
        if (majoritySaysCorrect == t.approved) {
            refundToObjector = 0;
        } else {
            refundToObjector = (verifyCost * 50) / 100;  
            payable(d.objector).transfer(refundToObjector);
        }         
    
        uint256 platformFee = verifyCost - refundToObjector - jurorPool;
        if (!majoritySaysCorrect) {
            if (t.approved) {
                platformFee += submitCost;
            } else {
                payable(t.verifier).transfer(submitCost);
            }
        }

        uint256 majorityWeight = majoritySaysCorrect ? d.totalYesWeight : d.totalNoWeight;
        // edge case if nobody voted
        if (majorityWeight == 0) {
            platformFee += jurorPool;
            return;
        }

        // distribute juror rewards
        for (uint256 i = 0; i < d.jurors.length; i++) {
            address jur = d.jurors[i];
            if (d.voted[jur]) {
                uint256 jurStake = d.jurorStake[jur];
                bool jurVotedYes = d.choice[jur];
                if ((majoritySaysCorrect && jurVotedYes) || (!majoritySaysCorrect && !jurVotedYes)) {
                    uint256 reward = (jurStake * jurorPool) / majorityWeight;
                    payable(jur).transfer(reward);
                }
            }
        }
    }

    function _payoutAccepted(uint256 _taskId) internal {
        Task storage t = tasks[_taskId];
        Dispute storage d = disputes[_taskId];
        t.status = TaskStatus.Accepted;
        uint256 solverReward = (t.bounty * 90) / 100;
        uint256 verifierBonus = (t.bounty * 10) / 100;
        payable(t.solver).transfer(solverReward + submitCost);
        if (t.approved) {
            payable(t.verifier).transfer(verifierBonus + verifyCost);
        } else {
            payable(d.objector).transfer(verifierBonus + verifyCost);
        }
        emit TaskFinalized(_taskId, true);
    }

    //finalizing payments (no objection)
    function finalizeTask(uint256 _taskId) external {
        require(_taskId > 0 && _taskId <= taskCount, "Invalid task id");

        Task storage t = tasks[_taskId];
        require(t.status == TaskStatus.Verified, "Task not verified (yet)");
        require(block.timestamp > t.deadline, "Waiting time not passed yet");
        require(t.verifier != address(0), "No verifier yet"); // redundant
        require(!disputes[_taskId].exists, "disputed");

        if (t.approved) {
            t.status = TaskStatus.Accepted;
            uint256 solverReward = (t.bounty * 90) / 100;
            uint256 verifierBonus = (t.bounty * 10) / 100;
            payable(t.solver).transfer(solverReward + submitCost);
            payable(t.verifier).transfer(verifierBonus + verifyCost);
        } else { 
            payable(t.verifier).transfer(submitCost + verifyCost);
            
            t.status = TaskStatus.Open;
            t.solver = address(0);
            t.verifier = address(0);
            t.solutionHash = "";
            t.deadline = 0;
            t.approved = false;
        }
        emit TaskFinalized(_taskId, t.approved);
    }

    function getTask(uint256 _taskId) external view returns (
        address creator,
        address solver,
        address verifier,
        uint256 bounty,
        string memory descriptionHash,
        string memory solutionHash,
        bool approved,
        uint256 deadline,
        TaskStatus status
    ) {
        require(_taskId > 0 && _taskId <= taskCount, "Invalid task id");

        Task storage t = tasks[_taskId];
        return (t.creator, t.solver, t.verifier, t.bounty, t.descriptionHash, t.solutionHash, t.approved, t.deadline, t.status);
    }

    function getRemainingTime(uint256 _taskId) external view returns (uint256 Seconds) {
        require(_taskId > 0 && _taskId <= taskCount, "Invalid task id");

        if (tasks[_taskId].deadline == 0 || tasks[_taskId].deadline < block.timestamp) {
            return 0;
        } else {
            return (tasks[_taskId].deadline - block.timestamp);
        }
    }
    function getRemainingDisputeTime(uint256 _taskId) external view returns (uint256 Seconds) {
        require(_taskId > 0 && _taskId <= taskCount, "Invalid task id");

        if (disputes[_taskId].startTime == 0 || disputes[_taskId].startTime + disputePeriod >= block.timestamp) {
            return 0;
        } else {
            return (block.timestamp - (disputes[_taskId].startTime + disputePeriod));
        }
    }

    function getTaskCount() external view returns (uint256) {
        return taskCount;
    }
}
